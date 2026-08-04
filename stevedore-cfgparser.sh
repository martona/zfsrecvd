#!/usr/bin/env bash
# Parse /etc/stevedore/stevedore.conf and leave:
#   * recv_root      (string)
#   * tcp_port       (string)
#   * tcp_addr       (string)
#   * keep_count     (string, numeric)
#   * allowed_hosts  (bash array)
#   * sends          (bash array)
#   * prune_prefixes (bash array)
#   * orchtargets    (bash array)
#   * orchjobs       (bash array)
#   * orchworkers    (string, numeric)
#   * orchec2up      (bash array)
#   * transport      (string: socat | haproxy)
#   * tunnels        (bash array: "dial localport" rows, haproxy senders)
#   * retain_spec    (string: retention grid, e.g. "hourly=48 daily=30")
#   * snapsbudget    (bash array: "tree value" rows -- sender snapshot
#                     budgets, value = <N><K|M|G|T|P> or <N>%; generated
#                     by fleetrun from fleet.conf snaps=)

source "$(dirname "${BASH_SOURCE[0]}")/stevedore-paths.sh"

CFG="${STEVEDORE_CONF:-$STEVE_ETC/stevedore.conf}"

recv_root="" tcp_port="" tcp_addr="" keep_count="" cert_dir="" allowed_hosts=()
sends=() prune_prefixes=() orchtargets=() orchjobs=() orchec2up=() orchworkers=""
transport="" tunnels=() retain_spec="" snapsbudget=()

current=""
while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}               # strip comments
    line=${line//$'\r'/}           # strip CR
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -z "$line" ]] && continue   # skip blanks
    if [[ $line =~ ^\[(.*)\]$ ]]; then
        current="${BASH_REMATCH[1]}"
        continue
    fi
    case "$current" in
        recv-root)             recv_root="$line" ;;
        tcp-port)              tcp_port="$line"  ;;
        tcp-addr)              tcp_addr="$line"  ;;
        keep-count)            keep_count="$line" ;;
        cert-dir)              cert_dir="$line" ;;
        allowed_hosts)         allowed_hosts+=( "$line" ) ;;
        sends)                 sends+=( "$line" ) ;;
        prune-prefixes)        prune_prefixes+=( "$line" ) ;;
        orchestrator-targets)  orchtargets+=( "$line" ) ;;
        orchestrator-jobs)     orchjobs+=( "$line" ) ;;
        orchestrator-workers)  orchworkers="$line" ;;
        transport)             transport="$line" ;;
        tunnel)                tunnels+=( "$line" ) ;;
        retain)                retain_spec="$line" ;;
        snaps-budget)          snapsbudget+=( "$line" ) ;;
        orchestrator-ec2up)    orchec2up+=( "$line" ) ;;
    esac
done < "$CFG"

# resolve the address if needed.
# early in the boot we might not have a DNS server yet,
# or tailscale might not yet be up. we retry a few times
# to allow the address to become resolvable.
# the default must be applied BEFORE the loop: resolving an empty string
# would burn all five retries on nothing.
if [[ -z "$tcp_addr" ]]; then tcp_addr="127.0.0.1"; fi
max_tries=5
name_or_ip="$tcp_addr"
for ((try=1; try<=max_tries; try++)); do
    tcp_addr=$(getent ahosts "$name_or_ip" | awk '{print $1; exit}') || true
    [[ -n $tcp_addr ]] && break          # success, quit loop
    echo "wait-net: [$name_or_ip] not yet resolvable (attempt $try/$max_tries)" >&2
    sleep 5
done

if [[ -z "$recv_root" ]]; then recv_root="ebs/recv"; fi
if [[ -z "$tcp_port"  ]]; then tcp_port=5299;        fi
if ! [[ "$keep_count" =~ ^[0-9]+$ ]]; then keep_count=6; fi
# cert-dir lets a generated run config point at per-run certs (fleetrun)
# without touching any statically-placed ones.
if [[ -z "$cert_dir" ]]; then cert_dir="$STEVE_ETC"; fi
if [[ -z "$transport" ]]; then transport="socat"; fi
if [[ ${#prune_prefixes[@]} -eq 0 ]]; then prune_prefixes=( "stevedore-" ); fi

# force pv to display output. inner scripts will run through run_indented.sh so they
# won't see a terminal, but will inherit this variable.
if [ -t 2 ]; then
    # stderr is a terminal
    export PV_FORCE_FLAG="-f"
fi
if [[ -z "${PV_FORCE_FLAG+x}" ]]; then
    # avoid unbound variable errors
    export PV_FORCE_FLAG=""
fi
