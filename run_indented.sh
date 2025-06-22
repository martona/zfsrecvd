#!/bin/bash

# This function takes a command and its arguments, executes it,
# and prepends a prefix to every line of its output (both stdout and stderr).
run_indented() {
  local prefix="$1"
  shift
  "$@" |& sed -u "s/^/${prefix}/"
}
