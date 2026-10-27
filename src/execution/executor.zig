const catalog = @import("../catalog/catalog.zig");
const binder = @import("../sql/binder.zig");
const btree = @import("../storage/btree.zig");
const node = @import("../storage/node.zig");
const pager = @import("../storage/pager.zig");
const record = @import("../storage/record.zig");
const table = @import("../storage/table.zig");

/// 直接执行当前已绑定的语句。
pub const Executor = struct {
    pager: *pager.Pager,
    catalog: *catalog.Catalog,

    pub fn execute(self: *Executor, statement: binder.BoundStatement) !void {
        switch (statement) {
            .create_table => |bound| try self.createTable(bound.definition),
            .insert => |bound| try self.insert(bound),
        }
    }

    fn insert(self: *Executor, bound: binder.BoundInsert) !void {
        const allocator = self.pager.allocator;
        const columns = try allocator.alloc(record.Column, bound.table.columns.len);
        defer allocator.free(columns);
        for (bound.table.columns, 0..) |column, i| {
            columns[i] = .{
                .name = column.name,
                .type = switch (column.type) {
                    .integer => .integer,
                    .text => .text,
                },
            };
        }

        const values = try allocator.alloc(record.Value, bound.statement.values.len);
        defer allocator.free(values);
        for (bound.statement.values, 0..) |value, i| {
            values[i] = switch (value) {
                .integer => |number| .{ .integer = number },
                .string => |text| .{ .text = text },
                else => return error.InvalidBoundValue,
            };
        }
        const rowid = values[0].integer;
        var tree = btree.BPlusTree{ .pager = self.pager, .root_page_id = bound.table.root_page };
        var stored_table = table.Table{
            .root_page = bound.table.root_page,
            .schema = .{ .columns = columns },
            .btree = &tree,
        };
        try stored_table.insert(rowid, .{ .values = values });
        if (stored_table.root_page != bound.table.root_page) {
            try self.catalog.updateRootPage(bound.table.name, stored_table.root_page);
        }
    }

    fn createTable(self: *Executor, definition: @import("../sql/ast.zig").CreateTable) !void {
        const root = try self.pager.allocatePage();
        _ = node.LeafNode.init(root, 0, 0);
        try self.catalog.createTable(.{
            .name = definition.name,
            .root_page = root.id,
            .columns = definition.columns,
        });
    }
};
