#!/usr/bin/env bash
# stevedore wire protocol 2.1 sender: replicates a dataset tree over one TLS
# session. See PROTOCOL.md for the wire contract. 2.1 only (manifest
# snapshot+cursor guids, guid-veto replanning, received-bytes); a peer
# greeting anything else is a config error and fails clean.
#
# Usage: stevedore-sendtree.sh [--single] [--no-prune] <dataset[@snap]> <remote_host>
#        stevedore-sendtree.sh --prune-only <dataset>
#   --single:     send only the named dataset, not its descendants (send.sh
#                 execs into this for manual one-dataset runs).
#   --no-prune:   skip the local prune pass. Orchestrated (T) runs use this:
#                 with several destinations sending the same tree
#                 concurrently, pruning belongs to the orchestrator's
#                 prune-post stage, after ALL of them finished.
#   --prune-only: no session at all -- just the local prune pass over the
#                 tree (every dataset, not only ok ones: the orchestrator
#                 only invokes this when the whole tree replicated clean).
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
# Requires: <cert-dir>/{client.pem,client.key,ca.pem}, socat, pv.
#
# Exit: 0 all datasets ok (skips are warnings),
#       2 some datasets failed,
#       3 no session could ever be established.

set -euo pipefail
set -f                       # never glob; plenty of protocol word-splitting
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stevedore-cfgparser.sh"

# When we run under run_indented (see orchestrate.sh), every line we emit grows
# by STEVEDORE_INDENT columns of prefix before reaching the terminal. pv sizes
# its progress line to the terminal width (or assumes 80 when it can't tell),
# so an unshrunk line wraps once prefixed, and every \r-refresh then lands on
# a fresh row instead of overwriting in place. Shrink pv to compensate.
PV_WIDTH_FLAG=""
if [[ "${STEVEDORE_INDENT:-0}" -gt 0 ]]; then
    # Width source, in order: STEVEDORE_COLS (frozen once at orchestrate
    # startup -- stable against mid-run resizes), else a live
    # probe of the controlling tty. In the probe, 2>/dev/null must come
    # FIRST: redirections apply left to right, and a failed /dev/tty open
    # reports to whatever stderr is at that moment.
    cols="${STEVEDORE_COLS:-}"
    if [[ -z "$cols" ]]; then
        cols=$(stty size 2>/dev/null </dev/tty | awk '{print $2}') || true
    fi
    if [[ -n "${cols:-}" && "$cols" -gt $(( ${STEVEDORE_INDENT:-0} + 20 )) ]]; then
        PV_WIDTH_FLAG="-w $(( cols - ${STEVEDORE_INDENT:-0} - 1 ))"
    fi
fi

#
# ---------- 0.  arguments ----------------------------------------------------
#
single=""                    # nonempty: one dataset only, no descendants
no_prune=""                  # nonempty: skip the local prune pass (T fan-out)
prune_only=""                # nonempty: ONLY the local prune pass (T post-stage)
prune_all=""                 # prune gate: every dataset, not just ok_ds
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --single)     single=1;     shift ;;
        --no-prune)   no_prune=1;   shift ;;
        --prune-only) prune_only=1; shift ;;
        *) echo "Usage: $0 [--single] [--no-prune] <dataset[@snap]> <remote_host>" >&2
           echo "       $0 --prune-only <dataset>" >&2
           exit 64 ;;
    esac
done
if [[ $# -lt 2 && -z "$prune_only" ]] || [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--single] [--no-prune] <dataset[@snap]> <remote_host>" >&2
    echo "       $0 --prune-only <dataset>" >&2
    exit 64
fi
arg="$1"
remote="${2:-}"      # extra legacy arguments (old sentinel file) are ignored

# Local prune, same policy as the receiver (keep the newest keep_count
# prunable-prefix snapshots per dataset), but normally restricted to
# datasets that replicated cleanly: pruning under a failed dataset could
# destroy the very snapshot a future incremental needs as its base.
# --prune-only lifts that restriction via prune_all (the orchestrator
# calls it only after every destination of the tree finished clean).
# Defined here, ahead of the session machinery, because the --prune-only
# path below runs it and exits without ever gathering session state.
prune_local() {
    local snap ds name prefix matched extra i
    declare -A psnaps=()     # dataset -> space-joined prunable snaps, oldest first
    local order=()
    while IFS= read -r snap; do
        ds="${snap%@*}"
        name="${snap#*@}"
        [[ -n "$prune_all" || -n "${ok_ds[$ds]:-}" ]] || continue
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

if [[ -n "$prune_only" ]]; then
    root="${arg%%@*}"
    prune_all=1
    prune_local
    exit 0
fi

# Split dataset from target snapshot; with no @snap, the newest snapshot of
# the root names the run (manual runs -- orchestrated jobs pass @snap
# explicitly, pinned to the snapshot-pre stage's run name).
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
if [[ "${STEVEDORE_INDENT:-0}" -eq 0 ]]; then
    dest_tag=" -> [${remote}]"
fi

# Cursor identity (PROTOCOL.md §22): bookmarks are keyed by destination
# IDENTITY, never the dial name (dials get renamed; identities don't).
# Orchestrated jobs pass it via STEVEDORE_DEST_ID; manual runs fall back
# to the remote argument.
dest_id="${STEVEDORE_DEST_ID:-$remote}"
dest_id="${dest_id//[^A-Za-z0-9._-]/_}"

#
# ---------- 1.  gather local state (4 zfs invocations) -----------------------
#
datasets=()                          # tree in zfs list -r order (parents first)
declare -A dstype                    # dataset -> filesystem|volume
declare -A lsnaps                    # dataset -> local snaps, comma-joined, oldest first
declare -A lpairs                    # dataset -> "snap:guid,..." same order (2.1 manifest)
declare -A bpairs                    # dataset -> "#bookmark:guid,..." cursor lineage evidence
declare -A encroot encon             # encryptionroot / encryption per dataset

# The manifest always describes the FULL source tree (it is the
# informational truth the server's absence clocks key on, §5/§15b);
# --single only restricts what gets PLANNED AND SENT. A root-only
# manifest would make the server clock every receiver-side child as
# absent-at-source.
while IFS=$'\t' read -r name typ; do
    datasets+=( "$name" )
    dstype[$name]="$typ"
done < <(zfs list -H -r -t filesystem,volume -o name,type "$root")
if [[ ${#datasets[@]} -eq 0 ]]; then
    echo "ERROR: no such dataset: $root" >&2
    exit 2
fi
sendsets=( "${datasets[@]}" )        # what the planner walks
if [[ -n "$single" ]]; then
    sendsets=( "$root" )
fi

while IFS=$'\t' read -r s gd; do
    ds="${s%@*}"
    sn="${s#*@}"
    lsnaps[$ds]="${lsnaps[$ds]:-}${lsnaps[$ds]:+,}$sn"
    lpairs[$ds]="${lpairs[$ds]:-}${lpairs[$ds]:+,}$sn:$gd"
done < <(zfs list -H -r -t snapshot -s creation -o name,guid "$root")

# Replication cursors as manifest entries (2.1): every stevedore-* bookmark
# regardless of destination -- each one is lineage evidence for the
# server's collision pass ("this guid was in my history"), and more
# evidence means fewer false rename-asides. A bookmark's guid is its
# origin snapshot's guid, which is exactly what makes a cursor-catch-up
# tree (zero snapshot overlap, live cursor) distinguishable from a
# recreated-under-the-same-name tree (zero overlap, no cursor).
while IFS=$'\t' read -r b gd; do
    [[ "$b" == *#stevedore-* ]] || continue
    ds="${b%%#*}"
    bpairs[$ds]="${bpairs[$ds]:-}${bpairs[$ds]:+,}#${b#*#}:$gd"
done < <(zfs list -H -r -t bookmark -o name,guid "$root" 2>/dev/null || true)

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
# line to stderr. The announce goes out first: on a big rusty delta the
# dry run itself can grind for a long time, and without a line here the
# live board sits on the session header looking hung.
estimate() {
    local sz
    echo "estimating ${*: -1}" >&2
    sz=$(zfs send -nP "$@" 2>&1 | awk '/^size/{print $2; exit}') || sz=""
    echo "${sz:--}"
}

#
# ---------- 2.  session plumbing ---------------------------------------------
#
IN="" OUT=""                 # fds of the read/write ends of the TLS coproc

# H transport (PROTOCOL.md §20): [tunnel] rows in the run config map a
# destination dial name to the loopback port of the local haproxy bridge
# for it; matching destinations are dialed plaintext via /dev/tcp (TLS,
# peer verification, and connect timeouts all live in haproxy).
declare -A tunnel_port=()
if [[ "$transport" == "haproxy" ]]; then
    for _t in "${tunnels[@]}"; do
        read -r _td _tp _ <<<"$_t"
        if [[ -n "${_tp:-}" ]]; then
            tunnel_port[$_td]="$_tp"
        fi
    done
fi

# Replication cursors (PROTOCOL.md §22 -- zrepl's pattern): ONE bookmark
# per (dataset, destination) naming the newest snapshot that destination
# CONFIRMED holding: ds#stevedore-<dest-id>-<snapname>. Bookmarks pin no
# blocks, so local thinning can outrun every destination and an
# incremental from the cursor's GUID still works. Advance = create the
# new cursor, then destroy the OLDER ones for the pair; a crash between
# the two leaves both and the next advance cleans up.
cursor_list() {   # $1 = ds -> this pair's cursor bookmark names
    zfs list -H -t bookmark -d 1 -o name "$1" 2>/dev/null \
        | grep -F "#stevedore-${dest_id}-" || true
}
advance_cursor() {   # $1 = ds, $2 = confirmed snapname
    local bm="${1}#stevedore-${dest_id}-${2}" old osnap
    zfs bookmark "${1}@${2}" "$bm" 2>/dev/null || true
    while IFS= read -r old; do
        [[ -n "$old" && "$old" != "$bm" ]] || continue
        osnap="${old#*"#stevedore-${dest_id}-"}"
        if [[ "$osnap" < "$2" ]]; then
            zfs destroy "$old" 2>/dev/null || true
        fi
    done < <(cursor_list "$1")
}
# Newest cursor whose snapshot the receiver still HAS: the incremental
# base of last resort when no common snapshot survived local thinning.
cursor_base() {   # $1 = ds -> snapname or ""
    local bm snap best=""
    while IFS= read -r bm; do
        [[ -n "$bm" ]] || continue
        snap="${bm#*"#stevedore-${dest_id}-"}"
        [[ ",${have[$1]:-}," == *",$snap,"* ]] || continue
        if [[ -z "$best" || "$snap" > "$best" ]]; then
            best="$snap"
        fi
    done < <(cursor_list "$1")
    printf '%s\n' "$best"
}

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
    if [[ -n "${tunnel_port[$remote]:-}" ]]; then
        # plaintext to the local haproxy bridge: one bidirectional fd,
        # no relay process at all -- pv writes straight into the socket.
        # Loopback connects succeed or refuse instantly, so there is no
        # hang risk without a connect-timeout here; reaching the actual
        # receiver is haproxy's job (timeout connect 5s in its config).
        local fd
        NET_PID=""
        if ! exec {fd}<>"/dev/tcp/127.0.0.1/${tunnel_port[$remote]}"; then
            return 1
        fi
        OUT=$fd
        IN=$fd
    else
        local ssl_opts="connect-timeout=10"
        ssl_opts+=",so-keepalive"
        ssl_opts+=",nodelay"
        ssl_opts+=",cert=${cert_dir}/client.pem"
        ssl_opts+=",key=${cert_dir}/client.key"
        ssl_opts+=",cafile=${cert_dir}/ca.pem"
        ssl_opts+=",verify=1"
        coproc NET {
            exec socat -b 262144 \
                STDIO \
                "OPENSSL:${remote}:${tcp_port},${ssl_opts}" \
                2> >(grep -v "OpenSSL: Warning: this implementation does not check CRLs" >&2)
        }
        exec {OUT}>&"${NET[1]}"
        exec {IN}<&"${NET[0]}"
    fi
    printf 'stevedore2.1\n' >&"$OUT" 2>/dev/null || { close_session; return 1; }
    local g
    IFS= read -r -t 15 -u "$IN" g || { close_session; return 1; }
    if [[ "$g" != "OK stevedore2.1" ]]; then
        echo "ERROR: unexpected greeting from [$remote]: $g" >&2
        close_session
        return 1
    fi
    echo "connected to [$remote] (stevedore2.1${tunnel_port[$remote]:+, haproxy tunnel})" >&2
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
        local d ent
        for d in "${datasets[@]}"; do
            # manifest entries: snapshot guids + cursor bookmark guids
            ent="${lpairs[$d]:-}"
            if [[ -n "${bpairs[$d]:-}" ]]; then
                ent="${ent}${ent:+,}${bpairs[$d]}"
            fi
            if [[ -n "$ent" ]]; then
                printf 'DS %s %s\n' "$d" "$ent"
            else
                printf 'DS %s\n' "$d"
            fi
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
wire_bytes=0                 # receiver-reported bytes this run (2.1 OK lines)
LAST_REFUSAL=""              # detail of the last ERR refused (guid-veto replanning)
xfer() {
    # local -: set-option changes stay confined to this function. The
    # set +e/set -e pair around the pipeline below once LEAKED: it
    # re-armed errexit inside the session loop's deliberate set +e
    # window, so the first completed stream armed the trap and the next
    # nonzero xfer return killed the whole script SILENTLY with that
    # status -- no retry, no resume, no summary (bit the fleet when a
    # 64G-dirty receiver stalled recv finalization past the result
    # timeout: four truncated logs, exit 2, nothing else).
    local -
    local announce="$1" est="$2" cmdline="$3"
    shift 3
    echo "$announce" >&2
    printf '%s\n' "$cmdline" >&"$OUT" 2>/dev/null || return 2
    local reply
    IFS= read -r -t 120 -u "$IN" reply || return 2
    if [[ "$reply" == ERR\ refused\ * ]]; then
        LAST_REFUSAL="${reply#ERR refused }"
        echo "ERROR: receiver refused: $LAST_REFUSAL" >&2
        return 1
    fi
    [[ "$reply" == "GO" ]] || return 2
    # pv only gets -s when the estimate is a real number ("-" would be
    # taken as a filename).
    local est_pv=""
    if [[ "$est" =~ ^[0-9]+$ ]]; then
        est_pv="$est"
    fi
    # STEVEDORE_PV_EXTRA: optional extra pv flags from the environment, e.g.
    # STEVEDORE_PV_EXTRA="-L 50M" to cap bandwidth for a manual run.
    local rc pvrc ps=()
    set +e
    zfs send "$@" | pv $PV_FORCE_FLAG $PV_WIDTH_FLAG ${STEVEDORE_PV_EXTRA:-} ${est_pv:+-s "$est_pv"} >&"$OUT"
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
    # directly with no framing layer. The wait must outlast the receiver's
    # recv finalization: a txg sync on a big-dirty-tuned pool (zeus runs
    # zfs_dirty_data_max=64G on rust) can stall well past ten minutes.
    # Env-overridable for tests and unusual estates.
    IFS= read -r -t "${STEVEDORE_RESULT_TIMEOUT:-1800}" -u "$IN" reply || return 2
    case "$reply" in
        OK\ *)
            sent_n=$(( sent_n + 1 ))
            # result lines carry the receiver's byte count ("-" when it
            # could not tell)
            local okb
            read -r _ _ okb _ <<<"$reply"
            if [[ "${okb:-}" =~ ^[0-9]+$ ]]; then
                wire_bytes=$(( wire_bytes + okb ))
            fi
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

    # (The per-run receiver-only-snapshot NOTE lived here until
    # 2026-07-31: retired once 2.1's unknown-since stamps made the
    # receiver track those snapshots properly -- GC owns the inventory
    # now, report.sh --gc-debug surfaces it.)

    # Pending resume token? Handle it even when the dataset is otherwise up
    # to date: a lingering token blocks all future receives on the dataset.
    if [[ -n "${token[$ds]:-}" ]]; then
        local tk="${token[$ds]}" tinfo toname rsn
        echo "checking resume token for [$ds]" >&2
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
                advance_cursor "$ds" "$target"
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
        advance_cursor "$ds" "$target"
        return 0
    fi

    # Newest snapshot both sides know, by name: the incremental base.
    # Under 2.1 the server may refuse a base with "guid-mismatch" -- the
    # receiver's same-named snapshot is a different object (name reuse).
    # That name is no good as a base forever, so drop it from the
    # receiver's list and replan: next-newest common, then the cursor,
    # then bootstrap/full, exactly as if the name had never matched.
    local hh
    while common=$(local_newest_common "$ds"); [[ -n "$common" ]]; do
        est=$(estimate $flags -I "${ds}@${common}" "${ds}@${target}")
        xfer "${ds}@${common}${dest_tag}" "$est" "SEND $ds $common $target $est" \
            $flags -I "${ds}@${common}" "${ds}@${target}"
        rc=$?
        if [[ $rc -eq 1 && "$LAST_REFUSAL" == *guid-mismatch* ]]; then
            echo "NOTE: [$ds] receiver's @$common is a different object (guid mismatch); replanning without it" >&2
            hh=",${have[$ds]},"
            hh="${hh/,"$common",/,}"
            hh="${hh#,}"
            hh="${hh%,}"
            have[$ds]="$hh"
            continue
        fi
        if [[ $rc -eq 1 && "$LAST_REFUSAL" == *snapshot-collision* ]]; then
            # A same-named different snapshot sits inside every usable -I
            # range. No incremental can land; rebootstrap instead -- the
            # server moves the receiver's history aside whole at our
            # first full send, so nothing is lost, and the bootstrap
            # two-step restores depth.
            echo "NOTE: [$ds] snapshot name collision on receiver; rebootstrapping (receiver history moves aside)" >&2
            have[$ds]=""
            break
        fi
        [[ $rc -eq 0 ]] && advance_cursor "$ds" "$target"
        return $rc
    done

    # No common snapshot survives -- before falling back to a resend, try
    # the cursor: the receiver may still hold a snapshot we only remember
    # as a bookmark (long outage + sender thinning). Single step; -I
    # needs snapshots, and the gap's intermediates were pruned here anyway.
    # Volumes drop their -R here: send -R cannot take a bookmark source,
    # and -R only matters for streams that CREATE the dataset (bootstrap/
    # full) -- an incremental onto the existing volume is a plain -i.
    # Encrypted datasets keep their -w.
    local cbase cflags
    cbase=$(cursor_base "$ds")
    if [[ -n "$cbase" ]]; then
        cflags="$flags"
        [[ "$cflags" == "-R" ]] && cflags=""
        est=$(estimate $cflags -i "${ds}#stevedore-${dest_id}-${cbase}" "${ds}@${target}")
        xfer "${ds}@${cbase} (cursor catch-up)${dest_tag}" "$est" "SEND $ds $cbase $target $est" \
            $cflags -i "${ds}#stevedore-${dest_id}-${cbase}" "${ds}@${target}"
        rc=$?
        if [[ $rc -eq 1 && "$LAST_REFUSAL" == *guid-mismatch* ]]; then
            # The receiver's @cbase is not the snapshot our cursor points
            # at (recreated under the same name). The cursor is useless
            # against this receiver; fall through to bootstrap/full --
            # the server moves its imposter aside at the full send.
            echo "NOTE: [$ds] cursor base @$cbase is a different object on the receiver; falling back" >&2
            hh=",${have[$ds]},"
            hh="${hh/,"$cbase",/,}"
            hh="${hh#,}"
            hh="${hh%,}"
            have[$ds]="$hh"
        else
            [[ $rc -eq 0 ]] && advance_cursor "$ds" "$target"
            return $rc
        fi
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
            rc=$?
            [[ $rc -eq 0 ]] && advance_cursor "$ds" "$target"
            return $rc
        fi
    fi

    # First snapshot ever, or a diverged receiver (it has snaps, none in
    # common). Full send; the receiver's -F makes the source authoritative.
    est=$(estimate $flags "${ds}@${target}")
    xfer "${ds}@${target} (full send)${dest_tag}" "$est" "SEND $ds - $target $est" \
        $flags "${ds}@${target}"
    rc=$?
    [[ $rc -eq 0 ]] && advance_cursor "$ds" "$target"
    return $rc
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
    for ds in "${sendsets[@]}"; do
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
    echo "tree [$root@$target]${dest_tag}: ${#sendsets[@]} datasets local, ${#have[@]} known to receiver" >&2

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
            && IFS= read -r -t "${STEVEDORE_RESULT_TIMEOUT:-1800}" -u "$IN" reply \
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
for ds in "${sendsets[@]}"; do
    if [[ -z "${done_ds[$ds]:-}" ]]; then
        failed+=( "$ds (unsent)" )
    fi
done

#
# ---------- 6.  local prune (only datasets that fully succeeded) --------------
#
# prune_local is defined up in section 0 (the --prune-only path needs it
# early). Under --no-prune the orchestrator owns pruning: it runs the
# prune-post stage once per tree, after every destination finished.
if [[ -z "$no_prune" ]]; then
    prune_local
fi

echo "Tree [$root@$target]${dest_tag}: $sent_n sent, $utd_n up to date, $skip_n skipped, ${#failed[@]} failed" >&2
# machine-readable receiver-side byte count (0 on an all-up-to-date
# run) -- orchestrate harvests it per job
echo "WIRE-BYTES: $wire_bytes" >&2
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed datasets for [$remote]:" >&2
    printf '  %s\n' "${failed[@]}" >&2
    # machine-readable single line for the run report (names only, the
    # human list above carries the reasons)
    echo "FAILED-DATASETS: $(printf '%s\n' "${failed[@]}" | awk '{printf "%s%s", (NR>1?" ":""), $1}')" >&2
    exit 2
fi
