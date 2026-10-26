//! Pager 行为测试。
const std = @import("std");
const pager = @import("pager.zig");

const page_size = pager.page_size;

test "新分配的页面具有页号且初始未修改" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try pager.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer db.close() catch {};

    const page = try db.getPage(7);
    try std.testing.expectEqual(@as(u32, 7), page.id);
    try std.testing.expect(!page.dirty);
    try std.testing.expectEqual(page_size, page.data.len);
}

test "脏页数据按原始字节写入并重新读取" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected = [_]u8{0x5a} ** page_size;

    {
        var db = try pager.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
        const page = try db.getPage(3);
        @memcpy(page.data[0..], expected[0..]);
        page.dirty = true;
        try db.flushPage(3);
        try std.testing.expect(!page.dirty);
        try db.close();
    }

    {
        var db = try pager.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
        defer db.close() catch {};

        const page = try db.getPage(3);
        try std.testing.expectEqual(@as(u32, 3), page.id);
        try std.testing.expect(!page.dirty);
        try std.testing.expectEqualSlices(u8, expected[0..], page.data[0..]);
    }
}

test "刷新页面不会影响相邻页面数据" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = [_]u8{0x11} ** page_size;
    const second = [_]u8{0xee} ** page_size;

    {
        var db = try pager.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
        const page0 = try db.getPage(0);
        @memcpy(page0.data[0..], first[0..]);
        page0.dirty = true;
        const page1 = try db.getPage(1);
        @memcpy(page1.data[0..], second[0..]);
        page1.dirty = true;
        try db.flushPage(0);
        try db.flushPage(1);
        try db.close();
    }

    {
        var db = try pager.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
        defer db.close() catch {};

        const page0 = try db.getPage(0);
        const page1 = try db.getPage(1);
        try std.testing.expectEqualSlices(u8, first[0..], page0.data[0..]);
        try std.testing.expectEqualSlices(u8, second[0..], page1.data[0..]);
    }
}
