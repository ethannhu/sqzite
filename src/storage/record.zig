const std = @import("std");

/// 列的声明类型。
pub const ColumnType = enum {
    any,
    integer,
    real,
    text,
    blob,
};

/// 列定义由表的 Schema 持有。
pub const Column = struct {
    name: []const u8,
    type: ColumnType = .any,
};

/// 表的列定义。
pub const Schema = struct {
    columns: []const Column,
};

/// 一列的运行时值。
pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// 一条记录；values 按 Schema.columns 的顺序排列。解码所得 values 需用 deinit 释放。
pub const Record = struct {
    values: []const Value,

    /// 将记录编码为 SQLite serial type Header 与 Body。
    pub fn serialize(self: Record, allocator: std.mem.Allocator) ![]u8 {
        var serial_types = try allocator.alloc(u64, self.values.len);
        defer allocator.free(serial_types);

        var header_descriptors = try allocator.alloc(u8, self.values.len * 9);
        defer allocator.free(header_descriptors);
        var descriptor_len: usize = 0;
        var body_len: usize = 0;
        for (self.values, 0..) |value, i| {
            const serial = switch (value) {
                .null => 0,
                .integer => |n| integerSerialType(n),
                .real => 7,
                .text => |bytes| 13 + 2 * bytes.len,
                .blob => |bytes| 12 + 2 * bytes.len,
            };
            serial_types[i] = serial;
            descriptor_len += writeVarint(header_descriptors[descriptor_len..], serial);
            body_len += switch (value) {
                .null => 0,
                .integer => |n| integerByteLength(n),
                .real => 8,
                .text, .blob => |bytes| bytes.len,
            };
        }

        var header_size = descriptor_len + 1;
        while (varintLength(header_size) + descriptor_len != header_size) {
            header_size = varintLength(header_size) + descriptor_len;
        }
        const output = try allocator.alloc(u8, header_size + body_len);
        errdefer allocator.free(output);
        var header_offset = writeVarint(output, header_size);
        @memcpy(output[header_offset .. header_offset + descriptor_len], header_descriptors[0..descriptor_len]);
        header_offset += descriptor_len;

        var body_offset = header_size;
        for (self.values) |value| {
            switch (value) {
                .null => {},
                .integer => |n| {
                    const byte_len = integerByteLength(n);
                    writeBigEndian(output[body_offset .. body_offset + byte_len], @bitCast(n));
                    body_offset += byte_len;
                },
                .real => |n| {
                    writeBigEndian(output[body_offset .. body_offset + 8], @bitCast(n));
                    body_offset += 8;
                },
                .text, .blob => |bytes| {
                    @memcpy(output[body_offset .. body_offset + bytes.len], bytes);
                    body_offset += bytes.len;
                },
            }
        }
        std.debug.assert(header_offset == header_size);
        return output;
    }

    /// 根据 Schema 解码记录；values 数组由 allocator 分配，文本和二进制切片借用 data。
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8, schema: Schema) !Record {
        if (data.len == 0) return error.InvalidRecord;
        var cursor: usize = 0;
        const header_size_u64 = try readVarint(data, &cursor);
        if (header_size_u64 > data.len or header_size_u64 < cursor) return error.InvalidRecord;
        const header_size: usize = @intCast(header_size_u64);
        const values = try allocator.alloc(Value, schema.columns.len);
        errdefer allocator.free(values);

        var body_offset = header_size;
        for (values) |*value| {
            if (cursor >= header_size) return error.ColumnCountMismatch;
            const serial = try readVarint(data[0..header_size], &cursor);
            value.* = switch (serial) {
                0 => .null,
                1...6 => blk: {
                    const len = serialTypeByteLength(serial);
                    const bits = try readBigEndian(data, &body_offset, len);
                    const signed: i64 = if (len == 8)
                        @bitCast(bits)
                    else if ((bits & (@as(u64, 1) << @intCast(len * 8 - 1))) != 0)
                        @bitCast(bits | ~(@as(u64, 0) >> @intCast(len * 8)))
                    else
                        @intCast(bits);
                    break :blk .{ .integer = signed };
                },
                7 => .{ .real = @bitCast(try readBigEndian(data, &body_offset, 8)) },
                8 => .{ .integer = 0 },
                9 => .{ .integer = 1 },
                else => blk: {
                    if (serial < 12) return error.InvalidRecord;
                    const is_blob = serial % 2 == 0;
                    const len: usize = @intCast((serial - (if (is_blob) @as(u64, 12) else 13)) / 2);
                    if (body_offset > data.len or len > data.len - body_offset) return error.InvalidRecord;
                    const bytes = data[body_offset .. body_offset + len];
                    body_offset += len;
                    break :blk if (is_blob) .{ .blob = bytes } else .{ .text = bytes };
                },
            };
        }
        if (cursor != header_size or body_offset != data.len) return error.InvalidRecord;
        return .{ .values = values };
    }

    /// 释放 values 数组；text 与 blob 切片借用输入 payload，不由此释放。
    pub fn deinit(self: Record, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }
};

fn integerSerialType(value: i64) u64 {
    return switch (integerByteLength(value)) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        6 => 5,
        8 => 6,
        else => unreachable,
    };
}

fn integerByteLength(value: i64) usize {
    if (value >= -128 and value <= 127) return 1;
    if (value >= -32768 and value <= 32767) return 2;
    if (value >= -8388608 and value <= 8388607) return 3;
    if (value >= -2147483648 and value <= 2147483647) return 4;
    if (value >= -140737488355328 and value <= 140737488355327) return 6;
    return 8;
}

fn serialTypeByteLength(serial: u64) usize {
    return switch (serial) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        5 => 6,
        6 => 8,
        else => unreachable,
    };
}

fn varintLength(value: usize) usize {
    var remaining = value;
    var length: usize = 1;
    while (remaining > 0x7f) : (length += 1) remaining >>= 7;
    return length;
}

fn writeVarint(output: []u8, value: u64) usize {
    var groups: [10]u8 = undefined;
    var remaining = value;
    var len: usize = 0;
    while (remaining > 0x7f) : (len += 1) {
        groups[len] = @intCast(remaining & 0x7f);
        remaining >>= 7;
    }
    groups[len] = @intCast(remaining);
    len += 1;
    for (0..len) |i| {
        const group = groups[len - i - 1];
        output[i] = group | (if (i + 1 < len) @as(u8, 0x80) else 0);
    }
    return len;
}

fn readVarint(data: []const u8, offset: *usize) error{InvalidRecord}!u64 {
    var result: u64 = 0;
    var count: usize = 0;
    while (offset.* < data.len and count < 9) : (count += 1) {
        const byte = data[offset.*];
        offset.* += 1;
        result = (result << 7) | (byte & 0x7f);
        if ((byte & 0x80) == 0) return result;
    }
    return error.InvalidRecord;
}

fn writeBigEndian(output: []u8, bits: u64) void {
    for (output, 0..) |*byte, i| {
        const shift: u6 = @intCast((output.len - i - 1) * 8);
        byte.* = @truncate(bits >> shift);
    }
}

fn readBigEndian(data: []const u8, offset: *usize, len: usize) error{InvalidRecord}!u64 {
    if (offset.* > data.len or len > data.len - offset.* or len > 8) return error.InvalidRecord;
    var bits: u64 = 0;
    for (data[offset.* .. offset.* + len]) |byte| bits = (bits << 8) | byte;
    offset.* += len;
    return bits;
}
