// Protocol tests for lua/agent/providers/copilot.lua, served by a headless Neovim
// (tests/node/fixtures/copilot_provider.lua). The client replays what GitHub Copilot CLI 1.0.88
// sends (specs/copilot.md, captured in work-copilot-spec/exp1..exp12): Node http over the lock's
// Unix socket, keep-alive, chunked POST bodies, the exact headers and payloads, the discover probe,
// the DELETE + re-initialize cycles, the GET notification stream, open_diff/close_diff.
// Run: cd tests/node && node --test provider_copilot.test.mjs
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync, readFileSync, realpathSync, writeFileSync, statSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { Agent, fetch as ufetch } from 'undici';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'copilot_provider.lua');
const NVIM = process.env.NVIM_BIN || 'nvim';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, ms = 3000, what = 'condition') {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timeout waiting for ' + what);
    await sleep(25);
  }
}

async function startFixture() {
  const dir = mkdtempSync(path.join(tmpdir(), 'acpn-'));
  const env = { ...process.env, XDG_STATE_HOME: path.join(dir, 'state') };
  delete env.NVIM;
  delete env.COPILOT_HOME;
  const proc = spawn(NVIM, ['--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', FIXTURE, ROOT, dir], {
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  proc.stderr.on('data', (d) => (stderr += d));
  const lines = [];
  const waiters = [];
  let buf = '';
  proc.stdout.on('data', (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (waiters.length) waiters.shift()(line);
      else lines.push(line);
    }
  });
  const nextLine = (ms = 10000) =>
    new Promise((resolve, reject) => {
      if (lines.length) return resolve(lines.shift());
      const t = setTimeout(() => reject(new Error('timeout waiting for fixture output; stderr: ' + stderr)), ms);
      waiters.push((l) => {
        clearTimeout(t);
        resolve(l);
      });
    });
  const exited = new Promise((r) => proc.on('exit', r));
  const info = JSON.parse(await nextLine());
  return {
    ...info,
    dir,
    proc,
    stderr: () => stderr,
    async cmd(word, arg) {
      const a = arg === undefined ? '' : ' ' + (typeof arg === 'string' ? arg : JSON.stringify(arg));
      proc.stdin.write(word + a + '\n');
      return JSON.parse(await nextLine());
    },
    async stop() {
      if (proc.exitCode === null) {
        proc.stdin.write('quit\n');
        proc.stdin.end();
        const t = setTimeout(() => proc.kill('SIGKILL'), 5000);
        await exited;
        clearTimeout(t);
      }
      rmSync(dir, { recursive: true, force: true });
      if (stderr.trim()) console.error('[fixture stderr]', stderr.trim());
    },
  };
}

function parseSse(text) {
  const events = [];
  const comments = [];
  for (const block of text.split(/\r?\n\r?\n/)) {
    if (!block.trim()) continue;
    let event, data = [];
    for (const line of block.split(/\r?\n/)) {
      if (line.startsWith(':')) comments.push(line.slice(1).trim());
      else if (line.startsWith('event:')) event = line.slice(6).trim();
      else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
    }
    if (data.length) events.push({ event, data: JSON.parse(data.join('\n')) });
  }
  return { events, comments };
}

/**
 * A client that behaves like Copilot CLI 1.0.88's IDE transport: Node http.request over the lock's
 * socketPath with the default keep-alive agent, lock headers + X-Copilot-* headers on every request,
 * chunked POST bodies, Mcp-Session-Id echoed after the first response that carried one.
 */
class FakeCli {
  constructor(lock, { sessionId = crypto.randomUUID(), pid = 4719, ppid = 4718, authorization } = {}) {
    this.lock = lock;
    this.copilotSessionId = sessionId;
    this.pid = pid;
    this.ppid = ppid;
    this.authorization = authorization ?? lock.headers.Authorization;
    this.mcpSessionId = undefined;
    this.agent = new http.Agent({ keepAlive: true });
    this.nextId = 0;
    this.sockets = new Set();
  }

  baseHeaders() {
    return {
      'x-copilot-session-id': this.copilotSessionId,
      'x-copilot-pid': String(this.pid),
      'x-copilot-parent-pid': String(this.ppid),
      authorization: this.authorization,
    };
  }

  raw({ method, headers, body, pathName = '/mcp', agent = this.agent }) {
    return new Promise((resolve, reject) => {
      const req = http.request({ socketPath: this.lock.socketPath, path: pathName, method, headers, agent }, (res) => {
        this.sockets.add(res.socket);
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data, socket: res.socket }));
      });
      req.on('error', reject);
      if (body !== undefined) req.write(body); // no Content-Length: Node sends it chunked, like the CLI
      req.end();
    });
  }

  async post(msg, { withSession = true } = {}) {
    const headers = {
      ...this.baseHeaders(),
      accept: 'application/json, text/event-stream',
      'content-type': 'application/json',
      host: 'localhost',
      connection: 'keep-alive',
      'transfer-encoding': 'chunked',
    };
    if (withSession && this.mcpSessionId) headers['mcp-session-id'] = this.mcpSessionId;
    const r = await this.raw({ method: 'POST', headers, body: JSON.stringify(msg) });
    const sid = r.headers['mcp-session-id'];
    if (sid) this.mcpSessionId = sid;
    const ct = r.headers['content-type'] || '';
    if (ct.includes('application/json')) r.json = JSON.parse(r.body);
    else if (ct.includes('text/event-stream')) {
      r.sse = parseSse(r.body);
      r.json = r.sse.events.length ? r.sse.events[r.sse.events.length - 1].data : undefined;
    }
    return r;
  }

  request(method, params) {
    const id = this.nextId++;
    const msg = { jsonrpc: '2.0', id, method };
    if (params !== undefined) msg.params = params;
    return this.post(msg);
  }

  notify(method) {
    return this.post({ jsonrpc: '2.0', method });
  }

  callTool(name, args, progressToken = 0) {
    return this.request('tools/call', { _meta: { progressToken }, name, arguments: args });
  }

  /** server/discover exactly as 1.0.88 sends it (id 0, no mcp-session-id). */
  discover() {
    this.nextId = 0;
    return this.post(
      {
        jsonrpc: '2.0',
        id: this.nextId++,
        method: 'server/discover',
        params: {
          _meta: {
            'io.modelcontextprotocol/protocolVersion': '2026-07-28',
            'io.modelcontextprotocol/clientInfo': { name: 'copilot-cli', version: '1.0.88' },
            'io.modelcontextprotocol/clientCapabilities': {},
          },
        },
      },
      { withSession: false },
    );
  }

  initialize() {
    this.mcpSessionId = undefined;
    return this.request('initialize', {
      protocolVersion: '2025-11-25',
      capabilities: {},
      clientInfo: { name: 'copilot-cli', version: '1.0.88' },
    });
  }

  /** Open the GET notification stream; events are queued for nextEvent(). */
  openStream() {
    const stream = { events: [], waiters: [], ended: false, status: undefined, headers: undefined };
    return new Promise((resolve, reject) => {
      const headers = {
        ...this.baseHeaders(),
        accept: 'text/event-stream',
        'mcp-session-id': this.mcpSessionId,
        host: 'localhost',
        connection: 'keep-alive',
      };
      const req = http.request({ socketPath: this.lock.socketPath, path: '/mcp', method: 'GET', headers, agent: this.agent }, (res) => {
        stream.status = res.statusCode;
        stream.headers = res.headers;
        stream.res = res;
        let buf = '';
        res.setEncoding('utf8');
        const flush = () => {
          if (stream.waiters.length && stream.events.length) stream.waiters.shift()(stream.events.shift());
        };
        res.on('data', (c) => {
          buf += c;
          let i;
          while ((i = buf.search(/\r?\n\r?\n/)) >= 0) {
            const block = buf.slice(0, i);
            buf = buf.slice(i).replace(/^\r?\n\r?\n/, '');
            const parsed = parseSse(block + '\n\n');
            for (const e of parsed.events) stream.events.push(e);
            flush();
          }
        });
        res.on('end', () => {
          stream.ended = true;
          for (const w of stream.waiters.splice(0)) w(null);
        });
        res.on('error', () => {});
        resolve(stream);
      });
      stream.req = req;
      req.on('error', (e) => (stream.status === undefined ? reject(e) : null));
      req.end();
    });
  }

  nextEvent(stream, ms = 3000) {
    if (stream.events.length) return Promise.resolve(stream.events.shift());
    if (stream.ended) return Promise.resolve(null);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('timeout waiting for an SSE event')), ms);
      stream.waiters.push((e) => {
        clearTimeout(t);
        resolve(e);
      });
    });
  }

  delete() {
    const headers = { ...this.baseHeaders(), 'mcp-session-id': this.mcpSessionId, host: 'localhost', connection: 'keep-alive' };
    return this.raw({ method: 'DELETE', headers });
  }

  /** The startup handshake: discover -> initialize -> initialized -> GET + tools/list. */
  async connect() {
    const d = await this.discover();
    assert.equal(d.status, 200);
    const init = await this.initialize();
    assert.equal(init.status, 200);
    const ready = await this.notify('notifications/initialized');
    assert.equal(ready.status, 202);
    const [stream, tools] = await Promise.all([this.openStream(), this.request('tools/list', { _meta: { progressToken: 0 } })]);
    return { d, init, ready, stream, tools };
  }

  close() {
    this.agent.destroy();
  }
}

const readLock = (p) => JSON.parse(readFileSync(p, 'utf8'));
const toolText = (r) => {
  assert.ok(r.json?.result, 'expected a result, got ' + JSON.stringify(r.json));
  const c = r.json.result.content;
  assert.equal(c.length, 1);
  assert.equal(c[0].type, 'text');
  return JSON.parse(c[0].text);
};

describe('copilot provider (replaying Copilot CLI 1.0.88)', () => {
  let fx;
  let lock;

  before(async () => {
    fx = await startFixture();
    lock = readLock(fx.lock);
  });

  after(async () => {
    await fx?.stop();
  });

  test('lock file: the schema the CLI validates (zod zqn), 0600, one per folder', () => {
    assert.deepEqual(Object.keys(lock).sort(), ['headers', 'ideName', 'isTrusted', 'pid', 'scheme', 'socketPath', 'timestamp', 'workspaceFolders']);
    assert.equal(typeof lock.socketPath, 'string');
    assert.equal(lock.scheme, 'unix');
    assert.deepEqual(Object.keys(lock.headers), ['Authorization']);
    assert.match(lock.headers.Authorization, /^Nonce [0-9a-f]{64}$/);
    assert.equal(lock.pid, fx.proc.pid);
    assert.ok(Math.abs(lock.timestamp - Date.now()) < 60000);
    assert.deepEqual(lock.workspaceFolders, [realpathSync(fx.ws)]);
    assert.equal(lock.ideName, 'Neovim');
    assert.equal(lock.isTrusted, false);
    assert.equal(statSync(fx.lock).mode & 0o777, 0o600);
    assert.ok(statSync(lock.socketPath).isSocket());
    assert.equal(statSync(path.dirname(lock.socketPath)).mode & 0o777, 0o700);
    assert.ok(Buffer.byteLength(lock.socketPath) <= 103);
    assert.ok(path.basename(fx.lock).endsWith('.lock'));
    assert.deepEqual(readdirSync(fx.ide_dir).filter((f) => f.endsWith('.lock')), [path.basename(fx.lock)]);
  });

  test('probe connections that send nothing are tolerated', async () => {
    for (let i = 0; i < 3; i++) {
      await new Promise((resolve, reject) => {
        const s = net.connect({ path: lock.socketPath }, () => {
          s.destroy();
          resolve();
        });
        s.on('error', reject);
      });
    }
    const cli = new FakeCli(lock);
    const d = await cli.discover();
    assert.equal(d.status, 200);
    cli.close();
  });

  test('startup: discover -> -32601 at once, initialize, initialized 202, GET + tools/list, DELETE, re-initialize', async () => {
    writeFileSync(path.join(fx.ws, 'a.txt'), 'hello world\nsecond line\n');
    await fx.cmd('select', { path: path.join(fx.ws, 'a.txt'), start: [0, 0], end: [0, 5] });

    const cli = new FakeCli(lock);
    // 1. server/discover: HTTP 200 + JSON-RPC -32601, JSON, no Mcp-Session-Id (copilot.md §4.2).
    const t0 = Date.now();
    const d = await cli.discover();
    assert.ok(Date.now() - t0 < 2000);
    assert.equal(d.status, 200);
    assert.match(d.headers['content-type'], /application\/json/);
    assert.equal(d.headers['mcp-session-id'], undefined);
    assert.deepEqual(d.json, { jsonrpc: '2.0', id: 0, error: { code: -32601, message: 'Method not found' } });

    // 2. initialize on the same keep-alive connection.
    const init = await cli.initialize();
    assert.equal(init.status, 200);
    assert.match(init.headers['content-type'], /application\/json/);
    const sid1 = init.headers['mcp-session-id'];
    assert.match(sid1, /^[0-9a-f-]{36}$/);
    assert.equal(init.socket, d.socket, 'keep-alive connection reused');
    assert.equal(init.json.id, 1);
    assert.equal(init.json.result.protocolVersion, '2025-11-25');
    assert.deepEqual(init.json.result.serverInfo, { name: 'agent-nvim-copilot-cli', title: 'Neovim Copilot CLI', version: '0.0.1' });
    assert.deepEqual(init.json.result.capabilities, { tools: { listChanged: true } });

    // 3. notifications/initialized -> 202 with an empty body (the CLI opens its GET only after a 202).
    const ready = await cli.notify('notifications/initialized');
    assert.equal(ready.status, 202);
    assert.equal(ready.body, '');
    assert.equal(ready.headers['mcp-session-id'], sid1);

    // 4. GET stream and tools/list together.
    const [stream, tools] = await Promise.all([cli.openStream(), cli.request('tools/list', { _meta: { progressToken: 0 } })]);
    assert.equal(stream.status, 200);
    assert.match(stream.headers['content-type'], /text\/event-stream/);
    assert.equal(stream.headers['mcp-session-id'], sid1);
    assert.deepEqual(
      tools.json.result.tools.map((t) => t.name),
      ['get_vscode_info', 'get_selection', 'open_diff', 'close_diff', 'get_diagnostics', 'update_session_name'],
    );
    const openDiff = tools.json.result.tools.find((t) => t.name === 'open_diff');
    assert.deepEqual(openDiff.inputSchema.required, ['original_file_path', 'new_file_contents', 'tab_name']);
    assert.equal(openDiff.inputSchema.additionalProperties, false);
    const getSel = tools.json.result.tools.find((t) => t.name === 'get_selection');
    assert.deepEqual(getSel.inputSchema, { type: 'object', properties: {} });

    // 5. The current selection is replayed as soon as the stream opens.
    const replay = await cli.nextEvent(stream);
    assert.equal(replay.event, 'message');
    assert.deepEqual(replay.data, {
      jsonrpc: '2.0',
      method: 'selection_changed',
      params: {
        text: 'hello',
        filePath: path.join(fx.ws, 'a.txt'),
        fileUrl: 'file://' + path.join(fx.ws, 'a.txt'),
        selection: { start: { line: 0, character: 0 }, end: { line: 0, character: 5 }, isEmpty: false },
      },
    });

    // 6. DELETE (the CLI does this when its MCP host settles) ends the stream; then the same CLI
    //    session re-initializes with the same X-Copilot-Session-Id.
    const del = await cli.delete();
    assert.equal(del.status, 200);
    await waitFor(() => stream.ended, 2000, 'GET stream end');
    const again = await cli.connect();
    const sid2 = again.init.headers['mcp-session-id'];
    assert.ok(sid2 && sid2 !== sid1);
    assert.equal(again.d.headers['mcp-session-id'], undefined);
    assert.equal(again.tools.json.result.tools.length, 6);
    assert.equal((await cli.nextEvent(again.stream)).data.method, 'selection_changed');
    const stats = await fx.cmd('stats');
    assert.equal(stats.clients, 1);
    assert.equal(stats.sessions[0].id, sid2);
    assert.equal(stats.sessions[0].copilot_session_id, cli.copilotSessionId);
    assert.equal(stats.sessions[0].pid, 4719);
    assert.equal(stats.sessions[0].streaming, true);

    // Every POST so far was chunked (Node sets Transfer-Encoding: chunked when no length is given).
    await cli.delete();
    await waitFor(() => again.stream.ended, 2000);
    cli.close();
    await waitFor(async () => (await fx.cmd('stats')).clients === 0, 2000);
  });

  describe('connected session', () => {
    let cli, stream;
    const ws = () => fx.ws;

    before(async () => {
      cli = new FakeCli(lock, { pid: 5001, ppid: 5000 });
      const c = await cli.connect();
      stream = c.stream;
      // Drain the selection replay (if any).
      await sleep(100);
      stream.events.length = 0;
    });

    after(async () => {
      await cli.delete().catch(() => {});
      cli.close();
    });

    test('selection_changed is pushed on the GET stream', async () => {
      writeFileSync(path.join(ws(), 'u.txt'), 'añb😀c\n');
      await fx.cmd('select', { path: path.join(ws(), 'u.txt'), start: [0, 1], end: [0, 8] });
      const e = await cli.nextEvent(stream);
      assert.equal(e.event, 'message');
      assert.equal(e.data.method, 'selection_changed');
      assert.deepEqual(e.data.params, {
        text: 'ñb😀',
        filePath: path.join(ws(), 'u.txt'),
        fileUrl: 'file://' + path.join(ws(), 'u.txt'),
        // UTF-16 characters: 'a'=1, 'ñ'=1, 'b'=1, '😀'=2
        selection: { start: { line: 0, character: 1 }, end: { line: 0, character: 5 }, isEmpty: false },
      });
      assert.equal('current' in e.data.params, false);
    });

    test('add_file_reference: whole file (null selection and selectedText) and a line range', async () => {
      writeFileSync(path.join(ws(), 'r.txt'), 'l1\nl2\nl3\nl4\nl5\n');
      assert.deepEqual(await fx.cmd('mention', { path: path.join(ws(), 'r.txt') }), { sent: true });
      const whole = await cli.nextEvent(stream);
      assert.deepEqual(whole.data, {
        jsonrpc: '2.0',
        method: 'add_file_reference',
        params: { filePath: path.join(ws(), 'r.txt'), fileUrl: 'file://' + path.join(ws(), 'r.txt'), selection: null, selectedText: null },
      });
      assert.deepEqual(await fx.cmd('mention', { path: path.join(ws(), 'r.txt'), start: 3, end: 5, pid: 5000 }), { sent: true });
      const range = await cli.nextEvent(stream);
      assert.deepEqual(range.data.params, {
        filePath: path.join(ws(), 'r.txt'),
        fileUrl: 'file://' + path.join(ws(), 'r.txt'),
        selection: { start: { line: 2, character: 0 }, end: { line: 4, character: 2 } },
        selectedText: 'l3\nl4\nl5',
      });
      assert.deepEqual(await fx.cmd('mention', { path: path.join(ws(), 'r.txt'), pid: 1 }), { sent: false });
    });

    test('update_session_name (as sent after the first prompt)', async () => {
      const r = await cli.callTool('update_session_name', { name: '@a.txt:3-5 PLEASE_EDIT now' }, 1);
      assert.equal(r.status, 200);
      assert.match(r.headers['content-type'], /application\/json/);
      assert.deepEqual(toolText(r), { success: true });
      const stats = await fx.cmd('stats');
      assert.equal(stats.sessions.find((s) => s.id === cli.mcpSessionId).name, '@a.txt:3-5 PLEASE_EDIT now');
    });

    test('open_diff (create) held open until the user accepts -> SAVED; the CLI writes the file', async () => {
      const file = path.join(ws(), 'b.txt');
      const tab = '[Copilot CLI] - b.txt (bdeb09)';
      const pending = cli.callTool('open_diff', { original_file_path: file, new_file_contents: 'brand new file\n', tab_name: tab }, 2);
      await waitFor(async () => (await fx.cmd('diffinfo', tab)).open, 3000, 'diff UI');
      const info = await fx.cmd('diffinfo', tab);
      assert.equal(info.editable, false);
      assert.equal(info.modifiable, false);
      assert.deepEqual(info.proposed, ['brand new file']);
      assert.deepEqual(info.original, ['']);
      await sleep(200);
      assert.deepEqual((await fx.cmd('accept', tab)).ok, true);
      const r = await pending;
      assert.equal(r.status, 200);
      // Answered later than synchronously: an SSE response with one message event.
      assert.match(r.headers['content-type'], /text\/event-stream/);
      assert.equal(r.sse.events.length, 1);
      assert.equal(r.sse.events[0].event, 'message');
      assert.deepEqual(toolText(r), {
        success: true,
        result: 'SAVED',
        trigger: 'accepted_via_button',
        tab_name: tab,
        message: 'User accepted changes for ' + file,
      });
      assert.equal(existsSync(file), false, 'Neovim must not write the file');
      assert.equal((await fx.cmd('diffinfo', tab)).open, false);
    });

    test('open_diff (edit) -> the user rejects -> REJECTED', async () => {
      const file = path.join(ws(), 'a.txt');
      const tab = '[Copilot CLI] - a.txt (cbb44d)';
      const pending = cli.callTool('open_diff', { original_file_path: file, new_file_contents: 'hello neovim\n', tab_name: tab }, 3);
      await waitFor(async () => (await fx.cmd('diffinfo', tab)).open, 3000);
      assert.deepEqual((await fx.cmd('diffinfo', tab)).original, ['hello world', 'second line']);
      await fx.cmd('reject', tab);
      const data = toolText(await pending);
      assert.equal(data.result, 'REJECTED');
      assert.equal(data.trigger, 'rejected_via_button');
      assert.equal(data.message, 'User rejected changes for ' + file);
    });

    test('the terminal answers first: close_diff on another connection resolves the pending open_diff', async () => {
      const file = path.join(ws(), 'a.txt');
      const tab = '[Copilot CLI] - a.txt (e66943)';
      const pending = cli.callTool('open_diff', { original_file_path: file, new_file_contents: 'hello neovim\n', tab_name: tab }, 4);
      await waitFor(async () => (await fx.cmd('diffinfo', tab)).open, 3000);
      await fx.cmd('buflines', file);
      const closed = await cli.callTool('close_diff', { tab_name: tab }, 5);
      assert.deepEqual(toolText(closed), {
        success: true,
        already_closed: false,
        tab_name: tab,
        message: `Diff "${tab}" closed successfully`,
      });
      const data = toolText(await pending);
      assert.equal(data.result, 'REJECTED');
      assert.equal(data.trigger, 'closed_via_tool');
      assert.equal((await fx.cmd('diffinfo', tab)).open, false);
      // "Yes" in the terminal: the CLI writes the file, and Neovim's buffer follows.
      await sleep(150);
      await fx.cmd('write', { path: file, text: 'hello neovim\nsecond line\n' });
      await waitFor(async () => (await fx.cmd('buflines', file)).lines?.[0] === 'hello neovim', 3000, 'buffer reload');
    });

    test('the user closes the diff UI: open_diff stays pending until close_diff', async () => {
      const file = path.join(ws(), 'a.txt');
      const tab = '[Copilot CLI] - a.txt (aaaaaa)';
      let settled = false;
      const pending = cli.callTool('open_diff', { original_file_path: file, new_file_contents: 'x\n', tab_name: tab }, 6).then((r) => {
        settled = true;
        return r;
      });
      await waitFor(async () => (await fx.cmd('diffinfo', tab)).open, 3000);
      await fx.cmd('closeui', tab);
      await sleep(300);
      assert.equal(settled, false);
      const stats = await fx.cmd('stats');
      assert.deepEqual(stats.pending, [tab]);
      assert.deepEqual(stats.diffs, []);
      const closed = toolText(await cli.callTool('close_diff', { tab_name: tab }, 7));
      assert.equal(closed.already_closed, false);
      const data = toolText(await pending);
      assert.equal(data.result, 'REJECTED');
      assert.equal(data.trigger, 'closed_via_tool');
    });

    test('close_diff for an unknown tab -> already_closed', async () => {
      const tab = '[Copilot CLI] - zzz.txt (000000)';
      assert.deepEqual(toolText(await cli.callTool('close_diff', { tab_name: tab }, 8)), {
        success: true,
        already_closed: true,
        tab_name: tab,
        message: `No active diff found with tab name "${tab}" (may already be closed)`,
      });
    });

    test('open_diff on a directory -> isError "Failed to open diff"', async () => {
      const r = await cli.callTool('open_diff', { original_file_path: ws(), new_file_contents: 'x', tab_name: 't' }, 9);
      assert.equal(r.json.result.isError, true);
      assert.match(r.json.result.content[0].text, /^Failed to open diff: /);
    });

    test('get_selection: current editor, then cached with current=false', async () => {
      await fx.cmd('cursor', { path: path.join(ws(), 'a.txt'), line: 2, col: 3 });
      const cur = toolText(await cli.callTool('get_selection', {}, 10));
      assert.deepEqual(cur, {
        text: '',
        filePath: path.join(ws(), 'a.txt'),
        fileUrl: 'file://' + path.join(ws(), 'a.txt'),
        selection: { start: { line: 1, character: 3 }, end: { line: 1, character: 3 }, isEmpty: true },
        current: true,
      });
      await fx.cmd('enew');
      const cached = toolText(await cli.callTool('get_selection', {}, 11));
      assert.equal(cached.current, false);
      assert.equal(cached.filePath, path.join(ws(), 'a.txt'));
    });

    test('get_diagnostics: all files, or one file by URI', async () => {
      const file = path.join(ws(), 'd.lua');
      writeFileSync(file, 'print(x)\n');
      await fx.cmd('diag', {
        path: file,
        items: [
          { lnum: 0, col: 6, end_lnum: 0, end_col: 7, message: 'undefined global x', severity: 2, source: 'lua_ls', code: 'undefined-global' },
        ],
      });
      const all = toolText(await cli.callTool('get_diagnostics', {}, 12));
      assert.deepEqual(all, [
        {
          uri: 'file://' + file,
          filePath: file,
          diagnostics: [
            {
              message: 'undefined global x',
              severity: 'warning',
              range: { start: { line: 0, character: 6 }, end: { line: 0, character: 7 } },
              source: 'lua_ls',
              code: 'undefined-global',
            },
          ],
        },
      ]);
      assert.deepEqual(toolText(await cli.callTool('get_diagnostics', { uri: 'file://' + file }, 13)), all);
      assert.deepEqual(toolText(await cli.callTool('get_diagnostics', { uri: 'file://' + path.join(ws(), 'a.txt') }, 14)), []);
    });

    test('get_vscode_info, ping, unknown methods and tools', async () => {
      const info = toolText(await cli.callTool('get_vscode_info', {}, 15));
      assert.equal(info.appName, 'Neovim');
      assert.equal(info.uriScheme, 'file');
      assert.match(info.version, /^\d+\.\d+\.\d+$/);
      const ping = await cli.request('ping');
      assert.deepEqual(ping.json.result, {});
      const unknown = await cli.request('resources/list', {});
      assert.equal(unknown.json.error.code, -32601);
      const tool = await cli.callTool('nope', {}, 16);
      assert.ok(tool.json.error || tool.json.result?.isError);
    });

    test('a second GET replaces the first stream', async () => {
      const s2 = await cli.openStream();
      assert.equal(s2.status, 200);
      await waitFor(() => stream.ended, 2000, 'old stream end');
      stream = s2;
      await sleep(100);
      stream.events.length = 0;
      await fx.cmd('select', { path: path.join(ws(), 'a.txt'), start: [1, 0], end: [1, 6] });
      assert.equal((await cli.nextEvent(stream)).data.params.text, 'second');
    });
  });

  test('takeover: re-initialize with the same X-Copilot-Session-Id -> 409 while streaming, takeover after the stream closed', async () => {
    const cli = new FakeCli(lock);
    const first = await cli.connect();
    const sid1 = first.init.headers['mcp-session-id'];

    // Still streaming: 409 with the substring the CLI matches (copilot.md §4.5).
    const other = new FakeCli(lock, { sessionId: cli.copilotSessionId });
    await other.discover();
    const conflict = await other.initialize();
    assert.equal(conflict.status, 409);
    assert.match(conflict.body, /A connection for this session already exists/);
    assert.equal(conflict.headers['mcp-session-id'], undefined);

    // The lock-rewrite case: the CLI drops its streams WITHOUT a DELETE and reconnects.
    first.stream.req.destroy();
    cli.close();
    await waitFor(async () => (await fx.cmd('stats')).sessions.every((s) => !s.streaming), 2000, 'stream closed');
    const re = new FakeCli(lock, { sessionId: cli.copilotSessionId });
    const second = await re.connect();
    const sid2 = second.init.headers['mcp-session-id'];
    assert.ok(sid2 && sid2 !== sid1);
    const stats = await fx.cmd('stats');
    assert.deepEqual(stats.sessions.map((s) => s.id), [sid2]);
    // Requests for the old session are refused now.
    re.mcpSessionId = sid1;
    const stale = await re.callTool('get_vscode_info', {});
    assert.equal(stale.status, 404);
    re.mcpSessionId = sid2;
    await re.delete();
    re.close();
    other.close();
  });

  test('DELETE with a pending open_diff dismisses the diff', async () => {
    const cli = new FakeCli(lock);
    await cli.connect();
    const tab = '[Copilot CLI] - a.txt (d00d00)';
    const pending = cli.callTool('open_diff', { original_file_path: path.join(fx.ws, 'a.txt'), new_file_contents: 'x\n', tab_name: tab }, 2);
    await waitFor(async () => (await fx.cmd('diffinfo', tab)).open, 3000);
    const del = await cli.delete();
    assert.equal(del.status, 200);
    const r = await pending;
    // The session is gone: the POST stream ends without a response.
    assert.equal(r.json, undefined);
    const stats = await fx.cmd('stats');
    assert.deepEqual(stats.diffs, []);
    assert.deepEqual(stats.pending, []);
    cli.close();
  });

  test('HTTP errors: auth, path, method, body, session', async () => {
    const bad = new FakeCli(lock, { authorization: 'Nonce ' + 'f'.repeat(64) });
    const r401 = await bad.discover();
    assert.equal(r401.status, 401);
    assert.equal(r401.body, 'Unauthorized');
    const none = new FakeCli(lock, { authorization: '' });
    assert.equal((await none.raw({ method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })).status, 401);

    const cli = new FakeCli(lock);
    const auth = cli.baseHeaders();
    assert.equal((await cli.raw({ method: 'POST', headers: auth, body: '{}', pathName: '/other' })).status, 404);
    const put = await cli.raw({ method: 'PUT', headers: auth, body: '{}' });
    assert.equal(put.status, 405);
    assert.match(put.headers.allow, /GET, POST, DELETE/);
    const parse = await cli.raw({ method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: '{nope' });
    assert.equal(parse.status, 400);
    assert.equal(JSON.parse(parse.body).error.code, -32700);
    cli.mcpSessionId = 'unknown-session';
    assert.equal((await cli.request('tools/list', {})).status, 404);
    // initialize without X-Copilot-Session-Id
    const anon = await cli.raw({
      method: 'POST',
      headers: { authorization: lock.headers.Authorization, 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'x', version: '1' } } }),
    });
    assert.equal(anon.status, 400);
    for (const c of [bad, none, cli]) c.close();
  });

  test('the MCP SDK transport (what the CLI bridges to) works over the socket', async () => {
    const agent = new Agent({ connect: { socketPath: lock.socketPath } });
    const transport = new StreamableHTTPClientTransport(new URL('http://localhost/mcp'), {
      fetch: (url, init) => ufetch(url, { ...init, dispatcher: agent }),
      requestInit: { headers: { ...lock.headers, 'X-Copilot-Session-Id': crypto.randomUUID(), 'X-Copilot-Pid': '1', 'X-Copilot-Parent-Pid': '0' } },
    });
    const client = new Client({ name: 'copilot-cli', version: '1.0.88' });
    await client.connect(transport);
    assert.equal(client.getServerVersion().name, 'agent-nvim-copilot-cli');
    const { tools } = await client.listTools();
    assert.equal(tools.length, 6);
    const r = await client.callTool({ name: 'update_session_name', arguments: { name: 'sdk' } });
    assert.deepEqual(JSON.parse(r.content[0].text), { success: true });
    await transport.terminateSession();
    await client.close();
    await agent.close();
  });

  test('launch_info adds a lock for the launch folder; stop removes every lock and the socket', async () => {
    const other = mkdtempSync(path.join(tmpdir(), 'acpn-ws-'));
    try {
      const r = await fx.cmd('launch', { cwd: other });
      assert.equal(r.info.lock_folder, realpathSync(other));
      const l2 = readLock(r.info.lock);
      assert.deepEqual(l2.workspaceFolders, [realpathSync(other)]);
      assert.equal(l2.socketPath, lock.socketPath);
      assert.equal(l2.headers.Authorization, lock.headers.Authorization);
      assert.equal(readdirSync(fx.ide_dir).filter((f) => f.endsWith('.lock')).length, 2);
      await fx.cmd('stop');
      assert.deepEqual(readdirSync(fx.ide_dir).filter((f) => f.endsWith('.lock')), []);
      assert.equal(existsSync(lock.socketPath), false);
      assert.equal(existsSync(path.dirname(lock.socketPath)), false);
      await assert.rejects(new FakeCli(lock).discover());
    } finally {
      rmSync(other, { recursive: true, force: true });
    }
  });
});
