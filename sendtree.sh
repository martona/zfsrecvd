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
# Requires: /etc/zfsrecvd/{client.pem,client.key,ca.pem}, socat, pv.
#
# Exit: 0 all datasets ok (skips are warnings),
#       2 some datasets failed,
#       3 no session could ever be established.

set -euo pipefail
set -f
source /etc/zfsrecvd/cfgparser.sh

# When we run under run_indented (see sendall.sh), every line we emit grows
# by ZFSRECVD_INDENT columns of prefix before reaching the terminal. pv sizes
# its progress line to the terminal width (or assumes 80 when it can't tell),
# so an unshrunk line wraps once prefixed, and every \r-refresh then lands on
# a fresh row instead of overwriting in place. Shrink pv to compensate.
PV_WIDTH_FLAG=""
if [[ "${ZFSRECVD_INDENT:-0}" -gt 0 ]]; then
    cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}') || true
    if [[ -n "${cols:-}" && "$cols" -gt $(( ${ZFSRECVD_INDENT:-0} + 20 )) ]]; then
        PV_WIDTH_FLAG="-w $(( cols - ${ZFSRECVD_INDENT:-0} - 1 ))"
    fi
fi

#
# ---------- 0.  arguments ----------------------------------------------------
#
single=""
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

# Under run_indented the prefix already names both ends; on a bare manual
# run there is no prefix, so append the destination for context.
dest_tag=""
if [[ "${ZFSRECVD_INDENT:-0}" -eq 0 ]]; then
    dest_tag=" -> [${remote}]"
fi

#
# ---------- 1.  gather local state (3 zfs invocations) -----------------------
#
datasets=()
declare -A dstype lsnaps encroot encon

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

# "-w" for encrypted datasets; "-R" for plain volumes (works around the
# OpenZFS 13033-adjacent unencrypted-zvol-into-encrypted-parent issue).
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

estimate() {   # zfs send args... -> bytes or "-"
    local sz
    sz=$(zfs send -nP "$@" 2>&1 | awk '/^size/{print $2; exit}') || sz=""
    echo "${sz:--}"
}

#
# ---------- 2.  session plumbing ---------------------------------------------
#
IN="" OUT=""

close_session() {
    # No stray redirections on these execs: an exec redirection is permanent,
    # so a careless "2>/dev/null" here would silence the rest of the script.
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
    return 0
}

declare -A have token
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
# 0 = ok, 1 = refused (permanent for this dataset), 2 = session dead
sent_n=0
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
# 0 = done (sent, up to date, or warn-skipped), 1 = failed permanently,
# 2 = session dead
utd_n=0
skip_n=0
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
            est=$(awk '/^size/{print $2; exit}' <<<"$tinfo")
            xfer "${ds} (resume)${dest_tag}" "${est:--}" "RESUME $ds ${est:--}" -t "$tk"
            rc=$?
            [[ $rc -ne 0 ]] && return $rc
            unset "token[$ds]"
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

    common=$(local_newest_common "$ds")
    if [[ -n "$common" ]]; then
        est=$(estimate $flags -I "${ds}@${common}" "${ds}@${target}")
        xfer "${ds}@${common}${dest_tag}" "$est" "SEND $ds $common $target $est" \
            $flags -I "${ds}@${common}" "${ds}@${target}"
        return $?
    fi

    if [[ -z "${have[$ds]:-}" ]]; then
        # bootstrap: seed with the oldest snapshot, then bring up to target,
        # preserving history depth on the receiver
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

    # first snapshot ever, or diverged receiver (source is authoritative)
    est=$(estimate $flags "${ds}@${target}")
    xfer "${ds}@${target} (full send)${dest_tag}" "$est" "SEND $ds - $target $est" \
        $flags "${ds}@${target}"
    return $?
}

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
declare -A done_ds dskill ok_ds
failed=()
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

    progress=0
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
    sleep 2
done

# anything never reached counts as failed
for ds in "${datasets[@]}"; do
    if [[ -z "${done_ds[$ds]:-}" ]]; then
        failed+=( "$ds (unsent)" )
    fi
done

#
# ---------- 6.  local prune (only datasets that fully succeeded) --------------
#
prune_local() {
    local snap ds name prefix matched extra i
    declare -A psnaps=()
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
