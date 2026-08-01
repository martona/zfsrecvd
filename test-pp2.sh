#!/usr/bin/env bash
# Unit tests for pp2.sh (PROXY protocol v2 reader). Pure bash + od/dd --
# runs on any dev box: ./test-pp2.sh
# Vectors are hand-built from the spec (haproxy doc/proxy-protocol.txt);
# vmtest-fleet.sh additionally exercises the parser against headers a
# real haproxy emits, so a misreading of the spec cannot hide here.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PP="$HERE/stevedore-pp2.sh"
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

feed() {   # hex string -> raw bytes on stdout
    local h="$1" i
    for (( i = 0; i < ${#h}; i += 2 )); do
        printf "\x${h:i:2}"
    done
}

# run_case <hex> [trailer]: parse; print OK:<cn>[:<first line after hdr>]
run_case() {
    { feed "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2"; } | (
        source "$PP"
        if pp2_read_cn; then
            rest=""
            if [[ -n "${2:-}" ]]; then IFS= read -r rest; fi
            echo "OK:${PP2_CN}${rest:+:$rest}"
        else
            echo "REFUSED:${PP2_CN:-empty}"
        fi
    )
}

SIG="0d0a0d0a000d0a515549540a"
ADDR4="7f0000017f000001c0003bc2"                       # 12 bytes
SSLTLV="20000f0100000000220007$(printf jupiter | od -An -v -tx1 | tr -d ' \n')"
V_OK="${SIG}2111001e${ADDR4}${SSLTLV}"                  # len 12+18 = 30 = 0x001e

r=$(run_case "$V_OK")
[[ "$r" == "OK:jupiter" ]] && ok "valid TCP4 header -> CN jupiter" || bad "valid: $r"

r=$(run_case "$V_OK" "zfsrecvd2.0")
[[ "$r" == "OK:jupiter:zfsrecvd2.0" ]] && ok "byte-exact: greeting intact after header" || bad "byte-exact: $r"

r=$(run_case "0e${V_OK:2}")
[[ "$r" == REFUSED:* ]] && ok "bad signature refused" || bad "bad sig: $r"

r=$(run_case "${SIG}2011000c${ADDR4}")
[[ "$r" == REFUSED:* ]] && ok "LOCAL (healthcheck) refused" || bad "LOCAL: $r"

V_BADVERIFY="${SIG}2111001e${ADDR4}20000f0100000001220007$(printf jupiter | od -An -v -tx1 | tr -d ' \n')"
r=$(run_case "$V_BADVERIFY")
[[ "$r" == REFUSED:* ]] && ok "verify!=0 (unverified cert) refused" || bad "verify: $r"

V_NOSSL="${SIG}2111001e${ADDR4}04000f$(printf '0%.0s' {1..30})"
r=$(run_case "$V_NOSSL")
[[ "$r" == REFUSED:* ]] && ok "no SSL TLV refused" || bad "no-ssl: $r"

V_BADCN="${SIG}2111001e${ADDR4}20000f0100000000220007$(printf 'jup;ter' | od -An -v -tx1 | tr -d ' \n')"
r=$(run_case "$V_BADCN")
[[ "$r" == REFUSED:* ]] && ok "CN outside identity charset refused" || bad "bad cn: $r"

r=$(run_case "${V_OK:0:40}")
[[ "$r" == REFUSED:* ]] && ok "truncated header refused" || bad "trunc: $r"

ADDR6=$(printf '0%.0s' {1..72})                         # 36 zero bytes
V_OK6="${SIG}21210036${ADDR6}${SSLTLV}"                 # len 36+18 = 54 = 0x0036
r=$(run_case "$V_OK6")
[[ "$r" == "OK:jupiter" ]] && ok "valid TCP6 header -> CN jupiter" || bad "tcp6: $r"

V_UNIX="${SIG}213100d8$(printf '0%.0s' {1..432})"
r=$(run_case "$V_UNIX")
[[ "$r" == REFUSED:* ]] && ok "unix family refused" || bad "unix: $r"

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
