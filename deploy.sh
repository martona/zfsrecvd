#!/usr/bin/env bash
# Push the zfsrecvd scripts from this host's /etc/zfsrecvd to every host
# named in the config, over ssh+sudo (a plain scp can't write /etc/zfsrecvd
# as a non-root login).
#
# Targets, deduped by host name:
#   * [orchestrator-targets]  (logging in as the listed user)
#   * [sends] destinations    (logging in as the current user)
#   * [allowed_hosts]         (logging in as the current user)
#
# EC2 instances in [orchestrator-ec2up] are started for the duration and
# stopped after, exactly like an orchestrated run. Certificates, keys and
# zfsrecvd.conf are per-host and are never copied. If a target's zfsrecvd
# listener is active, it is restarted so it picks up the new scripts.
#
# Workflow when iterating: edit in the checkout, run install.sh to refresh
# this host, then run this script to fan out.
#
# Exit: 0 all hosts deployed, 1 some failed, 75 another orchestrate/deploy
#       run is in progress.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/ec2helpers.sh

# One orchestrate/deploy at a time across the estate.
orch_lock

# Running under sudo makes ssh use root's keys, which is a common source
# of baffling auth failures. Root is not needed here.
if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo "WARNING: running under sudo; ssh will use root's keys, not yours." >&2
    echo "deploy.sh does not need root -- run it as your own user." >&2
fi

src_dir="/etc/zfsrecvd"
scripts=(
    cfgparser.sh
    deploy.sh
    ec2helpers.sh
    fleetparser.sh
    fleetrun.sh
    gc.sh
    listen.sh
    orchestrate.sh
    pp2.sh
    retain.sh
    run_indented.sh
    send.sh
    sendtree.sh
    zfsrecvd.sh
)

for f in "${scripts[@]}"; do
    if [[ ! -f "$src_dir/$f" ]]; then
        echo "ERROR: $src_dir/$f is missing; run install.sh first." >&2
        exit 1
    fi
done

#
# ---------- 1.  collect deploy targets ---------------------------------------
#
# Fall back to the invoking user even under sudo, not to root.
me="${SUDO_USER:-$(id -un)}"
declare -A target_user=()
targets=()                     # first-seen order

add_target() {
    local host="$1" user="$2"
    [[ -n "$host" ]] || return 0
    if [[ -z "${target_user[$host]:-}" ]]; then
        target_user[$host]="$user"
        targets+=( "$host" )
    fi
}

# orchestrator-targets go first so their explicit user wins the dedupe.
for entry in "${orchtargets[@]}"; do
    read -r host user _ <<<"$entry"
    add_target "$host" "${user:-$me}"
done
for entry in "${sends[@]}"; do
    read -r _dataset host _ <<<"$entry"
    add_target "$host" "$me"
done
for host in "${allowed_hosts[@]}"; do
    add_target "$host" "$me"
done

if [[ ${#targets[@]} -eq 0 ]]; then
    echo "No deploy targets found in the config; nothing to do." >&2
    exit 0
fi

#
# ---------- 2.  wake the EC2 fleet, then push --------------------------------
#
ec2_maybe_start

# sudo -n everywhere: without a tty, an unexpected password prompt would
# otherwise silently eat the tar stream as password attempts.
# --unlink-first so a script that is being executed right now (e.g. the
# listener's zfsrecvd.sh) is replaced via a fresh inode, never truncated
# under a running interpreter.
# daemon-reload clears the "unit file changed on disk" nag that a prior
# install.sh run leaves behind; it is cheap and safe on hosts without the
# service too.
remote_cmd='sudo -n mkdir -p /etc/zfsrecvd \
  && sudo -n tar -C /etc/zfsrecvd --unlink-first -xf - \
  && sudo -n systemctl daemon-reload \
  && if systemctl is-active --quiet zfsrecvd.service; then
         sudo -n systemctl restart zfsrecvd.service && echo "    listener restarted"
     fi'

succs=()
fails=()
for host in "${targets[@]}"; do
    user="${target_user[$host]}"
    echo "Deploying to [$user@$host]" >&2
    set +e
    tar -C "$src_dir" -cf - "${scripts[@]}" \
        | ssh "${ssh_opts[@]}" "$user@$host" "$remote_cmd"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        succs+=( "$host" )
    else
        fails+=( "$host (rc=$rc)" )
        echo "ERROR: deploy to [$user@$host] failed (rc=$rc)" >&2
    fi
done

if [[ ${#succs[@]} -gt 0 ]]; then
    echo "Deployed to:" >&2
    printf '  %s\n' "${succs[@]}" >&2
fi
if [[ ${#fails[@]} -gt 0 ]]; then
    echo "Failed:" >&2
    printf '  %s\n' "${fails[@]}" >&2
    exit 1
fi
