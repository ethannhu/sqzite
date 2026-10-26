在 SQLite 中，Table 是一棵 B+ 树（更准确地说是 B-tree），Record 是存储在叶子节点 Cell 中的序列化数据。

## 1. Table 如何映射到 B+ 树？

每张普通的 SQLite Rowid Table 对应一棵独立的 B-tree。

- Table：持有根节点的 Page Number（`root_page`）。
- B-tree：负责根据 `rowid` 查找、插入、删除记录。
- Page：磁盘上的固定大小数据块。
- Node：Page 中的树节点结构。
- Cell：节点内部的条目，叶子节点的 Cell 存储 `rowid` 和 Record。

例如：

Table: users

root_page = 2

Internal Node (Page 2)

分隔 Key：100

Leaf Page 3

rowid ≤ 100

1 → Alice, 20

2 → Bob, 25

Leaf Page 4

rowid > 100

101 → Carol, 30

102 → David, 22

SQLite 使用 `sqlite_schema` 系统表记录表名、建表 SQL 和根 Page Number。

## 2. Record 如何存储？

假设表定义：

```
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT,
    age INTEGER
);
```

插入：

```
INSERT INTO users VALUES (1, 'Alice', 20);
```

SQLite 会将其转换成：

```
Leaf Cell
├── Payload Size
├── Rowid = 1
└── Payload (Record)
    ├── Header
    │   ├── Header Size
    │   └── Serial Types
    └── Body
        ├── name = "Alice"
        └── age = 20
```

这里 `id INTEGER PRIMARY KEY` 是 `rowid` 的别名，因此 Record 内对应的字段存储为 NULL 占位，实际 ID 来自 Cell 的 Rowid。

Record 的 Header 描述各列的数据类型和长度，Body 存储实际数据。较大的 Record 可能使用 Overflow Pages。

## 3. Table 与 B-tree 提供什么接口？

如果你正在实现 Zig 版 SQLite，可以将接口设计为：

```
const Table = struct {
    root_page: u32,
    schema: Schema,
    btree: *BTree,

    pub fn insert(self: *Table, record: Record) !void;
    pub fn get(self: *Table, rowid: i64) !?Record;
    pub fn delete(self: *Table, rowid: i64) !void;
};
```

底层 B-tree 不需要知道列名、SQL 类型等信息，只处理：

```
pub fn insert(key: i64, payload: []const u8) !void;
pub fn search(key: i64) !?[]const u8;
pub fn delete(key: i64) !void;
```

Record 负责序列化和反序列化：

```
pub fn serialize(record: Record) ![]u8;
pub fn deserialize(data: []const u8, schema: Schema) !Record;
```

因此，完整的数据访问路径是：

Table → B-tree → Leaf Page → Cell → Payload → Record → Column Value

注意：以上描述针对普通 Rowid Table。SQLite 的 `WITHOUT ROWID` 表使用以主键为索引的另一种 B-tree 组织方式；二级索引也有独立的 B-tree。
