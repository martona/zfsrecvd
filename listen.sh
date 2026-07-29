#!/bin/bash
# Launch a forking socat listener for ZFS replication.
# All stderr (socat and its children) is consumed by systemd and ends in the journal.

source /etc/zfsrecvd/cfgparser.sh

echo "Starting ZFS receive listener on $tcp_addr:$tcp_port (transport: $transport)" >&2

# H transport (PROTOCOL.md §20): haproxy owns TLS on the public port and
# forwards plaintext to us on loopback, prepending a PROXY protocol v2
# header with the verified client CN -- zfsrecvd.sh parses it fail-closed
# via pp2.sh. This listener must never be reachable beyond loopback; the
# generated run config pins tcp-addr to 127.0.0.1.
if [[ "$transport" == "haproxy" ]]; then
    exec /usr/bin/socat -b 262144 \
        "TCP-LISTEN:${tcp_port},bind=${tcp_addr},reuseaddr,fork,max-children=16,nodelay" \
        EXEC:'/etc/zfsrecvd/zfsrecvd.sh'
fi

# Options assembled in a variable on purpose: a missing "\" in the old
# backslash-continued form silently detached the remaining options into a
# no-op shell statement (see send.sh for the full story).
ssl_opts="reuseaddr,fork,max-children=16"
ssl_opts+=",nodelay"
ssl_opts+=",so-keepalive"
ssl_opts+=",cert=${cert_dir}/server.pem"
ssl_opts+=",key=${cert_dir}/server.key"
ssl_opts+=",cafile=${cert_dir}/ca.pem"
ssl_opts+=",verify=1"

exec /usr/bin/socat -b 262144 \
    "OPENSSL-LISTEN:${tcp_port},bind=${tcp_addr},${ssl_opts}" \
    EXEC:'/etc/zfsrecvd/zfsrecvd.sh' \
    2> >(grep --line-buffered -v "OpenSSL: Warning: this implementation does not check CRLs" >&2)
