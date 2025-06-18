#!/bin/sh
# Launch a forking socat listener for ZFS replication.
# All stderr (socat and its children) is consumed by systemd and ends in the journal.

source /etc/zfsrecvd/cfgparser.sh

exec /usr/bin/socat \
OPENSSL-LISTEN:"$tcp_port",reuseaddr,fork,\
cert=/etc/zfsrecvd/server.pem,\
key=/etc/zfsrecvd/server.key,\
cafile=/etc/zfsrecvd/ca.pem,\
verify=1 \
EXEC:'/etc/zfsrecvd/zfsrecvd.sh'
