-- agent.nvim user commands. This file never calls setup(): each command calls setup({}) once,
-- lazily, when the user has not called require('agent').setup() themselves.
if vim.g.loaded_agent_nvim == 1 then
  return
end
vim.g.loaded_agent_nvim = 1

if vim.fn.has('nvim-0.11') ~= 1 then
  vim.api.nvim_echo({ { 'agent.nvim requires Neovim 0.11 or newer', 'ErrorMsg' } }, true, {})
  return
end

local function run(name)
  return function(o)
    require('agent')._command(name, o)
  end
end

local function complete_agents(lead)
  return require('agent')._complete_agents(lead)
end

local commands = {
  { 'Agent', { nargs = '?', complete = complete_agents, desc = 'Toggle an agent terminal' } },
  { 'AgentOpen', { nargs = '?', complete = complete_agents, desc = 'Open (start or show) an agent terminal' } },
  { 'AgentClose', { nargs = '?', complete = complete_agents, desc = 'Hide an agent terminal (the agent keeps running)' } },
  { 'AgentStop', { nargs = '?', bang = true, complete = complete_agents,
    desc = 'Stop an agent (with !: stop all agents and IDE servers)' } },
  { 'AgentDiffAccept', { nargs = 0, desc = 'Accept the proposed change in the current diff' } },
  { 'AgentDiffReject', { nargs = 0, desc = 'Reject the proposed change in the current diff' } },
  { 'AgentStatus', { nargs = 0, desc = 'Show agents and IDE servers' } },
  { 'AgentMcpConfig', { nargs = '?', complete = complete_agents,
    desc = 'Print the MCP config for registering the Neovim controller by hand' } },
  { 'AgentGeminiSetup', { nargs = 0, desc = 'Link the agent.nvim extension into Gemini CLI (one time)' } },
}

for _, c in ipairs(commands) do
  -- `bar` lets commands be chained with `|` (e.g. in mappings), like built-in Ex commands.
  c[2].bar = true
  vim.api.nvim_create_user_command(c[1], run(c[1]), c[2])
end
