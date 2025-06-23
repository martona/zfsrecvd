#!/usr/bin/env bash
# Usage:   send.sh <local_snapshot> <remote_host>
#
# Example: send.sh tank/outer/inner/actual@snap2025-06-18   backup‑box
#
# Send a single ZFS snapshot to a remote host. Non-recursive.
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
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <snapshot> <remote_host>  [sentinel_tmpfile]" >&2
    exit 1
fi

full_snap="$1"           # tank/ds@snap
remote="$2"              # DNS name or IP of zfsrecvd listener
sentinel_file="${3:-}"   # /tmp/send-resume-status.xxxxxx  (optional)

exit_script() {
    local exit_code="$1"
    exec {OUT}>&-      || true    # close our duplicate
    exec {NET[1]}>&-   || true    # close the original write FD from coproc
    wait "${NET_PID}"  || true
    exit "$exit_code"
}

finalize_and_exit() {
    local exit_code="$1"
    # Read the response from the server. (It ends with an empty line.)
    # We don't actually care what's in there - just making sure we don't
    # close the FDs prematurely and prevent proper log output on the other side.
    while true; do
        if IFS= read -r -u "${IN}" line; then
            if [[ -z $line ]]; then          # blank line => list finished
                break
            fi
        else
            rc=$?
            echo "ERROR: lost connection while confirming completion."
            exit_script $rc
        fi
    done
    exit_script "$exit_code"
}

mark_resume_ok() {
    [[ -n $sentinel_file ]] || return 0
    printf 'RESUME_OK\n' >| "$sentinel_file" 2>/dev/null || true
}

#
# ---------- 1.  allow dataset‑only argument ---------------------------------
#
if [[ "$full_snap" != *@* ]]; then
    # Caller gave only a dataset; pick its most recent snapshot.
    latest=$( zfs list -H -o name -t snapshot -s creation -d 1 "$full_snap" | tail -n 1 )
    if [[ -z "$latest" ]]; then
        echo "ERROR: dataset '$full_snap' has no snapshots" >&2
        exit 1
    fi
    full_snap="$latest"
    echo "Newest local snapshot: $full_snap" >&2
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
printf 'zfsrecvd1.1\n%s\n\n' "${full_snap}" >&${OUT}

#
# ---------- 4.  receive remote snapshot list --------------------------------
#
remote_snaps=()
resume_token=""
already_there=false
while true; do
    if IFS= read -r -u "${IN}" line; then
        if [[ -z $line ]]; then                  # blank line => list finished
            break
        fi
        if [[ "$line" == "TOKEN: "* ]]; then
            resume_token="${line#TOKEN: }"      # store for later use
            continue
        fi
        if [[ "$line" == SNAPSHOT:* ]]; then
            line="${line#SNAPSHOT: }"           # strip prefix
            if [[ "$line" == */"$full_snap" ]]; then
                already_there=true
            else
                remote_snaps+=( "${line#*@}" )
            fi
        fi
    else
        rc=$?
        echo "ERROR: lost connection while receiving snapshot list (read rc=$rc)" >&2
        exit_script "$rc"
    fi
done

#
# ---------- 5.  handle resumes before anything else --------------------------
#
if [[ -n "$resume_token" ]]; then
    dataset_part="${resume_token%%=*}"   # "tank/ds@snap"
    token_part="${resume_token#*=}"      # "1-136b462817-110-789..."
    token_part="${token_part//[^a-zA-Z0-9-]/}"   
    echo "Resuming from token." >&2
    size=$( zfs send -nP -t "$token_part" | awk '/^size/{print $2;exit}' )
    if zfs send -t $token_part | pv "$PV_FORCE_FLAG" ${size:+-s "$size"} >&${OUT}; then
        echo "Resume successful." >&2
        mark_resume_ok 
        finalize_and_exit 0
    else
        rc=$?
        echo "ERROR: resume failed with rc=$rc" >&2
        exit_script $rc
    fi
fi

#
# ---------- 6.  Nothing to do if destination dataset is already in place -----
#
if $already_there; then
    echo "Snapshot already up to date on destination." >&2
    exit_script 0
fi

#
# ---------- 7.  build list of local snaps older than target ------------------
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
# ---------- 8.  find newest common ancestor ---------------------------------
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
# ---------- 9.  decide raw mode ----------------------------------------------
#

# Find the encryption status of the dataset that this one derives its 
# encryption from. If the dataset is encrypted, we need to send it raw.

enc_root=$(zfs get -H -o value encryptionroot "$dataset")
SEND_RAW=""
if [[ "$enc_root" != "-" ]]; then               # "-" means dataset not encrypted
    enc_prop=$(zfs get -H -o value encryption "$enc_root")
    [[ "$enc_prop" != "off" ]] && SEND_RAW="-w"  # if encrypted, send raw
fi

#
# ---------- 9.  ship the stream ---------------------------------------------
#
if [[ -n "$common" ]]; then
    echo "Sending incremental from [${dataset}@${common}] to [${full_snap}]" >&2
    # determine size of the incremental send
    size=$( zfs send -nP $SEND_RAW -i "${dataset}@${common}" "${full_snap}" | awk '/^size/{print $2;exit}' )
    # Incremental: -w (raw), -i FROM@ TO@
    zfs send $SEND_RAW -i "${dataset}@${common}" "${full_snap}" | pv "${PV_FORCE_FLAG}" ${size:+-s "$size"} >&${OUT}
else
    echo "No common snapshot; full send: [${full_snap}]" >&2
    # determine size
    size=$( zfs send -nP $SEND_RAW "${full_snap}" 2>&1 | awk '/^size/{print $2;exit}' )
    zfs send $SEND_RAW "${full_snap}" | pv "${PV_FORCE_FLAG}" ${size:+-s "$size"} >&${OUT}
fi
echo "Send successful." >&2

finalize_and_exit 0
