const std = @import("std");
const ast = @import("ast.zig");
const catalog = @import("../catalog/catalog.zig");

pub const BoundCreateTable = struct {
    definition: ast.CreateTable,
};

pub const BoundInsert = struct {
    table: *const catalog.TableSchema,
    statement: ast.Insert,
};

pub const BoundStatement = union(enum) {
    create_table: BoundCreateTable,
    insert: BoundInsert,
};

/// 目前只绑定 CREATE TABLE。
pub const Binder = struct {
    catalog: *const catalog.Catalog,

    pub fn bind(self: *const Binder, statement: ast.Statement) !BoundStatement {
        return switch (statement) {
            .create_table => |create| .{ .create_table = .{ .definition = try self.bindCreateTable(create) } },
            .insert => |insert| .{ .insert = try self.bindInsert(insert) },
            else => error.UnsupportedStatement,
        };
    }

    fn bindInsert(self: *const Binder, insert: ast.Insert) !BoundInsert {
        const table = self.catalog.findTable(insert.table) orelse return error.TableNotFound;
        if (insert.values.len != table.columns.len) return error.ColumnCountMismatch;
        if (table.columns.len == 0 or table.columns[0].type != .integer) return error.InvalidPrimaryKey;
        for (insert.values, table.columns) |value, column| {
            switch (column.type) {
                .integer => switch (value) {
                    .integer => {},
                    else => return error.TypeMismatch,
                },
                .text => switch (value) {
                    .string => {},
                    else => return error.TypeMismatch,
                },
            }
        }
        return .{ .table = table, .statement = insert };
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
