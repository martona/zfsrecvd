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
source /etc/zfsrecvd/ec2helpers.sh

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

ec2_maybe_start

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
    # No local prefixing: sendall.sh prefixes its own output remotely (with
    # the real hostname), and adding more columns here would push pv's
    # width-budgeted progress lines past the terminal edge again (see
    # run_indented.sh).
    ssh "${ssh_tty_flag[@]}" -o ConnectTimeout=10 -o BatchMode=yes "$user@$host" sudo /etc/zfsrecvd/sendall.sh
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
