const std = @import("std");
const catalog_mod = @import("../catalog/catalog.zig");
const binder_mod = @import("../sql/binder.zig");
const parser_mod = @import("../sql/parser.zig");
const executor_mod = @import("executor.zig");
const node = @import("../storage/node.zig");
const pager_mod = @import("../storage/pager.zig");

test "CREATE TABLE 经 Parser、Binder 后创建空表并登记 schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pager = try pager_mod.Pager.open(std.testing.allocator, std.testing.io, tmp.dir, "db");
    defer pager.close() catch {};

    var catalog = catalog_mod.Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = parser_mod.Parser.init(arena.allocator(), "CREATE TABLE users (id INTEGER, name TEXT)");
    const statement = try parser.parse();
    const binder = binder_mod.Binder{ .catalog = &catalog };
    const bound = try binder.bind(statement);
    var executor = executor_mod.Executor{ .pager = &pager, .catalog = &catalog };
    try executor.execute(bound);

    const table = catalog.findTable("users").?;
    try std.testing.expectEqual(@as(usize, 2), table.columns.len);
    try std.testing.expectEqual(@import("../sql/ast.zig").ColumnType.integer, table.columns[0].type);
    const root = try pager.getPage(table.root_page);
    try std.testing.expectEqual(node.NodeType.leaf, @as(node.NodeType, @enumFromInt(root.data[0])));
}

test "Binder 拒绝重复表名和重复列名" {
    var catalog = catalog_mod.Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    const first_cols = [_]@import("../sql/ast.zig").ColumnDef{.{ .name = "id", .type = .integer }};
    try catalog.createTable(.{ .name = "users", .root_page = 0, .columns = &first_cols });

    const binder = binder_mod.Binder{ .catalog = &catalog };
    const duplicate_table_cols = [_]@import("../sql/ast.zig").ColumnDef{.{ .name = "x", .type = .integer }};
    try std.testing.expectError(error.TableAlreadyExists, binder.bind(.{ .create_table = .{ .name = "users", .columns = &duplicate_table_cols } }));
    const duplicate_cols = [_]@import("../sql/ast.zig").ColumnDef{
        .{ .name = "id", .type = .integer },
        .{ .name = "id", .type = .text },
    };
    try std.testing.expectError(error.DuplicateColumn, binder.bind(.{ .create_table = .{ .name = "items", .columns = &duplicate_cols } }));
}
