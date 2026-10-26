/// SQL 词法单元。
pub const Token = struct {
    tag: Tag,
    lexeme: []const u8,
};

pub const Tag = enum {
    eof,
    invalid,
    identifier,
    integer,
    string,
    create,
    table,
    insert,
    into,
    values,
    select,
    from,
    where,
    update,
    set,
    delete,
    integer_type,
    text_type,
    and_,
    star,
    comma,
    left_paren,
    right_paren,
    equal,
    semicolon,
};

/// 逐个读取 SQL token；token 内容引用输入 SQL。
pub const Lexer = struct {
    input: []const u8,
    offset: usize = 0,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input };
    }

    pub fn next(self: *Lexer) Token {
        while (self.offset < self.input.len and isWhitespace(self.input[self.offset])) : (self.offset += 1) {}
        if (self.offset == self.input.len) return .{ .tag = .eof, .lexeme = self.input[self.offset..] };

        const start = self.offset;
        const ch = self.input[self.offset];
        if (isIdentifierStart(ch)) {
            self.offset += 1;
            while (self.offset < self.input.len and isIdentifierContinue(self.input[self.offset])) : (self.offset += 1) {}
            const lexeme = self.input[start..self.offset];
            return .{ .tag = keywordTag(lexeme) orelse .identifier, .lexeme = lexeme };
        }
        if (isDigit(ch)) {
            self.offset += 1;
            while (self.offset < self.input.len and isDigit(self.input[self.offset])) : (self.offset += 1) {}
            return .{ .tag = .integer, .lexeme = self.input[start..self.offset] };
        }
        if (ch == '\'') return self.readString();

        self.offset += 1;
        return .{ .tag = switch (ch) {
            '*' => .star,
            ',' => .comma,
            '(' => .left_paren,
            ')' => .right_paren,
            '=' => .equal,
            ';' => .semicolon,
            else => .invalid,
        }, .lexeme = self.input[start..self.offset] };
    }

    fn readString(self: *Lexer) Token {
        const start = self.offset;
        self.offset += 1;
        while (self.offset < self.input.len) {
            if (self.input[self.offset] == '\'') {
                self.offset += 1;
                if (self.offset < self.input.len and self.input[self.offset] == '\'') {
                    self.offset += 1;
                    continue;
                }
                return .{ .tag = .string, .lexeme = self.input[start..self.offset] };
            }
            self.offset += 1;
        }
        return .{ .tag = .invalid, .lexeme = self.input[start..self.offset] };
    }
};

fn keywordTag(word: []const u8) ?Tag {
    const keywords = .{
        .{ "create", Tag.create },  .{ "table", Tag.table },   .{ "insert", Tag.insert },
        .{ "into", Tag.into },      .{ "values", Tag.values }, .{ "select", Tag.select },
        .{ "from", Tag.from },      .{ "where", Tag.where },   .{ "update", Tag.update },
        .{ "set", Tag.set },        .{ "delete", Tag.delete }, .{ "integer", Tag.integer_type },
        .{ "text", Tag.text_type }, .{ "and", Tag.and_ },
    };
    inline for (keywords) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    }
    return null;
}

const std = @import("std");

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or isDigit(ch);
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}
