#!/usr/bin/env bash
# The Final Shape driver: one run of the whole fleet from one config.
#
#   fleetrun.sh [-c fleet.conf] [--check] [--keep] [-- orchestrate args]
#
# Reads fleet.conf (see fleetparser.sh / PROTOCOL.md §18), then:
#   1. wakes any EC2 hosts participating in this run,
#   2. mints a per-run CA and per-host certs (keys are generated ON the
#      hosts and never transit; validity is a constant 365 days -- the
#      revocation story is CA abandonment at teardown, not expiry),
#   3. generates per-host run configs (the CLASSIC format, consumed via
#      the ZFSRECVD_CONF override -- sendtree/listen are unchanged),
#   4. ships bundles to /etc/zfsrecvd/run/ on every participant,
#   5. starts an ephemeral listener (systemd-run unit "zfsrecvd-run") on
#      every receiver, bound to the run CA,
#   6. executes the run through orchestrate.sh's worker pool: one job per
#      (source, tree, destination) row, scheduled per PROTOCOL.md §19,
#   7. tears everything down: listeners stopped, /etc/zfsrecvd/run removed,
#      local run dir (including the CA key) deleted unless --keep.
#
# Static certs and each host's own /etc/zfsrecvd/zfsrecvd.conf are never
# touched; manual send.sh runs keep working throughout.
#
# Exit: orchestrate's exit code (0/1/2), or 78 config, 75 busy, 1 provisioning.

set -euo pipefail
set -f
source /etc/zfsrecvd/ec2helpers.sh
source /etc/zfsrecvd/fleetparser.sh

FLEET_CONF="/etc/zfsrecvd/fleet.conf"
# Per-IDENTITY run dirs under this base: two identities can share one
# physical host (sender + receiver roles, or test rigs) without their
# bundles clobbering each other.
RUN_REMOTE_BASE="/etc/zfsrecvd/run"

# The scripts every participant gets refreshed with on every run, from
# this orchestrator's /etc/zfsrecvd (keep in sync with deploy.sh's list).
# Shipping them per run makes participants stateless: a brand-new sender
# needs only ssh, sudo, and the packages (zfs, socat, pv) -- no
# prior deploy.sh visit. --unlink-first so a script that is executing
# right now is replaced via a fresh inode, never truncated.
FLEET_SCRIPTS=(
    cfgparser.sh
    deploy.sh
    ec2helpers.sh
    fleetparser.sh
    fleetrun.sh
    gc.sh
    listen.sh
    orchestrate.sh
    pp2.sh
    retain.sh
    run_indented.sh
    send.sh
    sendtree.sh
    unlock-replica.sh
    zfsrecvd.sh
)
check_only=""
keep_rundir=""
orch_args=()
while (( $# > 0 )); do
    case "$1" in
        -c|--config) FLEET_CONF="$2"; shift 2 ;;
        --check)     check_only=1; shift ;;
        --keep)      keep_rundir=1; shift ;;
        --)          shift; orch_args=( "$@" ); break ;;
        *)           echo "Usage: $0 [-c fleet.conf] [--check] [--keep] [-- orchestrate args]" >&2
                     exit 64 ;;
    esac
done

fleet_parse "$FLEET_CONF"

for f in "${FLEET_SCRIPTS[@]}"; do
    if [[ ! -f "/etc/zfsrecvd/$f" ]]; then
        echo "ERROR: /etc/zfsrecvd/$f missing on the orchestrator; run install.sh first" >&2
        exit 1
    fi
done

#
# ---------- plan -------------------------------------------------------------
#
wake_ids=()
for h in "${fleet_participants[@]}"; do
    if [[ -n "${fleet_host_ec2[$h]:-}" ]]; then
        wake_ids+=( "${fleet_host_ec2[$h]}" )
    fi
done

echo "fleet plan: ${#fleet_job_src[@]} jobs, sources: ${fleet_sources[*]}, receivers: ${fleet_receivers[*]}" >&2
if [[ ${#wake_ids[@]} -gt 0 ]]; then
    echo "fleet plan: EC2 wake set: ${wake_ids[*]}" >&2
fi
if [[ "$fleet_opt_transport" == "haproxy" ]]; then
    echo "fleet plan: transport haproxy (PP2 identity)" >&2
fi
if [[ -n "$check_only" ]]; then
    local_i=0
    while (( local_i < ${#fleet_job_src[@]} )); do
        printf '  job: %s %s -> %s (dial %s)\n' \
            "${fleet_job_src[local_i]}" "${fleet_job_tree[local_i]}" \
            "${fleet_job_dest[local_i]}" "$(fleet_data "${fleet_job_dest[local_i]}")" >&2
        local_i=$(( local_i + 1 ))
    done
    echo "fleet plan: OK (check only, nothing provisioned)" >&2
    exit 0
fi

# One orchestrate/deploy/fleetrun at a time across the estate; the child
# orchestrate skips the lock via ZFSRECVD_SKIP_LOCK.
orch_lock
export ZFSRECVD_SKIP_LOCK=1

rundir=$(mktemp -d /tmp/zfsrecvd-fleet.XXXXXX)
provisioned=()
listeners=()
ha_started=()
declare -A prov_failed=()    # identity -> 1; dropped from the run, forces rc 1

is_receiver() {
    local r
    for r in "${fleet_receivers[@]}"; do
        [[ "$r" == "$1" ]] && return 0
    done
    return 1
}

is_source() {
    local s
    for s in "${fleet_sources[@]}"; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# H transport port plan (PROTOCOL.md §20): haproxy owns $fleet_opt_port
# (TLS, public). Each receiver identity gets a loopback plaintext port
# for its run listener (base+1+idx -- two receiver identities can share a
# box), and every sender bridges to receiver idx via loopback port
# base+64+idx (the same table on every sender; the two pools cannot
# collide below 63 receivers). All allocations are recorded in generated
# configs, nothing is probed at runtime.
declare -A recv_plain=() recv_tun=()
if [[ "$fleet_opt_transport" == "haproxy" ]]; then
    _ri=0
    for h in "${fleet_receivers[@]}"; do
        recv_plain[$h]=$(( fleet_opt_port + 1 + _ri ))
        recv_tun[$h]=$(( fleet_opt_port + 64 + _ri ))
        _ri=$(( _ri + 1 ))
    done
fi

fleet_ssh() {   # <user@addr> <command...>
    local dest="$1"
    shift
    ssh "${ssh_opts[@]}" "$dest" "$@"
}

fleet_teardown() {
    # stop + reset-failed are best-effort: a CLEANLY stopped transient
    # unit is removed instantly, making reset-failed whine "not loaded"
    # -- rc noise, not a failure (first real H run warned on every host
    # while every haproxy was in fact down). The verdict is the final
    # is-active: warn only when a unit actually survived teardown.
    local h dest
    for h in "${ha_started[@]}"; do
        dest=$(fleet_ssh_dest "$h")
        fleet_ssh "$dest" "sudo -n systemctl stop zfsrecvd-ha-$h 2>/dev/null; sudo -n systemctl reset-failed zfsrecvd-ha-$h 2>/dev/null; ! systemctl is-active --quiet zfsrecvd-ha-$h" \
            </dev/null || echo "WARNING: haproxy unit still active on [$h]" >&2
    done
    for h in "${listeners[@]}"; do
        dest=$(fleet_ssh_dest "$h")
        fleet_ssh "$dest" "sudo -n systemctl stop zfsrecvd-run-$h 2>/dev/null; sudo -n systemctl reset-failed zfsrecvd-run-$h 2>/dev/null; ! systemctl is-active --quiet zfsrecvd-run-$h" \
            </dev/null || echo "WARNING: run listener still active on [$h]" >&2
    done
    # prov_failed hosts too: a mid-provision failure can leave a partial
    # run dir behind, and the cleanup attempt is cheap if they are still
    # offline (fast refusal or one timeout).
    for h in "${provisioned[@]}" "${!prov_failed[@]}"; do
        dest=$(fleet_ssh_dest "$h")
        fleet_ssh "$dest" "sudo -n rm -rf $RUN_REMOTE_BASE/$h; sudo -n rmdir $RUN_REMOTE_BASE 2>/dev/null || true" \
            </dev/null || echo "WARNING: could not remove $RUN_REMOTE_BASE/$h on [$h]" >&2
    done
    if [[ -n "$keep_rundir" ]]; then
        echo "run artifacts kept in $rundir (--keep)" >&2
    else
        rm -rf -- "$rundir"
    fi
}

#
# ---------- 1. wake EC2 (before provisioning needs to ssh into them) ----------
#
orchec2up=( "${wake_ids[@]}" )
ec2_maybe_start
# ec2_maybe_start installed its own EXIT trap; combine with teardown so a
# failure at any later point still stops instances AND cleans up hosts.
trap 'fleet_teardown; stop_ec2_instances' EXIT

#
# ---------- 2. mint the run CA -----------------------------------------------
#
run_id="run-$(date -u +%Y%m%d-%H%M%S)"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$rundir/ca.key" -out "$rundir/ca.pem" \
    -subj "/CN=zfsrecvd-$run_id-ca" 2>/dev/null
echo "minted run CA ($run_id, validity 365d)" >&2

#
# ---------- 3. generate + provision every participant ------------------------
#
gen_run_conf() {   # $1 = host identity -> writes $rundir/bundle-$1/run.conf
    local id="$1" out="$rundir/bundle-$1/run.conf"
    # keep-count is the sender-side retention: the source scope's hourly
    # bucket (senders retain hourlies ONLY -- owner doctrine, §22).
    # Receivers prune by the [retain] grid below; their keep-count is a
    # fallback for a config that somehow lost its grid. Source wins on
    # dual-role hosts: the local prune there is sender business.
    local kc="" src_h dst_h
    src_h=$(fleet_ret_bucket "$fleet_ret_source" hourly)
    dst_h=$(fleet_ret_bucket "$fleet_ret_destination" hourly)
    if is_source "$id" && [[ -n "$src_h" ]]; then
        kc="$src_h"
    elif is_receiver "$id" && [[ -n "$dst_h" ]]; then
        kc="$dst_h"
    fi
    [[ -z "$kc" ]] && kc=6
    {
        printf '# generated by fleetrun %s for %s -- do not edit\n' "$run_id" "$id"
        printf '[cert-dir]\n%s/%s\n' "$RUN_REMOTE_BASE" "$id"
        if [[ "$fleet_opt_transport" == "haproxy" ]]; then
            printf '[transport]\nhaproxy\n'
            if is_receiver "$id"; then
                # loopback plaintext port the run listener binds behind
                # this host's haproxy TLS frontend
                printf '[tcp-port]\n%s\n' "${recv_plain[$id]}"
            fi
        else
            printf '[tcp-port]\n%s\n' "$fleet_opt_port"
        fi
        printf '[keep-count]\n%s\n' "$kc"
        printf '[prune-prefixes]\nzfsrecvd-\n'
        # No [sends] since T: the orchestrator drives sendtree per job row
        # (PROTOCOL.md §19); this conf carries host-scoped settings only.
        local i d
        declare -A tseen=()
        if [[ "$fleet_opt_transport" == "haproxy" ]] && is_source "$id"; then
            # dial name -> loopback port of this sender's haproxy bridge
            printf '[tunnel]\n'
            for (( i = 0; i < ${#fleet_job_src[@]}; i++ )); do
                if [[ "${fleet_job_src[i]}" == "$id" && -z "${tseen[${fleet_job_dest[i]}]:-}" ]]; then
                    d="${fleet_job_dest[i]}"
                    tseen[$d]=1
                    printf '%s %s\n' "$(fleet_data "$d")" "${recv_tun[$d]}"
                fi
            done
        fi
        if is_receiver "$id"; then
            printf '[recv-root]\n%s\n' "${fleet_host_recv[$id]}"
            if [[ -n "$fleet_ret_destination" ]]; then
                # the deep grid; prune_tree thins by it at ENDTREE
                printf '[retain]\n%s\n' "$fleet_ret_destination"
            fi
            if [[ "$fleet_opt_transport" == "haproxy" ]]; then
                # haproxy owns the public bind; the listener stays local
                printf '[tcp-addr]\n127.0.0.1\n'
            else
                printf '[tcp-addr]\n%s\n' "${fleet_host_bind[$id]:-0.0.0.0}"
            fi
            printf '[allowed_hosts]\n'
            local s
            declare -A allowed=()
            for (( i = 0; i < ${#fleet_job_src[@]}; i++ )); do
                if [[ "${fleet_job_dest[i]}" == "$id" ]]; then
                    s="${fleet_job_src[i]}"
                    if [[ -z "${allowed[$s]:-}" ]]; then
                        allowed[$s]=1
                        printf '%s\n' "$s"
                    fi
                fi
            done
        fi
    } > "$out"
}

provision_host() {   # $1 = host identity
    local id="$1"
    local dest data bdir rdir
    dest=$(fleet_ssh_dest "$id")
    data=$(fleet_data "$id")
    bdir="$rundir/bundle-$id"
    rdir="$RUN_REMOTE_BASE/$id"
    mkdir -p "$bdir"
    echo "provisioning [$id] ($dest)" >&2

    # dependency preflight + key/CSR minted on the host; only the CSR
    # travels back. Every step reports and RETURNS 1 instead of dying: one
    # offline box must not take the whole fleet's run down -- the caller
    # drops the host's jobs and carries on (learned on the first real T
    # run, when a powered-off virtualboy killed all 70 jobs). NB set -e
    # is suppressed inside a function called under "if !", so the error
    # handling here must be explicit.
    local deps="zfs socat pv openssl"
    if [[ "$fleet_opt_transport" == "haproxy" ]]; then
        deps="$deps haproxy"
    fi
    if ! fleet_ssh "$dest" "for b in $deps; do command -v \$b >/dev/null || { echo \"missing dependency on this host: \$b\" >&2; exit 9; }; done; sudo -n mkdir -p $rdir && sudo -n chmod 700 $rdir && sudo -n openssl req -new -newkey rsa:2048 -nodes -keyout $rdir/client.key -subj /CN=$id 2>/dev/null && sudo -n chmod 600 $rdir/client.key" \
        </dev/null > "$rundir/$id.csr"; then
        echo "ERROR: [$id] unreachable or failed preflight" >&2
        return 1
    fi
    if ! grep -q "BEGIN CERTIFICATE REQUEST" "$rundir/$id.csr"; then
        echo "ERROR: no CSR from [$id]" >&2
        return 1
    fi

    # sign with the run CA; SANs carry identity and dial name (H needs SANs)
    printf 'subjectAltName=DNS:%s,DNS:%s\n' "$id" "$data" > "$rundir/$id.ext"
    openssl x509 -req -in "$rundir/$id.csr" -CA "$rundir/ca.pem" -CAkey "$rundir/ca.key" \
        -CAcreateserial -days 365 -extfile "$rundir/$id.ext" -out "$bdir/client.pem" 2>/dev/null
    if ! grep -q "BEGIN CERTIFICATE" "$bdir/client.pem"; then
        echo "ERROR: signing failed for [$id]" >&2
        return 1
    fi

    # one key+cert serves both roles: no EKU restriction, both names in SAN
    cp "$bdir/client.pem" "$bdir/server.pem"
    cp "$rundir/ca.pem" "$bdir/ca.pem"
    gen_run_conf "$id"
    local postship=""
    if [[ "$fleet_opt_transport" == "haproxy" ]]; then
        gen_haproxy_cfg "$id"
        # haproxy wants cert+key in ONE pem; assembled on the host so
        # the private key still never transits
        postship=" && sudo -n sh -c 'cat $rdir/client.pem $rdir/client.key > $rdir/haproxy.pem && chmod 600 $rdir/haproxy.pem'"
    fi

    if ! tar czf - -C "$bdir" . | fleet_ssh "$dest" \
        "sudo -n tar xzf - -C $rdir && sudo -n cp $rdir/client.key $rdir/server.key && sudo -n chmod 600 $rdir/server.key$postship"; then
        echo "ERROR: bundle ship to [$id] failed" >&2
        return 1
    fi

    # refresh the scripts themselves: participants are stateless, no prior
    # deploy.sh visit required, and version skew cannot exist within a run
    if ! tar czf - -C /etc/zfsrecvd "${FLEET_SCRIPTS[@]}" | fleet_ssh "$dest" \
        "sudo -n mkdir -p /etc/zfsrecvd && sudo -n tar xzf - -C /etc/zfsrecvd --unlink-first"; then
        echo "ERROR: script ship to [$id] failed" >&2
        return 1
    fi
    provisioned+=( "$id" )
}

start_listener() {   # $1 = receiver identity
    local id="$1" dest unit bindpat
    dest=$(fleet_ssh_dest "$id")
    unit="zfsrecvd-run-$id"
    # Verify the bind by address when one is configured: two receiver
    # identities can share a box on different addresses of the same port,
    # and a bare :port match would credit one listener with the other's
    # socket.
    bindpat=":$fleet_opt_port "
    if [[ "$fleet_opt_transport" == "haproxy" ]]; then
        # behind haproxy the listener binds loopback on its plain port
        bindpat="127.0.0.1:${recv_plain[$id]} "
    elif [[ -n "${fleet_host_bind[$id]:-}" ]]; then
        bindpat="${fleet_host_bind[$id]}:$fleet_opt_port "
    fi
    echo "starting run listener on [$id] (port $fleet_opt_port)" >&2
    fleet_ssh "$dest" "sudo -n systemctl stop $unit 2>/dev/null; sudo -n systemctl reset-failed $unit 2>/dev/null; sudo -n systemd-run --unit=$unit --setenv=ZFSRECVD_CONF=$RUN_REMOTE_BASE/$id/run.conf /etc/zfsrecvd/listen.sh >/dev/null 2>&1; for i in \$(seq 1 40); do ss -tln | grep -qF '$bindpat' && exit 0; sleep 0.25; done; echo 'run listener failed to bind:' >&2; sudo -n journalctl -u $unit -n 10 --no-pager >&2; exit 1" \
        </dev/null || return 1
    listeners+=( "$id" )
}

# One haproxy per participant per run, doing every role the box has:
# receiver = TLS frontend on the public bind, plaintext to the local run
# listener with the client CN forwarded as a PROXY protocol v2 TLV;
# sender = one loopback plaintext frontend per destination, TLS with the
# run client cert outward. Owner's benched template verbatim -- 1M
# bufsize is a constant, not a knob (2M regresses, 4M heavily; §20).
gen_haproxy_cfg() {   # $1 = identity -> writes $rundir/bundle-$1/haproxy.cfg
    local id="$1" out="$rundir/bundle-$1/haproxy.cfg" rdir="$RUN_REMOTE_BASE/$1"
    local i d
    declare -A hseen=()
    {
        printf 'global\n    maxconn 64\n    tune.bufsize 1048576\n    tune.maxrewrite 16384\n\n'
        printf 'defaults\n    mode tcp\n    timeout connect 5s\n    timeout client 1h\n    timeout server 1h\n\n'
        if is_receiver "$id"; then
            printf 'frontend tls_in\n'
            printf '    bind %s:%s ssl crt %s/haproxy.pem ca-file %s/ca.pem verify required\n' \
                "${fleet_host_bind[$id]:-0.0.0.0}" "$fleet_opt_port" "$rdir" "$rdir"
            printf '    default_backend sink\n\n'
            printf 'backend sink\n'
            printf '    server local 127.0.0.1:%s send-proxy-v2-ssl-cn\n\n' "${recv_plain[$id]}"
        fi
        if is_source "$id"; then
            for (( i = 0; i < ${#fleet_job_src[@]}; i++ )); do
                if [[ "${fleet_job_src[i]}" == "$id" && -z "${hseen[${fleet_job_dest[i]}]:-}" ]]; then
                    d="${fleet_job_dest[i]}"
                    hseen[$d]=1
                    printf 'frontend plain_%s\n    bind 127.0.0.1:%s\n    default_backend tun_%s\n\n' \
                        "$d" "${recv_tun[$d]}" "$d"
                    printf 'backend tun_%s\n    server receiver %s:%s ssl crt %s/haproxy.pem ca-file %s/ca.pem verify required\n\n' \
                        "$d" "$(fleet_data "$d")" "$fleet_opt_port" "$rdir" "$rdir"
                fi
            done
        fi
    } > "$out"
}

start_haproxy() {   # $1 = participant identity
    local id="$1" dest unit rdir pat i
    dest=$(fleet_ssh_dest "$id")
    unit="zfsrecvd-ha-$id"
    rdir="$RUN_REMOTE_BASE/$id"
    # bind-verify pattern: receivers bind their public TLS port; a
    # sender-only box binds its first tunnel frontend on loopback
    if is_receiver "$id"; then
        pat="${fleet_host_bind[$id]:-0.0.0.0}:$fleet_opt_port "
    else
        pat=""
        for (( i = 0; i < ${#fleet_job_src[@]}; i++ )); do
            if [[ "${fleet_job_src[i]}" == "$id" ]]; then
                pat="127.0.0.1:${recv_tun[${fleet_job_dest[i]}]} "
                break
            fi
        done
    fi
    echo "starting haproxy on [$id]" >&2
    fleet_ssh "$dest" "sudo -n systemctl stop $unit 2>/dev/null; sudo -n systemctl reset-failed $unit 2>/dev/null; sudo -n systemd-run --unit=$unit /usr/sbin/haproxy -db -f $rdir/haproxy.cfg >/dev/null 2>&1; for i in \$(seq 1 40); do ss -tln | grep -qF '$pat' && exit 0; sleep 0.25; done; echo 'haproxy failed to bind:' >&2; sudo -n journalctl -u $unit -n 15 --no-pager >&2; exit 1" \
        </dev/null || return 1
    ha_started+=( "$id" )
}

for h in "${fleet_participants[@]}"; do
    if ! provision_host "$h"; then
        prov_failed[$h]=1
        echo "ERROR: provisioning [$h] failed; dropping its jobs from this run" >&2
    fi
done

# Space accounting for the run report: recv_root `used` before any bytes
# move; the delta at the end is the run's net effect on the pool.
declare -A rused_before=()
for h in "${fleet_receivers[@]}"; do
    if [[ -z "${prov_failed[$h]:-}" ]]; then
        rused_before[$h]=$(fleet_ssh "$(fleet_ssh_dest "$h")" \
            "zfs get -Hp -o value used ${fleet_host_recv[$h]}" </dev/null 2>/dev/null) \
            || rused_before[$h]=""
    fi
done
for h in "${fleet_receivers[@]}"; do
    if [[ -n "${prov_failed[$h]:-}" ]]; then
        continue
    fi
    if ! start_listener "$h"; then
        prov_failed[$h]=1
        echo "ERROR: run listener on [$h] failed; dropping its jobs from this run" >&2
    fi
done
if [[ "$fleet_opt_transport" == "haproxy" ]]; then
    # receivers first: senders' backends dial their TLS frontends.
    # Dual-role boxes get their (combined) haproxy in this first pass.
    for h in "${fleet_receivers[@]}"; do
        if [[ -n "${prov_failed[$h]:-}" ]]; then
            continue
        fi
        if ! start_haproxy "$h"; then
            prov_failed[$h]=1
            echo "ERROR: haproxy on [$h] failed; dropping its jobs from this run" >&2
        fi
    done
    for h in "${fleet_sources[@]}"; do
        if [[ -n "${prov_failed[$h]:-}" ]] || is_receiver "$h"; then
            continue
        fi
        if ! start_haproxy "$h"; then
            prov_failed[$h]=1
            echo "ERROR: haproxy on [$h] failed; dropping its jobs from this run" >&2
        fi
    done
fi

#
# ---------- 4. generated orchestrator config + execute -----------------------
#
runnable=0
{
    printf '# generated by fleetrun %s -- do not edit\n' "$run_id"
    printf '[orchestrator-workers]\n%s\n' "$fleet_opt_workers"
    printf '[orchestrator-jobs]\n'
    # <source-id> <user@host> <run.conf> <tree> <dest-id> <dial>
    # jobs touching a host that failed provisioning are dropped here
    for (( i = 0; i < ${#fleet_job_src[@]}; i++ )); do
        if [[ -n "${prov_failed[${fleet_job_src[i]}]:-}" || -n "${prov_failed[${fleet_job_dest[i]}]:-}" ]]; then
            continue
        fi
        runnable=$(( runnable + 1 ))
        printf '%s %s %s/%s/run.conf %s %s %s\n' \
            "${fleet_job_src[i]}" "$(fleet_ssh_dest "${fleet_job_src[i]}")" \
            "$RUN_REMOTE_BASE" "${fleet_job_src[i]}" \
            "${fleet_job_tree[i]}" "${fleet_job_dest[i]}" \
            "$(fleet_data "${fleet_job_dest[i]}")"
    done
    # EC2 handled by fleetrun itself (instances must be up before
    # provisioning); the child orchestrate gets an empty wake set.
} > "$rundir/orchestrator.conf"

if (( runnable == 0 )); then
    echo "ERROR: no runnable jobs remain after provisioning failures" >&2
    exit 1
fi

echo "executing run $run_id" >&2
set +e
ZFSRECVD_CONF="$rundir/orchestrator.conf" \
    /etc/zfsrecvd/orchestrate.sh "${orch_args[@]}"
orch_rc=$?
set -e

if (( ${#prov_failed[@]} > 0 )); then
    echo "WARNING: hosts dropped by provisioning/listener failures: ${!prov_failed[*]}" >&2
    orch_rc=1
fi
# Orphan GC pass, warn-only (PROTOCOL.md §22): summary-class output,
# printed in every mode -- these are the loud advance warnings the GC
# doctrine requires, plus the owner's "old crap" listing.
# The GC test knobs forward over ssh (numeric-validated): the natural
# way to use them is on the fleetrun command line, and env does not
# cross ssh by itself (bit the owner's first grace-knob experiment).
gcenv=""
if [[ "${ZFSRECVD_GC_CAND_DAYS:-}" =~ ^[0-9]+$ ]]; then
    gcenv+=" ZFSRECVD_GC_CAND_DAYS=${ZFSRECVD_GC_CAND_DAYS}"
fi
if [[ "${ZFSRECVD_GC_GRACE_DAYS:-}" =~ ^[0-9]+$ ]]; then
    gcenv+=" ZFSRECVD_GC_GRACE_DAYS=${ZFSRECVD_GC_GRACE_DAYS}"
fi
for h in "${fleet_receivers[@]}"; do
    if [[ -n "${prov_failed[$h]:-}" ]]; then
        continue
    fi
    echo "gc: [$h]" >&2
    fleet_ssh "$(fleet_ssh_dest "$h")" \
        "sudo -n env ZFSRECVD_CONF=$RUN_REMOTE_BASE/$h/run.conf$gcenv /etc/zfsrecvd/gc.sh" \
        </dev/null >&2 \
        || echo "WARNING: gc pass failed on [$h]" >&2
done

#
# ---------- run report v1 (PROTOCOL.md §22): net / pruned / avail ------------
#
report_json=""
for h in "${fleet_receivers[@]}"; do
    if [[ -n "${prov_failed[$h]:-}" ]]; then
        continue
    fi
    vals=$(fleet_ssh "$(fleet_ssh_dest "$h")" \
        "zfs get -Hp -o value used,avail ${fleet_host_recv[$h]}; sudo -n cat $RUN_REMOTE_BASE/$h/pruned.bytes 2>/dev/null || true" \
        </dev/null 2>/dev/null) || vals=""
    r_used=$(sed -n 1p <<<"$vals")
    r_avail=$(sed -n 2p <<<"$vals")
    r_pruned=$(sed -n '3,$p' <<<"$vals" | awk '{s+=$1} END{printf "%d", s+0}')
    r_before="${rused_before[$h]:-}"
    if [[ "$r_used" =~ ^[0-9]+$ && "$r_before" =~ ^[0-9]+$ ]]; then
        r_net=$(( r_used - r_before ))
        r_sign=""
        (( r_net >= 0 )) && r_sign="+"
        echo "report: [$h] net ${r_sign}$(numfmt --to=iec -- "$r_net" 2>/dev/null || echo "$r_net")B, pruned $(numfmt --to=iec -- "$r_pruned" 2>/dev/null || echo "$r_pruned")B, avail $(numfmt --to=iec -- "${r_avail:-0}" 2>/dev/null || echo "$r_avail")B" >&2
        report_json="${report_json}${report_json:+,}{\"id\":\"$h\",\"before\":$r_before,\"after\":$r_used,\"avail\":${r_avail:-0},\"pruned\":$r_pruned}"
        # ZFSRECVD_SHOW_PRUNES=1: name every snapshot this run destroyed
        # on the receiver (owner: watch the thinning while trust in it
        # builds). The ledger exists regardless; only display is gated.
        if [[ -n "${ZFSRECVD_SHOW_PRUNES:-}" ]]; then
            fleet_ssh "$(fleet_ssh_dest "$h")" \
                "sudo -n cat $RUN_REMOTE_BASE/$h/pruned.list 2>/dev/null || true" \
                </dev/null 2>/dev/null | sed 's/^/  pruned: /' >&2 || true
        fi
    else
        echo "report: [$h] space accounting unavailable this run" >&2
    fi
done
if [[ -n "$report_json" ]]; then
    report_dir="/var/log/zfsrecvd"
    if ! mkdir -p "$report_dir" 2>/dev/null || [[ ! -w "$report_dir" ]]; then
        report_dir="${XDG_STATE_HOME:-$HOME/.local/state}/zfsrecvd"
        mkdir -p "$report_dir" 2>/dev/null || report_dir=""
    fi
    if [[ -n "$report_dir" ]]; then
        printf '{"ts":"%s","kind":"run","run":"%s","rc":%s,"recv":[%s]}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id" "$orch_rc" "$report_json" \
            >> "$report_dir/runs.jsonl" 2>/dev/null || true
    fi
fi

echo "run $run_id finished (rc=$orch_rc); tearing down" >&2
exit "$orch_rc"
