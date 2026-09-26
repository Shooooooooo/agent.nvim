// Real-client tests for lua/agent/net/{http,websocket}.lua, served by a headless Neovim
// (tests/node/fixtures/net_server.lua). Run: cd tests/node && node --test net.test.mjs
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, statSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { Agent, fetch as ufetch } from 'undici';
import WS from 'ws';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const FIXTURE = path.join(import.meta.dirname, 'fixtures', 'net_server.lua');
const TOKEN = 'test-token-0123456789';
const NVIM = process.env.NVIM_BIN || 'nvim';

const sha1 = (data) => crypto.createHash('sha1').update(data).digest('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Spawn the fixture server; resolves once it prints its addresses. */
async function startServer() {
  // Short base dir: the socket path must fit in sun_path (104 bytes on macOS).
  const base = process.platform === 'darwin' || process.platform === 'linux' ? '/tmp' : tmpdir();
  const dir = mkdtempSync(path.join(existsSync(base) ? base : tmpdir(), 'anet-'));
  const sock = path.join(dir, 'sub', 'm.sock');
  const env = { ...process.env, XDG_STATE_HOME: path.join(dir, 'state') };
  delete env.NVIM;
  const proc = spawn(NVIM, ['--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', FIXTURE, ROOT, sock, TOKEN], {
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
    sock,
    proc,
    nextLine,
    base: `http://127.0.0.1:${info.http_port}`,
    ws: `ws://127.0.0.1:${info.ws_port}/`,
    send: (cmd) => proc.stdin.write(cmd + '\n'),
    async stop() {
      if (proc.exitCode === null) {
        proc.stdin.write('quit\n');
        proc.stdin.end();
        const t = setTimeout(() => proc.kill('SIGKILL'), 3000);
        await exited;
        clearTimeout(t);
      }
      rmSync(dir, { recursive: true, force: true });
      if (stderr.trim()) console.error('[fixture stderr]', stderr.trim());
    },
  };
}

/** A ReadableStream body; undici sends it with Transfer-Encoding: chunked. */
function streamBody(parts) {
  let i = 0;
  return new ReadableStream({
    pull(controller) {
      if (i < parts.length) controller.enqueue(new TextEncoder().encode(parts[i++]));
      else controller.close();
    },
  });
}

/** Minimal SSE parser over a fetch response body. */
async function* sseEvents(body) {
  const decoder = new TextDecoder();
  let buf = '';
  for await (const chunk of body) {
    buf += decoder.decode(chunk, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const ev = { event: 'message', data: [], id: undefined, comments: [] };
      for (const line of block.split('\n')) {
        if (line.startsWith(':')) ev.comments.push(line.slice(1).trim());
        else if (line.startsWith('data:')) ev.data.push(line.slice(5).replace(/^ /, ''));
        else if (line.startsWith('event:')) ev.event = line.slice(6).trim();
        else if (line.startsWith('id:')) ev.id = line.slice(3).trim();
      }
      yield { ...ev, data: ev.data.join('\n') };
    }
  }
}

async function waitFor(fn, ms = 3000, what = 'condition') {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timeout waiting for ' + what);
    await sleep(25);
  }
}

describe('agent.net servers against real clients', { timeout: 60000 }, () => {
  let srv;
  before(async () => {
    srv = await startServer();
  });
  after(async () => {
    await srv?.stop();
  });

  test('undici fetch over TCP: query, Content-Length and chunked bodies', async () => {
    let r = await fetch(`${srv.base}/echo?a=1&b=two%20words`);
    assert.equal(r.status, 200);
    let j = await r.json();
    assert.equal(j.method, 'GET');
    assert.deepEqual(j.query, { a: '1', b: 'two words' });
    assert.equal(j.transport, 'tcp');
    assert.equal(j.headers.host, `127.0.0.1:${srv.http_port}`);

    r = await fetch(`${srv.base}/echo`, { method: 'POST', body: '{"x":1}', headers: { 'content-type': 'application/json' } });
    j = await r.json();
    assert.equal(j.body, '{"x":1}');
    assert.equal(j.headers['content-length'], '7');

    r = await fetch(`${srv.base}/echo`, { method: 'POST', body: streamBody(['{"a":', '"chunked"', '}']), duplex: 'half' });
    j = await r.json();
    assert.equal(j.body, '{"a":"chunked"}');
    assert.equal(j.headers['transfer-encoding'], 'chunked');
    assert.equal(j.headers['content-length'], undefined);
  });

  test('undici keeps TCP connections alive across requests', async () => {
    const agent = new Agent({ connections: 1 });
    try {
      const ids = [];
      for (let i = 0; i < 5; i++) {
        const r = await ufetch(`${srv.base}/echo`, { method: 'POST', body: 'n' + i, dispatcher: agent });
        ids.push((await r.json()).conn);
      }
      assert.equal(new Set(ids).size, 1, `one connection reused: ${ids}`);
      const big = await ufetch(`${srv.base}/big?size=2000000`, { dispatcher: agent });
      assert.equal((await big.arrayBuffer()).byteLength, 2000000);
      const after = await ufetch(`${srv.base}/echo`, { dispatcher: agent });
      assert.equal((await after.json()).conn, ids[0]);
    } finally {
      await agent.close();
    }
  });

  test('the Unix socket is a 0600 socket in a 0700 directory', () => {
    assert.equal(srv.pipe, srv.sock);
    const st = statSync(srv.sock);
    assert.ok(st.isSocket());
    assert.equal(st.mode & 0o777, 0o600);
    assert.equal(statSync(path.dirname(srv.sock)).mode & 0o777, 0o700);
  });

  test('undici fetch over the Unix socket: chunked bodies and keep-alive', async () => {
    const agent = new Agent({ connect: { socketPath: srv.sock }, connections: 1 });
    try {
      const parts = [];
      for (let i = 0; i < 48; i++) parts.push(String.fromCharCode(97 + (i % 26)).repeat(65536));
      const whole = parts.join('');
      const ids = [];
      let r = await ufetch('http://localhost/echo', {
        method: 'POST',
        body: streamBody(parts),
        duplex: 'half',
        headers: { authorization: 'Nonce abc', 'content-type': 'application/json' },
        dispatcher: agent,
      });
      let j = await r.json();
      assert.equal(j.transport, 'pipe');
      assert.equal(j.headers['transfer-encoding'], 'chunked');
      assert.equal(j.headers.host, 'localhost');
      assert.equal(j.headers.authorization, 'Nonce abc');
      assert.equal(j.body_len, whole.length);
      assert.equal(j.body_sha1, sha1(whole));
      ids.push(j.conn);
      for (let i = 0; i < 3; i++) {
        r = await ufetch('http://localhost/echo', { method: 'POST', body: streamBody(['x', String(i)]), duplex: 'half', dispatcher: agent });
        j = await r.json();
        assert.equal(j.body, 'x' + i);
        ids.push(j.conn);
      }
      assert.equal(new Set(ids).size, 1, `one connection reused: ${ids}`);
    } finally {
      await agent.close();
    }
  });

  test('node:http over the Unix socket (the Copilot CLI client) with chunked bodies and keep-alive', async () => {
    const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
    const request = (body) =>
      new Promise((resolve, reject) => {
        const req = http.request(
          { socketPath: srv.sock, path: '/echo', method: 'POST', agent, headers: { host: 'localhost', 'content-type': 'application/json' } },
          (res) => {
            let data = '';
            res.setEncoding('utf8');
            res.on('data', (d) => (data += d));
            res.on('end', () => resolve({ status: res.statusCode, json: JSON.parse(data) }));
          },
        );
        req.on('error', reject);
        for (const part of body) req.write(part); // no Content-Length -> chunked
        req.end();
      });
    try {
      const a = await request(['{"jsonrpc":', '"2.0","id":1,', '"method":"server/discover"}']);
      const b = await request(['{"jsonrpc":"2.0","method":"notifications/initialized"}']);
      assert.equal(a.status, 200);
      assert.equal(a.json.body, '{"jsonrpc":"2.0","id":1,"method":"server/discover"}');
      assert.equal(a.json.headers['transfer-encoding'], 'chunked');
      assert.equal(a.json.headers['content-length'], undefined);
      assert.equal(b.json.conn, a.json.conn, 'keep-alive reuse');
    } finally {
      agent.destroy();
    }
  });

  for (const transport of ['tcp', 'unix']) {
    test(`SSE over ${transport}: events, multi-line data, comments, and on_close after abort`, async () => {
      const agent = transport === 'unix' ? new Agent({ connect: { socketPath: srv.sock } }) : new Agent();
      const base = transport === 'unix' ? 'http://localhost' : srv.base;
      try {
        const before = await (await ufetch(`${base}/stats`, { dispatcher: agent })).json();
        const ac = new AbortController();
        const r = await ufetch(`${base}/sse?count=3&interval=20`, { dispatcher: agent, signal: ac.signal, headers: { accept: 'text/event-stream' } });
        assert.equal(r.status, 200);
        assert.equal(r.headers.get('content-type'), 'text/event-stream');
        assert.equal(r.headers.get('transfer-encoding'), 'chunked');
        const events = [];
        for await (const ev of sseEvents(r.body)) {
          events.push(ev);
          if (ev.comments.includes('keepalive')) break;
        }
        assert.deepEqual(events[0].comments, ['stream open']);
        const messages = events.filter((e) => e.event === 'message' && e.data);
        assert.deepEqual(messages.map((e) => JSON.parse(e.data).n), [1, 2, 3]);
        const multi = events.find((e) => e.event === 'multi');
        assert.equal(multi.data, 'first line\nsecond line');
        assert.equal(multi.id, 'id-1');
        ac.abort();
        await waitFor(async () => {
          const s = await (await ufetch(`${base}/stats`, { dispatcher: agent })).json();
          return s.sse_closed === before.sse_closed + 1;
        }, 3000, 'server-side res:on_close');
      } finally {
        await agent.close();
      }
    });
  }

  test('a finished SSE stream leaves the connection reusable', async () => {
    const agent = new Agent({ connect: { socketPath: srv.sock }, connections: 1 });
    try {
      const r = await ufetch('http://localhost/sse?count=2&interval=10&end=1', { dispatcher: agent });
      const conn = r.headers.get('x-conn');
      const events = [];
      for await (const ev of sseEvents(r.body)) events.push(ev);
      assert.equal(events.filter((e) => e.event === 'message' && e.data).length, 2);
      const j = await (await ufetch('http://localhost/echo', { dispatcher: agent })).json();
      assert.equal(String(j.conn), conn);
    } finally {
      await agent.close();
    }
  });

  test('concurrent requests on separate connections are not serialized', async () => {
    const agent = new Agent({ connect: { socketPath: srv.sock }, connections: 4 });
    try {
      const t0 = Date.now();
      const rs = await Promise.all([1, 2, 3].map(() => ufetch('http://localhost/slow?ms=400', { dispatcher: agent }).then((r) => r.json())));
      const dt = Date.now() - t0;
      assert.equal(new Set(rs.map((r) => r.conn)).size, 3);
      assert.ok(dt < 1100, `took ${dt} ms`);
    } finally {
      await agent.close();
    }
  });

  test('pipelined raw requests are answered in order on one socket', async () => {
    const sock = net.connect(srv.http_port, '127.0.0.1');
    await new Promise((r) => sock.on('connect', r));
    let data = '';
    sock.setEncoding('latin1');
    sock.on('data', (d) => (data += d));
    sock.write(
      'GET /slow?ms=150 HTTP/1.1\r\nHost: x\r\n\r\n' +
        'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc' +
        'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nxy\r\n0\r\n\r\n',
    );
    await waitFor(() => (data.match(/HTTP\/1\.1 200/g) || []).length === 3 && data.trimEnd().endsWith('}'), 3000, '3 responses');
    sock.destroy();
    const bodies = data.split(/HTTP\/1\.1 200 OK\r\n/).slice(1).map((r) => JSON.parse(r.split('\r\n\r\n')[1]));
    assert.ok('conn' in bodies[0] && !('body' in bodies[0]), 'slow response first');
    assert.equal(bodies[1].body, 'abc');
    assert.equal(bodies[2].body, 'xy');
    assert.equal(bodies[1].conn, bodies[0].conn);
  });

  test('global WebSocket with x-claude-code-ide-authorization and the mcp subprotocol', async () => {
    const ws = new WebSocket(srv.ws, { protocols: ['mcp'], headers: { 'x-claude-code-ide-authorization': TOKEN } });
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = (e) => reject(new Error('ws error ' + e.message));
    });
    assert.equal(ws.protocol, 'mcp');
    assert.equal(ws.extensions, '');
    const next = () => new Promise((r) => (ws.onmessage = (ev) => r(ev.data)));
    let p = next();
    ws.send('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    assert.equal(await p, '{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    p = next();
    ws.send('héllo wörld ✓');
    assert.equal(await p, 'héllo wörld ✓');
    const closed = new Promise((r) => (ws.onclose = r));
    ws.close(1000, 'bye');
    const ev = await closed;
    assert.equal(ev.code, 1000);
    assert.ok(ev.wasClean);
  });

  test('global WebSocket with a wrong token is rejected before opening', async () => {
    const ws = new WebSocket(srv.ws, { protocols: ['mcp'], headers: { 'x-claude-code-ide-authorization': 'wrong-token-000' } });
    let opened = false;
    ws.onopen = () => (opened = true);
    await new Promise((r) => (ws.onclose = r));
    assert.equal(opened, false);
  });

  test('ws package: a >1 MB message, fragmentation, ping/pong, no subprotocol', async () => {
    const ws = new WS(srv.ws, { headers: { 'x-claude-code-ide-authorization': TOKEN } });
    await new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('error', reject);
    });
    assert.equal(ws.protocol, '');
    const next = () => new Promise((r) => ws.once('message', (d, isBinary) => r({ text: d.toString('utf8'), isBinary })));

    const big = JSON.stringify({ jsonrpc: '2.0', id: 7, params: { content: 'ä'.repeat(600000) + 'x'.repeat(1500000) } });
    assert.ok(Buffer.byteLength(big) > 2 * 1024 * 1024);
    let p = next();
    ws.send(big);
    const echoed = await p;
    assert.equal(echoed.isBinary, false);
    assert.equal(echoed.text.length, big.length);
    assert.equal(sha1(echoed.text), sha1(big));

    p = next();
    ws.send('frag-one ', { fin: false });
    ws.send('frag-two ', { fin: false });
    ws.send('frag-three', { fin: true });
    assert.equal((await p).text, 'frag-one frag-two frag-three');

    const pong = new Promise((r) => ws.once('pong', (d) => r(d.toString())));
    ws.ping('are you there');
    assert.equal(await pong, 'are you there');

    p = next();
    ws.send('info');
    assert.deepEqual(JSON.parse((await p).text).protocol, null);

    const closed = new Promise((r) => ws.once('close', (code, reason) => r({ code, reason: reason.toString() })));
    ws.send('close:4001');
    assert.deepEqual(await closed, { code: 4001, reason: 'requested' });
  });

  test('ws package: an Origin header is refused with 403', async () => {
    const ws = new WS(srv.ws, { origin: 'http://evil.example', headers: { 'x-claude-code-ide-authorization': TOKEN } });
    const status = await new Promise((resolve) => {
      ws.once('unexpected-response', (_req, res) => {
        resolve(res.statusCode);
        res.resume();
      });
      ws.once('open', () => resolve('opened'));
      ws.once('error', () => {});
    });
    assert.equal(status, 403);
    ws.terminate();
  });

  test('messages and bodies over the 100 MiB cap get 1009 and 413', async () => {
    const over = 'z'.repeat(100 * 1024 * 1024 + 1);
    const ws = new WS(srv.ws, { headers: { 'x-claude-code-ide-authorization': TOKEN } });
    await new Promise((r) => ws.once('open', r));
    const closed = new Promise((r) => ws.once('close', (code) => r(code)));
    ws.on('error', () => {});
    ws.send(over);
    assert.equal(await closed, 1009);

    const agent = new Agent({ connect: { socketPath: srv.sock } });
    try {
      const r = await ufetch('http://localhost/echo', { method: 'POST', body: over, dispatcher: agent });
      assert.equal(r.status, 413);
      await r.text();
    } finally {
      await agent.close();
    }
  });

  test('the server saw the clients close with their codes', async () => {
    const ws = new WS(srv.ws, { headers: { 'x-claude-code-ide-authorization': TOKEN } });
    await new Promise((r) => ws.once('open', r));
    const p = new Promise((r) => ws.once('message', (d) => r(JSON.parse(d.toString()))));
    ws.send('stats');
    const stats = await p;
    const codes = stats.ws_closes.map((c) => c.code);
    assert.ok(codes.includes(1000), `codes: ${codes}`);
    assert.ok(codes.includes(4001), `codes: ${codes}`);
    ws.close();
  });
});

describe('agent.net server shutdown', { timeout: 30000 }, () => {
  let srv;
  before(async () => {
    srv = await startServer();
  });
  after(async () => {
    await srv?.stop();
  });

  test('server:close() ends SSE streams cleanly, sends 1001 and removes the socket', async () => {
    const agent = new Agent({ connect: { socketPath: srv.sock } });
    const r = await ufetch('http://localhost/sse?count=1&interval=10', { dispatcher: agent });
    const reader = (async () => {
      const events = [];
      for await (const ev of sseEvents(r.body)) events.push(ev);
      return events; // a clean end (terminating chunk) resolves; a reset would throw
    })();
    const ws = new WS(srv.ws, { headers: { 'x-claude-code-ide-authorization': TOKEN } });
    await new Promise((res) => ws.once('open', res));
    const wsClosed = new Promise((res) => ws.once('close', (code, reason) => res({ code, reason: reason.toString() })));
    const keepAlive = new Agent({ connections: 1 });
    await (await ufetch(`${srv.base}/echo`, { dispatcher: keepAlive })).json(); // leaves an idle keep-alive socket

    await sleep(100);
    srv.send('close');
    const closed = JSON.parse(await srv.nextLine());
    assert.equal(closed.closed, true);
    assert.equal(closed.socket_exists, false);

    const events = await reader;
    assert.ok(events.length >= 1);
    assert.deepEqual(await wsClosed, { code: 1001, reason: 'Server shutting down' });
    assert.equal(existsSync(srv.sock), false);
    assert.equal(existsSync(path.dirname(srv.sock)), false, 'the directory created by listen() is removed');
    await assert.rejects(ufetch(`${srv.base}/echo`, { dispatcher: new Agent() }));
    await agent.close();
    await keepAlive.close();
  });
});
