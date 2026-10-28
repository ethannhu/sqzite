# Record 与 Table

实现：[`src/storage/record.zig`](../../src/storage/record.zig)、[`src/storage/table.zig`](../../src/storage/table.zig)。

## Record 编码

`Record` 的值顺序对应 `Schema.columns`。运行时值类型为 NULL、整数 `i64`、`f64`、文本字节和 blob 字节。序列化采用 SQLite 风格的 record header/body：header 先写 header 长度 varint，再写每列 serial type；body 按列顺序写实际值。整数使用最短支持宽度（1、2、3、4、6 或 8 字节）并以大端写入，浮点用 8 字节，大端；文本和 blob 写原始字节。NULL 不占 body。serial type 8/9 解码为整数 0/1。

`deserialize` 按 Schema 列数读取，检查 header、varint、列数和 body 边界。返回的 `values` 数组由调用方 allocator 拥有，需调用 `Record.deinit`；文本和 blob 切片借用输入 payload。

## Table 与 rowid

`Table` 包含根页号、Schema 和 B+ 树指针。`insert(rowid, record)` 验证列数，序列化 payload 后按树键插入，并同步自身的根页号。`get(rowid)` 查树并反序列化，结果按上述规则释放。`delete(rowid)` 删除键并同步根页号；目标不存在时不报错。

为了让无符号 B+ 树键保持与有符号 rowid 相同的排序，Table 对 rowid 位模式异或最高位 `1<<63` 后再传给 B+ 树。当前 SQL binder 进一步限制首列为 integer 并将首个插入值作为 rowid；Table 本身不负责 Schema 类型验证。

Table 的根页号由使用方维护。REPL Executor 在插入导致根变化时将其写回 Catalog。当前没有 Table 游标/全表扫描接口。
