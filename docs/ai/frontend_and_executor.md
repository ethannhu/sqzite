既然你已经实现了 Record、B+ Tree、Pager 等存储层，下一步只需要实现 SQL 前端和执行层。

建议使用 Zig 自己编写递归下降 Parser，先支持一个精简的 SQL 子集，不引入复杂的查询优化器或虚拟机。

## 1. 整体架构

```
SQL String
    │
    ▼
Lexer              词法分析
    │ Tokens
    ▼
Parser             语法分析
    │ AST
    ▼
Binder             名称解析、Schema 验证
    │ Bound AST
    ▼
Planner            生成简单执行计划
    │ Plan
    ▼
Executor           执行查询
    │
    ▼
Table API          已实现
    │
    ▼
Record / B+ Tree / Pager
```

建议代码结构：

```
src/
├── sql/
│   ├── lexer.zig
│   ├── parser.zig
│   ├── ast.zig
│   ├── binder.zig
│   └── planner.zig
├── execution/
│   └── executor.zig
├── catalog/
│   └── catalog.zig
├── storage/          # 已实现
└── db.zig
```

## 2. 分阶段实现

| 阶段 | 模块          | 核心工作                                 |
| -- | ----------- | ------------------------------------ |
| 1  | Lexer       | SQL 字符串 → Token，处理关键字、标识符、整数、字符串及运算符 |
| 2  | Parser      | Token → AST，使用递归下降和 Pratt 表达式解析      |
| 3  | Catalog     | 管理 Table Schema、列定义、B+ Tree 根页号      |
| 4  | Binder      | 验证表名、列名，将列引用解析成列索引                   |
| 5  | Planner     | 将 AST 转换为 `Get`、`Scan`、`Insert` 等计划  |
| 6  | Executor    | 调用现有 Table API，实现过滤、投影及增删改           |
| 7  | Integration | `Database.execute(sql)`，连接所有模块       |

## 3. 第一版 SQL 子集

优先支持：

```
CREATE TABLE users (id INTEGER, name TEXT);
INSERT INTO users VALUES (1, 'Alice');
SELECT * FROM users;
SELECT name FROM users WHERE id = 1;
UPDATE users SET name = 'Bob' WHERE id = 1;
DELETE FROM users WHERE id = 1;
```

第一版限制：单表、整数主键、`=` 比较、`AND`、无 JOIN、无聚合、无事务 SQL。

## 4. 核心数据结构

### AST

使用 Zig 的 `union(enum)`：

```
const Statement = union(enum) {
    create_table: CreateTable,
    insert: Insert,
    select: Select,
    update: Update,
    delete: Delete,
};

const Expr = union(enum) {
    integer: i64,
    string: []const u8,
    column: []const u8,
    binary: BinaryExpr,
};

const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
};
```

### Catalog

```
const Column = struct {
    name: []const u8,
    type: ColumnType,
};

const TableSchema = struct {
    name: []const u8,
    root_page: u32,
    columns: []Column,
};
```

Catalog 必须持久化，否则数据库重新打开后无法恢复表的 Schema 与根页号。可以先用单独的元数据页，后续再实现类似 SQLite 的系统表。

### Execution Plan

```
const Plan = union(enum) {
    create_table: CreateTablePlan,
    insert: InsertPlan,
    point_lookup: PointLookupPlan,
    table_scan: TableScanPlan,
    update: UpdatePlan,
    delete: DeletePlan,
};
```

最初只需要两种查询路径：

- `WHERE id = ?`：使用 B+ Tree 的 `search(key)`。
- 其他 `WHERE` 条件：遍历 B+ Tree，逐行计算表达式。

## 5. Executor 如何调用存储层

建议 Table 层暴露以下接口：

```
pub fn get(self: *Table, key: i64) !?Record;
pub fn insert(self: *Table, key: i64, record: Record) !void;
pub fn update(self: *Table, key: i64, record: Record) !void;
pub fn delete(self: *Table, key: i64) !void;
pub fn cursor(self: *Table) !Cursor;
```

`Cursor` 用于顺序扫描：

```
pub fn first(self: *Cursor) !void;
pub fn next(self: *Cursor) !void;
pub fn valid(self: *Cursor) bool;
pub fn record(self: *Cursor) !Record;
```

例如执行：

```
SELECT name FROM users WHERE id = 1;
```

调用链为：

```
Parser.parse()
    ↓
Binder.bind()
    ↓
Planner.plan()
    ↓
PointLookup(table=users, key=1)
    ↓
Table.get(1)
    ↓
BTree.search(1)
    ↓
Record.deserialize()
    ↓
Project(name)
    ↓
ResultSet
```

## 6. 推荐的开发顺序

M1

Lexer + Parser

SQL 能转换成 AST

M2

Catalog + CREATE TABLE

能创建表并持久化 Schema

M3

INSERT + SELECT by PK

完整打通 SQL 到 B+ Tree

M4

Cursor + Table Scan

支持 SELECT \* 和 WHERE 过滤

M5

UPDATE + DELETE

支持数据修改和删除

M6

Planner + Secondary Index

增加索引访问路径

Zig 实现上的三个注意点：

1. 用 `ArenaAllocator` 管理一次 SQL 解析和执行计划的临时对象；持久化的 Schema 不能引用这个 Arena 中的内存。
2. `Parser`、`Binder`、`Executor` 分别测试，避免每次都要启动完整数据库。
3. `UPDATE` / `DELETE` 扫描时注意 Cursor 失效问题，可以先收集待修改的主键，再逐个修改。

最重要的里程碑是 M3。 实现 `CREATE TABLE`、`INSERT` 和按主键 `SELECT` 之后，你就已经拥有了一个可以实际存储、查询并持久化数据的最小 SQL 数据库。之后的 WHERE、全表扫描、索引优化都是增量扩展。
