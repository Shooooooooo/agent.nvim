# agent.nvim README demo. Do not run this tape directly: run demo/record.sh (or `make demo`),
# which builds the isolated environment, exports DEMO_RC and encodes the frames written here.
#
# Story: open Neovim on a small Lua module, start Claude Code with :AgentToggle claude (in the
# default split below the file; its chip shows the open file), select a function (the chip follows
# the selection), go straight to Claude's prompt and ask for a change (Claude gets the selected
# lines), watch the $NVIM controller's notification, review the proposed edit in a Neovim diff (a
# tab of its own: original | proposed on top, Claude below, waiting for the review) and accept it
# with :w, then run the new code. The model turn is scripted in demo/plan.json.

# VHS 0.12.0 cannot encode videos (see record.sh), so it only writes the frames.
Output frames/

Require nvim
Require claude

Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 16
# Without VHS's default extra pixel between letters the terminal is 148 columns wide.
Set LetterSpacing 0
# record.sh centers the frames on a 1400x800 background when it encodes them.
Set Width 1364
Set Height 764
Set Padding 0
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 70ms
Set CursorBlink false

# Hidden setup: the isolated `nvim` function, the prompt and the working directory, then Neovim
# on the sample project, so that the first frame (all that viewers with autoplay off see)
# already shows the code.
Hide
Type@1ms 'source "$DEMO_RC"; clear'
Enter
Wait+Screen@10s /greeter/
Type@1ms "nvim greet.lua"
Enter
Wait+Screen@20s /M\.greet/
Sleep 500ms
Show

# 1. Neovim on the sample project.
Sleep 3s

# 2. Claude Code in a split below the file, connected to Neovim. The split and the terminal open
# under Hide: VHS would otherwise catch Neovim's screen clear half way (one blank frame).
Type ":AgentToggle claude"
Sleep 700ms
Hide
Enter
Wait+Screen@60s /Claude Code/
Show
Wait+Screen@60s /In greet\.lua/
Sleep 3.5s

# 3. Back in the file (<C-w>k), select the function. Claude's chip follows the selection as it
# grows.
Ctrl+\
Ctrl+N
Ctrl+W
Type "k"
Sleep 600ms
Type "4G"
Sleep 400ms
Type "V"
Down@200ms 9
Wait+Screen@10s /10 lines selected/
Sleep 3s

# 4. Straight from Visual mode to Claude's prompt (<C-w>j): leaving Visual mode keeps the
# selection, so the chip still shows the lines. Ask for the change; Claude's transcript shows
# the selected lines went along. (The switch is hidden: it would show Neovim's normal-mode
# cursor inside Claude's prompt for a frame.)
Hide
Ctrl+W
Type "j"
Type "i"
Sleep 300ms
Wait+Screen@10s /10 lines selected/
Show
Sleep 2s
Type "use table.concat and handle an empty list"
Sleep 1s
Enter
Wait+Screen@20s /Selected 10 lines from greet\.lua/

# 5. The model notifies through the $NVIM controller, then proposes an edit: a diff tab opens,
# original | proposed on top and Claude below, where Claude shows its own permission prompt for the
# edit.
Wait+Screen@60s /Review the diff/
Wait+Screen@60s /proposed/
Wait+Screen@20s /Opened changes in Neovim/
Sleep 6.5s

# 6. Accept the proposal with :w. Claude writes the file and the buffer reloads. The switch back
# is hidden until both have settled: in between, Claude redraws its whole screen (and for a
# frame still shows its permission dialog) while the editor still shows the old code. Claude's
# Update block is taller than its 14 rows: the wait is for its last lines (its '+' line for the
# new return), not for its 'Added N lines' header, which has scrolled out of the pane.
Type ":w"
Sleep 700ms
Hide
Enter
Wait+Screen@60s /\d \+\s+return "Hello, "/
Wait+Screen@10s /(?m)^\s*12 return M/
Show
Wait+Screen@60s /instead of/
Sleep 4s

# 7. The result: back in the editor, the new greet() handles the empty list.
Ctrl+\
Ctrl+N
Ctrl+W
Type "k"
Sleep 1s
Type ":=require('greet').greet({})"
Sleep 700ms
Enter
Wait+Screen@10s /(?m)^"Hello!"/
Sleep 3s

# Hidden teardown.
Hide
Ctrl+\
Ctrl+N
Type ":qa!"
Enter
Wait@20s /greeter/
