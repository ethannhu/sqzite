const pager = @import("pager.zig");
const node = @import("node.zig");

const LeafRecord = node.LeafRecord;

/// 搜索过程中可能遇到的节点或存储错误。
pub const SearchError = error{ CorruptNode, InvalidNodeType, Storage };

/// 插入时可能遇到的结构、容量或存储错误。
pub const InsertError = error{ CorruptNode, DuplicateKey, InvalidNodeType, NoSpace, Storage };

/// 查询结果是叶子页中的借用数据，生命周期受 Pager 页面缓存管理。
pub const SearchResult = ?[]const u8;

fn mapSearchNodeError(err: node.NodeError) SearchError {
    return switch (err) {
        error.InvalidNodeType => error.InvalidNodeType,
        else => error.CorruptNode,
    };
}

fn mapInsertNodeError(err: node.NodeError) InsertError {
    return switch (err) {
        error.InvalidNodeType => error.InvalidNodeType,
        error.DuplicateKey => error.DuplicateKey,
        error.NoSpace => error.NoSpace,
        else => error.CorruptNode,
    };
}

/// B+ 树句柄只保存 Pager 和根页号，不拥有 Pager。
pub const BPlusTree = struct {
    pager: *pager.Pager,
    root_page_id: ?u32,

    /// 插入键值；叶子页或内部页满时分裂，并将分隔键向根递归传播。
    pub fn insert(self: *BPlusTree, key: u64, value: []const u8) InsertError!void {
        if (value.len > pager.page_size - node.leaf_layout.header_size - node.leaf_layout.cell_size) {
            return error.NoSpace;
        }

        if (self.root_page_id == null) {
            const root = self.pager.allocatePage() catch return error.Storage;
            var leaf = node.LeafNode.init(root, 0, 0);
            leaf.insertRecord(key, value) catch |err| return mapInsertNodeError(err);
            self.root_page_id = root.id;
            return;
        }

        var page_id = self.root_page_id.?;
        var parent_path: [128]u32 = undefined;
        var parent_count: usize = 0;
        for (0..128) |_| {
            const page = self.pager.getPage(page_id) catch return error.Storage;
            const current = node.Node.open(page) catch |err| return mapInsertNodeError(err);
            switch (current) {
                .leaf => {
                    const parent_page_id = if (parent_count == 0) null else parent_path[parent_count - 1];
                    return insertOrSplitLeaf(self, page, parent_page_id, key, value);
                },
                .internal => |internal| {
                    if (parent_count == parent_path.len) return error.CorruptNode;
                    parent_path[parent_count] = page_id;
                    parent_count += 1;
                    page_id = internal.childPageForKey(key) catch |err| return mapInsertNodeError(err);
                },
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
            const current = node.Node.open(page) catch |err| return mapSearchNodeError(err);
            switch (current) {
                .leaf => |leaf| {
                    const index = leaf.findKey(key) catch |err| return mapSearchNodeError(err);
                    if (index) |found| return leaf.readValue(found) catch |err| return mapSearchNodeError(err);
                    return null;
                },
                .internal => |internal| {
                    page_id = internal.childPageForKey(key) catch |err| return mapSearchNodeError(err);
                },
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
    var leaf = node.LeafNode{ .page = page };
    leaf.insertRecord(key, value) catch |err| {
        if (err != error.NoSpace) return mapInsertNodeError(err);
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
    const leaf = node.LeafNode{ .page = page };
    const cell_count = leaf.cellCount() catch |err| return mapInsertNodeError(err);
    if ((leaf.findKey(key) catch |err| return mapInsertNodeError(err)) != null) return error.DuplicateKey;

    // 定位叶子在父节点中的槽位，后续将分隔键递归插入父节点。
    var parent: ?*pager.Page = null;
    var child_index: usize = 0;
    if (parent_page_id) |parent_id| {
        const parent_page = tree.pager.getPage(parent_id) catch return error.Storage;
        const parent_node = node.Node.open(parent_page) catch |err| return mapInsertNodeError(err);
        const internal = switch (parent_node) {
            .internal => |internal_node| internal_node,
            .leaf => return error.InvalidNodeType,
        };
        child_index = (internal.childIndex(page.id) catch |err| return mapInsertNodeError(err)) orelse return error.CorruptNode;
        parent = parent_page;
    }

    const insert_index = leaf.lowerBound(key) catch |err| return mapInsertNodeError(err);
    const total_count = @as(usize, cell_count) + 1;
    var records: [node.leaf_layout.max_cells + 1]LeafRecord = undefined;
    var values: [pager.page_size * 2]u8 = undefined;
    var values_len: usize = 0;

    // 暂存旧值，后续重建页面时原始字节区会被覆盖。
    for (0..cell_count) |index| {
        const cell = leaf.readCell(index) catch |err| return mapInsertNodeError(err);
        const old_value = leaf.readValue(index) catch |err| return mapInsertNodeError(err);
        if (old_value.len > values.len - values_len) return error.CorruptNode;

        @memcpy(values[values_len .. values_len + old_value.len], old_value);
        records[index] = .{
            .key = cell.key,
            .value_offset = values_len,
            .value_length = old_value.len,
        };
        values_len += old_value.len;
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
    if (!node.recordsFit(left_records) or !node.recordsFit(right_records)) return error.NoSpace;

    const old_next_page_id = leaf.nextLeafPageId();
    const right_page = tree.pager.allocatePage() catch return error.Storage;

    if (parent) |parent_page| {
        node.rebuildLeafPage(page, left_records, &values, parent_page.id, right_page.id) catch |err| return mapInsertNodeError(err);
        node.rebuildLeafPage(right_page, right_records, &values, parent_page.id, old_next_page_id) catch |err| return mapInsertNodeError(err);
        try insertSeparator(tree, parent_page, child_index, right_records[0].key, right_page.id);
        return;
    }

    const new_root = tree.pager.allocatePage() catch return error.Storage;
    node.rebuildLeafPage(page, left_records, &values, new_root.id, right_page.id) catch |err| return mapInsertNodeError(err);
    node.rebuildLeafPage(right_page, right_records, &values, new_root.id, old_next_page_id) catch |err| return mapInsertNodeError(err);
    try initializeInternalRoot(new_root, page.id, right_records[0].key, right_page.id);
    tree.root_page_id = new_root.id;
}

/// 将子节点分裂产生的分隔键插入父节点；满时拆分内部节点并向上递归。
fn insertSeparator(
    tree: *BPlusTree,
    parent_page: *pager.Page,
    child_index: usize,
    separator: u64,
    right_child_page_id: u32,
) InsertError!void {
    var parent = node.InternalNode{ .page = parent_page };
    const cell_count = parent.cellCount() catch |err| return mapInsertNodeError(err);
    if (child_index > cell_count) return error.CorruptNode;

    if (cell_count < node.internal_layout.max_cells) {
        parent.insertCell(child_index, .{ .separator_key = separator, .child_page_id = right_child_page_id }) catch |err| return mapInsertNodeError(err);
        const right_child = tree.pager.getPage(right_child_page_id) catch return error.Storage;
        var right_node = node.Node.open(right_child) catch |err| return mapInsertNodeError(err);
        right_node.setParentPageId(parent_page.id);
        return;
    }

    const total_cells = @as(usize, cell_count) + 1;
    var separators: [node.internal_layout.max_cells + 1]u64 = undefined;
    var children: [node.internal_layout.max_cells + 2]u32 = undefined;

    children[0] = parent.firstChildPageId();
    for (0..cell_count) |index| {
        const cell = parent.readCell(index) catch |err| return mapInsertNodeError(err);
        separators[index] = cell.separator_key;
        children[index + 1] = cell.child_page_id;
    }

    var merged_separators: [node.internal_layout.max_cells + 1]u64 = undefined;
    var merged_children: [node.internal_layout.max_cells + 2]u32 = undefined;
    for (0..total_cells) |index| {
        if (index < child_index) {
            merged_separators[index] = separators[index];
        } else if (index == child_index) {
            merged_separators[index] = separator;
        } else {
            merged_separators[index] = separators[index - 1];
        }
    }
    for (0..total_cells + 1) |index| {
        if (index <= child_index) {
            merged_children[index] = children[index];
        } else if (index == child_index + 1) {
            merged_children[index] = right_child_page_id;
        } else {
            merged_children[index] = children[index - 1];
        }
    }

    const split_index = total_cells / 2;
    const promoted_separator = merged_separators[split_index];
    const parent_page_id = parent.parentPageId();
    const is_root = tree.root_page_id != null and tree.root_page_id.? == parent_page.id;
    const right_page = tree.pager.allocatePage() catch return error.Storage;

    node.rebuildInternalPage(
        parent_page,
        parent_page_id,
        merged_children[0],
        merged_separators[0..split_index],
        merged_children[0 .. split_index + 1],
    ) catch |err| return mapInsertNodeError(err);
    node.rebuildInternalPage(
        right_page,
        parent_page_id,
        merged_children[split_index + 1],
        merged_separators[split_index + 1 .. total_cells],
        merged_children[split_index + 1 .. total_cells + 1],
    ) catch |err| return mapInsertNodeError(err);

    for (merged_children[0 .. split_index + 1]) |child_id| {
        const child = tree.pager.getPage(child_id) catch return error.Storage;
        var child_node = node.Node.open(child) catch |err| return mapInsertNodeError(err);
        child_node.setParentPageId(parent_page.id);
    }
    for (merged_children[split_index + 1 .. total_cells + 1]) |child_id| {
        const child = tree.pager.getPage(child_id) catch return error.Storage;
        var child_node = node.Node.open(child) catch |err| return mapInsertNodeError(err);
        child_node.setParentPageId(right_page.id);
    }

    if (is_root) {
        const new_root = tree.pager.allocatePage() catch return error.Storage;
        try initializeInternalRoot(new_root, parent_page.id, promoted_separator, right_page.id);
        parent.setParentPageId(new_root.id);
        var right_node = node.InternalNode{ .page = right_page };
        right_node.setParentPageId(new_root.id);
        tree.root_page_id = new_root.id;
        return;
    }

    const grandparent = tree.pager.getPage(parent_page_id) catch return error.Storage;
    const grandparent_node = node.Node.open(grandparent) catch |err| return mapInsertNodeError(err);
    const grandparent_internal = switch (grandparent_node) {
        .internal => |internal| internal,
        .leaf => return error.InvalidNodeType,
    };
    const parent_index = (grandparent_internal.childIndex(parent_page.id) catch |err| return mapInsertNodeError(err)) orelse return error.CorruptNode;
    try insertSeparator(tree, grandparent, parent_index, promoted_separator, right_page.id);
}

fn initializeInternalRoot(page: *pager.Page, left_page_id: u32, separator: u64, right_page_id: u32) InsertError!void {
    var internal = node.InternalNode.init(page, 0, left_page_id);
    internal.writeCell(0, .{ .separator_key = separator, .child_page_id = right_page_id }) catch |err| return mapInsertNodeError(err);
}
