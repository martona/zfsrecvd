#!/usr/bin/env bash
# Shared helpers for stevedore-orchestrate.sh and stevedore-fleetrun.sh:
# the ssh option set, the estate lock, and the EC2 wake/stop logic.
# Source this after the cfgparser. Call orch_lock to take the shared lock,
# and ec2_maybe_start once to wake the fleet; instances it starts -- plus
# any debt a crashed earlier run left behind -- are stopped by an EXIT trap
# it installs.

# Every control-plane ssh in the project rides these options. Fleet boxes
# answer to several names each (bare hostname, .lan, .local, tailscale
# with and without .ts.net), so known_hosts can never stay coherent:
# first contact under yet another name would prompt, and a name that now
# points at a rebuilt or different box would hard-fail the run. So we
# never prompt, accept whatever key the peer presents, and keep the
# operator's real known_hosts out of it entirely (never read, never
# written). LogLevel=ERROR mutes the "Permanently added ..." notice this
# would otherwise print on every single connection; real errors still
# come through. Host authenticity is treated as a property of the
# LAN/tailnet; the data path authenticates itself with mTLS either way.
source "$(dirname "${BASH_SOURCE[0]}")/stevedore-paths.sh"
ssh_opts=( -o ConnectTimeout=10 -o BatchMode=yes
           -o StrictHostKeyChecking=no
           -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null
           -o LogLevel=ERROR )

# Take the lock shared by orchestrate.sh and deploy.sh: swapping scripts
# under a run in flight would mix script generations within one run, so the
# two exclude each other. The file is chmod 666 so root-run and user-run
# invocations contend on the same lock instead of locking each other out.
orch_lock() {
    # fleetrun.sh holds the estate lock itself and runs orchestrate.sh as a
    # child; the child must not contend with its parent.
    if [[ -n "${ZFSRECVD_SKIP_LOCK:-}" ]]; then
        return 0
    fi
    local lock_file="${ZFSRECVD_LOCK_FILE:-/run/lock/stevedore-orchestrate.lock}"
    # Probe with a normal redirection first: a failed exec redirection would
    # abort the script with a bare "Permission denied" instead of this hint.
    if ! : 2>/dev/null >> "$lock_file"; then
        echo "ERROR: cannot open $lock_file (left behind by a run as another user?)." >&2
        echo "Remove it once with: sudo rm -f $lock_file" >&2
        exit 1
    fi
    chmod 666 "$lock_file" 2>/dev/null || true
    exec {orch_lock_fd}>>"$lock_file"
    if ! flock -n "$orch_lock_fd"; then
        echo "ERROR: another orchestrate or deploy run is already in progress." >&2
        exit 75
    fi
}

ec2_instances_to_stop=()

# Instances we start are recorded on disk so that a crashed run's instances
# still get stopped by a later run. (The PreviousState filter below would
# otherwise consider them "already running" forever and never stop them.)
# The -w check matters: mkdir -p succeeds on an existing root-owned dir even
# when we can't write into it.
ec2_state_dir="$STEVE_VAR"
if ! mkdir -p "$ec2_state_dir" 2>/dev/null || [[ ! -w "$ec2_state_dir" ]]; then
    ec2_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/stevedore"
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
