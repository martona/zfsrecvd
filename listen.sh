#!/bin/bash
# Launch a forking socat listener for ZFS replication.
# All stderr (socat and its children) is consumed by systemd and ends in the journal.

source /etc/zfsrecvd/cfgparser.sh

echo "Starting ZFS receive listener on $tcp_addr:$tcp_port" >&2

exec /usr/bin/socat \
OPENSSL-LISTEN:"$tcp_port",bind="$tcp_addr",\
reuseaddr,fork,max-children=16,\
cert=/etc/zfsrecvd/server.pem,\
key=/etc/zfsrecvd/server.key,\
cafile=/etc/zfsrecvd/ca.pem,\
verify=1 \
EXEC:'/etc/zfsrecvd/zfsrecvd.sh' \
2> >(grep -v "OpenSSL: Warning: this implementation does not check CRLs" >&2)
