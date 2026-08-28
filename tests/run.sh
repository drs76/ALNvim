#!/bin/sh
# Run the ALNvim test suite.
#
#   tests/run.sh
#
# Uses -u NONE so the suite is independent of the user's config, and adds only
# the repo itself to the runtimepath — no plugin manager, no plenary, no
# network. Exits non-zero on failure.
set -e
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec nvim --headless -u NONE \
  --cmd "set rtp+=$repo" \
  --cmd "lua package.path = package.path .. ';$repo/?.lua;$repo/?/init.lua'" \
  -l "$repo/tests/run.lua"
