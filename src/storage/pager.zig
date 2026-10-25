const std = @import("std");

pub const page_size = 4096;

/// 内存中的页面；这些控制字段不会写入数据库文件。
pub const Page = struct {
    id: u32,
    dirty: bool = false,
    data: [page_size]u8,
};

/// 按固定偏移读写页面，并缓存已访问的页面。
pub const Pager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    cache: std.AutoHashMap(u32, *Page),

    /// 打开或创建数据库文件，不截断已有数据。
    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Pager {
        const file = try dir.createFile(io, path, .{ .read = true, .truncate = false });
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .cache = .init(allocator),
        };
    }

    /// 取缓存页；首次访问时从文件读取，不足一页的部分补零。
    pub fn getPage(self: *Pager, id: u32) !*Page {
        if (self.cache.get(id)) |page| return page;

        const page = try self.allocator.create(Page);
        errdefer self.allocator.destroy(page);

        page.id = id;
        page.dirty = false;
        @memset(&page.data, 0);

        const offset = @as(u64, id) * page_size;
        const bytes_read = try self.file.readPositionalAll(self.io, &page.data, offset);
        if (bytes_read < page_size) {
            @memset(page.data[bytes_read..], 0);
        }

        try self.cache.put(id, page);
        return page;
    }

    /// 在文件和缓存页面之后分配一个新的零填充页面。
    pub fn allocatePage(self: *Pager) !*Page {
        const file_length = try self.file.length(self.io);
        var next_id = file_length / page_size;
        if (file_length % page_size != 0) next_id += 1;

        var iterator = self.cache.keyIterator();
        while (iterator.next()) |cached_id| {
            next_id = @max(next_id, @as(u64, cached_id.*) + 1);
        }
        if (next_id > std.math.maxInt(u32)) return error.PageIdExhausted;

        const page = try self.allocator.create(Page);
        errdefer self.allocator.destroy(page);
        page.* = .{
            .id = @intCast(next_id),
            .dirty = true,
            .data = undefined,
        };
        @memset(&page.data, 0);
        try self.cache.put(page.id, page);
        return page;
    }

    /// 将指定脏页写回文件，只写页面数据，不写 id 或 dirty。
    pub fn flushPage(self: *Pager, id: u32) !void {
        const page = self.cache.get(id) orelse return error.PageNotCached;
        if (!page.dirty) return;

        const offset = @as(u64, id) * page_size;
        try self.file.writePositionalAll(self.io, &page.data, offset);
        page.dirty = false;
    }

    /// 刷新所有脏页并关闭文件，释放缓存。
    pub fn close(self: *Pager) !void {
        var flush_error: ?anyerror = null;
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.flushPage(entry.key_ptr.*) catch |err| {
                if (flush_error == null) flush_error = err;
            };
        }

        var pages = self.cache.valueIterator();
        while (pages.next()) |page| self.allocator.destroy(page.*);
        self.cache.deinit();
        self.file.close(self.io);
        if (flush_error) |err| return err;
    }
};
