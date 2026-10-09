#!/bin/sh
# Records the README demo: demo/agent-nvim-demo.gif.
#
#   demo/record.sh        (or: make demo)
#
# Story (demo/demo.tape): the user opens Claude Code in Neovim, on a buggy Python script
# (demo/project/stats.py), and asks it to debug the script in a pdb session with nvim-gdb.
# Claude starts the session through the $NVIM controller (execute_command :GdbStartPDB), which
# opens pdb's terminal next to the script and marks the line pdb stops on in the script; it sends
# pdb commands with nvim-gdb's :Gdb and reads pdb's answers from nvim-gdb's terminal (exec_lua),
# proposes the fix as a diff, and re-runs the script in the same pdb session. Only the model's
# text and tool choices are scripted (demo/plan.json); pdb, nvim-gdb, Neovim, agent.nvim and
# Claude Code really run.
#
# Needs vhs, ttyd, ffmpeg, nvim (0.12+), node, claude, git and python3 on PATH, and the
# "JetBrainsMono Nerd Font" (without it VHS silently uses another font; the script warns).
# python3 must be Python 3.9 (on macOS, /usr/bin/python3 from the Command Line Tools): the tape
# waits for pdb's output as 3.9 prints it (the `restart` of Python 3.14, for one, also prints
# "The program finished"). The recording was made with vhs 0.12.0, nvim 0.12.5, Claude Code
# 2.1.284 and Python 3.9.6, on macOS; the Linux branch of the cleanup is untested.
#
# nvim-gdb (https://github.com/sakhnik/nvim-gdb) is fetched at the pinned commit NVIMGDB_SHA into
# the temp dir, which needs network access to github.com; set DEMO_NVIMGDB to an existing
# checkout of that commit to skip the fetch. Only the demo's Neovim loads it (demo/init.lua adds
# it to 'runtimepath'): nothing is installed anywhere else, and agent.nvim itself does not use
# it. Its pdb backend needs no Python package: it runs pdb behind a small Lua proxy (nvim -l).
#
# The real Claude Code TUI runs inside agent.nvim, against a local scripted model: nothing uses
# your Claude account, your ~/.claude or any real model API.
#   * HOME, TMPDIR, XDG_*_HOME and CLAUDE_CONFIG_DIR point into a fresh temp dir, and Neovim's
#     environment is rebuilt with env -i. The config dir is seeded by tests/e2e/claude_seed.lua
#     (onboarding done, workspace trusted, dummy API key approved), and its settings.json turns
#     off the spinner's tips (spinnerTipsEnabled), which would otherwise pop up during the turn.
#   * The model is tests/e2e/fake_model.mjs on 127.0.0.1, playing demo/plan.json.
#   * The workspace is a copy of demo/project in the temp dir, which is HOME (shown as ~/stats).
#     pdb prints the script's full real path, so the temp dir is a short one in /tmp
#     (/tmp/dbg.XXXX, /private/tmp on macOS): pdb's longest line (Restarting
#     /private/tmp/dbg.XXXX/stats/stats.py with arguments:) is 63 columns, which fits nvim-gdb's
#     pdb pane (a vertical split of the script's window, 73 columns).
# VHS types demo/demo.tape into a bash that sources the generated rc file ($DEMO_RC), which
# defines `nvim` as that isolated Neovim with demo/init.lua. VHS 0.12.0 cannot encode videos
# itself (its ffmpeg step runs with an already cancelled context), so the tape writes PNG frames
# and this script encodes the GIF with ffmpeg (after replacing any frame captured as an empty
# screen, see step 4).
#
# Variables: DEMO_OUT (directory for the GIF, default demo/; use a scratch directory for
# trial runs, since every run differs slightly: clock, spinner words, session hash),
# DEMO_KEEP=1 keeps the temp dir (frames, model log), DEMO_TIMEOUT (seconds for vhs, default 300),
# DEMO_NVIMGDB (an nvim-gdb checkout at NVIMGDB_SHA to use instead of fetching one).
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
OUT=${DEMO_OUT:-$REPO/demo}
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd -P) || exit 2

for p in vhs ttyd ffmpeg nvim node claude git python3; do
  command -v "$p" >/dev/null 2>&1 || { echo "record.sh: $p not found on PATH" >&2; exit 2; }
done
pyver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
[ "$pyver" = 3.9 ] || {
  echo "record.sh: python3 on PATH is Python $pyver, not 3.9 (on macOS: put /usr/bin first)" >&2
  exit 2
}
set -- $(nvim --version | sed -n '1s/^NVIM v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ "${1:-0}" -eq 0 ] && [ "${2:-0}" -lt 12 ]; then
  echo "record.sh: Neovim 0.12 or newer required" >&2
  exit 2
fi
if command -v fc-list >/dev/null 2>&1; then
  fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'
else
  ls "$HOME/Library/Fonts" /Library/Fonts 2>/dev/null | grep -qi '^JetBrainsMonoNerdFont'
fi || echo 'record.sh: warning: "JetBrainsMono Nerd Font" not found; VHS will use another font' >&2

REAL_TMPDIR=${TMPDIR:-/tmp}
ROOT=$(mktemp -d /tmp/dbg.XXXX) || exit 2
ROOT=$(cd "$ROOT" && pwd -P)
WS="$ROOT/stats"
mkdir -p "$ROOT/xdg/config" "$ROOT/xdg/data" "$ROOT/xdg/state" "$ROOT/xdg/cache" "$ROOT/vhs-tmp" "$ROOT/tmp"
cp -R "$REPO/demo/project" "$WS"
echo "demo temp dir: $ROOT"
# nvim-gdb keeps each session's side-channel port in a directory of its own in $TMPDIR
# (nvimgdb-XXXXXX, deleted when the session ends): Neovim's TMPDIR is $ROOT/tmp, so that it stays
# in the temp dir; the cleanup checks that none appeared in the real $TMPDIR.
nvimgdb_dirs() { ls -d "${REAL_TMPDIR%/}"/nvimgdb-* 2>/dev/null | sort; }
nvimgdb_dirs > "$ROOT/nvimgdb-dirs.before"

MODEL_PID=
# Every process of the run: the fake model, and whatever still mentions the temp dir in its
# environment or command line (the spelled-out "[.]" keeps grep from matching itself).
PAT="${ROOT%.*}[.]${ROOT##*.}"
ours() {
  {
    [ -n "$MODEL_PID" ] && kill -0 "$MODEL_PID" 2>/dev/null && echo "$MODEL_PID"
    if [ -r /proc/self/environ ]; then # Linux
      grep -l -a -s -E "$PAT" /proc/[0-9]*/environ /proc/[0-9]*/cmdline 2>/dev/null |
        sed -E 's#^/proc/([0-9]+)/.*#\1#'
    else # macOS and BSD: ps -E appends the environment to the command
      ps -axwwEo pid=,command= 2>/dev/null | grep -E "$PAT" | awk '{print $1}'
    fi
  } | sort -un
}
cleanup() {
  trap - EXIT INT TERM
  exec 3>&-
  if [ -n "$MODEL_PID" ]; then
    { kill "$MODEL_PID" && wait "$MODEL_PID"; } 2>/dev/null
  fi
  # Neovim quit at the end of the tape, which stops Claude and pdb; give the rest a moment to exit.
  i=0
  while [ -n "$(ours)" ] && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done
  left=$(ours)
  if [ -n "$left" ]; then
    echo "record.sh: stopping leftover processes:" >&2
    for p in $left; do ps -o pid=,command= -p "$p" | cut -c1-200 >&2; done
    for p in $left; do kill "$p" 2>/dev/null; done
    sleep 0.5
    for p in $(ours); do kill -9 "$p" 2>/dev/null; done
  fi
  new_dirs=$(nvimgdb_dirs | comm -13 "$ROOT/nvimgdb-dirs.before" -)
  [ -z "$new_dirs" ] ||
    echo "record.sh: warning: new in the real TMPDIR (another nvim-gdb session's?): $new_dirs" >&2
  if [ "${DEMO_KEEP:-0}" = 1 ]; then
    echo "kept $ROOT"
  else
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 0. nvim-gdb at the pinned commit (master, 2026-06-15: "Merge pull request #221 from
# anonsgithub/fix-escape-source-path"), in the temp dir unless DEMO_NVIMGDB names a checkout.
NVIMGDB_SHA=67abac716b626ece57f3a7c72121542f0b3edfe9
if [ -n "${DEMO_NVIMGDB:-}" ]; then
  NVIMGDB=$(cd "$DEMO_NVIMGDB" && pwd -P) || exit 2
else
  NVIMGDB="$ROOT/nvim-gdb"
  git init -q "$NVIMGDB" &&
    perl -e 'alarm shift; exec @ARGV' 120 git -C "$NVIMGDB" fetch -q --depth 1 \
      https://github.com/sakhnik/nvim-gdb.git "$NVIMGDB_SHA" &&
    git -C "$NVIMGDB" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
    { echo "record.sh: cannot fetch nvim-gdb $NVIMGDB_SHA (needs network access)" >&2; exit 1; }
fi
[ "$(git -C "$NVIMGDB" rev-parse HEAD 2>/dev/null)" = "$NVIMGDB_SHA" ] ||
  { echo "record.sh: $NVIMGDB is not nvim-gdb $NVIMGDB_SHA" >&2; exit 2; }
echo "nvim-gdb: $NVIMGDB ($NVIMGDB_SHA)"

# 1. Claude config and the scripted model.
KEY=$(nvim --headless -u NONE -i NONE -n -l "$REPO/tests/e2e/claude_seed.lua" "$ROOT/claude-config" "$WS") || exit 1
echo '{ "spinnerTipsEnabled": false }' > "$ROOT/claude-config/settings.json"
sed "s|@WORKSPACE@|$WS|g" "$REPO/demo/plan.json" > "$ROOT/plan.json"
# The endpoint serves until its stdin ends; a FIFO held open on fd 3 keeps it open (cleanup
# also kills it, since a FIFO's EOF does not always reach node on macOS).
mkfifo "$ROOT/model.stdin"
node "$REPO/tests/e2e/fake_model.mjs" "$ROOT/plan.json" "$ROOT/model.jsonl" < "$ROOT/model.stdin" > "$ROOT/model.port" &
MODEL_PID=$!
exec 3> "$ROOT/model.stdin"
i=0
while [ ! -s "$ROOT/model.port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
PORT=$(head -n 1 "$ROOT/model.port")
[ -n "$PORT" ] || { echo "record.sh: the fake model did not start" >&2; exit 1; }

# 2. The shell VHS types into.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; } # single-quote for the rc file
cat > "$ROOT/bashrc" <<EOF
PS1='\[\e[1;34m\]~/stats\[\e[0m\] \[\e[1;35m\]❯\[\e[0m\] '
cd $(q "$WS") || exit 1
nvim() {
  env -i PATH=$(q "$PATH") HOME=$(q "$ROOT") USER=$(q "${USER:-}") LOGNAME=$(q "${LOGNAME:-${USER:-}}") \\
    SHELL=/bin/sh LANG=$(q "${LANG:-en_US.UTF-8}") TERM="\$TERM" COLORTERM=truecolor TMPDIR=$(q "$ROOT/tmp") \\
    XDG_CONFIG_HOME=$(q "$ROOT/xdg/config") XDG_DATA_HOME=$(q "$ROOT/xdg/data") \\
    XDG_STATE_HOME=$(q "$ROOT/xdg/state") XDG_CACHE_HOME=$(q "$ROOT/xdg/cache") \\
    DEMO_MODEL_URL=$(q "http://127.0.0.1:$PORT") DEMO_CLAUDE_CONFIG_DIR=$(q "$ROOT/claude-config") \\
    DEMO_API_KEY=$(q "$KEY") DEMO_NVIMGDB=$(q "$NVIMGDB") \\
    command nvim -u $(q "$REPO/demo/init.lua") -i NONE -n "\$@"
}
EOF

# 3. Record. VHS and its browser keep their temp files in the temp dir too.
# (A subshell cds there: this script's own exported PWD must not name the temp dir, or ours()
# would find its own ps and grep.)
(
  cd "$ROOT" || exit 1
  DEMO_RC="$ROOT/bashrc" TMPDIR="$ROOT/vhs-tmp" exec perl -e 'alarm shift; exec @ARGV' "${DEMO_TIMEOUT:-300}" \
    vhs "$REPO/demo/demo.tape"
) > "$ROOT/vhs.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$ROOT/frames/frame-text-00001.png" ]; then
  echo "record.sh: vhs failed (exit $rc):" >&2
  tail -n 30 "$ROOT/vhs.log" >&2
  exit 1
fi

# 4. Now and then (at random) the terminal in VHS's browser is captured as an empty screen for
# one frame, all background, when Neovim's screen changes a lot (leaving Terminal mode for the
# editor, the diff's tab page opening): a flash the terminal itself never shows. Such a frame (all
# one colour: its lowest luma is its highest) becomes a copy of the frame before it.
perl -e 'alarm shift; exec @ARGV' 300 ffmpeg -v error -i "$ROOT/frames/frame-text-%05d.png" \
  -vf 'signalstats,metadata=print:file=-' -f null - 2>/dev/null |
  awk '/^frame:/ { f++ }
    /YMIN=/ { sub(/.*=/, ""); lo = $0 }
    /YMAX=/ { sub(/.*=/, ""); if ($0 == lo) print f }' > "$ROOT/blank-frames" || exit 1
for n in $(cat "$ROOT/blank-frames"); do
  [ "$n" -gt 1 ] || continue
  cur=$(printf '%05d' "$n")
  prev=$(printf '%05d' $((n - 1)))
  echo "replacing empty frame $n with frame $((n - 1))"
  cp "$ROOT/frames/frame-text-$prev.png" "$ROOT/frames/frame-text-$cur.png" || exit 1
  cp "$ROOT/frames/frame-cursor-$prev.png" "$ROOT/frames/frame-cursor-$cur.png" || exit 1
done

# 5. Encode. Same layers as VHS: the text frames with the cursor frames on top, centered on the
# theme's background. Keep FPS and BG in sync with demo/demo.tape (Framerate, Theme).
FPS=25
W=1400
H=900
BG='#1e1e2e'
nframes=$(ls "$ROOT/frames" | grep -c '^frame-text-')
echo "encoding $nframes frames ($(awk "BEGIN { printf \"%.1f\", $nframes / $FPS }") s)"
LAYERS="[0][1]overlay,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:$BG"
perl -e 'alarm shift; exec @ARGV' 600 ffmpeg -y -v error -framerate $FPS -i "$ROOT/frames/frame-text-%05d.png" \
  -framerate $FPS -i "$ROOT/frames/frame-cursor-%05d.png" \
  -filter_complex "$LAYERS,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  "$ROOT/agent-nvim-demo.gif" || exit 1
mv "$ROOT/agent-nvim-demo.gif" "$OUT/" || exit 1
ls -l "$OUT/agent-nvim-demo.gif"
