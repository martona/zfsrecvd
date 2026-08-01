#!/usr/bin/env bash
# PROXY protocol v2 reader for the haproxy transport (PROTOCOL.md §20).
#
# Source this, then call pp2_read_cn with the connection on stdin. It
# consumes EXACTLY the PP2 header (byte-exact reads -- the v2 protocol
# session follows immediately on the same stream) and sets PP2_CN to the
# TLS-verified client certificate CN that haproxy extracted and placed
# in the header (server option: send-proxy-v2-ssl-cn).
#
# There is NO certificate material on this wire and none is parsed here:
# haproxy does the X.509 work with its own OpenSSL and forwards only the
# resulting CN string inside its own framing, which is a frozen,
# versioned wire format (doc/proxy-protocol.txt in the haproxy tree).
#
# Fail-closed ladder -- ANY anomaly returns nonzero with PP2_CN empty,
# and the caller must drop the connection; nothing ever defaults:
#   * short read / missing signature   (also catches anything that is
#     not haproxy dialing the plaintext port directly)
#   * version+command != 0x21          (PROXYv2; 0x20 LOCAL healthchecks
#     carry no identity and are refused too)
#   * address family not TCP4/TCP6
#   * no SSL TLV (0x20), or its verify field nonzero (cert NOT verified)
#   * no CN sub-TLV (0x22), or a CN that fails the identity charset
#     check ([A-Za-z0-9._-]+, same as fleet.conf identities)
#
# The CN is the only printable string in the whole header, so a slicing
# bug yields binary junk that dies at the charset check -- there is no
# other name in there to misread. Byte counts are exact: dd bs=1 makes
# one read() per byte, which is correct on a socket/pipe (and this runs
# once per session, on a few dozen bytes).

# Read exactly $1 bytes from stdin, emit as a lowercase hex string.
# Emits whatever arrived; the caller checks the length (short = EOF).
_pp2_hex() {
    dd bs=1 count="$1" 2>/dev/null | od -An -v -tx1 | tr -cd '0123456789abcdef'
}

pp2_read_cn() {
    PP2_CN=""
    local hdr len fam body tlv pos typ tl val
    local sub spos styp stl cnhex cn i

    hdr=$(_pp2_hex 16)
    [[ ${#hdr} -eq 32 ]] || return 1
    # 12-byte signature, then version+command 0x21 (v2, PROXY)
    [[ "${hdr:0:24}" == "0d0a0d0a000d0a515549540a" ]] || return 1
    [[ "${hdr:24:2}" == "21" ]] || return 1
    fam="${hdr:26:2}"
    len=$(( 16#${hdr:28:4} ))
    # sanity cap: addresses + a CN's worth of TLVs is well under this
    [[ $len -le 4096 ]] || return 1

    body=$(_pp2_hex "$len")
    [[ ${#body} -eq $(( len * 2 )) ]] || return 1

    # skip the address block; size is fixed per family
    case "$fam" in
        11) tlv="${body:24}"  ;;   # TCP4: 4+4+2+2 = 12 bytes
        21) tlv="${body:72}"  ;;   # TCP6: 16+16+2+2 = 36 bytes
        *)  return 1 ;;
    esac

    # walk TLVs: type(1) len(2) value(len)
    pos=0
    while (( pos + 6 <= ${#tlv} )); do
        typ="${tlv:pos:2}"
        tl=$(( 16#${tlv:pos+2:4} ))
        val="${tlv:pos+6:tl*2}"
        [[ ${#val} -eq $(( tl * 2 )) ]] || return 1
        pos=$(( pos + 6 + tl * 2 ))
        [[ "$typ" == "20" ]] || continue

        # PP2_TYPE_SSL: client(1) verify(4), then sub-TLVs. verify must
        # be zero = haproxy verified the client cert against the run CA.
        (( tl >= 5 )) || return 1
        [[ "${val:2:8}" == "00000000" ]] || return 1
        sub="${val:10}"
        spos=0
        while (( spos + 6 <= ${#sub} )); do
            styp="${sub:spos:2}"
            stl=$(( 16#${sub:spos+2:4} ))
            cnhex="${sub:spos+6:stl*2}"
            [[ ${#cnhex} -eq $(( stl * 2 )) ]] || return 1
            spos=$(( spos + 6 + stl * 2 ))
            [[ "$styp" == "22" ]] || continue

            cn=""
            for (( i = 0; i < ${#cnhex}; i += 2 )); do
                cn+=$(printf "\x${cnhex:i:2}")
            done
            # same identity charset fleet.conf enforces; anything else
            # is junk or an attack, never a default
            [[ "$cn" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
            PP2_CN="$cn"
            return 0
        done
        return 1     # SSL TLV present but no CN inside
    done
    return 1         # no SSL TLV at all
}
