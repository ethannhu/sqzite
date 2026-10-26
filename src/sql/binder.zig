const ast = @import("ast.zig");
const catalog = @import("../catalog/catalog.zig");

/// 已解析的列引用。
pub const BoundColumn = struct {
    table: *const catalog.TableSchema,
    index: usize,
};

/// Binder 接口：验证名称并将列引用解析为列索引。
pub const Binder = struct {
    catalog: *catalog.Catalog,

    pub fn bind(self: *Binder, statement: ast.Statement) anyerror!BoundStatement {
        _ = self;
        _ = statement;
        unreachable;
    }
};

pub const BoundStatement = struct {
    statement: ast.Statement,
};
