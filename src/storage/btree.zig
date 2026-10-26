const pager = @import("pager.zig");

/// 节点类型标记，存放在页面数据的第一个字节。
pub const NodeType = enum(u8) {
    leaf = 1,
    internal = 2,
};

/// 节点共享头部的页面字节布局。
pub const header_layout = struct {
    pub const node_type_offset = 0;
    pub const cell_count_offset = 1;
    pub const parent_page_id_offset = 3;
    pub const reserved_offset = 7;
    pub const base_size = 8;
};

/// 叶子节点头部在公共头部后保存下一个叶子页号。
pub const leaf_layout = struct {
    pub const next_leaf_page_id_offset = header_layout.base_size;
    pub const header_size = 12;
    pub const cell_size = 12;
    pub const max_cells = (pager.page_size - header_size) / cell_size;
};

/// 叶子槽位的磁盘字段偏移，整数采用小端编码。
pub const leaf_cell_layout = struct {
    pub const key_offset = 0;
    pub const value_offset_offset = 8;
    pub const value_length_offset = 10;
};

/// 内部节点头部在公共头部后保存第一个子页号。
pub const internal_layout = struct {
    pub const first_child_page_id_offset = header_layout.base_size;
    pub const header_size = 12;
    pub const cell_size = 12;
    pub const max_cells = (pager.page_size - header_size) / cell_size;
};

/// 内部槽位的磁盘字段偏移，整数采用小端编码。
/// 分隔键是右子树的下界；查询键大于等于分隔键时走右子页。
pub const internal_cell_layout = struct {
    pub const separator_key_offset = 0;
    pub const child_page_id_offset = 8;
};

/// 叶子槽位的逻辑字段；磁盘字节偏移见 `leaf_cell_layout`。
pub const LeafCell = struct {
    key: u64,
    value_offset: u16,
    value_length: u16,
};

/// 内部节点槽位保存分隔键及其右侧子页号。
pub const InternalCell = struct {
    separator_key: u64,
    child_page_id: u32,
};

const LeafRecord = struct {
    key: u64,
    value_offset: usize,
    value_length: usize,
};

/// 叶子节点恰好由一个 Pager 页面承载。
pub const LeafNode = struct {
    page: *pager.Page,

    /// 清空页面并初始化叶子节点头部。
    pub fn init(page: *pager.Page, parent_page_id: u32, next_leaf_page_id: u32) LeafNode {
        @memset(&page.data, 0);
        page.data[header_layout.node_type_offset] = @intFromEnum(NodeType.leaf);
        writeU16(&page.data, header_layout.cell_count_offset, 0);
        writeU32(&page.data, header_layout.parent_page_id_offset, parent_page_id);
        writeU32(&page.data, leaf_layout.next_leaf_page_id_offset, next_leaf_page_id);
        page.dirty = true;
        return .{ .page = page };
    }

    /// 读取叶子槽位；索引必须小于已写入的槽位数量。
    pub fn readCell(self: *const LeafNode, index: usize) error{CellOutOfBounds}!LeafCell {
        const cell_count = readU16(&self.page.data, header_layout.cell_count_offset);
        if (cell_count > leaf_layout.max_cells or index >= cell_count) return error.CellOutOfBounds;
        const cell_offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        return .{
            .key = readU64(&self.page.data, cell_offset + leaf_cell_layout.key_offset),
            .value_offset = readU16(&self.page.data, cell_offset + leaf_cell_layout.value_offset_offset),
            .value_length = readU16(&self.page.data, cell_offset + leaf_cell_layout.value_length_offset),
        };
    }

    /// 覆写现有槽位，或追加到槽位末尾；不允许产生空洞。
    pub fn writeCell(self: *LeafNode, index: usize, cell: LeafCell) error{CellOutOfBounds}!void {
        const cell_count = readU16(&self.page.data, header_layout.cell_count_offset);
        if (cell_count > leaf_layout.max_cells or index > cell_count or index >= leaf_layout.max_cells) {
            return error.CellOutOfBounds;
        }
        const cell_offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        writeU64(&self.page.data, cell_offset + leaf_cell_layout.key_offset, cell.key);
        writeU16(&self.page.data, cell_offset + leaf_cell_layout.value_offset_offset, cell.value_offset);
        writeU16(&self.page.data, cell_offset + leaf_cell_layout.value_length_offset, cell.value_length);
        if (index == cell_count) writeU16(&self.page.data, header_layout.cell_count_offset, cell_count + 1);
        self.page.dirty = true;
    }
};

/// 内部节点恰好由一个 Pager 页面承载。
pub const InternalNode = struct {
    page: *pager.Page,

    /// 清空页面并初始化内部节点头部及第一个子页。
    pub fn init(page: *pager.Page, parent_page_id: u32, first_child_page_id: u32) InternalNode {
        @memset(&page.data, 0);
        page.data[header_layout.node_type_offset] = @intFromEnum(NodeType.internal);
        writeU16(&page.data, header_layout.cell_count_offset, 0);
        writeU32(&page.data, header_layout.parent_page_id_offset, parent_page_id);
        writeU32(&page.data, internal_layout.first_child_page_id_offset, first_child_page_id);
        page.dirty = true;
        return .{ .page = page };
    }

    /// 读取内部槽位；索引必须小于已写入的槽位数量。
    pub fn readCell(self: *const InternalNode, index: usize) error{CellOutOfBounds}!InternalCell {
        const cell_count = readU16(&self.page.data, header_layout.cell_count_offset);
        if (cell_count > internal_layout.max_cells or index >= cell_count) return error.CellOutOfBounds;
        const cell_offset = internal_layout.header_size + index * internal_layout.cell_size;
        return .{
            .separator_key = readU64(&self.page.data, cell_offset + internal_cell_layout.separator_key_offset),
            .child_page_id = readU32(&self.page.data, cell_offset + internal_cell_layout.child_page_id_offset),
        };
    }

    /// 覆写现有槽位，或追加到槽位末尾；不允许产生空洞。
    pub fn writeCell(self: *InternalNode, index: usize, cell: InternalCell) error{CellOutOfBounds}!void {
        const cell_count = readU16(&self.page.data, header_layout.cell_count_offset);
        if (cell_count > internal_layout.max_cells or index > cell_count or index >= internal_layout.max_cells) {
            return error.CellOutOfBounds;
        }
        const cell_offset = internal_layout.header_size + index * internal_layout.cell_size;
        writeU64(&self.page.data, cell_offset + internal_cell_layout.separator_key_offset, cell.separator_key);
        writeU32(&self.page.data, cell_offset + internal_cell_layout.child_page_id_offset, cell.child_page_id);
        if (index == cell_count) writeU16(&self.page.data, header_layout.cell_count_offset, cell_count + 1);
        self.page.dirty = true;
    }
};

/// 仅区分节点形态，不包含查找、插入或分裂行为。
pub const Node = union(enum) {
    leaf: LeafNode,
    internal: InternalNode,
};

/// 搜索过程中可能遇到的节点或存储错误。
pub const SearchError = error{ CorruptNode, InvalidNodeType, Storage };

/// 插入时可能遇到的结构、容量或存储错误。
pub const InsertError = error{ CorruptNode, DuplicateKey, InvalidNodeType, NoSpace, Storage };

/// 查询结果是叶子页中的借用数据，生命周期受 Pager 页面缓存管理。
pub const SearchResult = ?[]const u8;

/// B+ 树句柄只保存 Pager 和根页号，不拥有 Pager。
pub const BPlusTree = struct {
    pager: *pager.Pager,
    root_page_id: ?u32,

    /// 插入键值；叶子页需要空间时分裂，父节点满时返回 NoSpace。
    pub fn insert(self: *BPlusTree, key: u64, value: []const u8) InsertError!void {
        if (value.len > pager.page_size - leaf_layout.header_size - leaf_layout.cell_size) {
            return error.NoSpace;
        }

        if (self.root_page_id == null) {
            const root = self.pager.allocatePage() catch return error.Storage;
            root.data[header_layout.node_type_offset] = @intFromEnum(NodeType.leaf);
            writeU16(&root.data, header_layout.cell_count_offset, 0);
            try insertIntoLeaf(root, key, value);
            self.root_page_id = root.id;
            return;
        }

        var page_id = self.root_page_id.?;
        var parent_path: [128]u32 = undefined;
        var parent_count: usize = 0;
        for (0..128) |_| {
            const page = self.pager.getPage(page_id) catch return error.Storage;
            const kind = page.data[header_layout.node_type_offset];
            const cell_count = readU16(&page.data, header_layout.cell_count_offset);

            switch (kind) {
                @intFromEnum(NodeType.leaf) => {
                    const parent_page_id = if (parent_count == 0) null else parent_path[parent_count - 1];
                    return insertOrSplitLeaf(self, page, parent_page_id, key, value);
                },
                @intFromEnum(NodeType.internal) => {
                    if (cell_count > internal_layout.max_cells) return error.CorruptNode;
                    if (parent_count == parent_path.len) return error.CorruptNode;
                    parent_path[parent_count] = page_id;
                    parent_count += 1;
                    page_id = findChildPage(&page.data, key, cell_count);
                },
                else => return error.InvalidNodeType,
            }
        }

        return error.CorruptNode;
    }

    /// 沿内部节点查找叶子；未找到时返回 null。
    /// 返回切片借用 Pager 缓存，Pager 关闭或页面数据被改写后失效。
    pub fn search(self: *BPlusTree, key: u64) SearchError!SearchResult {
        const root_page_id = self.root_page_id orelse return null;
        var page_id = root_page_id;

        // 防止损坏的子页指针形成无限循环。
        for (0..128) |_| {
            const page = self.pager.getPage(page_id) catch return error.Storage;
            const kind = page.data[header_layout.node_type_offset];
            const cell_count = readU16(&page.data, header_layout.cell_count_offset);

            switch (kind) {
                @intFromEnum(NodeType.leaf) => {
                    if (cell_count > leaf_layout.max_cells) return error.CorruptNode;

                    if (findLeafCell(&page.data, key, cell_count)) |index| {
                        return try readLeafValue(page, index, cell_count);
                    }
                    return null;
                },
                @intFromEnum(NodeType.internal) => {
                    if (cell_count > internal_layout.max_cells) return error.CorruptNode;
                    page_id = findChildPage(&page.data, key, cell_count);
                },
                else => return error.InvalidNodeType,
            }
        }

        return error.CorruptNode;
    }
};

/// 尝试直接插入；空间不足时改为分裂叶子。
fn insertOrSplitLeaf(
    tree: *BPlusTree,
    page: *pager.Page,
    parent_page_id: ?u32,
    key: u64,
    value: []const u8,
) InsertError!void {
    insertIntoLeaf(page, key, value) catch |err| {
        if (err != error.NoSpace) return err;
        try splitLeafAndInsert(tree, page, parent_page_id, key, value);
    };
}

/// 将满叶子的记录与新记录合并后拆成左右两页。
fn splitLeafAndInsert(
    tree: *BPlusTree,
    page: *pager.Page,
    parent_page_id: ?u32,
    key: u64,
    value: []const u8,
) InsertError!void {
    const cell_count = readU16(&page.data, header_layout.cell_count_offset);
    if (cell_count > leaf_layout.max_cells) return error.CorruptNode;
    if (findLeafCell(&page.data, key, cell_count) != null) return error.DuplicateKey;

    // 先确认原父节点可容纳新增分隔键，避免分裂后才发现父节点已满。
    var parent: ?*pager.Page = null;
    var child_index: usize = 0;
    if (parent_page_id) |parent_id| {
        const parent_page = tree.pager.getPage(parent_id) catch return error.Storage;
        if (parent_page.data[header_layout.node_type_offset] != @intFromEnum(NodeType.internal)) {
            return error.InvalidNodeType;
        }
        const parent_cells = readU16(&parent_page.data, header_layout.cell_count_offset);
        if (parent_cells > internal_layout.max_cells) return error.CorruptNode;
        if (parent_cells == internal_layout.max_cells) return error.NoSpace;
        child_index = findChildIndex(&parent_page.data, page.id, parent_cells) orelse return error.CorruptNode;
        parent = parent_page;
    }

    const insert_index = leafLowerBound(&page.data, key, cell_count);
    const total_count = @as(usize, cell_count) + 1;
    var records: [leaf_layout.max_cells + 1]LeafRecord = undefined;
    var values: [pager.page_size * 2]u8 = undefined;
    var values_len: usize = 0;

    // 暂存旧值，后续重建页面时原始字节区会被覆盖。
    for (0..cell_count) |index| {
        const cell_offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        const old_value_offset = readU16(&page.data, cell_offset + leaf_cell_layout.value_offset_offset);
        const old_value_length = readU16(&page.data, cell_offset + leaf_cell_layout.value_length_offset);
        const value_start: usize = old_value_offset;
        const value_end = value_start + old_value_length;
        const cells_end = leaf_layout.header_size + @as(usize, cell_count) * leaf_layout.cell_size;
        if (value_start < cells_end or value_end > pager.page_size) return error.CorruptNode;
        if (old_value_length > values.len - values_len) return error.CorruptNode;

        @memcpy(values[values_len .. values_len + old_value_length], page.data[value_start..value_end]);
        records[index] = .{
            .key = readU64(&page.data, cell_offset + leaf_cell_layout.key_offset),
            .value_offset = values_len,
            .value_length = old_value_length,
        };
        values_len += old_value_length;
    }

    if (value.len > values.len - values_len) return error.CorruptNode;
    const new_value_offset = values_len;
    @memcpy(values[values_len .. values_len + value.len], value);
    values_len += value.len;

    var record_index: usize = cell_count;
    while (record_index > insert_index) : (record_index -= 1) {
        records[record_index] = records[record_index - 1];
    }
    records[insert_index] = .{
        .key = key,
        .value_offset = new_value_offset,
        .value_length = value.len,
    };

    const split_index = total_count / 2;
    const left_records = records[0..split_index];
    const right_records = records[split_index..total_count];
    if (!leafRecordsFit(left_records) or !leafRecordsFit(right_records)) return error.NoSpace;

    const old_next_page_id = readU32(&page.data, leaf_layout.next_leaf_page_id_offset);
    const right_page = tree.pager.allocatePage() catch return error.Storage;

    if (parent) |parent_page| {
        try buildLeafPage(page, left_records, &values, parent_page.id, right_page.id);
        try buildLeafPage(right_page, right_records, &values, parent_page.id, old_next_page_id);
        try insertIntoInternal(parent_page, child_index, right_records[0].key, right_page.id);
        return;
    }

    const new_root = tree.pager.allocatePage() catch return error.Storage;
    try buildLeafPage(page, left_records, &values, new_root.id, right_page.id);
    try buildLeafPage(right_page, right_records, &values, new_root.id, old_next_page_id);
    initializeInternalRoot(new_root, page.id, right_records[0].key, right_page.id);
    tree.root_page_id = new_root.id;
}

fn leafRecordsFit(records: []const LeafRecord) bool {
    if (records.len > leaf_layout.max_cells) return false;
    const cells_end = leaf_layout.header_size + records.len * leaf_layout.cell_size;
    var payload_size: usize = 0;
    for (records) |record| payload_size += record.value_length;
    return payload_size <= pager.page_size - cells_end;
}

/// 用暂存记录重新写一页叶子，值区从页面尾部向前打包。
fn buildLeafPage(
    page: *pager.Page,
    records: []const LeafRecord,
    values: []const u8,
    parent_page_id: u32,
    next_leaf_page_id: u32,
) InsertError!void {
    if (!leafRecordsFit(records)) return error.NoSpace;
    @memset(&page.data, 0);
    page.data[header_layout.node_type_offset] = @intFromEnum(NodeType.leaf);
    writeU16(&page.data, header_layout.cell_count_offset, @intCast(records.len));
    writeU32(&page.data, header_layout.parent_page_id_offset, parent_page_id);
    writeU32(&page.data, leaf_layout.next_leaf_page_id_offset, next_leaf_page_id);

    var payload_start: usize = pager.page_size;
    for (records, 0..) |record, index| {
        payload_start -= record.value_length;
        const cell_offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        writeU64(&page.data, cell_offset + leaf_cell_layout.key_offset, record.key);
        writeU16(&page.data, cell_offset + leaf_cell_layout.value_offset_offset, @intCast(payload_start));
        writeU16(&page.data, cell_offset + leaf_cell_layout.value_length_offset, @intCast(record.value_length));
        @memcpy(
            page.data[payload_start .. payload_start + record.value_length],
            values[record.value_offset .. record.value_offset + record.value_length],
        );
    }
    page.dirty = true;
}

/// 在非满内部页中，为刚拆出的右子页插入分隔键。
fn insertIntoInternal(page: *pager.Page, index: usize, separator: u64, right_page_id: u32) InsertError!void {
    const cell_count = readU16(&page.data, header_layout.cell_count_offset);
    if (cell_count > internal_layout.max_cells) return error.CorruptNode;
    if (cell_count == internal_layout.max_cells) return error.NoSpace;
    if (index > cell_count) return error.CorruptNode;

    var cell_index: usize = cell_count;
    while (cell_index > index) : (cell_index -= 1) {
        const source = internal_layout.header_size + (cell_index - 1) * internal_layout.cell_size;
        const destination = internal_layout.header_size + cell_index * internal_layout.cell_size;
        var cell_copy: [internal_layout.cell_size]u8 = undefined;
        @memcpy(cell_copy[0..], page.data[source .. source + internal_layout.cell_size]);
        @memcpy(page.data[destination .. destination + internal_layout.cell_size], cell_copy[0..]);
    }

    const new_cell = internal_layout.header_size + index * internal_layout.cell_size;
    writeU64(&page.data, new_cell + internal_cell_layout.separator_key_offset, separator);
    writeU32(&page.data, new_cell + internal_cell_layout.child_page_id_offset, right_page_id);
    writeU16(&page.data, header_layout.cell_count_offset, cell_count + 1);
    page.dirty = true;
}

fn findChildIndex(data: []const u8, child_page_id: u32, cell_count: u16) ?usize {
    if (readU32(data, internal_layout.first_child_page_id_offset) == child_page_id) return 0;
    for (0..cell_count) |index| {
        const cell_offset = internal_layout.header_size + index * internal_layout.cell_size;
        if (readU32(data, cell_offset + internal_cell_layout.child_page_id_offset) == child_page_id) {
            return index + 1;
        }
    }
    return null;
}

fn initializeInternalRoot(page: *pager.Page, left_page_id: u32, separator: u64, right_page_id: u32) void {
    @memset(&page.data, 0);
    page.data[header_layout.node_type_offset] = @intFromEnum(NodeType.internal);
    writeU16(&page.data, header_layout.cell_count_offset, 1);
    writeU32(&page.data, internal_layout.first_child_page_id_offset, left_page_id);
    const cell_offset = internal_layout.header_size;
    writeU64(&page.data, cell_offset + internal_cell_layout.separator_key_offset, separator);
    writeU32(&page.data, cell_offset + internal_cell_layout.child_page_id_offset, right_page_id);
    page.dirty = true;
}

/// 在键升序排列的叶子槽位中二分查找，返回匹配槽位的索引。
fn findLeafCell(data: []const u8, key: u64, cell_count: u16) ?usize {
    var low: usize = 0;
    var high: usize = cell_count;

    while (low < high) {
        const middle = low + (high - low) / 2;
        const cell_offset = leaf_layout.header_size + middle * leaf_layout.cell_size;
        const cell_key = readU64(data, cell_offset + leaf_cell_layout.key_offset);

        if (cell_key < key) {
            low = middle + 1;
        } else if (cell_key > key) {
            high = middle;
        } else {
            return middle;
        }
    }
    return null;
}

/// 找到键应插入的位置，即第一个不小于它的槽位。
fn leafLowerBound(data: []const u8, key: u64, cell_count: u16) usize {
    var low: usize = 0;
    var high: usize = cell_count;

    while (low < high) {
        const middle = low + (high - low) / 2;
        const cell_offset = leaf_layout.header_size + middle * leaf_layout.cell_size;
        const cell_key = readU64(data, cell_offset + leaf_cell_layout.key_offset);
        if (cell_key < key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

/// 在叶子页内插入一个有序槽位和对应值，不触发分裂。
fn insertIntoLeaf(page: *pager.Page, key: u64, value: []const u8) InsertError!void {
    const cell_count = readU16(&page.data, header_layout.cell_count_offset);
    if (cell_count > leaf_layout.max_cells) return error.CorruptNode;
    if (cell_count == leaf_layout.max_cells) return error.NoSpace;

    const insert_index = leafLowerBound(&page.data, key, cell_count);
    if (insert_index < cell_count) {
        const cell_offset = leaf_layout.header_size + insert_index * leaf_layout.cell_size;
        if (readU64(&page.data, cell_offset + leaf_cell_layout.key_offset) == key) {
            return error.DuplicateKey;
        }
    }

    const previous_cells_end = leaf_layout.header_size + @as(usize, cell_count) * leaf_layout.cell_size;
    const new_cells_end = previous_cells_end + leaf_layout.cell_size;
    var payload_start: usize = pager.page_size;

    for (0..cell_count) |index| {
        const cell_offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        const value_offset = readU16(&page.data, cell_offset + leaf_cell_layout.value_offset_offset);
        const value_length = readU16(&page.data, cell_offset + leaf_cell_layout.value_length_offset);
        const start: usize = value_offset;
        const end = start + value_length;
        if (start < previous_cells_end or end > pager.page_size) return error.CorruptNode;
        payload_start = @min(payload_start, start);
    }

    if (value.len > payload_start) return error.NoSpace;
    const new_value_start = payload_start - value.len;
    if (new_value_start < new_cells_end) return error.NoSpace;

    // 从右向左搬移槽位，为新槽位留出位置。
    var index: usize = cell_count;
    while (index > insert_index) {
        const source = leaf_layout.header_size + (index - 1) * leaf_layout.cell_size;
        const destination = leaf_layout.header_size + index * leaf_layout.cell_size;
        var cell_copy: [leaf_layout.cell_size]u8 = undefined;
        @memcpy(cell_copy[0..], page.data[source .. source + leaf_layout.cell_size]);
        @memcpy(page.data[destination .. destination + leaf_layout.cell_size], cell_copy[0..]);
        index -= 1;
    }

    const new_cell = leaf_layout.header_size + insert_index * leaf_layout.cell_size;
    writeU64(&page.data, new_cell + leaf_cell_layout.key_offset, key);
    writeU16(&page.data, new_cell + leaf_cell_layout.value_offset_offset, @intCast(new_value_start));
    writeU16(&page.data, new_cell + leaf_cell_layout.value_length_offset, @intCast(value.len));
    @memcpy(page.data[new_value_start .. new_value_start + value.len], value);

    writeU16(&page.data, header_layout.cell_count_offset, cell_count + 1);
    page.dirty = true;
}

/// 在分隔键升序排列的内部槽位中二分查找目标子页。
fn findChildPage(data: []const u8, key: u64, cell_count: u16) u32 {
    var low: usize = 0;
    var high: usize = cell_count;

    // 找到第一个大于 key 的分隔键，即 upper bound。
    while (low < high) {
        const middle = low + (high - low) / 2;
        const cell_offset = internal_layout.header_size + middle * internal_layout.cell_size;
        const separator = readU64(data, cell_offset + internal_cell_layout.separator_key_offset);
        if (separator <= key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    if (low == 0) {
        return readU32(data, internal_layout.first_child_page_id_offset);
    }

    const cell_offset = internal_layout.header_size + (low - 1) * internal_layout.cell_size;
    return readU32(data, cell_offset + internal_cell_layout.child_page_id_offset);
}

/// 从指定叶子槽位读取值，并检查值区域是否越界或覆盖槽位区。
fn readLeafValue(page: *pager.Page, cell_index: usize, cell_count: u16) SearchError![]const u8 {
    const cell_offset = leaf_layout.header_size + cell_index * leaf_layout.cell_size;
    const value_offset = readU16(&page.data, cell_offset + leaf_cell_layout.value_offset_offset);
    const value_length = readU16(&page.data, cell_offset + leaf_cell_layout.value_length_offset);
    const start: usize = value_offset;
    const end = start + value_length;
    const cells_end = leaf_layout.header_size + @as(usize, cell_count) * leaf_layout.cell_size;

    if (start < cells_end or end > pager.page_size) return error.CorruptNode;
    return page.data[start..end];
}

fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn readU64(data: []const u8, offset: usize) u64 {
    var value: u64 = 0;
    for (0..8) |index| {
        value |= @as(u64, data[offset + index]) << @as(u6, @intCast(index * 8));
    }
    return value;
}

fn writeU16(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
}

fn writeU32(data: []u8, offset: usize, value: u32) void {
    for (0..4) |index| {
        data[offset + index] = @truncate(value >> @as(u5, @intCast(index * 8)));
    }
}

fn writeU64(data: []u8, offset: usize, value: u64) void {
    for (0..8) |index| {
        data[offset + index] = @truncate(value >> @as(u6, @intCast(index * 8)));
    }
}
