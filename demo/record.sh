#!/bin/sh
# Records the README demo: demo/agent-nvim-demo.gif and demo/agent-nvim-demo.mp4.
#
#   demo/record.sh        (or: make demo)
#
# Needs vhs, ttyd, ffmpeg, nvim (0.12+ for the bundled catppuccin colorscheme; older versions
# fall back to habamax), node and claude on PATH, and the "JetBrainsMono Nerd Font" (without it
# VHS silently uses another font; the script warns). The recording was made with vhs 0.12.0,
# nvim 0.12.5 and Claude Code 2.1.283, on macOS; the Linux branch of the cleanup is untested.
#
# The real Claude Code TUI runs inside agent.nvim, against a local scripted model: nothing uses
# your Claude account, your ~/.claude or any real model API.
#   * HOME, XDG_*_HOME and CLAUDE_CONFIG_DIR point into a fresh temp dir, and Neovim's environment
#     is rebuilt with env -i. The config dir is seeded by tests/e2e/claude_seed.lua (onboarding
#     done, workspace trusted, dummy API key approved).
#   * The model is tests/e2e/fake_model.mjs on 127.0.0.1, playing demo/plan.json.
#   * The workspace is a copy of demo/project in the temp HOME (shown as ~/greeter).
# VHS types demo/demo.tape into a bash that sources the generated rc file ($DEMO_RC), which
# defines `nvim` as that isolated Neovim with demo/init.lua. VHS 0.12.0 cannot encode videos
# itself (its ffmpeg step runs with an already cancelled context), so the tape writes PNG frames
# and this script encodes them with ffmpeg.
#
# Variables: DEMO_OUT (directory for the GIF and MP4, default demo/; use a scratch directory for
# trial runs, since every run differs slightly: clock, spinner words, session hash),
# DEMO_KEEP=1 keeps the temp dir (frames, model log), DEMO_TIMEOUT (seconds for vhs, default 300).
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
OUT=${DEMO_OUT:-$REPO/demo}
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd -P) || exit 2

for p in vhs ttyd ffmpeg nvim node claude; do
  command -v "$p" >/dev/null 2>&1 || { echo "record.sh: $p not found on PATH" >&2; exit 2; }
done
set -- $(nvim --version | sed -n '1s/^NVIM v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
if [ "${1:-0}" -eq 0 ] && [ "${2:-0}" -lt 12 ]; then
  echo "record.sh: warning: Neovim 0.12+ recommended (catppuccin colorscheme); using habamax" >&2
fi
if command -v fc-list >/dev/null 2>&1; then
  fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'
else
  ls "$HOME/Library/Fonts" /Library/Fonts 2>/dev/null | grep -qi '^JetBrainsMonoNerdFont'
fi || echo 'record.sh: warning: "JetBrainsMono Nerd Font" not found; VHS will use another font' >&2

REAL_TMPDIR=${TMPDIR:-/tmp}
ROOT=$(mktemp -d "${REAL_TMPDIR%/}/agent-nvim-demo.XXXXXX") || exit 2
ROOT=$(cd "$ROOT" && pwd -P)
WS="$ROOT/home/greeter"
mkdir -p "$ROOT/home" "$ROOT/xdg/config" "$ROOT/xdg/data" "$ROOT/xdg/state" "$ROOT/xdg/cache" "$ROOT/vhs-tmp"
cp -R "$REPO/demo/project" "$WS"
echo "demo temp dir: $ROOT"

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
  # Neovim quit at the end of the tape, which stops Claude; give the rest a moment to exit.
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
  if [ "${DEMO_KEEP:-0}" = 1 ]; then
    echo "kept $ROOT"
  else
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. Claude config and the scripted model.
KEY=$(nvim --headless -u NONE -i NONE -n -l "$REPO/tests/e2e/claude_seed.lua" "$ROOT/claude-config" "$WS") || exit 1
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
PS1='\[\e[1;34m\]~/greeter\[\e[0m\] \[\e[1;35m\]❯\[\e[0m\] '
cd $(q "$WS") || exit 1
nvim() {
  env -i PATH=$(q "$PATH") HOME=$(q "$ROOT/home") USER=$(q "${USER:-}") LOGNAME=$(q "${LOGNAME:-${USER:-}}") \\
    SHELL=/bin/sh LANG=$(q "${LANG:-en_US.UTF-8}") TERM="\$TERM" COLORTERM=truecolor TMPDIR=$(q "$REAL_TMPDIR") \\
    XDG_CONFIG_HOME=$(q "$ROOT/xdg/config") XDG_DATA_HOME=$(q "$ROOT/xdg/data") \\
    XDG_STATE_HOME=$(q "$ROOT/xdg/state") XDG_CACHE_HOME=$(q "$ROOT/xdg/cache") \\
    DEMO_MODEL_URL=$(q "http://127.0.0.1:$PORT") DEMO_CLAUDE_CONFIG_DIR=$(q "$ROOT/claude-config") \\
    DEMO_API_KEY=$(q "$KEY") \\
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

# 4. Encode. Same layers as VHS: the text frames with the cursor frames on top, centered on the
# theme's background. Keep FPS and BG in sync with demo/demo.tape (Framerate, Theme).
FPS=25
W=1400
H=800
BG='#1e1e2e'
nframes=$(ls "$ROOT/frames" | grep -c '^frame-text-')
echo "encoding $nframes frames ($(awk "BEGIN { printf \"%.1f\", $nframes / $FPS }") s)"
LAYERS="[0][1]overlay,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:$BG"
perl -e 'alarm shift; exec @ARGV' 600 ffmpeg -y -v error -framerate $FPS -i "$ROOT/frames/frame-text-%05d.png" \
  -framerate $FPS -i "$ROOT/frames/frame-cursor-%05d.png" \
  -filter_complex "$LAYERS,format=yuv420p" -c:v libx264 -preset slow -crf 20 -movflags +faststart -an \
  "$ROOT/agent-nvim-demo.mp4" || exit 1
perl -e 'alarm shift; exec @ARGV' 600 ffmpeg -y -v error -framerate $FPS -i "$ROOT/frames/frame-text-%05d.png" \
  -framerate $FPS -i "$ROOT/frames/frame-cursor-%05d.png" \
  -filter_complex "$LAYERS,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  "$ROOT/agent-nvim-demo.gif" || exit 1
mv "$ROOT/agent-nvim-demo.mp4" "$ROOT/agent-nvim-demo.gif" "$OUT/" || exit 1
ls -l "$OUT/agent-nvim-demo.gif" "$OUT/agent-nvim-demo.mp4"
