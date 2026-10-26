//! B+ 树查询接口测试。
const std = @import("std");
const btree = @import("btree.zig");
const pager_module = @import("pager.zig");

test "空树查询任意键返回未找到" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try @import("pager.zig").Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = null,
    };

    try std.testing.expectEqual(@as(?[]const u8, null), try tree.search(42));
}

test "查询叶子节点中的键返回对应字节值" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try @import("pager.zig").Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = 0,
    };

    const page = try pager.getPage(0);
    var leaf = btree.LeafNode.init(page, 0, 0);

    // 用节点接口构造键升序排列的叶子页，目标键位于中间槽位。
    try writeLeafCell(&leaf, 0, 10, 128, "ten");
    try writeLeafCell(&leaf, 1, 42, 140, "hello");
    try writeLeafCell(&leaf, 2, 90, 160, "ninety");

    const result = try tree.search(42);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "hello", result.?);
}

test "查询键分别命中内部节点的左中右子叶" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try @import("pager.zig").Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = 0,
    };

    const root = try pager.getPage(0);
    var internal = btree.InternalNode.init(root, 0, 1);
    try internal.writeCell(0, .{ .separator_key = 30, .child_page_id = 2 });
    try internal.writeCell(1, .{ .separator_key = 60, .child_page_id = 3 });

    const left_page = try pager.getPage(1);
    try writeLeafEntry(left_page, 10, 128, "left");

    const middle_page = try pager.getPage(2);
    try writeLeafEntry(middle_page, 40, 128, "middle");

    const right_page = try pager.getPage(3);
    try writeLeafEntry(right_page, 70, 128, "right");

    const left_result = try tree.search(10);
    try std.testing.expect(left_result != null);
    try std.testing.expectEqualSlices(u8, "left", left_result.?);

    const middle_result = try tree.search(40);
    try std.testing.expect(middle_result != null);
    try std.testing.expectEqualSlices(u8, "middle", middle_result.?);

    const right_result = try tree.search(70);
    try std.testing.expect(right_result != null);
    try std.testing.expectEqualSlices(u8, "right", right_result.?);

    try tree.insert(5, "low");
    try tree.insert(80, "high");
    const inserted_left = try tree.search(5);
    const inserted_right = try tree.search(80);
    try std.testing.expectEqualSlices(u8, "low", inserted_left.?);
    try std.testing.expectEqualSlices(u8, "high", inserted_right.?);
}

test "插入空树并按键顺序保存多个值" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try @import("pager.zig").Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = null,
    };

    try tree.insert(20, "twenty");
    try tree.insert(10, "ten");
    try tree.insert(30, "thirty");

    try std.testing.expect(tree.root_page_id != null);
    try std.testing.expectEqualSlices(u8, "ten", (try tree.search(10)).?);
    try std.testing.expectEqualSlices(u8, "twenty", (try tree.search(20)).?);
    try std.testing.expectEqualSlices(u8, "thirty", (try tree.search(30)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try tree.search(15));
}

test "插入重复键或超出单页空间时返回错误" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try @import("pager.zig").Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = null,
    };

    try tree.insert(7, "seven");
    try std.testing.expectError(error.DuplicateKey, tree.insert(7, "updated"));

    const too_large = [_]u8{0xaa} ** pager_module.page_size;
    var empty_tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = null,
    };
    try std.testing.expectError(error.NoSpace, empty_tree.insert(1, &too_large));
    try std.testing.expect(empty_tree.root_page_id == null);
}

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

test "叶子子节点已满且父节点有空间时分裂并继续插入" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = 0,
    };

    const root = try pager.getPage(0);
    var internal = btree.InternalNode.init(root, 0, 1);
    try internal.writeCell(0, .{ .separator_key = 1000, .child_page_id = 2 });

    const full_child = try pager.getPage(1);
    try writeFullLeafWithRange(full_child, btree.leaf_layout.max_cells, 2);

    const right_child = try pager.getPage(2);
    try writeLeafEntry(right_child, 1000, 128, "right");

    // 0..339 已填满左叶子；500 应进入该子树并触发叶子分裂。
    try tree.insert(500, "inserted");

    try std.testing.expectEqual(@as(u16, 2), getU16(&root.data, btree.header_layout.cell_count_offset));
    const split_right_id = readU32(
        &root.data,
        btree.internal_layout.header_size + btree.internal_cell_layout.child_page_id_offset,
    );
    try std.testing.expectEqual(split_right_id, readU32(&full_child.data, btree.leaf_layout.next_leaf_page_id_offset));
    const split_right = try pager.getPage(split_right_id);
    try std.testing.expectEqual(@as(u32, 2), readU32(&split_right.data, btree.leaf_layout.next_leaf_page_id_offset));
    for (0..btree.leaf_layout.max_cells) |key| {
        try std.testing.expect((try tree.search(key)) != null);
    }
    try std.testing.expectEqualSlices(u8, "inserted", (try tree.search(500)).?);
    try std.testing.expectEqualSlices(u8, "right", (try tree.search(1000)).?);
}

test "根叶子已满时分裂并创建新的内部根节点" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = 0,
    };
    const old_root = try pager.getPage(0);
    try writeFullLeafWithRange(old_root, btree.leaf_layout.max_cells, 0);

    try tree.insert(btree.leaf_layout.max_cells, "new");

    try std.testing.expect(tree.root_page_id.? != old_root.id);
    const new_root = try pager.getPage(tree.root_page_id.?);
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(btree.NodeType.internal)),
        new_root.data[btree.header_layout.node_type_offset],
    );
    try std.testing.expectEqual(@as(u16, 1), getU16(&new_root.data, btree.header_layout.cell_count_offset));
    try std.testing.expect((try tree.search(0)) != null);
    try std.testing.expect((try tree.search(170)) != null);
    try std.testing.expectEqualSlices(u8, "new", (try tree.search(btree.leaf_layout.max_cells)).?);
}

fn writeLeafEntry(page: *pager_module.Page, key: u64, value_offset: u16, value: []const u8) !void {
    var leaf = btree.LeafNode.init(page, 0, 0);
    try writeLeafCell(&leaf, 0, key, value_offset, value);
}

fn writeFullLeafWithRange(page: *pager_module.Page, cell_count: usize, next_leaf_page_id: u32) !void {
    var leaf = btree.LeafNode.init(page, 0, next_leaf_page_id);
    for (0..cell_count) |index| {
        try leaf.writeCell(index, .{
            .key = @intCast(index),
            .value_offset = pager_module.page_size,
            .value_length = 0,
        });
    }
}

fn writeLeafCell(leaf: *btree.LeafNode, index: usize, key: u64, value_offset: u16, value: []const u8) !void {
    const start: usize = value_offset;
    @memcpy(leaf.page.data[start .. start + value.len], value);
    try leaf.writeCell(index, .{
        .key = key,
        .value_offset = value_offset,
        .value_length = @intCast(value.len),
    });
}

fn getU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}
