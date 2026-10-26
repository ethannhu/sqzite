/// SQL 前端共享的语法树类型。
pub const Statement = union(enum) {
    create_table: CreateTable,
    insert: Insert,
    select: Select,
    update: Update,
    delete: Delete,
};

pub const CreateTable = struct {
    name: []const u8,
    columns: []const ColumnDef,
};

pub const ColumnDef = struct {
    name: []const u8,
    type: ColumnType,
};

pub const Insert = struct {
    table: []const u8,
    values: []const Expr,
};

pub const Select = struct {
    table: []const u8,
    columns: []const []const u8,
    where: ?Expr,
};

pub const Update = struct {
    table: []const u8,
    assignments: []const Assignment,
    where: ?Expr,
};

pub const Assignment = struct {
    column: []const u8,
    value: Expr,
};

pub const Delete = struct {
    table: []const u8,
    where: ?Expr,
};

pub const Expr = union(enum) {
    integer: i64,
    string: []const u8,
    column: []const u8,
    binary: BinaryExpr,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *const Expr,
    rhs: *const Expr,
};

pub const BinaryOp = enum { equal, and_ };
pub const ColumnType = enum { integer, text };
