# SQL 与执行流程现状

当前前端由 Lexer、Parser、Binder、Executor 和 REPL 组成，模块入口见 [`src/root.zig`](../src/root.zig)。整体路径为：SQL 文本 → token → AST → 绑定语句 → Executor → Catalog / Table / B+ 树。

## 词法与语法

Lexer 不区分关键字大小写，标识符保留原拼写；支持整数、单引号字符串（连续两个单引号表示转义单引号）、`* , ( ) = ;`，以及 `CREATE TABLE`、`INSERT INTO ... VALUES`、`SELECT ... FROM ... WHERE`、`UPDATE ... SET`、`DELETE FROM ... WHERE` 所需关键字。字符串 token 引用原 SQL；Parser 解码字符串时分配新内容。其他字符得到 invalid token。

Parser 以递归下降解析语句，用 Pratt 表达式解析 `=` 与 `AND`，其中 AND 优先级更低。可选末尾分号；每次只解析一条语句并要求后续为 EOF。AST/parser 可表示 SELECT、UPDATE、DELETE 和表达式，但这不表示它们可执行。

## Binder 与 Executor

Binder 当前只接受 CREATE TABLE 和 INSERT。建表要求至少一列、表名不存在且列名不重复。插入会检查表存在、值数与列数一致、首列为 integer，并逐列验证 integer/text 值类型；当前 rowid 取 values[0]。其余语句返回 `UnsupportedStatement`。

Executor 只实现 CREATE TABLE 和 INSERT。建表先分配并初始化空叶子页，再将 schema 和根页号存入 Catalog。插入构造 Record schema/value，使用 Table API 写入 B+ 树；若根页改变则更新 Catalog。重复 rowid 会由 B+ 树作为重复键拒绝。

虽然 AST、Parser 中存在 SELECT/UPDATE/DELETE，Planner 的 `plan` 目前是 `unreachable`，且 Executor 不调用 Planner。查询结果输出、扫描、投影、过滤、更新和 SQL 删除尚未实现。存储层的 B+ 树删除 API 不等于 SQL DELETE 已接通。

## REPL

REPL 按行读取，空行忽略；以 `.` 开头的行按点命令处理。支持 `.help`、`.tables`、`.schema <表名>`、`.quit`/`.exit`。SQL 每行使用临时 Arena 解析和绑定，执行成功输出“执行成功”；错误以错误名打印后继续交互。未提供多语句解析或事务命令。
