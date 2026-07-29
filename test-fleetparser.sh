#!/usr/bin/env bash
# Unit tests for fleetparser.sh: happy-path derivations plus one fixture
# per validation rule (each must exit 78 with the right file:line message).
# Pure bash -- no zfs, no network; runs on any dev box: ./test-fleetparser.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/fleetparser.sh"
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

cat > "$FX/good.conf" <<'EOF'
[options]
user   marton
port   15299
transport haproxy

[retention]
source        hourly=24 daily=7
destination   hourly=48 daily=30 weekly=8 monthly=12

[hosts]
bergamo         recv=tank/recv   data=bergamo.lan
cp4             recv=tank/recv   data=commodoreplus4.lan   ec2=i-abc123
zeus            ssh=root@zeus-mgmt   recv=rust/recv

[jobs]
jupiter    nvmetank      bergamo
jupiter    nvmetank      cp4
jupiter    nvmetank      zeus
sapphire   rpool         bergamo
bergamo    tank/backup   cp4
EOF

out=$(bash -c "source '$FP'; fleet_parse '$FX/good.conf';
    echo \"user=\$fleet_opt_user port=\$fleet_opt_port workers=\$fleet_opt_workers transport=\$fleet_opt_transport\";
    echo \"sources=\${fleet_sources[*]}\";
    echo \"receivers=\${fleet_receivers[*]}\";
    echo \"participants=\${fleet_participants[*]}\";
    echo \"jobs=\${#fleet_job_src[@]}\";
    echo \"sshd_jup=\$(fleet_ssh_dest jupiter) sshd_zeus=\$(fleet_ssh_dest zeus)\";
    echo \"data_cp4=\$(fleet_data cp4) data_jup=\$(fleet_data jupiter)\";
    echo \"hourly_src=\$(fleet_ret_bucket \"\$fleet_ret_source\" hourly)\";
    echo \"monthly_dst=\$(fleet_ret_bucket \"\$fleet_ret_destination\" monthly)\";
    echo \"absent=[\$(fleet_ret_bucket \"\$fleet_ret_source\" monthly)]\";
    echo \"ec2_cp4=\${fleet_host_ec2[cp4]}\"" 2>&1)
rc=$?
[[ $rc -eq 0 ]] && ok "good.conf parses (rc=0)" || { bad "good.conf rc=$rc"; echo "$out"; }
grep -q "user=marton port=15299 workers=8 transport=haproxy" <<<"$out" && ok "options + workers default + transport" || bad "options: $out"
grep -q "sources=jupiter sapphire bergamo" <<<"$out" && ok "sources order/dedup" || bad "sources: $out"
grep -q "receivers=bergamo cp4 zeus" <<<"$out" && ok "receivers order/dedup" || bad "receivers: $out"
grep -q "participants=jupiter sapphire bergamo cp4 zeus" <<<"$out" && ok "participants union" || bad "participants: $out"
grep -q "jobs=5" <<<"$out" && ok "job count" || bad "jobs: $out"
grep -q "sshd_jup=marton@jupiter sshd_zeus=root@zeus-mgmt" <<<"$out" && ok "ssh defaults + override" || bad "ssh: $out"
grep -q "data_cp4=commodoreplus4.lan data_jup=jupiter" <<<"$out" && ok "data defaults + override" || bad "data: $out"
grep -q "hourly_src=24" <<<"$out" && ok "ret bucket hourly/source" || bad "bucket: $out"
grep -q "monthly_dst=12" <<<"$out" && ok "ret bucket monthly/dest" || bad "bucket: $out"
grep -q "absent=\[\]" <<<"$out" && ok "ret bucket absent = empty" || bad "bucket absent: $out"
grep -q "ec2_cp4=i-abc123" <<<"$out" && ok "ec2 attr" || bad "ec2: $out"

expect_fatal() { # name conf-body expected-line expected-msg-fragment
    local name="$1" body="$2" eline="$3" frag="$4"
    printf '%s\n' "$body" > "$FX/$name.conf"
    local o r
    o=$(bash -c "source '$FP'; fleet_parse '$FX/$name.conf'" 2>&1)
    r=$?
    if [[ $r -eq 78 ]] && grep -q "$name.conf:$eline: .*$frag" <<<"$o"; then
        ok "$name rejected ($frag @ line $eline)"
    else
        bad "$name: rc=$r out=$o"
    fi
}

expect_fatal badsection '[foo]
x' 1 "unknown section"

expect_fatal badcols '[jobs]
jupiter bergamo' 2 "3 columns"

expect_fatal selfjob '[hosts]
a recv=t/r
[jobs]
a tree a' 4 "source == dest"

expect_fatal dupjob '[hosts]
b recv=t/r
[jobs]
a tree b
a tree b' 5 "duplicate job"

expect_fatal typodest '[hosts]
bergamo recv=t/r
[jobs]
jupiter tree bergamoo' EOF "no recv="

expect_fatal viareserved '[hosts]
b recv=t/r
[jobs]
a tree b via=c' 4 "reserved for the relay"

expect_fatal badopt '[options]
frobnicate 9' 2 "unknown option"

expect_fatal badtransport '[options]
transport pigeon' 2 "transport must be"

expect_fatal badbucket '[retention]
source fortnightly=3' 2 "bad retention bucket"

expect_fatal dataport '[hosts]
b recv=t/r data=b.lan:9999' 2 "reserved"

expect_fatal duphost '[hosts]
b recv=t/r
b recv=t/r2' 3 "duplicate host"

expect_fatal nojobs '[hosts]
b recv=t/r' EOF "no \[jobs\]"

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
