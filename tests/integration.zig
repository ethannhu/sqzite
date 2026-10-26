//! B+ 树与 Pager 持久化集成测试。
const std = @import("std");
const project = @import("zig_hello");
const btree = project.btree;
const pager_module = project.pager;

test "关闭并重开 Pager 后仍可搜索已插入的数据" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_page_id: u32 = undefined;

    {
        var pager = try pager_module.Pager.open(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            "db",
        );
        var tree = btree.BPlusTree{
            .pager = &pager,
            .root_page_id = null,
        };

        try tree.insert(11, "eleven");
        try tree.insert(22, "twenty-two");
        root_page_id = tree.root_page_id.?;
        try pager.close();
    }

    {
        var pager = try pager_module.Pager.open(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            "db",
        );
        defer pager.close() catch {};
        var tree = btree.BPlusTree{
            .pager = &pager,
            .root_page_id = root_page_id,
        };

        try std.testing.expectEqualSlices(u8, "eleven", (try tree.search(11)).?);
        try std.testing.expectEqualSlices(u8, "twenty-two", (try tree.search(22)).?);
    }
}

test "大量混合读写与删除后数据及持久化保持正确" {
    const key_count = 20_000;
    const sample_count = 4;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const keys = try std.testing.allocator.alloc(u32, key_count);
    defer std.testing.allocator.free(keys);
    const present = try std.testing.allocator.alloc(bool, key_count);
    defer std.testing.allocator.free(present);
    @memset(present, false);
    for (keys, 0..) |*key, index| key.* = @intCast(index);

    var random_state: u64 = 0x8f3d_9a72_61c5_b407;
    shuffleKeys(keys, &random_state);

    var root_page_id: u32 = undefined;
    {
        var pager = try pager_module.Pager.open(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            "db",
        );
        var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = null };

        for (keys, 0..) |key, index| {
            const value = stressValue(key);
            try tree.insert(key, &value);
            present[key] = true;

            // 每次写入后检查刚写入的键和多个随机键。
            try expectStressSearch(&tree, present, key);
            for (0..sample_count) |_| {
                const query = keys[@as(usize, @intCast(nextRandom(&random_state) % key_count))];
                try expectStressSearch(&tree, present, query);
            }

            if (index % 1024 == 1023) {
                const absent_key: u32 = @intCast(key_count + index);
                try expectStressSearch(&tree, present, absent_key);
            }
        }

        root_page_id = tree.root_page_id.?;
        try pager.close();
    }

    {
        var pager = try pager_module.Pager.open(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            "db",
        );
        defer pager.close() catch {};
        var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page_id };

        // 重开后遍历全部键，验证写入内容和缺失键查询。
        for (keys) |key| try expectStressSearch(&tree, present, key);
        try expectStressSearch(&tree, present, key_count + 1);

        shuffleKeys(keys, &random_state);
        for (keys, 0..) |key, index| {
            try std.testing.expect(try tree.delete(key));
            present[key] = false;
            try expectStressSearch(&tree, present, key);

            for (0..sample_count) |_| {
                const query = keys[@as(usize, @intCast(nextRandom(&random_state) % key_count))];
                try expectStressSearch(&tree, present, query);
            }

            if (index % 1024 == 1023) {
                const absent_key: u32 = @intCast(key_count + index);
                try expectStressSearch(&tree, present, absent_key);
            }
        }

        try std.testing.expect(tree.root_page_id == null);
        for (keys) |key| try expectStressSearch(&tree, present, key);
    }
}

fn expectStressSearch(tree: *btree.BPlusTree, present: []const bool, key: u32) !void {
    const actual = try tree.search(key);
    if (key < present.len and present[key]) {
        const expected = stressValue(key);
        try std.testing.expectEqualSlices(u8, &expected, actual.?);
    } else {
        try std.testing.expect(actual == null);
    }
}

fn stressValue(key: u32) [16]u8 {
    var value: [16]u8 = undefined;
    const checksum = @as(u64, key) *% 0x9e37_79b9_7f4a_7c15;
    for (0..8) |index| {
        const shift: u6 = @intCast(index * 8);
        value[index] = @truncate(@as(u64, key) >> shift);
        value[index + 8] = @truncate(checksum >> shift);
    }
    return value;
}

fn shuffleKeys(keys: []u32, state: *u64) void {
    var index = keys.len;
    while (index > 1) {
        index -= 1;
        const other: usize = @intCast(nextRandom(state) % @as(u64, @intCast(index + 1)));
        std.mem.swap(u32, &keys[index], &keys[other]);
    }
}

fn nextRandom(state: *u64) u64 {
    state.* = state.* *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
    return state.*;
}
