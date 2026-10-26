const std = @import("std");
const btree = @import("btree.zig");
const pager_module = @import("pager.zig");
const record = @import("record.zig");
const table_module = @import("table.zig");

test "插入记录后可按 rowid 读取列值" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = null };
    const columns = [_]record.Column{
        .{ .name = "name", .type = .text },
        .{ .name = "age", .type = .integer },
    };
    var table = table_module.Table{
        .root_page = 0,
        .schema = .{ .columns = &columns },
        .btree = &tree,
    };
    const values = [_]record.Value{
        .{ .text = "Alice" },
        .{ .integer = 20 },
    };

    try table.insert(42, .{ .values = &values });

    const found = (try table.get(42)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), found.values.len);
    try std.testing.expectEqualStrings("Alice", found.values[0].text);
    try std.testing.expectEqual(@as(i64, 20), found.values[1].integer);
    try std.testing.expect((try table.get(43)) == null);
}

test "不同 rowid 的记录互不覆盖" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = null };
    const columns = [_]record.Column{.{ .name = "value", .type = .integer }};
    var table = table_module.Table{
        .root_page = 0,
        .schema = .{ .columns = &columns },
        .btree = &tree,
    };
    const first = [_]record.Value{.{ .integer = 100 }};
    const second = [_]record.Value{.{ .integer = 200 }};

    try table.insert(1, .{ .values = &first });
    try table.insert(2, .{ .values = &second });

    const actual_first = (try table.get(1)).?;
    defer actual_first.deinit(std.testing.allocator);
    const actual_second = (try table.get(2)).?;
    defer actual_second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 100), actual_first.values[0].integer);
    try std.testing.expectEqual(@as(i64, 200), actual_second.values[0].integer);
}

test "负 rowid 可以插入并读取" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = null };
    const columns = [_]record.Column{.{ .name = "value", .type = .integer }};
    var table = table_module.Table{
        .root_page = 0,
        .schema = .{ .columns = &columns },
        .btree = &tree,
    };
    const values = [_]record.Value{.{ .integer = -9223372036854775807 - 1 }};

    try table.insert(-1, .{ .values = &values });
    const found = (try table.get(-1)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(values[0].integer, found.values[0].integer);
}

test "删除记录后查询不到且不影响其他记录" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pager = try pager_module.Pager.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "db",
    );
    defer pager.close() catch {};

    var tree = btree.BPlusTree{ .pager = &pager, .root_page_id = null };
    const columns = [_]record.Column{.{ .name = "value", .type = .text }};
    var table = table_module.Table{
        .root_page = 0,
        .schema = .{ .columns = &columns },
        .btree = &tree,
    };
    const first = [_]record.Value{.{ .text = "remove me" }};
    const second = [_]record.Value{.{ .text = "keep me" }};

    try table.insert(10, .{ .values = &first });
    try table.insert(20, .{ .values = &second });
    try table.delete(10);

    try std.testing.expect((try table.get(10)) == null);
    const remaining = (try table.get(20)).?;
    defer remaining.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("keep me", remaining.values[0].text);
}
