#!/bin/bash
# Launch a forking socat listener for ZFS replication.
# All stderr (socat and its children) is consumed by systemd and ends in the journal.

source /etc/zfsrecvd/cfgparser.sh

echo "Starting ZFS receive listener on $tcp_addr:$tcp_port" >&2

# Options assembled in a variable on purpose: a missing "\" in the old
# backslash-continued form silently detached the remaining options into a
# no-op shell statement (see send.sh for the full story).
ssl_opts="reuseaddr,fork,max-children=16"
ssl_opts+=",nodelay"
ssl_opts+=",so-keepalive"
ssl_opts+=",cert=/etc/zfsrecvd/server.pem"
ssl_opts+=",key=/etc/zfsrecvd/server.key"
ssl_opts+=",cafile=/etc/zfsrecvd/ca.pem"
ssl_opts+=",verify=1"

exec /usr/bin/socat -b 262144 \
    "OPENSSL-LISTEN:${tcp_port},bind=${tcp_addr},${ssl_opts}" \
    EXEC:'/etc/zfsrecvd/zfsrecvd.sh' \
    2> >(grep --line-buffered -v "OpenSSL: Warning: this implementation does not check CRLs" >&2)
