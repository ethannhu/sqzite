# 存储实现索引

本文档集描述当前代码中的数据库格式、存储模块和算法。文档以 `src/` 中的实际行为为准；规划中但尚未接通的能力会明确标出。

## 文档

- [Pager 与页面生命周期](pager.md)：固定页面大小、缓存、分配、刷新与关闭。
- [节点页格式](node.md)：叶子和内部节点布局，以及单页操作。
- [B+ 树与重平衡算法](btree.md)：查找、插入、分裂、删除、重分配、合并和根收缩。
- [Record 与 Table](record-table.md)：记录编码、rowid 映射和 Table API。
- [Catalog 元数据](catalog.md)：0 号页格式以及表结构、根页持久化。

SQL 词法、语法、绑定、执行和 REPL 的现状见 [SQL 与执行流程](sql.md)。

## 当前边界

目前数据库文件由 Pager 页面组成，Catalog 占用 0 号页；每张表由一个以整数 rowid 为键的 B+ 树保存。存储层已经实现 point lookup、插入和删除；REPL 执行器当前只接通 `CREATE TABLE` 与 `INSERT`。`SELECT`、`UPDATE`、`DELETE` 虽有部分 AST/parser 结构，但不能通过当前 Binder/Executor 执行。尚无事务、并发控制、崩溃恢复、空闲页回收或 overflow page。
