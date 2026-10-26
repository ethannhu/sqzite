const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

fn parse(allocator: std.mem.Allocator, sql: []const u8) !ast.Statement {
    var parser = parser_mod.Parser.init(allocator, sql);
    return parser.parse();
}

test "Parser 解析 CREATE TABLE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const statement = try parse(arena.allocator(), "CREATE TABLE users (id INTEGER, name TEXT);");
    const create = statement.create_table;
    try std.testing.expectEqualStrings("users", create.name);
    try std.testing.expectEqual(@as(usize, 2), create.columns.len);
    try std.testing.expectEqual(ast.ColumnType.integer, create.columns[0].type);
    try std.testing.expectEqual(ast.ColumnType.text, create.columns[1].type);
}

test "Parser 解析 INSERT 与字符串值" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const statement = try parse(arena.allocator(), "INSERT INTO users VALUES (7, 'O''Reilly')");
    const insert = statement.insert;
    try std.testing.expectEqual(@as(usize, 2), insert.values.len);
    try std.testing.expectEqual(@as(i64, 7), insert.values[0].integer);
    try std.testing.expectEqualStrings("O'Reilly", insert.values[1].string);
}

test "Parser 解析 SELECT 和 Pratt 条件优先级" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const statement = try parse(arena.allocator(), "SELECT name FROM users WHERE id = 1 AND name = 'A'");
    const select = statement.select;
    try std.testing.expectEqualStrings("name", select.columns[0]);
    const conjunction = select.where.?.binary;
    try std.testing.expectEqual(ast.BinaryOp.and_, conjunction.op);
    try std.testing.expectEqual(ast.BinaryOp.equal, conjunction.lhs.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.equal, conjunction.rhs.binary.op);
}

test "Parser 解析 UPDATE 与 DELETE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const updated = try parse(arena.allocator(), "UPDATE users SET name = 'B' WHERE id = 1");
    try std.testing.expectEqualStrings("name", updated.update.assignments[0].column);
    try std.testing.expectEqual(ast.BinaryOp.equal, updated.update.where.?.binary.op);
    const deleted = try parse(arena.allocator(), "DELETE FROM users WHERE id = 1;");
    try std.testing.expectEqualStrings("users", deleted.delete.table);
}

test "Parser 拒绝不支持的语法和多条语句" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var join_parser = parser_mod.Parser.init(arena.allocator(), "SELECT * FROM a JOIN b");
    try std.testing.expectError(error.InvalidSyntax, join_parser.parse());
    var multi_parser = parser_mod.Parser.init(arena.allocator(), "DELETE FROM users; DELETE FROM users");
    try std.testing.expectError(error.InvalidSyntax, multi_parser.parse());
}
