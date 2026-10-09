#!/bin/sh
# Live end-to-end test of agent.nvim against the real agent CLIs.
#
# NOT part of `make test` (it needs the agent CLIs, node, and a minute or two per agent).
# Run it by hand or with `make test-e2e`:
#
#   tests/e2e/run.sh                      # every agent that is installed
#   tests/e2e/run.sh claude copilot       # only these
#
# For each agent, a headless Neovim runs tests/e2e/driver.lua: it calls require('agent').setup()
# and require('agent').open(<agent>) (a split on the right, or see E2E_LAYOUT and E2E_SPLIT_SIDE
# below), waits for the agent's IDE connection, selects lines in the editor and sends them with
# :AgentSend (a Visual-mode <cmd>AgentSend<cr> mapping), checks that the focus went to the agent,
# that the selection went through the IDE connection (as selection.track sends it) and shows in
# its TUI, and that nothing was typed into its prompt; then submits a prompt, whose model request
# must carry the selected text. A scripted model turn then (a) calls the $NVIM controller
# (exec_lua and open_file) and (b) proposes an edit that goes through the IDE diff, which the
# driver accepts in Neovim. The driver checks the effects in Neovim and on disk, sends lines of a
# scratch buffer (by its nvim://buffer/ id) the same way, with one more prompt, then the same lines
# again once that prompt was answered, whose next prompt must carry them again (Claude and OpenCode
# use a selection for one prompt only), then a charwise Visual selection with a typed :'<,'>AgentSend
# (the characters selected must reach the agent, not whole lines), stops the agent (its provider
# stops with it and removes its lock/discovery file), tears down, and checks that no
# lock/discovery files or temp dirs are left.
# This script then checks that no process started by the run is still alive.
#
# Isolation: nothing touches your real agent configs or accounts.
#   * HOME, XDG_*_HOME, CLAUDE_CONFIG_DIR, COPILOT_HOME and GEMINI_CLI_HOME point into a fresh
#     temp dir, and the environment is rebuilt from scratch (env -i), so no inherited CLAUDE_*,
#     ANTHROPIC_*, COPILOT_*, GEMINI_* or NVIM variable leaks in.
#   * Model turns come from a local fake endpoint (tests/e2e/fake_model.mjs, 127.0.0.1 only) or,
#     for Gemini, from --fake-responses-non-strict (its model requests are read from its local
#     telemetry outfile). Dummy API keys only.
#   * The workspaces are temp dirs, never this repository.
#
# Requirements: nvim (0.12+), node, and the agent CLIs to test:
#   claude    `claude` on PATH, or E2E_CLAUDE_BIN
#   copilot   `copilot` on PATH, or E2E_COPILOT_BIN
#   gemini    `gemini` on PATH, or E2E_GEMINI_JS=/path/to/gemini-cli/bundle/gemini.js (run with node)
#   opencode  `opencode` on PATH, or E2E_OPENCODE_BIN
# Agents that are not found are reported as SKIP.
#
# Other variables: E2E_TMP (parent of the temp dir; default $TMPDIR or /tmp), E2E_KEEP=1 (keep
# the temp dir with the logs: <agent>.driver.log, <agent>.model.jsonl or gemini.telemetry.log,
# <agent>.tty.txt, and <agent>.tty-send.txt, the TUI after the last :AgentSend),
# E2E_TIMEOUT (seconds per agent, default 300), E2E_LAYOUT (terminal.layout: split, the default,
# or current), E2E_SPLIT_SIDE (terminal.split_side: right, the baseline here, or below, the
# plugin's default; the diff tab page must show the agent on that side: on the right as wide as
# its split, or at the bottom, full width and as tall), E2E_TRACK=1 (selection.track = true, the
# automatic mode: also checks that a selection reaches the agent by itself, is kept when the focus
# goes straight from Visual mode to the agent, and is dropped by <Esc>).
# Exit status: 0 when every selected agent passed or was skipped.
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO=$(pwd -P)

if [ "$#" -eq 0 ]; then set -- claude copilot gemini opencode; fi
for k in "$@"; do
  case "$k" in claude | copilot | gemini | opencode) ;; *) echo "unknown agent: $k" >&2; exit 2 ;; esac
done
command -v nvim >/dev/null || { echo "nvim not found" >&2; exit 2; }
command -v node >/dev/null || { echo "node not found" >&2; exit 2; }

BASE=${E2E_TMP:-${TMPDIR:-/tmp}}
ROOT=$(mktemp -d "${BASE%/}/agent-nvim-e2e.XXXXXX") || exit 2
ROOT=$(cd "$ROOT" && pwd -P)
mkdir -p "$ROOT/home" "$ROOT/xdg/config" "$ROOT/xdg/data" "$ROOT/xdg/state" "$ROOT/xdg/cache"
echo "e2e temp dir: $ROOT"

# Resolve the CLIs now, before HOME changes (~/.local/bin and friends stay on the absolute PATH).
resolve() { # <env var value> <command>
  if [ -n "$1" ]; then echo "$1"; else command -v "$2" 2>/dev/null || true; fi
}
CLAUDE_BIN=$(resolve "${E2E_CLAUDE_BIN:-}" claude)
COPILOT_BIN=$(resolve "${E2E_COPILOT_BIN:-}" copilot)
OPENCODE_BIN=$(resolve "${E2E_OPENCODE_BIN:-}" opencode)
GEMINI_JS=${E2E_GEMINI_JS:-}

# Leftover processes are found three ways: the pids each driver recorded (its agent's whole
# process tree and the fake endpoint, <agent>.pids), processes whose environment has the run's
# HOME (ps -E on macOS, ps e on Linux; macOS hides it for hardened binaries), and processes whose
# command line mentions the temp dir. The pattern spells the dot of the temp dir name as "[.]" so
# that grep does not match its own command line.
ps_env() { ps -axwwEo pid=,command= 2>/dev/null || ps axwwe -o pid=,command= 2>/dev/null; }
ours() {
  {
    cat "$ROOT"/*.pids 2>/dev/null | while read -r p; do
      [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"
    done
    ps_env | grep -E "${ROOT%.*}[.]${ROOT##*.}" | awk '{print $1}'
  } | sort -un
}

NVIM_TMPDIR=${TMPDIR:-/tmp}
status=0
for kind in "$@"; do
  echo "==== $kind"
  env -i \
    PATH="$PATH" HOME="$ROOT/home" USER="${USER:-}" LOGNAME="${LOGNAME:-${USER:-}}" SHELL=/bin/sh \
    LANG="${LANG:-en_US.UTF-8}" TERM=xterm-256color TMPDIR="$NVIM_TMPDIR" \
    XDG_CONFIG_HOME="$ROOT/xdg/config" XDG_DATA_HOME="$ROOT/xdg/data" \
    XDG_STATE_HOME="$ROOT/xdg/state" XDG_CACHE_HOME="$ROOT/xdg/cache" \
    E2E_CLAUDE_BIN="$CLAUDE_BIN" E2E_COPILOT_BIN="$COPILOT_BIN" E2E_OPENCODE_BIN="$OPENCODE_BIN" \
    E2E_GEMINI_JS="$GEMINI_JS" E2E_LAYOUT="${E2E_LAYOUT:-}" E2E_SPLIT_SIDE="${E2E_SPLIT_SIDE:-}" \
    E2E_TRACK="${E2E_TRACK:-}" \
    perl -e 'alarm shift; exec @ARGV' "${E2E_TIMEOUT:-300}" \
    nvim --headless -u NONE -i NONE -n -l "$REPO/tests/e2e/driver.lua" "$kind" "$ROOT"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "==== $kind: FAILED (exit $rc)"
    status=1
  fi
done

# Leftover processes: anything still running with the run's HOME.
i=0
while [ -n "$(ours)" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
left=$(ours)
if [ -n "$left" ]; then
  echo "FAIL leftover processes:"
  for p in $left; do ps -o pid=,command= -p "$p" | cut -c1-300; done
  for p in $left; do kill "$p" 2>/dev/null; done
  status=1
else
  echo "PASS no leftover processes"
fi

echo "==== summary"
for kind in "$@"; do
  if [ -f "$ROOT/$kind.result.json" ]; then
    node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(`${r.kind}: ${r.passed} passed, ${r.failed} failed, ${r.skipped} skipped`);
      for (const x of r.results) if (!x.ok) console.log(`  ${x.skipped ? "SKIP" : "FAIL"} ${x.name}${x.skipped ? " -- " + x.skipped : x.detail ? " -- " + x.detail : ""}`);' \
      "$ROOT/$kind.result.json"
  else
    echo "$kind: no result (driver crashed or timed out; see $ROOT/$kind.driver.log)"
    status=1
  fi
done

if [ "${E2E_KEEP:-0}" = 1 ]; then
  echo "kept $ROOT"
else
  rm -rf "$ROOT"
fi
exit $status
