const btree = @import("btree.zig");
const record = @import("record.zig");

pub const Schema = record.Schema;
pub const Record = record.Record;

/// 普通 Rowid Table 的句柄；记录与字符串 payload 借用 B-tree/Pager 生命周期。
pub const Table = struct {
    root_page: u32,
    schema: Schema,
    btree: *btree.BPlusTree,

    /// 插入一条记录，并由 B-tree 按 rowid 保存其序列化 payload。
    pub fn insert(self: *Table, rowid: i64, value: Record) !void {
        if (value.values.len != self.schema.columns.len) return error.ColumnCountMismatch;
        const allocator = self.btree.pager.allocator;
        const payload = try value.serialize(allocator);
        defer allocator.free(payload);

        try self.btree.insert(treeKey(rowid), payload);
        self.root_page = self.btree.root_page_id orelse 0;
    }

    /// 按 rowid 读取记录；调用方需用 Pager allocator 调用 Record.deinit 释放 values。
    pub fn get(self: *Table, rowid: i64) !?Record {
        const payload = (try self.btree.search(treeKey(rowid))) orelse return null;
        return try Record.deserialize(self.btree.pager.allocator, payload, self.schema);
    }

    /// 按 rowid 删除记录；目标不存在时正常返回。
    pub fn delete(self: *Table, rowid: i64) !void {
        _ = try self.btree.delete(treeKey(rowid));
        self.root_page = self.btree.root_page_id orelse 0;
    }
};

/// 将有符号 rowid 映射为保持有符号排序的无符号 B-tree 键。
fn treeKey(rowid: i64) u64 {
    return @as(u64, @bitCast(rowid)) ^ (@as(u64, 1) << 63);
}
