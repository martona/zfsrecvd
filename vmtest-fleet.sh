#!/usr/bin/env bash
# End-to-end suite for the Final Shape (fleetrun.sh). Runs ON the test VM.
# The VM plays orchestrator, sender (its hostname identity), and receiver
# (second identity "vmrecv" via localhost) at once; an ephemeral run
# listener on RUNPORT coexists with the legacy static listener on 5299.
# Assumes: repo in ~/zfsrecvd-src, passwordless sudo, zfs/socat/pv.
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

CN=$(hostname)
RUNPORT=15299
DEST="ztest/recv/$CN/ztest/src"

echo "=== setup ==="
sudo systemctl stop "zfsrecvd-run-*" zfsrecvd-test 2>/dev/null
sudo systemctl reset-failed "zfsrecvd-run-*" zfsrecvd-test 2>/dev/null
rm -rf /tmp/zfsrecvd-fleet.* 2>/dev/null
sleep 0.5
sudo zpool destroy ztest 2>/dev/null
sudo rm -rf /dev/zvol/ztest 2>/dev/null
sudo rm -f /var/tmp/ztest.img
sudo rm -rf /etc/zfsrecvd/run
sudo truncate -s 8G /var/tmp/ztest.img
sudo zpool create -f -O mountpoint=none ztest /var/tmp/ztest.img || { echo "pool create failed"; exit 1; }
sudo zfs create ztest/recv
sudo zfs create -p ztest/src/a/deep
sudo zfs create ztest/src/b
sudo zfs create -V 16M ztest/src/vol
for _ in $(seq 1 50); do [ -b /dev/zvol/ztest/src/vol ] && break; sleep 0.2; done
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=8 oflag=direct 2>/dev/null

sudo bash ~/zfsrecvd-src/install.sh >/dev/null

# static conf + certs so the LEGACY listener can run on 5299 (coexistence)
sudo tee /etc/zfsrecvd/zfsrecvd.conf >/dev/null <<EOF
[recv-root]
ztest/recv
[tcp-port]
5299
[tcp-addr]
127.0.0.1
[allowed_hosts]
$CN
EOF
sudo bash -c '
cd /etc/zfsrecvd
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=static-test-ca" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -out server.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN='"$CN"'" 2>/dev/null
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -out client.pem 2>/dev/null
chmod 600 *.key
'
sudo systemd-run --unit=zfsrecvd-test /etc/zfsrecvd/listen.sh >/dev/null 2>&1
sleep 1
check "legacy listener up on 5299" bash -c 'ss -tln | grep -q ":5299 "'
static_sum=$(sudo sha256sum /etc/zfsrecvd/client.pem /etc/zfsrecvd/server.pem /etc/zfsrecvd/ca.pem | sha256sum)

# self-ssh must work for both names fleetrun will dial
ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null
ssh-keyscan -H "$CN" >> ~/.ssh/known_hosts 2>/dev/null

cat > ~/fleet-test.conf <<EOF
[options]
user   marton
port   $RUNPORT

[retention]
source        hourly=24 daily=7
destination   hourly=48 daily=30

[hosts]
vmrecv   ssh=marton@localhost   data=localhost   recv=ztest/recv   bind=127.0.0.1

[jobs]
$CN   ztest/src   vmrecv
EOF

echo "=== T1: --check plan ==="
out=$(/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf --check 2>&1)
rc=$?
check "T1 check rc=0" test "$rc" -eq 0
grep -q "1 jobs, sources: $CN, receivers: vmrecv" <<<"$out" && ok "T1 plan content" || { bad "T1 plan content"; echo "$out"; }

echo "=== T2: bad config rejected ==="
sed 's/vmrecv$/vmrcev/' ~/fleet-test.conf > ~/fleet-bad.conf
out=$(/etc/zfsrecvd/fleetrun.sh -c ~/fleet-bad.conf --check 2>&1)
rc=$?
check "T2 rc=78" test "$rc" -eq 78
grep -q "no recv=" <<<"$out" && ok "T2 message" || { bad "T2 message"; echo "$out"; }

echo "=== T3: full fleet run ==="
# scripts must be shipped by the run itself (participants need no prior
# deploy). Single-box rig: ship source == target, so mtime/content can't
# prove anything -- but --unlink-first guarantees a fresh inode.
ino_before=$(stat -c %i /etc/zfsrecvd/sendall.sh)
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet1.log 2>&1
rc=$?
check "T3 rc=0" test "$rc" -eq 0
check "T3 scripts shipped with run" bash -c "[ \"\$(stat -c %i /etc/zfsrecvd/sendall.sh)\" != \"$ino_before\" ]"
check "T3 data arrived"        sudo zfs list -H "$DEST"
check "T3 deep child arrived"  bash -c "sudo zfs list -H -t snapshot -d 1 -o name $DEST/a/deep | grep -q zfsrecvd-"
check "T3 zvol arrived"        bash -c "sudo zfs list -H -t snapshot -d 1 -o name $DEST/vol | grep -q zfsrecvd-"
check "T3 stamp present"       bash -c "[ \"\$(sudo zfs get -H -o value zfsrecvd:last-recv $DEST)\" != '-' ]"
grep -q "0 failed" /tmp/fleet1.log && ok "T3 no failures reported" || { bad "T3 failures"; tail -n 30 /tmp/fleet1.log; }

echo "=== T4: teardown left nothing behind ==="
check "T4 run dir removed"     bash -c "! sudo test -e /etc/zfsrecvd/run"
check "T4 run listener gone"   bash -c "! ss -tln | grep -q ':$RUNPORT '"
check "T4 unit inactive"       bash -c "! systemctl is-active --quiet zfsrecvd-run-vmrecv"
check "T4 local rundirs gone"  bash -c "! ls -d /tmp/zfsrecvd-fleet.* 2>/dev/null | grep -q ."
static_sum2=$(sudo sha256sum /etc/zfsrecvd/client.pem /etc/zfsrecvd/server.pem /etc/zfsrecvd/ca.pem | sha256sum)
check "T4 static certs untouched" test "$static_sum" = "$static_sum2"
check "T4 legacy listener still up" bash -c 'ss -tln | grep -q ":5299 "'

echo "=== T5: immediate rerun (same minute): idempotent, all up to date ==="
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet2.log 2>&1
rc=$?
check "T5 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet2.log && ok "T5 clean" || { bad "T5 failures"; tail -n 30 /tmp/fleet2.log; }

echo "=== T6: next-minute run with new data: incremental lands ==="
last_min=$(date +%H%M)
for _ in $(seq 1 130); do [ "$(date +%H%M)" != "$last_min" ] && break; sleep 1; done
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=4 oflag=direct 2>/dev/null
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet3.log 2>&1
rc=$?
check "T6 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet3.log && ok "T6 clean" || { bad "T6 failures"; tail -n 30 /tmp/fleet3.log; }
n_snaps=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c zfsrecvd-)
check "T6 two run snapshots on dest (got $n_snaps)" test "$n_snaps" -ge 2

echo "=== T7: retention hourly buckets drive generated keep-counts ==="
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf --keep >/tmp/fleet4.log 2>&1
rc=$?
check "T7 rc=0" test "$rc" -eq 0
kdir=$(ls -dt /tmp/zfsrecvd-fleet.* 2>/dev/null | head -n 1)
snd_kc=$(grep -A1 '^\[keep-count\]' "$kdir/bundle-$CN/run.conf" 2>/dev/null | tail -n 1)
rcv_kc=$(grep -A1 '^\[keep-count\]' "$kdir/bundle-vmrecv/run.conf" 2>/dev/null | tail -n 1)
check "T7 sender keep-count=24 (got ${snd_kc:-none})"   test "$snd_kc" = "24"
check "T7 receiver keep-count=48 (got ${rcv_kc:-none})" test "$rcv_kc" = "48"
rm -rf /tmp/zfsrecvd-fleet.*

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in /tmp/fleet1.log /tmp/fleet2.log /tmp/fleet3.log; do
        [ -f "$f" ] && { echo "--- $f tail ---"; tail -n 25 "$f"; }
    done
    echo "--- run listener journal ---"
    sudo journalctl -u zfsrecvd-run-vmrecv -n 30 --no-pager 2>/dev/null | tail -n 30
    exit 1
fi
