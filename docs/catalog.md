# Catalog 元数据

实现：[`src/catalog/catalog.zig`](../../src/catalog/catalog.zig)。Catalog 固定存放在 Pager 的 0 号页；创建表和更新根页后立即写回该页。

## 页格式

页首 8 字节为 ASCII `SQZCAT01`，随后是小端 `u16` 表数量。每张表按顺序编码：`u16` 表名长度、表名字节、`u32` 根页号、`u16` 列数；每列编码 `u16` 列名长度、列名字节、1 字节列类型（0 integer，1 text）。未使用部分为零。所有内容必须放入单个 4096 字节页面。

打开时，识别 magic 则解析元数据；若整页全零则视为空库并初始化 Catalog；非零但 magic 不匹配、类型编码非法或数据结构不完整时返回 `InvalidCatalog`。当前页格式无版本迁移机制。

## 内存与更新

Catalog 加载时复制表名、列名和列数组，由 Catalog 持有至 `deinit`。`findTable` 精确区分大小写。`createTable` 拒绝同名表、预先检查页面容量，再复制 Schema 并持久化；失败时撤销内存列表新增。`updateRootPage` 更新匹配表根页并持久化，写入失败会恢复原根页；未知表返回 `TableNotFound`。

Catalog 页空间不足返回 `CatalogFull`。页内单页目录是当前实现的规模限制，尚无系统表、删除表或多页目录。
