#!/usr/bin/env bash
# zfsrecvd protocol 2.0/2.1 end-to-end test suite. Runs ON the test VM.
# T1-T10 exercise the full transfer machinery (now over a 2.1 session);
# T8 hand-drives a 2.0 session, proving the compat path. T11+ are the
# 2.1 GUID features: unknown-since stamps, the base guid veto,
# rename-aside, cursor catch-up survival, received-bytes.
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

echo "=== T11: receiver-only snapshots get unknown-since; reappearance clears ==="
# (a) a non-prefix snapshot that exists only on the receiver is stamped
sudo zfs snapshot "$DEST/b@recvonly"
# (b) a synced snapshot carrying a stale stamp is cleared (guid reappears)
sudo zfs set zfsrecvd:unknown-since=2026-01-01T00:00:00Z "$DEST/b@s2"
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t11.log 2>&1
rc=$?
check "T11 exit 0" test "$rc" -eq 0
us=$(sudo zfs get -H -s local -o value zfsrecvd:unknown-since "$DEST/b@recvonly" 2>/dev/null)
if [ -n "$us" ] && [ "$us" != "-" ]; then ok "T11 receiver-only snap stamped ($us)"; else bad "T11 stamp missing (got '$us')"; fi
us2=$(sudo zfs get -H -s local -o value zfsrecvd:unknown-since "$DEST/b@s2" 2>/dev/null)
if [ -z "$us2" ] || [ "$us2" = "-" ]; then ok "T11 reappeared snap cleared"; else bad "T11 stale stamp survived ($us2)"; fi
grep -q "receiver-only snapshots" /tmp/t11.log && ok "T11 sender NOTE still emitted" || bad "T11 sender NOTE"
# prefix snaps are the grid's business: none may carry a stamp
pn=$(sudo zfs get -H -r -s local -t snapshot -o name,value zfsrecvd:unknown-since "$DEST" | grep -c "@zfsrecvd-") || pn=0
check "T11 no prefix snap stamped (got $pn)" test "$pn" -eq 0

echo "=== T12: snapshot name reuse -> guid veto -> replanned base ==="
sudo zfs snapshot ztest/src/c@dup
sudo /etc/zfsrecvd/send.sh ztest/src/c@dup localhost >/tmp/t12a.log 2>&1 || bad "T12 seed sync failed"
sudo zfs destroy ztest/src/c@dup
sudo zfs snapshot ztest/src/c@dup          # same name, new guid
sudo zfs snapshot ztest/src/c@dup2
sudo /etc/zfsrecvd/send.sh ztest/src/c@dup2 localhost >/tmp/t12b.log 2>&1
rc=$?
check "T12 exit 0" test "$rc" -eq 0
grep -q "guid mismatch" /tmp/t12b.log && ok "T12 veto refusal observed" || { bad "T12 veto"; cat /tmp/t12b.log; }
grep -q "rebootstrapping" /tmp/t12b.log && ok "T12 collision fallback taken" || { bad "T12 fallback"; cat /tmp/t12b.log; }
cgone=$(sudo zfs list -H -o name | grep -c "^$DEST/c\.gone-") || cgone=0
check "T12 old history renamed aside (got $cgone)" test "$cgone" -eq 1
check "T12 dup2 arrived" sudo zfs list -H "$DEST/c@dup2"
sg=$(sudo zfs get -H -o value guid ztest/src/c@dup)
dg=$(sudo zfs get -H -o value guid "$DEST/c@dup" 2>/dev/null)
check "T12 receiver @dup is now the source's object" test "$sg" = "$dg"

echo "=== T13: recreated dataset and zvol get renamed aside, not clobbered ==="
sudo zfs destroy -r ztest/src/d
sudo zfs create ztest/src/d
sudo zfs snapshot ztest/src/d@n1
sudo /etc/zfsrecvd/send.sh ztest/src/d@n1 localhost >/tmp/t13a.log 2>&1
rc=$?
check "T13 fs exit 0" test "$rc" -eq 0
check "T13 fs newcomer arrived" sudo zfs list -H "$DEST/d@n1"
gone=$(sudo zfs list -H -o name | grep -c "^$DEST/d\.gone-") || gone=0
check "T13 fs old lineage renamed aside (got $gone)" test "$gone" -eq 1
check "T13 fs old history preserved" bash -c "sudo zfs list -H -t snapshot -o name | grep -q '^$DEST/d\.gone-.*@s1'"
# the zvol variant -- pre-2.1 this full -R onto an existing zvol killed
# the session (the known T14-era edge)
sudo zfs destroy -r ztest/src/vol
sudo zfs create -V 16M ztest/src/vol
wait_zvol /dev/zvol/ztest/src/vol
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=4 oflag=direct 2>/dev/null
sudo zfs snapshot ztest/src/vol@vn1
sudo /etc/zfsrecvd/send.sh ztest/src/vol@vn1 localhost >/tmp/t13b.log 2>&1
rc=$?
check "T13 zvol exit 0" test "$rc" -eq 0
check "T13 zvol newcomer arrived" sudo zfs list -H "$DEST/vol@vn1"
vgone=$(sudo zfs list -H -o name | grep -c "^$DEST/vol\.gone-") || vgone=0
check "T13 zvol old lineage renamed aside (got $vgone)" test "$vgone" -eq 1

echo "=== T14: cursor catch-up survives the collision pass (zero snap overlap) ==="
# destroy every source snapshot of e; the cursor bookmark is the only
# lineage evidence left -- the naive zero-overlap rule would rename e
# aside and force a full re-send
sudo zfs list -H -t snapshot -d 1 -o name ztest/src/e | while read -r s; do sudo zfs destroy "$s"; done
sudo zfs snapshot ztest/src/e@fresh
sudo /etc/zfsrecvd/send.sh ztest/src/e@fresh localhost >/tmp/t14.log 2>&1
rc=$?
check "T14 exit 0" test "$rc" -eq 0
grep -q "(cursor catch-up)" /tmp/t14.log && ok "T14 catch-up path taken" || { bad "T14 catch-up"; cat /tmp/t14.log; }
egone=$(sudo zfs list -H -o name | grep -c "^$DEST/e\.gone-") || egone=0
check "T14 e NOT renamed aside (got $egone)" test "$egone" -eq 0
check "T14 e@fresh arrived" sudo zfs list -H "$DEST/e@fresh"

echo "=== T15: received-bytes ride the OK line ==="
wb=$(grep -a "WIRE-BYTES:" /tmp/t13b.log | tail -n 1 | sed 's/.*WIRE-BYTES: //')
if [ -n "$wb" ] && [ "$wb" -gt 0 ] 2>/dev/null; then ok "T15 wire bytes counted ($wb)"; else bad "T15 wire bytes (got '$wb')"; cat /tmp/t13b.log; fi
sudo /etc/zfsrecvd/sendtree.sh ztest/src localhost >/tmp/t15.log 2>&1 || bad "T15 up-to-date run failed"
grep -q "WIRE-BYTES: 0" /tmp/t15.log && ok "T15 up-to-date run counts zero" || { bad "T15 zero"; grep -a "WIRE-BYTES" /tmp/t15.log; }

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo "--- listener journal tail ---"
    sudo journalctl -u zfsrecvd-test -n 40 --no-pager 2>/dev/null | tail -n 40
    exit 1
fi
