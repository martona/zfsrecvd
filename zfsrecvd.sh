#!/usr/bin/env bash
# Wrapper for socat -> ZFS receive with simple header protocol
#   * Mutual‑TLS already done by socat; we just check if CN is whitelisted.
#   * Creates ebs/recv/<CN>/<ds_path minus last component>
#   * Finally execs:  zfs recv -u -F -e <parent>

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

#
# ---- 1. authenticate CN -----------------------------------------------------
#
cn="${SOCAT_OPENSSL_X509_COMMONNAME-}"
if [[ -z "$cn" ]]; then
    echo "ERROR: TLS CN missing; socat not started with OPENSSL-LISTEN verify=1?" >&2
    exit 111
fi
if ! [[ " ${allowed_hosts[*]} " == *" $cn "* ]]; then
    echo "ERROR: CN '$cn' not authorized" >&2
    exit 113
fi
safe_cn=${cn//[^[:alnum:]._-]/_}           # basic sanitization
echo "Processing connection from: $safe_cn" >&2

#
# ---- 2. read header lines ---------------------------------------------------
#
IFS= read -r version || { echo "ERROR: stream closed before header" >&2; exit 120; }
[[ "$version" == "zfsrecvd1.0" ]] || { echo "ERROR: unsupported header '$version'" >&2; exit 121; }

IFS= read -r header || { echo "ERROR: dataset line missing" >&2; exit 122; }
[[ "$header" =~ ^[A-Za-z0-9._/-]+@[A-Za-z0-9._-]+$ ]] || { echo "ERROR: malformed dataset line '$header'" >&2; exit 123; }

dataset_with_snap="$header"                # e.g. "tank/outer/inner/actual@snap2025-06-18" 
dataset="${dataset_with_snap%@*}"          # strip "@snap"
leaf="${dataset##*/}"                      # last component
parent="${dataset%/*}"                     # everything before leaf
[[ "$parent" == "$dataset" ]] && parent="" # no slash case
echo "Receiving: $dataset_with_snap" >&2

#
# ---- 3. ensure parent datasets exist ----------------------------------------
#
dest_base="${recv_root}/${safe_cn}"
dest_parent="$dest_base"
[[ -n "$parent" ]] && dest_parent="${dest_base}/${parent}"

# if hostname wasn't seen before, create its dataset without a mountpoint
zfs list -H "$dest_base" >/dev/null 2>&1 || zfs create -o mountpoint=none "$dest_base"

# create full path if doesn't exist (-o ignored here by zfs)
# ignore errors here, e.g. if path already exists
zfs create -p "$dest_parent" 2>/dev/null || true

#
# ---- 3½. send snapshot list back to client ---------------------------------
#
# List any existing snapshots for the exact dataset path that will be updated.
# Respond with this to client, followed by an empty line as the delimiter.
# Again we ignore errors in case the dataset doesn't exist here or has no snapshots.
zfs list -H -o name -t snapshot "${dest_base}/${dataset}" 2>/dev/null || true
echo

# Client will process this list and decide whether to send a full or 
# incremental send. Our `zfs recv` will handle both cases.

#
# ---- 4. hand stream off to ZFS ----------------------------------------------
#
exec /sbin/zfs recv -u -F -e "$dest_parent"
