#!/usr/bin/env bash
# Parse /etc/zfsrecvd/zfsrecvd.conf and leave:
#   * recv_root     (string)
#   * tcp_port      (string)
#   * allowed_hosts (bash array)
#   * sends         (bash array)

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

CFG="/etc/zfsrecvd/zfsrecvd.conf"

recv_root="" tcp_port="" tcp_addr="" allowed_hosts=() sends=()
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
    esac
done < "$CFG"

tcp_addr=$(getent ahosts "$tcp_addr" | awk '{print $1; exit}') || true

if [[ -z "$recv_root" ]]; then recv_root="ebs/recv"; fi
if [[ -z "$tcp_port"  ]]; then tcp_port=5299;        fi
if [[ -z "$tcp_addr"  ]]; then tcp_addr="127.0.0.1"; fi
