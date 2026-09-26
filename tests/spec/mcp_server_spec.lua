-- Tests for lua/agent/mcp/server.lua (transport-agnostic MCP core) with an in-memory session.
local McpServer = require('agent.mcp.server')

-- Handler bugs are reported through vim.notify (scheduled); capture them instead of printing.
local notified = {}
vim.notify = function(msg)
  table.insert(notified, msg)
end

local function req(id, method, params)
  return { jsonrpc = '2.0', id = id, method = method, params = params }
end

local function note(method, params)
  return { jsonrpc = '2.0', method = method, params = params }
end

-- A server plus one session whose outbound messages are collected (JSON round-tripped, so the
-- tests see exactly what a client would decode).
local function setup(opts)
  local srv = McpServer.new(vim.tbl_extend('force', { name = 'test-server', version = '1.2.3' }, opts or {}))
  local sent, raw = {}, {}
  local closed = {}
  local session = srv:open_session({
    send = function(msg)
      local text = vim.json.encode(msg)
      table.insert(raw, text)
      table.insert(sent, vim.json.decode(text))
      return true
    end,
    info = { kind = 'memory' },
    on_close = function(s, reason)
      table.insert(closed, { s = s, reason = reason })
    end,
  })
  return srv, session, sent, raw, closed
end

local function init(srv, session, version)
  srv:handle(session, req(0, 'initialize', {
    protocolVersion = version or '2025-06-18',
    capabilities = {},
    clientInfo = { name = 'spec-client', version = '0.0.1' },
  }))
end

describe('mcp.server helpers', function()
  it('classifies messages', function()
    assert.eq('request', McpServer.classify(req(1, 'x')))
    assert.eq('request', McpServer.classify(req('a', 'x')))
    assert.eq('notification', McpServer.classify(note('x')))
    assert.eq('response', McpServer.classify({ jsonrpc = '2.0', id = 1, result = {} }))
    assert.eq('response', McpServer.classify({ jsonrpc = '2.0', id = 1, error = { code = 1, message = 'm' } }))
    assert.eq(nil, McpServer.classify({ jsonrpc = '1.0', id = 1, method = 'x' }))
    assert.eq(nil, McpServer.classify({ jsonrpc = '2.0', id = {}, method = 'x' }))
    assert.eq(nil, McpServer.classify({ jsonrpc = '2.0', id = 1, method = 5 }))
    assert.eq(nil, McpServer.classify({ jsonrpc = '2.0', id = 1 }))
    assert.eq(nil, McpServer.classify('x'))
    assert.truthy(McpServer.is_batch({ req(1, 'a') }))
    assert.truthy(McpServer.is_batch({}))
    assert.falsy(McpServer.is_batch(req(1, 'a')))
  end)

  it('negotiates protocol versions', function()
    assert.eq('2025-06-18', McpServer.negotiate_version('2025-06-18', McpServer.SUPPORTED_PROTOCOL_VERSIONS))
    assert.eq('2025-11-25', McpServer.negotiate_version('1999-01-01', McpServer.SUPPORTED_PROTOCOL_VERSIONS))
    assert.eq('2024-11-05', McpServer.negotiate_version(nil, { '2025-03-26' }, '2024-11-05'))
    local p = McpServer.version_policy({ '2025-06-18', '2024-11-05' })
    assert.eq('2024-11-05', p('2024-11-05'))
    assert.eq('2025-06-18', p('2025-11-25'))
  end)

  it('normalizes tool results', function()
    assert.same({ content = {} }, McpServer.tool_result(nil))
    assert.same({ content = { { type = 'text', text = 'hi' } } }, McpServer.tool_result('hi'))
    local r = { content = { { type = 'text', text = 'x' } }, isError = true }
    assert.eq(r, McpServer.tool_result(r))
    assert.same({ isError = true, content = {} }, McpServer.tool_result({ isError = true }))
    -- A plain table is data: JSON text (Copilot style), including a string-valued `content` key.
    local t = McpServer.tool_result({ success = true, n = 1 })
    assert.same({ success = true, n = 1 }, vim.json.decode(t.content[1].text))
    assert.eq('{"content":"abc"}', McpServer.tool_result({ content = 'abc' }).content[1].text)
    assert.eq('null', McpServer.tool_result(vim.NIL).content[1].text)
    assert.eq('{}', McpServer.tool_result(vim.empty_dict()).content[1].text)
    assert.same({ isError = true, content = { { type = 'text', text = 'bad' } } }, McpServer.error_result('bad'))
  end)
end)

describe('mcp.server initialize', function()
  it('answers with version, capabilities and serverInfo', function()
    local srv, session, sent, raw = setup({ title = 'Test', capabilities = { tools = { listChanged = true }, logging = {} } })
    init(srv, session, '2025-06-18')
    assert.eq(1, #sent)
    local r = sent[1]
    assert.eq(0, r.id)
    assert.eq('2.0', r.jsonrpc)
    assert.eq('2025-06-18', r.result.protocolVersion)
    assert.same({ name = 'test-server', version = '1.2.3', title = 'Test' }, r.result.serverInfo)
    assert.same({ listChanged = true }, r.result.capabilities.tools)
    assert.matches('"logging":{}', raw[1])
    assert.truthy(session.initialized)
    assert.falsy(session.ready)
    assert.eq('spec-client', session.client_info.name)
    assert.eq('2025-06-18', session.protocol_version)
  end)

  it('falls back for unknown versions and honors policies', function()
    local srv, session, sent = setup()
    init(srv, session, '2099-01-01')
    assert.eq(McpServer.LATEST_PROTOCOL_VERSION, sent[1].result.protocolVersion)

    srv, session, sent = setup({ protocol_version = '2024-11-05' })
    init(srv, session, '2025-11-25')
    assert.eq('2024-11-05', sent[1].result.protocolVersion)

    srv, session, sent = setup({ protocol_version = { '2025-06-18', '2025-03-26' } })
    init(srv, session, '2025-03-26')
    assert.eq('2025-03-26', sent[1].result.protocolVersion)

    srv, session, sent = setup({ protocol_version = { supported = { '2025-06-18' }, fallback = '2024-11-05' } })
    init(srv, session, '2025-11-25')
    assert.eq('2024-11-05', sent[1].result.protocolVersion)

    local seen
    srv, session, sent = setup({
      protocol_version = function(requested, s)
        seen = { requested, s }
        return 'custom'
      end,
    })
    init(srv, session, '2025-11-25')
    assert.eq('custom', sent[1].result.protocolVersion)
    assert.eq('2025-11-25', seen[1])
    assert.eq(session, seen[2])
  end)

  it('lets on_initialize adjust or reject the handshake', function()
    local srv, session, sent = setup({
      on_initialize = function(s, params, result)
        s.data.kind = params.clientInfo.name
        result.instructions = 'hello'
        return { serverInfo = { name = 'per-client', version = '9' } }
      end,
    })
    init(srv, session)
    assert.eq('spec-client', session.data.kind)
    assert.eq('hello', sent[1].result.instructions)
    assert.eq('per-client', sent[1].result.serverInfo.name)

    srv, session, sent = setup({
      on_initialize = function()
        error(McpServer.rpc_error(-32000, 'go away', { why = 1 }))
      end,
    })
    init(srv, session)
    assert.same({ code = -32000, message = 'go away', data = { why = 1 } }, sent[1].error)
    assert.falsy(session.initialized)
  end)
end)

describe('mcp.server dispatch', function()
  it('answers ping with an object, unknown methods with -32601', function()
    local srv, session, sent, raw = setup()
    srv:handle(session, req(7, 'ping'))
    assert.eq(7, sent[1].id)
    assert.matches('"result":{}', raw[1])
    srv:handle(session, req('s-1', 'resources/list'))
    assert.eq('s-1', sent[2].id)
    assert.eq(-32601, sent[2].error.code)
    assert.eq('Method not found', sent[2].error.message)
    assert.eq('Unknown method: resources/list', sent[2].error.data)
  end)

  it('handles notifications without answering them', function()
    local seen = {}
    local srv, session, sent = setup({
      on_notification = function(s, method, params)
        table.insert(seen, { s = s, method = method, params = params })
      end,
    })
    init(srv, session)
    srv:handle(session, note('notifications/initialized'))
    srv:handle(session, note('ide_connected', { pid = 42 }))
    srv:handle(session, note('something/unknown'))
    assert.eq(1, #sent) -- only the initialize response
    assert.truthy(session.ready)
    assert.eq(3, #seen)
    assert.eq('ide_connected', seen[2].method)
    assert.eq(42, seen[2].params.pid)
    assert.eq(session, seen[1].s)
  end)

  it('rejects malformed requests that carry an id and drops the rest', function()
    local srv, session, sent = setup()
    srv:handle(session, { jsonrpc = '2.0', id = 3 })
    assert.eq(-32600, sent[1].error.code)
    assert.eq(3, sent[1].id)
    srv:handle(session, { foo = 'bar' })
    srv:handle(session, { jsonrpc = '1.0', method = 'x' })
    assert.eq(1, #sent)
    srv:handle(session, req(4, 'ping', 'not-an-object'))
    assert.eq(-32602, sent[2].error.code)
  end)

  it('a message with "id": null is an invalid request, not a notification', function()
    local seen = {}
    local srv, session, sent = setup({
      on_notification = function(_, method)
        table.insert(seen, method)
      end,
    })
    init(srv, session)
    local ok, msg = McpServer.decode('{"jsonrpc":"2.0","id":null,"method":"notifications/initialized"}')
    assert.truthy(ok)
    assert.eq(vim.NIL, msg.id)
    assert.eq(nil, McpServer.classify(msg))
    srv:handle_json(session, '{"jsonrpc":"2.0","id":null,"method":"notifications/initialized"}')
    assert.falsy(session.ready)
    assert.same({}, seen)
    srv:handle_json(session, '[{"jsonrpc":"2.0","id":null,"method":"ping"},{"jsonrpc":"2.0","id":1,"method":"ping"}]')
    assert.eq(2, #sent)
    assert.eq(1, #sent[2])
    assert.eq(1, sent[2][1].id)
    -- Other nulls still decode to nil; a missing id is still a notification.
    ok, msg = McpServer.decode('{"jsonrpc":"2.0","method":"n","params":{"a":null,"b":[null,1]}}')
    assert.truthy(ok)
    assert.eq('notification', McpServer.classify(msg))
    assert.eq(nil, msg.params.a)
    assert.eq(1, msg.params.b[2])
    ok, msg = McpServer.decode('[{"jsonrpc":"2.0","method":"n","params":{"a":null}},{"jsonrpc":"2.0","id":null,"method":"p"}]')
    assert.eq('notification', McpServer.classify(msg[1]))
    assert.eq(nil, McpServer.classify(msg[2]))
    assert.same({ false }, { (McpServer.decode('{nope')) })
  end)

  it('refuses a duplicate id while the first request is pending', function()
    local srv, session, sent = setup()
    srv:add_tool({ name = 'wait', async = true, handler = function() end })
    srv:handle(session, req(1, 'tools/call', { name = 'wait' }))
    srv:handle(session, req(1, 'ping'))
    assert.eq(1, #sent)
    assert.eq(-32600, sent[1].error.code)
    -- The same number as a string is a different id.
    srv:handle(session, req('1', 'ping'))
    assert.eq('1', sent[2].id)
  end)

  it('drops unparseable JSON text', function()
    local srv, session, sent = setup()
    local d, err = srv:handle_json(session, '{nope')
    assert.eq(nil, d)
    assert.eq('parse error', err)
    assert.eq(0, #sent)
    srv:handle_json(session, '{"jsonrpc":"2.0","id":0,"method":"ping"}')
    assert.eq(0, sent[1].id)
  end)

  it('answers a batch with one array once every request settled', function()
    local srv, session, sent = setup()
    local later
    srv:add_tool({
      name = 'later',
      async = true,
      handler = function(_, _, respond)
        later = respond
      end,
    })
    srv:handle(session, {
      req(1, 'ping'),
      note('notifications/initialized'),
      req(2, 'tools/call', { name = 'later' }),
      { jsonrpc = '2.0', id = 3 },
      { bogus = true },
    })
    assert.eq(0, #sent)
    later('done')
    assert.eq(1, #sent)
    local arr = sent[1]
    assert.eq(3, #arr)
    local by_id = {}
    for _, r in ipairs(arr) do
      by_id[r.id] = r
    end
    assert.truthy(by_id[1].result)
    assert.eq('done', by_id[2].result.content[1].text)
    assert.eq(-32600, by_id[3].error.code)
    -- Empty batch and notification-only batch: nothing to send.
    srv:handle(session, {})
    srv:handle(session, { note('a'), note('b') })
    assert.eq(1, #sent)
  end)

  it('routes responses through on_response / on_done when given', function()
    local srv, session, sent = setup()
    local got, done = {}, nil
    local d = srv:handle(session, { req(1, 'ping'), req(2, 'tools/list') }, {
      on_response = function(r)
        table.insert(got, r)
      end,
      on_done = function(responses)
        done = responses
      end,
    })
    assert.eq(0, #sent)
    assert.eq(2, #got)
    assert.eq(2, #done)
    assert.truthy(d.done)
    assert.eq(2, d.total)
    local only_done
    srv:handle(session, note('x'), {
      on_done = function(r)
        only_done = r
      end,
    })
    assert.same({}, only_done)
  end)

  it('supports custom methods, sync and async, overriding built-ins', function()
    local srv, session, sent = setup()
    srv:add_method('prompts/list', function()
      return { prompts = {} }
    end)
    local pending
    srv:add_method('slow/echo', function(params, _, respond)
      pending = function()
        respond({ echo = params.v })
      end
    end, { async = true })
    srv:add_method('ping', function()
      return { custom = true }
    end)
    srv:handle(session, req(1, 'prompts/list'))
    srv:handle(session, req(2, 'slow/echo', { v = 'x' }))
    srv:handle(session, req(3, 'ping'))
    assert.same({ prompts = {} }, sent[1].result)
    assert.eq(3, sent[2].id)
    assert.same({ custom = true }, sent[2].result)
    pending()
    assert.same({ echo = 'x' }, sent[3].result)
  end)
end)

describe('mcp.server tools', function()
  it('lists visible tools in order with object schemas', function()
    local srv, session, sent, raw = setup()
    srv:add_tool({ name = 'b', description = 'B', inputSchema = { type = 'object', properties = {} }, handler = function() end })
    srv:add_tool({
      name = 'a',
      description = 'A',
      inputSchema = { type = 'object', properties = { x = { type = 'string' } }, required = { 'x' } },
      execution = { taskSupport = 'forbidden' },
      handler = function() end,
    })
    srv:add_tool({ name = 'hidden', hidden = true, handler = function() end })
    srv:add_tool({
      name = 'maybe',
      hidden = function(s)
        return s.data.hide_maybe
      end,
      handler = function() end,
    })
    srv:add_tool({ name = 'noschema', handler = function() end })
    srv:handle(session, req(1, 'tools/list'))
    local names = vim.tbl_map(function(t)
      return t.name
    end, sent[1].result.tools)
    assert.same({ 'b', 'a', 'maybe', 'noschema' }, names)
    assert.matches('"properties":{}', raw[1])
    assert.falsy(raw[1]:find('"properties":%[%]'))
    local a = sent[1].result.tools[2]
    assert.same({ taskSupport = 'forbidden' }, a.execution)
    assert.eq(nil, a.handler)
    assert.eq('object', sent[1].result.tools[4].inputSchema.type)
    session.data.hide_maybe = true
    assert.eq(3, #srv:list_tools(session))
    -- Replacing keeps the position; removing drops it.
    srv:add_tool({ name = 'b', description = 'B2', handler = function() end })
    assert.eq('B2', srv:list_tools(session)[1].description)
    assert.truthy(srv:remove_tool('b'))
    assert.falsy(srv:remove_tool('b'))
    assert.eq('a', srv:list_tools(session)[1].name)
  end)

  it('calls sync tools and normalizes their results', function()
    local srv, session, sent = setup()
    local seen_ctx
    srv:add_tool({
      name = 'echo',
      inputSchema = { type = 'object', properties = { text = { type = 'string' } }, required = { 'text' } },
      handler = function(args, ctx)
        seen_ctx = ctx
        return args.text
      end,
    })
    srv:add_tool({ name = 'data', handler = function() return { success = true } end })
    srv:add_tool({ name = 'nothing', handler = function() end })
    srv:add_tool({ name = 'hidden', hidden = true, handler = function() return 'secret' end })
    srv:handle(session, req(1, 'tools/call', { name = 'echo', arguments = { text = 'hi' }, _meta = { progressToken = 5 } }))
    assert.same({ content = { { type = 'text', text = 'hi' } } }, sent[1].result)
    assert.eq('echo', seen_ctx.tool)
    assert.eq(1, seen_ctx.request_id)
    assert.eq(session, seen_ctx.session)
    assert.eq(5, seen_ctx.progress_token)
    srv:handle(session, req(2, 'tools/call', { name = 'data' }))
    assert.eq('{"success":true}', sent[2].result.content[1].text)
    srv:handle(session, req(3, 'tools/call', { name = 'nothing', arguments = {} }))
    assert.same({}, sent[3].result.content)
    srv:handle(session, req(4, 'tools/call', { name = 'hidden' }))
    assert.eq('secret', sent[4].result.content[1].text)
  end)

  it('reports protocol errors for bad calls and handler failures', function()
    local srv, session, sent = setup()
    srv:add_tool({
      name = 'need',
      inputSchema = { type = 'object', properties = { path = { type = 'string' } }, required = { 'path' } },
      handler = function() return 'ok' end,
    })
    srv:add_tool({
      name = 'lax',
      validate = false,
      inputSchema = { type = 'object', properties = { path = { type = 'string' } }, required = { 'path' } },
      handler = function() return 'ok' end,
    })
    srv:add_tool({
      name = 'rpcfail',
      handler = function()
        error({ code = -32000, message = 'Cannot create diff', data = 'dirty' })
      end,
    })
    srv:add_tool({
      name = 'boom',
      handler = function()
        error('kaboom', 0)
      end,
    })
    srv:add_tool({ name = 'soft', handler = function() return McpServer.error_result('nope') end })
    notified = {}
    srv:handle(session, req(1, 'tools/call', { name = 'missing' }))
    srv:handle(session, req(2, 'tools/call', {}))
    srv:handle(session, req(3, 'tools/call', { name = 'need', arguments = {} }))
    srv:handle(session, req(4, 'tools/call', { name = 'need', arguments = 'x' }))
    srv:handle(session, req(5, 'tools/call', { name = 'lax' }))
    srv:handle(session, req(6, 'tools/call', { name = 'rpcfail' }))
    srv:handle(session, req(7, 'tools/call', { name = 'boom' }))
    srv:handle(session, req(8, 'tools/call', { name = 'soft' }))
    -- Only the plain Lua error (a bug) is reported to the user, not the intentional rpc error.
    wait_for(function()
      return #notified > 0
    end, 1000)
    vim.wait(20)
    assert.eq(1, #notified)
    assert.matches('kaboom', notified[1])
    assert.eq(-32602, sent[1].error.code)
    assert.eq('Unknown tool: missing', sent[1].error.message)
    assert.eq(-32602, sent[2].error.code)
    assert.eq(-32602, sent[3].error.code)
    assert.matches('path', sent[3].error.message)
    assert.eq(-32602, sent[4].error.code)
    assert.eq('ok', sent[5].result.content[1].text)
    assert.same({ code = -32000, message = 'Cannot create diff', data = 'dirty' }, sent[6].error)
    assert.eq(-32603, sent[7].error.code)
    assert.matches('kaboom', sent[7].error.message)
    assert.truthy(sent[8].result.isError)
    assert.eq(0, session:pending_count())
  end)

  it('answers async tools later, once', function()
    local srv, session, sent = setup()
    srv:add_tool({
      name = 'sleep',
      async = true,
      handler = function(args, _, respond)
        vim.defer_fn(function()
          assert.truthy(respond('slept ' .. args.ms))
          assert.falsy(respond('again'))
        end, args.ms)
      end,
    })
    srv:add_tool({
      name = 'fails',
      async = true,
      handler = function(_, _, respond)
        vim.schedule(function()
          respond(nil, McpServer.rpc_error(-32000, 'later failure'))
        end)
      end,
    })
    srv:add_tool({
      name = 'throws',
      async = true,
      handler = function()
        error(McpServer.rpc_error(-32001, 'sync throw'))
      end,
    })
    srv:handle(session, req(1, 'tools/call', { name = 'sleep', arguments = { ms = 30 } }))
    srv:handle(session, req(2, 'tools/call', { name = 'fails' }))
    srv:handle(session, req(3, 'tools/call', { name = 'throws' }))
    assert.eq(1, #sent)
    assert.eq(-32001, sent[1].error.code)
    assert.eq(2, session:pending_count())
    wait_for(function()
      return #sent == 3
    end, 2000)
    assert.eq(-32000, sent[2].error.code)
    assert.eq('slept 30', sent[3].result.content[1].text)
    assert.eq(0, session:pending_count())
  end)
end)

describe('mcp.server cancellation', function()
  local function blocking(srv, record)
    srv:add_tool({
      name = 'block',
      async = true,
      handler = function(args, ctx, respond)
        record[args.tag] = { ctx = ctx, respond = respond }
        ctx.on_cancel(function(reason, detail)
          record[args.tag].reason = reason
          record[args.tag].detail = detail
          -- Answering from a cancel callback must not produce a response.
          record[args.tag].late = respond('too late')
        end)
      end,
    })
  end

  it('cancels on notifications/cancelled without answering', function()
    local srv, session, sent = setup()
    local rec = {}
    blocking(srv, rec)
    srv:handle(session, req(10, 'tools/call', { name = 'block', arguments = { tag = 'a' } }))
    srv:handle(session, req(11, 'tools/call', { name = 'block', arguments = { tag = 'b' } }))
    assert.eq(2, session:pending_count())
    assert.eq('block', session:pending_requests()[1].tool)
    srv:handle(session, note('notifications/cancelled', { requestId = 10, reason = 'user aborted' }))
    assert.eq('cancelled', rec.a.reason)
    assert.eq('user aborted', rec.a.detail)
    assert.falsy(rec.a.late)
    assert.truthy(rec.a.ctx.cancelled)
    assert.eq('cancelled', rec.a.ctx.cancel_reason)
    assert.falsy(rec.a.ctx.is_active())
    assert.falsy(rec.a.respond('after'))
    assert.eq(0, #sent)
    assert.eq(nil, rec.b.reason)
    assert.eq(1, session:pending_count())
    -- Unknown ids are ignored; registering on_cancel after the fact runs at once.
    srv:handle(session, note('notifications/cancelled', { requestId = 999 }))
    local ran
    rec.a.ctx.on_cancel(function(reason)
      ran = reason
    end)
    assert.eq('cancelled', ran)
    assert.truthy(rec.b.respond('fine'))
    assert.eq('fine', sent[1].result.content[1].text)
  end)

  it('never cancels initialize', function()
    local srv, session = setup()
    srv:add_method('initialize', function() end, { async = true })
    srv:handle(session, req(0, 'initialize', {}))
    assert.falsy(srv:cancel_request(session, 0))
  end)

  it('cancels pending requests when the session closes', function()
    local closes = {}
    local srv, session, sent, _, transport_closed = setup({
      on_session_close = function(s, reason)
        table.insert(closes, { s = s, reason = reason })
      end,
    })
    local rec = {}
    blocking(srv, rec)
    init(srv, session)
    srv:handle(session, req(1, 'tools/call', { name = 'block', arguments = { tag = 'x' } }))
    local failed
    srv:request(session, 'roots/list', nil, function(_, err)
      failed = err
    end)
    srv:close_session(session, 'deleted')
    assert.eq('session_closed', rec.x.reason)
    assert.eq('deleted', rec.x.detail)
    assert.eq(-32000, failed.code)
    assert.eq(1, #closes)
    assert.eq('deleted', closes[1].reason)
    assert.eq('deleted', transport_closed[1].reason)
    assert.truthy(session.closed)
    assert.same({}, srv:sessions())
    -- Closed sessions ignore input and output.
    local before = #sent
    assert.eq(nil, srv:handle(session, req(2, 'ping')))
    assert.falsy(srv:notify(session, 'x'))
    assert.eq(before, #sent)
    srv:close_session(session, 'again')
    assert.eq(1, #closes)
  end)

  it('cancels a dispatch on transport disconnect', function()
    local srv, session, sent = setup()
    local rec = {}
    blocking(srv, rec)
    local done
    local d = srv:handle(session, { req(1, 'tools/call', { name = 'block', arguments = { tag = 'p' } }), req(2, 'ping') }, {
      on_response = function() end,
      on_done = function(r)
        done = r
      end,
    })
    assert.eq(1, d.pending)
    d:cancel('disconnect')
    assert.eq('disconnect', rec.p.reason)
    assert.eq(1, #done) -- only the ping answer
    assert.eq(0, #sent)
    assert.eq(0, session:pending_count())
  end)
end)

describe('mcp.server notifications and requests', function()
  it('only notifies initialized sessions', function()
    local srv, session, sent, raw = setup()
    assert.falsy(srv:notify(session, 'selection_changed', { a = 1 }))
    assert.truthy(srv:notify(session, 'early', nil, { force = true }))
    init(srv, session)
    assert.truthy(session:notify('selection_changed', { text = 'x' }))
    assert.truthy(srv:notify(session, 'empty', {}))
    local names = vim.tbl_map(function(m)
      return m.method or 'response'
    end, sent)
    assert.same({ 'early', 'response', 'selection_changed', 'empty' }, names)
    assert.matches('"params":{}', raw[4])
    assert.eq(nil, sent[3].id)
  end)

  it('broadcasts to initialized sessions that pass the filter', function()
    local srv = McpServer.new({ name = 'n', version = '1' })
    local got = {}
    local function open(tag)
      return srv:open_session({
        send = function(m)
          table.insert(got, tag .. ':' .. (m.method or 'response'))
        end,
      })
    end
    local s1, s2, s3 = open('s1'), open('s2'), open('s3')
    init(srv, s1)
    init(srv, s2)
    assert.same({ s1, s2, s3 }, srv:sessions())
    assert.eq(s2, srv:get_session(s2.id))
    got = {}
    assert.eq(2, srv:broadcast('ping/all', { x = 1 }))
    assert.eq(1, srv:broadcast('ping/one', nil, function(s)
      return s == s2
    end))
    assert.same({ 's1:ping/all', 's2:ping/all', 's2:ping/one' }, got)
    srv:close()
    assert.same({}, srv:sessions())
    assert.truthy(s3.closed)
  end)

  it('routes related notifications (progress) through on_notify', function()
    local srv, session, sent = setup()
    init(srv, session)
    srv:add_tool({
      name = 'work',
      handler = function(_, ctx)
        ctx.progress(1, 2, 'half')
        ctx.notify('custom/related', { k = 'v' })
        return 'ok'
      end,
    })
    local related = {}
    srv:handle(session, req(1, 'tools/call', { name = 'work', _meta = { progressToken = 'tok' } }), {
      on_notify = function(n)
        table.insert(related, n)
        return true
      end,
      on_response = function() end,
    })
    assert.eq(2, #related)
    assert.same({ progressToken = 'tok', progress = 1, total = 2, message = 'half' }, related[1].params)
    assert.eq('custom/related', related[2].method)
    -- Without on_notify they fall back to the session; without a token progress is a no-op.
    srv:handle(session, req(2, 'tools/call', { name = 'work', _meta = { progressToken = 3 } }))
    srv:handle(session, req(3, 'tools/call', { name = 'work' }))
    local methods = vim.tbl_map(function(m)
      return m.method or ('id' .. tostring(m.id))
    end, sent)
    assert.same({ 'id0', 'notifications/progress', 'custom/related', 'id2', 'custom/related', 'id3' }, methods)
  end)

  it('sends server->client requests and matches responses', function()
    local srv, session, sent = setup()
    init(srv, session)
    local result, err
    local id = srv:request(session, 'roots/list', {}, function(r, e)
      result, err = r, e
    end)
    assert.eq('roots/list', sent[2].method)
    assert.eq(id, sent[2].id)
    srv:handle(session, { jsonrpc = '2.0', id = id, result = { roots = {} } })
    assert.same({ roots = {} }, result)
    assert.eq(nil, err)
    -- Unknown responses are ignored, errors are passed through.
    srv:handle(session, { jsonrpc = '2.0', id = 12345, result = {} })
    local id2 = srv:request(session, 'x', nil, function(r, e)
      result, err = r, e
    end)
    srv:handle(session, { jsonrpc = '2.0', id = id2, error = { code = -1, message = 'no' } })
    assert.eq(nil, result)
    assert.eq('no', err.message)
    -- Timeout.
    local timed_out
    srv:request(session, 'slow', nil, function(_, e)
      timed_out = e
    end, { timeout_ms = 20 })
    wait_for(function()
      return timed_out ~= nil
    end, 1000)
    assert.eq(-32001, timed_out.code)
  end)

  it('reports send failures from the transport', function()
    local srv = McpServer.new({ name = 'n', version = '1' })
    local s = srv:open_session({
      send = function()
        return false
      end,
    })
    init(srv, s)
    assert.falsy(srv:notify(s, 'x'))
    local s2 = srv:open_session({
      send = function()
        error('socket gone')
      end,
    })
    s2.initialized = true
    assert.falsy(srv:notify(s2, 'x'))
  end)
end)
