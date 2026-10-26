const ast = @import("../sql/ast.zig");

/// 表列类型。
pub const ColumnType = ast.ColumnType;

pub const Column = struct {
    name: []const u8,
    type: ColumnType,
};

pub const TableSchema = struct {
    name: []const u8,
    root_page: u32,
    columns: []const Column,
};

/// Catalog 接口；持久化格式后续实现。
pub const Catalog = struct {
    pub fn findTable(self: *Catalog, name: []const u8) anyerror!?*const TableSchema {
        _ = self;
        _ = name;
        unreachable;
    }

    pub fn createTable(self: *Catalog, schema: TableSchema) anyerror!void {
        _ = self;
        _ = schema;
        unreachable;
    }
};
