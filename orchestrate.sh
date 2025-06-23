#!/usr/bin/env bash
# SSH into destinations and execute sends.sh.
#   Use /etc/zfsrecvd/zfsrecvd.conf to configure.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/run_indented.sh

succs=()
fails=()
ec2_instances_to_stop=()

if [[ -n "${orchec2up[*]}" ]]; then
    if ! command -v aws &>/dev/null; then
        echo "ERROR: AWS CLI is not installed, but orchestrator-ec2up section is present in the config." >&2
        exit 1
    fi
    if ! aws ec2 describe-instances; then
        echo "ERROR: AWS CLI failed to connect to EC2 service. Check your credentials." >&2
        exit 1
    fi
    printf 'Starting EC2 instances:\n'
    printf '  %s\n' "${orchec2up[@]}" >&2
    instances_to_stop=($(aws ec2 start-instances --instance-ids "${orchec2up[@]}" --query 'StartingInstances[?PreviousState.Name==`stopped`].InstanceId' --output text))
    printf '  %d will be stopped after the operation\n' "${#instances_to_stop[@]}" >&2
    aws ec2 wait instance-running --instance-ids "${instances_to_stop[@]}"
fi

for entry in "${orchtargets[@]}"; do
    # split on any whitespace -> dataset + host
    read -r host user _ <<<"$entry"          # ignore extra columns

    # sanity‑skip malformed lines
    [[ -z "$host" || -z "$user" ]] && continue

    echo "Connecting to [$user@$host] to execute sendall.sh" >&2
    set +e
    run_indented "  [sendall] " ssh -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" sudo /etc/zfsrecvd/sendall.sh
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        succs+=("$host")
    else
        fails+=("$host (rc=$rc)")
        echo "ERROR: SSH connection to [$user@$host] failed" >&2
    fi    
done

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Successfully processed:"
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#fails[@]} -gt 0 ]]; then
    echo "Failed hosts:"
    printf '  %s\n' "${fails[@]}" >&2
fi

if [[ -n "${ec2_instances_to_stop[*]}" ]]; then
    printf 'Stopping EC2 instances: \n'
    printf '  %s\n' "${ec2_instances_to_stop[@]}" >&2
    aws ec2 stop-instances --instance-ids "${ec2_instances_to_stop[@]}"
fi
