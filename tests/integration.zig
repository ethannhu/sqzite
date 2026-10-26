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
