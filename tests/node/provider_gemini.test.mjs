// Protocol tests for lua/agent/providers/gemini.lua, served by a headless Neovim
// (tests/node/fixtures/gemini_provider.lua). The clients replay what Gemini CLI 0.61 does
// (specs/gemini.md §4-§7): undici fetch with keep-alive and the exact recorded bodies, the SSE
// stream parsed by eventsource-parser (the parser inside the MCP SDK client), and every server
// notification checked against Gemini's zod schemas (gemini-cli core/src/ide/types.ts).
// Run: cd tests/node && node --test provider_gemini.test.mjs
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync, statSync, writeFileSync, realpathSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { Agent, fetch as ufetch } from 'undici';
import { createParser } from 'eventsource-parser';
import { z } from 'zod';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'gemini_provider.lua');
const NVIM = process.env.NVIM_BIN || 'nvim';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- Gemini's schemas (core/src/ide/types.ts) ---------------------------------------------
const FileSchema = z.object({
  path: z.string(),
  timestamp: z.number(),
  isActive: z.boolean().optional(),
  selectedText: z.string().optional(),
  cursor: z.object({ line: z.number(), character: z.number() }).optional(),
});
const IdeContextSchema = z.object({
  workspaceState: z
    .object({ openFiles: z.array(FileSchema).optional(), isTrusted: z.boolean().optional() })
    .optional(),
});
const IdeContextNotificationSchema = z.object({
  jsonrpc: z.literal('2.0'),
  method: z.literal('ide/contextUpdate'),
  params: IdeContextSchema,
});
const IdeDiffAcceptedNotificationSchema = z.object({
  jsonrpc: z.literal('2.0'),
  method: z.literal('ide/diffAccepted'),
  params: z.object({ filePath: z.string(), content: z.string() }),
});
const IdeDiffRejectedNotificationSchema = z.object({
  jsonrpc: z.literal('2.0'),
  method: z.literal('ide/diffRejected'),
  params: z.object({ filePath: z.string() }),
});
const NOTIFICATION_SCHEMAS = {
  'ide/contextUpdate': IdeContextNotificationSchema,
  'ide/diffAccepted': IdeDiffAcceptedNotificationSchema,
  'ide/diffRejected': IdeDiffRejectedNotificationSchema,
};
// Gemini's SDK 1.23 accepts these initialize versions (sdk/types.js SUPPORTED_PROTOCOL_VERSIONS).
const CLIENT_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05', '2024-10-07'];

// The tools/list body recommended by the spec (§5.3), which mirrors VS Code's companion.
const EXPECTED_TOOLS = [
  {
    name: 'openDiff',
    description:
      '(IDE Tool) Open a diff view to create or modify a file. Returns a notification once the diff has been accepted or rejected.',
    inputSchema: {
      type: 'object',
      properties: { filePath: { type: 'string' }, newContent: { type: 'string' } },
      required: ['filePath', 'newContent'],
    },
  },
  {
    name: 'closeDiff',
    description: '(IDE Tool) Close an open diff view for a specific file.',
    inputSchema: {
      type: 'object',
      properties: { filePath: { type: 'string' }, suppressNotification: { type: 'boolean' } },
      required: ['filePath'],
    },
  },
];

// --- fixture -------------------------------------------------------------------------------
async function startFixture() {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), 'agem-')));
  const env = { ...process.env, XDG_STATE_HOME: path.join(dir, 'state') };
  delete env.NVIM;
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
    stderr: () => stderr,
    url: `http://127.0.0.1:${info.port}/mcp`,
    async cmd(obj) {
      proc.stdin.write(JSON.stringify(obj) + '\n');
      const res = JSON.parse(await nextLine());
      if (res.error) throw new Error('fixture: ' + res.error);
      return res;
    },
    async stop() {
      if (proc.exitCode === null) {
        proc.stdin.write(JSON.stringify({ cmd: 'quit' }) + '\n');
        proc.stdin.end();
        const t = setTimeout(() => proc.kill('SIGKILL'), 5000);
        await exited;
        clearTimeout(t);
      }
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** Raw HTTP with full control over Host/Origin. */
function rawRequest({ port, method = 'POST', path: p = '/mcp', headers = {}, body }) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: p, headers, agent: false }, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(typeof body === 'string' ? body : JSON.stringify(body));
    req.end();
  });
}

/**
 * Read an SSE response the way the SDK client does (eventsource-parser; only events named
 * "message" or unnamed are JSON-RPC messages). Every message is validated like Gemini would:
 * a parse or schema failure is recorded in `errors` (Gemini would disconnect).
 */
function sseReader(res) {
  const r = { events: [], messages: [], comments: [], errors: [], ended: false, streamError: null };
  const parser = createParser({
    onEvent(ev) {
      r.events.push(ev);
      if (ev.event && ev.event !== 'message') return;
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch (e) {
        r.errors.push('invalid JSON: ' + ev.data);
        return;
      }
      const schema = NOTIFICATION_SCHEMAS[msg.method];
      if (msg.id !== undefined) r.errors.push('unexpected message with an id: ' + ev.data);
      else if (!schema) r.errors.push('unexpected notification: ' + ev.data);
      else {
        const parsed = schema.safeParse(msg);
        if (!parsed.success) r.errors.push('schema: ' + parsed.error.message + ' in ' + ev.data);
      }
      r.messages.push(msg);
    },
    onComment(c) {
      r.comments.push(c);
    },
  });
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  r.done = (async () => {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        parser.feed(decoder.decode(value, { stream: true }));
      }
    } catch (e) {
      r.streamError = e;
    }
    r.ended = true;
  })();
  r.cancel = () => reader.cancel().catch(() => {});
  r.of = (method) => r.messages.filter((m) => m.method === method);
  r.waitFor = async (method, n = 1, ms = 5000) => {
    const end = Date.now() + ms;
    while (r.of(method).length < n) {
      if (Date.now() > end) throw new Error(`timeout waiting for ${n} x ${method}; got ${JSON.stringify(r.messages)}`);
      if (r.ended) throw new Error(`stream ended while waiting for ${method}`);
      await sleep(10);
    }
    return r.of(method)[n - 1];
  };
  return r;
}

/**
 * A client that sends exactly what Gemini 0.61's IdeClient sends: SDK 1.23 StreamableHTTP
 * transport over undici fetch (keep-alive), bodies serialized with the same key order.
 */
class GeminiLikeClient {
  constructor(fx, dispatcher) {
    this.fx = fx;
    this.dispatcher = dispatcher;
    this.sessionId = undefined;
    this.protocolVersion = undefined;
    this.nextId = 0;
  }

  headers(extra = {}) {
    const h = { authorization: `Bearer ${this.fx.token}` };
    if (this.sessionId) h['mcp-session-id'] = this.sessionId;
    if (this.protocolVersion) h['mcp-protocol-version'] = this.protocolVersion;
    return { ...h, ...extra };
  }

  async postRaw(bodyText) {
    const res = await ufetch(this.fx.url, {
      method: 'POST',
      headers: this.headers({ 'content-type': 'application/json', accept: 'application/json, text/event-stream' }),
      body: bodyText,
      dispatcher: this.dispatcher,
    });
    const sid = res.headers.get('mcp-session-id');
    if (sid) this.sessionId = sid;
    const text = await res.text();
    return { status: res.status, headers: res.headers, text, json: text ? JSON.parse(text) : undefined };
  }

  // JSON.stringify of the SDK's request object: {method, params, jsonrpc, id}.
  request(method, params) {
    const id = this.nextId++;
    return this.postRaw(JSON.stringify({ method, params, jsonrpc: '2.0', id }));
  }

  notify(method, params) {
    return this.postRaw(JSON.stringify(params === undefined ? { method, jsonrpc: '2.0' } : { method, params, jsonrpc: '2.0' }));
  }

  callTool(name, args) {
    return this.request('tools/call', { name, arguments: args });
  }

  async openStream() {
    const res = await ufetch(this.fx.url, {
      method: 'GET',
      headers: this.headers({ accept: 'text/event-stream' }),
      dispatcher: this.dispatcher,
    });
    return { res, sse: res.ok ? sseReader(res) : null };
  }

  /** initialize -> notifications/initialized (202) -> GET -> tools/list, as Gemini does. */
  async connect() {
    const init = await this.postRaw(
      '{"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"streamable-http-client","version":"0.61.0"}},"jsonrpc":"2.0","id":0}',
    );
    this.nextId = 1;
    this.protocolVersion = init.json.result.protocolVersion;
    const initialized = await this.notify('notifications/initialized');
    const { res, sse } = await this.openStream();
    this.stream = sse;
    const tools = await this.request('tools/list', {});
    return { init, initialized, get: res, tools };
  }
}

// --- tests ---------------------------------------------------------------------------------
describe('gemini provider', () => {
  let fx;
  let agent;
  const clients = [];
  const newClient = () => {
    const c = new GeminiLikeClient(fx, agent);
    clients.push(c);
    return c;
  };
  const wsFile = (name, text) => {
    const p = path.join(fx.ws, name);
    if (text !== undefined) writeFileSync(p, text);
    return p;
  };

  before(async () => {
    fx = await startFixture();
    agent = new Agent({ keepAliveTimeout: 60000 });
  });
  after(async () => {
    for (const c of clients) c.stream?.cancel();
    await agent?.close().catch(() => {});
    await fx?.stop();
    if (fx?.stderr().trim()) console.error('[fixture stderr]', fx.stderr().trim());
  });

  test('discovery file is what Gemini reads: name, 0600, port, token, workspacePath, ideInfo', () => {
    const name = path.basename(fx.discovery_file);
    const m = name.match(/^gemini-ide-server-(\d+)-\d+\.json$/);
    assert.ok(m, name);
    assert.equal(Number(m[1]), fx.pid);
    assert.equal(name, `gemini-ide-server-${fx.pid}-${fx.port}.json`);
    assert.equal(statSync(fx.discovery_file).mode & 0o777, 0o600);
    assert.equal(statSync(path.dirname(fx.discovery_file)).mode & 0o777, 0o700);
    const data = JSON.parse(readFileSync(fx.discovery_file, 'utf8'));
    assert.equal(data.port, fx.port);
    assert.equal(data.authToken, fx.token);
    assert.deepEqual(data.ideInfo, { name: 'neovim', displayName: 'Neovim' });
    assert.equal(typeof data.workspacePath, 'string');
    const parts = data.workspacePath.split(path.delimiter);
    assert.ok(parts.includes(fx.ws), data.workspacePath);
    assert.ok(parts.every((p) => p !== ''), 'no empty segments');
  });

  test('replays Gemini 0.61: handshake, GET stream, tools/list, openDiff accepted in Neovim', async () => {
    const hello = wsFile('hello.txt', 'original\n');
    await fx.cmd({ cmd: 'edit', file: hello, line: 1, col: 0 });
    const c = newClient();
    const { init, initialized, get, tools } = await c.connect();

    assert.equal(init.status, 200);
    assert.match(init.headers.get('content-type'), /^application\/json/);
    assert.ok(c.sessionId, 'mcp-session-id issued');
    assert.equal(init.json.jsonrpc, '2.0');
    assert.equal(init.json.id, 0);
    const result = init.json.result;
    assert.equal(result.protocolVersion, '2025-06-18');
    assert.ok(CLIENT_VERSIONS.includes(result.protocolVersion));
    assert.deepEqual(result.capabilities, { tools: { listChanged: false }, logging: {} });
    assert.equal(typeof result.serverInfo.name, 'string');
    assert.equal(typeof result.serverInfo.version, 'string');

    assert.equal(initialized.status, 202);
    assert.equal(initialized.text, '');

    assert.equal(get.status, 200);
    assert.equal(get.headers.get('content-type'), 'text/event-stream');
    assert.equal(get.headers.get('mcp-session-id'), c.sessionId);

    assert.equal(tools.status, 200);
    assert.deepEqual(tools.json, { jsonrpc: '2.0', id: 1, result: { tools: EXPECTED_TOOLS } });

    // The first event on the stream is the initial context, with the file we just opened.
    const ctx = await c.stream.waitFor('ide/contextUpdate');
    const files = ctx.params.workspaceState.openFiles;
    assert.equal(files[0].path, hello);
    assert.equal(files[0].isActive, true);
    assert.deepEqual(files[0].cursor, { line: 1, character: 1 });
    assert.equal(ctx.params.workspaceState.isTrusted, undefined);

    // openDiff answers at once with {content: []}.
    const open = await c.callTool('openDiff', { filePath: hello, newContent: 'hello from model\n' });
    assert.equal(open.status, 200);
    assert.deepEqual(open.json, { jsonrpc: '2.0', id: 2, result: { content: [] } });
    const st = await fx.cmd({ cmd: 'state' });
    assert.deepEqual(st.diffs.map((d) => [d.path, d.text]), [[hello, 'hello from model']]);

    // The user edits the proposal and accepts it in Neovim.
    await fx.cmd({ cmd: 'append', path: hello, text: 'EDITED-IN-IDE' });
    assert.equal((await fx.cmd({ cmd: 'accept', path: hello })).ok, true);
    const accepted = await c.stream.waitFor('ide/diffAccepted');
    assert.deepEqual(accepted.params, { filePath: hello, content: 'hello from model\nEDITED-IN-IDE\n' });
    assert.equal(readFileSync(hello, 'utf8'), 'original\n', 'Neovim never writes the file: Gemini does');
    assert.deepEqual((await fx.cmd({ cmd: 'state' })).diffs, []);

    assert.deepEqual(c.stream.errors, []);
    assert.ok(c.stream.events.every((e) => e.event === 'message' && e.id === undefined));
  });

  test('TUI decisions: closeDiff returns the edited proposal as JSON text and sends nothing', async () => {
    const hello = wsFile('tui.txt', 'x\n');
    const c = newClient();
    await c.connect();
    await c.stream.waitFor('ide/contextUpdate');

    // Enter in the TUI: closeDiff{filePath, suppressNotification:true} before the write.
    await c.callTool('openDiff', { filePath: hello, newContent: '{"content":"a JSON file"}\n' });
    await fx.cmd({ cmd: 'append', path: hello, text: 'edited in nvim' });
    const close = await c.callTool('closeDiff', { filePath: hello, suppressNotification: true });
    assert.equal(close.status, 200);
    const content = close.json.result.content;
    assert.equal(content.length, 1);
    assert.equal(content[0].type, 'text');
    assert.deepEqual(JSON.parse(content[0].text), { content: '{"content":"a JSON file"}\nedited in nvim\n' });
    assert.deepEqual((await fx.cmd({ cmd: 'state' })).diffs, []);

    // Gemini exiting with a pending diff: closeDiff{filePath} (suppressNotification undefined).
    await c.callTool('openDiff', { filePath: hello, newContent: 'y\n' });
    const close2 = await c.callTool('closeDiff', { filePath: hello });
    assert.deepEqual(JSON.parse(close2.json.result.content[0].text), { content: 'y\n' });

    // No diff open: "{}" (what VS Code returns).
    const close3 = await c.callTool('closeDiff', { filePath: hello, suppressNotification: true });
    assert.equal(close3.json.result.content[0].text, '{}');

    await sleep(200);
    assert.equal(c.stream.of('ide/diffAccepted').length + c.stream.of('ide/diffRejected').length, 0);
    assert.deepEqual(c.stream.errors, []);
  });

  test('rejections in Neovim: reject key and closing the diff UI send ide/diffRejected {filePath}', async () => {
    const f = wsFile('rej.txt', 'r\n');
    const c = newClient();
    await c.connect();
    await c.callTool('openDiff', { filePath: f, newContent: 'no\n' });
    await fx.cmd({ cmd: 'reject', path: f });
    const r1 = await c.stream.waitFor('ide/diffRejected');
    assert.deepEqual(r1.params, { filePath: f });
    await c.callTool('openDiff', { filePath: f, newContent: 'no again\n' });
    await fx.cmd({ cmd: 'wipe', path: f });
    const r2 = await c.stream.waitFor('ide/diffRejected', 2);
    assert.deepEqual(r2.params, { filePath: f });
    assert.equal(c.stream.of('ide/diffAccepted').length, 0);
    assert.deepEqual(c.stream.errors, []);
  });

  test('silent replace of a diff for the same path; an empty proposal cannot be accepted', async () => {
    const f = wsFile('rep.txt', 'a\n');
    const c = newClient();
    await c.connect();
    await c.callTool('openDiff', { filePath: f, newContent: 'first\n' });
    const second = await c.callTool('openDiff', { filePath: f, newContent: 'second\n' });
    assert.deepEqual(second.json.result, { content: [] });
    let st = await fx.cmd({ cmd: 'state' });
    assert.deepEqual(st.diffs.map((d) => d.text), ['second']);
    await sleep(150);
    assert.equal(c.stream.of('ide/diffRejected').length, 0, 'no notification for the replaced diff');

    await fx.cmd({ cmd: 'clear', path: f });
    const acc = await fx.cmd({ cmd: 'accept', path: f });
    assert.equal(acc.ok, false);
    st = await fx.cmd({ cmd: 'state' });
    assert.equal(st.diffs.length, 1, 'still open');
    await c.callTool('closeDiff', { filePath: f, suppressNotification: true });
    assert.equal(c.stream.of('ide/diffAccepted').length, 0);
  });

  test('filePath is echoed byte for byte (non-realpath form, spaces, non-ASCII)', async () => {
    const odd = path.join(fx.ws, 'dir with spaces', 'ünï cødé.txt');
    const c = newClient();
    await c.connect();
    await c.callTool('openDiff', { filePath: odd, newContent: 'new file\n' });
    await fx.cmd({ cmd: 'accept', path: odd });
    assert.equal((await c.stream.waitFor('ide/diffAccepted')).params.filePath, odd);
    const alias = fx.ws + '/./hello.txt';
    await c.callTool('openDiff', { filePath: alias, newContent: 'z\n' });
    await fx.cmd({ cmd: 'reject', path: alias });
    assert.equal((await c.stream.waitFor('ide/diffRejected')).params.filePath, alias);
    assert.equal(existsSync(odd), false, 'the new file is not created by Neovim');
  });

  test('official MCP SDK client with Gemini\'s notification handlers stays error-free', async () => {
    const transport = new StreamableHTTPClientTransport(new URL(fx.url), {
      requestInit: { headers: { Authorization: `Bearer ${fx.token}` } },
    });
    // Gemini pins SDK 1.23, whose initialize asks for 2025-06-18.
    const send = transport.send.bind(transport);
    transport.send = (msg, opts) => {
      if (msg.method === 'initialize') msg = { ...msg, params: { ...msg.params, protocolVersion: '2025-06-18' } };
      return send(msg, opts);
    };
    const client = new Client({ name: 'streamable-http-client', version: '0.61.0' });
    const errors = [];
    client.onerror = (e) => errors.push(String(e));
    const got = { ctx: [], accepted: [], rejected: [] };
    client.setNotificationHandler(IdeContextNotificationSchema, (n) => got.ctx.push(n.params));
    client.setNotificationHandler(IdeDiffAcceptedNotificationSchema, (n) => got.accepted.push(n.params));
    client.setNotificationHandler(IdeDiffRejectedNotificationSchema, (n) => got.rejected.push(n.params));
    await client.connect(transport);
    try {
      assert.equal(transport.protocolVersion, '2025-06-18');
      assert.equal(client.getServerVersion().name, 'agent.nvim-gemini-companion');
      const { tools } = await client.listTools();
      assert.deepEqual(tools.map((t) => t.name), ['openDiff', 'closeDiff']);
      const f = wsFile('sdk.txt', 'sdk\n');
      const res = await client.callTool({ name: 'openDiff', arguments: { filePath: f, newContent: 'from sdk\n' } });
      assert.deepEqual(res.content, []);
      await fx.cmd({ cmd: 'accept', path: f });
      const end = Date.now() + 5000;
      while (got.accepted.length === 0 && Date.now() < end) await sleep(10);
      assert.deepEqual(got.accepted, [{ filePath: f, content: 'from sdk\n' }]);
      assert.ok(got.ctx.length >= 1, 'initial context received');
      await client.ping();
      assert.deepEqual(errors, []);
    } finally {
      await client.close();
    }
  });

  test('keep-alive comments flow on an idle GET stream', async () => {
    const c = newClient();
    await c.connect();
    await sleep(fx.keepalive_ms * 4);
    assert.ok(c.stream.comments.length >= 2, `comments: ${c.stream.comments.length}`);
    assert.ok(c.stream.comments.every((t) => t.trim() === 'keepalive'));
    assert.equal(c.stream.ended, false);
  });

  test('a second GET replaces the first stream, which ends cleanly', async () => {
    const c = newClient();
    await c.connect();
    const first = c.stream;
    await first.waitFor('ide/contextUpdate');
    const { res, sse } = await c.openStream();
    assert.equal(res.status, 200);
    c.stream = sse;
    await first.done;
    assert.equal(first.streamError, null, 'graceful end (terminating chunk), not a reset');
    await sse.waitFor('ide/contextUpdate');
  });

  test('ide/contextUpdate: focus, 1-based UTF-16 cursor, selection, schema-valid', async () => {
    const a = wsFile('ctx.txt', 'first line\nhéllo \u{1F600} world\nthird\n');
    const c = newClient();
    await c.connect();
    await c.stream.waitFor('ide/contextUpdate');
    const before = c.stream.of('ide/contextUpdate').length;
    // 0-based byte column 11 on line 2 is right after "héllo 😀" (11 bytes: é = 2 bytes / 1 UTF-16
    // unit, 😀 = 4 bytes / 2 units), i.e. 8 UTF-16 units: 1-based character 9.
    await fx.cmd({ cmd: 'edit', file: a, line: 2, col: 11 });
    const moved = await c.stream.waitFor('ide/contextUpdate', before + 1);
    const active = moved.params.workspaceState.openFiles[0];
    assert.equal(active.path, a);
    assert.equal(active.isActive, true);
    assert.deepEqual(active.cursor, { line: 2, character: 9 });
    assert.ok(moved.params.workspaceState.openFiles.slice(1).every((f) => f.isActive === undefined && f.cursor === undefined));

    const sel = await fx.cmd({ cmd: 'select', from: 1, to: 2 });
    assert.equal(sel.mode, 'V');
    const selected = await c.stream.waitFor('ide/contextUpdate', before + 2);
    assert.equal(selected.params.workspaceState.openFiles[0].selectedText, 'first line\nhéllo \u{1F600} world');
    await fx.cmd({ cmd: 'escape' });
    assert.deepEqual(c.stream.errors, []);
  });

  test('request validation: Host, Origin, Bearer, DELETE, sessions', async () => {
    const init = '{"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"0"}},"jsonrpc":"2.0","id":0}';
    const base = { authorization: `Bearer ${fx.token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
    let r = await rawRequest({ port: fx.port, headers: { ...base, host: `evil.example:${fx.port}` }, body: init });
    assert.equal(r.status, 403);
    assert.deepEqual(JSON.parse(r.body), { error: 'Invalid Host header' });
    r = await rawRequest({ port: fx.port, headers: { ...base, origin: 'https://evil.example' }, body: init });
    assert.equal(r.status, 403);
    assert.deepEqual(JSON.parse(r.body), { error: 'Request denied by CORS policy.' });
    r = await rawRequest({ port: fx.port, headers: { ...base, authorization: 'Bearer nope' }, body: init });
    assert.equal(r.status, 401);
    r = await rawRequest({ port: fx.port, headers: { ...base, authorization: `Bearer ${fx.token} x` }, body: init });
    assert.equal(r.status, 401);
    r = await rawRequest({ port: fx.port, headers: { ...base, host: `localhost:${fx.port}` }, body: init });
    assert.equal(r.status, 200);
    const sid = r.headers['mcp-session-id'];
    r = await rawRequest({ port: fx.port, method: 'DELETE', headers: { ...base, 'mcp-session-id': sid } });
    assert.equal(r.status, 405);
    r = await rawRequest({ port: fx.port, headers: base, body: '{"method":"tools/list","params":{},"jsonrpc":"2.0","id":1}' });
    assert.equal(r.status, 400);
    r = await rawRequest({ port: fx.port, method: 'GET', headers: { authorization: base.authorization, accept: 'text/event-stream', 'mcp-session-id': 'nope' } });
    assert.equal(r.status, 400);
    r = await rawRequest({ port: fx.port, headers: base, body: '{oops' });
    assert.equal(r.status, 400);
    assert.equal(JSON.parse(r.body).error.code, -32700);
  });

  test('stop(): streams end gracefully, discovery file removed, port closed', async () => {
    const c = newClient();
    await c.connect();
    const f = wsFile('stop.txt', 's\n');
    await c.callTool('openDiff', { filePath: f, newContent: 'pending\n' });
    const res = await fx.cmd({ cmd: 'stop' });
    assert.equal(res.discovery_exists, false);
    await c.stream.done;
    assert.equal(c.stream.streamError, null);
    assert.equal(c.stream.of('ide/diffRejected').length, 0, 'Gemini\'s own prompt still decides');
    const st = await fx.cmd({ cmd: 'state' });
    assert.equal(st.running, false);
    assert.deepEqual(st.diffs, []);
    await assert.rejects(
      rawRequest({ port: fx.port, headers: { authorization: `Bearer ${fx.token}` }, body: '{}' }),
      /ECONNREFUSED/,
    );
  });
});
