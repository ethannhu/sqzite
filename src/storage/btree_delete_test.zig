//! BPlusTree 删除行为测试。
const std = @import("std");
const btree = @import("btree.zig");
const node = @import("node.zig");
const pager_module = @import("pager.zig");

test "删除空树或不存在的键返回 false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = null };
    try std.testing.expect(!(try tree.delete(1)));

    const root_page = try pager.allocatePage();
    var leaf = node.LeafNode.init(root_page, 0, 0);
    try leaf.insertRecord(10, "ten");
    tree.root_page_id = root_page.id;
    try std.testing.expect(!(try tree.delete(11)));
    try std.testing.expectEqualSlices(u8, "ten", (try tree.search(10)).?);
}

test "删除叶子记录后槽位和值仍正确，空根被移除" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    var leaf = node.LeafNode.init(root_page, 0, 0);
    try leaf.insertRecord(1, "one");
    try leaf.insertRecord(2, "two");
    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };

    try std.testing.expect(try tree.delete(1));
    try std.testing.expect((try tree.search(1)) == null);
    try std.testing.expectEqualSlices(u8, "two", (try tree.search(2)).?);
    try std.testing.expect(!(try tree.delete(1)));
    try std.testing.expect(try tree.delete(2));
    try std.testing.expect(tree.root_page_id == null);
}

test "删除右子树最小键后更新父分隔键" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 170, .child_page_id = right_page.id });
    try fillLeaf(left_page, root_page.id, 0, 170);
    try fillLeaf(right_page, root_page.id, 170, 171);

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try std.testing.expect(try tree.delete(170));

    try std.testing.expectEqual(@as(u64, 171), (try root.readCell(0)).separator_key);
    try std.testing.expect((try tree.search(170)) == null);
    try std.testing.expect((try tree.search(171)) != null);
}

test "删除导致叶子合并时递归重平衡并收缩根" {
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
    try left_internal.writeCell(0, .{ .separator_key = 170, .child_page_id = right_leaf_page.id });
    try fillLeaf(left_leaf_page, left_internal_page.id, 0, 170);
    try fillLeaf(right_leaf_page, left_internal_page.id, 170, 170);

    const child_count = node.internal_layout.max_cells / 2 + 31;
    const right_child_ids = try std.testing.allocator.alloc(u32, child_count);
    defer std.testing.allocator.free(right_child_ids);
    for (right_child_ids, 0..) |*id, index| {
        const child_page = try pager.allocatePage();
        id.* = child_page.id;
        try writeLeaf(child_page, right_internal_page.id, @as(u64, @intCast(index + 1)) * 1000);
    }
    var right_internal = node.InternalNode.init(right_internal_page, root_page.id, right_child_ids[0]);
    for (0..right_child_ids.len - 1) |index| {
        try right_internal.writeCell(index, .{
            .separator_key = @as(u64, @intCast(index + 2)) * 1000,
            .child_page_id = right_child_ids[index + 1],
        });
    }

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = root_page.id };
    try std.testing.expect(try tree.delete(0));

    try std.testing.expectEqual(left_internal_page.id, tree.root_page_id.?);
    const new_root = node.InternalNode{ .page = left_internal_page };
    try std.testing.expectEqual(@as(u16, 201), try new_root.cellCount());
    try std.testing.expect((try tree.search(0)) == null);
    try std.testing.expect((try tree.search(1)) != null);
    try std.testing.expect((try tree.search(170)) != null);
    try std.testing.expect((try tree.search(1000)) != null);
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

fn writeLeaf(page: *pager_module.Page, parent_page_id: u32, key: u64) !void {
    var leaf = node.LeafNode.init(page, parent_page_id, 0);
    try leaf.insertRecord(key, "value");
}
