#!/usr/bin/env bash
# Unit tests for retain.sh (the grid selector). Pure bash -- runs on any
# dev box: ./test-retain.sh
# Every expectation is hand-derived; 2026-07-27 is a Monday, so Jul
# 27/28/29 share one ISO week and Jun 30 is in the prior week/month.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/retain.sh"
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

run() {   # $1 spec, $2 newline names -> sorted comma list of destroys
    retain_destroy "$1" <<<"$2" | sort | paste -sd, -
}

NAMES="zfsrecvd-2026-07-27-1000Z
zfsrecvd-2026-07-27-1030Z
zfsrecvd-2026-07-27-1100Z
zfsrecvd-2026-07-28-0900Z
zfsrecvd-2026-07-28-0930Z
zfsrecvd-2026-07-29-0900Z
zfsrecvd-2026-07-29-1000Z
zfsrecvd-2026-07-29-1005Z"

# hourly=2: hour-reps of 29-09 (0900) and 29-10 (1000) + frontier (1005)
r=$(run "hourly=2" "$NAMES")
exp="zfsrecvd-2026-07-27-1000Z,zfsrecvd-2026-07-27-1030Z,zfsrecvd-2026-07-27-1100Z,zfsrecvd-2026-07-28-0900Z,zfsrecvd-2026-07-28-0930Z"
[[ "$r" == "$exp" ]] && ok "hourly=2 thins to 2 hour-reps + frontier" || bad "hourly=2: $r"

# hourly=2 daily=2: adds day-reps of 28 (0900) and 29 (0900)
r=$(run "hourly=2 daily=2" "$NAMES")
exp="zfsrecvd-2026-07-27-1000Z,zfsrecvd-2026-07-27-1030Z,zfsrecvd-2026-07-27-1100Z,zfsrecvd-2026-07-28-0930Z"
[[ "$r" == "$exp" ]] && ok "hourly=2 daily=2 union" || bad "h2d2: $r"

# weekly=1 monthly=1: all July names share week+month; rep = first
# (27-1000) + frontier survive
r=$(run "weekly=1 monthly=1" "$NAMES")
exp="zfsrecvd-2026-07-27-1030Z,zfsrecvd-2026-07-27-1100Z,zfsrecvd-2026-07-28-0900Z,zfsrecvd-2026-07-28-0930Z,zfsrecvd-2026-07-29-0900Z,zfsrecvd-2026-07-29-1000Z"
[[ "$r" == "$exp" ]] && ok "weekly/monthly reps are first-of-period" || bad "w1m1: $r"

# monthly=2 with a June straggler: both month-reps kept
r=$(run "monthly=2" "zfsrecvd-2026-06-30-2359Z
$NAMES")
exp="zfsrecvd-2026-07-27-1030Z,zfsrecvd-2026-07-27-1100Z,zfsrecvd-2026-07-28-0900Z,zfsrecvd-2026-07-28-0930Z,zfsrecvd-2026-07-29-0900Z,zfsrecvd-2026-07-29-1000Z"
[[ "$r" == "$exp" ]] && ok "monthly=2 keeps both month reps" || bad "m2: $r"

# gaps don't burn budget: daily=3 over 3 sparse days keeps all reps
r=$(run "daily=3" "zfsrecvd-2026-05-01-1200Z
zfsrecvd-2026-06-15-1200Z
zfsrecvd-2026-07-29-1200Z")
[[ -z "$r" ]] && ok "daily=3 with gaps destroys nothing" || bad "gaps: $r"

# budget smaller than periods: daily=1 keeps only newest day rep + frontier
r=$(run "daily=1" "zfsrecvd-2026-05-01-1200Z
zfsrecvd-2026-06-15-1200Z
zfsrecvd-2026-07-29-1200Z")
exp="zfsrecvd-2026-05-01-1200Z,zfsrecvd-2026-06-15-1200Z"
[[ "$r" == "$exp" ]] && ok "daily=1 keeps newest day only" || bad "d1: $r"

# frontier survives even with zero-width spec
r=$(run "hourly=0" "$NAMES")
grep -q "1005Z" <<<"$r" && bad "frontier destroyed under hourly=0" || ok "frontier always survives"

# unparseable names are never emitted
r=$(run "hourly=1" "manual-keepme
zfsrecvd-2026-07-29-1000Z
zfsrecvd-2026-07-29-1005Z")
[[ "$r" != *manual-keepme* ]] && ok "unparseable names never destroyed" || bad "unparseable: $r"

# garbled spec disables the call entirely
r=$(run "hourly=2 fortnightly=9" "$NAMES" 2>/dev/null)
[[ -z "$r" ]] && ok "unknown spec token keeps everything" || bad "badspec: $r"

# single snapshot: never destroyed under any spec
r=$(run "hourly=1 daily=1" "zfsrecvd-2026-07-29-1005Z")
[[ -z "$r" ]] && ok "lone snapshot survives" || bad "lone: $r"

# out-of-order input: same result as sorted
r=$(run "hourly=2" "zfsrecvd-2026-07-29-1005Z
zfsrecvd-2026-07-27-1000Z
zfsrecvd-2026-07-29-0900Z
zfsrecvd-2026-07-28-0900Z
zfsrecvd-2026-07-29-1000Z
zfsrecvd-2026-07-27-1030Z
zfsrecvd-2026-07-28-0930Z
zfsrecvd-2026-07-27-1100Z")
exp="zfsrecvd-2026-07-27-1000Z,zfsrecvd-2026-07-27-1030Z,zfsrecvd-2026-07-27-1100Z,zfsrecvd-2026-07-28-0900Z,zfsrecvd-2026-07-28-0930Z"
[[ "$r" == "$exp" ]] && ok "input order irrelevant" || bad "unordered: $r"

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
