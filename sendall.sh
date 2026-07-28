#!/usr/bin/env bash
# Take snapshots and send them to remote hosts.
# Operate on all datasets/hosts in the [sends] section of the configuration file.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.
#
# Exit: 0 all sends ok, 2 some sends failed, 75 another run is in progress.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/run_indented.sh

# One send run per host at a time; overlapping runs would interleave sends
# and fight over resume tokens.
exec {lock_fd}>/run/lock/zfsrecvd-sendall.lock
if ! flock -n "$lock_fd"; then
    echo "ERROR: another sendall run is already in progress on this host." >&2
    exit 75
fi

# Freeze the output width once per run: pv bars sized now stay stable no
# matter how the terminal is resized mid-run. Under orchestrate the pty is
# already pinned (and this just reads that pinned width); on a direct
# interactive run it captures the real terminal once.
if [[ -t 2 && -z "${ZFSRECVD_COLS:-}" ]]; then
    export ZFSRECVD_COLS="$(tput cols 2>/dev/null || echo 120)"
fi

snap="zfsrecvd-$(date -u +%Y-%m-%d-%H%MZ)"

declare -A snapped=()          # dataset -> ok|failed; snapshot taken once per run
declare -A unreachable=()      # host -> 1; skip further entries for dead hosts
succs=()
fails=()
for entry in "${sends[@]}"; do
    # split on any whitespace -> dataset + host
    read -r dataset host _ <<<"$entry"          # ignore extra columns

    # sanity‑skip malformed lines
    [[ -z "$dataset" || -z "$host" ]] && continue

    if [[ -n "${unreachable[$host]:-}" ]]; then
        echo "Skipping [$dataset -> $host]: host was unreachable earlier in this run" >&2
        fails+=( "$dataset@$snap -> $host (skipped, unreachable)" )
        continue
    fi

    if [[ -z "${snapped[$dataset]:-}" ]]; then
        echo "Taking snapshot: [$dataset@${snap}]" >&2
        if zfs snapshot -r "${dataset}@${snap}"; then
            snapped[$dataset]="ok"
        else
            snapped[$dataset]="failed"
        fi
    fi
    if [[ "${snapped[$dataset]}" != "ok" ]]; then
        fails+=( "$dataset@$snap -> $host (snapshot failed)" )
        continue
    fi

    # Perform the send. This is the only prefixing layer: the prefix names
    # both ends, so nothing else needs to tag the stream again upstream.
    set +e
    run_indented "[${HOSTNAME}]>[${host}] " /etc/zfsrecvd/sendtree.sh "$dataset" "$host"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        succs+=( "$dataset@$snap -> $host" )
    else
        if [[ $rc -eq 3 ]]; then
            unreachable[$host]=1
        fi
        fails+=( "$dataset@$snap -> $host (rc=$rc)" )
    fi
done

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Successfully sent snapshots:" >&2
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#fails[@]} -gt 0 ]]; then
    echo "Failed sends:" >&2
    printf '  %s\n' "${fails[@]}" >&2
    exit 2
fi
