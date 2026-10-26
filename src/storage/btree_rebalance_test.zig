//! BPlusTree 自动重平衡测试。
const std = @import("std");
const btree = @import("btree.zig");
const node = @import("node.zig");
const pager_module = @import("pager.zig");

test "兄弟可借出记录时重平衡优先重分配" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 100, .child_page_id = right_page.id });
    try fillLeaf(left_page, root_page.id, 0, 100);
    try fillLeaf(right_page, root_page.id, 100, 240);

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.rebalanceNode(left_page.id);

    try std.testing.expectEqual(root_page.id, tree.root_page_id.?);
    try std.testing.expectEqual(@as(u16, 170), try (node.LeafNode{ .page = left_page }).cellCount());
    try std.testing.expectEqual(@as(u16, 170), try (node.LeafNode{ .page = right_page }).cellCount());
    try std.testing.expectEqual(@as(u64, 170), (try root.readCell(0)).separator_key);
    try std.testing.expect((try tree.search(250)) != null);
}

test "重分配不足时合并并递归重平衡父节点直到根" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_internal_page = try pager.allocatePage();
    const right_internal_page = try pager.allocatePage();
    const left_leaf_page = try pager.allocatePage();
    const right_leaf_page = try pager.allocatePage();

    var root = node.InternalNode.init(root_page, 0, left_internal_page.id);
    try root.writeCell(0, .{ .separator_key = 1000, .child_page_id = right_internal_page.id });
    var left_internal = node.InternalNode.init(left_internal_page, root_page.id, left_leaf_page.id);
    try left_internal.writeCell(0, .{ .separator_key = 10, .child_page_id = right_leaf_page.id });

    var left_leaf = node.LeafNode.init(left_leaf_page, left_internal_page.id, right_leaf_page.id);
    try fillLeafRecords(&left_leaf, 0, 10, "left");
    var right_leaf = node.LeafNode.init(right_leaf_page, left_internal_page.id, 0);
    try fillLeafRecords(&right_leaf, 10, 200, "right");

    const right_child_ids: [node.internal_layout.max_cells / 2 + 31]u32 = blk: {
        var ids: [node.internal_layout.max_cells / 2 + 31]u32 = undefined;
        for (&ids, 0..) |*id, index| {
            const child_page = try pager.allocatePage();
            id.* = child_page.id;
            try writeLeaf(child_page, right_internal_page.id, @as(u64, @intCast(index + 1)) * 1000);
        }
        break :blk ids;
    };

    var right_internal = node.InternalNode.init(right_internal_page, root_page.id, right_child_ids[0]);
    for (0..right_child_ids.len - 1) |index| {
        try right_internal.writeCell(index, .{
            .separator_key = @as(u64, @intCast(index + 2)) * 1000,
            .child_page_id = right_child_ids[index + 1],
        });
    }

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.rebalanceNode(left_leaf_page.id);

    try std.testing.expectEqual(left_internal_page.id, tree.root_page_id.?);
    const new_root = node.InternalNode{ .page = left_internal_page };
    try std.testing.expectEqual(@as(u16, 201), try new_root.cellCount());
    try std.testing.expectEqualSlices(u8, "left", (try tree.search(5)).?);
    try std.testing.expectEqualSlices(u8, "right", (try tree.search(100)).?);
    try std.testing.expect((try tree.search(1000)) != null);
    try std.testing.expect((try tree.search(2000)) != null);
    try std.testing.expectError(error.InvalidNodeType, node.Node.open(right_leaf_page));
    try std.testing.expectError(error.InvalidNodeType, node.Node.open(root_page));
}

fn fillLeaf(page: *pager_module.Page, parent_page_id: u32, first_key: u64, count: usize) !void {
    var leaf = node.LeafNode.init(page, parent_page_id, 0);
    for (0..count) |index| {
        try leaf.writeCell(index, .{
            .key = first_key + @as(u64, @intCast(index)),
            .value_offset = pager_module.page_size,
            .value_length = 0,
        });
    }
}

fn fillLeafRecords(leaf: *node.LeafNode, first_key: u64, count: usize, value: []const u8) !void {
    for (0..count) |index| try leaf.insertRecord(first_key + @as(u64, @intCast(index)), value);
}

fn writeLeaf(page: *pager_module.Page, parent_page_id: u32, key: u64) !void {
    var leaf = node.LeafNode.init(page, parent_page_id, 0);
    try leaf.insertRecord(key, "value");
}
