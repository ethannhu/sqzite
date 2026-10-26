const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

/// 将 token 流解析为语法树；语法树内存由调用方提供的 allocator 管理。
pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer.Lexer,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{ .allocator = allocator, .lexer = lexer.Lexer.init(input) };
    }

    pub fn parse(self: *Parser) anyerror!ast.Statement {
        _ = self;
        unreachable;
    }
};
