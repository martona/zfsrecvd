#!/usr/bin/env bash
# Shared EC2 wake/stop logic for orchestrate.sh and deploy.sh.
# Source this after cfgparser.sh (it needs $orchec2up), then call
# ec2_maybe_start once. Instances it starts -- plus any debt a crashed
# earlier run left behind -- are stopped by an EXIT trap it installs.

ec2_instances_to_stop=()

# Instances we start are recorded on disk so that a crashed run's instances
# still get stopped by a later run. (The PreviousState filter below would
# otherwise consider them "already running" forever and never stop them.)
ec2_state_dir="/var/lib/zfsrecvd"
if ! mkdir -p "$ec2_state_dir" 2>/dev/null; then
    ec2_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/zfsrecvd"
    mkdir -p "$ec2_state_dir"
fi
ec2_pending_file="$ec2_state_dir/ec2-pending-stop"

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
        printf '%s\n' "${failed[@]}" >| "$ec2_pending_file"
        echo "WARNING: could not stop: ${failed[*]} (recorded in $ec2_pending_file; next run will retry)" >&2
    else
        rm -f -- "$ec2_pending_file"
    fi
    ec2_instances_to_stop=()
}

ec2_maybe_start() {
    [[ ${#orchec2up[@]} -gt 0 ]] || return 0

    if ! command -v aws &>/dev/null; then
        echo "ERROR: AWS CLI is not installed, but orchestrator-ec2up section is present in the config." >&2
        exit 1
    fi
    if ! aws ec2 describe-instances > /dev/null 2>&1; then
        echo "ERROR: AWS CLI failed to connect to EC2 service. Check your credentials." >&2
        exit 1
    fi

    # Debt from a previous run that crashed before stopping its instances.
    local leftover=()
    if [[ -s "$ec2_pending_file" ]]; then
        mapfile -t leftover < <(grep -v '^[[:space:]]*$' "$ec2_pending_file" || true)
        if [[ ${#leftover[@]} -gt 0 ]]; then
            printf 'EC2 instances a previous run left running (will stop them at the end):\n' >&2
            printf '  %s\n' "${leftover[@]}" >&2
        fi
    fi

    printf 'Starting EC2 instances:\n' >&2
    printf '  %s\n' "${orchec2up[@]}" >&2
    local started
    started=($(aws ec2 start-instances --instance-ids "${orchec2up[@]}" \
        --query 'StartingInstances[?PreviousState.Name==`stopped`].InstanceId' --output text))

    local -A stop_seen=()
    local id
    for id in "${leftover[@]}" "${started[@]}"; do
        if [[ -n "$id" && -z "${stop_seen[$id]:-}" ]]; then
            stop_seen[$id]=1
            ec2_instances_to_stop+=( "$id" )
        fi
    done
    printf '  %d will be stopped after the operation\n' "${#ec2_instances_to_stop[@]}" >&2

    if [[ ${#ec2_instances_to_stop[@]} -gt 0 ]]; then
        printf '%s\n' "${ec2_instances_to_stop[@]}" >| "$ec2_pending_file"
    fi
    trap stop_ec2_instances EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Wait on every configured instance, not just the ones we started: some
    # may be mid-boot already, and a wait on an empty list is a CLI error.
    aws ec2 wait instance-running --instance-ids "${orchec2up[@]}"
}
