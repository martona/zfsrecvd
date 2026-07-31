#!/usr/bin/env bash
# zfsrecvd protocol 2.1 receiver. socat (see listen.sh) spawns one
# instance per TLS connection; stdin/stdout are the socket, stderr goes to
# the journal.
#
# 2.1 (PROTOCOL.md §15b): the client's manifest carries snapshot and
# cursor-bookmark GUIDs; everything GUID-aware happens HERE, server-side --
# rename-aside of replaced lineages, the incremental-base guid veto,
# unknown-since stamping of receiver-only snapshots, received-bytes on the
# OK line. There is no 2.0 handler (owner decision, same doctrine as
# dropping 1.1): the fleet ships scripts per run, so a version-mismatched
# peer is a config error that fails clean at the greeting.
#
# A connection is one *session*: any number of sequential TREE exchanges,
# each being a client manifest, our state dump back, a series of
# SEND/RESUME/ABORT transfers, and an ENDTREE (prune + stamp). Streams are
# multiplexed over the socket with no framing; that works because bash's
# read consumes bytes one at a time (never past its newline), zfs recv
# stops at the stream's END record without needing EOF, and the client is
# forbidden from writing anything after a stream until it sees our result
# line. See PROTOCOL.md for the full contract; v1.1 is not supported (the
# fleet upgrades atomically via deploy.sh).

set -euo pipefail
set -f                       # never glob; we word-split protocol input
source /etc/zfsrecvd/cfgparser.sh
source /etc/zfsrecvd/retain.sh

# Field grammars from PROTOCOL.md §3. Anything outside these charsets is
# rejected before it reaches a zfs command line.
RE_DATASET='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
RE_SNAP='^[A-Za-z0-9._-]+$'
RE_SIZE='^([0-9]+|-)$'

log() { echo "$*" >&2; }          # to the journal
out() { printf '%s\n' "$*"; }     # to the client (the socket)

# Protocol errors are always session-fatal: tell the client if we still
# can, log why, and drop the connection.
proto_err() {
    out "ERR proto $*"
    log "protocol error: $*"
    exit 1
}

#
# ---- 1. authenticate CN -----------------------------------------------------
#
# The transport already verified the client cert against our CA; what's
# left is learning the CN it carried and checking the whitelist. The CN
# also names the client's namespace: everything it sends lands under
# recv_root/<CN>/.
#   socat transport:   OPENSSL-LISTEN verify=1 exports the CN in the env.
#   haproxy transport: haproxy terminated TLS and prepended a PROXY
#     protocol v2 header with the CN it extracted from the verified cert;
#     pp2_read_cn consumes exactly that header (fail-closed ladder, see
#     pp2.sh) and leaves the session bytes untouched on stdin.
if [[ "$transport" == "haproxy" ]]; then
    source /etc/zfsrecvd/pp2.sh
    if ! pp2_read_cn; then
        log "ERROR: bad/missing PROXY protocol header on the plaintext port (direct dial? haproxy misconfig?); dropping"
        exit 1
    fi
    cn="$PP2_CN"
else
    cn="${SOCAT_OPENSSL_X509_COMMONNAME-}"
    if [[ -z "$cn" ]]; then
        log "ERROR: TLS CN missing; socat not started with OPENSSL-LISTEN verify=1?"
        exit 1
    fi
fi
if ! [[ " ${allowed_hosts[*]} " == *" $cn "* ]]; then
    log "ERROR: CN '$cn' not authorized"
    exit 1
fi
safe_cn=${cn//[^[:alnum:]._-]/_}
dest_base="${recv_root}/${safe_cn}"
log "session from: $safe_cn"

#
# ---- 2. version sanity check ------------------------------------------------
#
# The fleet upgrades in one deploy, so this is a sanity check rather than
# a negotiation: any 2.x hello is answered with the one version we speak
# (2.1); a stale client fails clean at the greeting, exactly like 1.1
# before it (owner decision 2026-07-31: no 2.0 handler -- there is no
# mixed-version fleet, and rollback is redeploying the previous commit,
# both sides together).
IFS= read -r -t 30 hello || { log "ERROR: no version line"; exit 1; }
if ! [[ "$hello" =~ ^zfsrecvd2\.[0-9]+$ ]]; then
    log "ERROR: unsupported version '$hello'"
    exit 1
fi
out "OK zfsrecvd2.1"

#
# ---- session state ----------------------------------------------------------
#
declare -A made_parents=()   # parents already ensured this session (skip re-create)
base_ready=""                # dest_base existence confirmed (lazy, once)
tree_root=""                 # source-side root of the TREE currently in progress
received=()                  # dest datasets received this tree; stamped at ENDTREE

# Per-TREE 2.1 state (reset in handle_tree). All GUIDs are the u64 decimal
# zfs reports; comparison is exact-string.
man_ds=()                    # manifest datasets, client order (parents first)
declare -A man_gset=()       # ds -> " g1 g2 ..." client-side guids (snaps + cursor bookmarks)
declare -A man_ng=()         # "ds@snap" -> guid (snapshot entries only): the
                             # base veto compares by NAME first -- a client
                             # snapshot named like the base is what an -I/-i
                             # actually sends, and a surviving cursor of a
                             # since-recreated snap must not vouch for it
declare -A man_order=()      # ds -> space-joined snap names, client creation
                             # order (the -I range walk for collision checks)
declare -A rhave=()          # ds -> receiver snaps, comma-joined, creation order
declare -A rsg=()            # "ds@snap" -> receiver-side guid
rds_order=()                 # receiver datasets, first-seen (creation) order
declare -A renamed_aside=()  # ds renamed aside at TREE time (subtree roots)
declare -A sess_recvd=()     # ds received THIS session (guid veto skips them:
                             # their base snapshots were just written by us)

# Is a client-supplied path inside the tree announced by TREE? This is the
# scope check that keeps a session from writing outside its own subtree.
in_tree() {
    [[ "$1" == "$tree_root" || "$1" == "$tree_root"/* ]]
}

# Make sure recv_root/<CN> exists (unmounted). Created without -p on
# purpose: -p would ignore -o mountpoint=none, and a missing recv_root is
# an operator error we want to surface, not paper over.
ensure_base() {
    if [[ -z "$base_ready" ]]; then
        zfs list -H -o name "$dest_base" >/dev/null 2>&1 \
            || zfs create -o mountpoint=none "$dest_base" 2>/dev/null \
            || return 1
        base_ready=1
    fi
}

# Make sure the destination parent of a dataset exists, so that
# `zfs recv -e <parent>` has somewhere to land. Nonzero only when even the
# CN base can't be created (caller turns that into ERR refused).
ensure_parent() {
    local parent="${dest_base}/$1"
    parent="${parent%/*}"
    if [[ -n "${made_parents[$parent]:-}" ]]; then
        return 0
    fi
    ensure_base || return 1
    # -o is ignored with -p (hence ensure_base above); pre-existing is fine.
    zfs create -p "$parent" 2>/dev/null || true
    made_parents[$parent]=1
}

#
# ---- state dump -------------------------------------------------------------
#
# Everything we know about the tree, in two zfs invocations total: one
# snapshot listing (globally creation-sorted, which keeps each dataset's
# sub-list creation-sorted too) grouped into HAVE lines, and one property
# scan for pending resume TOKENs. Paths are translated to source-relative
# so both sides talk in the same names.
# Load the receiver's snapshot state for the tree into rhave/rsg/rds_order.
# One listing carries names AND guids; 2.0 sessions simply never read the
# guid side. The bash fill loop is linear in snapshot count -- fine for
# trees in the thousands (the awk-only fast path can return if it ever
# is not).
gather_state() {
    local dest_tree="${dest_base}/${tree_root}"
    local pfx="${dest_base}/"
    local rel sn gd
    rhave=(); rsg=(); rds_order=()
    while IFS=$'\t' read -r rel sn gd; do
        if [[ -z "${rhave[$rel]:-}" ]]; then
            rds_order+=( "$rel" )
            rhave[$rel]="$sn"
        else
            rhave[$rel]="${rhave[$rel]},$sn"
        fi
        rsg["$rel@$sn"]="$gd"
    done < <(zfs list -H -r -t snapshot -s creation -o name,guid "$dest_tree" 2>/dev/null \
        | awk -F'\t' -v pfx="$pfx" '
            {
                at = index($1, "@"); if (at == 0) next
                ds = substr($1, 1, at - 1)
                if (index(ds, pfx) != 1) next
                printf "%s\t%s\t%s\n", substr(ds, length(pfx) + 1), substr($1, at + 1), $2
            }
        ' || true)
}

# Is a dataset under (or at) a subtree renamed aside this TREE?
under_renamed() {
    local r
    for r in "${!renamed_aside[@]}"; do
        [[ "$1" == "$r" || "$1" == "$r"/* ]] && return 0
    done
    return 1
}

# Move a replaced lineage out of the way: <ds> -> <ds>.gone-<YYYYMMDD>
# (collision gets a numeric suffix). Any pending partial recv is discarded
# first -- its token references the old lineage and could never be
# satisfied by the newcomer anyway. The renamed subtree keeps its stamps
# and ages into ordinary orphan GC (PROTOCOL.md §22).
rename_aside() {   # $1 = source-relative ds; returns nonzero on failure
    local src="${dest_base}/$1"
    local tgt="${src}.gone-$(date -u +%Y%m%d)" n=1
    while zfs list -H -o name "$tgt" >/dev/null 2>&1; do
        tgt="${src}.gone-$(date -u +%Y%m%d)-$n"
        n=$(( n + 1 ))
    done
    zfs recv -A "$src" >/dev/null 2>&1 || true
    if zfs rename "$src" "$tgt" 2>/dev/null; then
        renamed_aside[$1]=1
        log "renamed aside: $src -> $tgt (no shared lineage with the source's '$1')"
        return 0
    fi
    log "WARNING: could not rename aside $src"
    return 1
}

# 2.1 TREE-time collision pass: a manifest dataset whose receiver-side
# snapshots share NO guid with the client's evidence (snapshots + cursor
# bookmarks) is a different thing wearing the same name -- rename it aside
# so the newcomer bootstraps clean and the old history survives. Requires
# evidence on BOTH sides: an empty manifest entry or a snapless receiver
# dataset is absence of evidence, and absence never triggers action.
resolve_collisions() {
    local d g hit sn
    for d in "${man_ds[@]}"; do
        [[ -n "${rhave[$d]:-}" ]] || continue
        [[ -n "${man_gset[$d]:-}" ]] || continue
        under_renamed "$d" && continue
        hit=""
        local -a rsl=()
        IFS=, read -r -a rsl <<<"${rhave[$d]}"
        for sn in "${rsl[@]}"; do
            g="${rsg[$d@$sn]:-}"
            if [[ -n "$g" && " ${man_gset[$d]} " == *" $g "* ]]; then
                hit=1
                break
            fi
        done
        if [[ -z "$hit" ]]; then
            rename_aside "$d" || true
        fi
    done
}

# Emit the state dump from the (post-collision-pass) gathered state:
# HAVE from rhave minus renamed subtrees, TOKEN from a live property scan
# similarly filtered. Paths are source-relative on the wire.
emit_state() {
    local dest_tree="${dest_base}/${tree_root}"
    local pfx="${dest_base}/"
    local d nh=0 nt=0 tds ttk
    for d in "${rds_order[@]}"; do
        under_renamed "$d" && continue
        out "HAVE $d ${rhave[$d]}"
        nh=$(( nh + 1 ))
    done
    while IFS=$'\t' read -r tds ttk; do
        [[ -n "$tds" ]] || continue
        under_renamed "$tds" && continue
        out "TOKEN $tds $ttk"
        nt=$(( nt + 1 ))
    done < <(zfs get -H -r -t filesystem,volume -o name,value receive_resume_token "$dest_tree" 2>/dev/null \
        | awk -F'\t' -v pfx="$pfx" '
            $2 != "-" && index($1, pfx) == 1 {
                printf "%s\t%s\n", substr($1, length(pfx) + 1), $2
            }
        ' || true)
    out ""
    log "state sent: $nh datasets known, $nt pending resumes"
}

#
# ---- transfers --------------------------------------------------------------
#
# SEND <ds> <from|-> <to> <est|->: validate, answer GO, hand the socket to
# zfs recv. Refusals (scope, missing recv_root) happen before GO and leave
# the session healthy. A recv failure after the stream started is fatal to
# the session: we can't know how much of the unframed stream was consumed,
# so resynchronization is impossible (PROTOCOL.md §7) -- the client
# reconnects and the interrupted dataset comes back via its resume token.
# Sum of a `zfs recv -v` stdout capture, in bytes. recv prints one
# "received <size> stream in ..." line per snapshot stream in the package;
# sizes are zfs_nicebytes-rounded (~3 significant figures -- accepted,
# PROTOCOL.md §15b). mawk-safe.
recv_bytes() {   # $1 = capture file -> bytes on stdout, or nothing
    awk '
        /^received / {
            v = $2
            mult = 1
            if      (v ~ /K/) mult = 1024
            else if (v ~ /M/) mult = 1048576
            else if (v ~ /G/) mult = 1073741824
            else if (v ~ /T/) mult = 1099511627776
            else if (v ~ /P/) mult = 1125899906842624
            gsub(/[^0-9.]/, "", v)
            total += v * mult
        }
        END { if (total > 0) printf "%.0f\n", total }
    ' "$1" 2>/dev/null || true
}

do_send() {
    local _ ds from to est extra
    read -r _ ds from to est extra <<<"$1"
    [[ -n "$est" && -z "$extra" ]] || proto_err "SEND arity"
    [[ "$ds" =~ $RE_DATASET ]] || proto_err "SEND dataset"
    [[ "$from" == "-" || "$from" =~ $RE_SNAP ]] || proto_err "SEND from-snap"
    [[ "$to" =~ $RE_SNAP ]] || proto_err "SEND to-snap"
    [[ "$est" =~ $RE_SIZE ]] || proto_err "SEND size"
    if ! in_tree "$ds"; then
        out "ERR refused $ds not under session tree"
        log "refused SEND $ds (outside $tree_root)"
        return 0
    fi
    # GUID guardrails (PROTOCOL.md §15b), both before GO so the
    # session survives. Datasets received THIS session are exempt: their
    # bases were just written by us and are not in the TREE-time state.
    if [[ -z "${sess_recvd[$ds]:-}" ]]; then
        if [[ "$from" != "-" ]]; then
            # Plan-time veto: an incremental whose base name we hold but
            # whose lineage the client does not share would die
            # mid-stream and take the session with it. Refuse instead.
            local bg="${rsg[$ds@$from]:-}" cg
            if [[ -z "$bg" ]]; then
                out "ERR refused $ds incremental base @$from not present on receiver"
                log "refused SEND $ds: base @$from unknown here"
                return 0
            fi
            cg="${man_ng[$ds@$from]:-}"
            if [[ -n "$cg" ]]; then
                # client sends -I from its snapshot @from: guids must agree
                if [[ "$cg" != "$bg" ]]; then
                    out "ERR refused $ds guid-mismatch base @$from (name matches, lineage does not)"
                    log "refused SEND $ds: guid veto on @$from (client $cg vs ours $bg)"
                    return 0
                fi
                # and the -I range (from, to] must not carry a snapshot
                # whose name we hold as a DIFFERENT object -- recv dies on
                # "destination already exists" (proven empirically, T12)
                # and takes the session with it. Refuse instead; the
                # client rebootstraps and our history moves aside whole.
                local inrange="" mn rg
                for mn in ${man_order[$ds]:-}; do
                    if [[ -n "$inrange" ]]; then
                        rg="${rsg[$ds@$mn]:-}"
                        if [[ -n "$rg" && "$rg" != "${man_ng[$ds@$mn]}" ]]; then
                            out "ERR refused $ds snapshot-collision @$mn (receiver holds a different object by that name)"
                            log "refused SEND $ds: snapshot-collision on @$mn"
                            return 0
                        fi
                        [[ "$mn" == "$to" ]] && break
                    elif [[ "$mn" == "$from" ]]; then
                        inrange=1
                    fi
                done
            else
                # no client snapshot named @from: a cursor catch-up
                # (single-step -i; only @to lands). A bookmark must vouch
                # for our base, and @to itself must not collide.
                if [[ " ${man_gset[$ds]:-} " != *" $bg "* ]]; then
                    out "ERR refused $ds guid-mismatch base @$from (no lineage evidence)"
                    log "refused SEND $ds: guid veto on @$from (bookmarkless)"
                    return 0
                fi
                local tg="${rsg[$ds@$to]:-}"
                if [[ -n "$tg" && "$tg" != "${man_ng[$ds@$to]:-}" ]]; then
                    out "ERR refused $ds snapshot-collision @$to (receiver holds a different object by that name)"
                    log "refused SEND $ds: snapshot-collision on @$to (catch-up)"
                    return 0
                fi
            fi
        elif [[ -n "${rhave[$ds]:-}" ]] && ! under_renamed "$ds"; then
            # Full send onto an existing snapshotted dataset: -F would
            # clobber receiver history (and a zvol -R stream dies
            # outright). Rename the old lineage aside instead -- the
            # history-preserving resolution, same as the TREE pass.
            if ! rename_aside "$ds"; then
                out "ERR refused $ds cannot move existing diverged dataset aside"
                return 0
            fi
            made_parents=()   # a moved subtree may invalidate ensured parents
        fi
    fi
    if ! ensure_parent "$ds"; then
        out "ERR refused $ds cannot create destination (recv_root '$recv_root' missing?)"
        log "refused SEND $ds: cannot create destination under $dest_base"
        return 0
    fi
    local parent="${dest_base}/${ds}"
    parent="${parent%/*}"
    out "GO"
    local errf vf rc detail bytes=""
    errf=$(mktemp)
    vf=$(mktemp)
    set +e
    # -v prints its summary to STDOUT -- which is the socket here.
    # The redirect is load-bearing, not cosmetic.
    zfs recv -s -u -v -F -e -x canmount "$parent" >"$vf" 2>"$errf"
    rc=$?
    set -e
    if (( rc == 0 )); then
        bytes=$(recv_bytes "$vf")
        rm -f -- "$errf" "$vf"
        out "OK $ds ${bytes:--}"
        received+=( "${dest_base}/${ds}" )
        sess_recvd[$ds]=1
        if [[ "$est" == "-" ]]; then
            log "received $ds ($from -> $to${bytes:+, $bytes bytes})"
        else
            log "received $ds ($from -> $to, ~$est bytes${bytes:+, $bytes on wire})"
        fi
    else
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf" "$vf"
        out "ERR recv $ds ${detail:-zfs recv exit $rc}"
        log "recv FAILED for $ds: ${detail:-exit $rc}; closing session"
        exit 1
    fi
}

# RESUME <ds> <est|->: like SEND, but the client continues an interrupted
# stream from our receive_resume_token, so recv targets the dataset itself
# rather than the -e parent form.
do_resume() {
    local _ ds est extra
    read -r _ ds est extra <<<"$1"
    [[ -n "$est" && -z "$extra" ]] || proto_err "RESUME arity"
    [[ "$ds" =~ $RE_DATASET ]] || proto_err "RESUME dataset"
    [[ "$est" =~ $RE_SIZE ]] || proto_err "RESUME size"
    if ! in_tree "$ds"; then
        out "ERR refused $ds not under session tree"
        return 0
    fi
    out "GO"
    local errf vf rc detail bytes=""
    errf=$(mktemp)
    vf=$(mktemp)
    set +e
    # see do_send: -v writes to stdout = the socket; redirect away
    zfs recv -s -v "${dest_base}/${ds}" >"$vf" 2>"$errf"
    rc=$?
    set -e
    if (( rc == 0 )); then
        bytes=$(recv_bytes "$vf")
        rm -f -- "$errf" "$vf"
        out "OK $ds ${bytes:--}"
        received+=( "${dest_base}/${ds}" )
        sess_recvd[$ds]=1
        log "resumed $ds${bytes:+ ($bytes bytes on wire)}"
    else
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf" "$vf"
        out "ERR recv $ds ${detail:-zfs recv exit $rc}"
        log "resume FAILED for $ds: ${detail:-exit $rc}; closing session"
        exit 1
    fi
}

# ABORT <ds>: discard our pending resume state (zfs recv -A) because the
# client can no longer satisfy the token (its side of the resume was
# pruned). No stream is involved, so failure here is a refusal, not a
# session-killer -- the byte stream is still in sync either way.
do_abort() {
    local _ ds extra
    read -r _ ds extra <<<"$1"
    [[ -n "$ds" && -z "$extra" ]] || proto_err "ABORT arity"
    [[ "$ds" =~ $RE_DATASET ]] || proto_err "ABORT dataset"
    if ! in_tree "$ds"; then
        out "ERR refused $ds not under session tree"
        return 0
    fi
    local errf detail
    errf=$(mktemp)
    if zfs recv -A "${dest_base}/${ds}" 2>"$errf"; then
        rm -f -- "$errf"
        out "OK $ds"
        log "aborted pending resume on $ds"
    else
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf"
        out "ERR refused $ds abort failed: ${detail:-unknown}"
        log "recv -A failed for $ds: ${detail:-unknown}"
    fi
}

#
# ---- pruning + stamping (at ENDTREE) ----------------------------------------
#
# With a [retain] grid in the config (fleet runs since D), each dataset's
# prunable snapshots are thinned by the bucket selector in retain.sh
# (hourly/daily/weekly/monthly representatives; fail-safe: anything the
# selector can't reason about is kept). Without one, the legacy behavior:
# keep the newest keep_count per dataset. Either way only names matching
# a prune-prefix are candidates; manual and foreign snapshots are never
# touched.
prune_tree() {
    local dest_tree="${dest_base}/${tree_root}"
    local snap ds name prefix matched extra i pruned=0
    declare -A psnaps=()     # dataset -> space-joined prunable snaps, oldest first
    local order=()
    while IFS= read -r snap; do
        ds="${snap%@*}"
        name="${snap#*@}"
        matched=""
        for prefix in "${prune_prefixes[@]}"; do
            if [[ "$name" == "$prefix"* ]]; then
                matched=1
                break
            fi
        done
        [[ -n "$matched" ]] || continue
        if [[ -z "${psnaps[$ds]:-}" ]]; then
            order+=( "$ds" )
        fi
        psnaps[$ds]="${psnaps[$ds]:-}${psnaps[$ds]:+ }$snap"
    done < <(zfs list -H -r -t snapshot -s creation -o name "$dest_tree" 2>/dev/null || true)
    local list=() doomed freed=0 b
    for ds in "${order[@]}"; do
        read -r -a list <<<"${psnaps[$ds]}"
        if [[ -n "$retain_spec" ]]; then
            doomed=$(printf '%s\n' "${list[@]##*@}" | retain_destroy "$retain_spec")
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                log "pruning ${ds}@${name}"
                b=$(zfs get -Hp -o value used "${ds}@${name}" 2>/dev/null) || b=0
                [[ "$b" =~ ^[0-9]+$ ]] || b=0
                if zfs destroy "${ds}@${name}" 2>/dev/null; then
                    pruned=$(( pruned + 1 ))
                    freed=$(( freed + b ))
                    if [[ "$cert_dir" != "/etc/zfsrecvd" ]]; then
                        echo "${ds}@${name}" >> "${cert_dir}/pruned.list" 2>/dev/null || true
                    fi
                else
                    log "WARNING: failed to prune ${ds}@${name}"
                fi
            done <<<"$doomed"
        else
            extra=$(( ${#list[@]} - keep_count ))
            for (( i = 0; i < extra; i++ )); do
                log "pruning ${list[i]}"
                b=$(zfs get -Hp -o value used "${list[i]}" 2>/dev/null) || b=0
                [[ "$b" =~ ^[0-9]+$ ]] || b=0
                if zfs destroy "${list[i]}" 2>/dev/null; then
                    pruned=$(( pruned + 1 ))
                    freed=$(( freed + b ))
                    if [[ "$cert_dir" != "/etc/zfsrecvd" ]]; then
                        echo "${list[i]}" >> "${cert_dir}/pruned.list" 2>/dev/null || true
                    fi
                else
                    log "WARNING: failed to prune ${list[i]}"
                fi
            done
        fi
    done
    if (( pruned > 0 )); then
        # freed = sum of each snap's unique bytes at destroy time; blocks
        # shared between adjacent doomed snaps are attributed to neither,
        # so this UNDERestimates. Honest enough for the run report.
        log "pruned $pruned snapshots under $dest_tree (~$freed bytes reclaimed)"
        # per-run reclaim ledger for fleetrun's report -- run dirs only,
        # never the static /etc/zfsrecvd
        if [[ "$cert_dir" != "/etc/zfsrecvd" ]]; then
            echo "$freed" >> "${cert_dir}/pruned.bytes" 2>/dev/null || true
        fi
    fi
}

# ENDTREE: prune, then stamp everything received this tree with
# zfsrecvd:last-recv (marks the dataset as ours + records freshness; this
# is the foundation the future orphan GC reads). One zfs set for the whole
# batch, with a per-dataset fallback in case a zfs version dislikes
# multiple targets.
# 2.1 absence bookkeeping (PROTOCOL.md §22), both levels, at ENDTREE:
#   datasets:  a receiver dataset the manifest does not list is absent at
#              source -- the session itself is the liveness proof, so the
#              orphan clock starts NOW (manifest-driven GC; the old
#              relative-staleness inference is retired). Reappearance in
#              a manifest clears the clock. The server owns ALL clocks;
#              gc.sh only reads them.
#   snapshots: judged by GUID against the manifest evidence, non-prefix
#              names only (grid-prefix snaps are the retention grid's
#              business). unknown-since starts at FIRST absence; a guid
#              reappearing in the manifest is the all-clear.
# Stamps are read with source=local,received -- received survives pool
# migrations and is per-dataset, so it cannot cloak (§17 corollary);
# inherited values are still nothing. `zfs inherit` clears local AND
# received (verified by suite).
stamp_absent() {
    local now d sn g full pfx matched
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local -a to_stamp=() to_clear=() dto_stamp=() dto_clear=() rsl=()
    declare -A stamped=() dstamped=() man_in=()
    for d in "${man_ds[@]}"; do
        man_in[$d]=1
    done
    while IFS=$'\t' read -r full g; do
        if [[ -n "$full" && "$g" != "-" ]]; then
            stamped[$full]=1
        fi
    done < <(zfs get -H -r -s local,received -t snapshot -o name,value zfsrecvd:unknown-since "${dest_base}/${tree_root}" 2>/dev/null || true)
    while IFS=$'\t' read -r full g; do
        if [[ -n "$full" && "$g" != "-" ]]; then
            dstamped[$full]=1
        fi
    done < <(zfs get -H -r -s local,received -t filesystem,volume -o name,value zfsrecvd:orphan-since "${dest_base}/${tree_root}" 2>/dev/null || true)
    # dataset level: membership in the DS list alone (the manifest is
    # complete by contract §5, guid entries or not)
    for d in "${rds_order[@]}"; do
        under_renamed "$d" && continue
        full="${dest_base}/${d}"
        if [[ -n "${man_in[$d]:-}" ]]; then
            if [[ -n "${dstamped[$full]:-}" ]]; then
                dto_clear+=( "$full" )
            fi
        elif [[ -z "${dstamped[$full]:-}" ]]; then
            dto_stamp+=( "$full" )
        fi
    done
    for d in "${man_ds[@]}"; do
        [[ -n "${rhave[$d]:-}" ]] || continue
        # snapshot identity needs guid evidence: a bare manifest entry
        # says nothing about the client's snapshots, and absence of
        # evidence never starts a reclaim clock
        [[ -n "${man_gset[$d]:-}" ]] || continue
        under_renamed "$d" && continue
        IFS=, read -r -a rsl <<<"${rhave[$d]}"
        for sn in "${rsl[@]}"; do
            matched=""
            for pfx in "${prune_prefixes[@]}"; do
                if [[ "$sn" == "$pfx"* ]]; then
                    matched=1
                    break
                fi
            done
            [[ -n "$matched" ]] && continue
            full="${dest_base}/${d}@${sn}"
            g="${rsg[$d@$sn]:-}"
            if [[ -n "$g" && " ${man_gset[$d]:-} " == *" $g "* ]]; then
                if [[ -n "${stamped[$full]:-}" ]]; then
                    to_clear+=( "$full" )
                fi
            elif [[ -z "${stamped[$full]:-}" ]]; then
                to_stamp+=( "$full" )
            fi
        done
    done
    if [[ ${#dto_stamp[@]} -gt 0 ]]; then
        if ! zfs set "zfsrecvd:orphan-since=$now" "${dto_stamp[@]}" 2>/dev/null; then
            for full in "${dto_stamp[@]}"; do
                zfs set "zfsrecvd:orphan-since=$now" "$full" 2>/dev/null || true
            done
        fi
        log "stamped ${#dto_stamp[@]} manifest-absent dataset(s) orphan-since=$now"
    fi
    if [[ ${#dto_clear[@]} -gt 0 ]]; then
        if ! zfs inherit zfsrecvd:orphan-since "${dto_clear[@]}" 2>/dev/null; then
            for full in "${dto_clear[@]}"; do
                zfs inherit zfsrecvd:orphan-since "$full" 2>/dev/null || true
            done
        fi
        log "cleared orphan-since on ${#dto_clear[@]} reappeared dataset(s)"
    fi
    if [[ ${#to_stamp[@]} -gt 0 ]]; then
        if ! zfs set "zfsrecvd:unknown-since=$now" "${to_stamp[@]}" 2>/dev/null; then
            for full in "${to_stamp[@]}"; do
                zfs set "zfsrecvd:unknown-since=$now" "$full" 2>/dev/null || true
            done
        fi
        log "stamped ${#to_stamp[@]} receiver-only snapshot(s) unknown-since=$now"
    fi
    if [[ ${#to_clear[@]} -gt 0 ]]; then
        if ! zfs inherit zfsrecvd:unknown-since "${to_clear[@]}" 2>/dev/null; then
            for full in "${to_clear[@]}"; do
                zfs inherit zfsrecvd:unknown-since "$full" 2>/dev/null || true
            done
        fi
        log "cleared unknown-since on ${#to_clear[@]} reappeared snapshot(s)"
    fi
}

do_endtree() {
    prune_tree
    stamp_absent
    if [[ ${#received[@]} -gt 0 ]]; then
        local stamp
        stamp="zfsrecvd:last-recv=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! zfs set "$stamp" "${received[@]}" 2>/dev/null; then
            local d
            for d in "${received[@]}"; do
                zfs set "$stamp" "$d" 2>/dev/null || true
            done
        fi
        log "stamped ${#received[@]} datasets"
    fi
    log "tree $tree_root complete: ${#received[@]} received this session"
    out "OK ENDTREE"
}

#
# ---- TREE handler -----------------------------------------------------------
#
# Read the client's manifest (validated but, in 2.0, only logged), send the
# state dump, then serve transfers until ENDTREE hands control back to the
# session loop.
handle_tree() {   # $1 = tree root, $2 = target snapname
    tree_root="$1"
    received=()
    man_ds=(); man_gset=(); man_ng=(); man_order=(); renamed_aside=(); sess_recvd=()
    local snap="$2" line d ents e nm gd manifest_count=0 ended=""
    local -a el=()
    while IFS= read -r -t 120 line; do
        if [[ -z "$line" ]]; then
            ended=1
            break
        fi
        # Manifest: DS <ds> [entry,entry,...] where an entry is
        # <snap>:<guid> or #<bookmark>:<guid> ('#' is outside the
        # snapname charset, so the two are unambiguous). Bookmark
        # entries are the client's replication cursors -- lineage
        # evidence for the collision pass, nothing else. A bare DS line
        # (no snapshots, no cursors) is legal and carries no evidence.
        if [[ "$line" =~ ^DS\ ([A-Za-z0-9._/-]+)(\ ([A-Za-z0-9._#:,-]+))?$ ]]; then
            d="${BASH_REMATCH[1]}"
            ents="${BASH_REMATCH[3]:-}"
            in_tree "$d" || proto_err "manifest dataset outside tree: $d"
            man_ds+=( "$d" )
            if [[ -n "$ents" ]]; then
                IFS=, read -r -a el <<<"$ents"
                for e in "${el[@]}"; do
                    nm="${e%:*}"
                    gd="${e##*:}"
                    if [[ "$e" != *:* || -z "$nm" ]] || ! [[ "$gd" =~ ^[0-9]+$ ]]; then
                        proto_err "bad manifest entry for $d"
                    fi
                    man_gset[$d]="${man_gset[$d]:-}${man_gset[$d]:+ }$gd"
                    if [[ "$nm" != "#"* ]]; then
                        man_ng["$d@$nm"]="$gd"
                        man_order[$d]="${man_order[$d]:-}${man_order[$d]:+ }$nm"
                    fi
                done
            fi
            manifest_count=$(( manifest_count + 1 ))
        else
            proto_err "bad manifest line"
        fi
    done
    [[ -n "$ended" ]] || proto_err "eof/timeout in manifest"
    log "TREE $tree_root@$snap ($manifest_count datasets in manifest)"
    gather_state
    resolve_collisions
    out "OK TREE"
    emit_state

    while true; do
        IFS= read -r -t 300 line || { log "eof/idle in transfer loop"; exit 1; }
        case "$line" in
            SEND\ *)   do_send "$line" ;;
            RESUME\ *) do_resume "$line" ;;
            ABORT\ *)  do_abort "$line" ;;
            ENDTREE)   do_endtree; return 0 ;;
            *)         proto_err "unexpected in transfer loop" ;;
        esac
    done
}

#
# ---- session loop -----------------------------------------------------------
#
# Between trees a session idles here; a client that goes quiet for two
# minutes is dropped (so-keepalive on the socket reaps dead peers too).
while true; do
    IFS= read -r -t 120 line || { log "session idle/eof; closing"; exit 0; }
    case "$line" in
        TREE\ *)
            read -r _ troot tsnap textra <<<"$line"
            [[ -n "${tsnap:-}" && -z "${textra:-}" ]] || proto_err "TREE arity"
            [[ "$troot" =~ $RE_DATASET ]] || proto_err "TREE root"
            [[ "$tsnap" =~ $RE_SNAP ]] || proto_err "TREE snap"
            handle_tree "$troot" "$tsnap"
            ;;
        BYE)
            log "session ended cleanly"
            exit 0
            ;;
        *)
            proto_err "expected TREE or BYE"
            ;;
    esac
done
