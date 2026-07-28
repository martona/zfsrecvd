#!/usr/bin/env bash
# zfsrecvd protocol 2.0 sender: replicates a dataset tree over one TLS
# session. See PROTOCOL.md for the wire contract.
#
# Usage: sendtree.sh [--single] <dataset[@snap]> <remote_host>
#   --single: send only the named dataset, not its descendants (send.sh
#             execs into this for manual one-dataset runs).
#   Without @snap, the newest snapshot of the root dataset is the target;
#   descendants lacking that snapshot are skipped with a warning.
#
# Shape of a run: gather local tree state (3 zfs invocations), connect,
# announce the tree, receive the server's HAVE/TOKEN state, then walk the
# datasets deciding per dataset: nothing (already on the receiver), resume,
# abort-then-send, incremental, bootstrap two-step, or full send. Streams
# share the one connection with stop-and-wait discipline: after a stream
# we write nothing until the server's result line arrives. If the session
# dies we reconnect and replan; finished work shows up as up-to-date and
# costs nothing the second time.
#
# Requires: /etc/zfsrecvd/{client.pem,client.key,ca.pem}, socat, pv.
#
# Exit: 0 all datasets ok (skips are warnings),
#       2 some datasets failed,
#       3 no session could ever be established.

set -euo pipefail
set -f                       # never glob; plenty of protocol word-splitting
source /etc/zfsrecvd/cfgparser.sh

# When we run under run_indented (see sendall.sh), every line we emit grows
# by ZFSRECVD_INDENT columns of prefix before reaching the terminal. pv sizes
# its progress line to the terminal width (or assumes 80 when it can't tell),
# so an unshrunk line wraps once prefixed, and every \r-refresh then lands on
# a fresh row instead of overwriting in place. Shrink pv to compensate.
PV_WIDTH_FLAG=""
if [[ "${ZFSRECVD_INDENT:-0}" -gt 0 ]]; then
    # 2>/dev/null must come FIRST: redirections apply left to right, and a
    # failed /dev/tty open reports to whatever stderr is at that moment
    cols=$(stty size 2>/dev/null </dev/tty | awk '{print $2}') || true
    if [[ -n "${cols:-}" && "$cols" -gt $(( ${ZFSRECVD_INDENT:-0} + 20 )) ]]; then
        PV_WIDTH_FLAG="-w $(( cols - ${ZFSRECVD_INDENT:-0} - 1 ))"
    fi
fi

#
# ---------- 0.  arguments ----------------------------------------------------
#
single=""                    # nonempty: one dataset only, no descendants
if [[ "${1:-}" == "--single" ]]; then
    single=1
    shift
fi
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [--single] <dataset[@snap]> <remote_host>" >&2
    exit 64
fi
arg="$1"
remote="$2"          # extra legacy arguments (old sentinel file) are ignored

# Split dataset from target snapshot; with no @snap, the newest snapshot of
# the root names the run (sendall just created it, so newest is the run's).
root="" target=""
if [[ "$arg" == *@* ]]; then
    root="${arg%@*}"
    target="${arg#*@}"
else
    root="$arg"
    target=$(zfs list -H -o name -t snapshot -s creation -d 1 "$root" | tail -n 1) || true
    target="${target#*@}"
    if [[ -z "$target" ]]; then
        echo "ERROR: dataset '$root' has no snapshots" >&2
        exit 2
    fi
fi

# Under run_indented the line prefix already names both ends; on a bare
# manual run there is no prefix, so announce lines append the destination.
dest_tag=""
if [[ "${ZFSRECVD_INDENT:-0}" -eq 0 ]]; then
    dest_tag=" -> [${remote}]"
fi

#
# ---------- 1.  gather local state (3 zfs invocations) -----------------------
#
datasets=()                          # tree in zfs list -r order (parents first)
declare -A dstype                    # dataset -> filesystem|volume
declare -A lsnaps                    # dataset -> local snaps, comma-joined, oldest first
declare -A encroot encon             # encryptionroot / encryption per dataset

while IFS=$'\t' read -r name typ; do
    datasets+=( "$name" )
    dstype[$name]="$typ"
done < <(
    if [[ -n "$single" ]]; then
        zfs list -H -t filesystem,volume -o name,type "$root"
    else
        zfs list -H -r -t filesystem,volume -o name,type "$root"
    fi
)
if [[ ${#datasets[@]} -eq 0 ]]; then
    echo "ERROR: no such dataset: $root" >&2
    exit 2
fi

while IFS= read -r s; do
    ds="${s%@*}"
    sn="${s#*@}"
    lsnaps[$ds]="${lsnaps[$ds]:-}${lsnaps[$ds]:+,}$sn"
done < <(
    if [[ -n "$single" ]]; then
        zfs list -H -t snapshot -s creation -d 1 -o name "$root"
    else
        zfs list -H -r -t snapshot -s creation -o name "$root"
    fi
)

while IFS=$'\t' read -r name prop val; do
    case "$prop" in
        encryptionroot) encroot[$name]="$val" ;;
        encryption)     encon[$name]="$val" ;;
    esac
done < <(zfs get -H -r -t filesystem,volume -o name,property,value encryptionroot,encryption "$root")

# Send-mode flags for one dataset: "-w" (raw) if its encryption root is
# encrypted; else "-R" for plain volumes, working around the OpenZFS
# 13033-adjacent unencrypted-zvol-into-encrypted-parent receive bug; else
# nothing. An encryption root outside the tree is looked up once and cached.
send_flags_for() {
    local ds="$1" er e
    er="${encroot[$ds]:--}"
    if [[ "$er" != "-" ]]; then
        e="${encon[$er]:-}"
        if [[ -z "$e" ]]; then
            e=$(zfs get -H -o value encryption "$er" 2>/dev/null) || e="off"
            encon[$er]="$e"
        fi
        if [[ "$e" != "off" ]]; then
            echo "-w"
            return 0
        fi
    fi
    if [[ "${dstype[$ds]}" == "volume" ]]; then
        echo "-R"
        return 0
    fi
    echo ""
}

# Dry-run size of a send (bytes), for pv -s and the SEND line; "-" when the
# estimate can't be had. 2>&1 because some send variants print the size
# line to stderr.
estimate() {
    local sz
    sz=$(zfs send -nP "$@" 2>&1 | awk '/^size/{print $2; exit}') || sz=""
    echo "${sz:--}"
}

#
# ---------- 2.  session plumbing ---------------------------------------------
#
IN="" OUT=""                 # fds of the read/write ends of the TLS coproc

# Tear down the coproc and its fds; safe to call twice (and called once
# more via the EXIT trap). No stray redirections on these execs: an exec
# redirection is permanent, so a careless "2>/dev/null" here would silence
# the rest of the script.
close_session() {
    if [[ -n "${OUT:-}" ]]; then
        exec {OUT}>&- || true
        OUT=""
    fi
    if [[ -n "${IN:-}" ]]; then
        exec {IN}<&- || true
        IN=""
    fi
    if [[ -n "${NET_PID:-}" ]]; then
        kill "$NET_PID" 2>/dev/null || true
        wait "$NET_PID" 2>/dev/null || true
    fi
}
trap close_session EXIT

# Open the TLS connection (socat coproc), send our version, and require the
# server's greeting. Nonzero means "no usable session" -- the caller
# decides whether to retry.
connect_session() {
    local ssl_opts="connect-timeout=10"
    ssl_opts+=",so-keepalive"
    ssl_opts+=",nodelay"
    ssl_opts+=",cert=/etc/zfsrecvd/client.pem"
    ssl_opts+=",key=/etc/zfsrecvd/client.key"
    ssl_opts+=",cafile=/etc/zfsrecvd/ca.pem"
    ssl_opts+=",verify=1"
    coproc NET {
        exec socat -b 262144 \
            STDIO \
            "OPENSSL:${remote}:${tcp_port},${ssl_opts}" \
            2> >(grep -v "OpenSSL: Warning: this implementation does not check CRLs" >&2)
    }
    exec {OUT}>&"${NET[1]}"
    exec {IN}<&"${NET[0]}"
    printf 'zfsrecvd2.0\n' >&"$OUT" 2>/dev/null || { close_session; return 1; }
    local g
    IFS= read -r -t 15 -u "$IN" g || { close_session; return 1; }
    if [[ "$g" != "OK zfsrecvd2.0" ]]; then
        echo "ERROR: unexpected greeting from [$remote]: $g" >&2
        close_session
        return 1
    fi
    echo "connected to [$remote] (zfsrecvd2.0)" >&2
    return 0
}

# Announce the tree (manifest of our datasets) and parse the server's
# state dump into have[]/token[]. Nonzero on any hiccup -- the caller
# treats that as a dead session.
declare -A have              # dataset -> receiver's snaps, comma-joined, oldest first
declare -A token             # dataset -> receiver's pending resume token
send_tree_block() {
    {
        printf 'TREE %s %s\n' "$root" "$target"
        local d
        for d in "${datasets[@]}"; do
            printf 'DS %s\n' "$d"
        done
        printf '\n'
    } >&"$OUT" 2>/dev/null || return 1
    local line ended="" hds hsnl tds ttk
    IFS= read -r -t 120 -u "$IN" line || return 1
    [[ "$line" == "OK TREE" ]] || return 1
    have=()
    token=()
    while IFS= read -r -t 120 -u "$IN" line; do
        if [[ -z "$line" ]]; then
            ended=1
            break
        fi
        case "$line" in
            HAVE\ *)  read -r _ hds hsnl <<<"$line"; have[$hds]="$hsnl" ;;
            TOKEN\ *) read -r _ tds ttk  <<<"$line"; token[$tds]="$ttk" ;;
            *) return 1 ;;
        esac
    done
    [[ -n "$ended" ]]
}

#
# ---------- 3.  transfer primitive -------------------------------------------
#
# xfer <announce> <est> <cmdline> <zfs send args...>
# One command/stream/result exchange. Returns 0 = ok, 1 = server refused
# (permanent for this dataset, session healthy), 2 = session dead (any
# post-GO error: an unframed stream can't be resynchronized, so both sides
# abandon the connection and we rely on reconnect + resume tokens).
sent_n=0                     # successful transfers this run (for the summary)
xfer() {
    local announce="$1" est="$2" cmdline="$3"
    shift 3
    echo "$announce" >&2
    printf '%s\n' "$cmdline" >&"$OUT" 2>/dev/null || return 2
    local reply
    IFS= read -r -t 120 -u "$IN" reply || return 2
    if [[ "$reply" == ERR\ refused\ * ]]; then
        echo "ERROR: receiver refused: ${reply#ERR refused }" >&2
        return 1
    fi
    [[ "$reply" == "GO" ]] || return 2
    # pv only gets -s when the estimate is a real number ("-" would be
    # taken as a filename).
    local est_pv=""
    if [[ "$est" =~ ^[0-9]+$ ]]; then
        est_pv="$est"
    fi
    # ZFSRECVD_PV_EXTRA: optional extra pv flags from the environment, e.g.
    # ZFSRECVD_PV_EXTRA="-L 50M" to cap bandwidth for a manual run.
    local rc pvrc ps=()
    set +e
    zfs send "$@" | pv $PV_FORCE_FLAG $PV_WIDTH_FLAG ${ZFSRECVD_PV_EXTRA:-} ${est_pv:+-s "$est_pv"} >&"$OUT"
    ps=( "${PIPESTATUS[@]}" )   # copy in one statement; any command resets it
    set -e
    rc=${ps[0]}
    pvrc=${ps[1]:-1}
    if [[ $rc -ne 0 || $pvrc -ne 0 ]]; then
        echo "ERROR: local send failed for [$cmdline] (zfs=$rc pv=$pvrc)" >&2
        return 2
    fi
    # Stop-and-wait: nothing is written after the stream until this result
    # line arrives -- that guarantee is what lets zfs recv read the socket
    # directly with no framing layer.
    IFS= read -r -t 600 -u "$IN" reply || return 2
    case "$reply" in
        OK\ *)
            sent_n=$(( sent_n + 1 ))
            return 0 ;;
        ERR\ *)
            echo "ERROR: receiver: ${reply#ERR }" >&2
            return 2 ;;   # post-stream errors are session-fatal (PROTOCOL.md §7)
        *)
            return 2 ;;
    esac
}

#
# ---------- 4.  per-dataset planner ------------------------------------------
#
# Decide and perform what one dataset needs, possibly several transfers
# (resume then top-up; bootstrap then top-up). Returns 0 = done (sent, up
# to date, or warn-skipped), 1 = failed permanently, 2 = session dead.
utd_n=0                      # datasets already up to date (zero wire cost)
skip_n=0                     # datasets skipped for missing the target snap
plan_one() {
    local ds="$1" rc est flags common reply
    if ! [[ ",${lsnaps[$ds]:-}," == *",$target,"* ]]; then
        echo "WARNING: [$ds] has no @$target locally; skipped" >&2
        skip_n=$(( skip_n + 1 ))
        return 0
    fi

    flags=$(send_flags_for "$ds")

    # Pending resume token? Handle it even when the dataset is otherwise up
    # to date: a lingering token blocks all future receives on the dataset.
    if [[ -n "${token[$ds]:-}" ]]; then
        local tk="${token[$ds]}" tinfo toname rsn
        if tinfo=$(zfs send -nP -t "$tk" 2>&1); then
            # Token is satisfiable here: resume the interrupted stream, then
            # fall through and re-plan -- the token may predate newer snaps.
            est=$(awk '/^size/{print $2; exit}' <<<"$tinfo")
            xfer "${ds} (resume)${dest_tag}" "${est:--}" "RESUME $ds ${est:--}" -t "$tk"
            rc=$?
            [[ $rc -ne 0 ]] && return $rc
            unset "token[$ds]"
            # The dry-run's toname tells us which snapshot the resume
            # completed; credit it to the receiver's state.
            toname=$(awk '$1 == "toname" {print $3; exit}' <<<"$tinfo")
            rsn="${toname#*@}"
            if [[ -z "$rsn" ]]; then
                # cannot tell where the resume landed; replan next session
                return 2
            fi
            have[$ds]="${have[$ds]:-}${have[$ds]:+,}$rsn"
            if [[ "$rsn" == "$target" ]]; then
                return 0
            fi
        else
            # We no longer have what the token needs (snapshot pruned);
            # have the receiver discard it or the dataset wedges forever.
            echo "NOTE: [$ds] resume token not satisfiable here; discarding it on receiver" >&2
            printf 'ABORT %s\n' "$ds" >&"$OUT" 2>/dev/null || return 2
            IFS= read -r -t 120 -u "$IN" reply || return 2
            case "$reply" in
                OK\ *)
                    unset "token[$ds]" ;;
                ERR\ refused\ *)
                    echo "ERROR: could not discard token for [$ds]: ${reply#ERR refused }" >&2
                    return 1 ;;
                *)  return 2 ;;
            esac
        fi
    fi

    if [[ ",${have[$ds]:-}," == *",$target,"* ]]; then
        utd_n=$(( utd_n + 1 ))
        return 0
    fi

    # Newest snapshot both sides know, by name: the incremental base.
    common=$(local_newest_common "$ds")
    if [[ -n "$common" ]]; then
        est=$(estimate $flags -I "${ds}@${common}" "${ds}@${target}")
        xfer "${ds}@${common}${dest_tag}" "$est" "SEND $ds $common $target $est" \
            $flags -I "${ds}@${common}" "${ds}@${target}"
        return $?
    fi

    if [[ -z "${have[$ds]:-}" ]]; then
        # Receiver has nothing: bootstrap with the oldest snapshot, then
        # bring it to target with -I, preserving history depth remotely.
        local ls=()
        IFS=, read -r -a ls <<<"${lsnaps[$ds]}"
        local oldest="${ls[0]}"
        if [[ "$oldest" != "$target" ]]; then
            est=$(estimate $flags "${ds}@${oldest}")
            xfer "${ds}@${oldest} (bootstrap)${dest_tag}" "$est" "SEND $ds - $oldest $est" \
                $flags "${ds}@${oldest}"
            rc=$?
            [[ $rc -ne 0 ]] && return $rc
            est=$(estimate $flags -I "${ds}@${oldest}" "${ds}@${target}")
            xfer "${ds}@${oldest}${dest_tag}" "$est" "SEND $ds $oldest $target $est" \
                $flags -I "${ds}@${oldest}" "${ds}@${target}"
            return $?
        fi
    fi

    # First snapshot ever, or a diverged receiver (it has snaps, none in
    # common). Full send; the receiver's -F makes the source authoritative.
    est=$(estimate $flags "${ds}@${target}")
    xfer "${ds}@${target} (full send)${dest_tag}" "$est" "SEND $ds - $target $est" \
        $flags "${ds}@${target}"
    return $?
}

# Newest local snapshot (walking newest to oldest) that the receiver also
# has, by name; empty if histories share nothing.
local_newest_common() {
    local ds="$1" i
    local ls=()
    IFS=, read -r -a ls <<<"${lsnaps[$ds]:-}"
    for (( i = ${#ls[@]} - 1; i >= 0; i-- )); do
        if [[ ",${have[$ds]:-}," == *",${ls[i]},"* ]]; then
            echo "${ls[i]}"
            return 0
        fi
    done
    echo ""
}

#
# ---------- 5.  session loop with reconnect ----------------------------------
#
# Retry accounting, tuned to fail fast on hopeless targets but survive
# flaky links:
#   conn_tries -- consecutive failures to establish the FIRST session;
#                 5 of those and the host is unreachable (exit 3).
#   strikes    -- consecutive dead sessions with zero completed datasets;
#                 3 of those and we give up on what's left. Any progress
#                 resets it: a 47-of-50-then-die session is progress.
#   dskill     -- per-dataset session kills; a dataset that killed 2
#                 sessions is marked failed so one poison dataset can't
#                 block the rest of the tree forever.
declare -A done_ds           # dataset -> handled (any outcome), skip when replanning
declare -A dskill ok_ds
failed=()                    # "<dataset> (reason)" collected for the summary
strikes=0
conn_tries=0
ever_connected=""

while true; do
    pending=()
    for ds in "${datasets[@]}"; do
        if [[ -z "${done_ds[$ds]:-}" ]]; then
            pending+=( "$ds" )
        fi
    done
    if [[ ${#pending[@]} -eq 0 ]]; then
        break
    fi

    if ! connect_session; then
        if [[ -z "$ever_connected" ]]; then
            conn_tries=$(( conn_tries + 1 ))
            if (( conn_tries >= 5 )); then
                echo "ERROR: no session to [$remote] after $conn_tries attempts" >&2
                exit 3
            fi
            echo "NOTE: connect to [$remote] failed (attempt $conn_tries/5); retrying" >&2
            sleep 5
            continue
        fi
        strikes=$(( strikes + 1 ))
        if (( strikes >= 3 )); then
            echo "ERROR: giving up: cannot re-establish session with [$remote]" >&2
            break
        fi
        sleep 5
        continue
    fi
    ever_connected=1

    if ! send_tree_block; then
        close_session
        strikes=$(( strikes + 1 ))
        if (( strikes >= 3 )); then
            echo "ERROR: giving up: TREE exchange keeps failing with [$remote]" >&2
            break
        fi
        sleep 2
        continue
    fi
    echo "tree [$root@$target] -> [$remote]: ${#datasets[@]} datasets local, ${#have[@]} known to receiver" >&2

    progress=0               # datasets settled this session (resets strikes)
    session_dead=""
    for ds in "${pending[@]}"; do
        set +e
        plan_one "$ds"
        prc=$?
        set -e
        case $prc in
            0)  done_ds[$ds]=1
                ok_ds[$ds]=1
                progress=$(( progress + 1 )) ;;
            1)  done_ds[$ds]=1
                failed+=( "$ds" )
                progress=$(( progress + 1 )) ;;
            2)  session_dead=1
                dskill[$ds]=$(( ${dskill[$ds]:-0} + 1 ))
                if (( dskill[$ds] >= 2 )); then
                    done_ds[$ds]=1
                    failed+=( "$ds (repeated session failures)" )
                fi
                break ;;
        esac
    done

    if [[ -z "$session_dead" ]]; then
        # Clean finish: ENDTREE triggers the receiver's prune+stamp pass.
        if printf 'ENDTREE\n' >&"$OUT" 2>/dev/null \
            && IFS= read -r -t 600 -u "$IN" reply \
            && [[ "$reply" == "OK ENDTREE" ]]; then
            :
        else
            echo "WARNING: ENDTREE handshake with [$remote] did not complete" >&2
        fi
        printf 'BYE\n' >&"$OUT" 2>/dev/null || true
        close_session
        break
    fi

    close_session
    if (( progress > 0 )); then
        strikes=0
    else
        strikes=$(( strikes + 1 ))
    fi
    if (( strikes >= 3 )); then
        echo "ERROR: giving up after 3 sessions without progress" >&2
        break
    fi
    echo "NOTE: session with [$remote] lost; reconnecting" >&2
    sleep 2
done

# Anything the retry loop never got to counts as failed.
for ds in "${datasets[@]}"; do
    if [[ -z "${done_ds[$ds]:-}" ]]; then
        failed+=( "$ds (unsent)" )
    fi
done

#
# ---------- 6.  local prune (only datasets that fully succeeded) --------------
#
# Same policy as the receiver (keep the newest keep_count prunable-prefix
# snapshots per dataset), but restricted to datasets that replicated
# cleanly: pruning under a failed dataset could destroy the very snapshot
# a future incremental needs as its base.
prune_local() {
    local snap ds name prefix matched extra i
    declare -A psnaps=()     # dataset -> space-joined prunable snaps, oldest first
    local order=()
    while IFS= read -r snap; do
        ds="${snap%@*}"
        name="${snap#*@}"
        [[ -n "${ok_ds[$ds]:-}" ]] || continue
        matched=""
        for prefix in "${prune_prefixes[@]}"; do
            if [[ "$name" == "$prefix"* ]]; then
                matched=1
                break
            fi
        done
        [[ -n "$matched" ]] || continue
        if [[ -z "${psnaps[$ds]:-}" ]]; then
            order+=( "$ds" )
        fi
        psnaps[$ds]="${psnaps[$ds]:-}${psnaps[$ds]:+ }$snap"
    done < <(
        if [[ -n "$single" ]]; then
            zfs list -H -t snapshot -s creation -d 1 -o name "$root" 2>/dev/null
        else
            zfs list -H -r -t snapshot -s creation -o name "$root" 2>/dev/null
        fi || true
    )
    local list=()
    for ds in "${order[@]}"; do
        read -r -a list <<<"${psnaps[$ds]}"
        extra=$(( ${#list[@]} - keep_count ))
        for (( i = 0; i < extra; i++ )); do
            echo "pruning ${list[i]}" >&2
            zfs destroy "${list[i]}" 2>/dev/null \
                || echo "WARNING: failed to prune old local snapshot: ${list[i]}" >&2
        done
    done
}
prune_local

echo "Tree [$root@$target]${dest_tag}: $sent_n sent, $utd_n up to date, $skip_n skipped, ${#failed[@]} failed" >&2
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed datasets for [$remote]:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    exit 2
fi
