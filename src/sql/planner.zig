const ast = @import("ast.zig");
const binder = @import("binder.zig");

/// 简单执行计划的接口类型。
pub const Plan = union(enum) {
    create_table: ast.CreateTable,
    insert: ast.Insert,
    point_lookup: ast.Select,
    table_scan: ast.Select,
    update: ast.Update,
    delete: ast.Delete,
};

pub const Planner = struct {
    pub fn plan(self: *Planner, statement: binder.BoundStatement) anyerror!Plan {
        _ = self;
        _ = statement;
        unreachable;
    }
};
