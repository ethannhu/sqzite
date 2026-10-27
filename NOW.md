# 当前进度

项目使用 Zig 0.16.0，已有页面存储、B+ Tree 和初版 SQL 到存储链路。

## 已完成

- **存储层**：Pager 管理 4096 字节页面；B+ Tree 支持搜索、插入、删除、分裂、合并和重平衡；Table 封装 rowid 记录读写。
- **Catalog**：固定使用 0 号页保存表名、根页号和列定义；启动时加载，建表或根页变化时立即写回。元数据目前限于单页。
- **SQL 前端**：Lexer 支持当前 SQL 子集的 token；Parser 用递归下降解析语句、用 Pratt 解析表达式。支持 CREATE TABLE、INSERT、SELECT、UPDATE、DELETE 的 AST。
- **Binder 与执行**：CREATE TABLE、INSERT 已完成绑定和直接执行。INSERT 检查表、列数、值类型，并约定 schema 第一列为整数主键。
- **REPL**：启动可交互 Shell；支持 SQL 输入以及 `.help`、`.tables`、`.schema`、`.quit`、`.exit`。
- **测试**：覆盖存储、Lexer、Parser、建表、插入、Catalog 重启恢复及 Binder 校验。

## 当前限制

- SELECT、UPDATE、DELETE 目前只解析成 AST，尚未绑定和执行；Planner 仍是接口占位。
- 第一列整数作为主键是当前约定，SQL 尚无显式主键约束语法。
- Catalog 只占一个页面；超出容量会返回 `CatalogFull`。旧格式或未知非空 0 号页无法打开。
- CLI 默认数据库文件为当前目录下的 `sqzite.db`，可用第一个命令行参数指定路径。
- Pager 使用启动时传入的分配器；CLI 使用进程级 arena，因此内存统一在进程退出时回收。

## 验证

最近验证：`zig build test`、`zig build` 均通过。
