#!/usr/bin/env bash
# Usage:   sendtree.sh <local_snapshot> <remote_host>
#
# Example: sendtree.sh tank/outer/inner/actual@snap2025-06-18   backup‑box
#
# Sends a zfs dataset's snapshot, and snapshots of all its children, to a remote host.
#
# Requires:
#   * /etc/zfsrecvd/{client.pem,client.key,ca.pem}
#   * socat with OpenSSL support
#   * ZFS 0.8+ (for raw send)

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

#
# ---------- 0.  arguments ----------------------------------------------------
#
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <snapshot> <remote_host>" >&2
    exit 64
fi

full_snap="$1"           # tank/ds@snap
remote="$2"              # DNS name or IP of zfsrecvd listener

dataset=""
snapname=""
if [[ "$full_snap" == *@* ]]; then
    dataset="${full_snap%@*}"     # tank/ds
    snapname="@${full_snap#*@}"    # snap
else
    dataset="$full_snap"          # tank/ds
fi

#
# ---------- 1.  walk list, send each entry -----------------------------------
#
while read -r ds; do
    retry=0
    max_retries=5
    while [[ $retry -lt $max_retries ]]; do
        echo "Sending [$ds$snapname] to [$remote]" >&2
        if [[ $retry -gt 0 ]]; then
            sleep 5
            echo "    Retrying [$ds$snapname] to [$remote] (attempt $((retry + 1)))" >&2
        fi
        if /etc/zfsrecvd/send.sh "$ds$snapname" "$remote"; then
            break
        fi
        ((retry++))
    done
done < <(zfs list -r -H -o name -t filesystem,volume "$dataset")
