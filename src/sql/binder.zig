const std = @import("std");
const ast = @import("ast.zig");
const catalog = @import("../catalog/catalog.zig");

pub const BoundCreateTable = struct {
    definition: ast.CreateTable,
};

pub const BoundStatement = union(enum) {
    create_table: BoundCreateTable,
};

/// 目前只绑定 CREATE TABLE。
pub const Binder = struct {
    catalog: *const catalog.Catalog,

    pub fn bind(self: *const Binder, statement: ast.Statement) !BoundStatement {
        return switch (statement) {
            .create_table => |create| .{ .create_table = .{ .definition = try self.bindCreateTable(create) } },
            else => error.UnsupportedStatement,
        };
    }

    fn bindCreateTable(self: *const Binder, create: ast.CreateTable) !ast.CreateTable {
        if (create.columns.len == 0) return error.EmptyTableSchema;
        if (self.catalog.findTable(create.name) != null) return error.TableAlreadyExists;
        for (create.columns, 0..) |column, i| {
            for (create.columns[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, column.name)) return error.DuplicateColumn;
            }
        }
        return create;
    }
};
