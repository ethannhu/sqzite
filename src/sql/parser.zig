const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

/// 递归下降解析语句，使用 Pratt 方法解析表达式。
pub const Parser = struct {
    allocator: std.mem.Allocator,
    scanner: lexer.Lexer,
    current: lexer.Token,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        var scanner = lexer.Lexer.init(input);
        const first = scanner.next();
        return .{ .allocator = allocator, .scanner = scanner, .current = first };
    }

    /// 解析一条语句，可带末尾分号。
    pub fn parse(self: *Parser) anyerror!ast.Statement {
        const statement = try self.parseStatement();
        if (self.current.tag == .semicolon) self.advance();
        try self.expect(.eof);
        return statement;
    }

    fn parseStatement(self: *Parser) anyerror!ast.Statement {
        return switch (self.current.tag) {
            .create => .{ .create_table = try self.parseCreateTable() },
            .insert => .{ .insert = try self.parseInsert() },
            .select => .{ .select = try self.parseSelect() },
            .update => .{ .update = try self.parseUpdate() },
            .delete => .{ .delete = try self.parseDelete() },
            else => error.InvalidSyntax,
        };
    }

    fn parseCreateTable(self: *Parser) anyerror!ast.CreateTable {
        try self.expect(.create);
        try self.expect(.table);
        const name = try self.identifier();
        try self.expect(.left_paren);
        var columns: std.ArrayList(ast.ColumnDef) = .empty;
        while (true) {
            const column_name = try self.identifier();
            const column_type: ast.ColumnType = switch (self.current.tag) {
                .integer_type => .integer,
                .text_type => .text,
                else => return error.InvalidSyntax,
            };
            self.advance();
            try columns.append(self.allocator, .{ .name = column_name, .type = column_type });
            if (self.current.tag != .comma) break;
            self.advance();
        }
        try self.expect(.right_paren);
        return .{ .name = name, .columns = try columns.toOwnedSlice(self.allocator) };
    }

    fn parseInsert(self: *Parser) anyerror!ast.Insert {
        try self.expect(.insert);
        try self.expect(.into);
        const table_name = try self.identifier();
        try self.expect(.values);
        try self.expect(.left_paren);
        const values = try self.parseExprList(.right_paren);
        try self.expect(.right_paren);
        return .{ .table = table_name, .values = values };
    }

    fn parseSelect(self: *Parser) anyerror!ast.Select {
        try self.expect(.select);
        var columns: std.ArrayList([]const u8) = .empty;
        if (self.current.tag == .star) {
            try columns.append(self.allocator, "*");
            self.advance();
        } else {
            while (true) {
                try columns.append(self.allocator, try self.identifier());
                if (self.current.tag != .comma) break;
                self.advance();
            }
        }
        try self.expect(.from);
        const table_name = try self.identifier();
        const condition = try self.parseOptionalWhere();
        return .{ .table = table_name, .columns = try columns.toOwnedSlice(self.allocator), .where = condition };
    }

    fn parseUpdate(self: *Parser) anyerror!ast.Update {
        try self.expect(.update);
        const table_name = try self.identifier();
        try self.expect(.set);
        var assignments: std.ArrayList(ast.Assignment) = .empty;
        while (true) {
            const column = try self.identifier();
            try self.expect(.equal);
            try assignments.append(self.allocator, .{ .column = column, .value = try self.parseExpr(0) });
            if (self.current.tag != .comma) break;
            self.advance();
        }
        const condition = try self.parseOptionalWhere();
        return .{ .table = table_name, .assignments = try assignments.toOwnedSlice(self.allocator), .where = condition };
    }

    fn parseDelete(self: *Parser) anyerror!ast.Delete {
        try self.expect(.delete);
        try self.expect(.from);
        const table_name = try self.identifier();
        return .{ .table = table_name, .where = try self.parseOptionalWhere() };
    }

    fn parseOptionalWhere(self: *Parser) anyerror!?ast.Expr {
        if (self.current.tag != .where) return null;
        self.advance();
        return try self.parseExpr(0);
    }

    fn parseExprList(self: *Parser, end: lexer.Tag) anyerror![]ast.Expr {
        var items: std.ArrayList(ast.Expr) = .empty;
        while (true) {
            try items.append(self.allocator, try self.parseExpr(0));
            if (self.current.tag != .comma) break;
            self.advance();
        }
        if (self.current.tag != end) return error.InvalidSyntax;
        return try items.toOwnedSlice(self.allocator);
    }

    // AND 优先级低于等号；递归右侧使用更高 binding power 保持左结合。
    fn parseExpr(self: *Parser, min_bp: u8) anyerror!ast.Expr {
        var lhs = try self.parsePrimary();
        while (true) {
            const binding_power: u8 = switch (self.current.tag) {
                .and_ => 1,
                .equal => 3,
                else => break,
            };
            if (binding_power < min_bp) break;
            const op: ast.BinaryOp = if (self.current.tag == .and_) .and_ else .equal;
            self.advance();
            const rhs = try self.parseExpr(binding_power + 1);
            const lhs_ptr = try self.allocator.create(ast.Expr);
            lhs_ptr.* = lhs;
            const rhs_ptr = try self.allocator.create(ast.Expr);
            rhs_ptr.* = rhs;
            lhs = .{ .binary = .{ .op = op, .lhs = lhs_ptr, .rhs = rhs_ptr } };
        }
        return lhs;
    }

    fn parsePrimary(self: *Parser) anyerror!ast.Expr {
        const token = self.current;
        switch (token.tag) {
            .integer => {
                self.advance();
                return .{ .integer = try std.fmt.parseInt(i64, token.lexeme, 10) };
            },
            .string => {
                self.advance();
                return .{ .string = try self.decodeString(token.lexeme) };
            },
            .identifier => {
                self.advance();
                return .{ .column = token.lexeme };
            },
            else => return error.InvalidSyntax,
        }
    }

    fn decodeString(self: *Parser, quoted: []const u8) ![]const u8 {
        const decoded = try self.allocator.alloc(u8, quoted.len - 2);
        var read: usize = 1;
        var write: usize = 0;
        while (read < quoted.len - 1) : (read += 1) {
            decoded[write] = quoted[read];
            write += 1;
            if (quoted[read] == '\'' and read + 1 < quoted.len - 1 and quoted[read + 1] == '\'') read += 1;
        }
        return decoded[0..write];
    }

    fn identifier(self: *Parser) anyerror![]const u8 {
        if (self.current.tag != .identifier) return error.InvalidSyntax;
        const name = self.current.lexeme;
        self.advance();
        return name;
    }

    fn expect(self: *Parser, tag: lexer.Tag) anyerror!void {
        if (self.current.tag != tag) return error.InvalidSyntax;
        self.advance();
    }

    fn advance(self: *Parser) void {
        self.current = self.scanner.next();
    }
};
