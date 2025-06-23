#!/bin/bash

# This function takes a command and its arguments, executes it,
# and prepends a prefix to every line of its output (both stdout and stderr).
run_indented() {
    local prefix=$1; shift
    "$@" 2>&1 | gawk -v p="$prefix" '
        BEGIN       { RS = "[\r\n]"; ORS = "" ; }
        { printf "%s%s%s", p, $0, RT }
    '
}

# The above fails to produce output if used through SSH - i'll disable it here 
# for now.
run_indented() {
    shift
    "$@"
}
