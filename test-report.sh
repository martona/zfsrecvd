#!/usr/bin/env bash
# Unit tests for report.sh against a synthetic runs.jsonl. Pure bash+awk,
# runs anywhere: ./test-report.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

cat > "$FX/runs.jsonl" <<'EOF'
{"ts":"2026-07-29T01:00:00Z","snap":"zfsrecvd-2026-07-29-0100Z","src":"jup","tree":"tank/a","dst":"berg","state":"done","rc":"0","why":"","failed_ds":"","secs":10}
{"ts":"2026-07-29T01:00:00Z","snap":"zfsrecvd-2026-07-29-0100Z","src":"jup","tree":"tank/a","dst":"cp4","state":"done","rc":"0","why":"","failed_ds":"","secs":12}
{"ts":"2026-07-29T01:01:00Z","kind":"run","run":"run-A","rc":0,"recv":[{"id":"berg","before":1000,"after":2024,"avail":5000000,"pruned":100},{"id":"cp4","before":500,"after":800,"avail":900000,"pruned":0}],"src":[{"id":"jup","tree":"tank/a","used":123456,"avail":777777}]}
{"ts":"2026-07-30T01:00:00Z","snap":"zfsrecvd-2026-07-30-0100Z","src":"jup","tree":"tank/a","dst":"berg","state":"done","rc":"0","why":"","failed_ds":"","secs":9}
{"ts":"2026-07-30T01:00:00Z","snap":"zfsrecvd-2026-07-30-0100Z","src":"jup","tree":"tank/a","dst":"cp4","state":"done","rc":"2","why":"some datasets failed","failed_ds":"tank/a/vol tank/a/deep","secs":44}
{"ts":"2026-07-30T01:00:40Z","snap":"","src":"jup","tree":"tank/c","dst":"ec2","state":"cadence","rc":"0","why":"last ok 2026-07-29T20:00:00Z (cadence 24h)","failed_ds":"","secs":0}
{"ts":"2026-07-30T01:00:41Z","snap":"","src":"vbox","tree":"tank/d","dst":"ec2","state":"cadence","rc":"0","why":"source unreachable; cadence window not consulted","failed_ds":"","secs":0}
{"ts":"2026-07-30T01:00:42Z","snap":"","src":"jup","tree":"tank/e","dst":"ec2","state":"cadence","rc":"0","why":"skipped by --skip-ec2","failed_ds":"","secs":0}
{"ts":"2026-07-30T01:01:00Z","kind":"run","run":"run-B","rc":2,"recv":[{"id":"berg","before":2024,"after":4072,"avail":4990000,"pruned":512},{"id":"cp4","before":800,"after":800,"avail":900000,"pruned":0}],"src":[{"id":"jup","tree":"tank/a","used":200000,"avail":700000}],"gc":[{"id":"berg","gc":"tank/recv/x/gone: ORPHAN CANDIDATE -- 42d behind siblings; eligible in 48d"},{"id":"berg","gc":"track tank/recv/x/dev@codex: unknown-since 2026-07-30T00:00:00Z; eligible in 89d"},{"id":"cp4","gc":"all quiet: 1 client(s), 3 datasets, everything fresh"}]}
EOF

out=$(bash "$HERE/stevedore-report.sh" -f "$FX/runs.jsonl" 2>&1)
rc=$?
[[ $rc -eq 0 ]] && ok "renders rc=0" || { bad "rc=$rc"; echo "$out"; }
grep -q "last run: run-B" <<<"$out" && ok "latest run selected" || bad "latest: $out"
grep -q "jobs: 1 ok, 1 not ok, 1 within cadence, 1 source offline, 1 ec2 skipped" <<<"$out" && ok "job tally incl cadence + offline + skip-ec2" || bad "tally: $out"
grep -q "FAIL.*tank/c" <<<"$out" && bad "cadence job rendered as FAIL" || ok "cadence job is not a failure"
grep -q "FAIL.*tank/d" <<<"$out" && bad "offline-source job rendered as FAIL" || ok "offline-source job is not a failure"
grep -q "FAIL.*tank/e" <<<"$out" && bad "skip-ec2 job rendered as FAIL" || ok "skip-ec2 job is not a failure"
grep -q "FAIL  \[jup\] tank/a -> \[cp4\]" <<<"$out" && ok "failure drilldown line" || bad "fail line: $out"
grep -q "datasets: tank/a/vol tank/a/deep" <<<"$out" && ok "failed_ds surfaced" || bad "failed_ds: $out"
# table rows are exact-line asserts: they prove the right-alignment, not
# just the numbers
grep -qx "  receiver   net  pruned   avail" <<<"$out" && ok "receiver table header" || bad "recv hdr: $out"
grep -qx "  berg      2.0K    512B    4.8M" <<<"$out" && ok "receiver row aligned (berg)" || bad "recv berg: $out"
grep -qx "  cp4         0B      0B  878.9K" <<<"$out" && ok "receiver row aligned (cp4)" || bad "recv cp4: $out"
grep -qx "  source  tree      used   avail" <<<"$out" && ok "source table header" || bad "src hdr: $out"
grep -qx "  jup     tank/a  195.3K  683.6K" <<<"$out" && ok "source row aligned" || bad "src row: $out"
grep -q "gc \[berg\] tank/recv/x/gone: ORPHAN CANDIDATE" <<<"$out" && ok "gc warning rendered" || bad "gc warn: $out"
grep -q "gc \[cp4\] all quiet: 1 client(s)" <<<"$out" && ok "gc all-quiet rendered" || bad "gc quiet: $out"
grep -q "@codex" <<<"$out" && bad "gc track entry shown without --gc-debug" || ok "gc track hidden by default"
outg=$(bash "$HERE/stevedore-report.sh" --gc-debug -f "$FX/runs.jsonl" 2>&1)
grep -q "gc \[berg\] track tank/recv/x/dev@codex: unknown-since" <<<"$outg" && ok "--gc-debug surfaces track inventory" || bad "gc-debug: $outg"
grep -q "trend (last 2 run(s))" <<<"$out" && ok "trend window" || bad "trend hdr: $out"
grep -qx "  berg      3.0K    612B" <<<"$out" && ok "trend sums aligned (berg)" || bad "trend berg: $out"
grep -qx "  cp4       300B      0B" <<<"$out" && ok "trend sums aligned (cp4)" || bad "trend cp4: $out"
grep -q "runs with nonzero rc: 1" <<<"$out" && ok "trend failure count" || bad "trend fails: $out"

out1=$(bash "$HERE/stevedore-report.sh" -n 1 -f "$FX/runs.jsonl" 2>&1)
grep -q "trend (last 1 run(s))" <<<"$out1" && ok "-n limits window" || bad "-n: $out1"
grep -qx "  berg      2.0K    512B" <<<"$out1" && ok "-n=1 sums only last" || bad "-n sums: $out1"

# a run record without the gc field (pre-gc history) renders untouched
cat > "$FX/old.jsonl" <<'EOF'
{"ts":"2026-07-28T00:00:00Z","kind":"run","run":"run-old","rc":0,"recv":[{"id":"berg","before":0,"after":1024,"avail":2048,"pruned":0}],"src":[]}
EOF
out2=$(bash "$HERE/stevedore-report.sh" -f "$FX/old.jsonl" 2>&1)
rc=$?
[[ $rc -eq 0 && "$out2" == *"last run: run-old"* ]] && ok "gc-less record renders" || { bad "compat rc=$rc"; echo "$out2"; }
grep -q "  gc \[" <<<"$out2" && bad "gc section on gc-less record" || ok "no gc section when absent"
grep -q "within cadence" <<<"$out2" && bad "cadence suffix on cadence-less run" || ok "no cadence suffix when none"
grep -q "ec2 skipped" <<<"$out2" && bad "ec2-skipped suffix on skip-less run" || ok "no ec2-skipped suffix when none"

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
