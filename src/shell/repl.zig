const std = @import("std");
const Io = std.Io;
const catalog_mod = @import("../catalog/catalog.zig");
const binder_mod = @import("../sql/binder.zig");
const parser_mod = @import("../sql/parser.zig");
const executor_mod = @import("../execution/executor.zig");

const Action = enum { continue_, quit };

/// 简单的逐行 SQL 交互 Shell。
pub const Repl = struct {
    allocator: std.mem.Allocator,
    catalog: *catalog_mod.Catalog,
    executor: *executor_mod.Executor,

    pub fn run(self: *Repl, reader: *Io.Reader, writer: *Io.Writer) !void {
        while (true) {
            try writer.writeAll("sqzite> ");
            try writer.flush();
            const line = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = reader.discardDelimiterInclusive('\n') catch {};
                    try writer.writeAll("错误: 输入行过长\n");
                    continue;
                },
                else => return err,
            } orelse break;
            if (try self.executeLine(writer, line) == .quit) break;
        }
    }

    /// 执行一条点命令或 SQL，便于嵌入其他前端。
    pub fn executeLine(self: *Repl, writer: *Io.Writer, raw_line: []const u8) !Action {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) return .continue_;
        if (line[0] == '.') return self.executeDotCommand(writer, line);
        self.executeSql(writer, line) catch |err| try writer.print("错误: {s}\n", .{@errorName(err)});
        return .continue_;
    }

    fn executeDotCommand(self: *Repl, writer: *Io.Writer, line: []const u8) !Action {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        const command = tokens.next() orelse return .continue_;
        if (std.mem.eql(u8, command, ".quit") or std.mem.eql(u8, command, ".exit")) return .quit;
        if (std.mem.eql(u8, command, ".help")) {
            try writer.writeAll("可用命令:\n  .help          显示帮助\n  .tables        列出表\n  .schema <表名> 显示表结构\n  .quit          退出\n");
        } else if (std.mem.eql(u8, command, ".tables")) {
            for (self.catalog.tables.items) |table| try writer.print("{s}\n", .{table.name});
        } else if (std.mem.eql(u8, command, ".schema")) {
            const name = tokens.next() orelse {
                try writer.writeAll("用法: .schema <表名>\n");
                return .continue_;
            };
            if (self.catalog.findTable(name)) |table| {
                try writer.print("{s} (", .{table.name});
                for (table.columns, 0..) |column, i| {
                    if (i != 0) try writer.writeAll(", ");
                    try writer.print("{s} {s}", .{ column.name, @tagName(column.type) });
                }
                try writer.writeAll(")\n");
            } else {
                try writer.print("未找到表: {s}\n", .{name});
            }
        } else {
            try writer.print("未知命令: {s}，输入 .help 查看帮助\n", .{command});
        }
        return .continue_;
    }

    fn executeSql(self: *Repl, writer: *Io.Writer, sql: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var parser = parser_mod.Parser.init(arena.allocator(), sql);
        const statement = try parser.parse();
        const binder = binder_mod.Binder{ .catalog = self.catalog };
        const bound = try binder.bind(statement);
        try self.executor.execute(bound);
        try writer.writeAll("执行成功\n");
    }
};
