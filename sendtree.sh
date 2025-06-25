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
source /etc/zfsrecvd/run_indented.sh
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

sentinel=$(mktemp)
: >"${sentinel}"

#
# ---------- 1.  walk list, send each entry -----------------------------------
#
while read -r ds; do
    retry=0
    max_retries=5
    rc=0
    while [[ $retry -lt $max_retries ]]; do
        ((++retry))
        #echo "Sending [$ds$snapname] to [$remote]" >&2
        if [[ $retry -gt 1 ]]; then
            sleep 5
            echo "    Retrying [$ds$snapname] to [$remote] (attempt $retry/$max_retries)" >&2
        fi
        set +e
        run_indented "[send] " /etc/zfsrecvd/send.sh "$ds$snapname" "$remote" "$sentinel"
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            if [[ $(head -n1 "$sentinel") == "RESUME_OK" ]]; then
                # we just resumed a previous fail; we should retry the current operation
                # to make sure the dataset is where it needs to be. the resume token
                # could have been from a while ago.
                : >"${sentinel}"
                continue
            fi
            break
        fi
    done
    if [[ $rc -ne 0 ]]; then
        echo "ERROR: Failed to send [$ds$snapname] to [$remote] (rc=$rc)" >&2
        echo "Check the logs on the remote host for more details." >&2
        exit $rc
    fi
done < <(zfs list -r -H -o name -t filesystem,volume "$dataset")

#
# ---------- 2.  cleanup ------------------------------------------------------
#

rm -f -- "$sentinel"