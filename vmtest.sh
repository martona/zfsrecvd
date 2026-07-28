#!/usr/bin/env bash
# zfsrecvd protocol 2.0 end-to-end test suite. Runs ON the test VM.
# Assumes: repo scripts in ~/zfsrecvd-src, passwordless sudo, zfs, socat, pv.
# Everything happens in a file-backed pool "ztest"; rpool/bpool untouched.
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

CN=$(hostname)
DEST="ztest/recv/$CN/ztest/src"

# zfs create -V returns before udev makes the device node; dd'ing too early
# would create a REGULAR FILE at that path in devtmpfs and write to the void.
wait_zvol() {
    local i
    for i in $(seq 1 50); do
        [ -b "$1" ] && return 0
        sleep 0.2
    done
    echo "WARNING: zvol node $1 never appeared" >&2
    return 1
}

echo "=== setup ==="
sudo systemctl kill zfsrecvd-test 2>/dev/null
sudo systemctl reset-failed zfsrecvd-test 2>/dev/null
sleep 0.5
sudo zpool destroy ztest 2>/dev/null
sudo rm -rf /dev/zvol/ztest 2>/dev/null   # stale regular-file junk from lost udev races
sudo rm -f /var/tmp/ztest.img
sudo truncate -s 12G /var/tmp/ztest.img
sudo zpool create -f -O mountpoint=none ztest /var/tmp/ztest.img || { echo "pool create failed"; exit 1; }
sudo zfs create ztest/recv

sudo bash ~/zfsrecvd-src/install.sh >/dev/null

sudo tee /etc/zfsrecvd/zfsrecvd.conf >/dev/null <<EOF
[recv-root]
ztest/recv
[tcp-port]
5299
[tcp-addr]
127.0.0.1
[allowed_hosts]
$CN
[keep-count]
6
[prune-prefixes]
zfsrecvd-
EOF

sudo bash -c '
cd /etc/zfsrecvd
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=zfsrecvd-test-ca" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -out server.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN='"$CN"'" 2>/dev/null
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -out client.pem 2>/dev/null
chmod 600 *.key
'

sudo systemd-run --unit=zfsrecvd-test /etc/zfsrecvd/listen.sh >/dev/null 2>&1
sleep 1
check "listener is up on 5299" bash -c 'ss -tln | grep -q :5299'

# source tree: root + nested fs + several small fs + zvol + encrypted fs
sudo zfs create -p ztest/src/a/deep
for d in b c d e f g h i j; do sudo zfs create "ztest/src/$d"; done
sudo zfs create -V 16M ztest/src/vol
wait_zvol /dev/zvol/ztest/src/vol
echo "test-passphrase-123" | sudo tee /var/tmp/ztest.key >/dev/null
sudo zfs create -o encryption=on -o keyformat=passphrase -o keylocation=file:///var/tmp/ztest.key ztest/src/enc
sudo zfs snapshot -r ztest/src@s1

echo "=== T1: initial full replication of the tree ==="
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t1.log 2>&1
rc=$?
check "T1 exit 0" test "$rc" -eq 0
check "T1 nested dataset arrived"  sudo zfs list -H "$DEST/a/deep@s1"
check "T1 zvol arrived"            sudo zfs list -H "$DEST/vol@s1"
check "T1 encrypted arrived raw"   bash -c "[ \"\$(sudo zfs get -H -o value encryption $DEST/enc)\" != off ]"
check "T1 stamp present"           bash -c "[ \"\$(sudo zfs get -H -o value zfsrecvd:last-recv $DEST)\" != '-' ]"
grep -q "14 sent" /tmp/t1.log && ok "T1 counted 14 sent" || { bad "T1 sent count"; cat /tmp/t1.log; }

echo "=== T2: idempotent re-run, all up to date ==="
start=$SECONDS
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t2.log 2>&1
rc=$?
t2_dur=$((SECONDS-start))
check "T2 exit 0" test "$rc" -eq 0
grep -q "0 sent, 14 up to date" /tmp/t2.log && ok "T2 zero sends" || { bad "T2 zero sends"; cat /tmp/t2.log; }
check "T2 fast (<10s, was $t2_dur)" test "$t2_dur" -lt 10

echo "=== T3: incremental ==="
sudo dd if=/dev/zero of=/dev/zvol/ztest/src/vol bs=1M count=8 oflag=direct 2>/dev/null
sudo zfs snapshot -r ztest/src@s2
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t3.log 2>&1
rc=$?
check "T3 exit 0" test "$rc" -eq 0
check "T3 vol@s2 arrived"  sudo zfs list -H "$DEST/vol@s2"
check "T3 deep@s2 arrived" sudo zfs list -H "$DEST/a/deep@s2"

echo "=== T4: new dataset bootstraps with history (oldest, then -I) ==="
sudo zfs create ztest/src/late
sudo zfs snapshot ztest/src/late@old1
sleep 1
sudo zfs snapshot -r ztest/src@s3
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t4.log 2>&1
rc=$?
check "T4 exit 0" test "$rc" -eq 0
check "T4 late@old1 (bootstrap leg)" sudo zfs list -H "$DEST/late@old1"
check "T4 late@s3 (incremental leg)" sudo zfs list -H "$DEST/late@s3"
grep -q "(bootstrap)" /tmp/t4.log && ok "T4 bootstrap announced" || bad "T4 bootstrap announced"

echo "=== T5: interrupt mid-stream, resume via token ==="
sudo zfs create -V 3G ztest/src/big
wait_zvol /dev/zvol/ztest/src/big
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/big bs=1M count=600 oflag=direct 2>/dev/null
sudo zfs snapshot ztest/src/big@s4big
sudo env ZFSRECVD_PV_EXTRA="-L 60M" /etc/zfsrecvd/send.sh ztest/src/big@s4big localhost >/tmp/t5a.log 2>&1 &
bg=$!
for _ in $(seq 1 50); do pgrep -f 'zfs send -R ztest/src/big@s4big' >/dev/null && break; sleep 0.2; done
sleep 1.5
# kill the whole client so its reconnect-and-resume logic cannot self-heal
# before we get to inspect the token
sudo pkill -f 'sendtree.sh --single ztest/src/big@s4big'
sudo pkill -f 'zfs send -R ztest/src/big@s4big'
wait "$bg" 2>/dev/null
sleep 1
tok=$(sudo zfs get -H -o value receive_resume_token "$DEST/big" 2>/dev/null)
if [ -n "$tok" ] && [ "$tok" != "-" ]; then ok "T5 token exists after interrupt"; else bad "T5 token exists after interrupt (tok=$tok)"; cat /tmp/t5a.log; fi
sudo /etc/zfsrecvd/send.sh ztest/src/big@s4big localhost >/tmp/t5b.log 2>&1
rc=$?
check "T5 resume run exit 0" test "$rc" -eq 0
grep -q "(resume)" /tmp/t5b.log && ok "T5 resume path taken" || { bad "T5 resume path taken"; cat /tmp/t5b.log; }
check "T5 big@s4big complete" sudo zfs list -H "$DEST/big@s4big"
tok=$(sudo zfs get -H -o value receive_resume_token "$DEST/big" 2>/dev/null)
check "T5 token cleared" test "$tok" = "-"

echo "=== T6: unsatisfiable token gets ABORTed ==="
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/big bs=1M count=400 seek=700 oflag=direct 2>/dev/null
sudo zfs snapshot ztest/src/big@s5big
sudo env ZFSRECVD_PV_EXTRA="-L 60M" /etc/zfsrecvd/send.sh ztest/src/big@s5big localhost >/tmp/t6a.log 2>&1 &
bg=$!
for _ in $(seq 1 50); do pgrep -f 'zfs send.*ztest/src/big@s5big' >/dev/null && break; sleep 0.2; done
sleep 1.5
sudo pkill -f 'sendtree.sh --single ztest/src/big@s5big'
sudo pkill -f 'zfs send.*ztest/src/big@s5big'
wait "$bg" 2>/dev/null
sleep 1
tok=$(sudo zfs get -H -o value receive_resume_token "$DEST/big" 2>/dev/null)
if [ -n "$tok" ] && [ "$tok" != "-" ]; then ok "T6 token exists"; else bad "T6 token exists (tok=$tok)"; cat /tmp/t6a.log; fi
sudo zfs destroy ztest/src/big@s5big
sudo /etc/zfsrecvd/send.sh ztest/src/big localhost >/tmp/t6b.log 2>&1
rc=$?
check "T6 exit 0 after abort" test "$rc" -eq 0
grep -q "not satisfiable" /tmp/t6b.log && ok "T6 abort path taken" || { bad "T6 abort path taken"; cat /tmp/t6b.log; }
tok=$(sudo zfs get -H -o value receive_resume_token "$DEST/big" 2>/dev/null)
check "T6 token cleared" test "$tok" = "-"

echo "=== T7: pruning keeps 6 zfsrecvd-* snapshots each side ==="
for i in 1 2 3 4 5 6 7 8; do
    sudo zfs snapshot -r "ztest/src@zfsrecvd-2026-07-27-10${i}0Z"
    sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >"/tmp/t7-$i.log" 2>&1 || bad "T7 run $i failed"
done
src_n=$(sudo zfs list -H -t snapshot -d 1 -o name ztest/src | grep -c '@zfsrecvd-')
dst_n=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c '@zfsrecvd-')
check "T7 source pruned to 6 (got $src_n)" test "$src_n" -eq 6
check "T7 dest pruned to 6 (got $dst_n)" test "$dst_n" -eq 6
check "T7 non-prefixed s1 survived on dest" sudo zfs list -H "$DEST@s1"

echo "=== T8: multi-TREE control session + refusal, hand-driven ==="
{ printf 'zfsrecvd2.0\nTREE ztest/src zfsrecvd-2026-07-27-1080Z\nDS ztest/src\n\nSEND ztest/other - nope -\nENDTREE\nTREE ztest/src zfsrecvd-2026-07-27-1080Z\nDS ztest/src\n\nENDTREE\nBYE\n'; sleep 3; } \
    | sudo openssl s_client -connect localhost:5299 -CAfile /etc/zfsrecvd/ca.pem \
        -cert /etc/zfsrecvd/client.pem -key /etc/zfsrecvd/client.key -quiet 2>/dev/null >/tmp/t8.log
check "T8 greeting"        grep -q "OK zfsrecvd2.0" /tmp/t8.log
check "T8 out-of-tree refused" grep -q "ERR refused ztest/other" /tmp/t8.log
n_oktree=$(grep -c "OK TREE" /tmp/t8.log)
n_okend=$(grep -c "OK ENDTREE" /tmp/t8.log)
check "T8 two TREEs accepted (got $n_oktree)" test "$n_oktree" -eq 2
check "T8 two ENDTREEs (got $n_okend)" test "$n_okend" -eq 2

echo "=== T9: bad version is rejected ==="
{ printf 'zfsrecvd1.1\nztest/src@s1\n\n'; sleep 1; } \
    | sudo openssl s_client -connect localhost:5299 -CAfile /etc/zfsrecvd/ca.pem \
        -cert /etc/zfsrecvd/client.pem -key /etc/zfsrecvd/client.key -quiet 2>/dev/null >/tmp/t9.log
if grep -q "OK" /tmp/t9.log; then bad "T9 v1.1 wrongly accepted"; else ok "T9 v1.1 rejected"; fi

echo "=== T10: timing snapshot ==="
start=$SECONDS
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t10.log 2>&1
t10=$((SECONDS-start))
n_ds=$(sudo zfs list -H -r -t filesystem,volume ztest/src | wc -l)
echo "INFO: up-to-date run over $n_ds datasets took ${t10}s"
check "T10 up-to-date run <8s (took $t10)" test "$t10" -lt 8

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo "--- listener journal tail ---"
    sudo journalctl -u zfsrecvd-test -n 40 --no-pager 2>/dev/null | tail -n 40
    exit 1
fi
