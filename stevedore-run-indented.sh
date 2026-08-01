#!/bin/bash

# run_indented <prefix> <command> [args...]
#
# Executes the command and prepends the prefix to every line of its
# combined stdout+stderr. Records are split on \r\n, \r, or \n -- longest
# match first, so a CRLF pair is ONE separator (splitting on the chars
# individually would yield an empty record between \r and \n, which came
# out as a spurious prefix-only line after every completed pv display).
# Bare \r stays a separator of its own, so progress bars keep refreshing
# in place with the prefix intact.
#
# Pure bash byte loop, NOT gawk, and that is load-bearing: gawk with a
# regex RS holds every record until the byte AFTER the separator arrives
# (empirically true even for a plain \n match that cannot be extended),
# so each line lags one record behind. Invisible while pv chatters; but
# when a line is followed by silence -- an hours-long transfer with pv
# quiet, a long dry-run estimate -- the line sits inside gawk for the
# whole stretch and the live board shows a stale header instead. Found
# on the first real T run: a multi-TB send displayed "tree [...]" start
# to finish. The bash loop's only peek is one byte after \r (CRLF
# detection), which the very next progress byte resolves.
#
# Only sendtree's chatter and pv's progress flow through here (never the
# zfs stream), so the byte loop's throughput is a non-issue.
#
# STEVEDORE_INDENT tells descendants how many columns of prefix will be
# glued onto their lines: anything that sizes output to the terminal
# width (pv, see sendtree.sh) must shrink by that amount, or the line
# exceeds the terminal width, wraps, and \r-refreshes land on fresh rows
# instead of overwriting.
#
# Returns the command's exit status, not the pipeline's.

run_indented() {
    local prefix=$1; shift
    STEVEDORE_INDENT=$(( ${STEVEDORE_INDENT:-0} + ${#prefix} )) \
    "$@" 2>&1 | {
        # one printf per completed record = one write(): concurrent jobs
        # interleave at record granularity, the same guarantee gawk gave
        local buf="" ch="" pending_cr=""
        while IFS= read -r -d '' -n 1 ch; do
            if [[ -n "$pending_cr" ]]; then
                pending_cr=""
                if [[ "$ch" == $'\n' ]]; then
                    printf '%s%s\r\n' "$prefix" "$buf"
                    buf=""
                    continue
                fi
                printf '%s%s\r' "$prefix" "$buf"
                buf=""
            fi
            case "$ch" in
                $'\r') pending_cr=1 ;;
                $'\n') printf '%s%s\n' "$prefix" "$buf"; buf="" ;;
                *)     buf+="$ch" ;;
            esac
        done
        # EOF: a trailing \r is a complete record; a bare unterminated
        # tail is emitted as-is
        if [[ -n "$pending_cr" ]]; then
            printf '%s%s\r' "$prefix" "$buf"
        elif [[ -n "$buf" ]]; then
            printf '%s%s' "$prefix" "$buf"
        fi
    }
    return "${PIPESTATUS[0]}"
}
