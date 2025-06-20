#!/usr/bin/env bash
# Take snapshots and send them to remote hosts.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

prev_ds=""
snap="manual-$(date -u +%Y-%m-%d-%H%MZ)"

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

    echo "Sending [$dataset] to [$host]" >&2
    /etc/zfsrecvd/send.sh "$dataset" "$host"
done
