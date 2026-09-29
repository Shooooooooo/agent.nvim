#!/bin/sh
# Fake agent CLI for the process-tree stop tests. It ignores the hangup of its terminal (SIGHUP),
# as Gemini CLI does at times, and so does its child, which runs in a process group of its own
# (set -m), out of reach of a signal to the terminal's process group. Only SIGTERM (or SIGKILL)
# sent to each of them ends them. Writes "<pid> <child pid>" to $FAKE_AGENT_OUT.pids once both run.
out="${FAKE_AGENT_OUT:?FAKE_AGENT_OUT is required}"
trap '' HUP
set -m
sleep 300 &
child=$!
echo "$$ $child" > "$out.pids.tmp" && mv "$out.pids.tmp" "$out.pids"
wait
