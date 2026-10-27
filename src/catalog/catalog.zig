const std = @import("std");
const ast = @import("../sql/ast.zig");
const pager_mod = @import("../storage/pager.zig");

pub const Column = ast.ColumnDef;
pub const TableSchema = struct { name: []const u8, root_page: u32, columns: []const Column };

const magic = "SQZCAT01";
const header_size = magic.len + 2;

/// Catalog 页固定为 0 号页；schema 名称由 Catalog 持有。
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    pager: *pager_mod.Pager,
    page: *pager_mod.Page,
    tables: std.ArrayList(TableSchema) = .empty,

    /// 加载已有 Catalog；空数据库会初始化 0 号页。
    pub fn open(allocator: std.mem.Allocator, pager: *pager_mod.Pager) !Catalog {
        const page = try pager.getPage(0);
        var result = Catalog{ .allocator = allocator, .pager = pager, .page = page };
        errdefer result.deinit();

        if (std.mem.eql(u8, page.data[0..magic.len], magic)) {
            try result.load();
        } else {
            for (page.data) |byte| {
                if (byte != 0) return error.InvalidCatalog;
            }
            try result.persist();
        }
        return result;
    }

    pub fn deinit(self: *Catalog) void {
        for (self.tables.items) |table| self.freeSchema(table);
        self.tables.deinit(self.allocator);
    }

    pub fn findTable(self: *const Catalog, name: []const u8) ?*const TableSchema {
        for (self.tables.items) |*table| {
            if (std.mem.eql(u8, table.name, name)) return table;
        }
        return null;
    }

    /// 注册 schema 并立即刷新 Catalog 页。
    pub fn createTable(self: *Catalog, schema: TableSchema) !void {
        if (self.findTable(schema.name) != null) return error.TableAlreadyExists;
        try self.checkFits(schema);
        const owned = try self.copySchema(schema);
        errdefer self.freeSchema(owned);
        try self.tables.append(self.allocator, owned);
        self.persist() catch |err| {
            _ = self.tables.pop();
            return err;
        };
    }

    /// 更新 B+ Tree 根页并持久化目录。
    pub fn updateRootPage(self: *Catalog, name: []const u8, root_page: u32) !void {
        for (self.tables.items) |*table| {
            if (!std.mem.eql(u8, table.name, name)) continue;
            const previous = table.root_page;
            table.root_page = root_page;
            self.persist() catch |err| {
                table.root_page = previous;
                return err;
            };
            return;
        }
        return error.TableNotFound;
    }

    fn load(self: *Catalog) !void {
        const data = &self.page.data;
        var cursor: usize = magic.len;
        const table_count = try readU16(data, &cursor);
        for (0..table_count) |_| {
            const name_len = try readU16(data, &cursor);
            const name = try readBytes(data, &cursor, name_len);
            const root_page = try readU32(data, &cursor);
            const column_count = try readU16(data, &cursor);
            const columns = try self.allocator.alloc(Column, column_count);
            var filled: usize = 0;
            errdefer {
                for (columns[0..filled]) |column| self.allocator.free(column.name);
                self.allocator.free(columns);
            }
            for (columns) |*column| {
                const column_name_len = try readU16(data, &cursor);
                const column_name = try readBytes(data, &cursor, column_name_len);
                if (cursor >= data.len) return error.InvalidCatalog;
                const column_type = switch (data[cursor]) {
                    0 => ast.ColumnType.integer,
                    1 => ast.ColumnType.text,
                    else => return error.InvalidCatalog,
                };
                cursor += 1;
                column.* = .{ .name = try self.allocator.dupe(u8, column_name), .type = column_type };
                filled += 1;
            }
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            try self.tables.append(self.allocator, .{ .name = owned_name, .root_page = root_page, .columns = columns });
        }
    }

    fn checkFits(self: *const Catalog, schema: TableSchema) !void {
        if (self.tables.items.len >= std.math.maxInt(u16)) return error.CatalogFull;
        if (schema.name.len > std.math.maxInt(u16) or schema.columns.len > std.math.maxInt(u16)) return error.CatalogFull;
        var needed = header_size + 2 + schema.name.len + 4 + 2;
        for (schema.columns) |column| {
            if (column.name.len > std.math.maxInt(u16)) return error.CatalogFull;
            needed += 2 + column.name.len + 1;
        }
        for (self.tables.items) |table| {
            needed += 2 + table.name.len + 4 + 2;
            for (table.columns) |column| needed += 2 + column.name.len + 1;
        }
        if (needed > pager_mod.page_size) return error.CatalogFull;
    }

    fn copySchema(self: *Catalog, schema: TableSchema) !TableSchema {
        const name = try self.allocator.dupe(u8, schema.name);
        errdefer self.allocator.free(name);
        const columns = try self.allocator.alloc(Column, schema.columns.len);
        var filled: usize = 0;
        errdefer {
            for (columns[0..filled]) |column| self.allocator.free(column.name);
            self.allocator.free(columns);
        }
        for (schema.columns, 0..) |column, i| {
            columns[i] = .{ .name = try self.allocator.dupe(u8, column.name), .type = column.type };
            filled += 1;
        }
        return .{ .name = name, .root_page = schema.root_page, .columns = columns };
    }

    fn freeSchema(self: *Catalog, schema: TableSchema) void {
        self.allocator.free(schema.name);
        for (schema.columns) |column| self.allocator.free(column.name);
        self.allocator.free(schema.columns);
    }

    fn persist(self: *Catalog) !void {
        const data = &self.page.data;
        @memset(data, 0);
        @memcpy(data[0..magic.len], magic);
        var cursor: usize = magic.len;
        writeU16(data, &cursor, @intCast(self.tables.items.len));
        for (self.tables.items) |table| {
            writeU16(data, &cursor, @intCast(table.name.len));
            writeBytes(data, &cursor, table.name);
            writeU32(data, &cursor, table.root_page);
            writeU16(data, &cursor, @intCast(table.columns.len));
            for (table.columns) |column| {
                writeU16(data, &cursor, @intCast(column.name.len));
                writeBytes(data, &cursor, column.name);
                data[cursor] = switch (column.type) {
                    .integer => 0,
                    .text => 1,
                };
                cursor += 1;
            }
        }
        self.page.dirty = true;
        try self.pager.flushPage(0);
    }
};

fn readU16(data: []const u8, cursor: *usize) !u16 {
    if (cursor.* > data.len or data.len - cursor.* < 2) return error.InvalidCatalog;
    const value = std.mem.readInt(u16, data[cursor.*..][0..2], .little);
    cursor.* += 2;
    return value;
}

fn readU32(data: []const u8, cursor: *usize) !u32 {
    if (cursor.* > data.len or data.len - cursor.* < 4) return error.InvalidCatalog;
    const value = std.mem.readInt(u32, data[cursor.*..][0..4], .little);
    cursor.* += 4;
    return value;
}

fn readBytes(data: []const u8, cursor: *usize, len: usize) ![]const u8 {
    if (cursor.* > data.len or len > data.len - cursor.*) return error.InvalidCatalog;
    const bytes = data[cursor.* .. cursor.* + len];
    cursor.* += len;
    return bytes;
}

fn writeU16(data: []u8, cursor: *usize, value: u16) void {
    std.mem.writeInt(u16, data[cursor.*..][0..2], value, .little);
    cursor.* += 2;
}

fn writeU32(data: []u8, cursor: *usize, value: u32) void {
    std.mem.writeInt(u32, data[cursor.*..][0..4], value, .little);
    cursor.* += 4;
}

fn writeBytes(data: []u8, cursor: *usize, bytes: []const u8) void {
    @memcpy(data[cursor.* .. cursor.* + bytes.len], bytes);
    cursor.* += bytes.len;
}
