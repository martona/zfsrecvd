#!/usr/bin/env bash
# steve -- the stevedore front door (PROTOCOL.md §24). A pure dispatcher
# with a deliberately small surface: everything else in the lib dir is
# internal, and debug invocation is the full path (appropriate friction).
#
#   steve install              copy the impl set to /usr/local/lib/stevedore,
#                              link /usr/local/bin/steve, create /etc/stevedore
#                              and the /var/lib/stevedore ledger (owned by the
#                              invoking user -- the orchestrator's identity)
#   steve run [args]           one fleet run (stevedore-fleetrun.sh; --check
#                              previews the plan, everything passes through)
#   steve report [args]        render runs.jsonl (--gc-debug for the full
#                              GC track inventory)
#   steve check                doctor: install integrity, config parse,
#                              ledger writability, dependencies, participant
#                              reachability, leftover run units/dirs
#   steve unlock <replica>     load a received replica's keys from its own
#                              keystore (stevedore-unlock-replica.sh)
#   steve uninstall [--purge]  remove the code; --purge also config + ledger
#   steve help                 the operator cheat-sheet
#
# Installed, /usr/local/bin/steve is a symlink here; dispatch resolves the
# real path so siblings are found in the lib dir. From a git checkout,
# `sudo bash stevedore.sh install` bootstraps (first ever install), and
# every subcommand runs against the checkout's own scripts -- which is
# exactly what the VM rig wants.

set -euo pipefail

STEVE_HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$STEVE_HERE/stevedore-paths.sh"

usage() {
    echo "usage: steve install | run [args] | jobs [-c conf] | report [args] | check | timer [on [cal]|off|status] | unlock <replica> | uninstall [--purge] | help" >&2
    exit 64
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: steve $1 needs root (rerun under sudo)" >&2
        exit 1
    fi
}

# The orchestrator's identity: the ledger belongs to the user who runs the
# fleet, not to root -- this is what collapses the manual-vs-systemd
# duality (§24: both modes write the system path).
orch_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
    else
        id -un
    fi
}

do_install() {
    need_root install
    local f u home legacy
    for f in "${STEVE_FILES[@]}"; do
        if [[ ! -f "$STEVE_HERE/$f" ]]; then
            echo "ERROR: $STEVE_HERE/$f missing; install must run from a complete checkout or lib dir" >&2
            exit 1
        fi
    done
    mkdir -p "$STEVE_LIB"
    for f in "${STEVE_FILES[@]}"; do
        # fresh inode per file (a script executing right now must never be
        # truncated in place -- same rule as the fleet ship's --unlink-first)
        rm -f "$STEVE_LIB/$f.new"
        cp "$STEVE_HERE/$f" "$STEVE_LIB/$f.new"
        chmod 755 "$STEVE_LIB/$f.new"
        mv -f "$STEVE_LIB/$f.new" "$STEVE_LIB/$f"
    done
    ln -sfn "$STEVE_LIB/stevedore.sh" "$STEVE_BIN"

    mkdir -p "$STEVE_ETC"
    if [[ ! -f "$STEVE_ETC/stevedore.conf" && -f "$STEVE_HERE/stevedore.conf" ]]; then
        cp "$STEVE_HERE/stevedore.conf" "$STEVE_ETC/stevedore.conf"
    fi

    u=$(orch_user)
    mkdir -p "$STEVE_VAR"
    chown "$u" "$STEVE_VAR"
    if [[ ! -s "$STEVE_VAR/runs.jsonl" ]]; then
        # one-time ledger import (§24): the pre-stevedore ledger lived in
        # the orchestrator user's state dir (or /var/log); history -- and
        # the cadence windows computed from it -- carries over verbatim
        home=$(getent passwd "$u" | cut -d: -f6)
        for legacy in "$home/.local/state/zfsrecvd/runs.jsonl" /var/log/zfsrecvd/runs.jsonl; do
            if [[ -s "$legacy" ]]; then
                cat "$legacy" >> "$STEVE_VAR/runs.jsonl"
                echo "imported ledger: $legacy ($(wc -l < "$legacy") lines)" >&2
                break
            fi
        done
    fi
    touch "$STEVE_VAR/runs.jsonl"
    chown "$u" "$STEVE_VAR/runs.jsonl"

    echo "stevedore installed: $STEVE_LIB (steve -> $STEVE_BIN, ledger $STEVE_VAR/runs.jsonl owned by $u)" >&2
    echo "config dir: $STEVE_ETC (fleet.conf drives runs; stevedore.conf is per-host settings)" >&2
}

do_uninstall() {
    need_root uninstall
    local purge=""
    [[ "${1:-}" == "--purge" ]] && purge=1
    rm -f "$STEVE_BIN"
    rm -rf "$STEVE_LIB"
    if [[ -n "$purge" ]]; then
        rm -rf "$STEVE_ETC" "$STEVE_VAR"
        echo "stevedore removed, including config and ledger (--purge)" >&2
    else
        echo "stevedore code removed; config ($STEVE_ETC) and ledger ($STEVE_VAR) kept" >&2
    fi
}

# Doctor. Every finding prints; exit 1 if anything failed. Read-only.
do_check() {
    local bad=0 f missing=()

    ok()   { echo "check: OK   $*"; }
    warn() { echo "check: WARN $*"; }
    fail() { echo "check: FAIL $*"; bad=1; }

    # install integrity
    if [[ -L "$STEVE_BIN" && "$(readlink -f "$STEVE_BIN")" == "$STEVE_LIB/stevedore.sh" ]]; then
        ok "steve symlink -> $STEVE_LIB/stevedore.sh"
    else
        fail "$STEVE_BIN is not a symlink to $STEVE_LIB/stevedore.sh (run: sudo steve install)"
    fi
    for f in "${STEVE_FILES[@]}"; do
        [[ -x "$STEVE_LIB/$f" ]] || missing+=( "$f" )
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "lib complete: ${#STEVE_FILES[@]} files in $STEVE_LIB"
    else
        fail "lib incomplete: missing/non-executable: ${missing[*]}"
    fi

    # config
    if [[ -f "$STEVE_ETC/fleet.conf" ]]; then
        if (bash -c "set -euo pipefail; source '$STEVE_HERE/stevedore-fleetparser.sh'; fleet_parse '$STEVE_ETC/fleet.conf'") >/dev/null 2>&1; then
            ok "fleet.conf parses"
        else
            fail "fleet.conf does not parse:"
            (bash -c "set -euo pipefail; source '$STEVE_HERE/stevedore-fleetparser.sh'; fleet_parse '$STEVE_ETC/fleet.conf'") 2>&1 | sed 's/^/check:      /' || true
        fi
    else
        warn "no $STEVE_ETC/fleet.conf (not an orchestrator box, or not configured yet)"
    fi
    if [[ -f "$STEVE_ETC/stevedore.conf" ]]; then
        if (bash -c "set -u; STEVEDORE_CONF='$STEVE_ETC/stevedore.conf' source '$STEVE_HERE/stevedore-cfgparser.sh'") >/dev/null 2>&1; then
            ok "stevedore.conf parses"
        else
            fail "stevedore.conf does not parse"
        fi
    fi

    # ledger
    if [[ -d "$STEVE_VAR" && -w "$STEVE_VAR" ]]; then
        ok "ledger dir writable: $STEVE_VAR ($(wc -l < "$STEVE_VAR/runs.jsonl" 2>/dev/null || echo 0) ledger lines)"
    else
        fail "$STEVE_VAR missing or not writable by $(id -un) (run: sudo steve install)"
    fi

    # dependencies (local; participants get preflighted per run)
    local deps="zfs socat pv openssl ssh" transport=""
    if [[ -f "$STEVE_ETC/fleet.conf" ]]; then
        transport=$(bash -c "source '$STEVE_HERE/stevedore-fleetparser.sh'; fleet_parse '$STEVE_ETC/fleet.conf' 2>/dev/null; echo \"\$fleet_opt_transport\"" 2>/dev/null) || transport=""
    fi
    [[ "$transport" == "haproxy" ]] && deps="$deps haproxy"
    local d dmiss=()
    for d in $deps; do
        command -v "$d" >/dev/null || dmiss+=( "$d" )
    done
    if [[ ${#dmiss[@]} -eq 0 ]]; then
        ok "dependencies present: $deps"
    else
        fail "missing dependencies: ${dmiss[*]}"
    fi

    # participant reachability (parallel, the cadence-probe pattern)
    if [[ -f "$STEVE_ETC/fleet.conf" ]]; then
        local hosts probe_pids=() probe_hosts=() h i unreach=()
        hosts=$(bash -c "source '$STEVE_HERE/stevedore-ec2helpers.sh' 2>/dev/null
                         source '$STEVE_HERE/stevedore-fleetparser.sh'
                         fleet_parse '$STEVE_ETC/fleet.conf' 2>/dev/null
                         for h in \"\${fleet_participants[@]}\"; do
                             printf '%s %s\n' \"\$h\" \"\$(fleet_ssh_dest \"\$h\")\"
                         done" 2>/dev/null) || hosts=""
        if [[ -n "$hosts" ]]; then
            source "$STEVE_HERE/stevedore-ec2helpers.sh"
            while read -r h dest; do
                [[ -n "$h" ]] || continue
                ssh "${ssh_opts[@]}" "$dest" true </dev/null >/dev/null 2>&1 &
                probe_pids+=( $! )
                probe_hosts+=( "$h" )
            done <<<"$hosts"
            for (( i = 0; i < ${#probe_pids[@]}; i++ )); do
                wait "${probe_pids[i]}" || unreach+=( "${probe_hosts[i]}" )
            done
            if [[ ${#unreach[@]} -eq 0 ]]; then
                ok "all ${#probe_hosts[@]} fleet participants reachable"
            else
                warn "unreachable participants (offline or EC2 asleep is normal): ${unreach[*]}"
            fi
        fi
    fi

    # leftovers from crashed runs
    local units
    units=$(systemctl list-units --no-legend --plain 'stevedore-run-*' 'stevedore-ha-*' 2>/dev/null | awk '{print $1}') || units=""
    if [[ -n "$units" ]]; then
        warn "leftover run units active (crashed run?): $(echo $units)"
    else
        ok "no leftover run units"
    fi
    if [[ -d "$STEVE_RUN" ]] && [[ -n "$(ls -A "$STEVE_RUN" 2>/dev/null)" ]]; then
        warn "leftover run bundles in $STEVE_RUN (crashed run?): $(ls -m "$STEVE_RUN")"
    else
        ok "no leftover run bundles"
    fi

    exit "$bad"
}

# The (4) systemd posture (§24): the timer is a SYSTEM unit with User=
# the operator -- on a one-operator estate the orchestrator's identity IS
# the operator, so the unit inherits ~/.ssh and ~/.aws and participants
# already trust it; no keys are copied anywhere. Units are named
# stevedore-fleet.* on purpose: stevedore-run-* is the per-run listener
# namespace and the doctor's leftover-unit glob must not match the timer.
do_timer() {
    local sub="${1:-status}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
    status)
        if systemctl is-enabled --quiet stevedore-fleet.timer 2>/dev/null; then
            systemctl list-timers stevedore-fleet.timer --no-pager 2>/dev/null || true
        else
            echo "stevedore-fleet.timer is not enabled (manual runs only)"
        fi
        ;;
    on)
        need_root "timer on"
        local cal="${1:-hourly}" u h dest err denied=()
        if command -v systemd-analyze >/dev/null \
            && ! systemd-analyze calendar "$cal" >/dev/null 2>&1; then
            echo "ERROR: '$cal' is not a valid systemd OnCalendar expression" >&2
            exit 64
        fi
        u=$(stat -c %U "$STEVE_VAR" 2>/dev/null) || u=""
        if [[ -z "$u" || "$u" == "root" ]]; then
            echo "ERROR: $STEVE_VAR missing or root-owned; run install via sudo as the operator first" >&2
            exit 1
        fi
        if [[ ! -f "$STEVE_ETC/fleet.conf" ]]; then
            echo "ERROR: $STEVE_ETC/fleet.conf required (the timer runs 'steve run')" >&2
            exit 78
        fi
        # Agent-less key preflight: under systemd there is no ssh-agent, so
        # $u's key must open every participant in BatchMode with the agent
        # stripped. "Permission denied" = passphrase-protected key or missing
        # authorized_keys -> refuse with the fix; merely unreachable (EC2
        # asleep, host down) skips the check, same doctrine as steve check.
        source "$STEVE_HERE/stevedore-ec2helpers.sh"
        source "$STEVE_HERE/stevedore-fleetparser.sh"
        fleet_parse "$STEVE_ETC/fleet.conf"
        for h in "${fleet_participants[@]}"; do
            dest=$(fleet_ssh_dest "$h")
            err=$(sudo -u "$u" env -u SSH_AUTH_SOCK ssh "${ssh_opts[@]}" "$dest" true </dev/null 2>&1) && continue
            if grep -qi "permission denied" <<<"$err"; then
                denied+=( "$h" )
            else
                echo "timer: [$h] unreachable during preflight (EC2 asleep is normal); key check skipped" >&2
            fi
        done
        if [[ ${#denied[@]} -gt 0 ]]; then
            echo "ERROR: agent-less ssh as '$u' was denied by: ${denied[*]}" >&2
            echo "Under systemd there is no ssh-agent, so the key must be passphrase-less." >&2
            echo "Either strip the passphrase, or mint a dedicated stevedore key and add" >&2
            echo "it to those participants' authorized_keys (from= restriction optional)." >&2
            exit 1
        fi
        cat > /etc/systemd/system/stevedore-fleet.service <<EOF
[Unit]
Description=stevedore fleet run
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$u
ExecStart=$STEVE_BIN run
TimeoutStartSec=infinity
# 75 = estate lock busy: a manual run is in progress and this tick
# politely yields -- that is scheduling, not failure
SuccessExitStatus=75
EOF
        cat > /etc/systemd/system/stevedore-fleet.timer <<EOF
[Unit]
Description=stevedore fleet run schedule

[Timer]
OnCalendar=$cal
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now stevedore-fleet.timer
        echo "timer on: OnCalendar=$cal, runs as $u (logs: journalctl -u stevedore-fleet.service)" >&2
        ;;
    off)
        need_root "timer off"
        systemctl disable --now stevedore-fleet.timer 2>/dev/null || true
        rm -f /etc/systemd/system/stevedore-fleet.timer /etc/systemd/system/stevedore-fleet.service
        systemctl daemon-reload
        systemctl reset-failed stevedore-fleet.service 2>/dev/null || true
        echo "timer off; units removed (manual 'steve run' unaffected)" >&2
        ;;
    *) usage ;;
    esac
}

do_help() {
    cat <<EOF
steve -- fleet ZFS replication (stevedore)

  steve run                   one fleet run from $STEVE_ETC/fleet.conf
  steve run --check           plan preview: jobs, skips, nothing provisioned
  steve run --force-ec2       override every cadence window for this run
  steve run --skip-ec2        drop all ec2= destinations (instance maintenance)
  steve jobs                  full-screen editor for the fleet.conf job
                              matrix: (source, tree) rows x receiver
                              columns, space toggles a job
  steve report [-n N]         last run + N-run trend + gc findings
  steve report --gc-debug     + the full GC track inventory (every clocked
                              dataset/snapshot with its eligible-in countdown)
  steve check                 doctor: install, config, deps, reachability,
                              crashed-run leftovers
  steve timer on [calendar]   scheduled runs as a system unit (default
                              hourly; any OnCalendar expression). Runs as
                              the ledger owner; preflights agent-less ssh.
  steve timer off | status    remove the schedule / show the next fire
  steve unlock <replica>      load a received replica's keys from its own
                              keystore (read-only; LUKS or plain)
  steve install / uninstall   [--purge] also removes config + ledger

Knobs (env, on the steve run command line):
  STEVEDORE_SHOW_PRUNES=1      name every snapshot destroyed by the run
  STEVEDORE_GC_WARN_DAYS= / STEVEDORE_GC_GRACE_DAYS=
                              GC thresholds, forwarded to receivers
                              (warn-only build: 0 is safe, nothing destroys)

Internals live in $STEVE_LIB (debug invocation = full path).
Ledger: $STEVE_VAR/runs.jsonl.
EOF
}

cmd="${1:-}"
[[ -n "$cmd" ]] && shift || usage
case "$cmd" in
    install)   do_install ;;
    uninstall) do_uninstall "$@" ;;
    run)       exec "$STEVE_HERE/stevedore-fleetrun.sh" "$@" ;;
    jobs)      exec "$STEVE_HERE/stevedore-jobs.sh" "$@" ;;
    report)    exec "$STEVE_HERE/stevedore-report.sh" "$@" ;;
    unlock)    exec "$STEVE_HERE/stevedore-unlock-replica.sh" "$@" ;;
    timer)     do_timer "$@" ;;
    check)     do_check ;;
    help|-h|--help) do_help ;;
    *)         usage ;;
esac
