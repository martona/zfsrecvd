#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p /etc/zfsrecvd
cp "$SCRIPT_DIR/cfgparser.sh"     /etc/zfsrecvd/
cp "$SCRIPT_DIR/orchestrate.sh"   /etc/zfsrecvd/
cp "$SCRIPT_DIR/sendall.sh"       /etc/zfsrecvd/
cp "$SCRIPT_DIR/sendtree.sh"      /etc/zfsrecvd/
cp "$SCRIPT_DIR/send.sh"          /etc/zfsrecvd/
cp "$SCRIPT_DIR/listen.sh"        /etc/zfsrecvd/
cp "$SCRIPT_DIR/zfsrecvd.sh"      /etc/zfsrecvd/
cp "$SCRIPT_DIR/run_indented.sh"  /etc/zfsrecvd/
cp "$SCRIPT_DIR/zfsrecvd.service" /etc/systemd/system/zfsrecvd.service

if [[ ! -f /etc/zfsrecvd/zfsrecvd.conf ]]; then
    cp "$SCRIPT_DIR/zfsrecvd.conf" /etc/zfsrecvd/zfsrecvd.conf
fi

chmod 755 /etc/zfsrecvd/*.sh

echo "Files copied. Edit /etc/zfsrecvd/zfsrecvd.conf to configure the service."
echo 
echo "Provide certificates in /etc/zfsrecvd/{server,client}.pem and .key"
echo "Provide public part of CA certificate in /etc/zfsrecvd/ca.pem"
echo "Execute the following command to enable the service:"
echo
echo "systemctl enable --now zfsrecvd.service"
