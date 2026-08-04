#!/usr/bin/env bash
# Unit tests for stevedore-jobs.sh (`steve jobs`, the job-matrix editor),
# driven headlessly: STEVEDORE_JOBS_SCRIPT=1 + piped keystrokes (text
# prompts read whole lines off the same stream). Pure bash -- runs on
# any dev box: ./test-jobs.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SJ="$HERE/stevedore-jobs.sh"
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT
CONF="$FX/fleet.conf"

mkconf() { cat > "$CONF" <<'EOF'
# top comment
[options]
user  marton
port  5299

[retention]
source       hourly=24
destination  hourly=48 daily=30

# hosts comment
[hosts]
recv1   recv=tank/recv    data=recv1.lan
recv2   recv=rust/recv

[jobs]
# jobs comment
srcA   tank/a   recv1
srcA   tank/a   recv2
srcB   tank/b   recv1
EOF
}

drive() {   # $1 = key/line stream -> rc; stderr in $FX/err
    printf '%b' "$1" | STEVEDORE_JOBS_SCRIPT=1 bash "$SJ" -c "$CONF" 2> "$FX/err"
}
njobs() {
    bash -c "source '$HERE/stevedore-fleetparser.sh'; fleet_parse '$CONF' >/dev/null 2>&1; echo \${#fleet_job_src[@]}"
}

# --- no-op save round-trips: comments live, content parses ------------------
mkconf
drive "sq"
[[ $(njobs) == 3 ]] && ok "no-op save keeps all 3 jobs" || bad "job count after save: $(njobs)"
grep -q "^# top comment" "$CONF"   && ok "top comment preserved"   || bad "top comment lost"
grep -q "^# hosts comment" "$CONF" && ok "hosts comment preserved" || bad "hosts comment lost"
grep -q "^# jobs comment" "$CONF"  && ok "jobs comment hoisted+kept" || bad "jobs comment lost"
grep -q "recv1   recv=tank/recv    data=recv1.lan" "$CONF" \
    && ok "hosts rows byte-identical" || bad "hosts row reformatted"

# --- second save is byte-identical (regeneration is stable) -----------------
cp "$CONF" "$FX/one"
drive "sq"
cmp -s "$CONF" "$FX/one" && ok "save is idempotent" || bad "second save changed the file"

# --- toggle a cell on, save; .bak holds the previous version ----------------
cp "$CONF" "$FX/pre"
drive "jl sq"
[[ $(njobs) == 4 ]] && ok "toggle added a job" || bad "toggle count: $(njobs)"
grep -Eq "^srcB +tank/b +recv2$" "$CONF" && ok "srcB/tank/b -> recv2 row emitted" || bad "row missing"
cmp -s "$CONF.bak" "$FX/pre" && ok ".bak is the previous version" || bad ".bak wrong"
# mktemp is 0600; the atomic replace must mirror the original's mode
# (a root edit once left fleet.conf unreadable to the operator). Some
# filesystems (NTFS under Git Bash) cannot express 640 at all -- only
# assert when the pre-save chmod actually stuck.
chmod 640 "$CONF" 2>/dev/null
if [[ "$(stat -c %a "$CONF")" == 640 ]]; then
    drive "sq"
    mode=$(stat -c %a "$CONF")
    [[ "$mode" == 640 ]] && ok "save preserves file mode (640)" || bad "mode after save: $mode"
else
    ok "mode preservation untestable here (fs cannot express 640); VM asserts it"
fi

# --- toggle without saving: q q discards, file untouched --------------------
mkconf
cp "$CONF" "$FX/pre"
drive " qq"
cmp -s "$CONF" "$FX/pre" && ok "discarded quit leaves file untouched" || bad "discard wrote changes"
grep -q "unsaved changes" "$FX/err" && ok "quit guard warned" || bad "no quit warning"

# --- add dataset: sender menu (preselected) -> name -> toggle ---------------
mkconf
drive "a\ntank/new\n sq"
grep -Eq "^srcA +tank/new +recv1$" "$CONF" && ok "add-dataset flow lands a row" || bad "add-dataset row missing"
[[ $(njobs) == 4 ]] && ok "add-dataset job count" || bad "count: $(njobs)"

# --- add sender loops back into the menu, preselected -----------------------
mkconf
drive "ajj\nsrcC\n\ntank/c\n sq"
grep -Eq "^srcC +tank/c +recv1$" "$CONF" && ok "add-sender loop lands the row" || bad "add-sender row missing"

# --- add receiver: appended to [hosts], toggleable column -------------------
mkconf
drive "Hrecv3\npool/recv\n\n\n\n\n\n sq"
grep -Eq "^recv3 +recv=pool/recv$" "$CONF" && ok "receiver row appended" || bad "receiver row missing"
r2=$(grep -n "^recv2" "$CONF" | cut -d: -f1)
r3=$(grep -n "^recv3" "$CONF" | cut -d: -f1)
[[ -n "$r2" && -n "$r3" && "$r3" -gt "$r2" ]] && ok "receiver appended after existing rows" || bad "receiver position ($r2/$r3)"
grep -Eq "^srcA +tank/a +recv3$" "$CONF" && ok "job onto new receiver" || bad "job onto recv3 missing"

# --- delete row (with confirm) ----------------------------------------------
mkconf
drive "dy\nsq"
[[ $(njobs) == 1 ]] && ok "row delete drops its jobs" || bad "count after row delete: $(njobs)"
grep -q "tank/a" "$CONF" && bad "deleted row still present" || ok "deleted row gone"

# --- delete receiver: jobs + [hosts] row go together ------------------------
mkconf
drive "Dy\nsq"
grep -q "^recv1" "$CONF" && bad "deleted receiver's hosts row survived" || ok "receiver hosts row removed"
grep -Eq "^srcA +tank/a +recv2$" "$CONF" && ok "other receiver's job survives" || bad "surviving job lost"
[[ $(njobs) == 1 ]] && ok "receiver delete count" || bad "count: $(njobs)"

# --- an empty matrix cannot be saved (parser backstop) ----------------------
mkconf
cp "$CONF" "$FX/pre"
drive "Dy\nDy\nsqq"
cmp -s "$CONF" "$FX/pre" && ok "invalid (empty) save left file untouched" || bad "empty save clobbered file"
grep -q "NOT saved" "$FX/err" && ok "empty save refused loudly" || bad "no refusal message"

# --- job-row attribute tails (snaps=) survive the editor ---------------------
mkconf2() { cat > "$CONF" <<'EOF'
[hosts]
recv1   recv=tank/recv
recv2   recv=rust/recv

[jobs]
srcA   tank/a   recv1   snaps=1T
srcB   tank/b   recv1
EOF
}
mkconf2
drive "sq"
grep -Eq "^srcA +tank/a +recv1 +snaps=1T$" "$CONF" \
    && ok "no-op save keeps the snaps= tail" || bad "tail lost on save"
grep -Eq "^srcB +tank/b +recv1$" "$CONF" \
    && ok "tail-less row stays bare (no trailing attrs)" || bad "bare row grew a tail"
cp "$CONF" "$FX/one"
drive "sq"
cmp -s "$CONF" "$FX/one" && ok "tailed save is idempotent" || bad "second tailed save changed the file"

# a newly toggled cell on a tailed (src,tree) inherits the tail: the
# parser's consistency rule would otherwise refuse the very save that
# steve jobs just wrote
mkconf2
drive "l sq"
grep -Eq "^srcA +tank/a +recv2 +snaps=1T$" "$CONF" \
    && ok "toggled cell inherits the (src,tree) snaps= tail" || bad "inherited tail missing"
[[ $(njobs) == 3 ]] && ok "tailed toggle job count" || bad "count: $(njobs)"

# deleting the row forgets its tail (no resurrection on a later re-add)
mkconf2
drive "dy\nsq"
grep -q "snaps=1T" "$CONF" && bad "deleted row's tail lingers" || ok "row delete drops the tail"

# --- a config that doesn't parse is refused at open --------------------------
mkconf
echo "one two three four" >> "$CONF"
drive "q"
rc=$?
[[ "$rc" == 78 ]] && ok "invalid config refused at open (rc 78)" || bad "open rc: $rc"
grep -q "does not parse" "$FX/err" && ok "open refusal names the problem" || bad "no open message"

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
