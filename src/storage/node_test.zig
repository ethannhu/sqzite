//! 叶子和内部节点接口测试。
const std = @import("std");
const node = @import("node.zig");
const pager = @import("pager.zig");

test "Node.open 校验类型并返回节点视图" {
    var page = testPage(3);
    try std.testing.expectError(error.InvalidNodeType, node.Node.open(&page));

    _ = node.LeafNode.init(&page, 0, 0);
    const opened = try node.Node.open(&page);
    try std.testing.expect(opened == .leaf);
}

test "初始化叶子节点会清空页面并写入头部" {
    var page = testPage(4);
    @memset(&page.data, 0xaa);

    const leaf = node.LeafNode.init(&page, 2, 7);

    try std.testing.expectEqual(@as(u8, @intFromEnum(node.NodeType.leaf)), page.data[node.header_layout.node_type_offset]);
    try std.testing.expectEqual(@as(u16, 0), node.readU16(&page.data, node.header_layout.cell_count_offset));
    try std.testing.expectEqual(@as(u32, 2), node.readU32(&page.data, node.header_layout.parent_page_id_offset));
    try std.testing.expectEqual(@as(u32, 7), node.readU32(&page.data, node.leaf_layout.next_leaf_page_id_offset));
    try std.testing.expect(page.dirty);
    try std.testing.expectEqual(page.id, leaf.page.id);
    for (page.data[node.leaf_layout.header_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "叶子节点可以写入并读取槽位" {
    var page = testPage(5);
    var leaf = node.LeafNode.init(&page, 0, 0);
    const cell = node.LeafCell{
        .key = 42,
        .value_offset = 128,
        .value_length = 5,
    };

    page.dirty = false;
    try leaf.writeCell(0, cell);
    try std.testing.expectEqual(cell, try leaf.readCell(0));
    try std.testing.expectEqual(@as(u16, 1), node.readU16(&page.data, node.header_layout.cell_count_offset));
    try std.testing.expect(page.dirty);
}

test "叶子节点拒绝读取槽位范围之外的索引" {
    var page = testPage(6);
    var leaf = node.LeafNode.init(&page, 0, 0);

    try std.testing.expectError(error.CellOutOfBounds, leaf.readCell(0));
}

test "叶子节点拒绝跳过槽位写入" {
    var page = testPage(7);
    var leaf = node.LeafNode.init(&page, 0, 0);
    const cell = node.LeafCell{ .key = 1, .value_offset = 100, .value_length = 1 };

    try std.testing.expectError(error.CellOutOfBounds, leaf.writeCell(1, cell));
    try std.testing.expectEqual(@as(u16, 0), node.readU16(&page.data, node.header_layout.cell_count_offset));
}

test "初始化内部节点会写入头部和第一个子页" {
    var page = testPage(8);
    @memset(&page.data, 0xaa);

    const internal = node.InternalNode.init(&page, 3, 9);

    try std.testing.expectEqual(@as(u8, @intFromEnum(node.NodeType.internal)), page.data[node.header_layout.node_type_offset]);
    try std.testing.expectEqual(@as(u16, 0), node.readU16(&page.data, node.header_layout.cell_count_offset));
    try std.testing.expectEqual(@as(u32, 3), node.readU32(&page.data, node.header_layout.parent_page_id_offset));
    try std.testing.expectEqual(@as(u32, 9), node.readU32(&page.data, node.internal_layout.first_child_page_id_offset));
    try std.testing.expect(page.dirty);
    try std.testing.expectEqual(page.id, internal.page.id);
    for (page.data[node.internal_layout.header_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "内部节点可以写入并读取分隔键和子页" {
    var page = testPage(10);
    var internal = node.InternalNode.init(&page, 0, 11);
    const cell = node.InternalCell{
        .separator_key = 80,
        .child_page_id = 12,
    };

    page.dirty = false;
    try internal.writeCell(0, cell);
    try std.testing.expectEqual(cell, try internal.readCell(0));
    try std.testing.expectEqual(@as(u16, 1), node.readU16(&page.data, node.header_layout.cell_count_offset));
    try std.testing.expect(page.dirty);
}

test "内部节点拒绝读取槽位范围之外的索引" {
    var page = testPage(13);
    var internal = node.InternalNode.init(&page, 0, 14);

    try std.testing.expectError(error.CellOutOfBounds, internal.readCell(0));
}

test "内部节点拒绝跳过槽位写入" {
    var page = testPage(15);
    var internal = node.InternalNode.init(&page, 0, 16);
    const cell = node.InternalCell{ .separator_key = 1, .child_page_id = 17 };

    try std.testing.expectError(error.CellOutOfBounds, internal.writeCell(1, cell));
    try std.testing.expectEqual(@as(u16, 0), node.readU16(&page.data, node.header_layout.cell_count_offset));
}

fn testPage(id: u32) pager.Page {
    return .{
        .id = id,
        .dirty = false,
        .data = [_]u8{0} ** pager.page_size,
    };
}
