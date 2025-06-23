#!/usr/bin/env bash
# SSH into destinations and execute sends.sh.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/run_indented.sh

succs=()
fails=()
for entry in "${orchestrator[@]}"; do
    # split on any whitespace -> dataset + host
    read -r host user _ <<<"$entry"          # ignore extra columns

    # sanity‑skip malformed lines
    [[ -z "$host" || -z "$user" ]] && continue

    echo "Connecting to [$user@$host] to execute sendall.sh" >&2
    set +e
    run_indented "  [sendall] " ssh -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" sudo /etc/zfsrecvd/sendall.sh
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        succs+=("$host")
    else
        fails+=("$host (rc=$rc)")
        echo "ERROR: SSH connection to [$user@$host] failed" >&2
    fi    
done

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Successfully processed:"
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#fails[@]} -gt 0 ]]; then
    echo "Failed hosts:"
    printf '  %s\n' "${fails[@]}" >&2
fi
