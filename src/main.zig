const std = @import("std");
const Io = std.Io;

const zig_hello = @import("zig_hello");

pub fn main(init: std.process.Init) !void {
    // 输出调试信息，忽略写入错误。
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // arena 生命周期与进程一致。
    const arena: std.mem.Allocator = init.arena.allocator();

    // 读取命令行参数。
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // 获取执行 I/O 所需的实例。
    const io = init.io;

    // stdout 用于程序输出，调试信息应写入 stderr。
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try zig_hello.printAnotherMessage(stdout_writer);

    try stdout_writer.flush(); // 刷新缓冲区。
}

test "列表可以追加并弹出元素" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // 释放列表占用的内存。
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "模糊测试验证列表复制数据" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // 使用 `zig build test --fuzz` 生成更多输入。

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
