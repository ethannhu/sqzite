const pager = @import("pager.zig");
const node = @import("node.zig");

const LeafRecord = node.LeafRecord;

/// 搜索过程中可能遇到的节点或存储错误。
pub const SearchError = error{ CorruptNode, InvalidNodeType, Storage };

/// 同父节点下兄弟页的相对方向。
pub const SiblingDirection = enum {
    previous,
    next,
};

/// 插入时可能遇到的结构、容量或存储错误。
pub const InsertError = error{ CorruptNode, DuplicateKey, InvalidNodeType, NoSpace, Storage };

/// 删除时可能遇到的结构、容量或存储错误。
pub const DeleteError = error{ CorruptNode, InvalidNodeType, NoSpace, Storage };

/// 合并相邻节点时可能遇到的结构、容量或存储错误。
pub const MergeError = error{ CorruptNode, InvalidNodeType, NotSiblings, NotAdjacent, NoSpace, Storage };

/// 兄弟节点重分配时可能遇到的结构、容量或存储错误。
pub const RedistributeError = error{ CorruptNode, InvalidNodeType, NotSiblings, NotAdjacent, NoSpace, Storage };

/// 节点重平衡时可能遇到的结构、容量或存储错误。
pub const RebalanceError = error{ CorruptNode, InvalidNodeType, NotSiblings, NotAdjacent, NoSpace, Storage };

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

fn mapMergeNodeError(err: node.NodeError) MergeError {
    return switch (err) {
        error.InvalidNodeType => error.InvalidNodeType,
        error.NoSpace => error.NoSpace,
        else => error.CorruptNode,
    };
}

fn mapRedistributeNodeError(err: node.NodeError) RedistributeError {
    return switch (err) {
        error.InvalidNodeType => error.InvalidNodeType,
        error.NoSpace => error.NoSpace,
        else => error.CorruptNode,
    };
}

fn mapMergeErrorToRedistribute(err: MergeError) RedistributeError {
    return switch (err) {
        error.CorruptNode => error.CorruptNode,
        error.InvalidNodeType => error.InvalidNodeType,
        error.NotSiblings => error.NotSiblings,
        error.NotAdjacent => error.NotAdjacent,
        error.NoSpace => error.NoSpace,
        error.Storage => error.Storage,
    };
}

fn mapRedistributeErrorToRebalance(err: RedistributeError) RebalanceError {
    return switch (err) {
        error.CorruptNode => error.CorruptNode,
        error.InvalidNodeType => error.InvalidNodeType,
        error.NotSiblings => error.NotSiblings,
        error.NotAdjacent => error.NotAdjacent,
        error.NoSpace => error.NoSpace,
        error.Storage => error.Storage,
    };
}

fn mapMergeErrorToRebalance(err: MergeError) RebalanceError {
    return switch (err) {
        error.CorruptNode => error.CorruptNode,
        error.InvalidNodeType => error.InvalidNodeType,
        error.NotSiblings => error.NotSiblings,
        error.NotAdjacent => error.NotAdjacent,
        error.NoSpace => error.NoSpace,
        error.Storage => error.Storage,
    };
}

fn mapNodeErrorToRebalance(err: node.NodeError) RebalanceError {
    return switch (err) {
        error.InvalidNodeType => error.InvalidNodeType,
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

    /// 删除指定键；键不存在时返回 false，成功删除时调整节点占用和分隔键。
    pub fn delete(self: *BPlusTree, key: u64) DeleteError!bool {
        const root_page_id = self.root_page_id orelse return false;
        var page_id = root_page_id;

        for (0..128) |_| {
            const page = self.pager.getPage(page_id) catch return error.Storage;
            const current = node.Node.open(page) catch |err| return mapDeleteNodeError(err);
            switch (current) {
                .leaf => |leaf| {
                    const found = (leaf.findKey(key) catch |err| return mapDeleteNodeError(err)) orelse return false;
                    try deleteLeafRecord(leaf, found);
                    if (page_id == root_page_id) {
                        const remaining = leaf.cellCount() catch |err| return mapDeleteNodeError(err);
                        if (remaining == 0) {
                            node.invalidatePage(page);
                            self.root_page_id = null;
                        }
                        return true;
                    }

                    self.rebalanceNode(page_id) catch |err| return mapDeleteRebalanceError(err);
                    if (self.root_page_id) |new_root| {
                        _ = try refreshSeparators(self, new_root, 0);
                    }
                    return true;
                },
                .internal => |internal| {
                    page_id = internal.childPageForKey(key) catch |err| return mapDeleteNodeError(err);
                },
            }
        }

        return error.CorruptNode;
    }

    /// 返回当前节点在同一父节点下相邻的兄弟页号；根节点和边界位置返回 null。
    pub fn siblingPageId(self: *BPlusTree, page_id: u32, direction: SiblingDirection) SearchError!?u32 {
        const root_page_id = self.root_page_id orelse return null;
        if (page_id == root_page_id) return null;

        const page = self.pager.getPage(page_id) catch return error.Storage;
        const current = node.Node.open(page) catch |err| return mapSearchNodeError(err);
        const parent_page_id = switch (current) {
            .leaf => |leaf| leaf.parentPageId(),
            .internal => |internal| internal.parentPageId(),
        };

        const parent_page = self.pager.getPage(parent_page_id) catch return error.Storage;
        const parent_node = node.Node.open(parent_page) catch |err| return mapSearchNodeError(err);
        const parent = switch (parent_node) {
            .internal => |internal| internal,
            .leaf => return error.InvalidNodeType,
        };
        const child_index = (parent.childIndex(page_id) catch |err| return mapSearchNodeError(err)) orelse {
            return error.CorruptNode;
        };
        const child_count = parent.cellCount() catch |err| return mapSearchNodeError(err);

        const adjacent_index = switch (direction) {
            .previous => if (child_index == 0) return null else child_index - 1,
            .next => if (child_index == child_count) return null else child_index + 1,
        };
        return parent.childPageAt(adjacent_index) catch |err| return mapSearchNodeError(err);
    }

    /// 将同一父节点下相邻的两个兄弟合并进左页，并移除父节点中的分隔键。
    pub fn mergeSiblings(self: *BPlusTree, left_page_id: u32, right_page_id: u32) MergeError!void {
        if (left_page_id == right_page_id) return error.NotAdjacent;
        const root_page_id = self.root_page_id orelse return error.CorruptNode;
        if (left_page_id == root_page_id or right_page_id == root_page_id) return error.NotSiblings;

        const left_page = self.pager.getPage(left_page_id) catch return error.Storage;
        const right_page = self.pager.getPage(right_page_id) catch return error.Storage;
        const left_node = node.Node.open(left_page) catch |err| return mapMergeNodeError(err);
        const right_node = node.Node.open(right_page) catch |err| return mapMergeNodeError(err);
        const left_parent_id = nodeParentPageId(left_node);
        if (left_parent_id != nodeParentPageId(right_node)) return error.NotSiblings;

        const parent_page = self.pager.getPage(left_parent_id) catch return error.Storage;
        const parent_node = node.Node.open(parent_page) catch |err| return mapMergeNodeError(err);
        var parent = switch (parent_node) {
            .internal => |internal| internal,
            .leaf => return error.InvalidNodeType,
        };
        const left_index = (parent.childIndex(left_page_id) catch |err| return mapMergeNodeError(err)) orelse {
            return error.CorruptNode;
        };
        const right_index = (parent.childIndex(right_page_id) catch |err| return mapMergeNodeError(err)) orelse {
            return error.CorruptNode;
        };
        if (right_index != left_index + 1) return error.NotAdjacent;
        const parent_separator = (parent.readCell(left_index) catch |err| return mapMergeNodeError(err)).separator_key;

        switch (left_node) {
            .leaf => |left| switch (right_node) {
                .leaf => |right| try mergeLeafPages(left, right, left_parent_id),
                .internal => return error.InvalidNodeType,
            },
            .internal => |left| switch (right_node) {
                .leaf => return error.InvalidNodeType,
                .internal => |right| try mergeInternalPages(self, left, right, parent_separator, left_parent_id),
            },
        }

        _ = parent.deleteCell(left_index) catch |err| return mapMergeNodeError(err);
        const remaining_parent_cells = parent.cellCount() catch |err| return mapMergeNodeError(err);
        if (self.root_page_id.? == parent_page.id and remaining_parent_cells == 0) {
            var merged = node.Node.open(left_page) catch |err| return mapMergeNodeError(err);
            merged.setParentPageId(0);
            self.root_page_id = left_page_id;
            node.invalidatePage(parent_page);
        }
    }

    /// 在相邻兄弟之间平衡 Cell，并更新父节点分隔键。
    pub fn redistributeSiblings(self: *BPlusTree, left_page_id: u32, right_page_id: u32) RedistributeError!void {
        if (left_page_id == right_page_id) return error.NotAdjacent;
        const root_page_id = self.root_page_id orelse return error.CorruptNode;
        if (left_page_id == root_page_id or right_page_id == root_page_id) return error.NotSiblings;

        const left_page = self.pager.getPage(left_page_id) catch return error.Storage;
        const right_page = self.pager.getPage(right_page_id) catch return error.Storage;
        const left_node = node.Node.open(left_page) catch |err| return mapRedistributeNodeError(err);
        const right_node = node.Node.open(right_page) catch |err| return mapRedistributeNodeError(err);
        const parent_page_id = nodeParentPageId(left_node);
        if (parent_page_id != nodeParentPageId(right_node)) return error.NotSiblings;

        const parent_page = self.pager.getPage(parent_page_id) catch return error.Storage;
        const parent_node = node.Node.open(parent_page) catch |err| return mapRedistributeNodeError(err);
        const parent = switch (parent_node) {
            .internal => |internal| internal,
            .leaf => return error.InvalidNodeType,
        };
        const left_index = (parent.childIndex(left_page_id) catch |err| return mapRedistributeNodeError(err)) orelse {
            return error.CorruptNode;
        };
        const right_index = (parent.childIndex(right_page_id) catch |err| return mapRedistributeNodeError(err)) orelse {
            return error.CorruptNode;
        };
        if (right_index != left_index + 1) return error.NotAdjacent;

        switch (left_node) {
            .leaf => |left| switch (right_node) {
                .leaf => |right| try redistributeLeafPages(left, right, parent, left_index),
                .internal => return error.InvalidNodeType,
            },
            .internal => |left| switch (right_node) {
                .leaf => return error.InvalidNodeType,
                .internal => |right| try redistributeInternalPages(self, left, right, parent, left_index),
            },
        }
    }

    /// 从指定节点开始，先重分配兄弟 Cell；无法达到最小占用时合并并向父节点递归。
    pub fn rebalanceNode(self: *BPlusTree, page_id: u32) RebalanceError!void {
        try rebalanceAt(self, page_id, 0);
    }
};

fn mapDeleteNodeError(err: node.NodeError) DeleteError {
    return switch (err) {
        error.InvalidNodeType => error.InvalidNodeType,
        error.NoSpace => error.NoSpace,
        else => error.CorruptNode,
    };
}

fn mapDeleteRebalanceError(err: RebalanceError) DeleteError {
    return switch (err) {
        error.CorruptNode => error.CorruptNode,
        error.InvalidNodeType => error.InvalidNodeType,
        error.NoSpace => error.NoSpace,
        error.NotSiblings, error.NotAdjacent => error.CorruptNode,
        error.Storage => error.Storage,
    };
}

fn deleteLeafRecord(leaf: node.LeafNode, deleted_index: usize) DeleteError!void {
    const count = leaf.cellCount() catch |err| return mapDeleteNodeError(err);
    if (deleted_index >= count) return error.CorruptNode;

    var records: [node.leaf_layout.max_cells]LeafRecord = undefined;
    var values: [pager.page_size]u8 = undefined;
    var record_count: usize = 0;
    var values_len: usize = 0;
    for (0..count) |index| {
        if (index == deleted_index) continue;
        const cell = leaf.readCell(index) catch |err| return mapDeleteNodeError(err);
        const value = leaf.readValue(index) catch |err| return mapDeleteNodeError(err);
        if (value.len > values.len - values_len) return error.CorruptNode;
        @memcpy(values[values_len .. values_len + value.len], value);
        records[record_count] = .{
            .key = cell.key,
            .value_offset = values_len,
            .value_length = value.len,
        };
        record_count += 1;
        values_len += value.len;
    }

    node.rebuildLeafPage(
        leaf.page,
        records[0..record_count],
        values[0..values_len],
        leaf.parentPageId(),
        leaf.nextLeafPageId(),
    ) catch |err| return mapDeleteNodeError(err);
}

fn refreshSeparators(tree: *BPlusTree, page_id: u32, depth: usize) DeleteError!u64 {
    if (depth >= 128) return error.CorruptNode;
    const page = tree.pager.getPage(page_id) catch return error.Storage;
    const current = node.Node.open(page) catch |err| return mapDeleteNodeError(err);
    switch (current) {
        .leaf => |leaf| {
            const count = leaf.cellCount() catch |err| return mapDeleteNodeError(err);
            if (count == 0) return error.CorruptNode;
            return (leaf.readCell(0) catch |err| return mapDeleteNodeError(err)).key;
        },
        .internal => |internal_value| {
            var internal = internal_value;
            const count = internal.cellCount() catch |err| return mapDeleteNodeError(err);
            var first_key: ?u64 = null;
            for (0..@as(usize, count) + 1) |child_index| {
                const child_id = internal.childPageAt(child_index) catch |err| return mapDeleteNodeError(err);
                const child_minimum = try refreshSeparators(tree, child_id, depth + 1);
                if (child_index == 0) {
                    first_key = child_minimum;
                } else {
                    var cell = internal.readCell(child_index - 1) catch |err| return mapDeleteNodeError(err);
                    cell.separator_key = child_minimum;
                    internal.writeCell(child_index - 1, cell) catch |err| return mapDeleteNodeError(err);
                }
            }
            return first_key orelse error.CorruptNode;
        },
    }
}

fn nodeParentPageId(current: node.Node) u32 {
    return switch (current) {
        .leaf => |leaf| leaf.parentPageId(),
        .internal => |internal| internal.parentPageId(),
    };
}

fn nodeCellCount(current: node.Node) RebalanceError!usize {
    return current.cellCount() catch |err| return mapNodeErrorToRebalance(err);
}

fn nodeMinCellCount(current: node.Node) usize {
    return switch (current) {
        .leaf => node.leaf_layout.max_cells / 2,
        .internal => node.internal_layout.max_cells / 2,
    };
}

fn rebalanceAt(tree: *BPlusTree, page_id: u32, depth: usize) RebalanceError!void {
    if (depth >= 128) return error.CorruptNode;
    const root_page_id = tree.root_page_id orelse return error.CorruptNode;
    const page = tree.pager.getPage(page_id) catch return error.Storage;
    const current = node.Node.open(page) catch |err| return mapNodeErrorToRebalance(err);
    const current_count = try nodeCellCount(current);

    if (page_id == root_page_id) {
        if (current == .internal and current_count == 0) {
            const child_page_id = current.internal.firstChildPageId();
            if (child_page_id == page_id) return error.CorruptNode;
            const child_page = tree.pager.getPage(child_page_id) catch return error.Storage;
            var child = node.Node.open(child_page) catch |err| return mapNodeErrorToRebalance(err);
            child.setParentPageId(0);
            tree.root_page_id = child_page_id;
            node.invalidatePage(page);
        }
        return;
    }

    const minimum = nodeMinCellCount(current);
    if (current_count >= minimum) return;

    const parent_page_id = nodeParentPageId(current);
    const parent_page = tree.pager.getPage(parent_page_id) catch return error.Storage;
    const parent_node = node.Node.open(parent_page) catch |err| return mapNodeErrorToRebalance(err);
    const parent = switch (parent_node) {
        .internal => |internal| internal,
        .leaf => return error.InvalidNodeType,
    };
    const left_sibling = tree.siblingPageId(page_id, .previous) catch |err| return mapSearchErrorToRebalance(err);
    const right_sibling = tree.siblingPageId(page_id, .next) catch |err| return mapSearchErrorToRebalance(err);

    if (left_sibling == null and right_sibling == null) {
        const parent_count = try nodeCellCount(.{ .internal = parent });
        if (parent_page_id == root_page_id and parent_count == 0) {
            try rebalanceAt(tree, parent_page_id, depth + 1);
            if (tree.root_page_id.? == page_id) return;
            return rebalanceAt(tree, page_id, depth + 1);
        }
        if (parent_page_id != root_page_id and parent_count < node.internal_layout.max_cells / 2) {
            try rebalanceAt(tree, parent_page_id, depth + 1);
            if (tree.root_page_id.? == page_id) return;
            return rebalanceAt(tree, page_id, depth + 1);
        }
        return error.CorruptNode;
    }

    if (left_sibling) |sibling_id| {
        tree.redistributeSiblings(sibling_id, page_id) catch |err| {
            if (err != error.NoSpace) return mapRedistributeErrorToRebalance(err);
        };
        const left_page = tree.pager.getPage(sibling_id) catch return error.Storage;
        const left_node = node.Node.open(left_page) catch |err| return mapNodeErrorToRebalance(err);
        const current_page = tree.pager.getPage(page_id) catch return error.Storage;
        const current_node = node.Node.open(current_page) catch |err| return mapNodeErrorToRebalance(err);
        if (try nodeCellCount(left_node) >= nodeMinCellCount(left_node) and
            try nodeCellCount(current_node) >= nodeMinCellCount(current_node)) return;
    }
    if (right_sibling) |sibling_id| {
        tree.redistributeSiblings(page_id, sibling_id) catch |err| {
            if (err != error.NoSpace) return mapRedistributeErrorToRebalance(err);
        };
        const current_page = tree.pager.getPage(page_id) catch return error.Storage;
        const current_node = node.Node.open(current_page) catch |err| return mapNodeErrorToRebalance(err);
        const right_page = tree.pager.getPage(sibling_id) catch return error.Storage;
        const right_node = node.Node.open(right_page) catch |err| return mapNodeErrorToRebalance(err);
        if (try nodeCellCount(current_node) >= nodeMinCellCount(current_node) and
            try nodeCellCount(right_node) >= nodeMinCellCount(right_node)) return;
    }

    if (left_sibling) |sibling_id| {
        if (tree.mergeSiblings(sibling_id, page_id)) |_| {
            try rebalanceAt(tree, sibling_id, depth + 1);
            const merged_page = tree.pager.getPage(sibling_id) catch return error.Storage;
            const merged_node = node.Node.open(merged_page) catch |err| return mapNodeErrorToRebalance(err);
            const merged_parent_id = nodeParentPageId(merged_node);
            if (sibling_id != tree.root_page_id.? and merged_parent_id != tree.root_page_id.?) {
                try rebalanceAt(tree, merged_parent_id, depth + 1);
            }
            return;
        } else |err| {
            if (err != error.NoSpace) return mapMergeErrorToRebalance(err);
        }
    }
    if (right_sibling) |sibling_id| {
        if (tree.mergeSiblings(page_id, sibling_id)) |_| {
            try rebalanceAt(tree, page_id, depth + 1);
            const merged_page = tree.pager.getPage(page_id) catch return error.Storage;
            const merged_node = node.Node.open(merged_page) catch |err| return mapNodeErrorToRebalance(err);
            const merged_parent_id = nodeParentPageId(merged_node);
            if (page_id != tree.root_page_id.? and merged_parent_id != tree.root_page_id.?) {
                try rebalanceAt(tree, merged_parent_id, depth + 1);
            }
            return;
        } else |err| {
            if (err != error.NoSpace) return mapMergeErrorToRebalance(err);
        }
    }

    return error.NoSpace;
}

fn mapSearchErrorToRebalance(err: SearchError) RebalanceError {
    return switch (err) {
        error.CorruptNode => error.CorruptNode,
        error.InvalidNodeType => error.InvalidNodeType,
        error.Storage => error.Storage,
    };
}

fn mergeLeafPages(
    left: node.LeafNode,
    right: node.LeafNode,
    parent_page_id: u32,
) MergeError!void {
    const left_count = left.cellCount() catch |err| return mapMergeNodeError(err);
    const right_count = right.cellCount() catch |err| return mapMergeNodeError(err);
    const total_count = @as(usize, left_count) + right_count;
    if (total_count > node.leaf_layout.max_cells) return error.NoSpace;

    var records: [node.leaf_layout.max_cells]node.LeafRecord = undefined;
    var values: [pager.page_size * 2]u8 = undefined;
    var record_count: usize = 0;
    var values_len: usize = 0;
    try appendLeafRecords(left, &records, &record_count, &values, &values_len);
    try appendLeafRecords(right, &records, &record_count, &values, &values_len);
    if (!node.recordsFit(records[0..record_count])) return error.NoSpace;

    node.rebuildLeafPage(
        left.page,
        records[0..record_count],
        values[0..values_len],
        parent_page_id,
        right.nextLeafPageId(),
    ) catch |err| return mapMergeNodeError(err);
    node.invalidatePage(right.page);
}

fn appendLeafRecords(
    leaf: node.LeafNode,
    records: []node.LeafRecord,
    record_count: *usize,
    values: []u8,
    values_len: *usize,
) MergeError!void {
    const count = leaf.cellCount() catch |err| return mapMergeNodeError(err);
    if (count > records.len - record_count.*) return error.NoSpace;
    for (0..count) |index| {
        const cell = leaf.readCell(index) catch |err| return mapMergeNodeError(err);
        const value = leaf.readValue(index) catch |err| return mapMergeNodeError(err);
        if (value.len > values.len - values_len.*) return error.NoSpace;
        @memcpy(values[values_len.* .. values_len.* + value.len], value);
        records[record_count.*] = .{
            .key = cell.key,
            .value_offset = values_len.*,
            .value_length = value.len,
        };
        values_len.* += value.len;
        record_count.* += 1;
    }
}

fn mergeInternalPages(
    tree: *BPlusTree,
    left: node.InternalNode,
    right: node.InternalNode,
    parent_separator: u64,
    parent_page_id: u32,
) MergeError!void {
    const left_count = left.cellCount() catch |err| return mapMergeNodeError(err);
    const right_count = right.cellCount() catch |err| return mapMergeNodeError(err);
    const total_count = @as(usize, left_count) + 1 + right_count;
    if (total_count > node.internal_layout.max_cells) return error.NoSpace;

    var separators: [node.internal_layout.max_cells]u64 = undefined;
    var children: [node.internal_layout.max_cells + 1]u32 = undefined;
    var separator_count: usize = 0;
    var child_count: usize = 1;
    children[0] = left.firstChildPageId();

    for (0..left_count) |index| {
        const cell = left.readCell(index) catch |err| return mapMergeNodeError(err);
        separators[separator_count] = cell.separator_key;
        children[child_count] = cell.child_page_id;
        separator_count += 1;
        child_count += 1;
    }
    separators[separator_count] = parent_separator;
    children[child_count] = right.firstChildPageId();
    separator_count += 1;
    child_count += 1;
    for (0..right_count) |index| {
        const cell = right.readCell(index) catch |err| return mapMergeNodeError(err);
        separators[separator_count] = cell.separator_key;
        children[child_count] = cell.child_page_id;
        separator_count += 1;
        child_count += 1;
    }

    node.rebuildInternalPage(
        left.page,
        parent_page_id,
        children[0],
        separators[0..separator_count],
        children[0..child_count],
    ) catch |err| return mapMergeNodeError(err);
    for (children[0..child_count]) |child_page_id| {
        const child_page = tree.pager.getPage(child_page_id) catch return error.Storage;
        var child_node = node.Node.open(child_page) catch |err| return mapMergeNodeError(err);
        child_node.setParentPageId(left.page.id);
    }
    node.invalidatePage(right.page);
}

fn redistributeLeafPages(
    left: node.LeafNode,
    right: node.LeafNode,
    parent: node.InternalNode,
    parent_cell_index: usize,
) RedistributeError!void {
    const left_count = left.cellCount() catch |err| return mapRedistributeNodeError(err);
    const right_count = right.cellCount() catch |err| return mapRedistributeNodeError(err);
    const total_count = @as(usize, left_count) + right_count;
    if (total_count < 2) return;

    var records: [node.leaf_layout.max_cells * 2]node.LeafRecord = undefined;
    var values: [pager.page_size * 2]u8 = undefined;
    var record_count: usize = 0;
    var values_len: usize = 0;
    appendLeafRecords(left, &records, &record_count, &values, &values_len) catch |err| return mapMergeErrorToRedistribute(err);
    appendLeafRecords(right, &records, &record_count, &values, &values_len) catch |err| return mapMergeErrorToRedistribute(err);
    if (record_count < 2) return;

    const target = record_count / 2;
    var split_index: ?usize = null;
    var best_distance: usize = record_count;
    for (1..record_count) |candidate| {
        if (!node.recordsFit(records[0..candidate]) or !node.recordsFit(records[candidate..record_count])) continue;
        const distance = if (candidate > target) candidate - target else target - candidate;
        if (distance < best_distance) {
            split_index = candidate;
            best_distance = distance;
        }
    }
    const split = split_index orelse return error.NoSpace;
    const separator = records[split].key;
    const parent_cell = parent.readCell(parent_cell_index) catch |err| return mapRedistributeNodeError(err);
    const right_next_page_id = right.nextLeafPageId();

    node.rebuildLeafPage(
        left.page,
        records[0..split],
        values[0..values_len],
        parent.page.id,
        right.page.id,
    ) catch |err| return mapRedistributeNodeError(err);
    node.rebuildLeafPage(
        right.page,
        records[split..record_count],
        values[0..values_len],
        parent.page.id,
        right_next_page_id,
    ) catch |err| return mapRedistributeNodeError(err);
    var updated_parent = parent;
    updated_parent.writeCell(parent_cell_index, .{
        .separator_key = separator,
        .child_page_id = parent_cell.child_page_id,
    }) catch |err| return mapRedistributeNodeError(err);
}

fn redistributeInternalPages(
    tree: *BPlusTree,
    left: node.InternalNode,
    right: node.InternalNode,
    parent: node.InternalNode,
    parent_cell_index: usize,
) RedistributeError!void {
    const left_count = left.cellCount() catch |err| return mapRedistributeNodeError(err);
    const right_count = right.cellCount() catch |err| return mapRedistributeNodeError(err);
    const total_count = @as(usize, left_count) + 1 + right_count;
    if (total_count < 2) return;

    var separators: [node.internal_layout.max_cells * 2 + 1]u64 = undefined;
    var children: [node.internal_layout.max_cells * 2 + 2]u32 = undefined;
    var separator_count: usize = 0;
    var child_count: usize = 1;
    children[0] = left.firstChildPageId();
    for (0..left_count) |index| {
        const cell = left.readCell(index) catch |err| return mapRedistributeNodeError(err);
        separators[separator_count] = cell.separator_key;
        children[child_count] = cell.child_page_id;
        separator_count += 1;
        child_count += 1;
    }
    const parent_cell = parent.readCell(parent_cell_index) catch |err| return mapRedistributeNodeError(err);
    separators[separator_count] = parent_cell.separator_key;
    children[child_count] = right.firstChildPageId();
    separator_count += 1;
    child_count += 1;
    for (0..right_count) |index| {
        const cell = right.readCell(index) catch |err| return mapRedistributeNodeError(err);
        separators[separator_count] = cell.separator_key;
        children[child_count] = cell.child_page_id;
        separator_count += 1;
        child_count += 1;
    }

    const split_index = separator_count / 2;
    const promoted_separator = separators[split_index];
    node.rebuildInternalPage(
        left.page,
        parent.page.id,
        children[0],
        separators[0..split_index],
        children[0 .. split_index + 1],
    ) catch |err| return mapRedistributeNodeError(err);
    node.rebuildInternalPage(
        right.page,
        parent.page.id,
        children[split_index + 1],
        separators[split_index + 1 .. separator_count],
        children[split_index + 1 .. child_count],
    ) catch |err| return mapRedistributeNodeError(err);

    for (children[0 .. split_index + 1]) |child_page_id| {
        const child_page = tree.pager.getPage(child_page_id) catch return error.Storage;
        var child_node = node.Node.open(child_page) catch |err| return mapRedistributeNodeError(err);
        child_node.setParentPageId(left.page.id);
    }
    for (children[split_index + 1 .. child_count]) |child_page_id| {
        const child_page = tree.pager.getPage(child_page_id) catch return error.Storage;
        var child_node = node.Node.open(child_page) catch |err| return mapRedistributeNodeError(err);
        child_node.setParentPageId(right.page.id);
    }

    var updated_parent = parent;
    updated_parent.writeCell(parent_cell_index, .{
        .separator_key = promoted_separator,
        .child_page_id = right.page.id,
    }) catch |err| return mapRedistributeNodeError(err);
}

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
