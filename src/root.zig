//! 项目库模块入口。
const std = @import("std");
const Io = std.Io;

pub const btree = @import("storage/btree.zig");
pub const node = @import("storage/node.zig");
pub const pager = @import("storage/pager.zig");
pub const record = @import("storage/record.zig");
pub const table = @import("storage/table.zig");
pub const sql_ast = @import("sql/ast.zig");
pub const lexer = @import("sql/lexer.zig");
pub const parser = @import("sql/parser.zig");
pub const binder = @import("sql/binder.zig");
pub const planner = @import("sql/planner.zig");
pub const catalog = @import("catalog/catalog.zig");

/// 向指定 writer 输出测试提示。
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "加法返回两个整数之和" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    _ = @import("storage/pager_test.zig");
    _ = @import("storage/btree_test.zig");
    _ = @import("storage/node_test.zig");
    _ = @import("storage/table_test.zig");
    _ = @import("sql/lexer_test.zig");
}
