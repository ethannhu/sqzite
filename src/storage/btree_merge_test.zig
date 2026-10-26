//! BPlusTree 兄弟节点合并测试。
const std = @import("std");
const btree = @import("btree.zig");
const node = @import("node.zig");
const pager_module = @import("pager.zig");

test "合并叶子兄弟会拼接记录和叶子链并收缩根" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 20, .child_page_id = right_page.id });

    var left = node.LeafNode.init(left_page, root_page.id, right_page.id);
    try left.insertRecord(10, "left");
    var right = node.LeafNode.init(right_page, root_page.id, 0);
    try right.insertRecord(20, "right");

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.mergeSiblings(left_page.id, right_page.id);

    try std.testing.expectEqual(left_page.id, tree.root_page_id.?);
    try std.testing.expectEqualSlices(u8, "left", (try tree.search(10)).?);
    try std.testing.expectEqualSlices(u8, "right", (try tree.search(20)).?);
    const merged = node.LeafNode{ .page = left_page };
    try std.testing.expectEqual(@as(u16, 2), try merged.cellCount());
    try std.testing.expectEqual(@as(u32, 0), merged.nextLeafPageId());
    try std.testing.expectError(error.InvalidNodeType, node.Node.open(right_page));
    try std.testing.expectError(error.InvalidNodeType, node.Node.open(root_page));
}

test "根仍有其他子页时合并会删除对应分隔键并保留根" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const middle_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 10, .child_page_id = middle_page.id });
    try root.writeCell(1, .{ .separator_key = 20, .child_page_id = right_page.id });
    var left = node.LeafNode.init(left_page, root_page.id, middle_page.id);
    try left.insertRecord(5, "left");
    var middle = node.LeafNode.init(middle_page, root_page.id, right_page.id);
    try middle.insertRecord(10, "middle");
    try writeLeaf(right_page, root_page.id, 20, "right");

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.mergeSiblings(left_page.id, middle_page.id);

    try std.testing.expectEqual(root_page.id, tree.root_page_id.?);
    try std.testing.expectEqual(@as(u16, 1), try root.cellCount());
    try std.testing.expectEqual(right_page.id, (try root.readCell(0)).child_page_id);
    try std.testing.expectEqual(right_page.id, (node.LeafNode{ .page = left_page }).nextLeafPageId());
    try std.testing.expectEqualSlices(u8, "left", (try tree.search(5)).?);
    try std.testing.expectEqualSlices(u8, "middle", (try tree.search(10)).?);
    try std.testing.expectEqualSlices(u8, "right", (try tree.search(20)).?);
}

test "合并内部兄弟会提升父分隔键并重设子节点父页号" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    const leaf_a = try pager.allocatePage();
    const leaf_b = try pager.allocatePage();
    const leaf_c = try pager.allocatePage();
    const leaf_d = try pager.allocatePage();

    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 100, .child_page_id = right_page.id });
    var left = node.InternalNode.init(left_page, root_page.id, leaf_a.id);
    try left.writeCell(0, .{ .separator_key = 50, .child_page_id = leaf_b.id });
    var right = node.InternalNode.init(right_page, root_page.id, leaf_c.id);
    try right.writeCell(0, .{ .separator_key = 150, .child_page_id = leaf_d.id });

    try writeLeaf(leaf_a, left_page.id, 10, "a");
    try writeLeaf(leaf_b, left_page.id, 50, "b");
    try writeLeaf(leaf_c, right_page.id, 100, "c");
    try writeLeaf(leaf_d, right_page.id, 150, "d");

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try tree.mergeSiblings(left_page.id, right_page.id);

    try std.testing.expectEqual(left_page.id, tree.root_page_id.?);
    const merged = node.InternalNode{ .page = left_page };
    try std.testing.expectEqual(@as(u16, 3), try merged.cellCount());
    try std.testing.expectEqual(@as(u64, 100), (try merged.readCell(1)).separator_key);
    const leaf_c_node = try node.Node.open(leaf_c);
    try std.testing.expectEqual(left_page.id, leaf_c_node.leaf.parentPageId());
    try std.testing.expectEqualSlices(u8, "a", (try tree.search(10)).?);
    try std.testing.expectEqualSlices(u8, "b", (try tree.search(50)).?);
    try std.testing.expectEqualSlices(u8, "c", (try tree.search(100)).?);
    try std.testing.expectEqualSlices(u8, "d", (try tree.search(150)).?);
}

test "合并非相邻兄弟或超容量叶子时保持页面不变" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const middle_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 200, .child_page_id = middle_page.id });
    try root.writeCell(1, .{ .separator_key = 400, .child_page_id = right_page.id });

    try fillLeaf(left_page, root_page.id, 0, node.leaf_layout.max_cells / 2 + 1);
    try fillLeaf(middle_page, root_page.id, 200, node.leaf_layout.max_cells / 2);
    try fillLeaf(right_page, root_page.id, 400, node.leaf_layout.max_cells / 2 + 1);

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try std.testing.expectError(error.NotAdjacent, tree.mergeSiblings(left_page.id, right_page.id));
    try std.testing.expectError(error.NoSpace, tree.mergeSiblings(left_page.id, middle_page.id));
    try std.testing.expectEqual(@as(u16, 2), try root.cellCount());
    try std.testing.expectEqual(@as(u16, node.leaf_layout.max_cells / 2 + 1), try (node.LeafNode{ .page = left_page }).cellCount());
    try std.testing.expectEqual(@as(u16, node.leaf_layout.max_cells / 2), try (node.LeafNode{ .page = middle_page }).cellCount());
}

fn writeLeaf(page: *pager_module.Page, parent_page_id: u32, key: u64, value: []const u8) !void {
    var leaf = node.LeafNode.init(page, parent_page_id, 0);
    try leaf.insertRecord(key, value);
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
