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
    listen.sh
    orchestrate.sh
    run_indented.sh
    send.sh
    sendtree.sh
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

fleet_ssh() {   # <user@addr> <command...>
    local dest="$1"
    shift
    ssh "${ssh_opts[@]}" "$dest" "$@"
}

fleet_teardown() {
    local h dest
    for h in "${listeners[@]}"; do
        dest=$(fleet_ssh_dest "$h")
        fleet_ssh "$dest" "sudo -n systemctl stop zfsrecvd-run-$h 2>/dev/null; sudo -n systemctl reset-failed zfsrecvd-run-$h 2>/dev/null" \
            </dev/null || echo "WARNING: could not stop run listener on [$h]" >&2
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
    # Interim until D wires the full grid: keep-count is the [retention]
    # hourly bucket -- source scope for senders, destination scope for
    # receivers, the max of the two for dual-role hosts (one keep-count
    # governs both trees on such a host, and keeping more is the safe
    # direction). Falls back to 6 when the bucket is absent.
    local kc="" src_h dst_h
    src_h=$(fleet_ret_bucket "$fleet_ret_source" hourly)
    dst_h=$(fleet_ret_bucket "$fleet_ret_destination" hourly)
    if is_source "$id" && [[ -n "$src_h" ]]; then
        kc="$src_h"
    fi
    if is_receiver "$id" && [[ -n "$dst_h" ]]; then
        if [[ -z "$kc" || "$dst_h" -gt "$kc" ]]; then
            kc="$dst_h"
        fi
    fi
    [[ -z "$kc" ]] && kc=6
    {
        printf '# generated by fleetrun %s for %s -- do not edit\n' "$run_id" "$id"
        printf '[cert-dir]\n%s/%s\n' "$RUN_REMOTE_BASE" "$id"
        printf '[tcp-port]\n%s\n' "$fleet_opt_port"
        printf '[keep-count]\n%s\n' "$kc"
        printf '[prune-prefixes]\nzfsrecvd-\n'
        # No [sends] since T: the orchestrator drives sendtree per job row
        # (PROTOCOL.md §19); this conf carries host-scoped settings only.
        local i
        if is_receiver "$id"; then
            printf '[recv-root]\n%s\n' "${fleet_host_recv[$id]}"
            printf '[tcp-addr]\n%s\n' "${fleet_host_bind[$id]:-0.0.0.0}"
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
    if ! fleet_ssh "$dest" "for b in zfs socat pv openssl; do command -v \$b >/dev/null || { echo \"missing dependency on this host: \$b\" >&2; exit 9; }; done; sudo -n mkdir -p $rdir && sudo -n chmod 700 $rdir && sudo -n openssl req -new -newkey rsa:2048 -nodes -keyout $rdir/client.key -subj /CN=$id 2>/dev/null && sudo -n chmod 600 $rdir/client.key" \
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

    if ! tar czf - -C "$bdir" . | fleet_ssh "$dest" \
        "sudo -n tar xzf - -C $rdir && sudo -n cp $rdir/client.key $rdir/server.key && sudo -n chmod 600 $rdir/server.key"; then
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
    if [[ -n "${fleet_host_bind[$id]:-}" ]]; then
        bindpat="${fleet_host_bind[$id]}:$fleet_opt_port "
    fi
    echo "starting run listener on [$id] (port $fleet_opt_port)" >&2
    fleet_ssh "$dest" "sudo -n systemctl stop $unit 2>/dev/null; sudo -n systemctl reset-failed $unit 2>/dev/null; sudo -n systemd-run --unit=$unit --setenv=ZFSRECVD_CONF=$RUN_REMOTE_BASE/$id/run.conf /etc/zfsrecvd/listen.sh >/dev/null 2>&1; for i in \$(seq 1 40); do ss -tln | grep -qF '$bindpat' && exit 0; sleep 0.25; done; echo 'run listener failed to bind:' >&2; sudo -n journalctl -u $unit -n 10 --no-pager >&2; exit 1" \
        </dev/null || return 1
    listeners+=( "$id" )
}

for h in "${fleet_participants[@]}"; do
    if ! provision_host "$h"; then
        prov_failed[$h]=1
        echo "ERROR: provisioning [$h] failed; dropping its jobs from this run" >&2
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
echo "run $run_id finished (rc=$orch_rc); tearing down" >&2
exit "$orch_rc"
