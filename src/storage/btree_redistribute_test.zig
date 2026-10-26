//! BPlusTree 兄弟节点重分配测试。
const std = @import("std");
const btree = @import("btree.zig");
const node = @import("node.zig");
const pager_module = @import("pager.zig");

test "叶子兄弟重分配记录并更新父分隔键" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 40, .child_page_id = right_page.id });
    var left = node.LeafNode.init(left_page, root_page.id, right_page.id);
    try left.insertRecord(1, "one");
    try left.insertRecord(10, "ten");
    try left.insertRecord(20, "twenty");
    var right = node.LeafNode.init(right_page, root_page.id, 0);
    try right.insertRecord(40, "forty");

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.redistributeSiblings(left_page.id, right_page.id);

    try std.testing.expectEqual(@as(u16, 2), try left.cellCount());
    try std.testing.expectEqual(@as(u16, 2), try right.cellCount());
    try std.testing.expectEqual(@as(u64, 20), (try root.readCell(0)).separator_key);
    try std.testing.expectEqual(right_page.id, left.nextLeafPageId());
    try std.testing.expectEqualSlices(u8, "one", (try tree.search(1)).?);
    try std.testing.expectEqualSlices(u8, "ten", (try tree.search(10)).?);
    try std.testing.expectEqualSlices(u8, "twenty", (try tree.search(20)).?);
    try std.testing.expectEqualSlices(u8, "forty", (try tree.search(40)).?);
}

test "内部兄弟重分配父分隔键并更新移动子页的父页号" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    const children = [_]*pager_module.Page{
        try pager.allocatePage(),
        try pager.allocatePage(),
        try pager.allocatePage(),
        try pager.allocatePage(),
        try pager.allocatePage(),
        try pager.allocatePage(),
    };
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 100, .child_page_id = right_page.id });
    var left = node.InternalNode.init(left_page, root_page.id, children[0].id);
    try left.writeCell(0, .{ .separator_key = 10, .child_page_id = children[1].id });
    try left.writeCell(1, .{ .separator_key = 20, .child_page_id = children[2].id });
    try left.writeCell(2, .{ .separator_key = 30, .child_page_id = children[3].id });
    var right = node.InternalNode.init(right_page, root_page.id, children[4].id);
    try right.writeCell(0, .{ .separator_key = 110, .child_page_id = children[5].id });
    const keys = [_]u64{ 5, 10, 20, 30, 100, 110 };
    for (children, 0..) |child, index| {
        try writeLeaf(child, if (index < 4) left_page.id else right_page.id, keys[index]);
    }

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.redistributeSiblings(left_page.id, right_page.id);

    try std.testing.expectEqual(@as(u16, 2), try left.cellCount());
    try std.testing.expectEqual(@as(u16, 2), try right.cellCount());
    try std.testing.expectEqual(@as(u64, 30), (try root.readCell(0)).separator_key);
    try std.testing.expectEqual(children[3].id, right.firstChildPageId());
    const moved_child = try node.Node.open(children[3]);
    try std.testing.expectEqual(right_page.id, moved_child.leaf.parentPageId());
    try std.testing.expect((try tree.search(30)) != null);
    try std.testing.expect((try tree.search(100)) != null);
    try std.testing.expect((try tree.search(110)) != null);
}

fn writeLeaf(page: *pager_module.Page, parent_page_id: u32, key: u64) !void {
    var leaf = node.LeafNode.init(page, parent_page_id, 0);
    try leaf.insertRecord(key, "value");
}
