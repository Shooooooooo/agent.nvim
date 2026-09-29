// Local fake model endpoint for the live end-to-end tests (tests/e2e). Nothing leaves 127.0.0.1.
//
// usage: node fake_model.mjs <plan.json> <log.jsonl>
// Prints the port on stdout, exits when stdin closes (so it never outlives its parent).
//
// Serves both wire formats:
//   Anthropic Messages      POST /v1/messages            (Claude Code, via ANTHROPIC_BASE_URL)
//   OpenAI chat completions POST /v1/chat/completions    (Copilot CLI BYOK, OpenCode openai-compatible)
//   GET /v1/models, POST /v1/messages/count_tokens, HEAD/GET anything else -> harmless answers
//
// plan.json: { "trigger": "PLEASE_EDIT", "steps": [{ "tool": "<regex>", "input": {...} }, ...], "final": "Done." }
// Optional pacing keys (used by demo/plan.json; the e2e plans leave them out and get instant answers):
//   step.text          a text block streamed before the step's tool call
//   step.delay_ms      wait before answering that step (default: plan.delay_ms, else 0)
//   plan.final_delay_ms  wait before the final answer (default: plan.delay_ms, else 0)
//   plan.chunk_ms      stream text in word-sized chunks, this many ms apart (default 0: one chunk)
// A request is part of the scripted turn when some user text contains the trigger. The next step is
// the number of tool results in the conversation that answer OUR earlier tool calls (ids with an
// e2e prefix), so synthetic tool results an agent adds itself (e.g. Claude reading a file the
// prompt names with @path) do not shift the script. A step's tool is a regex matched against the tool names in the
// request; when none matches (a side request such as a title, or a missing tool) the answer is a
// plain text "OK" and the miss is logged.
// Each request of the scripted turn logs, as `input`, the text of the messages after the model's
// last answer: the prompt and what the agent attached to it (its IDE context, such as the selection
// sent with :AgentSend; Claude Code puts it in a system message after the prompt), which
// tests/e2e/driver.lua checks.
import http from 'node:http';
import fs from 'node:fs';

const [planFile, logFile] = process.argv.slice(2);
const plan = JSON.parse(fs.readFileSync(planFile, 'utf8'));
const log = (entry) => fs.appendFileSync(logFile, JSON.stringify({ t: new Date().toISOString(), ...entry }) + '\n');
let counter = 0;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const delayOf = (v) => (typeof v === 'number' ? v : typeof plan.delay_ms === 'number' ? plan.delay_ms : 0);

const textOf = (content) => {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map((b) => (typeof b === 'string' ? b : b.type === 'text' ? b.text : '')).join(' ');
};

const resultText = (content) => (typeof content === 'string' ? content : JSON.stringify(content));

// Returns { step, results: [{id, text}], triggered }
function progress(api, body) {
  const msgs = body.messages || [];
  const results = [];
  let triggered = false;
  for (const m of msgs) {
    if (m.role === 'user' && textOf(m.content).includes(plan.trigger)) triggered = true;
    if (api === 'anthropic' && Array.isArray(m.content)) {
      for (const b of m.content) {
        if (b.type === 'tool_result' && String(b.tool_use_id).startsWith('toolu_e2e_')) {
          results.push({ id: b.tool_use_id, text: resultText(b.content).slice(0, 2000) });
        }
        if (b.type === 'text' && m.role === 'user' && b.text.includes(plan.trigger)) triggered = true;
      }
    }
    if (api === 'openai' && m.role === 'tool' && String(m.tool_call_id).startsWith('call_e2e_')) {
      results.push({ id: m.tool_call_id, text: resultText(m.content).slice(0, 2000) });
    }
  }
  return { step: results.length, results, triggered };
}

// The text of the user and system messages after the last assistant message (tool results and a
// leading system prompt left out).
function inputText(body) {
  const msgs = body.messages || [];
  let i = msgs.length;
  while (i > 0 && msgs[i - 1].role !== 'assistant') i--;
  if (i === 0 && msgs[0]?.role === 'system') i = 1;
  return msgs.slice(i).filter((m) => m.role === 'user' || m.role === 'system').map((m) => textOf(m.content)).join('\n');
}

function toolNames(api, body) {
  return (body.tools || []).map((t) => (api === 'openai' ? t.function?.name ?? t.name : t.name)).filter(Boolean);
}

// -> { tool: {name, input} } | { text }
function decide(api, body) {
  const names = toolNames(api, body);
  const p = progress(api, body);
  if (!p.triggered || names.length === 0) return { text: 'OK', why: 'side request' };
  if (p.step >= plan.steps.length) {
    return { text: plan.final || 'Done.', step: p.step, results: p.results, delay: delayOf(plan.final_delay_ms) };
  }
  const want = plan.steps[p.step];
  const re = new RegExp(want.tool);
  const name = names.find((n) => re.test(n));
  if (!name) {
    return { text: 'OK', why: `missing tool ${want.tool}`, step: p.step, tools: names };
  }
  return { tool: { name, input: want.input }, text: want.text, step: p.step, results: p.results, delay: delayOf(want.delay_ms) };
}

// Text deltas: the whole text at once, or word-sized chunks when plan.chunk_ms is set.
const chunksOf = (text) => (plan.chunk_ms > 0 ? text.match(/\S+\s*|\s+/g) || [text] : [text]);

async function anthropic(body, res, d) {
  const id = 'msg_e2e_' + counter;
  const model = body.model || 'claude-fake';
  const usage = { input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
  const blocks = [];
  if (d.text) blocks.push({ type: 'text', text: d.text });
  if (d.tool) blocks.push({ type: 'tool_use', id: 'toolu_e2e_' + counter, name: d.tool.name, input: d.tool.input });
  const stop = d.tool ? 'tool_use' : 'end_turn';
  if (!body.stream) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ id, type: 'message', role: 'assistant', model, content: blocks, stop_reason: stop, stop_sequence: null, usage }));
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const ev = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  ev('message_start', { type: 'message_start', message: { id, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { ...usage, output_tokens: 1 } } });
  for (const [index, block] of blocks.entries()) {
    if (block.type === 'tool_use') {
      ev('content_block_start', { type: 'content_block_start', index, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } });
      ev('content_block_delta', { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } });
    } else {
      ev('content_block_start', { type: 'content_block_start', index, content_block: { type: 'text', text: '' } });
      for (const [i, chunk] of chunksOf(block.text).entries()) {
        if (i > 0) await sleep(plan.chunk_ms);
        ev('content_block_delta', { type: 'content_block_delta', index, delta: { type: 'text_delta', text: chunk } });
      }
    }
    ev('content_block_stop', { type: 'content_block_stop', index });
  }
  ev('message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } });
  ev('message_stop', { type: 'message_stop' });
  res.end();
}

function openai(body, res, d) {
  const id = 'chatcmpl-e2e-' + counter;
  const model = body.model || 'fake';
  const usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 };
  const toolCalls = d.tool
    ? [{ index: 0, id: 'call_e2e_' + counter, type: 'function', function: { name: d.tool.name, arguments: JSON.stringify(d.tool.input) } }]
    : undefined;
  const finish = d.tool ? 'tool_calls' : 'stop';
  if (!body.stream) {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ id, object: 'chat.completion', created: 1, model, choices: [{ index: 0, message: { role: 'assistant', content: d.text ?? null, tool_calls: toolCalls }, finish_reason: finish }], usage }));
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const chunk = (delta, finishReason, extra) =>
    res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1, model, choices: [{ index: 0, delta, finish_reason: finishReason }], ...extra })}\n\n`);
  chunk(d.tool ? { role: 'assistant', content: d.text ?? null, tool_calls: toolCalls } : { role: 'assistant', content: d.text }, null);
  chunk({}, finish, { usage });
  res.end('data: [DONE]\n\n');
}

const server = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    counter++;
    let body = {};
    try {
      body = JSON.parse(raw || '{}');
    } catch {}
    const url = req.url || '';
    if (url.includes('/count_tokens')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ input_tokens: 100 }));
    }
    if (req.method === 'GET' && url.includes('/models')) {
      log({ kind: 'REQ', method: req.method, url });
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ object: 'list', data: [{ id: body.model || 'gpt-4.1', object: 'model', owned_by: 'e2e' }] }));
    }
    const api = url.includes('/chat/completions') ? 'openai' : url.includes('/messages') ? 'anthropic' : null;
    if (req.method !== 'POST' || !api) {
      log({ kind: 'REQ', method: req.method, url });
      res.writeHead(req.method === 'HEAD' ? 200 : 404, { 'content-type': 'application/json' });
      return res.end(req.method === 'HEAD' ? undefined : JSON.stringify({ error: { message: 'not found' } }));
    }
    const d = decide(api, body);
    const input = progress(api, body).triggered ? inputText(body).slice(0, 50000) || undefined : undefined;
    log({ kind: 'REQ', api, url, model: body.model, stream: !!body.stream, nmsgs: (body.messages || []).length,
      ntools: toolNames(api, body).length, step: d.step, results: d.results, why: d.why, tools: d.tools, input });
    log({ kind: 'RESP', api, step: d.step, tool: d.tool, text: d.text, delay: d.delay || undefined });
    const answer = () => (api === 'openai' ? openai(body, res, d) : anthropic(body, res, d));
    if (d.delay > 0) setTimeout(answer, d.delay);
    else answer();
  });
});

server.listen(0, '127.0.0.1', () => {
  process.stdout.write(server.address().port + '\n');
  log({ kind: 'LISTEN', port: server.address().port });
});
process.stdin.on('end', () => process.exit(0));
process.stdin.on('error', () => process.exit(0));
process.stdin.resume();
