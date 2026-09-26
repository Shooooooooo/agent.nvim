#!/bin/sh
# Run Lua specs, each in its own headless Neovim. Usage: tests/run.sh [spec files...]
cd "$(dirname "$0")/.." || exit 1
NVIM=${NVIM_BIN:-nvim}
if [ "$#" -eq 0 ]; then set -- tests/spec/*_spec.lua; fi
# A private XDG_STATE_HOME for this run (Neovim's logs land there), removed on exit.
STATE=$(mktemp -d "${TMPDIR:-/tmp}/agent-nvim-test-state.XXXXXX") || exit 1
trap 'rm -rf "$STATE"' EXIT
trap 'exit 130' INT TERM
status=0
for f in "$@"; do
  # Isolate each run from the user's environment and from any parent Neovim.
  env -u NVIM XDG_STATE_HOME="$STATE" \
    "$NVIM" --headless -u NONE -i NONE -n -l tests/runner.lua "$f" || status=1
done
exit $status
