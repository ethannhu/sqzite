const std = @import("std");
const ast = @import("../sql/ast.zig");

pub const Column = ast.ColumnDef;

pub const TableSchema = struct {
    name: []const u8,
    root_page: u32,
    columns: []const Column,
};

/// 当前进程内的表目录；schema 字符串由 Catalog 持有。
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(TableSchema) = .empty,

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.tables.items) |table| {
            self.allocator.free(table.name);
            for (table.columns) |column| self.allocator.free(column.name);
            self.allocator.free(table.columns);
        }
        self.tables.deinit(self.allocator);
    }

    pub fn findTable(self: *const Catalog, name: []const u8) ?*const TableSchema {
        for (self.tables.items) |*table| {
            if (std.mem.eql(u8, table.name, name)) return table;
        }
        return null;
    }

    /// 注册 schema，并复制其名称，避免引用解析期临时内存。
    pub fn createTable(self: *Catalog, schema: TableSchema) !void {
        if (self.findTable(schema.name) != null) return error.TableAlreadyExists;
        const name = try self.allocator.dupe(u8, schema.name);
        errdefer self.allocator.free(name);
        const columns = try self.allocator.alloc(Column, schema.columns.len);
        var copied: usize = 0;
        errdefer {
            for (columns[0..copied]) |column| self.allocator.free(column.name);
            self.allocator.free(columns);
        }
        for (schema.columns, 0..) |column, i| {
            columns[i] = .{ .name = try self.allocator.dupe(u8, column.name), .type = column.type };
            copied += 1;
        }
        try self.tables.append(self.allocator, .{ .name = name, .root_page = schema.root_page, .columns = columns });
    }
};
