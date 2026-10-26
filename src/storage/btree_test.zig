//! B+ 树接口与节点重平衡单元测试。
const std = @import("std");
const btree = @import("btree.zig");
const node = @import("node.zig");
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
    var leaf = node.LeafNode.init(page, 0, 0);

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
    var internal = node.InternalNode.init(root, 0, 1);
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
    var internal = node.InternalNode.init(root, 0, 1);
    try internal.writeCell(0, .{ .separator_key = 1000, .child_page_id = 2 });

    const full_child = try pager.getPage(1);
    try writeFullLeafWithRange(full_child, node.leaf_layout.max_cells, 2);

    const right_child = try pager.getPage(2);
    try writeLeafEntry(right_child, 1000, 128, "right");

    // 0..339 已填满左叶子；500 应进入该子树并触发叶子分裂。
    try tree.insert(500, "inserted");

    try std.testing.expectEqual(@as(u16, 2), node.readU16(&root.data, node.header_layout.cell_count_offset));
    const split_right_id = node.readU32(
        &root.data,
        node.internal_layout.header_size + node.internal_cell_layout.child_page_id_offset,
    );
    try std.testing.expectEqual(split_right_id, node.readU32(&full_child.data, node.leaf_layout.next_leaf_page_id_offset));
    const split_right = try pager.getPage(split_right_id);
    try std.testing.expectEqual(@as(u32, 2), node.readU32(&split_right.data, node.leaf_layout.next_leaf_page_id_offset));
    for (0..node.leaf_layout.max_cells) |key| {
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
    try writeFullLeafWithRange(old_root, node.leaf_layout.max_cells, 0);

    try tree.insert(node.leaf_layout.max_cells, "new");

    try std.testing.expect(tree.root_page_id.? != old_root.id);
    const new_root = try pager.getPage(tree.root_page_id.?);
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(node.NodeType.internal)),
        new_root.data[node.header_layout.node_type_offset],
    );
    try std.testing.expectEqual(@as(u16, 1), node.readU16(&new_root.data, node.header_layout.cell_count_offset));
    try std.testing.expect((try tree.search(0)) != null);
    try std.testing.expect((try tree.search(170)) != null);
    try std.testing.expectEqualSlices(u8, "new", (try tree.search(node.leaf_layout.max_cells)).?);
}

test "叶子分裂穿过已满的父节点和根节点向上级联" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const full_internal_page = try pager.allocatePage();
    var inner_child_ids: [node.internal_layout.max_cells + 1]u32 = undefined;
    for (&inner_child_ids) |*child_id| {
        const child_page = try pager.allocatePage();
        child_id.* = child_page.id;
    }

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = root_page.id,
    };

    // 根和其第一个内部子节点均填满，目标叶子位于这两层的最左侧。
    var root = node.InternalNode.init(root_page, 0, full_internal_page.id);
    var full_internal = node.InternalNode.init(full_internal_page, root_page.id, inner_child_ids[0]);

    for (0..node.internal_layout.max_cells) |index| {
        try full_internal.writeCell(index, .{
            .separator_key = @as(u64, @intCast(index + 1)) * 1000,
            .child_page_id = inner_child_ids[index + 1],
        });
    }

    const first_leaf = try pager.getPage(inner_child_ids[0]);
    try writeFullLeafWithRange(first_leaf, node.leaf_layout.max_cells, inner_child_ids[1]);
    for (1..inner_child_ids.len) |index| {
        const leaf_page = try pager.getPage(inner_child_ids[index]);
        try writeLeafEntry(leaf_page, @as(u64, @intCast(index)) * 1000, pager_module.page_size, "");
    }

    for (0..node.internal_layout.max_cells) |index| {
        const sibling_page = try pager.allocatePage();
        try root.writeCell(index, .{
            .separator_key = @as(u64, @intCast(index + 1)) * 1_000_000,
            .child_page_id = sibling_page.id,
        });
        try writeLeafEntry(
            sibling_page,
            @as(u64, @intCast(index + 1)) * 1_000_000,
            pager_module.page_size,
            "",
        );
    }

    // 触发目标叶子分裂、满内部节点分裂，随后满根节点也分裂。
    try tree.insert(500, "inserted");

    try std.testing.expect(tree.root_page_id.? != root_page.id);
    const new_root = try pager.getPage(tree.root_page_id.?);
    try std.testing.expectEqual(@as(u16, 1), node.readU16(&new_root.data, node.header_layout.cell_count_offset));
    try std.testing.expectEqualSlices(u8, "inserted", (try tree.search(500)).?);
    try std.testing.expect((try tree.search(1000)) != null);
    try std.testing.expect((try tree.search(200_000_000)) != null);
    const split_right_id = node.readU32(&first_leaf.data, node.leaf_layout.next_leaf_page_id_offset);
    try std.testing.expect(split_right_id != inner_child_ids[1]);
    const split_right = try pager.getPage(split_right_id);
    try std.testing.expectEqual(inner_child_ids[1], node.readU32(&split_right.data, node.leaf_layout.next_leaf_page_id_offset));
}

test "同父节点下可取得左右兄弟页且边界返回 null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const left_page = try pager.allocatePage();
    const middle_page = try pager.allocatePage();
    const right_page = try pager.allocatePage();
    const unlinked_page = try pager.allocatePage();

    var root = node.InternalNode.init(root_page, 0, left_page.id);
    try root.writeCell(0, .{ .separator_key = 10, .child_page_id = middle_page.id });
    try root.writeCell(1, .{ .separator_key = 20, .child_page_id = right_page.id });

    _ = node.LeafNode.init(left_page, root_page.id, 0);
    _ = node.LeafNode.init(middle_page, root_page.id, 0);
    _ = node.LeafNode.init(right_page, root_page.id, 0);
    _ = node.LeafNode.init(unlinked_page, root_page.id, 0);

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = root_page.id,
    };

    try std.testing.expectEqual(left_page.id, (try tree.siblingPageId(middle_page.id, .previous)).?);
    try std.testing.expectEqual(right_page.id, (try tree.siblingPageId(middle_page.id, .next)).?);
    try std.testing.expectEqual(@as(?u32, null), try tree.siblingPageId(left_page.id, .previous));
    try std.testing.expectEqual(@as(?u32, null), try tree.siblingPageId(right_page.id, .next));
    try std.testing.expectEqual(@as(?u32, null), try tree.siblingPageId(root_page.id, .next));
    try std.testing.expectError(error.CorruptNode, tree.siblingPageId(unlinked_page.id, .previous));
}

test "兄弟页接口报告非内部父节点" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    const root_page = try pager.allocatePage();
    const current_page = try pager.allocatePage();
    const invalid_parent_page = try pager.allocatePage();
    _ = node.LeafNode.init(root_page, 0, 0);
    _ = node.LeafNode.init(current_page, invalid_parent_page.id, 0);
    _ = node.LeafNode.init(invalid_parent_page, 0, 0);

    var tree = btree.BPlusTree{
        .pager = &pager,
        .root_page_id = root_page.id,
    };

    try std.testing.expectError(error.InvalidNodeType, tree.siblingPageId(current_page.id, .next));
}

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
    try writeLeafWithValue(right_page, root_page.id, 20, "right");

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

    try writeLeafWithValue(leaf_a, left_page.id, 10, "a");
    try writeLeafWithValue(leaf_b, left_page.id, 50, "b");
    try writeLeafWithValue(leaf_c, right_page.id, 100, "c");
    try writeLeafWithValue(leaf_d, right_page.id, 150, "d");

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

fn writeLeafEntry(page: *pager_module.Page, key: u64, value_offset: u16, value: []const u8) !void {
    var leaf = node.LeafNode.init(page, 0, 0);
    try writeLeafCell(&leaf, 0, key, value_offset, value);
}

fn writeFullLeafWithRange(page: *pager_module.Page, cell_count: usize, next_leaf_page_id: u32) !void {
    var leaf = node.LeafNode.init(page, 0, next_leaf_page_id);
    for (0..cell_count) |index| {
        try leaf.writeCell(index, .{
            .key = @intCast(index),
            .value_offset = pager_module.page_size,
            .value_length = 0,
        });
    }
}

fn writeLeafCell(leaf: *node.LeafNode, index: usize, key: u64, value_offset: u16, value: []const u8) !void {
    const start: usize = value_offset;
    @memcpy(leaf.page.data[start .. start + value.len], value);
    try leaf.writeCell(index, .{
        .key = key,
        .value_offset = value_offset,
        .value_length = @intCast(value.len),
    });
}

fn writeLeafWithValue(page: *pager_module.Page, parent_page_id: u32, key: u64, value: []const u8) !void {
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

fn writeLeaf(page: *pager_module.Page, parent_page_id: u32, key: u64) !void {
    var leaf = node.LeafNode.init(page, parent_page_id, 0);
    try leaf.insertRecord(key, "value");
}

fn fillLeafRecords(leaf: *node.LeafNode, first_key: u64, count: usize, value: []const u8) !void {
    for (0..count) |index| try leaf.insertRecord(first_key + @as(u64, @intCast(index)), value);
}
