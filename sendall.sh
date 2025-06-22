#!/usr/bin/env bash
# Take snapshots and send them to remote hosts.
# Operate on all datasets/hosts in the [sends] section of the configuration file.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

prev_ds=""
snap="manual-$(date -u +%Y-%m-%d-%H%MZ)"

succs=()
fails=()
for entry in "${sends[@]}"; do
    # split on any whitespace -> dataset + host
    read -r dataset host _ <<<"$entry"          # ignore extra columns

    # sanity‑skip malformed lines
    [[ -z "$dataset" || -z "$host" ]] && continue

    if [[ "$dataset" != "$prev_ds" ]]; then
        echo "Taking snapshot: [$dataset@${snap}]" >&2
        zfs snapshot -r "${dataset}@${snap}"
        prev_ds="$dataset"
    fi

    # Perform the send.
    /etc/zfsrecvd/sendtree.sh "$dataset" "$host"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        succs+=( "$dataset@$snap -> $host" )
    else
        fails+=( "$dataset@$snap -> $host (rc=$rc)" )
    fi
done

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Successfully sent snapshots:"
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#fails[@]} -gt 0 ]]; then
    echo "Failed sends:"
    printf '  %s\n' "${fails[@]}" >&2
fi
