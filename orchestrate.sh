#!/usr/bin/env bash
# SSH into destinations and execute sendall.sh.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.
#
# Exit: 0 all hosts ok (a host skipped because a run was already in progress
#         there does not fail the run),
#       1 at least one host failed or was unreachable,
#       2 all hosts reachable, but some sends failed.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/run_indented.sh

# One orchestrated run at a time.
exec {lock_fd}>/run/lock/zfsrecvd-orchestrate.lock
if ! flock -n "$lock_fd"; then
    echo "ERROR: another orchestrate run is already in progress." >&2
    exit 75
fi

succs=()
partials=()
skips=()
fails=()
ec2_instances_to_stop=()

# Instances we start are recorded on disk so that a crashed run's instances
# still get stopped by a later run. (The PreviousState filter below would
# otherwise consider them "already running" forever and never stop them.)
state_dir="/var/lib/zfsrecvd"
if ! mkdir -p "$state_dir" 2>/dev/null; then
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/zfsrecvd"
    mkdir -p "$state_dir"
fi
pending_file="$state_dir/ec2-pending-stop"

stop_ec2_instances() {
    [[ ${#ec2_instances_to_stop[@]} -gt 0 ]] || return 0
    printf 'Stopping EC2 instances:\n' >&2
    local id
    local failed=()
    for id in "${ec2_instances_to_stop[@]}"; do
        printf '  %s\n' "$id" >&2
        aws ec2 stop-instances --instance-ids "$id" >/dev/null || failed+=( "$id" )
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        printf '%s\n' "${failed[@]}" >| "$pending_file"
        echo "WARNING: could not stop: ${failed[*]} (recorded in $pending_file; next run will retry)" >&2
    else
        rm -f -- "$pending_file"
    fi
    ec2_instances_to_stop=()
}

if [[ ${#orchec2up[@]} -gt 0 ]]; then
    if ! command -v aws &>/dev/null; then
        echo "ERROR: AWS CLI is not installed, but orchestrator-ec2up section is present in the config." >&2
        exit 1
    fi
    if ! aws ec2 describe-instances > /dev/null 2>&1; then
        echo "ERROR: AWS CLI failed to connect to EC2 service. Check your credentials." >&2
        exit 1
    fi

    # Debt from a previous run that crashed before stopping its instances.
    leftover=()
    if [[ -s "$pending_file" ]]; then
        mapfile -t leftover < <(grep -v '^[[:space:]]*$' "$pending_file" || true)
        if [[ ${#leftover[@]} -gt 0 ]]; then
            printf 'EC2 instances a previous run left running (will stop them at the end):\n' >&2
            printf '  %s\n' "${leftover[@]}" >&2
        fi
    fi

    printf 'Starting EC2 instances:\n' >&2
    printf '  %s\n' "${orchec2up[@]}" >&2
    started=($(aws ec2 start-instances --instance-ids "${orchec2up[@]}" \
        --query 'StartingInstances[?PreviousState.Name==`stopped`].InstanceId' --output text))

    declare -A stop_seen=()
    for id in "${leftover[@]}" "${started[@]}"; do
        if [[ -n "$id" && -z "${stop_seen[$id]:-}" ]]; then
            stop_seen[$id]=1
            ec2_instances_to_stop+=( "$id" )
        fi
    done
    printf '  %d will be stopped after the operation\n' "${#ec2_instances_to_stop[@]}" >&2

    if [[ ${#ec2_instances_to_stop[@]} -gt 0 ]]; then
        printf '%s\n' "${ec2_instances_to_stop[@]}" >| "$pending_file"
    fi
    trap stop_ec2_instances EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Wait on every configured instance, not just the ones we started: some
    # may be mid-boot already, and a wait on an empty list is a CLI error.
    aws ec2 wait instance-running --instance-ids "${orchec2up[@]}"
fi

# Interactive runs get a remote tty so pv renders progress live; headless
# runs (cron/systemd) don't, and pv then stays quiet on its own.
ssh_tty_flag=()
if [[ -t 2 ]]; then
    ssh_tty_flag=( -t )
fi

for entry in "${orchtargets[@]}"; do
    # split on any whitespace -> host + user
    read -r host user _ <<<"$entry"          # ignore extra columns

    # sanity‑skip malformed lines
    [[ -z "$host" || -z "$user" ]] && continue

    echo "Connecting to [$user@$host] to execute sendall.sh" >&2
    set +e
    run_indented "  [$host] " ssh "${ssh_tty_flag[@]}" -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" sudo /etc/zfsrecvd/sendall.sh
    rc=$?
    set -e
    case $rc in
        0)   succs+=( "$host" ) ;;
        2)   partials+=( "$host" )
             echo "NOTE: [$host] completed, but some sends failed (per-dataset details above)" >&2 ;;
        75)  skips+=( "$host" )
             echo "NOTE: [$host] skipped: another send run is already in progress there" >&2 ;;
        255) fails+=( "$host (ssh connection failed)" )
             echo "ERROR: SSH connection to [$user@$host] failed" >&2 ;;
        *)   fails+=( "$host (sendall rc=$rc)" )
             echo "ERROR: sendall on [$host] exited with rc=$rc" >&2 ;;
    esac
done

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Fully successful:" >&2
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#partials[@]} -gt 0 ]]; then
    echo "Completed with some failed sends (per-dataset details above):" >&2
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
