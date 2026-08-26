local assert = require("tests.helpers.assertions")
local session = require("partial_completion.session")

local function item(id, source)
  return {
    id = id,
    label = id,
    insert_text = id,
    source = source or "test",
  }
end

local function request(query)
  return {
    category = "generic",
    query = query,
    source_text = query,
    cursor_byte = #query,
    replacement = { start_byte = 0, end_byte = #query },
  }
end

return {
  {
    name = "session renders streaming snapshots and preserves stable selection",
    run = function()
      local callback
      local events = {}
      local active = session.new({
        complete = function(_, update)
          callback = update
          return { cancel = function() end }
        end,
        on_change = function(state, event)
          events[#events + 1] = { state = state, event = event }
        end,
      })
      active:start(request("a"))
      callback({
        request_id = 10,
        generation = 20,
        replacement = { start_byte = 0, end_byte = 1 },
        items = { item("alpha"), item("alpine") },
        done = false,
      })
      assert.same("alpha", active:selected_item().id)
      active:select("alpine", "test")
      callback({
        request_id = 10,
        generation = 20,
        replacement = { start_byte = 0, end_byte = 1 },
        items = { item("atlas"), item("alpine"), item("alpha") },
        done = false,
        is_incomplete = true,
      })
      assert.same("alpine", active:selected_item().id)
      assert.truthy(active:snapshot().is_incomplete)

      callback({ request_id = 11, generation = 20, items = { item("wrong") }, done = true })
      assert.same(3, #active:snapshot().items)
      callback({
        request_id = 10,
        generation = 20,
        replacement = { start_byte = 1, end_byte = 1 },
        items = { item("wrong-range") },
        done = true,
      })
      assert.same(3, #active:snapshot().items)
      assert.same("update", events[#events].event)
    end,
  },
  {
    name = "session replacement cancellation acceptance and close are idempotent",
    run = function()
      local callbacks = {}
      local cancel_count = 0
      local closes = {}
      local active = session.new({
        complete = function(_, update)
          callbacks[#callbacks + 1] = update
          return {
            cancel = function()
              cancel_count = cancel_count + 1
            end,
          }
        end,
        on_close = function(state, reason)
          closes[#closes + 1] = { status = state.status, reason = reason }
        end,
      })

      active:start(request("a"))
      active:start(request("b"))
      assert.same(1, cancel_count)
      callbacks[1]({ request_id = 1, generation = 1, items = { item("late") }, done = true })
      assert.same({}, active:snapshot().items)
      callbacks[2]({ request_id = 2, generation = 2, items = { item("beta") }, done = true })
      local result = active:accept(function(selected, state)
        return { inserted = selected.insert_text, generation = state.generation }
      end)
      assert.same("beta", result.inserted)
      assert.same("accepted", active:snapshot().status)
      assert.same(2, cancel_count)
      active:cancel()
      active:close()
      assert.same(2, cancel_count)
      assert.same({
        { status = "cancelled", reason = "replaced" },
        { status = "accepted", reason = "accepted" },
      }, closes)
    end,
  },
  {
    name = "session supports explicit no-selection adapter policy",
    run = function()
      local callback
      local active = session.new({
        select_first = false,
        complete = function(_, update)
          callback = update
          return { cancel = function() end }
        end,
      })
      active:start(request("a"))
      callback({ request_id = 1, generation = 1, items = { item("alpha") }, done = true })
      assert.same(nil, active:selected_item())
      local result, err = active:accept(function()
        return true
      end)
      assert.same(nil, result)
      assert.same("no_selection", err)
      assert.same("alpha", active:select_next(1).id)
      active:close("adapter_closed")
      assert.same("closed", active:snapshot().status)
    end,
  },
  {
    name = "explicit acceptance resolves only current stable item identities",
    run = function()
      local callbacks = {}
      local active = session.new({
        complete = function(_, update)
          callbacks[#callbacks + 1] = update
          return { cancel = function() end }
        end,
      })

      active:start(request("old"))
      callbacks[1]({
        request_id = 1,
        generation = 1,
        items = { item("old") },
        done = true,
      })
      local old_item = active:snapshot().items[1]

      active:start(request("new"))
      callbacks[2]({
        request_id = 2,
        generation = 2,
        items = {
          { id = "same", source = "one", label = "same", insert_text = "CURRENT-ONE" },
          { id = "same", source = "two", label = "same", insert_text = "CURRENT-TWO" },
        },
        done = true,
      })

      local result, err = active:accept(function()
        return true
      end, old_item)
      assert.same(nil, result)
      assert.same("invalid_item", err)

      local accepted = active:accept(function(selected)
        return { insert_text = selected.insert_text, source = selected.source }
      end, { id = "same", source = "two", insert_text = "FORGED" })
      assert.same({ insert_text = "CURRENT-TWO", source = "two" }, accepted)
      assert.same("accepted", active:snapshot().status)
    end,
  },
  {
    name = "session isolates canonical items from public mutation paths",
    run = function()
      local callback
      local active
      active = session.new({
        complete = function(_, update)
          callback = update
          return { cancel = function() end }
        end,
        on_change = function(state, event, update)
          if event == "update" then
            state.items[1].insert_text = "FORGED-STATE"
            update.items[1].insert_text = "FORGED-UPDATE"
          end
        end,
      })
      active:start(request("safe"))
      local emitted = {
        request_id = 1,
        generation = 1,
        items = { { id = "safe", source = "test", label = "safe", insert_text = "SAFE" } },
        done = true,
      }
      callback(emitted)
      emitted.items[1].insert_text = "FORGED-EMITTER"

      local selected = active:selected_item()
      selected.insert_text = "FORGED-SELECTED"
      local selected_again = active:select(1)
      selected_again.insert_text = "FORGED-SELECT"

      local accepted = active:accept(function(item_value)
        local insertion = item_value.insert_text
        item_value.insert_text = "FORGED-ACCEPTOR"
        return insertion
      end, { id = "safe", source = "test", insert_text = "FORGED-HINT" })
      assert.same("SAFE", accepted)
      assert.same("SAFE", active:snapshot().items[1].insert_text)
      assert.same("SAFE", active:snapshot().result)
    end,
  },
  {
    name = "reentrant accept is superseded without closing the newer generation",
    run = function()
      local callbacks = {}
      local handles = {}
      local active
      active = session.new({
        complete = function(request_value, update)
          callbacks[#callbacks + 1] = update
          local handle = { query = request_value.query, cancelled = false }
          function handle:cancel()
            self.cancelled = true
          end
          handles[#handles + 1] = handle
          return handle
        end,
      })
      active:start(request("old"))
      callbacks[1]({
        request_id = 1,
        generation = 1,
        items = { item("old") },
        done = true,
      })
      local result, err = active:accept(function()
        active:start(request("new"))
        callbacks[2]({
          request_id = 2,
          generation = 2,
          items = { item("new") },
          done = true,
        })
        return "OLD-RESULT"
      end)
      assert.same(nil, result)
      assert.same("accept_superseded", err)
      assert.truthy(handles[1].cancelled)
      assert.falsy(handles[2].cancelled)
      assert.same("active", active:snapshot().status)
      assert.same("new", active:snapshot().request.query)
      assert.same("new", active:selected_item().id)
      active:close()
      assert.truthy(handles[2].cancelled)
    end,
  },
  {
    name = "reentrant replacement cannot overwrite or leak the nested handle",
    run = function()
      local handles = {}
      local reenter = true
      local active
      active = session.new({
        complete = function(request_value)
          local handle = { query = request_value.query, cancelled = false }
          function handle:cancel()
            self.cancelled = true
          end
          handles[#handles + 1] = handle
          return handle
        end,
        on_close = function(_, reason)
          if reason == "replaced" and reenter then
            reenter = false
            active:start(request("nested"))
          end
        end,
      })

      active:start(request("first"))
      active:start(request("outer"))
      assert.same(2, #handles)
      assert.same("first", handles[1].query)
      assert.truthy(handles[1].cancelled)
      assert.same("nested", handles[2].query)
      assert.falsy(handles[2].cancelled)
      assert.same("nested", active:snapshot().request.query)
      active:close()
      assert.truthy(handles[2].cancelled)
    end,
  },
}
