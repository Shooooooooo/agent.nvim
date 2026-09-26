#!/bin/sh
# Fake agent CLI for terminal tests. Records its args, cwd and environment next to
# $FAKE_AGENT_OUT, then either exits ($FAKE_AGENT_EXIT) or records raw stdin until killed.
out="${FAKE_AGENT_OUT:?FAKE_AGENT_OUT is required}"
for a in "$@"; do printf '%s\n' "$a"; done > "$out.args"
pwd -P > "$out.cwd"
if [ -n "$FAKE_AGENT_PRINT" ]; then printf '%s\n' "$FAKE_AGENT_PRINT"; fi
if [ -n "$FAKE_AGENT_EXIT" ]; then
  env > "$out.env.tmp" && mv "$out.env.tmp" "$out.env"
  sleep "${FAKE_AGENT_SLEEP:-0}"
  exit "$FAKE_AGENT_EXIT"
fi
# Raw mode so pasted bytes reach us unchanged and without waiting for a newline.
stty raw -echo 2>/dev/null
env > "$out.env.tmp" && mv "$out.env.tmp" "$out.env"
exec cat > "$out.stdin"
