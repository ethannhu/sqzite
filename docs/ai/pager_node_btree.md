SQLite 中，Tree、Node、Page 并不是三个平级的数据结构，而是三层职责不同的抽象：

- Tree（`Btree` / `BtShared`）：管理整棵树的操作、游标及数据库级状态。
- Node（`MemPage`）：负责解析和修改一个 B-Tree 节点的内部结构。
- Page（`DbPage` / `Pager`）：负责页面缓存、磁盘 I/O 和事务保护。

其中 SQLite 的一个数据库文件可以包含多棵 B-Tree，它们通常共享同一个 Pager。

## 1. SQLite 的实际调用关系

Btree / BtCursor

`sqlite3BtreeInsert()` · `sqlite3BtreeTableMoveto()`

MemPage（Node）

`findCell()` · `insertCell()` · `dropCell()`

Pager / DbPage

`sqlite3PagerGet()` · `sqlite3PagerWrite()`

Database File

固定大小的磁盘页面

## 2. 三层之间暴露哪些接口？

| 层            | 主要接口                              | 职责              |
| ------------ | --------------------------------- | --------------- |
| Tree → Node  | `getAndInitPage()`                | 根据 Page ID 获取节点 |
|              | `findCell()`                      | 读取指定 Cell       |
|              | `insertCell()`                    | 在节点中插入 Cell     |
|              | `dropCell()`                      | 删除指定 Cell       |
|              | `balance()` 相关函数                  | 处理节点分裂和重平衡      |
| Node → Pager | `sqlite3PagerGet()` / `Acquire()` | 获取页面            |
|              | `sqlite3PagerGetData()`           | 获取原始字节数组        |
|              | `sqlite3PagerGetExtra()`          | 获取节点附加元数据       |
|              | `sqlite3PagerWrite()`             | 为修改页面进行事务保护     |
|              | `sqlite3PagerUnref()`             | 释放页面引用          |
| Tree → 上层    | `sqlite3BtreeCursor()`            | 打开树的游标          |
|              | `sqlite3BtreeInsert()`            | 插入记录            |
|              | `sqlite3BtreeDelete()`            | 删除记录            |
|              | `sqlite3BtreeNext()`              | 遍历记录            |

这些接口中，`findCell()`、`insertCell()` 等属于 `btree.c` 内部实现，不是对外导出的公共接口。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub

+1



## 3. 如果用 Zig 实现，我建议这样设计

不要完全照搬 SQLite 的内部实现，可以把三层封装为以下接口。

### Pager：只负责页面

```
pub const Pager = struct {
    pub fn get(self: *Pager, id: u32) !*Page;
    pub fn allocate(self: *Pager) !*Page;
    pub fn release(self: *Pager, page: *Page) void;
    pub fn makeWritable(self: *Pager, page: *Page) !void;
};
```

### Node：只负责页面内部结构

```
pub const Node = struct {
    page: *Page,

    pub fn open(page: *Page) !Node;
    pub fn init(page: *Page, kind: NodeType) !Node;

    pub fn cellCount(self: *const Node) u16;
    pub fn cellKey(self: *const Node, i: usize) !u64;
    pub fn childPage(self: *const Node, i: usize) !u32;

    pub fn lowerBound(self: *const Node, key: u64) !usize;
    pub fn insertCell(self: *Node, i: usize, cell: []const u8) !void;
    pub fn deleteCell(self: *Node, i: usize) !void;
};
```

### BTree：负责整棵树

```
pub const BTree = struct {
    pager: *Pager,
    root_page_id: u32,

    pub fn get(self: *BTree, key: u64) !?[]u8;
    pub fn insert(self: *BTree, key: u64, value: []const u8) !void;
    pub fn delete(self: *BTree, key: u64) !void;

    fn findLeaf(self: *BTree, key: u64) !u32;
    fn splitNode(self: *BTree, page_id: u32) !void;
};
```

`get()` 返回的 Value 最好是调用者拥有的副本；如果采用借用切片，则需要额外设计页面固定与释放机制。

## 4. 一个完整的插入操作如何跨越三层？

```
pub fn insert(
    self: *BTree,
    key: u64,
    value: []const u8,
) !void {
    // Tree：搜索目标叶子
    const page_id = try self.findLeaf(key);

    // Pager：获取页面
    const page = try self.pager.get(page_id);
    defer self.pager.release(page);

    // Node：将原始 Page 映射为节点
    var node = try Node.open(page);

    // Node：寻找插入位置
    const index = try node.lowerBound(key);

    // Pager：确保修改受事务保护
    try self.pager.makeWritable(page);

    // Node：修改页面内部的 Cell
    node.insertCell(index, /* encoded cell */) catch |err| {
        if (err == error.NoSpace) {
            // Tree：处理节点分裂
            try self.splitNode(page_id);
            return;
        }
        return err;
    };
}
```

这是简化示意，真正实现时，分裂必须把待插入记录也纳入重分配，并将新分隔 Key 传播到父节点。节点分裂时还要保证相关页面的引用在操作期间有效。

## 5. 最核心的设计原则

| 操作              | 应该由谁负责              |
| --------------- | ------------------- |
| 根据 Page ID 读取数据 | Pager               |
| 创建新的 Page       | Pager               |
| 将 Page 解释为节点    | Node                |
| 读取、修改 Cell      | Node                |
| 根据 Key 选择子节点    | BTree，调用 Node       |
| 节点分裂与合并         | BTree，调用 Node       |
| 页面写入磁盘          | Pager               |
| 保证写入的事务安全       | Pager / Transaction |

我最推荐的模块关系是：

```
BTree ──使用──> Node ──引用──> Page
  │                           ▲
  └────────使用──> Pager ──────┘
```

其中 `Node` 不需要知道 `Pager` 的存在，也不应该直接执行磁盘 I/O。

如果想进一步研究真实 SQLite 的实现，可以直接阅读三个文件：

- [btree.h](https://github.com/sqlite/sqlite/blob/master/src/btree.h?utm_source=chatgpt.com)：B-Tree 对上层暴露的接口。
- [btreeInt.h](https://github.com/sqlite/sqlite/blob/master/src/btreeInt.h?utm_source=chatgpt.com)：`MemPage`、`BtShared`、`BtCursor` 的结构定义。
- [pager.h](https://github.com/sqlite/sqlite/blob/master/src/pager.h?utm_source=chatgpt.com)：B-Tree 与 Pager 之间的接口。

对于你的项目，最重要的是保证 Node 只处理单页格式、BTree 处理跨页逻辑、Pager 处理页面生命周期和事务。这三个边界确定后，后续实现搜索、插入和分裂就会清晰很多。
