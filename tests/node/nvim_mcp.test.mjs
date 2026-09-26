// Protocol tests for the $NVIM controller (lua/agent/nvim_mcp): the official MCP SDK spawns the
// controller over stdio, pointed at a headless "parent" Neovim started with --listen. A second
// msgpack-RPC channel (a tiny client below) prepares the parent and checks the effects.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MAIN = path.join(ROOT, 'lua', 'agent', 'nvim_mcp', 'main.lua');
const NVIM = process.env.NVIM_BIN || 'nvim';
const FLAGS = ['--headless', '-u', 'NONE', '-i', 'NONE', '-n'];
const TOOL_NAMES = ['edit_buffer', 'eval', 'exec_lua', 'execute_command', 'get_diagnostics', 'get_editor_state',
  'list_buffers', 'notify', 'open_file', 'read_buffer'];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function cleanEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  if (!('NVIM' in extra)) delete env.NVIM;
  return env;
}

// Minimal msgpack codec (enough for Neovim's msgpack-RPC) ---------------------------------------

function encode(value, out = []) {
  const u8 = (...b) => out.push(Buffer.from(b));
  if (value === null || value === undefined) u8(0xc0);
  else if (value === false) u8(0xc2);
  else if (value === true) u8(0xc3);
  else if (typeof value === 'number') {
    if (Number.isInteger(value) && value >= 0 && value < 2 ** 32) {
      if (value < 128) u8(value);
      else if (value < 256) u8(0xcc, value);
      else if (value < 65536) u8(0xcd, value >> 8, value & 255);
      else { const b = Buffer.alloc(5); b[0] = 0xce; b.writeUInt32BE(value, 1); out.push(b); }
    } else if (Number.isInteger(value) && value < 0 && value >= -(2 ** 31)) {
      if (value >= -32) u8(value & 255);
      else { const b = Buffer.alloc(5); b[0] = 0xd2; b.writeInt32BE(value, 1); out.push(b); }
    } else { const b = Buffer.alloc(9); b[0] = 0xcb; b.writeDoubleBE(value, 1); out.push(b); }
  } else if (typeof value === 'string') {
    const s = Buffer.from(value, 'utf8');
    if (s.length < 32) u8(0xa0 | s.length);
    else if (s.length < 256) u8(0xd9, s.length);
    else if (s.length < 65536) u8(0xda, s.length >> 8, s.length & 255);
    else { const b = Buffer.alloc(5); b[0] = 0xdb; b.writeUInt32BE(s.length, 1); out.push(b); }
    out.push(s);
  } else if (Array.isArray(value)) {
    if (value.length < 16) u8(0x90 | value.length);
    else if (value.length < 65536) u8(0xdc, value.length >> 8, value.length & 255);
    else { const b = Buffer.alloc(5); b[0] = 0xdd; b.writeUInt32BE(value.length, 1); out.push(b); }
    for (const v of value) encode(v, out);
  } else if (typeof value === 'object') {
    const keys = Object.keys(value);
    if (keys.length < 16) u8(0x80 | keys.length);
    else u8(0xde, keys.length >> 8, keys.length & 255);
    for (const k of keys) { encode(k, out); encode(value[k], out); }
  } else throw new Error('cannot encode ' + typeof value);
  return out;
}

class NeedMore extends Error {}

function decode(buf, pos) {
  const need = (n) => { if (pos + n > buf.length) throw new NeedMore(); };
  need(1);
  const t = buf[pos++];
  const str = (n) => { need(n); const s = buf.toString('utf8', pos, pos + n); pos += n; return s; };
  const arr = (n) => { const a = []; for (let i = 0; i < n; i++) { const [v, p] = decode(buf, pos); a.push(v); pos = p; } return a; };
  const map = (n) => {
    const o = {};
    for (let i = 0; i < n; i++) {
      const [k, p1] = decode(buf, pos); const [v, p2] = decode(buf, p1); o[k] = v; pos = p2;
    }
    return o;
  };
  const ext = (n) => { need(1 + n); pos += 1; const [v] = decode(buf.subarray(pos, pos + n), 0); pos += n; return v; };
  let v;
  if (t < 0x80) v = t;
  else if (t < 0x90) v = map(t & 15);
  else if (t < 0xa0) v = arr(t & 15);
  else if (t < 0xc0) v = str(t & 31);
  else if (t >= 0xe0) v = t - 256;
  else switch (t) {
    case 0xc0: v = null; break;
    case 0xc2: v = false; break;
    case 0xc3: v = true; break;
    case 0xc4: need(1); v = (() => { const n = buf[pos]; pos += 1; need(n); const b = buf.subarray(pos, pos + n); pos += n; return b; })(); break;
    case 0xc5: need(2); v = (() => { const n = buf.readUInt16BE(pos); pos += 2; need(n); const b = buf.subarray(pos, pos + n); pos += n; return b; })(); break;
    case 0xc6: need(4); v = (() => { const n = buf.readUInt32BE(pos); pos += 4; need(n); const b = buf.subarray(pos, pos + n); pos += n; return b; })(); break;
    case 0xc7: need(1); v = (() => { const n = buf[pos]; pos += 1; return ext(n); })(); break;
    case 0xc8: need(2); v = (() => { const n = buf.readUInt16BE(pos); pos += 2; return ext(n); })(); break;
    case 0xc9: need(4); v = (() => { const n = buf.readUInt32BE(pos); pos += 4; return ext(n); })(); break;
    case 0xca: need(4); v = buf.readFloatBE(pos); pos += 4; break;
    case 0xcb: need(8); v = buf.readDoubleBE(pos); pos += 8; break;
    case 0xcc: need(1); v = buf[pos]; pos += 1; break;
    case 0xcd: need(2); v = buf.readUInt16BE(pos); pos += 2; break;
    case 0xce: need(4); v = buf.readUInt32BE(pos); pos += 4; break;
    case 0xcf: need(8); v = Number(buf.readBigUInt64BE(pos)); pos += 8; break;
    case 0xd0: need(1); v = buf.readInt8(pos); pos += 1; break;
    case 0xd1: need(2); v = buf.readInt16BE(pos); pos += 2; break;
    case 0xd2: need(4); v = buf.readInt32BE(pos); pos += 4; break;
    case 0xd3: need(8); v = Number(buf.readBigInt64BE(pos)); pos += 8; break;
    case 0xd4: v = ext(1); break;
    case 0xd5: v = ext(2); break;
    case 0xd6: v = ext(4); break;
    case 0xd7: v = ext(8); break;
    case 0xd8: v = ext(16); break;
    case 0xd9: need(1); v = (() => { const n = buf[pos]; pos += 1; return str(n); })(); break;
    case 0xda: need(2); v = (() => { const n = buf.readUInt16BE(pos); pos += 2; return str(n); })(); break;
    case 0xdb: need(4); v = (() => { const n = buf.readUInt32BE(pos); pos += 4; return str(n); })(); break;
    case 0xdc: need(2); v = (() => { const n = buf.readUInt16BE(pos); pos += 2; return arr(n); })(); break;
    case 0xdd: need(4); v = (() => { const n = buf.readUInt32BE(pos); pos += 4; return arr(n); })(); break;
    case 0xde: need(2); v = (() => { const n = buf.readUInt16BE(pos); pos += 2; return map(n); })(); break;
    case 0xdf: need(4); v = (() => { const n = buf.readUInt32BE(pos); pos += 4; return map(n); })(); break;
    default: throw new Error('unsupported msgpack type 0x' + t.toString(16));
  }
  return [v, pos];
}

class NvimRpc {
  static connect(addr) {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection(addr);
      sock.once('error', reject);
      sock.once('connect', () => { sock.off('error', reject); resolve(new NvimRpc(sock)); });
    });
  }

  constructor(sock) {
    this.sock = sock;
    this.buf = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
    sock.on('data', (chunk) => this.onData(chunk));
    sock.on('error', () => {});
    sock.on('close', () => {
      for (const p of this.pending.values()) p.reject(new Error('closed'));
      this.pending.clear();
    });
  }

  onData(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      let msg, pos;
      try { [msg, pos] = decode(this.buf, 0); } catch (e) { if (e instanceof NeedMore) return; throw e; }
      this.buf = this.buf.subarray(pos);
      if (msg[0] === 1) {
        const p = this.pending.get(msg[1]);
        if (p) {
          this.pending.delete(msg[1]);
          if (msg[2] !== null) p.reject(new Error(Array.isArray(msg[2]) ? msg[2][1] : String(msg[2])));
          else p.resolve(msg[3]);
        }
      } else if (msg[0] === 0) {
        this.sock.write(Buffer.concat(encode([1, msg[1], [0, 'not supported'], null])));
      }
      // notifications (e.g. UI redraw) are ignored
    }
  }

  request(method, ...params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.sock.write(Buffer.concat(encode([0, id, method, params])));
    });
  }

  lua(code, ...args) {
    return this.request('nvim_exec_lua', code, args);
  }

  close() {
    this.sock.destroy();
  }
}

// Fixtures --------------------------------------------------------------------------------------

let tmp;
let parent;
let sock;
let rpc;

async function waitFor(cond, ms = 5000, what = 'condition') {
  const end = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > end) throw new Error('timeout waiting for ' + what);
    await sleep(20);
  }
}

before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'anv-mcp-'));
  sock = path.join(tmp, 'p.sock');
  parent = spawn(NVIM, [...FLAGS, '--listen', sock], { env: cleanEnv(), stdio: 'ignore' });
  await waitFor(() => fs.existsSync(sock), 5000, 'parent socket');
  rpc = await NvimRpc.connect(sock);
  await rpc.lua('vim.o.showmode = false');
});

after(async () => {
  if (rpc) {
    rpc.request('nvim_command', 'qa!').catch(() => {});
    let timer;
    await Promise.race([
      new Promise((r) => parent.once('exit', r)),
      new Promise((r) => { timer = setTimeout(r, 3000); }),
    ]);
    clearTimeout(timer);
    rpc.close();
  }
  if (parent && parent.exitCode === null) parent.kill('SIGKILL');
  fs.rmSync(tmp, { recursive: true, force: true });
});

async function connectController({ args = [sock], env = {} } = {}) {
  const transport = new StdioClientTransport({
    command: NVIM,
    args: [...FLAGS, '-l', MAIN, ...args],
    env: cleanEnv(env),
    stderr: 'pipe',
  });
  let stderr = '';
  transport.stderr?.on('data', (d) => { stderr += d; });
  const client = new Client({ name: 'nvim-mcp-test', version: '1.0.0' });
  await client.connect(transport);
  return { client, transport, stderr: () => stderr };
}

const text = (res) => res.content[0].text;
const json = (res) => {
  assert.notEqual(res.isError, true, 'tool failed: ' + text(res));
  return JSON.parse(text(res));
};

async function resetParent() {
  await rpc.lua(`
    for _, j in ipairs(vim.g.__test_jobs or {}) do pcall(vim.fn.jobstop, j) end
    vim.g.__test_jobs = {}
    vim.cmd('silent! tabonly! | silent! only!')
    vim.cmd('enew!')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= vim.api.nvim_get_current_buf() then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    vim.diagnostic.reset()
  `);
}

// Opens `file` in the editor window and a `cat` terminal in a right split, which stays current
// (the layout of an agent running in a Neovim terminal).
async function editorWithTerminal(file) {
  return rpc.lua(`
    local file = ...
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    local editor = vim.api.nvim_get_current_win()
    vim.cmd('botright vnew')
    local job = vim.fn.jobstart({ 'cat' }, { term = true })
    vim.g.__test_jobs = { job }
    return { editor = editor, term = vim.api.nvim_get_current_win(), term_buf = vim.api.nvim_get_current_buf() }
  `, file);
}

// Tests -----------------------------------------------------------------------------------------

test('initialize and tools/list through the SDK', async () => {
  const { client } = await connectController();
  try {
    assert.equal(client.getServerVersion().name, 'agent.nvim');
    assert.deepEqual(client.getServerCapabilities(), { tools: {} });
    assert.match(client.getInstructions(), /Neovim/);
    const { tools } = await client.listTools();
    assert.deepEqual(tools.map((t) => t.name).sort(), TOOL_NAMES);
    for (const t of tools) {
      assert.match(t.name, /^[a-z][a-z0-9_]{0,39}$/);
      assert.equal(t.inputSchema.type, 'object');
      assert.equal(t.inputSchema.additionalProperties, false);
      assert.equal(typeof t.description, 'string');
    }
    await client.ping();
  } finally {
    await client.close();
  }
});

test('every tool works against the parent', async () => {
  await resetParent();
  const a = path.join(tmp, 'a.txt');
  const b = path.join(tmp, 'b.txt');
  fs.writeFileSync(a, 'one\ntwo\nthree\n');
  fs.writeFileSync(b, 'b1\nb2\nb3\nb4\n');
  const layout = await editorWithTerminal(a);
  // the user is typing in the agent terminal (terminal-insert mode)
  await rpc.request('nvim_input', 'i');
  await waitFor(async () => (await rpc.request('nvim_get_mode')).mode === 't', 3000, 'terminal mode');
  const aName = await rpc.lua('return vim.api.nvim_buf_get_name(vim.fn.bufnr(...))', a);
  const { client } = await connectController({ env: { AGENT_NVIM_AGENT: 'claude' } });
  try {
    // get_editor_state: "current" is the editor buffer although the terminal is focused
    const state = json(await client.callTool({ name: 'get_editor_state', arguments: {} }));
    assert.equal(state.mode, 't');
    assert.equal(state.current.path, aName);
    assert.deepEqual(state.current.cursor, { line: 1, col: 1 });
    assert.equal(state.windows.length, 2);
    const term = state.windows.find((w) => w.is_terminal);
    assert.equal(term.winid, layout.term);
    assert.equal(term.is_current, true);
    assert.equal(state.visual_selection, null);

    // list_buffers
    const bufs = json(await client.callTool({ name: 'list_buffers', arguments: {} }));
    const ba = bufs.find((x) => x.path === aName);
    assert.equal(ba.line_count, 3);
    assert.equal(ba.is_current, true);
    assert.ok(bufs.some((x) => x.buftype === 'terminal'));

    // read_buffer (by path, with a range)
    assert.equal(text(await client.callTool({ name: 'read_buffer', arguments: { buffer: a, start_line: 2 } })),
      `${aName} (lines 2-3 of 3)\n     2\ttwo\n     3\tthree`);

    // edit_buffer + save, checked through the second channel and on disk
    const edited = json(await client.callTool({
      name: 'edit_buffer', arguments: { buffer: a, start_line: 2, end_line: 2, text: 'TWO\nTWO-B', save: true },
    }));
    assert.deepEqual(edited, { bufnr: ba.bufnr, path: aName, line_count: 4, modified: false, saved: true });
    assert.deepEqual(await rpc.request('nvim_buf_get_lines', ba.bufnr, 0, -1, false), ['one', 'TWO', 'TWO-B', 'three']);
    assert.equal(fs.readFileSync(a, 'utf8'), 'one\nTWO\nTWO-B\nthree\n');

    // open_file: lands in the editor window, never the terminal; selects the range
    const opened = json(await client.callTool({ name: 'open_file', arguments: { path: b, line: 2, end_line: 3 } }));
    assert.equal(opened.winid, layout.editor);
    const after = await rpc.lua(`
      local t = ...
      return {
        cur = vim.api.nvim_get_current_win(),
        name = vim.api.nvim_buf_get_name(0),
        mode = vim.api.nvim_get_mode().mode,
        term_buf = vim.api.nvim_win_get_buf(t),
        sel = vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = 'V' }),
      }`, layout.term);
    assert.equal(after.cur, layout.editor);
    assert.equal(after.name, opened.path);
    assert.equal(after.mode, 'V');
    assert.equal(after.term_buf, layout.term_buf);
    assert.deepEqual(after.sel, ['b2', 'b3']);
    await rpc.request('nvim_input', '<Esc>');

    // get_diagnostics
    await rpc.lua(`
      local buf = ...
      local ns = vim.api.nvim_create_namespace('node_test')
      vim.diagnostic.set(ns, buf, { { lnum = 1, col = 0, end_lnum = 1, end_col = 3, severity = 1, message = 'bad', source = 'test' } })
    `, ba.bufnr);
    assert.deepEqual(json(await client.callTool({ name: 'get_diagnostics', arguments: { buffer: ba.bufnr } })), [
      { path: aName, line: 2, col: 1, end_line: 2, end_col: 3, severity: 'error', message: 'bad', source: 'test', code: null },
    ]);
    assert.deepEqual(json(await client.callTool({ name: 'get_diagnostics', arguments: { min_severity: 'error' } })).length, 1);

    // execute_command, eval, exec_lua
    assert.equal(text(await client.callTool({ name: 'execute_command', arguments: { command: 'echo "hello"' } })), 'hello');
    assert.equal(text(await client.callTool({ name: 'eval', arguments: { expression: '[1, v:null, "x"]' } })), '[1,null,"x"]');
    assert.equal(text(await client.callTool({
      name: 'exec_lua', arguments: { code: 'vim.g.from_agent = ...; return vim.g.from_agent, 2', args: ['hi'] },
    })), '["hi",2]');
    assert.equal(await rpc.request('nvim_get_var', 'from_agent'), 'hi');

    // notify: shown in the parent (message history in a headless Neovim)
    assert.equal(text(await client.callTool({ name: 'notify', arguments: { message: 'hello from the agent' } })), 'ok');
    await waitFor(async () => (await rpc.request('nvim_exec2', 'messages', { output: true })).output
      .includes('hello from the agent'), 3000, 'notification');

    // errors are tool results, not protocol errors
    const bad = await client.callTool({ name: 'exec_lua', arguments: { code: 'error("kaboom")' } });
    assert.equal(bad.isError, true);
    assert.match(text(bad), /kaboom/);
    const invalid = await client.callTool({ name: 'read_buffer', arguments: { start_line: 'first' } });
    assert.equal(invalid.isError, true);
    assert.match(text(invalid), /start_line/);
    const term_edit = await client.callTool({
      name: 'edit_buffer', arguments: { buffer: layout.term_buf, start_line: 1, end_line: 1, text: 'x' },
    });
    assert.equal(term_edit.isError, true);
  } finally {
    await client.close();
  }
});

test('per-request timeout, while the server keeps answering', async () => {
  await resetParent();
  const { client } = await connectController({ env: { AGENT_NVIM_TIMEOUT_MS: '400' } });
  try {
    const started = Date.now();
    const slow = client.callTool({ name: 'exec_lua', arguments: { code: 'vim.uv.sleep(1500)' } });
    await sleep(50);
    const pingStart = Date.now();
    await client.ping();
    assert.ok(Date.now() - pingStart < 300, 'ping is answered while a tool call is in flight');
    const res = await slow;
    const elapsed = Date.now() - started;
    assert.equal(res.isError, true);
    assert.match(text(res), /within 400 ms/);
    assert.match(text(res), /may still run later/);
    assert.ok(elapsed < 1400, `timed out after ${elapsed} ms`);
    await sleep(1300);
    assert.equal(text(await client.callTool({ name: 'eval', arguments: { expression: '6*7' } })), '42');
  } finally {
    await client.close();
  }
});

test('refuses to run while the parent is at a hit-enter prompt', async () => {
  await resetParent();
  const ui = await NvimRpc.connect(sock);
  const { client } = await connectController();
  try {
    await ui.request('nvim_ui_attach', 80, 24, { rgb: true });
    await ui.request('nvim_input', ':echo "a\\nb\\nc"<CR>');
    await waitFor(async () => (await ui.request('nvim_get_mode')).blocking === true, 3000, 'prompt');
    const res = await client.callTool({ name: 'exec_lua', arguments: { code: 'vim.g.should_not_run = 1' } });
    assert.equal(res.isError, true);
    assert.match(text(res), /waiting for input at a prompt/);
    await ui.request('nvim_input', '<CR>');
    await waitFor(async () => (await ui.request('nvim_get_mode')).blocking === false, 3000, 'prompt dismissed');
    assert.equal(await ui.request('nvim_eval', 'get(g:, "should_not_run", -1)'), -1);
  } finally {
    await ui.request('nvim_ui_detach').catch(() => {});
    ui.close();
    await client.close();
  }
});

test('zero tools without a Neovim address', async () => {
  for (const variant of [
    { args: [], env: { NVIM: '' } },
    { args: ['${NVIM}'], env: { NVIM: '', AGENT_NVIM_MCP_DEBUG: '1' } },
  ]) {
    const { client, stderr } = await connectController(variant);
    try {
      assert.deepEqual(client.getServerCapabilities(), { tools: {} });
      const { tools } = await client.listTools();
      assert.deepEqual(tools, []);
      await client.ping();
    } finally {
      await client.close();
    }
    // quiet by default (agents log MCP stderr as errors); explained with AGENT_NVIM_MCP_DEBUG
    if (variant.env.AGENT_NVIM_MCP_DEBUG) assert.match(stderr(), /zero tools/);
    else assert.equal(stderr(), '');
  }
});

test('raw stdio: discover, unknown methods, responses, notifications, versions, EOF', async () => {
  const child = spawn(NVIM, [...FLAGS, '-l', MAIN, sock], { env: cleanEnv(), stdio: ['pipe', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  const lines = () => out.split('\n').filter((l) => l !== '');
  const send = (obj) => child.stdin.write((typeof obj === 'string' ? obj : JSON.stringify(obj)) + '\n');
  const replyTo = async (id) => {
    let found;
    await waitFor(() => {
      found = lines().map((l) => JSON.parse(l)).find((m) => m.id === id);
      return found !== undefined;
    }, 3000, 'reply ' + id);
    return found;
  };

  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'raw', version: '1' } } });
  const init = await replyTo(1);
  assert.equal(init.result.protocolVersion, '2025-03-26');
  assert.ok(lines()[0].includes('"capabilities":{"tools":{}}'), 'capabilities.tools is an object: ' + lines()[0]);
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  send({ jsonrpc: '2.0', id: 2, method: 'server/discover', params: {} });
  assert.deepEqual((await replyTo(2)).error, { code: -32601, message: 'Method not found' });
  send({ jsonrpc: '2.0', id: 3, method: 'resources/list', params: {} });
  assert.equal((await replyTo(3)).error.code, -32601);
  send({ jsonrpc: '2.0', id: 'client-req', result: { ok: true } });
  send({ jsonrpc: '2.0', id: 'client-err', error: { code: -1, message: 'x' } });
  send({ jsonrpc: '2.0', method: 'notifications/unknown', params: {} });
  send('{not json');
  send({ jsonrpc: '2.0', id: 4, method: 'initialize', params: { protocolVersion: '1999-01-01' } });
  assert.equal((await replyTo(4)).result.protocolVersion, '2025-11-25');
  send({ jsonrpc: '2.0', id: 'last', method: 'ping' });
  assert.deepEqual((await replyTo('last')).result, {});

  const msgs = lines().map((l) => JSON.parse(l));
  assert.deepEqual(msgs.map((m) => m.id), [1, 2, 3, null, 4, 'last'], 'no replies to responses or notifications');
  assert.equal(msgs[3].error.code, -32700);

  const exit = new Promise((r) => child.once('exit', (code) => r(code)));
  child.stdin.end();
  assert.equal(await exit, 0);
});

test('a call in flight when stdin closes is still answered, then the process exits 0', async () => {
  await resetParent();
  const child = spawn(NVIM, [...FLAGS, '-l', MAIN, sock], { env: cleanEnv(), stdio: ['pipe', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  const exit = new Promise((r) => child.once('exit', (code) => r(code)));
  child.stdin.write(JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name: 'exec_lua', arguments: { code: 'vim.uv.sleep(300) return "late"' } },
  }) + '\n');
  child.stdin.end();
  assert.equal(await exit, 0);
  const msgs = out.split('\n').filter((l) => l).map((l) => JSON.parse(l));
  assert.deepEqual(msgs, [{ jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: '"late"' }] } }]);
});
