//! 叶子和内部节点接口约定测试；节点方法实现后再接入测试入口。
const std = @import("std");
const btree = @import("btree.zig");
const pager = @import("pager.zig");

test "初始化叶子节点会清空页面并写入头部" {
    var page = testPage(4);
    @memset(&page.data, 0xaa);

    const leaf = btree.LeafNode.init(&page, 2, 7);

    try std.testing.expectEqual(@as(u8, @intFromEnum(btree.NodeType.leaf)), page.data[btree.header_layout.node_type_offset]);
    try std.testing.expectEqual(@as(u16, 0), readU16(&page.data, btree.header_layout.cell_count_offset));
    try std.testing.expectEqual(@as(u32, 2), readU32(&page.data, btree.header_layout.parent_page_id_offset));
    try std.testing.expectEqual(@as(u32, 7), readU32(&page.data, btree.leaf_layout.next_leaf_page_id_offset));
    try std.testing.expect(page.dirty);
    try std.testing.expectEqual(page.id, leaf.page.id);
    for (page.data[btree.leaf_layout.header_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "叶子节点可以写入并读取槽位" {
    var page = testPage(5);
    var leaf = btree.LeafNode.init(&page, 0, 0);
    const cell = btree.LeafCell{
        .key = 42,
        .value_offset = 128,
        .value_length = 5,
    };

    page.dirty = false;
    try leaf.writeCell(0, cell);
    try std.testing.expectEqual(cell, try leaf.readCell(0));
    try std.testing.expectEqual(@as(u16, 1), readU16(&page.data, btree.header_layout.cell_count_offset));
    try std.testing.expect(page.dirty);
}

test "叶子节点拒绝读取槽位范围之外的索引" {
    var page = testPage(6);
    var leaf = btree.LeafNode.init(&page, 0, 0);

    try std.testing.expectError(error.CellOutOfBounds, leaf.readCell(0));
}

test "初始化内部节点会写入头部和第一个子页" {
    var page = testPage(8);
    @memset(&page.data, 0xaa);

    const internal = btree.InternalNode.init(&page, 3, 9);

    try std.testing.expectEqual(@as(u8, @intFromEnum(btree.NodeType.internal)), page.data[btree.header_layout.node_type_offset]);
    try std.testing.expectEqual(@as(u16, 0), readU16(&page.data, btree.header_layout.cell_count_offset));
    try std.testing.expectEqual(@as(u32, 3), readU32(&page.data, btree.header_layout.parent_page_id_offset));
    try std.testing.expectEqual(@as(u32, 9), readU32(&page.data, btree.internal_layout.first_child_page_id_offset));
    try std.testing.expect(page.dirty);
    try std.testing.expectEqual(page.id, internal.page.id);
    for (page.data[btree.internal_layout.header_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "内部节点可以写入并读取分隔键和子页" {
    var page = testPage(10);
    var internal = btree.InternalNode.init(&page, 0, 11);
    const cell = btree.InternalCell{
        .separator_key = 80,
        .child_page_id = 12,
    };

    page.dirty = false;
    try internal.writeCell(0, cell);
    try std.testing.expectEqual(cell, try internal.readCell(0));
    try std.testing.expectEqual(@as(u16, 1), readU16(&page.data, btree.header_layout.cell_count_offset));
    try std.testing.expect(page.dirty);
}

test "内部节点拒绝读取槽位范围之外的索引" {
    var page = testPage(13);
    var internal = btree.InternalNode.init(&page, 0, 14);

    try std.testing.expectError(error.CellOutOfBounds, internal.readCell(0));
}

fn testPage(id: u32) pager.Page {
    return .{
        .id = id,
        .dirty = false,
        .data = [_]u8{0} ** pager.page_size,
    };
}

fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}
