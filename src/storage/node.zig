const pager = @import("pager.zig");

/// 节点页面中存储的类型标记。
pub const NodeType = enum(u8) {
    leaf = 1,
    internal = 2,
};

/// 页面头部和槽位的磁盘布局。
pub const header_layout = struct {
    pub const node_type_offset = 0;
    pub const cell_count_offset = 1;
    pub const parent_page_id_offset = 3;
    pub const reserved_offset = 7;
    pub const base_size = 8;
};

pub const leaf_layout = struct {
    pub const next_leaf_page_id_offset = header_layout.base_size;
    pub const header_size = 12;
    pub const cell_size = 12;
    pub const max_cells = (pager.page_size - header_size) / cell_size;
};

pub const leaf_cell_layout = struct {
    pub const key_offset = 0;
    pub const value_offset_offset = 8;
    pub const value_length_offset = 10;
};

pub const internal_layout = struct {
    pub const first_child_page_id_offset = header_layout.base_size;
    pub const header_size = 12;
    pub const cell_size = 12;
    pub const max_cells = (pager.page_size - header_size) / cell_size;
};

pub const internal_cell_layout = struct {
    pub const separator_key_offset = 0;
    pub const child_page_id_offset = 8;
};

pub const LeafCell = struct {
    key: u64,
    value_offset: u16,
    value_length: u16,
};

pub const InternalCell = struct {
    separator_key: u64,
    child_page_id: u32,
};

pub const NodeError = error{ CorruptNode, InvalidNodeType, CellOutOfBounds, DuplicateKey, NoSpace };

pub const LeafRecord = struct {
    key: u64,
    value_offset: usize,
    value_length: usize,
};

pub const LeafNode = struct {
    page: *pager.Page,

    pub fn init(page: *pager.Page, parent_page_id: u32, next_leaf_page_id: u32) LeafNode {
        @memset(&page.data, 0);
        page.data[header_layout.node_type_offset] = @intFromEnum(NodeType.leaf);
        writeU16(&page.data, header_layout.cell_count_offset, 0);
        writeU32(&page.data, header_layout.parent_page_id_offset, parent_page_id);
        writeU32(&page.data, leaf_layout.next_leaf_page_id_offset, next_leaf_page_id);
        page.dirty = true;
        return .{ .page = page };
    }

    pub fn cellCount(self: *const LeafNode) NodeError!u16 {
        const count = readU16(&self.page.data, header_layout.cell_count_offset);
        if (count > leaf_layout.max_cells) return error.CorruptNode;
        return count;
    }

    pub fn parentPageId(self: *const LeafNode) u32 {
        return readU32(&self.page.data, header_layout.parent_page_id_offset);
    }

    pub fn setParentPageId(self: *LeafNode, page_id: u32) void {
        writeU32(&self.page.data, header_layout.parent_page_id_offset, page_id);
        self.page.dirty = true;
    }

    pub fn nextLeafPageId(self: *const LeafNode) u32 {
        return readU32(&self.page.data, leaf_layout.next_leaf_page_id_offset);
    }

    pub fn findKey(self: *const LeafNode, key: u64) NodeError!?usize {
        const count = try self.cellCount();
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const cell = try self.readCell(middle);
            if (cell.key < key) {
                low = middle + 1;
            } else if (cell.key > key) {
                high = middle;
            } else {
                return middle;
            }
        }
        return null;
    }

    pub fn lowerBound(self: *const LeafNode, key: u64) NodeError!usize {
        const count = try self.cellCount();
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if ((try self.readCell(middle)).key < key) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    pub fn readValue(self: *const LeafNode, index: usize) NodeError![]const u8 {
        const cell = try self.readCell(index);
        const start: usize = cell.value_offset;
        const end = start + cell.value_length;
        const cells_end = leaf_layout.header_size + @as(usize, try self.cellCount()) * leaf_layout.cell_size;
        if (start < cells_end or end > pager.page_size) return error.CorruptNode;
        return self.page.data[start..end];
    }

    pub fn insertRecord(self: *LeafNode, key: u64, value: []const u8) NodeError!void {
        const count = try self.cellCount();
        if (try self.findKey(key) != null) return error.DuplicateKey;
        if (count == leaf_layout.max_cells) return error.NoSpace;
        const insert_index = try self.lowerBound(key);
        const previous_cells_end = leaf_layout.header_size + @as(usize, count) * leaf_layout.cell_size;
        const new_cells_end = previous_cells_end + leaf_layout.cell_size;
        var payload_start: usize = pager.page_size;
        for (0..count) |index| {
            const cell = try self.readCell(index);
            const start: usize = cell.value_offset;
            const end = start + cell.value_length;
            if (start < previous_cells_end or end > pager.page_size) return error.CorruptNode;
            payload_start = @min(payload_start, start);
        }
        if (value.len > payload_start) return error.NoSpace;
        const value_start = payload_start - value.len;
        if (value_start < new_cells_end) return error.NoSpace;

        var index: usize = count;
        while (index > insert_index) : (index -= 1) {
            const source = leaf_layout.header_size + (index - 1) * leaf_layout.cell_size;
            const destination = leaf_layout.header_size + index * leaf_layout.cell_size;
            var copy: [leaf_layout.cell_size]u8 = undefined;
            @memcpy(&copy, self.page.data[source .. source + leaf_layout.cell_size]);
            @memcpy(self.page.data[destination .. destination + leaf_layout.cell_size], &copy);
        }
        try self.writeCell(insert_index, .{
            .key = key,
            .value_offset = @intCast(value_start),
            .value_length = @intCast(value.len),
        });
        writeU16(&self.page.data, header_layout.cell_count_offset, count + 1);
        @memcpy(self.page.data[value_start .. value_start + value.len], value);
        self.page.dirty = true;
    }

    pub fn readCell(self: *const LeafNode, index: usize) NodeError!LeafCell {
        const count = try self.cellCount();
        if (index >= count) return error.CellOutOfBounds;
        const offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        return .{
            .key = readU64(&self.page.data, offset + leaf_cell_layout.key_offset),
            .value_offset = readU16(&self.page.data, offset + leaf_cell_layout.value_offset_offset),
            .value_length = readU16(&self.page.data, offset + leaf_cell_layout.value_length_offset),
        };
    }

    pub fn writeCell(self: *LeafNode, index: usize, cell: LeafCell) NodeError!void {
        const count = try self.cellCount();
        if (index > count or index >= leaf_layout.max_cells) return error.CellOutOfBounds;
        const offset = leaf_layout.header_size + index * leaf_layout.cell_size;
        writeU64(&self.page.data, offset + leaf_cell_layout.key_offset, cell.key);
        writeU16(&self.page.data, offset + leaf_cell_layout.value_offset_offset, cell.value_offset);
        writeU16(&self.page.data, offset + leaf_cell_layout.value_length_offset, cell.value_length);
        if (index == count) writeU16(&self.page.data, header_layout.cell_count_offset, count + 1);
        self.page.dirty = true;
    }
};

pub const InternalNode = struct {
    page: *pager.Page,

    pub fn init(page: *pager.Page, parent_page_id: u32, first_child_page_id: u32) InternalNode {
        @memset(&page.data, 0);
        page.data[header_layout.node_type_offset] = @intFromEnum(NodeType.internal);
        writeU16(&page.data, header_layout.cell_count_offset, 0);
        writeU32(&page.data, header_layout.parent_page_id_offset, parent_page_id);
        writeU32(&page.data, internal_layout.first_child_page_id_offset, first_child_page_id);
        page.dirty = true;
        return .{ .page = page };
    }

    pub fn cellCount(self: *const InternalNode) NodeError!u16 {
        const count = readU16(&self.page.data, header_layout.cell_count_offset);
        if (count > internal_layout.max_cells) return error.CorruptNode;
        return count;
    }

    pub fn parentPageId(self: *const InternalNode) u32 {
        return readU32(&self.page.data, header_layout.parent_page_id_offset);
    }

    pub fn setParentPageId(self: *InternalNode, page_id: u32) void {
        writeU32(&self.page.data, header_layout.parent_page_id_offset, page_id);
        self.page.dirty = true;
    }

    pub fn setFirstChildPageId(self: *InternalNode, page_id: u32) void {
        writeU32(&self.page.data, internal_layout.first_child_page_id_offset, page_id);
        self.page.dirty = true;
    }

    pub fn childIndex(self: *const InternalNode, child_page_id: u32) NodeError!?usize {
        const count = try self.cellCount();
        if (self.firstChildPageId() == child_page_id) return 0;
        for (0..count) |index| {
            if ((try self.readCell(index)).child_page_id == child_page_id) return index + 1;
        }
        return null;
    }

    pub fn insertCell(self: *InternalNode, index: usize, cell: InternalCell) NodeError!void {
        const count = try self.cellCount();
        if (count == internal_layout.max_cells) return error.NoSpace;
        if (index > count) return error.CellOutOfBounds;
        var cursor = count;
        while (cursor > index) : (cursor -= 1) {
            const source = internal_layout.header_size + (cursor - 1) * internal_layout.cell_size;
            const destination = internal_layout.header_size + cursor * internal_layout.cell_size;
            var copy: [internal_layout.cell_size]u8 = undefined;
            @memcpy(&copy, self.page.data[source .. source + internal_layout.cell_size]);
            @memcpy(self.page.data[destination .. destination + internal_layout.cell_size], &copy);
        }
        try self.writeCell(index, cell);
        writeU16(&self.page.data, header_layout.cell_count_offset, count + 1);
        self.page.dirty = true;
    }

    pub fn firstChildPageId(self: *const InternalNode) u32 {
        return readU32(&self.page.data, internal_layout.first_child_page_id_offset);
    }

    pub fn childPageForKey(self: *const InternalNode, key: u64) NodeError!u32 {
        return findChildPageForKey(&self.page.data, key, try self.cellCount());
    }

    pub fn readCell(self: *const InternalNode, index: usize) NodeError!InternalCell {
        const count = try self.cellCount();
        if (index >= count) return error.CellOutOfBounds;
        const offset = internal_layout.header_size + index * internal_layout.cell_size;
        return .{
            .separator_key = readU64(&self.page.data, offset + internal_cell_layout.separator_key_offset),
            .child_page_id = readU32(&self.page.data, offset + internal_cell_layout.child_page_id_offset),
        };
    }

    pub fn writeCell(self: *InternalNode, index: usize, cell: InternalCell) NodeError!void {
        const count = try self.cellCount();
        if (index > count or index >= internal_layout.max_cells) return error.CellOutOfBounds;
        const offset = internal_layout.header_size + index * internal_layout.cell_size;
        writeU64(&self.page.data, offset + internal_cell_layout.separator_key_offset, cell.separator_key);
        writeU32(&self.page.data, offset + internal_cell_layout.child_page_id_offset, cell.child_page_id);
        if (index == count) writeU16(&self.page.data, header_layout.cell_count_offset, count + 1);
        self.page.dirty = true;
    }
};

pub const Node = union(enum) {
    leaf: LeafNode,
    internal: InternalNode,

    pub fn open(page: *pager.Page) NodeError!Node {
        return switch (page.data[header_layout.node_type_offset]) {
            @intFromEnum(NodeType.leaf) => blk: {
                const leaf = LeafNode{ .page = page };
                _ = try leaf.cellCount();
                break :blk .{ .leaf = leaf };
            },
            @intFromEnum(NodeType.internal) => blk: {
                const internal = InternalNode{ .page = page };
                _ = try internal.cellCount();
                break :blk .{ .internal = internal };
            },
            else => error.InvalidNodeType,
        };
    }

    pub fn cellCount(self: *const Node) NodeError!u16 {
        return switch (self.*) {
            .leaf => |leaf| leaf.cellCount(),
            .internal => |internal| internal.cellCount(),
        };
    }

    pub fn setParentPageId(self: *Node, page_id: u32) void {
        switch (self.*) {
            .leaf => |*leaf| leaf.setParentPageId(page_id),
            .internal => |*internal| internal.setParentPageId(page_id),
        }
    }

    pub fn childPageForKey(self: *const Node, key: u64) NodeError!u32 {
        return switch (self.*) {
            .leaf => error.InvalidNodeType,
            .internal => |internal| findChildPageForKey(&internal.page.data, key, try internal.cellCount()),
        };
    }
};

fn findChildPageForKey(data: []const u8, key: u64, count: u16) u32 {
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const offset = internal_layout.header_size + middle * internal_layout.cell_size;
        if (readU64(data, offset + internal_cell_layout.separator_key_offset) <= key) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == 0) return readU32(data, internal_layout.first_child_page_id_offset);
    const offset = internal_layout.header_size + (low - 1) * internal_layout.cell_size;
    return readU32(data, offset + internal_cell_layout.child_page_id_offset);
}

pub fn recordsFit(records: []const LeafRecord) bool {
    if (records.len > leaf_layout.max_cells) return false;
    const cells_end = leaf_layout.header_size + records.len * leaf_layout.cell_size;
    var payload_size: usize = 0;
    for (records) |record| payload_size += record.value_length;
    return payload_size <= pager.page_size - cells_end;
}

pub fn rebuildLeafPage(
    page: *pager.Page,
    records: []const LeafRecord,
    values: []const u8,
    parent_page_id: u32,
    next_leaf_page_id: u32,
) NodeError!void {
    if (!recordsFit(records)) return error.NoSpace;
    for (records) |record| {
        if (record.value_offset > values.len or record.value_length > values.len - record.value_offset) {
            return error.CorruptNode;
        }
    }
    var leaf = LeafNode.init(page, parent_page_id, next_leaf_page_id);
    var payload_start: usize = pager.page_size;
    for (records, 0..) |record, index| {
        payload_start -= record.value_length;
        try leaf.writeCell(index, .{
            .key = record.key,
            .value_offset = @intCast(payload_start),
            .value_length = @intCast(record.value_length),
        });
        @memcpy(
            page.data[payload_start .. payload_start + record.value_length],
            values[record.value_offset .. record.value_offset + record.value_length],
        );
    }
}

pub fn rebuildInternalPage(
    page: *pager.Page,
    parent_page_id: u32,
    first_child_page_id: u32,
    separators: []const u64,
    children: []const u32,
) NodeError!void {
    if (separators.len > internal_layout.max_cells or children.len != separators.len + 1) return error.CorruptNode;
    var internal = InternalNode.init(page, parent_page_id, first_child_page_id);
    for (separators, 0..) |key, index| {
        try internal.writeCell(index, .{ .separator_key = key, .child_page_id = children[index + 1] });
    }
}

pub fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

pub fn readU32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

pub fn readU64(data: []const u8, offset: usize) u64 {
    var value: u64 = 0;
    for (0..8) |index| value |= @as(u64, data[offset + index]) << @as(u6, @intCast(index * 8));
    return value;
}

pub fn writeU16(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
}

pub fn writeU32(data: []u8, offset: usize, value: u32) void {
    for (0..4) |index| data[offset + index] = @truncate(value >> @as(u5, @intCast(index * 8)));
}

pub fn writeU64(data: []u8, offset: usize, value: u64) void {
    for (0..8) |index| data[offset + index] = @truncate(value >> @as(u6, @intCast(index * 8)));
}
