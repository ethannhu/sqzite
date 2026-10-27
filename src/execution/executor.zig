const catalog = @import("../catalog/catalog.zig");
const binder = @import("../sql/binder.zig");
const node = @import("../storage/node.zig");
const pager = @import("../storage/pager.zig");

/// 直接执行当前已绑定的语句。
pub const Executor = struct {
    pager: *pager.Pager,
    catalog: *catalog.Catalog,

    pub fn execute(self: *Executor, statement: binder.BoundStatement) !void {
        switch (statement) {
            .create_table => |bound| try self.createTable(bound.definition),
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
