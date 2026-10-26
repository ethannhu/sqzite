const std = @import("std");
const lexer = @import("lexer.zig");

test "Lexer 识别 SQL 语句中的关键字与符号" {
    var scanner = lexer.Lexer.init("CREATE TABLE users (id INTEGER, name TEXT);");
    const expected = [_]lexer.Tag{
        .create, .table,      .identifier, .left_paren,  .identifier, .integer_type,
        .comma,  .identifier, .text_type,  .right_paren, .semicolon,  .eof,
    };
    for (expected) |tag| try std.testing.expectEqual(tag, scanner.next().tag);
}

test "Lexer 识别值、比较符和逻辑关键字" {
    var scanner = lexer.Lexer.init("INSERT INTO t VALUES (42, 'O''Reilly') WHERE id=42 AND name='x';");
    const tags = [_]lexer.Tag{
        .insert,     .into,        .identifier, .values,     .left_paren, .integer, .comma,
        .string,     .right_paren, .where,      .identifier, .equal,      .integer, .and_,
        .identifier, .equal,       .string,     .semicolon,  .eof,
    };
    for (tags) |tag| try std.testing.expectEqual(tag, scanner.next().tag);
}

test "Lexer 对关键字大小写不敏感并保留标识符" {
    var scanner = lexer.Lexer.init("SeLeCt Selectx");
    const keyword = scanner.next();
    try std.testing.expectEqual(lexer.Tag.select, keyword.tag);
    const identifier = scanner.next();
    try std.testing.expectEqual(lexer.Tag.identifier, identifier.tag);
    try std.testing.expectEqualStrings("Selectx", identifier.lexeme);
}

test "Lexer 将未知字符和未闭合字符串标为无效 token" {
    var scanner = lexer.Lexer.init("@ 'unfinished");
    try std.testing.expectEqual(lexer.Tag.invalid, scanner.next().tag);
    try std.testing.expectEqual(lexer.Tag.invalid, scanner.next().tag);
    try std.testing.expectEqual(lexer.Tag.eof, scanner.next().tag);
}
