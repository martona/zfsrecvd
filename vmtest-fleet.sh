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
sudo systemctl stop "stevedore-run-*" "stevedore-ha-*" stevedore-test 2>/dev/null
sudo systemctl reset-failed "stevedore-run-*" "stevedore-ha-*" stevedore-test 2>/dev/null
rm -rf /tmp/stevedore-fleet.* 2>/dev/null
sleep 0.5
sudo zpool destroy ztest 2>/dev/null
sudo rm -rf /dev/zvol/ztest 2>/dev/null
sudo rm -f /var/tmp/ztest.img
sudo rm -rf /run/stevedore
sudo truncate -s 8G /var/tmp/ztest.img
sudo zpool create -f -O mountpoint=none ztest /var/tmp/ztest.img || { echo "pool create failed"; exit 1; }
sudo zfs create ztest/recv
sudo zfs create ztest/recv2
sudo zfs create -p ztest/src/a/deep
sudo zfs create ztest/src/b
sudo zfs create -V 16M ztest/src/vol
for _ in $(seq 1 50); do [ -b /dev/zvol/ztest/src/vol ] && break; sleep 0.2; done
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=8 oflag=direct 2>/dev/null

sudo bash ~/zfsrecvd-src/stevedore.sh install >/dev/null

# static conf + certs so the LEGACY listener can run on 5299 (coexistence)
sudo tee /etc/stevedore/stevedore.conf >/dev/null <<EOF
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
cd /etc/stevedore
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=static-test-ca" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -out server.pem 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN='"$CN"'" 2>/dev/null
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -out client.pem 2>/dev/null
chmod 600 *.key
'
sudo systemd-run --unit=stevedore-test /usr/local/lib/stevedore/stevedore-listen.sh >/dev/null 2>&1
sleep 1
check "legacy listener up on 5299" bash -c 'ss -tln | grep -q ":5299 "'
static_sum=$(sudo sha256sum /etc/stevedore/client.pem /etc/stevedore/server.pem /etc/stevedore/ca.pem | sha256sum)

# no ssh-keyscan needed: fleet ssh ignores known_hosts entirely (ssh_opts
# in ec2helpers.sh) -- that behavior is itself under test here

cat > ~/fleet-test.conf <<EOF
[options]
user   marton
port   $RUNPORT

[retention]
source        hourly=24
destination   hourly=48 daily=30

[hosts]
vmrecv    ssh=marton@localhost   data=localhost   recv=ztest/recv    bind=127.0.0.1
vmrecv2   ssh=marton@localhost   data=127.0.0.2   recv=ztest/recv2   bind=127.0.0.2

[jobs]
$CN   ztest/src   vmrecv
$CN   ztest/src   vmrecv2
EOF

echo "=== T1: --check plan ==="
out=$(/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf --check 2>&1)
rc=$?
check "T1 check rc=0" test "$rc" -eq 0
grep -q "2 jobs, sources: $CN, receivers: vmrecv vmrecv2" <<<"$out" && ok "T1 plan content" || { bad "T1 plan content"; echo "$out"; }

echo "=== T2: bad config rejected ==="
sed 's/vmrecv$/vmrcev/' ~/fleet-test.conf > ~/fleet-bad.conf
out=$(/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-bad.conf --check 2>&1)
rc=$?
check "T2 rc=78" test "$rc" -eq 78
grep -q "no recv=" <<<"$out" && ok "T2 message" || { bad "T2 message"; echo "$out"; }

echo "=== T3: full fleet run, one tree fanned out to two receivers ==="
# scripts must be shipped by the run itself (participants need no prior
# deploy). Single-box rig: ship source == target, so mtime/content can't
# prove anything -- but --unlink-first guarantees a fresh inode.
ino_before=$(stat -c %i /usr/local/lib/stevedore/stevedore-sendtree.sh)
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet1.log 2>&1
rc=$?
check "T3 rc=0" test "$rc" -eq 0
check "T3 scripts shipped with run" bash -c "[ \"\$(stat -c %i /usr/local/lib/stevedore/stevedore-sendtree.sh)\" != \"$ino_before\" ]"
check "T3 data arrived"        sudo zfs list -H "$DEST"
check "T3 deep child arrived"  bash -c "sudo zfs list -H -t snapshot -d 1 -o name $DEST/a/deep | grep -q stevedore-"
check "T3 zvol arrived"        bash -c "sudo zfs list -H -t snapshot -d 1 -o name $DEST/vol | grep -q stevedore-"
check "T3 stamp present"       bash -c "[ \"\$(sudo zfs get -H -o value stevedore:last-recv $DEST)\" != '-' ]"
check "T3 second dest arrived" sudo zfs list -H "$DEST2"
check "T3 second dest stamp"   bash -c "[ \"\$(sudo zfs get -H -o value stevedore:last-recv $DEST2)\" != '-' ]"
grep -q "0 failed" /tmp/fleet1.log && ok "T3 no failures reported" || { bad "T3 failures"; tail -n 30 /tmp/fleet1.log; }

echo "=== T4: teardown left nothing behind ==="
check "T4 run dir removed"     bash -c "! sudo test -e /run/stevedore"
check "T4 run listeners gone"  bash -c "! ss -tln | grep -q ':$RUNPORT '"
check "T4 unit inactive"       bash -c "! systemctl is-active --quiet stevedore-run-vmrecv"
check "T4 unit2 inactive"      bash -c "! systemctl is-active --quiet stevedore-run-vmrecv2"
check "T4 local rundirs gone"  bash -c "! ls -d /tmp/stevedore-fleet.* 2>/dev/null | grep -q ."
static_sum2=$(sudo sha256sum /etc/stevedore/client.pem /etc/stevedore/server.pem /etc/stevedore/ca.pem | sha256sum)
check "T4 static certs untouched" test "$static_sum" = "$static_sum2"
check "T4 legacy listener still up" bash -c 'ss -tln | grep -q ":5299 "'
check "T4 teardown quiet (no spurious warnings)" bash -c "! grep -q 'WARNING.*still active' /tmp/fleet1.log && ! grep -q 'could not stop' /tmp/fleet1.log"

echo "=== T5: immediate rerun (same minute): idempotent, all up to date ==="
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet2.log 2>&1
rc=$?
check "T5 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet2.log && ok "T5 clean" || { bad "T5 failures"; tail -n 30 /tmp/fleet2.log; }

echo "=== T6: next-minute run with new data: incrementals land on both ==="
last_min=$(date +%H%M)
for _ in $(seq 1 130); do [ "$(date +%H%M)" != "$last_min" ] && break; sleep 1; done
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=4 oflag=direct 2>/dev/null
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet3.log 2>&1
rc=$?
check "T6 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet3.log && ok "T6 clean" || { bad "T6 failures"; tail -n 30 /tmp/fleet3.log; }
n_snaps=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c stevedore-)
check "T6 two run snapshots on dest (got $n_snaps)" test "$n_snaps" -ge 2
n_snaps2=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST2" | grep -c stevedore-)
check "T6 two run snapshots on dest2 (got $n_snaps2)" test "$n_snaps2" -ge 2

echo "=== T7: generated artifacts: retention keep-counts, jobs, workers ==="
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf --keep >/tmp/fleet4.log 2>&1
rc=$?
check "T7 rc=0" test "$rc" -eq 0
kdir=$(ls -dt /tmp/stevedore-fleet.* 2>/dev/null | head -n 1)
snd_kc=$(grep -A1 '^\[keep-count\]' "$kdir/bundle-$CN/run.conf" 2>/dev/null | tail -n 1)
rcv_kc=$(grep -A1 '^\[keep-count\]' "$kdir/bundle-vmrecv/run.conf" 2>/dev/null | tail -n 1)
check "T7 sender keep-count=24 (got ${snd_kc:-none})"   test "$snd_kc" = "24"
check "T7 receiver keep-count=48 (got ${rcv_kc:-none})" test "$rcv_kc" = "48"
n_jobs=$(grep -c "^$CN " "$kdir/orchestrator.conf" 2>/dev/null)
check "T7 two job rows generated (got ${n_jobs:-0})" test "$n_jobs" = "2"
n_workers=$(grep -A1 '^\[orchestrator-workers\]' "$kdir/orchestrator.conf" 2>/dev/null | tail -n 1)
check "T7 workers default 8 (got ${n_workers:-none})" test "$n_workers" = "8"
rm -rf /tmp/stevedore-fleet.*

echo "=== T8: prune-post trims the source, receivers keep history ==="
# source hourly bucket -> keep-count 1: after the run, prune-post must
# leave exactly one run snapshot on the source tree, while the receivers
# (hourly=48) retain everything received so far.
sed 's/hourly=24/hourly=1/' ~/fleet-test.conf > ~/fleet-prune.conf
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-prune.conf >/tmp/fleet5.log 2>&1
rc=$?
check "T8 rc=0" test "$rc" -eq 0
n_src=$(sudo zfs list -H -t snapshot -d 1 -o name ztest/src | grep -c stevedore-)
check "T8 source pruned to 1 (got $n_src)" test "$n_src" = "1"
n_dst=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c stevedore-)
check "T8 dest history kept (got $n_dst)" test "$n_dst" -ge 2
check "T8 prune lines in headless output" grep -q "pruning ztest/src@" /tmp/fleet5.log

echo "=== T9: offline participant is dropped, the rest of the run proceeds ==="
# nosuchuser@localhost: sshd refuses auth instantly, which is the fastest
# deterministic provisioning failure. (A 127.x.y.z address does NOT work
# for this: sshd binds 0.0.0.0, which answers on all of 127/8, and the
# "dead" host would provision onto the VM itself.)
sed '/^vmrecv2/a deadhost  ssh=nosuchuser@localhost   recv=ztest/recv' ~/fleet-test.conf > ~/fleet-offline.conf
echo "$CN   ztest/src   deadhost" >> ~/fleet-offline.conf
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-offline.conf >/tmp/fleet6.log 2>&1
rc=$?
check "T9 rc=1 (degraded run)" test "$rc" -eq 1
grep -q "dropping its jobs" /tmp/fleet6.log && ok "T9 offline host dropped" || { bad "T9 drop message"; tail -n 20 /tmp/fleet6.log; }
grep -q "run summary: 2 jobs, 2 ok" /tmp/fleet6.log && ok "T9 remaining jobs ran clean" || { bad "T9 summary"; tail -n 20 /tmp/fleet6.log; }

echo "=== T10: haproxy transport: TLS via haproxy, identity via PP2 ==="
# data landing at all proves the PP2 path end to end: in haproxy mode
# there is no TLS env var, so the CN the allowed_hosts check passes can
# only have come from a real haproxy-emitted PROXY v2 header.
sed '/^port/a transport   haproxy' ~/fleet-test.conf > ~/fleet-ha.conf
last_min=$(date +%H%M)
for _ in $(seq 1 130); do [ "$(date +%H%M)" != "$last_min" ] && break; sleep 1; done
sudo dd if=/dev/urandom of=/dev/zvol/ztest/src/vol bs=1M count=4 oflag=direct 2>/dev/null
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-ha.conf >/tmp/fleet7.log 2>&1
rc=$?
check "T10 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet7.log && ok "T10 clean" || { bad "T10 failures"; tail -n 40 /tmp/fleet7.log; }
# count-based assertions are wrong under the grid (same-hour snaps thin
# to rep+frontier); what matters is that the NEW snapshot arrived.
new_src=$(sudo zfs list -H -t snapshot -d 1 -o name ztest/src | tail -n 1); new_src="${new_src#*@}"
sudo zfs list -H -t snapshot -d 1 -o name "$DEST"  | grep -q "@$new_src\$" && ok "T10 new snapshot on dest"  || bad "T10 dest missing $new_src"
sudo zfs list -H -t snapshot -d 1 -o name "$DEST2" | grep -q "@$new_src\$" && ok "T10 new snapshot on dest2" || bad "T10 dest2 missing $new_src"

echo "=== T11: haproxy teardown ==="
check "T11 ha unit (sender) gone"   bash -c "! systemctl is-active --quiet stevedore-ha-$CN"
check "T11 ha unit vmrecv gone"     bash -c "! systemctl is-active --quiet stevedore-ha-vmrecv"
check "T11 ha unit vmrecv2 gone"    bash -c "! systemctl is-active --quiet stevedore-ha-vmrecv2"
check "T11 no run ports left"       bash -c "! ss -tln | grep -E ':(15299|15300|15301|15363|15364) ' | grep -q ."
check "T11 teardown quiet (no spurious warnings)" bash -c "! grep -q 'WARNING.*still active' /tmp/fleet7.log && ! grep -q 'could not stop' /tmp/fleet7.log"

echo "=== T12: retention grid thins the receiver at ENDTREE ==="
# The suite's real snapshots all live in one UTC hour, where hourly=N
# correctly keeps rep+frontier and thins nothing -- so fabricate
# yesterday's history by NAME (names are the grid's clock) and assert
# hourly=1 culls it while the frontier survives.
sudo zfs snapshot "$DEST@stevedore-2026-07-28-0800Z"
sudo zfs snapshot "$DEST@stevedore-2026-07-28-0900Z"
sudo zfs snapshot "$DEST@keepme-manual"
sed 's/^destination.*/destination   hourly=1/' ~/fleet-test.conf > ~/fleet-grid.conf
pre=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c stevedore-)
STEVEDORE_SHOW_PRUNES=1 /usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-grid.conf >/tmp/fleet8.log 2>&1
rc=$?
check "T12 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet8.log && ok "T12 clean" || { bad "T12 failures"; tail -n 30 /tmp/fleet8.log; }
post=$(sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -c stevedore-)
check "T12 dest thinned ($pre -> $post)" test "$post" -lt "$pre"
check "T12 yesterday's fakes culled" bash -c "! sudo zfs list -H -t snapshot -d 1 -o name $DEST | grep -q 2026-07-28-0"
check "T12 frontier survived (got $post)" test "$post" -ge 1
check "T12 manual snap untouched by grid" sudo zfs list -H "$DEST@keepme-manual"
grep -q "receiver-only snapshots" /tmp/fleet8.log && bad "T12 retired NOTE still prints" || ok "T12 receiver-only NOTE retired"
us=$(sudo zfs get -H -s local -o value stevedore:unknown-since "$DEST@keepme-manual" 2>/dev/null)
if [ -n "$us" ] && [ "$us" != "-" ]; then ok "T12 manual snap stamped unknown-since"; else bad "T12 stamp missing (got '$us')"; fi
grep -q "^GC-TRACK: " /tmp/fleet8.log && bad "T12 track lines leaked to console" || ok "T12 track lines off the console"
grep -q "gc: \[vmrecv\]" /tmp/fleet8.log && ok "T12 gc stage ran" || { bad "T12 gc stage"; tail -n 20 /tmp/fleet8.log; }
RJ="/var/lib/stevedore/runs.jsonl"
check "T12 runs.jsonl written" test -s "$RJ"
grep -q '"state":"done","rc":"0"' "$RJ" && ok "T12 jsonl records ok jobs" || { bad "T12 jsonl content"; tail -n 3 "$RJ"; }
grep -qF '{"id":"vmrecv","before":' "$RJ" && ok "T12 jsonl recv space data" || { bad "T12 recv data"; tail -n 2 "$RJ"; }
grep -q "report: \[vmrecv\] net" /tmp/fleet8.log && bad "T12 console report lines still print" || ok "T12 console report lines gone"
grep -q "\"kind\":\"run\"" "$RJ" && ok "T12 jsonl run record" || { bad "T12 run record"; tail -n 2 "$RJ"; }
grep -q "GC:   all quiet:" /tmp/fleet8.log && ok "T12 gc all-quiet rollup" || { bad "T12 rollup"; grep -a "GC:" /tmp/fleet8.log | head -n 5; }
grep -qF '","gc":"' "$RJ" && ok "T12 gc harvested into jsonl" || { bad "T12 gc jsonl"; tail -n 1 "$RJ"; }
grep -qF "{\"id\":\"$CN\",\"tree\":\"ztest/src\"" "$RJ" && ok "T12 jsonl source space data" || { bad "T12 src data"; tail -n 1 "$RJ"; }
grep -qF '"gc":"track ' "$RJ" && ok "T12 track inventory in jsonl" || { bad "T12 track jsonl"; tail -n 1 "$RJ"; }
rout=$(/usr/local/lib/stevedore/stevedore-report.sh 2>/dev/null)
grep -q "last run: run-" <<<"$rout" && ok "T12 report.sh renders" || { bad "T12 report.sh"; /usr/local/lib/stevedore/stevedore-report.sh 2>&1 | head -n 5; }
grep -q "track .*@keepme-manual" <<<"$rout" && bad "T12 track shown without --gc-debug" || ok "T12 track hidden by default"
rdbg=$(/usr/local/lib/stevedore/stevedore-report.sh --gc-debug 2>/dev/null)
grep -q "gc \[vmrecv\] track .*@keepme-manual: unknown-since" <<<"$rdbg" && ok "T12 --gc-debug surfaces the inventory" || { bad "T12 gc-debug"; grep "gc \[" <<<"$rdbg" | head -n 6; }
grep -qE "^  receiver +net +pruned +avail$" <<<"$rout" && ok "T12 report.sh receiver table" || { bad "T12 recv table"; echo "$rout" | head -n 12; }
grep -q "  gc \[" <<<"$rout" && ok "T12 report.sh gc section" || { bad "T12 gc section"; echo "$rout" | head -n 20; }
grep -q "pruned: \[vmrecv\] .*@stevedore-2026-07-28-0800Z" /tmp/fleet8.log && ok "T12 SHOW_PRUNES names the destroyed" || { bad "T12 show prunes"; grep -a "pruned:" /tmp/fleet8.log | head -n 5; }

echo "=== T13: replication cursors: exactly one per (dataset, dest) ==="
n_c1=$(sudo zfs list -H -t bookmark -d 1 -o name ztest/src | grep -c '#stevedore-vmrecv-')
n_c2=$(sudo zfs list -H -t bookmark -d 1 -o name ztest/src | grep -c '#stevedore-vmrecv2-')
check "T13 one cursor for vmrecv (got $n_c1)"  test "$n_c1" = "1"
check "T13 one cursor for vmrecv2 (got $n_c2)" test "$n_c2" = "1"

echo "=== T14: cursor catch-up after total source snapshot loss ==="
# destroy EVERY source snapshot (bookmarks survive); the next run has no
# common snapshot and must send -i from the cursor instead of a full.
sudo zfs list -H -t snapshot -r -o name ztest/src | while read -r s; do sudo zfs destroy "$s"; done
last_min=$(date +%H%M)
for _ in $(seq 1 130); do [ "$(date +%H%M)" != "$last_min" ] && break; sleep 1; done
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet9.log 2>&1
rc=$?
check "T14 rc=0" test "$rc" -eq 0
grep -q "0 failed" /tmp/fleet9.log && ok "T14 clean" || { bad "T14 failures"; tail -n 40 /tmp/fleet9.log; }
grep -q "(cursor catch-up)" /tmp/fleet9.log && ok "T14 cursor path taken" || { bad "T14 no cursor path"; grep -a "ztest/src " /tmp/fleet9.log | tail -n 10; }
new_src=$(sudo zfs list -H -t snapshot -d 1 -o name ztest/src | tail -n 1); new_src="${new_src#*@}"
sudo zfs list -H -t snapshot -d 1 -o name "$DEST" | grep -q "@$new_src\$" && ok "T14 catch-up landed on dest" || bad "T14 dest missing $new_src"

echo "=== T15: orphan GC, warn-only (server owns clocks; gc renders phases) ==="
sudo zfs create ztest/recv/$CN/oldcrap
sudo zfs create ztest/recv/$CN/stale
# canaries sit at CN level, OUTSIDE any session tree -- no run touches
# their clocks, so a manual orphan-since stands in for a server stamp
sudo zfs set "stevedore:orphan-since=$(date -u +%Y-%m-%dT%H:%M:%SZ)" ztest/recv/$CN/stale
# deep unstamped child under a STAMPED parent: inherited properties must
# not cloak it (the owner's no-such-zvol find). It gets a snapshot so it
# enters the server's state model -- SNAPLESS datasets are outside it
# (§5) and stay in the UNSTAMPED listing instead of being clocked.
sudo zfs create "$DEST/deepcrap"
sudo zfs snapshot "$DEST/deepcrap@junk"
out=$(sudo env STEVEDORE_CONF=/etc/stevedore/stevedore.conf /usr/local/lib/stevedore/stevedore-gc.sh 2>&1)
grep -q "oldcrap: UNSTAMPED" <<<"$out" && ok "T15 unstamped crap surfaced" || { bad "T15 unstamped"; echo "$out"; }
grep -q "deepcrap: UNSTAMPED" <<<"$out" && ok "T15 deep unstamped not cloaked by inheritance" || { bad "T15 deepcrap"; echo "$out"; }
grep -q "/ztest: UNSTAMPED" <<<"$out" && bad "T15 container noise" || ok "T15 containers stay quiet"
grep -q "stale: ABSENT AT SOURCE" <<<"$out" && bad "T15 warned inside the quiet window" || ok "T15 day-0 clock quiet on console"
grep -q "GC-TRACK: ztest/recv/$CN/stale: orphan-since" <<<"$out" && ok "T15 clock tracked from day 0" || { bad "T15 track"; echo "$out"; }
out2=$(sudo env STEVEDORE_GC_WARN_DAYS=0 STEVEDORE_CONF=/etc/stevedore/stevedore.conf /usr/local/lib/stevedore/stevedore-gc.sh 2>&1)
grep -q "stale: ABSENT AT SOURCE -- since .*eligible for reclaim in" <<<"$out2" && ok "T15 warn knob brings the click forward" || { bad "T15 warn knob"; echo "$out2"; }
grep -q "datasets, newest recv" <<<"$out2" && ok "T15 warned CN gets its summary line" || { bad "T15 summary"; echo "$out2"; }
out3=$(sudo env STEVEDORE_GC_GRACE_DAYS=0 STEVEDORE_CONF=/etc/stevedore/stevedore.conf /usr/local/lib/stevedore/stevedore-gc.sh 2>&1)
grep -q "stale: RECLAIM-ELIGIBLE" <<<"$out3" && ok "T15 grace knob turns down" || { bad "T15 knob"; echo "$out3"; }
check "T15 nothing destroyed" sudo zfs list -H ztest/recv/$CN/oldcrap ztest/recv/$CN/stale

echo "=== T16: GC knobs forward through fleetrun over ssh ==="
STEVEDORE_GC_WARN_DAYS=0 STEVEDORE_GC_GRACE_DAYS=0 /usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-test.conf >/tmp/fleet10.log 2>&1
rc=$?
check "T16 rc=0" test "$rc" -eq 0
grep -q "stale: RECLAIM-ELIGIBLE" /tmp/fleet10.log && ok "T16 knobs reached the receiver" || { bad "T16 knobs"; grep -a "GC:" /tmp/fleet10.log | head -n 8; }
# the run itself must have clocked the in-tree manifest-absent canary
dos=$(sudo zfs get -H -s local -o value stevedore:orphan-since "$DEST/deepcrap" 2>/dev/null)
if [ -n "$dos" ] && [ "$dos" != "-" ]; then ok "T16 manifest-absent dataset clocked by the run"; else bad "T16 deepcrap unclocked (got '$dos')"; fi

echo "=== T17: ec2 cadence: fresh destinations skip; --force-ec2 overrides ==="
# T16's run just succeeded for both receivers, so the ledger is fresh.
# 24h cadence on vmrecv2: its one job must skip; vmrecv still runs, and
# the skipped host is not provisioned at all (the EC2-wake-skip path is
# the same structural exclusion; the rig has no ec2= host to prove it on).
sed 's/^vmrecv2 /vmrecv2 cadence=24h /' ~/fleet-test.conf > ~/fleet-cad.conf
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-cad.conf >/tmp/fleet11.log 2>&1
rc=$?
check "T17 rc=0 (skip is not a failure)" test "$rc" -eq 0
grep -q "cadence: \[vmrecv2\] 1 job(s) within 24h" /tmp/fleet11.log && ok "T17 skip announced" || { bad "T17 announce"; grep -a "cadence" /tmp/fleet11.log; }
grep -q "starting run listener on \[vmrecv2\]" /tmp/fleet11.log && bad "T17 skipped host was provisioned" || ok "T17 skipped host left alone"
grep -q "0 failed" /tmp/fleet11.log && ok "T17 surviving jobs clean" || { bad "T17 failures"; tail -n 20 /tmp/fleet11.log; }
grep -qF '"dst":"vmrecv2","state":"cadence"' "$RJ" && ok "T17 cadence state in jsonl" || { bad "T17 jsonl"; tail -n 3 "$RJ"; }
/usr/local/lib/stevedore/stevedore-report.sh 2>/dev/null | grep -q "1 within cadence" && ok "T17 report shows the skip" || { bad "T17 report"; /usr/local/lib/stevedore/stevedore-report.sh 2>&1 | head -n 8; }

# --force-ec2 overrides the window
/usr/local/lib/stevedore/stevedore-fleetrun.sh --force-ec2 -c ~/fleet-cad.conf >/tmp/fleet12.log 2>&1
rc=$?
check "T17 force rc=0" test "$rc" -eq 0
grep -q "cadence: overridden by --force-ec2" /tmp/fleet12.log && ok "T17 override announced" || { bad "T17 override"; grep -a "cadence" /tmp/fleet12.log; }
grep -q "starting run listener on \[vmrecv2\]" /tmp/fleet12.log && ok "T17 forced host runs" || { bad "T17 forced"; tail -n 20 /tmp/fleet12.log; }
grep -q "0 failed" /tmp/fleet12.log && ok "T17 forced run clean" || { bad "T17 forced failures"; tail -n 20 /tmp/fleet12.log; }

# cadence on BOTH receivers: the whole run is a policy no-op, rc 0; the
# ledger stays grouped (cadence lines + a bare run record follow them)
sed -e 's/^vmrecv /vmrecv cadence=24h /' -e 's/^vmrecv2 /vmrecv2 cadence=24h /' ~/fleet-test.conf > ~/fleet-cad2.conf
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-cad2.conf >/tmp/fleet13.log 2>&1
rc=$?
check "T17 all-skip rc=0" test "$rc" -eq 0
grep -q "nothing to do" /tmp/fleet13.log && ok "T17 all-skip announced" || { bad "T17 all-skip"; tail -n 10 /tmp/fleet13.log; }
grep -q "minted run CA" /tmp/fleet13.log && bad "T17 all-skip still provisioned" || ok "T17 all-skip provisions nothing"
/usr/local/lib/stevedore/stevedore-report.sh 2>/dev/null | grep -q "0 ok, 0 not ok, 2 within cadence" && ok "T17 all-skip report tally" || { bad "T17 tally"; /usr/local/lib/stevedore/stevedore-report.sh 2>&1 | head -n 5; }

# an UNREACHABLE source with a stale tuple must not force the wake
# (owner: sometimes-offline sources would otherwise keep EC2 awake
# forever); its cadence-dest jobs skip with the window not consulted.
# nosuchuser@localhost refuses auth instantly (T9 precedent).
cp ~/fleet-cad.conf ~/fleet-cad3.conf
printf '[hosts]\nnosuchsrc ssh=nosuchuser@localhost\n[jobs]\nnosuchsrc ztest/src vmrecv2\n' >> ~/fleet-cad3.conf
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-cad3.conf >/tmp/fleet15.log 2>&1
rc=$?
check "T17 offline-source rc=0" test "$rc" -eq 0
grep -q "cadence: source \[nosuchsrc\] unreachable" /tmp/fleet15.log && ok "T17 offline source announced" || { bad "T17 offline announce"; grep -a "cadence" /tmp/fleet15.log; }
grep -q "starting run listener on \[vmrecv2\]" /tmp/fleet15.log && bad "T17 offline-source dest still provisioned" || ok "T17 offline-source dest stays asleep"
grep -qF '"src":"nosuchsrc","tree":"ztest/src","dst":"vmrecv2","state":"cadence","rc":"0","why":"source unreachable' "$RJ" && ok "T17 offline skip in jsonl" || { bad "T17 offline jsonl"; tail -n 4 "$RJ"; }
/usr/local/lib/stevedore/stevedore-report.sh 2>/dev/null | grep -q "1 within cadence, 1 source offline" && ok "T17 report splits offline from cadence" || { bad "T17 offline tally"; /usr/local/lib/stevedore/stevedore-report.sh 2>&1 | head -n 8; }
grep -q "0 failed" /tmp/fleet15.log && ok "T17 offline-source run clean" || { bad "T17 offline failures"; tail -n 20 /tmp/fleet15.log; }

# age the whole ledger out of the window (ISO ts compares as a string;
# 19xx loses to any cutoff): everything runs again
sed -i 's/"ts":"20/"ts":"19/g' "$RJ"
/usr/local/lib/stevedore/stevedore-fleetrun.sh -c ~/fleet-cad.conf >/tmp/fleet14.log 2>&1
rc=$?
check "T17 expired-window rc=0" test "$rc" -eq 0
grep -q "cadence: \[vmrecv2\]" /tmp/fleet14.log && bad "T17 expired window still skipped" || ok "T17 expired window runs again"
grep -q "starting run listener on \[vmrecv2\]" /tmp/fleet14.log && ok "T17 vmrecv2 participates again" || { bad "T17 no vmrecv2"; tail -n 20 /tmp/fleet14.log; }
grep -q "0 failed" /tmp/fleet14.log && ok "T17 expired-window run clean" || { bad "T17 expired failures"; tail -n 20 /tmp/fleet14.log; }

echo "=== T18: --skip-ec2 drops ec2= destinations outright ==="
# vmrecv2 poses as an EC2 host; --skip-ec2 must drop its job BEFORE the
# wake set is derived (no aws call ever happens -- the rig has no aws
# cli, so a leak here would fail loudly) and leave it unprovisioned.
sed 's/^vmrecv2 /vmrecv2 ec2=i-00000000 /' ~/fleet-test.conf > ~/fleet-skipec2.conf
/usr/local/lib/stevedore/stevedore-fleetrun.sh --skip-ec2 -c ~/fleet-skipec2.conf >/tmp/fleet16.log 2>&1
rc=$?
check "T18 rc=0 (skip is not a failure)" test "$rc" -eq 0
grep -q "skip-ec2: \[vmrecv2\] 1 job(s) dropped" /tmp/fleet16.log && ok "T18 drop announced" || { bad "T18 announce"; grep -a "skip-ec2" /tmp/fleet16.log; }
grep -q "starting run listener on \[vmrecv2\]" /tmp/fleet16.log && bad "T18 dropped host was provisioned" || ok "T18 dropped host left untouched"
grep -q "0 failed" /tmp/fleet16.log && ok "T18 surviving jobs clean" || { bad "T18 failures"; tail -n 20 /tmp/fleet16.log; }
grep -qF '"dst":"vmrecv2","state":"cadence","rc":"0","why":"skipped by --skip-ec2"' "$RJ" && ok "T18 skip in jsonl" || { bad "T18 jsonl"; tail -n 3 "$RJ"; }
/usr/local/lib/stevedore/stevedore-report.sh 2>/dev/null | grep -q "1 ec2 skipped" && ok "T18 report tallies separately" || { bad "T18 tally"; /usr/local/lib/stevedore/stevedore-report.sh 2>&1 | head -n 8; }

# contradictory flags refuse loudly
/usr/local/lib/stevedore/stevedore-fleetrun.sh --skip-ec2 --force-ec2 -c ~/fleet-skipec2.conf >/tmp/fleet17.log 2>&1
rc=$?
check "T18 --skip-ec2 --force-ec2 is a usage error" test "$rc" -eq 64

# --check names the dropped rows
/usr/local/lib/stevedore/stevedore-fleetrun.sh --skip-ec2 --check -c ~/fleet-skipec2.conf >/tmp/fleet18.log 2>&1
rc=$?
check "T18 check rc=0" test "$rc" -eq 0
grep -q "SKIPPED (--skip-ec2)" /tmp/fleet18.log && ok "T18 check lists the drop" || { bad "T18 check"; grep -a "job:" /tmp/fleet18.log; }

echo "=== T19: steve timer: system-unit posture ==="
# timer on: units written (stevedore-fleet.*, NOT stevedore-run-* -- the
# leftover-unit glob must never match them), User= the ledger owner,
# agent-less key preflight passes on the rig. One real service run
# proves the headless path end to end (same-minute rerun = idempotent),
# then off removes everything.
sudo cp ~/fleet-test.conf /etc/stevedore/fleet.conf
sudo bash ~/zfsrecvd-src/stevedore.sh timer on hourly >/tmp/t20a.log 2>&1
rc=$?
check "T19 timer on rc=0" test "$rc" -eq 0
check "T19 timer enabled" systemctl is-enabled --quiet stevedore-fleet.timer
check "T19 service runs as operator" grep -q "^User=marton$" /etc/systemd/system/stevedore-fleet.service
check "T19 busy-estate tick is success" grep -q "^SuccessExitStatus=75$" /etc/systemd/system/stevedore-fleet.service
check "T19 next fire scheduled" bash -c "systemctl list-timers --no-pager 2>/dev/null | grep -q stevedore-fleet"
rj_before=$(wc -l < "$RJ")
sudo systemctl start stevedore-fleet.service
rc=$?
check "T19 timer-driven run rc=0" test "$rc" -eq 0
rj_after=$(wc -l < "$RJ")
check "T19 ledger grew ($rj_before -> $rj_after)" test "$rj_after" -gt "$rj_before"
# journald flushes the unit's stdout stream asynchronously: querying the
# instant systemctl start returns can miss the tail lines (raced once).
# Poll briefly instead of trusting a single read.
t19_sum=""
for _ in $(seq 1 20); do
    sudo journalctl -u stevedore-fleet.service -n 80 --no-pager 2>/dev/null | grep -q "run summary" && { t19_sum=1; break; }
    sleep 0.5
done
[ -n "$t19_sum" ] && ok "T19 run summary in the journal" || bad "T19 no run summary in journal"
sudo bash ~/zfsrecvd-src/stevedore.sh timer off >/tmp/t20b.log 2>&1
rc=$?
check "T19 timer off rc=0" test "$rc" -eq 0
check "T19 timer gone"  bash -c "! systemctl is-enabled --quiet stevedore-fleet.timer 2>/dev/null"
check "T19 units removed" bash -c "! test -e /etc/systemd/system/stevedore-fleet.service && ! test -e /etc/systemd/system/stevedore-fleet.timer"
sudo rm /etc/stevedore/fleet.conf

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in /tmp/fleet1.log /tmp/fleet2.log /tmp/fleet3.log /tmp/fleet4.log /tmp/fleet5.log /tmp/fleet6.log /tmp/fleet7.log /tmp/fleet8.log /tmp/fleet9.log /tmp/fleet10.log /tmp/fleet11.log /tmp/fleet12.log /tmp/fleet13.log /tmp/fleet14.log /tmp/fleet15.log /tmp/fleet16.log /tmp/fleet17.log /tmp/fleet18.log; do
        [ -f "$f" ] && { echo "--- $f tail ---"; tail -n 25 "$f"; }
    done
    for u in stevedore-run-vmrecv stevedore-run-vmrecv2 stevedore-ha-vmrecv stevedore-ha-vmrecv2; do
        echo "--- $u journal ---"
        sudo journalctl -u "$u" -n 30 --no-pager 2>/dev/null | tail -n 30
    done
    exit 1
fi
