// Client-replay tests for lua/agent/providers/claude.lua, served by a headless Neovim
// (tests/node/fixtures/provider_claude.lua).
//  - "Claude Code 2.1.283": a raw TCP client that sends the exact upgrade request and JSON-RPC
//    messages captured from the real CLI (claude-opencode.md §3.2, §4.2, Appendix A), then the
//    tool calls the CLI makes around an Edit (§5), with masked frames like Bun's client.
//  - The `ws` library with Claude's options (protocols ['mcp'] + auth header), like Bun's WebSocket.
//  - "OpenCode": lock discovery and the client logic ported from opencode/packages/tui/src/
//    editor.ts and context/editor.ts (lowercase auth header, no subprotocol, schema checks).
// Run: cd tests/node && node --test provider_claude.test.mjs
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, readdirSync, readFileSync, statSync, writeFileSync, mkdirSync, realpathSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import net from 'node:net';
import path from 'node:path';
import crypto from 'node:crypto';
import WebSocket from 'ws';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'provider_claude.lua');
const NVIM = process.env.NVIM_BIN || 'nvim';
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Captured from Claude Code 2.1.283 [probe:probe.log]; Host and the token are filled in per run.
const CLAUDE_UPGRADE = (port, token) =>
  [
    'GET / HTTP/1.1',
    `Host: 127.0.0.1:${port}`,
    'Connection: Upgrade',
    'Upgrade: websocket',
    'Sec-WebSocket-Version: 13',
    'Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits',
    'Sec-WebSocket-Key: RN20ewn815D8uHEla2DB/w==',
    'Sec-WebSocket-Protocol: mcp',
    'User-Agent: claude-code/2.1.283 (cli)',
    `X-Claude-Code-Ide-Authorization: ${token}`,
    '',
    '',
  ].join('\r\n');
const CLAUDE_INITIALIZE =
  '{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.283","description":"Anthropic\'s agentic coding tool","websiteUrl":"https://claude.com/claude-code"}},"jsonrpc":"2.0","id":0}';
const CLAUDE_INITIALIZED = '{"jsonrpc":"2.0","method":"notifications/initialized"}';
const CLAUDE_IDE_CONNECTED = (pid) => `{"jsonrpc":"2.0","method":"ide_connected","params":{"pid":${pid}}}`;
const CLAUDE_TOOLS_LIST = '{"method":"tools/list","jsonrpc":"2.0","id":1}';
// Claude's tools/call shape (captured live from Claude Code 2.1.283): arguments always present, _meta.progressToken = id.
const CLAUDE_TOOL_CALL = (id, name, args) =>
  JSON.stringify({ method: 'tools/call', params: { name, arguments: args, _meta: { progressToken: id } }, jsonrpc: '2.0', id });

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

async function startFixture() {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), 'apcn-')));
  const lockDir = path.join(dir, 'home', '.claude', 'ide');
  const workspace = path.join(dir, 'ws');
  mkdirSync(workspace, { recursive: true });
  writeFileSync(path.join(workspace, 'a.txt'), 'hello\nworld\n');
  writeFileSync(path.join(workspace, 'b.txt'), 'one\ntwo\nthree\n');
  const env = { ...process.env, XDG_STATE_HOME: path.join(dir, 'state') };
  delete env.NVIM;
  const proc = spawn(NVIM, ['--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', FIXTURE, ROOT, lockDir, workspace], {
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  proc.stderr.on('data', (d) => (stderr += d));
  const waiters = new Map();
  const lines = [];
  let firstLine;
  const first = new Promise((r) => (firstLine = r));
  let buf = '';
  let started = false;
  proc.stdout.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!started) {
        started = true;
        firstLine(line);
        continue;
      }
      const msg = JSON.parse(line);
      const w = waiters.get(msg.id);
      if (w) {
        waiters.delete(msg.id);
        w(msg);
      } else lines.push(msg);
    }
  });
  const exited = new Promise((r) => proc.on('exit', r));
  const t = setTimeout(() => proc.kill('SIGKILL'), 15000);
  const info = JSON.parse(await first);
  clearTimeout(t);
  if (info.error) throw new Error('fixture failed: ' + info.error + stderr);
  let seq = 0;
  return {
    ...info,
    dir,
    lockDir,
    workspace,
    proc,
    stderr: () => stderr,
    /** Run a Lua chunk in the fixture (P = provider, diff = agent.editor.diff). */
    lua(code) {
      const id = ++seq;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('lua timeout: ' + code + '\n' + stderr)), 10000);
        waiters.set(id, (msg) => {
          clearTimeout(timer);
          if (!msg.ok) reject(new Error('lua error: ' + msg.result));
          else resolve(msg.result);
        });
        proc.stdin.write(JSON.stringify({ id, lua: code }) + '\n');
      });
    },
    async stop() {
      if (proc.exitCode === null) {
        proc.stdin.write('quit\n');
        proc.stdin.end();
        const k = setTimeout(() => proc.kill('SIGKILL'), 5000);
        await exited;
        clearTimeout(k);
      }
      const leftovers = existsSync(lockDir) ? readdirSync(lockDir) : [];
      rmSync(dir, { recursive: true, force: true });
      if (stderr.trim()) console.error('[fixture stderr]', stderr.trim());
      return leftovers;
    },
  };
}

const luaStr = (s) => JSON.stringify(s); // JSON string literals are valid Lua strings for our inputs

// ---------------------------------------------------------------------------
// Claude-style raw client (masked frames, exact captured bytes)
// ---------------------------------------------------------------------------

function maskedFrame(opcode, payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
  const mask = crypto.randomBytes(4);
  let header;
  if (data.length < 126) {
    header = Buffer.from([0x80 | opcode, 0x80 | data.length]);
  } else if (data.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(data.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(data.length), 2);
  }
  const body = Buffer.alloc(data.length);
  for (let i = 0; i < data.length; i++) body[i] = data[i] ^ mask[i % 4];
  return Buffer.concat([header, mask, body]);
}

/** Discover the lock the way Claude does with CLAUDE_CODE_SSE_PORT set: <lock dir>/<port>.lock. */
function claudeLock(fx) {
  const lock = JSON.parse(readFileSync(path.join(fx.lockDir, `${fx.port}.lock`), 'utf8'));
  assert.equal(lock.transport, 'ws');
  return lock;
}

async function rawClaude(fx, { token } = {}) {
  const lock = claudeLock(fx);
  const sock = net.connect(fx.port, '127.0.0.1');
  await new Promise((r, j) => (sock.once('connect', r), sock.once('error', j)));
  sock.setNoDelay(true);
  let buf = Buffer.alloc(0);
  const c = { sock, head: null, frames: [], messages: [], waiters: [], closed: false, closeCode: null };
  const deliver = () => {
    for (let i = 0; i < c.waiters.length; i++) {
      const w = c.waiters[i];
      const idx = c.messages.findIndex(w.pred);
      if (idx >= 0) {
        c.waiters.splice(i--, 1);
        clearTimeout(w.timer);
        w.resolve(c.messages.splice(idx, 1)[0]);
      }
    }
  };
  const parse = () => {
    if (c.head === null) {
      const he = buf.indexOf('\r\n\r\n');
      if (he < 0) return;
      c.head = buf.subarray(0, he).toString('latin1');
      buf = buf.subarray(he + 4);
      c.onHead?.();
    }
    for (;;) {
      if (buf.length < 2) return;
      const b1 = buf[0], b2 = buf[1];
      let len = b2 & 0x7f, p = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2);
        p = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        len = Number(buf.readBigUInt64BE(2));
        p = 10;
      }
      if (buf.length < p + len) return;
      const payload = buf.subarray(p, p + len);
      buf = buf.subarray(p + len);
      const frame = { fin: (b1 & 0x80) !== 0, rsv: b1 & 0x70, opcode: b1 & 0x0f, masked: (b2 & 0x80) !== 0, payload };
      c.frames.push(frame);
      if (frame.opcode === 1) {
        c.messages.push(JSON.parse(payload.toString('utf8')));
        deliver();
      } else if (frame.opcode === 8) {
        c.closeCode = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
      }
    }
  };
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    parse();
  });
  sock.on('close', () => (c.closed = true));
  const head = new Promise((r) => (c.onHead = r));
  sock.write(CLAUDE_UPGRADE(fx.port, token ?? lock.authToken));
  await Promise.race([head, new Promise((r) => sock.once('close', r))]);
  c.status = c.head ? Number(c.head.split(' ')[1]) : 0;
  c.raw = (text) => sock.write(maskedFrame(1, text));
  c.wait = (pred, ms = 5000, what = 'message') =>
    new Promise((resolve, reject) => {
      const idx = c.messages.findIndex(pred);
      if (idx >= 0) return resolve(c.messages.splice(idx, 1)[0]);
      const w = { pred, resolve };
      w.timer = setTimeout(() => {
        c.waiters.splice(c.waiters.indexOf(w), 1);
        reject(new Error('timeout waiting for ' + what));
      }, ms);
      c.waiters.push(w);
    });
  c.response = (id, ms) => c.wait((m) => m.id === id && m.method === undefined, ms, 'response ' + id);
  c.note = (method, ms) => c.wait((m) => m.method === method, ms, method);
  c.pending = (method) => c.messages.filter((m) => m.method === method);
  c.closeWith = async (code = 1000) => {
    const p = Buffer.alloc(2);
    p.writeUInt16BE(code);
    sock.write(maskedFrame(8, p));
    const end = Date.now() + 3000;
    while (!c.closed && Date.now() < end) await sleep(20);
    sock.destroy();
  };
  return c;
}

/** Connect and replay Claude's connect sequence; returns the client with init/list responses. */
async function claudeSession(fx, pid = 5077) {
  const c = await rawClaude(fx);
  assert.equal(c.status, 101, c.head);
  c.raw(CLAUDE_INITIALIZE);
  c.init = await c.response(0);
  c.raw(CLAUDE_INITIALIZED);
  c.raw(CLAUDE_IDE_CONNECTED(pid));
  c.raw(CLAUDE_TOOLS_LIST);
  c.list = await c.response(1);
  return c;
}

// ---------------------------------------------------------------------------
// OpenCode client (ported from opencode/packages/tui/src/{editor.ts,context/editor.ts})
// ---------------------------------------------------------------------------

function discoverEditorConnection(root, directory) {
  const contains = (parent) => {
    const resolved = path.resolve(parent);
    const relative = path.relative(resolved, path.resolve(directory));
    return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative)) ? resolved.length : 0;
  };
  return readdirSync(root)
    .filter((entry) => entry.endsWith('.lock'))
    .flatMap((entry) => {
      const file = path.join(root, entry);
      const port = Number.parseInt(path.basename(file, '.lock'), 10);
      if (!Number.isInteger(port) || port <= 0 || port > 65535) return [];
      try {
        const value = JSON.parse(readFileSync(file, 'utf8'));
        if (value.transport !== undefined && value.transport !== 'ws') return [];
        const folders = Array.isArray(value.workspaceFolders) ? value.workspaceFolders.filter((i) => typeof i === 'string') : [];
        const score = Math.max(0, ...folders.map(contains));
        if (!score) return [];
        return [{ url: `ws://127.0.0.1:${port}`, authToken: typeof value.authToken === 'string' ? value.authToken : undefined, score, mtime: statSync(file).mtimeMs }];
      } catch {
        return [];
      }
    })
    .sort((l, r) => r.score - l.score || r.mtime - l.mtime)[0];
}

const isPos = (p) => p && typeof p.line === 'number' && typeof p.character === 'number';
/** OpenCode's EditorSelectionSchema (Claude-style shape and ranges shape); undefined = dropped. */
function decodeSelection(p) {
  if (!p || typeof p !== 'object' || typeof p.filePath !== 'string') return undefined;
  if (p.source !== undefined && p.source !== 'websocket' && p.source !== 'zed') return undefined;
  if (Array.isArray(p.ranges) && p.ranges.length > 0) return p;
  if (typeof p.text !== 'string' || !p.selection || !isPos(p.selection.start) || !isPos(p.selection.end)) return undefined;
  return { filePath: p.filePath, ranges: [{ text: p.text, selection: p.selection }] };
}
/** OpenCode's EditorMentionSchema: both lines required. */
function decodeMention(p) {
  if (!p || typeof p.filePath !== 'string' || typeof p.lineStart !== 'number' || typeof p.lineEnd !== 'number') return undefined;
  return p;
}

async function opencodeClient(root, directory) {
  const conn = discoverEditorConnection(root, directory);
  if (!conn) return null;
  const socket = conn.authToken
    ? new WebSocket(conn.url, { headers: { 'x-claude-code-ide-authorization': conn.authToken } })
    : new WebSocket(conn.url);
  const c = { socket, selections: [], mentions: [], dropped: [], server: undefined, conn };
  let requestID = 0;
  const pending = new Map();
  const send = (payload) => socket.readyState === 1 && socket.send(JSON.stringify({ jsonrpc: '2.0', ...payload }));
  socket.on('message', (data, isBinary) => {
    if (isBinary) return;
    const message = JSON.parse(data.toString('utf8'));
    if (message.method === 'selection_changed') {
      const s = decodeSelection(message.params);
      if (s) return c.selections.push({ ...s, source: 'websocket' });
    }
    if (message.method === 'at_mentioned') {
      const m = decodeMention(message.params);
      if (m) return c.mentions.push(m);
    }
    if (message.method) return c.dropped.push(message);
    if (typeof message.id !== 'number') return;
    const method = pending.get(message.id);
    if (!method) return;
    pending.delete(message.id);
    if (message.error) return;
    if (method === 'initialize') {
      c.server = message.result;
      send({ method: 'notifications/initialized' });
    }
  });
  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  });
  requestID += 1;
  pending.set(requestID, 'initialize');
  send({ id: requestID, method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'opencode', version: '0.0.0' } } });
  c.close = () => new Promise((r) => (socket.readyState === 3 ? r() : (socket.once('close', r), socket.close())));
  return c;
}

async function until(fn, ms = 3000, what = 'condition') {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timeout waiting for ' + what);
    await sleep(20);
  }
}

// ---------------------------------------------------------------------------

describe('Claude Code 2.1.283 replay', () => {
  let fx;
  before(async () => {
    fx = await startFixture();
  });
  after(async () => {
    const left = await fx.stop();
    assert.deepEqual(left, [], 'lock removed on exit');
  });

  test('lock file as Claude reads it', () => {
    const lock = claudeLock(fx);
    assert.equal(lock.ideName, 'Neovim');
    assert.equal(lock.transport, 'ws');
    assert.match(lock.authToken, /^[0-9a-f]{32}$/);
    assert.equal(typeof lock.pid, 'number');
    assert.ok(lock.workspaceFolders.includes(fx.workspace));
    assert.equal(statSync(path.join(fx.lockDir, `${fx.port}.lock`)).mode & 0o777, 0o600);
    assert.equal(statSync(fx.lockDir).mode & 0o777, 0o700);
  });

  test('upgrade: 101 with the mcp subprotocol, correct accept key, no extensions', async () => {
    const c = await rawClaude(fx);
    const lines = c.head.split('\r\n');
    assert.equal(lines[0], 'HTTP/1.1 101 Switching Protocols');
    const h = Object.fromEntries(lines.slice(1).map((l) => [l.slice(0, l.indexOf(':')).toLowerCase(), l.slice(l.indexOf(':') + 1).trim()]));
    assert.equal(h['upgrade'].toLowerCase(), 'websocket');
    assert.equal(h['connection'].toLowerCase(), 'upgrade');
    assert.equal(h['sec-websocket-accept'], crypto.createHash('sha1').update('RN20ewn815D8uHEla2DB/w==' + GUID).digest('base64'));
    assert.equal(h['sec-websocket-protocol'], 'mcp');
    assert.equal(h['sec-websocket-extensions'], undefined);
    await c.closeWith(1000);
    assert.equal(c.closeCode, 1000, 'server echoes the close code');
  });

  test('a wrong token gets 401 before switching protocols', async () => {
    const c = await rawClaude(fx, { token: 'ffffffffffffffffffffffffffffffff' });
    assert.equal(c.status, 401);
    c.sock.destroy();
  });

  test('connect sequence, tools, selection after the delay, and an Edit round-trip', async () => {
    await fx.lua(`P.on_selection({ path = ${luaStr(fx.workspace + '/b.txt')}, bufnr = 1, text = 'two\\nthree',
      start = { line = 1, character = 0 }, finish = { line = 2, character = 5 }, is_empty = false, mode = 'v' })`);
    const c = await claudeSession(fx, 4242);
    // initialize (§4.3)
    assert.deepEqual(c.init, {
      jsonrpc: '2.0',
      id: 0,
      result: { protocolVersion: '2025-11-25', capabilities: { tools: { listChanged: true } }, serverInfo: { name: 'agent-nvim', version: '0.1.0' } },
    });
    // tools/list (§5)
    const tools = Object.fromEntries(c.list.result.tools.map((t) => [t.name, t]));
    for (const name of ['openDiff', 'getDiagnostics', 'closeAllDiffTabs', 'openFile', 'getCurrentSelection', 'getLatestSelection', 'getOpenEditors', 'getWorkspaceFolders', 'checkDocumentDirty', 'saveDocument']) {
      assert.ok(tools[name], name);
      assert.equal(tools[name].inputSchema.type, 'object');
    }
    assert.equal(tools.close_tab, undefined, 'close_tab is callable but not listed');
    assert.equal(tools.executeCode, undefined);
    assert.deepEqual(tools.openDiff.inputSchema.required, ['old_file_path', 'new_file_path', 'new_file_contents', 'tab_name']);
    assert.deepEqual(Object.keys(tools.getDiagnostics.inputSchema.properties), ['uri']);
    // Every server frame so far: FIN, no RSV, unmasked text.
    for (const f of c.frames) {
      assert.equal(f.fin, true);
      assert.equal(f.rsv, 0);
      assert.equal(f.masked, false);
      assert.equal(f.opcode, 1);
    }
    // selection_changed is held back ~600 ms after the connection completes (§6.3).
    await sleep(300);
    assert.equal(c.pending('selection_changed').length, 0, 'no early notification');
    const sel = await c.note('selection_changed', 3000);
    assert.deepEqual(sel.params, {
      text: 'two\nthree',
      filePath: fx.workspace + '/b.txt',
      fileUrl: 'file://' + fx.workspace + '/b.txt',
      selection: { start: { line: 1, character: 0 }, end: { line: 2, character: 5 }, isEmpty: false },
    });
    const clients = await fx.lua('return P.clients()');
    assert.equal(clients[0].pid, 4242);
    assert.equal(clients[0].name, 'claude-code');

    // at_mentioned (0-based; Claude adds 1 and shows @b.txt#L2-3)
    assert.equal(await fx.lua(`return P.at_mention(${luaStr(fx.workspace + '/b.txt')}, 2, 3)`), true);
    assert.deepEqual((await c.note('at_mentioned')).params, { filePath: fx.workspace + '/b.txt', lineStart: 1, lineEnd: 2 });

    // Turn start: closeAllDiffTabs {} (errors ignored by Claude).
    c.raw(CLAUDE_TOOL_CALL(2, 'closeAllDiffTabs', {}));
    assert.deepEqual((await c.response(2)).result, { content: [{ type: 'text', text: 'CLOSED_0_DIFF_TABS' }] });

    // Before the Edit: diagnostics baseline {uri: `file://${path}`}, 500 ms budget.
    const target = fx.workspace + '/a.txt';
    const t0 = Date.now();
    c.raw(CLAUDE_TOOL_CALL(3, 'getDiagnostics', { uri: `file://${target}` }));
    const diag = await c.response(3);
    assert.ok(Date.now() - t0 < 500, 'getDiagnostics answered within Claude\'s 500 ms');
    assert.deepEqual(JSON.parse(diag.result.content[0].text), [{ uri: `file://${target}`, diagnostics: [] }]);

    // openDiff blocks until the user decides.
    const tab = '✻ [Claude Code] a.txt (3f9a1c) ⧉';
    c.raw(CLAUDE_TOOL_CALL(4, 'openDiff', { old_file_path: target, new_file_path: target, new_file_contents: 'hello\nneovim\n', tab_name: tab }));
    await until(() => fx.lua(`return diff.is_open(${luaStr(tab)})`), 3000, 'diff open');
    await sleep(200);
    assert.equal(c.messages.find((m) => m.id === 4), undefined, 'still pending');
    await fx.lua(`local b = diff.get(${luaStr(tab)}).bufnr
      vim.api.nvim_buf_set_lines(b, 1, 2, false, { 'neovim, edited' })
      vim.api.nvim_buf_call(b, function() vim.cmd('write') end)`);
    const saved = await c.response(4);
    assert.deepEqual(saved.result, { content: [{ type: 'text', text: 'FILE_SAVED' }, { type: 'text', text: 'hello\nneovim, edited\n' }] });
    assert.equal(readFileSync(target, 'utf8'), 'hello\nworld\n', 'Neovim never writes the target');
    // close_tab twice, both TAB_CLOSED.
    c.raw(CLAUDE_TOOL_CALL(5, 'close_tab', { tab_name: tab }));
    c.raw(CLAUDE_TOOL_CALL(6, 'close_tab', { tab_name: tab }));
    assert.equal((await c.response(5)).result.content[0].text, 'TAB_CLOSED');
    assert.equal((await c.response(6)).result.content[0].text, 'TAB_CLOSED');

    // A rejected edit: DIFF_REJECTED + tab name.
    const tab2 = '✻ [Claude Code] a.txt (77aa00) ⧉';
    c.raw(CLAUDE_TOOL_CALL(7, 'openDiff', { old_file_path: target, new_file_path: target, new_file_contents: 'nope\n', tab_name: tab2 }));
    await until(() => fx.lua(`return diff.is_open(${luaStr(tab2)})`), 3000, 'diff 2 open');
    await fx.lua(`diff.reject(${luaStr(tab2)})`);
    assert.deepEqual((await c.response(7)).result, { content: [{ type: 'text', text: 'DIFF_REJECTED' }, { type: 'text', text: tab2 }] });

    // Answered in the terminal: Claude aborts and calls close_tab while the diff is pending.
    const tab3 = '✻ [Claude Code] a.txt (bb11cc) ⧉';
    c.raw(CLAUDE_TOOL_CALL(8, 'openDiff', { old_file_path: target, new_file_path: target, new_file_contents: 'x\n', tab_name: tab3 }));
    await until(() => fx.lua(`return diff.is_open(${luaStr(tab3)})`), 3000, 'diff 3 open');
    c.raw(CLAUDE_TOOL_CALL(9, 'close_tab', { tab_name: tab3 }));
    assert.equal((await c.response(8)).result.content[0].text, 'DIFF_REJECTED');
    assert.equal((await c.response(9)).result.content[0].text, 'TAB_CLOSED');
    assert.equal(await fx.lua(`return diff.is_open(${luaStr(tab3)})`), false);

    // Later turns: getDiagnostics {} over all files with diagnostics.
    await fx.lua(`vim.cmd.edit(${luaStr(target)})
      local ns = vim.api.nvim_create_namespace('t')
      vim.diagnostic.set(ns, 0, { { lnum = 1, col = 0, end_col = 5, severity = 1, message = 'bad', source = 'x', code = 7 } })`);
    c.raw(CLAUDE_TOOL_CALL(10, 'getDiagnostics', {}));
    assert.deepEqual(JSON.parse((await c.response(10)).result.content[0].text), [
      { uri: `file://${target}`, diagnostics: [{ message: 'bad', severity: 'Error', source: 'x', code: '7', range: { start: { line: 1, character: 0 }, end: { line: 1, character: 5 } } }] },
    ]);

    // Claude closes with 1000 on exit; the server echoes it.
    await c.closeWith(1000);
    assert.equal(c.closeCode, 1000);
    await until(async () => (await fx.lua('return P.status().clients')) === 0, 3000, 'session closed');
  });

  test('reconnect after a server restart: same port, same token, ids restart at 0', async () => {
    const c = await claudeSession(fx);
    const before = claudeLock(fx);
    await fx.lua('P.stop()');
    await until(() => c.closed || c.closeCode !== null, 3000, 'close');
    assert.equal(c.closeCode, 1001);
    c.sock.destroy();
    await fx.lua('assert(P.start())');
    const after = claudeLock(fx);
    assert.equal(after.authToken, before.authToken);
    const c2 = await claudeSession(fx);
    assert.equal(c2.init.result.protocolVersion, '2025-11-25');
    await c2.closeWith(1000);
  });

  test('the ws library as a Bun-like client (protocols [mcp] + header)', async () => {
    const lock = claudeLock(fx);
    const sock = new WebSocket(`ws://127.0.0.1:${fx.port}`, ['mcp'], {
      headers: { 'User-Agent': 'claude-code/2.1.283 (cli)', 'X-Claude-Code-Ide-Authorization': lock.authToken },
      perMessageDeflate: true,
    });
    await new Promise((r, j) => (sock.once('open', r), sock.once('error', j)));
    assert.equal(sock.protocol, 'mcp');
    assert.equal(sock.extensions, '');
    const got = new Promise((r) => sock.once('message', (d) => r(JSON.parse(d.toString()))));
    sock.send(CLAUDE_INITIALIZE);
    const init = await got;
    assert.equal(init.id, 0);
    assert.equal(init.result.serverInfo.name, 'agent-nvim');
    await new Promise((r) => (sock.once('close', r), sock.close(1000)));
  });

  test('a selection with invalid UTF-8 reaches a strict client as U+FFFD, and the connection survives', async () => {
    // Latin-1 text (e.g. from a `++bin` buffer) is the selection sent when the client becomes ready.
    await fx.lua(`require('agent.editor.selection')._reset()
      vim.cmd('enew')
      P._state.last_selection = { path = ${luaStr(fx.workspace + '/b.txt')}, bufnr = 1, text = 'caf\\233 cr\\232me',
        start = { line = 0, character = 0 }, finish = { line = 0, character = 10 }, is_empty = false, mode = 'v' }`);
    const lock = claudeLock(fx);
    // The ws library validates text frames like a WHATWG client (Bun's): invalid UTF-8 fails the connection.
    const sock = new WebSocket(`ws://127.0.0.1:${fx.port}`, ['mcp'], {
      headers: { 'X-Claude-Code-Ide-Authorization': lock.authToken },
    });
    const messages = [];
    let error = null;
    let closed = null;
    sock.on('message', (d) => messages.push(JSON.parse(d.toString())));
    sock.on('error', (e) => (error = e));
    sock.on('close', (code) => (closed = code));
    await new Promise((r, j) => (sock.once('open', r), sock.once('error', j)));
    for (const m of [CLAUDE_INITIALIZE, CLAUDE_INITIALIZED, CLAUDE_IDE_CONNECTED(4343), CLAUDE_TOOLS_LIST]) sock.send(m);
    await until(() => messages.find((m) => m.method === 'selection_changed') || error || closed !== null, 5000, 'selection_changed');
    assert.equal(error, null, 'no client error');
    assert.equal(closed, null, 'still connected');
    assert.equal(messages.find((m) => m.method === 'selection_changed').params.text, 'caf� cr�me');
    await fx.lua('P._state.last_selection = nil');
    await new Promise((r) => (sock.once('close', r), sock.close(1000)));
  });
});

describe('OpenCode client', () => {
  let fx;
  before(async () => {
    fx = await startFixture();
  });
  after(async () => {
    const left = await fx.stop();
    assert.deepEqual(left, []);
  });

  test('discovers the lock by workspace folder, authenticates, gets 1-based notifications', async () => {
    await fx.lua(`P.on_selection({ path = ${luaStr(fx.workspace + '/b.txt')}, bufnr = 1, text = 'two',
      start = { line = 1, character = 0 }, finish = { line = 1, character = 3 }, is_empty = false, mode = 'v' })`);
    // OpenCode runs in the workspace (or below it) and has no port variable set.
    const sub = path.join(fx.workspace, 'sub');
    mkdirSync(sub, { recursive: true });
    const c = await opencodeClient(fx.lockDir, sub);
    assert.ok(c, 'lock discovered');
    assert.equal(c.conn.url, `ws://127.0.0.1:${fx.port}`);
    assert.equal(c.socket.protocol, '', 'no subprotocol');
    await until(() => c.server, 3000, 'initialize result');
    assert.equal(c.server.protocolVersion, '2025-11-25');
    assert.equal(c.server.serverInfo.name, 'agent-nvim');
    // Right after initialize (no Claude delay), with +1 on lines and characters.
    await until(() => c.selections.length, 400, 'selection');
    // (extra keys such as isEmpty/fileUrl are ignored by OpenCode's schema)
    const r0 = c.selections[0].ranges[0];
    assert.equal(r0.text, 'two');
    assert.deepEqual([r0.selection.start, r0.selection.end], [{ line: 2, character: 1 }, { line: 2, character: 4 }]);
    assert.equal(c.selections[0].filePath, fx.workspace + '/b.txt');
    const clients = await fx.lua('return P.clients()');
    assert.equal(clients[0].kind, 'opencode');

    assert.equal(await fx.lua(`return P.at_mention(${luaStr(fx.workspace + '/b.txt')}, 2, 3)`), true);
    await until(() => c.mentions.length === 1, 2000, 'mention');
    assert.deepEqual(c.mentions[0], { filePath: fx.workspace + '/b.txt', lineStart: 2, lineEnd: 3 });
    // Whole file -> 1..N (OpenCode requires both lines).
    assert.equal(await fx.lua(`return P.at_mention(${luaStr(fx.workspace + '/b.txt')})`), true);
    await until(() => c.mentions.length === 2, 2000, 'mention 2');
    assert.deepEqual(c.mentions[1], { filePath: fx.workspace + '/b.txt', lineStart: 1, lineEnd: 3 });
    // Directories are not sent to OpenCode.
    assert.equal(await fx.lua(`return P.at_mention(${luaStr(fx.workspace)})`), false);
    await sleep(200);
    assert.equal(c.mentions.length, 2);
    assert.deepEqual(c.dropped, [], 'every notification decoded under OpenCode\'s schemas');
    await c.close();
  });

  test('prefers the newest lock after before_spawn() touches it', async () => {
    // A second, older lock for the same folder (another Neovim) must lose the mtime tie-break.
    const other = path.join(fx.lockDir, '10001.lock');
    writeFileSync(other, JSON.stringify({ pid: process.pid, workspaceFolders: [fx.workspace], ideName: 'Neovim', transport: 'ws', authToken: 'x'.repeat(32) }));
    await sleep(30);
    await fx.lua(`P.before_spawn({ cwd = ${luaStr(fx.workspace)} })`);
    const conn = discoverEditorConnection(fx.lockDir, fx.workspace);
    rmSync(other);
    assert.equal(conn.url, `ws://127.0.0.1:${fx.port}`);
  });

  test('a token-less connection (the env-port path) is refused', async () => {
    const sock = new WebSocket(`ws://127.0.0.1:${fx.port}`);
    const err = await new Promise((r) => sock.once('error', r));
    assert.match(String(err.message), /401/);
  });
});
