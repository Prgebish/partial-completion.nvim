local assert = require("tests.helpers.assertions")
local Cache = require("partial_completion.cache")

return {
  {
    name = "cache records hits misses expiration and explicit invalidation",
    run = function()
      local now = 0
      local cache = Cache.new({
        max_entries = 2,
        max_bytes = 100,
        ttl_ms = 10,
        clock = function()
          return now
        end,
      })
      assert.same(nil, cache:get("a"))
      cache:set("a", { "alpha" }, 10)
      assert.same({ "alpha" }, cache:get("a"))
      now = 10
      assert.same(nil, cache:get("a"))
      cache:set("a", {}, 10)
      cache:invalidate("a")
      assert.same({
        hits = 1,
        misses = 2,
        evictions = 0,
        expirations = 1,
        invalidations = 1,
        entries = 0,
        bytes = 0,
      }, cache:stats())
    end,
  },
  {
    name = "cache evicts least recently used entries within count and byte bounds",
    run = function()
      local cache = Cache.new({
        max_entries = 2,
        max_bytes = 20,
        ttl_ms = 1000,
        clock = function()
          return 0
        end,
      })
      cache:set("a", "a", 10)
      cache:set("b", "b", 10)
      assert.same("a", cache:get("a"))
      cache:set("c", "c", 10)
      assert.same(nil, cache:get("b"))
      assert.same("a", cache:get("a"))
      assert.same("c", cache:get("c"))
      assert.same(1, cache:stats().evictions)
      assert.same(2, cache:stats().entries)
      assert.same(20, cache:stats().bytes)
    end,
  },
}
