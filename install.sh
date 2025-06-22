#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p /etc/zfsrecvd
cp "$SCRIPT_DIR/cfgparser.sh"     /etc/zfsrecvd/cfgparser.sh
cp "$SCRIPT_DIR/send.sh"          /etc/zfsrecvd/send.sh
cp "$SCRIPT_DIR/listen.sh"        /etc/zfsrecvd/listen.sh
cp "$SCRIPT_DIR/zfsrecvd.sh"      /etc/zfsrecvd/zfsrecvd.sh
cp "$SCRIPT_DIR/sendall.sh"       /etc/zfsrecvd/sendsall.sh
cp "$SCRIPT_DIR/zfsrecvd.service" /etc/systemd/system/zfsrecvd.service
rm /etc/zfsrecvd/sends.sh         # old name for sendall.sh

if [[ ! -f /etc/zfsrecvd/zfsrecvd.conf ]]; then
    cp "$SCRIPT_DIR/zfsrecvd.conf" /etc/zfsrecvd/zfsrecvd.conf
fi

chmod 755 /etc/zfsrecvd/*.sh

echo "Files copied. Edit /etc/zfsrecvd/zfsrecvd.conf to configure the service."
echo 
echo "Provide certificates in /etc/zfsrecvd/{server,client}.pem and .key"
echo "Provide public part of CA certificate in /etc/zfsrecvd/ca.pem"
echo "Execute the following commands to enable the service:"
echo
echo "systemctl link /etc/zfsrecvd/zfsrecvd.service && systemctl enable --now zfsrecvd.service"
