#!/usr/bin/env bash
# Usage:   send.sh <local_snapshot> <remote_host>
#
# Example: send.sh tank/outer/inner/actual@snap2025-06-18   backup‑box
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

#
# ---------- 1.  allow dataset‑only argument ---------------------------------
#
if [[ "$full_snap" != *@* ]]; then
    # Caller gave only a dataset; pick its most recent snapshot.
    latest=$( zfs list -H -o name -t snapshot -s creation -d 1 "$full_snap" | tail -n 1 )
    if [[ -z "$latest" ]]; then
        echo "ERROR: dataset '$full_snap' has no snapshots" >&2
        exit 65
    fi
    echo "Autodetected newest snapshot: $latest" >&2
    full_snap="$latest"
fi

dataset="${full_snap%@*}"     # tank/ds
snapname="${full_snap#*@}"    # snap

#
# ---------- 2.  open bidirectional TLS pipe ---------------------------------
#
coproc NET {
exec socat \
STDIO \
OPENSSL:"${remote}":"$tcp_port",\
cert=/etc/zfsrecvd/client.pem,\
key=/etc/zfsrecvd/client.key,\
cafile=/etc/zfsrecvd/ca.pem,\
verify=1 \
2> >(grep -v "OpenSSL: Warning: this implementation does not check CRLs" >&2)
}

exec {OUT}>&"${NET[1]}"   # write‑end to server
exec  {IN}<&"${NET[0]}"   # read‑end from server

#
# ---------- 3.  send header --------------------------------------------------
#
printf 'zfsrecvd1.0\n%s\n' "${full_snap}" >&${OUT}

#
# ---------- 4.  receive remote snapshot list --------------------------------
#
remote_snaps=()
while true; do
    if IFS= read -r -u "${IN}" line; then
        if [[ -z $line ]]; then          # blank line => list finished
            break
        fi
        remote_snaps+=( "${line#*@}" )
    else
        rc=$?                             # non‑zero status (1 = EOF, >1 = error)
        echo "ERROR: lost connection while pulling snapshot list (read rc=$rc)" >&2
        wait "${NET_PID}"                 # reap socat
        exit $rc                          # propagate error
    fi
done

#
# ---------- 4b.  short‑circuit if snapshot already present -------------------
#
for rs in "${remote_snaps[@]}"; do
    if [[ "$rs" == */"$full_snap" ]]; then
        echo "Snapshot [$full_snap] is already on [${remote}]; nothing to do." >&2
        # close our side of the pipe cleanly so the server isn’t left hanging
        exec {OUT}>&-
        exec {NET[1]}>&-
        wait "${NET_PID}"
        exit 0
    fi
done

#
# ---------- 5.  build list of local snaps older than target ------------------
#
mapfile -t local_all < <(
    zfs list -H -o name -t snapshot -s creation "${dataset}"
)

local_prior=()
for s in "${local_all[@]}"; do
    [[ "$s" == "$full_snap" ]] && break  # stop once we hit the target snap
    local_prior+=( "${s#*@}" )           # store names, not full paths
done

#
# ---------- 6.  find newest common ancestor ---------------------------------
#
common=""
for (( idx=${#local_prior[@]}-1; idx>=0; idx-- )); do
    cand="${local_prior[idx]}"
    if printf '%s\n' "${remote_snaps[@]}" | grep -Fxq -- "$cand"; then
        common="$cand"
        break
    fi
done

#
# ---------- 7.  ship the stream ---------------------------------------------
#
if [[ -n "$common" ]]; then
    echo "Sending incremental from $common to $snapname" >&2
    # determine size of the incremental send
    size=$( zfs send -nP -Rwi "${dataset}@${common}" "${full_snap}" | awk '/^size/{print $2;exit}' )
    # Incremental: -R (replicate), -w (raw), -i FROM@ TO@
    zfs send -Rwi "${dataset}@${common}" "${full_snap}" | pv ${size:+-s "$size"} >&${OUT}
else
    echo "No common snapshot; full send" >&2
    # determine size
    size=$( zfs send -nP -Rw "${full_snap}" 2>&1 | awk '/^size/{print $2;exit}' )
    zfs send -Rw "${full_snap}" | pv ${size:+-s "$size"} >&${OUT}
fi
echo "Send successful." >&2

# read the response from the server. (ends with an empty line)
# we don't actually care what's in there - just making sure we don't
# close the FDs prematurely and prevent proper log output on the other side.

while true; do
    if IFS= read -r -u "${IN}" line; then
        if [[ -z $line ]]; then          # blank line => list finished
            break
        fi
    else
        rc=$?                             # non‑zero status (1 = EOF, >1 = error)
        echo "ERROR: lost connection while confirming completion"
        wait "${NET_PID}"                 # reap socat
        exit $rc                          # propagate error
    fi
done

#
# ---------- 8.  tidy up ------------------------------------------------------
#
exec {OUT}>&-          # close our duplicate
exec {NET[1]}>&-       # close the original write FD from coproc
wait "${NET_PID}"
