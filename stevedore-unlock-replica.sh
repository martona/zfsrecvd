#!/usr/bin/env bash
# unlock-replica.sh <received-rpool>     e.g. tank/recv/odin/rpool
#
# Operator tool: load the ZFS encryption keys of a raw-received replica
# using the key file inside its OWN replicated keystore (Ubuntu-style
# layout: <rpool>/keystore zvol, usually LUKS around ext4 holding
# system.key). Flow:
#   1. find the keystore zvol under the replica, wait for its dev node,
#   2. open READ-ONLY (cryptsetup --readonly when LUKS -- passphrase
#      prompt; piped stdin works for scripting), mount read-only,
#   3. zfs load-key -L file://<key> for every encryptionroot under the
#      replica whose keystatus is unavailable,
#   4. unmount and close everything, loaded keys stay.
# Nothing is ever written to the keystore. Undo with:
#   zfs unload-key -r <received-rpool>
set -euo pipefail

rp="${1:?usage: unlock-replica.sh <received-rpool> (e.g. tank/recv/odin/rpool)}"
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: needs root (mount/cryptsetup/load-key); run with sudo" >&2
    exit 1
fi

ks=$(zfs list -H -r -t volume -o name "$rp" 2>/dev/null | grep -m1 '/keystore$') || true
if [[ -z "$ks" ]]; then
    echo "ERROR: no */keystore zvol under $rp; volumes present:" >&2
    zfs list -H -r -t volume -o name "$rp" >&2 || true
    exit 1
fi

dev="/dev/zvol/$ks"
for _ in $(seq 1 50); do [[ -b "$dev" ]] && break; sleep 0.2; done
if [[ ! -b "$dev" ]]; then
    echo "ERROR: no device node at $dev (volmode=none on the replica?)" >&2
    exit 1
fi

mnt=$(mktemp -d /run/zfsrecvd-ks.XXXXXX)
luks=""
cleanup() {
    umount "$mnt" 2>/dev/null || true
    if [[ -n "$luks" ]]; then
        cryptsetup close "$luks" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

if blkid -o value -s TYPE "$dev" 2>/dev/null | grep -q crypto_LUKS; then
    luks="zfsrecvd-ks-$$"
    echo "keystore is LUKS; passphrase:" >&2
    cryptsetup open --readonly "$dev" "$luks"
    mount -o ro "/dev/mapper/$luks" "$mnt"
else
    mount -o ro "$dev" "$mnt"
fi

key=$(find "$mnt" -maxdepth 3 -type f -name '*.key' | head -n 1)
if [[ -z "$key" ]]; then
    echo "ERROR: no *.key file inside the keystore" >&2
    exit 1
fi

n=0
while IFS=$'\t' read -r ds er st; do
    [[ "$er" == "$ds" && "$st" == "unavailable" ]] || continue
    echo "load-key: $ds"
    zfs load-key -L "file://$key" "$ds"
    n=$(( n + 1 ))
done < <(zfs list -H -r -o name,encryptionroot,keystatus "$rp")

if (( n == 0 )); then
    echo "nothing to unlock under $rp (already loaded, or not encrypted)"
else
    echo "$n encryptionroot(s) unlocked; undo with: zfs unload-key -r $rp"
fi
