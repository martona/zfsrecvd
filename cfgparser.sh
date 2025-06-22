#!/usr/bin/env bash
# Parse /etc/zfsrecvd/zfsrecvd.conf and leave:
#   * recv_root     (string)
#   * tcp_port      (string)
#   * allowed_hosts (bash array)
#   * sends         (bash array)

CFG="/etc/zfsrecvd/zfsrecvd.conf"
MAGIC_RESUME_SUCCESS_RC=219

recv_root="" tcp_port="" tcp_addr="" allowed_hosts=() sends=() orchestrator=()

current=""
while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}               # strip comments
    line=${line//$'\r'/}           # strip CR
    [[ -z "$line" ]] && continue   # skip blanks
    if [[ $line =~ ^\[(.*)\]$ ]]; then
        current="${BASH_REMATCH[1]}"
        continue
    fi
    case "$current" in
        recv-root)     recv_root="$line" ;;
        tcp-port)      tcp_port="$line"  ;;
        tcp-addr)      tcp_addr="$line"  ;;
        allowed_hosts) allowed_hosts+=( "$line" ) ;;
        sends)         sends+=( "$line" ) ;;
        orchestrator)  orchestrator+=( "$line" ) ;;
    esac
done < "$CFG"

# resolve the address if needed.
# early in the boot we might not have a DNS server yet,
# or tailscale might not yet be up. we retry a few times 
# to allow the address to become resolvable. 
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
if [[ -z "$tcp_addr"  ]]; then tcp_addr="127.0.0.1"; fi

# force pv to display output. inner scripts will run through run_indented.sh so they
# won't see a terminal, but will inherit this variable.
if [ -t 2 ]; then
    # stderr is a terminal
    export PV_FORCE_FLAG="-f"
fi
