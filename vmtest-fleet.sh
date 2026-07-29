#!/usr/bin/env bash
# End-to-end suite for the Final Shape + T worker pool (fleetrun.sh over
# orchestrate.sh's job scheduler). Runs ON the test VM.
# The VM plays orchestrator, sender (its hostname identity), and TWO
# receiver identities at once -- "vmrecv" on 127.0.0.1 and "vmrecv2" on
# 127.0.0.2, same port -- so one tree fans out to two destinations in one
# run, which is exactly the shape T exists for. Ephemeral run listeners
# coexist with the legacy static listener on 5299.
# Assumes: repo in ~/zfsrecvd-src, passwordless sudo, zfs/socat/pv.
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

CN=$(hostname)
RUNPORT=15299
DEST="ztest/recv/$CN/ztest/src"
DEST2="ztest/recv2/$CN/ztest/src"

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
sudo zfs create ztest/recv2
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

# no ssh-keyscan needed: fleet ssh ignores known_hosts entirely (ssh_opts
# in ec2helpers.sh) -- that behavior is itself under test here

cat > ~/fleet-test.conf <<EOF
[options]
user   marton
port   $RUNPORT

[retention]
source        hourly=24 daily=7
destination   hourly=48 daily=30

[hosts]
vmrecv    ssh=marton@localhost   data=localhost   recv=ztest/recv    bind=127.0.0.1
vmrecv2   ssh=marton@localhost   data=127.0.0.2   recv=ztest/recv2   bind=127.0.0.2

[jobs]
$CN   ztest/src   vmrecv
$CN   ztest/src   vmrecv2
EOF

echo "=== T1: --check plan ==="
out=$(/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf --check 2>&1)
rc=$?
check "T1 check rc=0" test "$rc" -eq 0
grep -q "2 jobs, sources: $CN, receivers: vmrecv vmrecv2" <<<"$out" && ok "T1 plan content" || { bad "T1 plan content"; echo "$out"; }

echo "=== T2: bad config rejected ==="
sed 's/vmrecv$/vmrcev/' ~/fleet-test.conf > ~/fleet-bad.conf
out=$(/etc/zfsrecvd/fleetrun.sh -c ~/fleet-bad.conf --check 2>&1)
rc=$?
check "T2 rc=78" test "$rc" -eq 78
grep -q "no recv=" <<<"$out" && ok "T2 message" || { bad "T2 message"; echo "$out"; }

echo "=== T3: full fleet run, one tree fanned out to two receivers ==="
# scripts must be shipped by the run itself (participants need no prior
# deploy). Single-box rig: ship source == target, so mtime/content can't
# prove anything -- but --unlink-first guarantees a fresh inode.
ino_before=$(stat -c %i /etc/zfsrecvd/sendtree.sh)
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet1.log 2>&1
rc=$?
check "T3 rc=0" test "$rc" -eq 0
check "T3 scripts shipped with run" bash -c "[ \"\$(stat -c %i /etc/zfsrecvd/sendtree.sh)\" != \"$ino_before\" ]"
check "T3 data arrived"        sudo zfs list -H "$DEST"
check "T3 deep child arrived"  bash -c "sudo zfs list -H -t snapshot -d 1 -o name $DEST/a/deep | grep -q zfsrecvd-"
check "T3 zvol arrived"        bash -c "sudo zfs list -H -t snapshot -d 1 -o name $DEST/vol | grep -q zfsrecvd-"
check "T3 stamp present"       bash -c "[ \"\$(sudo zfs get -H -o value zfsrecvd:last-recv $DEST)\" != '-' ]"
check "T3 second dest arrived" sudo zfs list -H "$DEST2"
check "T3 second dest stamp"   bash -c "[ \"\$(sudo zfs get -H -o value zfsrecvd:last-recv $DEST2)\" != '-' ]"
grep -q "0 failed" /tmp/fleet1.log && ok "T3 no failures reported" || { bad "T3 failures"; tail -n 30 /tmp/fleet1.log; }

echo "=== T4: teardown left nothing behind ==="
check "T4 run dir removed"     bash -c "! sudo test -e /etc/zfsrecvd/run"
check "T4 run listeners gone"  bash -c "! ss -tln | grep -q ':$RUNPORT '"
check "T4 unit inactive"       bash -c "! systemctl is-active --quiet zfsrecvd-run-vmrecv"
check "T4 unit2 inactive"      bash -c "! systemctl is-active --quiet zfsrecvd-run-vmrecv2"
check "T4 local rundirs gone"  bash -c "! ls -d /tmp/zfsrecvd-fleet.* 2>/dev/null | grep -q ."
static_sum2=$(sudo sha256sum /etc/zfsrecvd/client.pem /etc/zfsrecvd/server.pem /etc/zfsrecvd/ca.pem | sha256sum)
check "T4 static certs untouched" test "$static_sum" = "$static_sum2"
check "T4 legacy listener still up" bash -c 'ss -tln | grep -q ":5299 "'

echo "=== T5: immediate rerun (same minute): idempotent, all up to date ==="
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet2.log 2>&1
rc=$?
check "T5 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet2.log && ok "T5 clean" || { bad "T5 failures"; tail -n 30 /tmp/fleet2.log; }

echo "=== T6: next-minute run with new data: incrementals land on both ==="
last_min=$(date +%H%M)
for _ in $(seq 1 130); do [ "$(date +%H%M)" != "$last_min" ] && break; sleep 1; done
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=4 oflag=direct 2>/dev/null
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet3.log 2>&1
rc=$?
check "T6 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet3.log && ok "T6 clean" || { bad "T6 failures"; tail -n 30 /tmp/fleet3.log; }
n_snaps=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c zfsrecvd-)
check "T6 two run snapshots on dest (got $n_snaps)" test "$n_snaps" -ge 2
n_snaps2=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST2" | grep -c zfsrecvd-)
check "T6 two run snapshots on dest2 (got $n_snaps2)" test "$n_snaps2" -ge 2

echo "=== T7: generated artifacts: retention keep-counts, jobs, workers ==="
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-test.conf --keep >/tmp/fleet4.log 2>&1
rc=$?
check "T7 rc=0" test "$rc" -eq 0
kdir=$(ls -dt /tmp/zfsrecvd-fleet.* 2>/dev/null | head -n 1)
snd_kc=$(grep -A1 '^\[keep-count\]' "$kdir/bundle-$CN/run.conf" 2>/dev/null | tail -n 1)
rcv_kc=$(grep -A1 '^\[keep-count\]' "$kdir/bundle-vmrecv/run.conf" 2>/dev/null | tail -n 1)
check "T7 sender keep-count=24 (got ${snd_kc:-none})"   test "$snd_kc" = "24"
check "T7 receiver keep-count=48 (got ${rcv_kc:-none})" test "$rcv_kc" = "48"
n_jobs=$(grep -c "^$CN " "$kdir/orchestrator.conf" 2>/dev/null)
check "T7 two job rows generated (got ${n_jobs:-0})" test "$n_jobs" = "2"
n_workers=$(grep -A1 '^\[orchestrator-workers\]' "$kdir/orchestrator.conf" 2>/dev/null | tail -n 1)
check "T7 workers default 8 (got ${n_workers:-none})" test "$n_workers" = "8"
rm -rf /tmp/zfsrecvd-fleet.*

echo "=== T8: prune-post trims the source, receivers keep history ==="
# source hourly bucket -> keep-count 1: after the run, prune-post must
# leave exactly one run snapshot on the source tree, while the receivers
# (hourly=48) retain everything received so far.
sed 's/hourly=24/hourly=1/' ~/fleet-test.conf > ~/fleet-prune.conf
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-prune.conf >/tmp/fleet5.log 2>&1
rc=$?
check "T8 rc=0" test "$rc" -eq 0
n_src=$(sudo zfs list -H -t snapshot -d 1 -o name ztest/src | grep -c zfsrecvd-)
check "T8 source pruned to 1 (got $n_src)" test "$n_src" = "1"
n_dst=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c zfsrecvd-)
check "T8 dest history kept (got $n_dst)" test "$n_dst" -ge 2
check "T8 prune logged to source journal" bash -c "sudo journalctl -t zfsrecvd-prune -n 20 --no-pager | grep -q pruning"

echo "=== T9: offline participant is dropped, the rest of the run proceeds ==="
# nosuchuser@localhost: sshd refuses auth instantly, which is the fastest
# deterministic provisioning failure. (A 127.x.y.z address does NOT work
# for this: sshd binds 0.0.0.0, which answers on all of 127/8, and the
# "dead" host would provision onto the VM itself.)
sed '/^vmrecv2/a deadhost  ssh=nosuchuser@localhost   recv=ztest/recv' ~/fleet-test.conf > ~/fleet-offline.conf
echo "$CN   ztest/src   deadhost" >> ~/fleet-offline.conf
/etc/zfsrecvd/fleetrun.sh -c ~/fleet-offline.conf >/tmp/fleet6.log 2>&1
rc=$?
check "T9 rc=1 (degraded run)" test "$rc" -eq 1
grep -q "dropping its jobs" /tmp/fleet6.log && ok "T9 offline host dropped" || { bad "T9 drop message"; tail -n 20 /tmp/fleet6.log; }
grep -q "run summary: 2 jobs, 2 ok" /tmp/fleet6.log && ok "T9 remaining jobs ran clean" || { bad "T9 summary"; tail -n 20 /tmp/fleet6.log; }

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in /tmp/fleet1.log /tmp/fleet2.log /tmp/fleet3.log /tmp/fleet4.log /tmp/fleet5.log /tmp/fleet6.log; do
        [ -f "$f" ] && { echo "--- $f tail ---"; tail -n 25 "$f"; }
    done
    for u in zfsrecvd-run-vmrecv zfsrecvd-run-vmrecv2; do
        echo "--- $u journal ---"
        sudo journalctl -u "$u" -n 30 --no-pager 2>/dev/null | tail -n 30
    done
    exit 1
fi
