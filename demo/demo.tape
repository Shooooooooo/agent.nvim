# agent.nvim README demo. Do not run this tape directly: run demo/record.sh (or `make demo`),
# which builds the isolated environment (nvim-gdb and animate.nvim included), exports DEMO_RC and
# encodes the frames written here.
#
# Story: Neovim on a small Python script whose mean() is wrong; the user opens Claude Code below
# (:AgentToggle claude) and asks it to debug the script in a pdb session with nvim-gdb. Everything
# else is Claude, through the $NVIM controller: it starts the session (execute_command
# "GdbStartPDB python3 -m pdb stats.py"), which puts pdb's terminal on the right of the script,
# sends pdb commands with nvim-gdb's :Gdb and reads pdb's answers (exec_lua), while nvim-gdb marks
# the line pdb stopped on in the script (▶, next to the breakpoint's ●). Claude proposes the fix
# in a Neovim diff (accepted with :w), re-runs the script in the same pdb session to the same
# breakpoint, runs it to the end and notifies the result. animate.nvim flies Claude's split and
# pdb's in as they open. The model turn is scripted in demo/plan.json; Neovim, nvim-gdb,
# animate.nvim, Claude Code and pdb really run.

# VHS 0.12.0 cannot encode videos (see record.sh), so it only writes the frames.
Output frames/

Require nvim
Require claude
Require python3

Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 16
# Without VHS's default extra pixel between letters the terminal is 148 columns wide.
Set LetterSpacing 0
# record.sh centers the frames on a 1400x900 background when it encodes them.
Set Width 1364
Set Height 864
Set Padding 0
Set Theme "Catppuccin Mocha"
Set Framerate 25
Set TypingSpeed 60ms
Set CursorBlink false

# Hidden setup: the isolated `nvim` function, the prompt and the working directory, then Neovim
# on the script, so that the first frame (all that viewers with autoplay off see) already shows
# the code.
Hide
Type@1ms 'source "$DEMO_RC"; clear'
Enter
Wait+Screen@10s /stats/
Type@1ms "nvim stats.py"
Enter
Wait+Screen@20s /def mean/
Sleep 500ms
Show

# 1. The script, then Claude Code in a split below, which flies in from the bottom edge
# (animate.nvim), and the question.
Sleep 3s
Type ":AgentToggle claude"
Sleep 700ms
Enter
Wait+Screen@60s /Claude Code/
Sleep 3s
Type "mean([4, 8, 6]) prints 4.67 instead of 6.0. Debug it in a pdb session with nvim-gdb"
Sleep 1s
Enter

# 2. Claude starts the session (execute_command :GdbStartPDB): pdb's terminal flies in on the right
# of the script (animate.nvim), whose first line nvim-gdb marks. Then it breaks in the loop and
# prints the variables (exec_lua, nvim-gdb's :Gdb): the mark follows pdb to line 4. The user's
# cursor stays in Claude's pane throughout.
Wait+Screen@60s /\(Pdb\)/
Wait+Screen@60s /\(1, 8, 0\)/
# 3. The analysis, then the fix as a diff in a tab of its own: original | proposed on top, Claude
# below, where Claude shows its own permission prompt for the edit.
Wait+Screen@60s /proposed/
Wait+Screen@30s /Do you want to make this edit/
Sleep 6s
Escape
Type ":w"
Sleep 700ms
# Accepted: Claude writes the file, the buffer reloads, the diff's tab closes and the focus goes
# back to Claude's pane, in Terminal mode (which also clears the ":w" from the command line).
# Hidden until all of that has settled.
Hide
Enter
Wait+Screen@60s /\+\s+for i in range\(len\(xs\)\):/
Wait+Screen@10s /(?m)^.{0,3}\s*3\s+for i in range\(len\(xs\)\):/
Wait+Screen@10s /TERMINAL/
Sleep 300ms
Show
# 4. The same pdb session re-runs the fixed script to the same breakpoint (the mark is back on
# line 4 under the fixed loop), then to the end; Claude notifies the result.
Wait+Screen@60s /\(0, 4, 0\)/
Wait+Screen@60s /The program finished/
Wait+Screen@60s /= 6\.0 in the pdb session/
Wait+Screen@60s /now prints 6\.0/
# 5. Hold the final frame.
Sleep 6s

# Hidden teardown.
Hide
Ctrl+\
Ctrl+N
Type ":qa!"
Enter
Wait@20s /stats/
