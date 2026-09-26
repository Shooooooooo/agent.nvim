// Real-client tests for lua/agent/mcp/{server,streamable_http}.lua, served by a headless Neovim
// (tests/node/fixtures/mcp_server.lua). Run: cd tests/node && node --test mcp_streamable.test.mjs
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { Agent, fetch as ufetch } from 'undici';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { McpError } from '@modelcontextprotocol/sdk/types.js';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'mcp_server.lua');
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

/** Spawn the fixture; resolves once it prints its addresses. */
async function startFixture() {
  // Short base dir: the socket path must fit in sun_path (104 bytes on macOS).
  const base = process.platform === 'win32' ? tmpdir() : '/tmp';
  const dir = mkdtempSync(path.join(existsSync(base) ? base : tmpdir(), 'amcp-'));
  const sock = path.join(dir, 's', 'm.sock');
  const env = { ...process.env, XDG_STATE_HOME: path.join(dir, 'state') };
  delete env.NVIM;
  const proc = spawn(NVIM, ['--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', FIXTURE, ROOT, sock], {
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
  const unixAgent = new Agent({ connect: { socketPath: info.pipe } });
  return {
    ...info,
    dir,
    proc,
    exited,
    unixAgent,
    stderr: () => stderr,
    async cmd(line) {
      proc.stdin.write(line + '\n');
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
      await unixAgent.close().catch(() => {});
      rmSync(dir, { recursive: true, force: true });
      if (stderr.trim()) console.error('[fixture stderr]', stderr.trim());
    },
  };
}

/** Raw HTTP request with full control over headers (Host, Origin, ...). */
function rawRequest({ port, socketPath, method = 'POST', path: p = '/mcp', headers = {}, body }) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, socketPath, method, path: p, headers, agent: false },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
      },
    );
    req.on('error', reject);
    if (body !== undefined) req.write(typeof body === 'string' ? body : JSON.stringify(body));
    req.end();
  });
}

const jsonBody = (r) => JSON.parse(r.body);

/** Minimal SSE parser over a fetch response body (events and comments). */
async function* sseEvents(body) {
  const decoder = new TextDecoder();
  let buf = '';
  for await (const chunk of body) {
    buf += decoder.decode(chunk, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const ev = { event: undefined, data: [], comments: [] };
      for (const line of block.split('\n')) {
        if (line.startsWith(':')) ev.comments.push(line.slice(1).trim());
        else if (line.startsWith('data:')) ev.data.push(line.slice(5).replace(/^ /, ''));
        else if (line.startsWith('event:')) ev.event = line.slice(6).trim();
      }
      yield { ...ev, data: ev.data.join('\n') };
    }
  }
}

const INIT = (id = 0, protocolVersion = '2025-06-18') => ({
  jsonrpc: '2.0',
  id,
  method: 'initialize',
  params: { protocolVersion, capabilities: {}, clientInfo: { name: 'raw-test', version: '0' } },
});

describe('mcp streamable http', () => {
  let fx;
  before(async () => {
    fx = await startFixture();
  });
  after(async () => {
    await fx?.stop();
  });

  // --- profile helpers -------------------------------------------------------------
  const gemini = {
    url: () => `http://127.0.0.1:${fx.gemini_port}/mcp`,
    headers: () => ({ Authorization: `Bearer ${fx.token}` }),
  };
  const copilotHeaders = (cid = crypto.randomUUID()) => ({
    Authorization: fx.nonce,
    'X-Copilot-Session-Id': cid,
    'X-Copilot-Pid': '4242',
    'X-Copilot-Parent-Pid': '4241',
  });
  const unixFetch = (u, init) => ufetch(u, { ...init, dispatcher: fx.unixAgent });

  async function sdkClient(kind, { headers, name = 'sdk-test' } = {}) {
    let transport;
    if (kind === 'copilot') {
      transport = new StreamableHTTPClientTransport(new URL('http://localhost/mcp'), {
        fetch: unixFetch,
        requestInit: { headers: headers ?? copilotHeaders() },
      });
    } else {
      const port = { gemini: fx.gemini_port, sse: fx.sse_port, json: fx.json_port }[kind];
      transport = new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`), {
        requestInit: { headers: headers ?? { Authorization: `Bearer ${fx.token}` } },
      });
    }
    const client = new Client({ name, version: '1.0.0' });
    const notes = [];
    client.fallbackNotificationHandler = async (n) => {
      notes.push(n);
    };
    await client.connect(transport);
    return { client, transport, notes };
  }

  // Raw initialize on the gemini profile; returns the session id.
  async function rawSession(port = fx.gemini_port) {
    const r = await rawRequest({
      port,
      headers: { ...gemini.headers(), Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' },
      body: INIT(),
    });
    assert.equal(r.status, 200, r.body);
    return r.headers['mcp-session-id'];
  }

  const post = (sid, body, extra = {}) =>
    rawRequest({
      port: fx.gemini_port,
      headers: {
        ...gemini.headers(),
        Accept: 'application/json, text/event-stream',
        'Content-Type': 'application/json',
        ...(sid ? { 'Mcp-Session-Id': sid } : {}),
        ...extra,
      },
      body,
    });

  // --- SDK client over TCP (gemini profile) -----------------------------------------
  describe('SDK client over TCP (gemini profile)', () => {
    test('handshake, tools, sync and async calls, ping', async () => {
      const { client, transport } = await sdkClient('gemini');
      try {
        assert.equal(client.getServerVersion().name, 'agent.nvim-test');
        assert.ok(transport.sessionId);
        const { tools } = await client.listTools();
        const names = tools.map((t) => t.name);
        assert.deepEqual(names, ['echo', 'add', 'noargs', 'sleep', 'block', 'progress', 'notify', 'fail']);
        const noargs = tools.find((t) => t.name === 'noargs');
        assert.deepEqual(noargs.inputSchema, { type: 'object', properties: {} });
        const echo = await client.callTool({ name: 'echo', arguments: { text: 'hello' } });
        assert.deepEqual(echo.content, [{ type: 'text', text: 'hello' }]);
        const add = await client.callTool({ name: 'add', arguments: { a: 2, b: 3 } });
        assert.deepEqual(JSON.parse(add.content[0].text), { sum: 5 });
        const na = JSON.parse((await client.callTool({ name: 'noargs', arguments: {} })).content[0].text);
        assert.equal(na.session, transport.sessionId);
        assert.equal(na.protocol, transport.protocolVersion);
        const t0 = Date.now();
        const slept = await client.callTool({ name: 'sleep', arguments: { ms: 350 } });
        assert.equal(slept.content[0].text, 'slept 350');
        assert.ok(Date.now() - t0 >= 300);
        const hidden = await client.callTool({ name: 'secret', arguments: {} });
        assert.equal(hidden.content[0].text, 'hidden result');
        assert.deepEqual(await client.ping(), {});
      } finally {
        await client.close();
      }
    });

    test('notifications arrive on the GET stream, including the on_stream_open replay', async () => {
      const { client, notes } = await sdkClient('gemini');
      try {
        await waitFor(() => notes.find((n) => n.method === 'test/stream_open'), 3000, 'stream_open replay');
        const r = await client.callTool({ name: 'notify', arguments: { text: 'ping!' } });
        assert.deepEqual(JSON.parse(r.content[0].text), { sent: true });
        const n = await waitFor(() => notes.find((x) => x.method === 'test/hello'), 3000, 'test/hello');
        assert.deepEqual(n.params, { text: 'ping!' });
        const b = await fx.cmd('broadcast test/broadcast');
        assert.ok(b.sent >= 1);
        await waitFor(() => notes.find((x) => x.method === 'test/broadcast'), 3000, 'broadcast');
      } finally {
        await client.close();
      }
    });

    test('server->client requests go out on the GET stream; the answer comes back as a POST', async () => {
      const { client, transport } = await sdkClient('gemini');
      try {
        await waitFor(async () => (await fx.cmd('stats')).sessions.gemini.find((s) => s.id === transport.sessionId && s.stream_open), 3000, 'stream');
        const r = await fx.cmd('ping ' + transport.sessionId);
        assert.deepEqual(r, { result: {}, error: null });
      } finally {
        await client.close();
      }
    });

    test('progress notifications are streamed on the POST response', async () => {
      const { client } = await sdkClient('gemini');
      try {
        const got = [];
        const r = await client.callTool({ name: 'progress', arguments: { steps: 3, ms: 30 } }, undefined, {
          onprogress: (p) => got.push(p),
        });
        assert.equal(r.content[0].text, 'progressed 3');
        assert.deepEqual(
          got.map((p) => [p.progress, p.total, p.message]),
          [
            [1, 3, 'step 1'],
            [2, 3, 'step 2'],
            [3, 3, 'step 3'],
          ],
        );
      } finally {
        await client.close();
      }
    });

    test('errors: JSON-RPC error, unknown tool, missing argument', async () => {
      const { client } = await sdkClient('gemini');
      try {
        await assert.rejects(client.callTool({ name: 'fail', arguments: {} }), (e) => {
          assert.ok(e instanceof McpError);
          assert.equal(e.code, -32000);
          assert.match(e.message, /intentional failure/);
          return true;
        });
        await assert.rejects(client.callTool({ name: 'nope', arguments: {} }), (e) => e.code === -32602);
        await assert.rejects(client.callTool({ name: 'echo', arguments: {} }), (e) => e.code === -32602 && /text/.test(e.message));
      } finally {
        await client.close();
      }
    });

    test('an aborted call sends notifications/cancelled and the tool sees it', async () => {
      const { client } = await sdkClient('gemini');
      try {
        const ac = new AbortController();
        const p = client.callTool({ name: 'block', arguments: { tag: 'abort-1' } }, undefined, { signal: ac.signal });
        await waitFor(async () => (await fx.cmd('stats')).started['abort-1'], 3000, 'block started');
        ac.abort('user stop');
        await assert.rejects(p);
        const s = await waitFor(async () => (await fx.cmd('stats')).cancelled['abort-1'], 3000, 'cancellation');
        assert.equal(s.reason, 'cancelled');
        assert.match(String(s.detail), /user stop/);
        // The session keeps working afterwards.
        assert.equal((await client.callTool({ name: 'echo', arguments: { text: 'still here' } })).content[0].text, 'still here');
      } finally {
        await client.close();
      }
    });

    test('a request timeout cancels the pending tool', async () => {
      const { client } = await sdkClient('gemini');
      try {
        await assert.rejects(
          client.callTool({ name: 'block', arguments: { tag: 'timeout-1' } }, undefined, { timeout: 300 }),
          (e) => e.code === -32001,
        );
        const s = await waitFor(async () => (await fx.cmd('stats')).cancelled['timeout-1'], 3000, 'cancellation');
        assert.equal(s.reason, 'cancelled');
      } finally {
        await client.close();
      }
    });

    test('without DELETE (405) the session expires after its GET stream is gone', async () => {
      const { client, transport } = await sdkClient('gemini');
      const sid = transport.sessionId;
      await waitFor(async () => (await fx.cmd('stats')).sessions.gemini.find((s) => s.id === sid && s.stream_open), 3000, 'stream');
      // The gemini profile disables DELETE; the SDK tolerates the 405.
      await transport.terminateSession();
      await client.close();
      const st = await waitFor(
        async () => (await fx.cmd('stats')).session_closes.find((c) => c.id === sid),
        5000,
        'session expiry',
      );
      assert.equal(st.reason, 'expired');
      assert.ok((await fx.cmd('stats')).stream_closes.find((c) => c.id === sid && c.reason === 'disconnect'));
    });
  });

  // --- Raw HTTP edge cases (gemini profile) ---------------------------------------------
  describe('raw HTTP (gemini profile)', () => {
    const base = () => ({ Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' });

    test('authorization, Host and Origin checks', async () => {
      const port = fx.gemini_port;
      let r = await rawRequest({ port, headers: base(), body: INIT() });
      assert.equal(r.status, 401);
      assert.equal(r.body, 'Unauthorized');
      r = await rawRequest({ port, headers: { ...base(), Authorization: 'Bearer wrong' }, body: INIT() });
      assert.equal(r.status, 401);
      r = await rawRequest({ port, headers: { ...base(), Authorization: `Bearer ${fx.token} extra` }, body: INIT() });
      assert.equal(r.status, 401);
      r = await rawRequest({ port, headers: { ...base(), Authorization: `bearer ${fx.token}` }, body: INIT() });
      assert.equal(r.status, 401);
      r = await rawRequest({ port, headers: { ...base(), ...gemini.headers(), Host: 'evil.example:80' }, body: INIT() });
      assert.equal(r.status, 403);
      assert.deepEqual(jsonBody(r), { error: 'Invalid Host header' });
      r = await rawRequest({ port, headers: { ...base(), ...gemini.headers(), Host: `localhost:${port}` }, body: INIT() });
      assert.equal(r.status, 200);
      r = await rawRequest({ port, headers: { ...base(), ...gemini.headers(), Origin: 'http://evil.example' }, body: INIT() });
      assert.equal(r.status, 403);
      assert.deepEqual(jsonBody(r), { error: 'Request denied by CORS policy.' });
      // Host is checked before auth.
      r = await rawRequest({ port, headers: { ...base(), Host: 'evil.example' }, body: INIT() });
      assert.equal(r.status, 403);
    });

    test('path and method routing', async () => {
      const port = fx.gemini_port;
      let r = await rawRequest({ port, path: '/other', headers: { ...base(), ...gemini.headers() }, body: INIT() });
      assert.equal(r.status, 404);
      r = await rawRequest({ port, path: '/mcp?x=1', headers: { ...base(), ...gemini.headers() }, body: INIT() });
      assert.equal(r.status, 200);
      r = await rawRequest({ port, method: 'PUT', headers: { ...base(), ...gemini.headers() }, body: '{}' });
      assert.equal(r.status, 405);
      assert.equal(r.headers.allow, 'GET, POST');
      assert.equal(jsonBody(r).error.code, -32000);
      const sid = await rawSession();
      r = await rawRequest({ port, method: 'DELETE', headers: { ...gemini.headers(), 'Mcp-Session-Id': sid } });
      assert.equal(r.status, 405);
    });

    test('malformed bodies', async () => {
      let r = await post(null, '{not json');
      assert.equal(r.status, 400);
      assert.equal(jsonBody(r).error.code, -32700);
      assert.equal(jsonBody(r).id, null);
      r = await post(null, '');
      assert.equal(r.status, 400);
      r = await post(null, { hello: 'world' });
      assert.equal(r.status, 400);
      assert.equal(jsonBody(r).error.code, -32600);
      r = await post(null, []);
      assert.equal(r.status, 400);
      r = await post(null, [INIT(1), INIT(2)]);
      assert.equal(r.status, 400);
    });

    test('session header rules: missing 400, unknown 404, discover without a session', async () => {
      let r = await post(null, { jsonrpc: '2.0', id: 1, method: 'tools/list' });
      assert.equal(r.status, 400);
      assert.match(jsonBody(r).error.message, /Mcp-Session-Id/);
      r = await post('no-such-session', { jsonrpc: '2.0', id: 1, method: 'tools/list' });
      assert.equal(r.status, 404);
      assert.equal(jsonBody(r).error.code, -32001);
      r = await post(null, { jsonrpc: '2.0', method: 'notifications/initialized' });
      assert.equal(r.status, 400);
      for (const sid of [null, 'stale-session-id']) {
        r = await post(sid, { jsonrpc: '2.0', id: 0, method: 'server/discover', params: {} });
        assert.equal(r.status, 200);
        assert.deepEqual(jsonBody(r), { jsonrpc: '2.0', id: 0, error: { code: -32601, message: 'Method not found' } });
        assert.equal(r.headers['mcp-session-id'], undefined);
      }
    });

    test('initialize, 202 for notifications, JSON for sync requests, batches', async () => {
      let r = await post(null, INIT(5, '2025-03-26'));
      assert.equal(r.status, 200);
      assert.match(r.headers['content-type'], /^application\/json/);
      const sid = r.headers['mcp-session-id'];
      assert.match(sid, /^[0-9a-f-]{36}$/);
      const init = jsonBody(r);
      assert.equal(init.id, 5);
      assert.equal(init.result.protocolVersion, '2025-03-26');
      assert.deepEqual(init.result.capabilities, { tools: { listChanged: false }, logging: {} });
      r = await post(sid, { jsonrpc: '2.0', method: 'notifications/initialized' });
      assert.equal(r.status, 202);
      assert.equal(r.body, '');
      // An id member makes a request (JSON-RPC 2.0), and MCP forbids a null id: -32600, not 202.
      for (const body of [
        { jsonrpc: '2.0', id: null, method: 'ping' },
        [{ jsonrpc: '2.0', method: 'notifications/a' }, { jsonrpc: '2.0', id: null, method: 'notifications/b' }],
      ]) {
        r = await post(sid, body);
        assert.equal(r.status, 400);
        assert.equal(jsonBody(r).id, null);
        assert.equal(jsonBody(r).error.code, -32600);
      }
      r = await post(sid, { jsonrpc: '2.0', id: 'p', method: 'ping' });
      assert.equal(r.status, 200);
      assert.equal(r.headers['mcp-session-id'], sid);
      assert.deepEqual(jsonBody(r), { jsonrpc: '2.0', id: 'p', result: {} });
      r = await post(sid, [
        { jsonrpc: '2.0', id: 1, method: 'ping' },
        { jsonrpc: '2.0', method: 'notifications/whatever' },
        { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'echo', arguments: { text: 'b' } } },
      ]);
      assert.equal(r.status, 200);
      const arr = jsonBody(r);
      assert.ok(Array.isArray(arr));
      assert.deepEqual(arr.map((x) => x.id).sort(), [1, 2]);
      // A batch of responses/notifications only: 202.
      r = await post(sid, [{ jsonrpc: '2.0', method: 'notifications/a' }, { jsonrpc: '2.0', id: 99, result: {} }]);
      assert.equal(r.status, 202);
    });

    test('MCP-Protocol-Version header validation', async () => {
      const sid = await rawSession();
      let r = await post(sid, { jsonrpc: '2.0', id: 1, method: 'ping' }, { 'MCP-Protocol-Version': '2025-06-18' });
      assert.equal(r.status, 200);
      r = await post(sid, { jsonrpc: '2.0', id: 1, method: 'ping' }, { 'MCP-Protocol-Version': '1999-01-01' });
      assert.equal(r.status, 400);
      assert.match(jsonBody(r).error.message, /Unsupported protocol version/);
    });

    test('a pending async call streams keep-alive comments, then the answer (auto mode)', async () => {
      const sid = await rawSession();
      const res = await fetch(gemini.url(), {
        method: 'POST',
        headers: { ...gemini.headers(), ...base(), 'Mcp-Session-Id': sid },
        body: JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'tools/call', params: { name: 'sleep', arguments: { ms: 450 } } }),
      });
      assert.equal(res.status, 200);
      assert.match(res.headers.get('content-type'), /^text\/event-stream/);
      assert.equal(res.headers.get('mcp-session-id'), sid);
      const seen = [];
      for await (const ev of sseEvents(res.body)) seen.push(ev);
      const comments = seen.filter((e) => e.comments.includes('keepalive'));
      assert.ok(comments.length >= 2, `expected keep-alives, got ${JSON.stringify(seen)}`);
      const last = seen[seen.length - 1];
      assert.equal(last.event, 'message');
      assert.deepEqual(JSON.parse(last.data), { jsonrpc: '2.0', id: 9, result: { content: [{ type: 'text', text: 'slept 450' }] } });
    });

    test('a client that accepts only JSON gets JSON for a pending call', async () => {
      const sid = await rawSession();
      const t0 = Date.now();
      const r = await post(sid, { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'sleep', arguments: { ms: 250 } } }, { Accept: 'application/json' });
      assert.equal(r.status, 200);
      assert.ok(Date.now() - t0 >= 200);
      assert.match(r.headers['content-type'], /^application\/json/);
      assert.equal(jsonBody(r).result.content[0].text, 'slept 250');
    });

    test('GET stream: validation, keep-alives, replacement by a second GET', async () => {
      const sid = await rawSession();
      let r = await rawRequest({ port: fx.gemini_port, method: 'GET', headers: { ...gemini.headers(), Accept: 'text/event-stream' } });
      assert.equal(r.status, 400);
      r = await rawRequest({ port: fx.gemini_port, method: 'GET', headers: { ...gemini.headers(), Accept: 'text/event-stream', 'Mcp-Session-Id': 'nope' } });
      assert.equal(r.status, 404);
      r = await rawRequest({ port: fx.gemini_port, method: 'GET', headers: { ...gemini.headers(), Accept: 'application/json', 'Mcp-Session-Id': sid } });
      assert.equal(r.status, 406);

      const open = async () => {
        const res = await fetch(gemini.url(), { headers: { ...gemini.headers(), Accept: 'text/event-stream', 'Mcp-Session-Id': sid } });
        assert.equal(res.status, 200);
        assert.match(res.headers.get('content-type'), /^text\/event-stream/);
        assert.equal(res.headers.get('cache-control'), 'no-cache, no-transform');
        return sseEvents(res.body)[Symbol.asyncIterator]();
      };
      const first = await open();
      let ev = await first.next();
      assert.deepEqual(JSON.parse(ev.value.data).method, 'test/stream_open');
      ev = await first.next();
      assert.deepEqual(ev.value.comments, ['keepalive']);
      const second = await open();
      // The first stream is ended gracefully; the second one takes over.
      for (;;) {
        const x = await first.next();
        if (x.done) break;
      }
      ev = await second.next();
      assert.equal(JSON.parse(ev.value.data).method, 'test/stream_open');
      await post(sid, { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'notify', arguments: { text: 'to-second' } } });
      for (;;) {
        ev = await second.next();
        if (ev.value.data) break;
      }
      assert.deepEqual(JSON.parse(ev.value.data), { jsonrpc: '2.0', method: 'test/hello', params: { text: 'to-second' } });
      await second.return();
    });

    test('a client that disconnects cancels its pending call', async () => {
      const sid = await rawSession();
      const ac = new AbortController();
      const res = await fetch(gemini.url(), {
        method: 'POST',
        signal: ac.signal,
        headers: { ...gemini.headers(), ...base(), 'Mcp-Session-Id': sid },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'block', arguments: { tag: 'disc-1' } } }),
      });
      assert.equal(res.status, 200);
      ac.abort();
      const s = await waitFor(async () => (await fx.cmd('stats')).cancelled['disc-1'], 3000, 'disconnect cancellation');
      assert.equal(s.reason, 'disconnect');
      const sessions = (await fx.cmd('stats')).sessions.gemini;
      assert.equal(sessions.find((x) => x.id === sid).pending, 0);
    });

    test('notifications/cancelled on another POST ends the pending stream without an answer', async () => {
      const sid = await rawSession();
      const res = await fetch(gemini.url(), {
        method: 'POST',
        headers: { ...gemini.headers(), ...base(), 'Mcp-Session-Id': sid },
        body: JSON.stringify({ jsonrpc: '2.0', id: 77, method: 'tools/call', params: { name: 'block', arguments: { tag: 'cancel-raw' } } }),
      });
      const events = [];
      const reading = (async () => {
        for await (const ev of sseEvents(res.body)) events.push(ev);
      })();
      await waitFor(async () => (await fx.cmd('stats')).started['cancel-raw'], 3000, 'block started');
      const r = await post(sid, { jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 77, reason: 'nah' } });
      assert.equal(r.status, 202);
      await reading;
      assert.equal(events.filter((e) => e.data).length, 0);
      const s = (await fx.cmd('stats')).cancelled['cancel-raw'];
      assert.deepEqual(s, { reason: 'cancelled', detail: 'nah' });
    });
  });

  // --- Copilot profile over the Unix socket -----------------------------------------------
  describe('copilot profile (Unix socket)', () => {
    const upost = (headers, body) =>
      rawRequest({
        socketPath: fx.pipe,
        headers: { Host: 'localhost', Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json', ...headers },
        body,
      });

    test('Nonce auth; discover gets 200 + -32601 without a session header', async () => {
      let r = await upost({ Authorization: 'Nonce wrong' }, INIT());
      assert.equal(r.status, 401);
      r = await upost({ 'X-Copilot-Session-Id': 'x' }, INIT());
      assert.equal(r.status, 401);
      const discover = {
        jsonrpc: '2.0',
        id: 0,
        method: 'server/discover',
        params: { _meta: { 'io.modelcontextprotocol/protocolVersion': '2026-07-28' } },
      };
      r = await upost(copilotHeaders(), discover);
      assert.equal(r.status, 200);
      assert.deepEqual(jsonBody(r), { jsonrpc: '2.0', id: 0, error: { code: -32601, message: 'Method not found' } });
      assert.equal(r.headers['mcp-session-id'], undefined);
    });

    test('initialize requires X-Copilot-Session-Id', async () => {
      const r = await upost({ Authorization: fx.nonce }, INIT(1, '2025-11-25'));
      assert.equal(r.status, 400);
      assert.match(r.body, /X-Copilot-Session-Id/);
    });

    test('SDK client over the socket: calls, notifications, DELETE on terminate', async () => {
      const cid = crypto.randomUUID();
      const { client, transport, notes } = await sdkClient('copilot', { headers: copilotHeaders(cid), name: 'copilot-cli' });
      try {
        const sid = transport.sessionId;
        assert.ok(sid);
        assert.notEqual(sid, cid);
        assert.equal((await client.callTool({ name: 'echo', arguments: { text: 'over uds' } })).content[0].text, 'over uds');
        assert.equal((await client.callTool({ name: 'sleep', arguments: { ms: 250 } })).content[0].text, 'slept 250');
        await waitFor(() => notes.find((n) => n.method === 'test/stream_open'), 3000, 'stream_open');
        await client.callTool({ name: 'notify', arguments: { text: 'uds note' } });
        await waitFor(() => notes.find((n) => n.method === 'test/hello' && n.params.text === 'uds note'), 3000, 'test/hello');
        const st = await fx.cmd('stats');
        const mine = st.sessions.copilot.find((s) => s.id === sid);
        assert.equal(mine.copilot_session_id, cid);
        assert.equal(mine.client, 'copilot-cli');
        // A second GET for the same session is refused in this profile.
        const second = await rawRequest({
          socketPath: fx.pipe,
          method: 'GET',
          headers: { ...copilotHeaders(cid), Host: 'localhost', Accept: 'text/event-stream', 'Mcp-Session-Id': sid },
        });
        assert.equal(second.status, 409);
        await transport.terminateSession();
        const closed = await waitFor(async () => (await fx.cmd('stats')).session_closes.find((c) => c.id === sid), 3000, 'close');
        assert.equal(closed.reason, 'deleted');
        const r = await upost({ ...copilotHeaders(cid), 'Mcp-Session-Id': sid }, { jsonrpc: '2.0', id: 1, method: 'ping' });
        assert.equal(r.status, 404);
      } finally {
        await client.close();
      }
    });

    test('duplicate X-Copilot-Session-Id: 409 while streaming, takeover once the stream is gone', async () => {
      const cid = crypto.randomUUID();
      const a = await sdkClient('copilot', { headers: copilotHeaders(cid) });
      const sidA = a.transport.sessionId;
      await waitFor(async () => (await fx.cmd('stats')).sessions.copilot.find((s) => s.id === sidA && s.stream_open), 3000, 'stream A');
      let r = await upost(copilotHeaders(cid), INIT(1, '2025-11-25'));
      assert.equal(r.status, 409);
      assert.match(r.body, /A connection for this session already exists/);
      // The CLI loses the IDE without sending DELETE: only its GET stream closes.
      await a.client.close();
      await waitFor(async () => !(await fx.cmd('stats')).sessions.copilot.find((s) => s.id === sidA)?.stream_open, 3000, 'stream A closed');
      const b = await sdkClient('copilot', { headers: copilotHeaders(cid) });
      try {
        assert.notEqual(b.transport.sessionId, sidA);
        const st = await fx.cmd('stats');
        assert.equal(st.session_closes.find((c) => c.id === sidA)?.reason, 'takeover');
        assert.equal(b.transport.protocolVersion, '2025-11-25');
      } finally {
        await b.transport.terminateSession();
        await b.client.close();
      }
    });

    test('DELETE cancels pending calls and ends their POST streams', async () => {
      const cid = crypto.randomUUID();
      let r = await upost(copilotHeaders(cid), INIT(1, '2025-11-25'));
      assert.equal(r.status, 200);
      const sid = r.headers['mcp-session-id'];
      const res = await unixFetch('http://localhost/mcp', {
        method: 'POST',
        headers: { ...copilotHeaders(cid), Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json', 'Mcp-Session-Id': sid },
        body: JSON.stringify({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'block', arguments: { tag: 'del-1' } } }),
      });
      assert.match(res.headers.get('content-type'), /^text\/event-stream/);
      const events = [];
      const reading = (async () => {
        for await (const ev of sseEvents(res.body)) events.push(ev);
      })();
      await waitFor(async () => (await fx.cmd('stats')).started['del-1'], 3000, 'block started');
      r = await rawRequest({ socketPath: fx.pipe, method: 'DELETE', headers: { ...copilotHeaders(cid), Host: 'localhost', 'Mcp-Session-Id': sid } });
      assert.equal(r.status, 200);
      await reading;
      assert.equal(events.filter((e) => e.data).length, 0);
      const s = (await fx.cmd('stats')).cancelled['del-1'];
      assert.deepEqual(s, { reason: 'session_closed', detail: 'deleted' });
      r = await rawRequest({ socketPath: fx.pipe, method: 'DELETE', headers: { ...copilotHeaders(cid), Host: 'localhost', 'Mcp-Session-Id': sid } });
      assert.equal(r.status, 404);
      r = await rawRequest({ socketPath: fx.pipe, method: 'DELETE', headers: { ...copilotHeaders(cid), Host: 'localhost' } });
      assert.equal(r.status, 400);
    });
  });

  // --- Forced response modes ---------------------------------------------------------------
  describe('response modes', () => {
    test("'sse' answers even sync requests as an event stream", async () => {
      const r = await rawRequest({
        port: fx.sse_port,
        headers: { Authorization: `Bearer ${fx.token}`, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' },
        body: INIT(),
      });
      assert.equal(r.status, 200);
      assert.match(r.headers['content-type'], /^text\/event-stream/);
      assert.ok(r.headers['mcp-session-id']);
      assert.match(r.body, /^event: message\ndata: \{.*"protocolVersion":"2025-06-18"/);
      const { client } = await sdkClient('sse');
      try {
        assert.equal((await client.callTool({ name: 'echo', arguments: { text: 's' } })).content[0].text, 's');
        assert.equal((await client.callTool({ name: 'sleep', arguments: { ms: 150 } })).content[0].text, 'slept 150');
      } finally {
        await client.close();
      }
    });

    test("'json' waits for async answers and replies with JSON", async () => {
      const { client } = await sdkClient('json');
      try {
        assert.equal((await client.callTool({ name: 'sleep', arguments: { ms: 200 } })).content[0].text, 'slept 200');
        const got = [];
        // Progress notifications fall back to the GET stream in JSON mode.
        const r = await client.callTool({ name: 'progress', arguments: { steps: 2, ms: 30 } }, undefined, { onprogress: (p) => got.push(p) });
        assert.equal(r.content[0].text, 'progressed 2');
        await waitFor(() => got.length === 2, 2000, 'progress via GET stream');
      } finally {
        await client.close();
      }
      const r = await rawRequest({
        port: fx.json_port,
        headers: { Authorization: `Bearer ${fx.token}`, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json' },
        body: INIT(),
      });
      const sid = r.headers['mcp-session-id'];
      const t0 = Date.now();
      const r2 = await rawRequest({
        port: fx.json_port,
        headers: { Authorization: `Bearer ${fx.token}`, Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json', 'Mcp-Session-Id': sid },
        body: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'sleep', arguments: { ms: 200 } } },
      });
      assert.ok(Date.now() - t0 >= 150);
      assert.match(r2.headers['content-type'], /^application\/json/);
    });
  });

  // --- Shutdown --------------------------------------------------------------------------
  describe('shutdown', () => {
    test('quit ends open streams gracefully and removes the socket', async () => {
      const sid = await rawSession();
      const res = await fetch(gemini.url(), { headers: { ...gemini.headers(), Accept: 'text/event-stream', 'Mcp-Session-Id': sid } });
      const it = sseEvents(res.body)[Symbol.asyncIterator]();
      await it.next();
      assert.ok(existsSync(fx.pipe));
      fx.proc.stdin.write('quit\n');
      for (;;) {
        const x = await it.next();
        if (x.done) break;
      }
      await fx.exited;
      assert.equal(existsSync(fx.pipe), false);
      assert.equal(existsSync(path.dirname(fx.pipe)), false);
    });
  });
});
