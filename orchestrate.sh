#!/usr/bin/env bash
# SSH into destinations and execute sendall.sh.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.
#
# Hosts run in parallel. Output modes:
#   * interactive (stderr is a tty): docker-style live board, one status
#     line per host repainted in place; full per-host output goes to log
#     files, and failing hosts get their log tail dumped at the end.
#   * headless: plain parallel, line-interleaved output (each line already
#     carries its [host]>[dest] prefix from the remote side).
#   * --serial: the old one-host-at-a-time mode with full scrolling output.
#
# Exit: 0 all hosts ok (a host skipped because a run was already in progress
#         there does not fail the run),
#       1 at least one host failed or was unreachable,
#       2 all hosts reachable, but some sends failed.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/ec2helpers.sh

# One orchestrate/deploy at a time across the estate.
orch_lock

succs=()
partials=()
skips=()
fails=()
pids=()
logdir=""

# split "[orchestrator-targets]" into parallel host/user arrays
hosts=()
users=()
for entry in "${orchtargets[@]}"; do
    read -r host user _ <<<"$entry"          # ignore extra columns
    [[ -z "$host" || -z "$user" ]] && continue
    hosts+=( "$host" )
    users+=( "$user" )
done
if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "No hosts in [orchestrator-targets]; nothing to do." >&2
    exit 0
fi

record_result() {
    local host="$1" rc="$2"
    case $rc in
        0)   succs+=( "$host" ) ;;
        2)   partials+=( "$host" )
             echo "NOTE: [$host] completed, but some sends failed" >&2 ;;
        75)  skips+=( "$host" )
             echo "NOTE: [$host] skipped: another send run is already in progress there" >&2 ;;
        255) fails+=( "$host (ssh connection failed)" )
             echo "ERROR: SSH connection to [$host] failed" >&2 ;;
        *)   fails+=( "$host (sendall rc=$rc)" )
             echo "ERROR: sendall on [$host] exited with rc=$rc" >&2 ;;
    esac
}

# Last visual record of a log: pv separates in-place updates with \r, so
# split on both \r and \n and take the final non-blank record -- exactly
# what the bottom line of a serial terminal would be showing.
latest_line() {
    tail -c 4096 "$1" 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -n 1 || true
}

# Re-pad "[host]>[rest]" so the ">" column lines up across the board.
board_fmt() {
    BOARD_LINE="$1"
    if [[ $BOARD_LINE =~ ^\[([^]]+)\]\>(.*)$ ]]; then
        BOARD_LINE=$(printf '[%-*s]>%s' "$2" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
    fi
}

orch_cleanup() {
    local p
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    tput cnorm 2>/dev/null || true
    stop_ec2_instances
}

ec2_maybe_start
# ec2_maybe_start installed its own EXIT trap; replace it with a combined
# handler so an interrupt also reaps the ssh children and restores the
# cursor before the instances are stopped.
trap orch_cleanup EXIT

#
# ---------- serial mode (old behavior, kept as an escape hatch) --------------
#
run_serial() {
    local ssh_tty_flag=()
    if [[ -t 2 ]]; then
        # give the remote a tty so pv renders progress live
        ssh_tty_flag=( -t )
    fi
    local i rc
    for ((i = 0; i < ${#hosts[@]}; i++)); do
        echo "Connecting to [${users[i]}@${hosts[i]}] to execute sendall.sh" >&2
        set +e
        ssh "${ssh_tty_flag[@]}" -o ConnectTimeout=10 -o BatchMode=yes \
            "${users[i]}@${hosts[i]}" sudo /etc/zfsrecvd/sendall.sh
        rc=$?
        set -e
        record_result "${hosts[i]}" "$rc"
    done
}

#
# ---------- headless parallel: line-interleaved --------------------------------
#
# Remote lines are prefixed and each gawk record is a single write(), so
# concurrent hosts interleave at line granularity -- fine for a journal.
run_parallel_plain() {
    local i rc
    for ((i = 0; i < ${#hosts[@]}; i++)); do
        echo "Connecting to [${users[i]}@${hosts[i]}] to execute sendall.sh" >&2
        ssh -o ConnectTimeout=10 -o BatchMode=yes \
            "${users[i]}@${hosts[i]}" sudo /etc/zfsrecvd/sendall.sh </dev/null &
        pids[i]=$!
    done
    for ((i = 0; i < ${#hosts[@]}; i++)); do
        set +e
        wait "${pids[i]}"
        rc=$?
        set -e
        record_result "${hosts[i]}" "$rc"
    done
}

#
# ---------- interactive parallel: live per-host status board -------------------
#
# One line per host, repainted in place. -tt forces a remote pty (so pv
# renders progress) while stdin comes from /dev/null and output goes to a
# log file: the ssh processes never touch the local terminal, the renderer
# owns it exclusively.
run_parallel_live() {
    local n=${#hosts[@]}
    local rows
    rows=$(tput lines 2>/dev/null) || rows=50
    if (( n + 3 > rows )); then
        echo "NOTE: terminal too short for the live board (${n} hosts); using plain output." >&2
        run_parallel_plain
        return
    fi

    logdir=$(mktemp -d /tmp/zfsrecvd-orch.XXXXXX)
    local i maxhost=0
    for ((i = 0; i < n; i++)); do
        (( ${#hosts[i]} > maxhost )) && maxhost=${#hosts[i]}
    done

    local c_run=$'\e[36m' c_ok=$'\e[32m' c_warn=$'\e[33m' c_err=$'\e[31m' c_off=$'\e[0m'
    local rcs=() finished=() statuses=() lines=()

    local cols prev_cols
    cols=$(tput cols 2>/dev/null) || cols=120
    prev_cols=$cols
    # Pin the remote pty width to the local terminal (minus the glyph
    # column) so pv sizes its bars to what actually fits on the board.
    # With stdin on /dev/null, ssh leaves the forced pty at a default size
    # that has nothing to do with this terminal, so we tell it ourselves.
    local remote_cols=$(( cols > 40 ? cols - 2 : cols ))

    echo "Orchestrating ${n} hosts in parallel (logs: $logdir)" >&2
    for ((i = 0; i < n; i++)); do
        ssh -tt -o ConnectTimeout=10 -o BatchMode=yes "${users[i]}@${hosts[i]}" \
            "stty cols $remote_cols 2>/dev/null || true; exec sudo /etc/zfsrecvd/sendall.sh" \
            </dev/null >"$logdir/${hosts[i]}.log" 2>&1 &
        pids[i]=$!
        rcs[i]=0
        finished[i]=0
        statuses[i]="${c_run}▸${c_off}"
        lines[i]="connecting to [${users[i]}@${hosts[i]}]..."
        printf '\n' >&2
    done

    tput civis 2>/dev/null || true
    local running content
    while :; do
        running=0
        for ((i = 0; i < n; i++)); do
            if (( ! finished[i] )); then
                if kill -0 "${pids[i]}" 2>/dev/null; then
                    running=1
                else
                    set +e
                    wait "${pids[i]}"
                    rcs[i]=$?
                    set -e
                    finished[i]=1
                    case ${rcs[i]} in
                        0)  statuses[i]="${c_ok}✔${c_off}" ;;
                        2)  statuses[i]="${c_warn}◐${c_off}" ;;
                        75) statuses[i]="${c_warn}⊘${c_off}" ;;
                        *)  statuses[i]="${c_err}✖${c_off}" ;;
                    esac
                fi
                content=$(latest_line "$logdir/${hosts[i]}.log")
                [[ -n "$content" ]] && lines[i]="$content"
            fi
        done

        cols=$(tput cols 2>/dev/null) || cols=120
        if (( cols != prev_cols )); then
            # Width changed: the old region may have rewrapped, making the
            # cursor-up arithmetic lie. Abandon it and re-anchor below.
            prev_cols=$cols
            for ((i = 0; i < n; i++)); do printf '\n' >&2; done
        fi
        printf '\e[%dA' "$n" >&2
        for ((i = 0; i < n; i++)); do
            board_fmt "${lines[i]}" "$maxhost"
            printf '\e[2K%s %s\n' "${statuses[i]}" "${BOARD_LINE:0:cols > 4 ? cols - 4 : 1}" >&2
        done
        (( running )) || break
        sleep 0.2
    done
    tput cnorm 2>/dev/null || true

    for ((i = 0; i < n; i++)); do
        record_result "${hosts[i]}" "${rcs[i]}"
    done

    # keep the logs if anything went sideways, and show the interesting tails
    local any_bad=0
    for ((i = 0; i < n; i++)); do
        case ${rcs[i]} in 0|75) : ;; *) any_bad=1 ;; esac
    done
    if (( any_bad )); then
        for ((i = 0; i < n; i++)); do
            case ${rcs[i]} in
                0|75) : ;;
                *)
                    echo "---- [${hosts[i]}] last lines (full log: $logdir/${hosts[i]}.log) ----" >&2
                    tr '\r' '\n' <"$logdir/${hosts[i]}.log" | tail -n 40 >&2
                    ;;
            esac
        done
        echo "Per-host logs kept in: $logdir" >&2
    else
        rm -rf -- "$logdir"
    fi
}

if [[ "${1:-}" == "--serial" ]]; then
    run_serial
elif [[ -t 2 ]]; then
    run_parallel_live
else
    run_parallel_plain
fi

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Fully successful:" >&2
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#partials[@]} -gt 0 ]]; then
    echo "Completed with some failed sends:" >&2
    printf '  %s\n' "${partials[@]}" >&2
fi
if [[ ${#skips[@]} -gt 0 ]]; then
    echo "Skipped (send run already in progress):" >&2
    printf '  %s\n' "${skips[@]}" >&2
fi
if [[ ${#fails[@]} -gt 0 ]]; then
    echo "Failed hosts:" >&2
    printf '  %s\n' "${fails[@]}" >&2
    exit 1
fi
if [[ ${#partials[@]} -gt 0 ]]; then
    exit 2
fi
