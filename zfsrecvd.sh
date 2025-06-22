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
    exit 1
fi
if ! [[ " ${allowed_hosts[*]} " == *" $cn "* ]]; then
    echo "ERROR: CN '$cn' not authorized" >&2
    exit 1
fi
safe_cn=${cn//[^[:alnum:]._-]/_}           # basic sanitization
echo "Processing connection from: $safe_cn" >&2

#
# ---- 2. read header lines ---------------------------------------------------
#
lines=()
while true; do
    IFS= read -r line || { echo "ERROR: reading header" >&2; exit 1; }
    if [[ -z $line ]]; then                # blank line => list finished
        break
    fi
    lines+=( "$line" )
done
if [[ ${#lines[@]} -lt 2 ]]; then
    echo "ERROR: expected at least 2 lines header" >&2
    exit 119
fi

[[ "${lines[0]}" == "zfsrecvd1.1" ]] || { echo "ERROR: unsupported version '${lines[0]}'" >&2; exit 1; }
intent="${lines[1]}"
[[ "$intent" =~ ^[A-Za-z0-9._/-]+@[A-Za-z0-9._-]+$ ]] || { echo "ERROR: malformed intent: [$intent]" >&2; exit 1; }

dataset_with_snap="$intent"                # e.g. "tank/outer/inner/actual@snap2025-06-18" 
dataset="${dataset_with_snap%@*}"          # strip "@snap"
leaf="${dataset##*/}"                      # last component
parent="${dataset%/*}"                     # everything before leaf
[[ "$parent" == "$dataset" ]] && parent="" # no slash case
echo "Intent: $dataset_with_snap" >&2
dest_base="${recv_root}/${safe_cn}"        # ebs/recv/hostname
dest_parent="$dest_base"
[[ -n "$parent" ]] && dest_parent="${dest_base}/${parent}" # ebs/recv/hostname/ds_path_minus_last_component


#
# ---- 3. resume? -------------------------------------------------------------
#
token_ds=""
token_val=""
while read -r ds; do
  # Check if the receive_resume_token property is set and not empty ('-')
  token_val=$(zfs get -H -p -o value receive_resume_token "$ds")
  if [[ "$token_val" != "-" ]]; then
    token_ds="$ds"
    break
  fi
done < <(zfs list -H -o name -t filesystem,volume -r "${dest_base}/${dataset}" 2>/dev/null || true)

if [[ -n "$token_ds" ]]; then
    # tell client that we've found a token; we expect it to resume from it.
    echo "TOKEN: $token_ds=$token_val"
    echo
    echo "Resuming dataset: [${token_ds}]" >&2
    zfs recv "$token_ds"
    echo "Successfully resumed & completed [${token_ds}]" >&2
    echo DONE
    echo
    exit 0
fi

#
# ---- 3. ensure parent datasets exist ----------------------------------------
#

# If hostname wasn't seen before, create its root dataset without a mountpoint.
zfs list -H "$dest_base" >/dev/null 2>&1 || zfs create -o mountpoint=none "$dest_base"

# Create full path for recv target if doesn't exist (-o ignored with -p by zfs,
# which is why we had to do the above step separately).
# Ignore errors here, e.g. if path already exists.
zfs create -p "$dest_parent" 2>/dev/null || true

#
# ---- 4. send snapshot list back to client ---------------------------------
#
# List any existing snapshots for the exact dataset path.
# Respond with this to client.
echo "Listing existing snapshots for: ${dest_base}/$dataset" >&2
zfs list -H -o name -t snapshot "${dest_base}/${dataset}" 2>/dev/null | awk 'NF==1 {printf "SNAPSHOT: %s\n", $1}' | tee /dev/stderr || true
# Complete the list with a single empty line.
echo

#
# ---- 5. hand stream off to ZFS ----------------------------------------------
#
echo "Receiving: $dataset_with_snap" >&2
/sbin/zfs recv -s -u -F -e "$dest_parent"
echo "Successfully completed: $dataset_with_snap" >&2
printf 'DONE\n\n'
