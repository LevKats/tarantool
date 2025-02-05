local t = require('luatest')
local server = require('luatest.server')

local group_config = {{wal_max_size = 50000}, {wal_max_size = 50000 * 10}}
-- 1. Many small xlogs. Let's check that threshold check indeed use
--    the sum of xlog sizes
-- 2. One big xlog. Let's check that xlog right after the snapshot is
--    taken into account.

local g = t.group("wal_max_size", group_config)

g.before_each(function(cg)
    cg.server = server:new({box_cfg = {
        wal_max_size = cg.params.wal_max_size,
        checkpoint_wal_threshold = 10 * 50000,
        checkpoint_count = 1e8,
        checkpoint_interval = 0,
    }})
    cg.server:start()
    cg.server:exec(function()
        local s = box.schema.space.create('test')
        s:create_index('pk', {sequence = true})
        -- let's delete all existing xlogs
        box.cfg{checkpoint_count = 1}
        -- snapshot() calls below should trigger GC
        box.snapshot()
        -- Just to make sure that at least one
        -- snapshot will be deleted
        box.snapshot()
        -- Effectively disable GC again
        box.cfg{checkpoint_count = 1e8}
    end)
end)


g.test_box_checkpoint_wal_threshold_batch_size = function(cg)
    cg.server:exec(function()
        local s = box.space.test
        local checkpoints_before = #box.info.gc().checkpoints
        for _ = 1, 7000 do
            -- should not trigger checkpointing
            s:insert({box.NULL})
        end
        -- wait for possible (but unwanted) checkpoint finish
        local fiber = require("fiber")
        fiber.sleep(1)
        t.assert_equals(#box.info.gc().checkpoints, checkpoints_before,
                        "too large batch")
        for _ = 1, 7000 do
            -- should not trigger checkpointing
            s:insert({box.NULL})
        end
        fiber.sleep(1)
        t.assert_gt(#box.info.gc().checkpoints, checkpoints_before,
                    "too small batch")
    end)
end

g.test_box_checkpoint_wal_threshold_after_restart = function(cg)
    cg.server:exec(function()
        -- let's create some xlogs followed by a snapshot
        local s = box.space.test
        local checkpoints_before = #box.info.gc().checkpoints
        for _ = 1, 7000 do
            -- should not trigger checkpointing
            s:insert({box.NULL})
        end
        -- wait for possible (but unwanted) checkpoint finish
        require("fiber").sleep(1)
        t.assert_equals(#box.info.gc().checkpoints, checkpoints_before,
                        "Wrong batch size. Check the test above")
        box.snapshot()
    end)
    cg.server:restart()
    cg.server:exec(function()
        local s = box.space.test
        -- There are xlogs created before the snapshot.
        -- Ignore them when calculating the threshold.
        local checkpoints_before = #box.info.gc().checkpoints
        for _ = 1, 7000 do
            s:insert({box.NULL})
        end
        -- result must be the same -- no new checkpoint
        require("fiber").sleep(1)
        t.assert_equals(#box.info.gc().checkpoints, checkpoints_before,
                        "old xlogs may be used")
    end)
    cg.server:restart()
    cg.server:exec(function()
        local checkpoints_before = #box.info.gc().checkpoints
        local s = box.space.test
        -- checkpoint must be created after that
        for _ = 1, 7000 do
            s:insert({box.NULL})
        end
        require("fiber").sleep(1)
        t.assert_gt(#box.info.gc().checkpoints, checkpoints_before)
    end)
end

g.after_each(function(cg)
    cg.server:drop()
end)
