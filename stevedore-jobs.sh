#!/usr/bin/env bash
# stevedore-jobs.sh -- `steve jobs`: a full-screen editor for fleet.conf's
# job matrix. Receiver identities across, (source, tree) pairs down; a
# toggled cell IS a job row. Offline by design: it reads and rewrites the
# config file only -- no ssh, no zfs.
#
#   steve jobs [-c fleet.conf]
#
# File-surgery contract: everything outside the [jobs] section body is
# preserved byte-for-byte, except [hosts] rows this session adds
# (appended to the section) or removes. The [jobs] body is regenerated
# row-major and column-aligned on save; comment lines inside it are
# kept, hoisted to the top of the section. Saves validate through
# fleetparser (loud, fatal parser = the backstop) into a temp file +
# atomic rename; the previous version is kept once as <conf>.bak.
#
# Keys: arrows/hjkl move . space/enter toggle . a add dataset .
#       H add receiver . d delete row . D delete receiver . s save .
#       q quit
#
# STEVEDORE_JOBS_SCRIPT=1 runs the key loop against non-tty stdin: the
# unit suite drives it with piped keystrokes and no stty/tput is ever
# touched (text prompts read whole lines from the same stream).

set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$here/stevedore-paths.sh"
# for FLEET_RE_IDENT / FLEET_RE_TREE and save-time validation
source "$here/stevedore-fleetparser.sh"

CONF="$STEVE_ETC/fleet.conf"
while (( $# > 0 )); do
    case "$1" in
        -c|--config) CONF="${2:?}"; shift 2 ;;
        *) echo "usage: steve jobs [-c fleet.conf]" >&2; exit 64 ;;
    esac
done
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: $CONF not found" >&2
    exit 78
fi
# refuse to open a config that doesn't parse: silently "repairing" a
# hand-edit typo by regenerating around it would hide the mistake
if ! _openerr=$(bash -c "source '$here/stevedore-fleetparser.sh'; fleet_parse '$CONF'" 2>&1); then
    echo "ERROR: $CONF does not parse; fix it by hand first:" >&2
    echo "  ${_openerr##*$'\n'}" >&2
    exit 78
fi

SCRIPTED="${STEVEDORE_JOBS_SCRIPT:-}"
if [[ -z "$SCRIPTED" ]] && ! [[ -t 0 && -t 2 ]]; then
    echo "ERROR: steve jobs needs a terminal" >&2
    exit 1
fi

#
# ---------- file model (pure core; the unit suite drives these) --------------
#
FL=()                     # raw file lines
declare -A DROPLN=()      # original line index -> 1 = omit on save
JOBS_HDR=-1               # line index of the [jobs] header
declare -A JOBSBODY=()    # original line indices replaced by the regenerated body
JCOMMENTS=()              # comment/blank lines from inside the [jobs] body
HOSTS_HDR=-1              # line index of the [hosts] header (-1: no section)
HOSTS_ANCHOR=-1           # last content line of [hosts]; new rows go after it
NEWHOSTS=()               # host rows added this session
JR=()                     # rows: "src<TAB>tree", first-seen order
JC=()                     # cols: receiver identities, [hosts] order
declare -A CELL=()        # "src|tree|dest" -> 1
declare -A HOSTLN=()      # host identity -> its [hosts] line index

# trim + de-comment exactly like fleetparser, but non-destructively
_clean() {
    local l="${1%%#*}"
    l=${l//$'\r'/}
    l="${l#"${l%%[![:space:]]*}"}"
    printf '%s' "${l%"${l##*[![:space:]]}"}"
}

jobs_load() {
    local nr=0 section="" line c w
    local -a words
    FL=(); JCOMMENTS=(); JR=(); JC=(); NEWHOSTS=()
    CELL=(); HOSTLN=(); DROPLN=(); JOBSBODY=()
    JOBS_HDR=-1; HOSTS_HDR=-1; HOSTS_ANCHOR=-1
    while IFS= read -r line || [[ -n "$line" ]]; do
        FL+=( "$line" )
        c=$(_clean "$line")
        if [[ "$c" =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            case "$section" in
                jobs)  JOBS_HDR=$nr ;;
                hosts) HOSTS_HDR=$nr; HOSTS_ANCHOR=$nr ;;
            esac
            nr=$(( nr + 1 ))
            continue
        fi
        case "$section" in
            jobs)
                if [[ -z "$c" ]]; then
                    # comment lines inside the body are kept, hoisted to
                    # the top of the section; pure blanks are dropped
                    if [[ -n "${line//[[:space:]]/}" ]]; then
                        JCOMMENTS+=( "$line" )
                    fi
                else
                    read -r -a words <<<"$c"
                    if (( ${#words[@]} == 3 )); then
                        jobs_row_add "${words[0]}" "${words[1]}"
                        CELL["${words[0]}|${words[1]}|${words[2]}"]=1
                    fi
                fi
                JOBSBODY[$nr]=1
                ;;
            hosts)
                if [[ -n "$c" ]]; then
                    HOSTS_ANCHOR=$nr
                    read -r -a words <<<"$c"
                    HOSTLN[${words[0]}]=$nr
                    for w in "${words[@]:1}"; do
                        if [[ "$w" == recv=* ]]; then
                            JC+=( "${words[0]}" )
                        fi
                    done
                fi
                ;;
        esac
        nr=$(( nr + 1 ))
    done < "$CONF"
    # a dest used by jobs but somehow absent from [hosts] (invalid config)
    # still gets a column so the matrix reflects reality; validation on
    # save reports it loudly either way
    local k d
    for k in "${!CELL[@]}"; do
        d="${k##*|}"
        if ! jobs_has_col "$d"; then
            JC+=( "$d" )
        fi
    done
}

jobs_has_col() {
    local c
    for c in "${JC[@]}"; do
        [[ "$c" == "$1" ]] && return 0
    done
    return 1
}

# add a (src, tree) row if new; result index in ROWIDX. NOT a $(...)
# helper on purpose: it mutates JR, and a subshell would lose that (the
# pick_job lesson, PROTOCOL.md §19).
ROWIDX=-1
jobs_row_add() {
    local key="$1"$'\t'"$2" i
    for (( i = 0; i < ${#JR[@]}; i++ )); do
        if [[ "${JR[i]}" == "$key" ]]; then
            ROWIDX=$i
            return 0
        fi
    done
    JR+=( "$key" )
    ROWIDX=$(( ${#JR[@]} - 1 ))
}

# regenerated [jobs] body: row-major, column-aligned (spreadsheet-pasteable)
jobs_emit_body() {
    local sw=6 tw=4 r c s t
    for r in "${JR[@]}"; do
        s="${r%%$'\t'*}"; t="${r#*$'\t'}"
        (( ${#s} > sw )) && sw=${#s}
        (( ${#t} > tw )) && tw=${#t}
    done
    for r in "${JR[@]}"; do
        s="${r%%$'\t'*}"; t="${r#*$'\t'}"
        for c in "${JC[@]}"; do
            if [[ -n "${CELL[$s|$t|$c]:-}" ]]; then
                printf '%-*s   %-*s   %s\n' "$sw" "$s" "$tw" "$t" "$c"
            fi
        done
    done
}

# rebuild the whole file; stdout. The anchor checks live OUTSIDE the
# skip so a dropped anchor line (deleted receiver's [hosts] row) still
# takes this session's additions.
jobs_emit_file() {
    local i cl n=${#FL[@]}
    for (( i = 0; i < n; i++ )); do
        if [[ -z "${JOBSBODY[$i]:-}" && -z "${DROPLN[$i]:-}" ]]; then
            printf '%s\n' "${FL[i]}"
        fi
        if (( i == JOBS_HDR )); then
            for cl in "${JCOMMENTS[@]:-}"; do
                [[ -n "$cl" ]] && printf '%s\n' "$cl"
            done
            jobs_emit_body
        fi
        if (( i == HOSTS_ANCHOR )) && (( ${#NEWHOSTS[@]} > 0 )); then
            printf '%s\n' "${NEWHOSTS[@]}"
        fi
    done
    # a config with no [hosts] section yet: create one ahead of [jobs]...
    # except [jobs] is already emitted above, so append at the end -- the
    # parser is section-order agnostic
    if (( HOSTS_HDR < 0 )) && [[ ${#NEWHOSTS[@]} -gt 0 ]]; then
        printf '\n[hosts]\n'
        printf '%s\n' "${NEWHOSTS[@]}"
    fi
}

# write + validate + atomic replace; on validation failure, echoes the
# parser's message and leaves the file untouched. Returns 1 on failure.
jobs_save() {
    local tmp
    tmp=$(mktemp "${CONF}.new.XXXXXX")
    # mktemp makes the temp 0600 owned by the INVOKER, and mv installs
    # that identity wholesale -- a sudo edit once flipped fleet.conf to
    # root:0600 and the operator's next run couldn't read it. Mirror the
    # original's mode and owner; chown needs root and is best-effort
    # (an unprivileged edit already has the right owner).
    chmod --reference="$CONF" "$tmp" 2>/dev/null || true
    chown --reference="$CONF" "$tmp" 2>/dev/null || true
    jobs_emit_file > "$tmp"
    local verr
    if ! verr=$(bash -c "source '$here/stevedore-fleetparser.sh'; fleet_parse '$tmp'" 2>&1); then
        rm -f "$tmp"
        printf '%s\n' "${verr##*$'\n'}"
        return 1
    fi
    cp -p "$CONF" "${CONF}.bak" 2>/dev/null || true
    mv "$tmp" "$CONF"
    return 0
}

jobs_count() {
    echo "${#CELL[@]}"
}

#
# ---------- interactive layer ------------------------------------------------
#
CR=0 CC=0                 # cursor row/col
DIRTY=""
MSG=""
LAST_SRC=""

tty_init() {
    [[ -n "$SCRIPTED" ]] && return 0
    SAVED_STTY=$(stty -g)
    stty -echo -icanon min 1 time 0
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
}

tty_done() {
    [[ -n "$SCRIPTED" ]] && return 0
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    stty "$SAVED_STTY" 2>/dev/null || true
}
trap tty_done EXIT

# one whole-line text prompt on the bottom row (cooked mode so editing
# works); scripted mode reads the next line off the piped stream
ask() {   # $1 prompt -> REPLY
    REPLY=""
    if [[ -n "$SCRIPTED" ]]; then
        printf '%s' "$1" >&2
        IFS= read -r REPLY || true
        return 0
    fi
    tput cup "$(( $(tput lines) - 1 ))" 0 2>/dev/null || true
    printf '\e[2K%s' "$1" >&2
    stty echo icanon
    IFS= read -r REPLY || true
    stty -echo -icanon min 1 time 0
}

getkey() {   # -> KEY: printable char, "" for enter, UP/DOWN/LEFT/RIGHT, ESC
    local k rest
    IFS= read -rsn1 k || exit 0
    if [[ "$k" == $'\e' ]]; then
        rest=""
        IFS= read -rsn2 -t 0.05 rest || true
        case "$rest" in
            '[A') KEY=UP ;;
            '[B') KEY=DOWN ;;
            '[C') KEY=RIGHT ;;
            '[D') KEY=LEFT ;;
            *)    KEY=ESC ;;
        esac
    else
        KEY="$k"
    fi
}

render() {
    local out="" r c s t i lw=0 cw name mark cur
    for r in "${JR[@]}"; do
        s="${r%%$'\t'*}"; t="${r#*$'\t'}"
        (( ${#s} + ${#t} + 1 > lw )) && lw=$(( ${#s} + ${#t} + 1 ))
    done
    (( lw < 12 )) && lw=12
    out+=$'\e[H\e[2J'
    out+="steve jobs . ${CONF} . $(jobs_count) jobs${DIRTY:+ . [modified]}"$'\n\n'
    # column headers
    out+=$(printf '%-*s' "$lw" "")
    for (( i = 0; i < ${#JC[@]}; i++ )); do
        name="${JC[i]}"
        cw=$(( ${#name} > 3 ? ${#name} : 3 ))
        if (( i == CC )) && [[ ${#JR[@]} -gt 0 ]]; then
            out+=$(printf '  \e[1m%-*s\e[0m' "$cw" "$name")
        else
            out+=$(printf '  %-*s' "$cw" "$name")
        fi
    done
    out+=$'\n'
    # rows
    for (( r = 0; r < ${#JR[@]}; r++ )); do
        s="${JR[r]%%$'\t'*}"; t="${JR[r]#*$'\t'}"
        out+=$(printf '%-*s' "$lw" "$s/$t")
        for (( i = 0; i < ${#JC[@]}; i++ )); do
            name="${JC[i]}"
            cw=$(( ${#name} > 3 ? ${#name} : 3 ))
            if [[ "$s" == "$name" ]]; then
                mark=" - "
            elif [[ -n "${CELL[$s|$t|$name]:-}" ]]; then
                mark="[x]"
            else
                mark="[ ]"
            fi
            cur=""
            (( r == CR && i == CC )) && cur=1
            out+=$(printf '  %s%-*s%s' "${cur:+$'\e[7m'}" "$cw" "$mark" "${cur:+$'\e[0m'}")
        done
        out+=$'\n'
    done
    out+=$'\n'"arrows/hjkl move . space toggle . a add dataset . H add receiver . d del row . D del receiver . s save . q quit"$'\n'
    [[ -n "$MSG" ]] && out+="$MSG"$'\n'
    printf '%s' "$out" >&2
}

# vertical menu; sets PICK (index) or returns 1 on ESC/q
menu() {   # $1 title, $2 preselect index, rest: items
    local title="$1" sel="$2"
    shift 2
    local items=( "$@" ) i
    while :; do
        render
        printf '\n%s\n' "$title" >&2
        for (( i = 0; i < ${#items[@]}; i++ )); do
            if (( i == sel )); then
                printf '  \e[7m %s \e[0m\n' "${items[i]}" >&2
            else
                printf '   %s\n' "${items[i]}" >&2
            fi
        done
        getkey
        case "$KEY" in
            UP|k)   (( sel > 0 )) && sel=$(( sel - 1 )) ;;
            DOWN|j) (( sel < ${#items[@]} - 1 )) && sel=$(( sel + 1 )) ;;
            "")     PICK=$sel; return 0 ;;
            ESC|q)  return 1 ;;
        esac
    done
}

do_toggle() {
    (( ${#JR[@]} == 0 || ${#JC[@]} == 0 )) && return 0
    local s="${JR[CR]%%$'\t'*}" t="${JR[CR]#*$'\t'}" d="${JC[CC]}"
    if [[ "$s" == "$d" ]]; then
        MSG="a host cannot send to itself"
        return 0
    fi
    if [[ -n "${CELL[$s|$t|$d]:-}" ]]; then
        unset "CELL[$s|$t|$d]"
    else
        CELL["$s|$t|$d"]=1
    fi
    DIRTY=1
    MSG=""
}

# the owner-specified add-dataset flow: sender menu (last-used
# preselected, enter accepts) -> dataset name -> new row under cursor.
# "add sender..." loops straight back into the menu with the newcomer
# selected.
do_add_dataset() {
    local senders=() seen r s pre=0 i
    declare -A _s=()
    while :; do
        senders=()
        _s=()
        for r in "${JR[@]}"; do
            s="${r%%$'\t'*}"
            if [[ -z "${_s[$s]:-}" ]]; then
                _s[$s]=1
                senders+=( "$s" )
            fi
        done
        pre=0
        for (( i = 0; i < ${#senders[@]}; i++ )); do
            [[ "${senders[i]}" == "$LAST_SRC" ]] && pre=$i
        done
        if ! menu "send from:" "$pre" "${senders[@]}" "add sender..."; then
            MSG=""
            return 0
        fi
        if (( PICK == ${#senders[@]} )); then
            ask "new sender identity: "
            if [[ -z "$REPLY" ]]; then
                continue
            fi
            if ! [[ "$REPLY" =~ $FLEET_RE_IDENT ]]; then
                MSG="bad identity '$REPLY'"
                return 0
            fi
            LAST_SRC="$REPLY"
            JR+=( "$REPLY"$'\t'"__pending__" )   # temp so it appears in the menu
            continue
        fi
        s="${senders[PICK]}"
        LAST_SRC="$s"
        break
    done
    ask "dataset on [$s]: "
    # placeholder rows only existed so a just-added sender shows in the
    # menu; drop them all before the real row lands
    local keep=()
    for r in "${JR[@]}"; do
        [[ "${r#*$'\t'}" == "__pending__" ]] && continue
        keep+=( "$r" )
    done
    JR=( "${keep[@]:-}" )
    [[ ${#JR[@]} -eq 1 && -z "${JR[0]}" ]] && JR=()
    if [[ -z "$REPLY" ]]; then
        MSG=""
        return 0
    fi
    if ! [[ "$REPLY" =~ $FLEET_RE_TREE ]]; then
        MSG="bad dataset name '$REPLY'"
        return 0
    fi
    jobs_row_add "$s" "$REPLY"
    CR=$ROWIDX
    DIRTY=1
    MSG="added row $s/$REPLY -- toggle its destinations"
}

do_add_receiver() {
    ask "new receiver identity: "
    local id="$REPLY" recv line
    [[ -z "$id" ]] && return 0
    if ! [[ "$id" =~ $FLEET_RE_IDENT ]]; then
        MSG="bad identity '$id'"
        return 0
    fi
    if jobs_has_col "$id"; then
        MSG="'$id' is already a receiver"
        return 0
    fi
    ask "recv= dataset root on [$id] (required): "
    recv="$REPLY"
    if ! [[ "$recv" =~ $FLEET_RE_TREE ]]; then
        MSG="bad recv dataset '$recv'"
        return 0
    fi
    line=$(printf '%-16s recv=%s' "$id" "$recv")
    local k v
    for k in data ssh bind ec2 cadence; do
        ask "$k= (optional, enter to skip): "
        v="$REPLY"
        [[ -z "$v" ]] && continue
        if [[ "$k" == "cadence" ]] && ! [[ "$v" =~ ^[0-9]+[mhd]$ ]]; then
            MSG="bad cadence '$v' (want <N>m|h|d); receiver added without it"
            continue
        fi
        line+="   $k=$v"
    done
    NEWHOSTS+=( "$line" )
    JC+=( "$id" )
    CC=$(( ${#JC[@]} - 1 ))
    DIRTY=1
    [[ -n "$MSG" ]] || MSG="added receiver [$id] -- toggle jobs onto its column"
}

do_del_row() {
    (( ${#JR[@]} == 0 )) && return 0
    local s="${JR[CR]%%$'\t'*}" t="${JR[CR]#*$'\t'}" c n=0
    for c in "${JC[@]}"; do
        [[ -n "${CELL[$s|$t|$c]:-}" ]] && n=$(( n + 1 ))
    done
    ask "delete row $s/$t ($n job(s))? [y/N] "
    [[ "$REPLY" == "y" ]] || { MSG=""; return 0; }
    for c in "${JC[@]}"; do
        unset "CELL[$s|$t|$c]" 2>/dev/null || true
    done
    local keep=() r
    for r in "${JR[@]}"; do
        [[ "$r" == "$s"$'\t'"$t" ]] && continue
        keep+=( "$r" )
    done
    JR=( "${keep[@]}" )
    (( CR >= ${#JR[@]} && CR > 0 )) && CR=$(( ${#JR[@]} - 1 ))
    DIRTY=1
    MSG="deleted row $s/$t"
}

do_del_receiver() {
    (( ${#JC[@]} == 0 )) && return 0
    local d="${JC[CC]}" k n=0
    for k in "${!CELL[@]}"; do
        [[ "${k##*|}" == "$d" ]] && n=$(( n + 1 ))
    done
    ask "remove receiver [$d] ($n job(s) + its [hosts] row)? [y/N] "
    [[ "$REPLY" == "y" ]] || { MSG=""; return 0; }
    for k in "${!CELL[@]}"; do
        [[ "${k##*|}" == "$d" ]] && unset "CELL[$k]"
    done
    local keep=() c
    for c in "${JC[@]}"; do
        [[ "$c" == "$d" ]] && continue
        keep+=( "$c" )
    done
    JC=( "${keep[@]}" )
    if [[ -n "${HOSTLN[$d]:-}" ]]; then
        DROPLN[${HOSTLN[$d]}]=1
    fi
    keep=()
    for c in "${NEWHOSTS[@]:-}"; do
        [[ "$c" == "$d "* || "$c" == "$d"$'\t'* ]] && continue
        keep+=( "$c" )
    done
    NEWHOSTS=( "${keep[@]:-}" )
    [[ ${#NEWHOSTS[@]} -eq 1 && -z "${NEWHOSTS[0]}" ]] && NEWHOSTS=()
    (( CC >= ${#JC[@]} && CC > 0 )) && CC=$(( ${#JC[@]} - 1 ))
    DIRTY=1
    MSG="removed receiver [$d]"
}

do_save() {
    local err
    if err=$(jobs_save); then
        DIRTY=""
        MSG="saved ($(jobs_count) jobs; previous version in ${CONF##*/}.bak)"
    else
        MSG="NOT saved -- $err"
    fi
}

#
# ---------- main -------------------------------------------------------------
#
jobs_load
tty_init

quit_armed=""
while :; do
    render
    getkey
    case "$KEY" in
        UP|k)    (( CR > 0 )) && CR=$(( CR - 1 )); MSG="" ;;
        DOWN|j)  (( CR < ${#JR[@]} - 1 )) && CR=$(( CR + 1 )); MSG="" ;;
        LEFT|h)  (( CC > 0 )) && CC=$(( CC - 1 )); MSG="" ;;
        RIGHT|l) (( CC < ${#JC[@]} - 1 )) && CC=$(( CC + 1 )); MSG="" ;;
        " "|"")  do_toggle ;;
        a)       do_add_dataset ;;
        H)       do_add_receiver ;;
        d)       do_del_row ;;
        D)       do_del_receiver ;;
        s)       do_save ;;
        q)
            if [[ -n "$DIRTY" && -z "$quit_armed" ]]; then
                quit_armed=1
                MSG="unsaved changes -- q again to discard, s to save first"
                continue
            fi
            break
            ;;
    esac
    [[ "$KEY" != "q" ]] && quit_armed=""
done
exit 0
