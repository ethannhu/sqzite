//! BPlusTree 兄弟页导航接口测试。
const std = @import("std");
const btree = @import("btree.zig");
const node = @import("node.zig");
const pager_module = @import("pager.zig");

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
