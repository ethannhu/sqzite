const std = @import("std");
const Io = std.Io;
const zig_hello = @import("zig_hello");

/// 启动交互 Shell；可用第一个参数指定数据库文件。
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const path = if (args.len > 1) args[1] else "sqzite.db";

    var pager = try zig_hello.pager.Pager.open(allocator, init.io, Io.Dir.cwd(), path);
    defer pager.close() catch {};
    var catalog = try zig_hello.catalog.Catalog.open(allocator, &pager);
    defer catalog.deinit();
    var executor = zig_hello.executor.Executor{ .pager = &pager, .catalog = &catalog };
    var repl = zig_hello.shell.Repl{ .allocator = allocator, .catalog = &catalog, .executor = &executor };

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try repl.run(&stdin_reader.interface, &stdout_file_writer.interface);
    try stdout_file_writer.interface.flush();
}
