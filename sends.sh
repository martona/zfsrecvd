#!/usr/bin/env bash
# Take snapshots and send them to remote hosts.
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

    we give the whole send business a few tries. 
    keepgoing=0
    send_succ=false
    while [[ $keepgoing -lt 5 ]]; do
        if [[ $keepgoing -gt 0 ]]; then
            sleep 5
            echo "Retrying [$dataset] to [$host] (attempt $((keepgoing + 1)))" >&2
        fi
        # Perform the send. Internally this might turn into a resume.
        echo "Sending [$dataset] to [$host]" >&2
        /etc/zfsrecvd/send.sh "$dataset" "$host"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "Send successful: [$dataset] to [$host]" >&2
            send_succ=true
            break
        else
            if [[ $rc -eq $MAGIC_RESUME_SUCCESS_RC ]]; then
                # This is a special return code that indicates a previous send was resumed.
                # We don't know if the resume token was left in place during this run
                # or previously. If the latter, we need to try again so the actual send
                # we've tried to do in the first place is actually done.
                echo "Resume successful: [$dataset] to [$host]" >&2
            else
                echo "Send failed: [$dataset] to [$host] (rc=$rc)" >&2
            fi
        fi
        ((keepgoing++))
    done
    if $send_succ; then
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
