const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");
const color = @import("color.zig");
const date = @import("date.zig");
const help = @import("help.zig");
const tui = @import("tui.zig");

const windows = std.os.windows;

const Allocator = std.mem.Allocator;
const LocalDate = date.LocalDate;

fn lowerBound(
    comptime T: type,
    key: anytype,
    items: []const T,
    context: anytype,
    comptime lessThan: *const fn (context: @TypeOf(context), key: @TypeOf(key), lhs: T) bool,
) usize {
    var left: usize = 0;
    var right: usize = items.len;
    var mid: usize = undefined;
    while (left < right) {
        mid = left + (right - left) / 2;
        if (lessThan(context, key, items[mid])) {
            right = mid;
        } else {
            left = mid + 1;
        }
    }
    return left;
}

fn panic() noreturn {
    @panic("fatal error");
}

pub const Kind = enum(u8) {
    daily,
    weekly,
};

pub const ChainMeta = extern struct {
    id_counter: u16,
    len: u16,
    _padding: u32 = 0,
};

pub const tag_name_max_len = 15;
pub const Tag = extern struct {
    header: packed struct {
        id: u3,
        len: u5,
    },
    name: [tag_name_max_len]u8,

    const Self = @This();

    pub fn getName(self: *const Self) []const u8 {
        return self.name[0..self.header.len];
    }
};

pub const ACTIVE: i64 = 0;
pub const chain_name_max_len = 128;
pub const max_tags = 4;
pub const Chain = extern struct {
    name: [chain_name_max_len]u8,
    created: i64,
    id: u16,
    name_len: u16,
    kind: Kind,
    color: color.Rgb,
    min_days: u8, // `0` means N/A
    n_tags: u8,
    tags: [max_tags]Tag,
    stopped: i64,
    _padding: [30]u8 = std.mem.zeroes([30]u8),

    const Self = @This();

    pub fn isActive(self: *const Self) bool {
        return self.stopped == ACTIVE;
    }

    pub fn getTags(self: *const Self) []const Tag {
        return self.tags[0..self.n_tags];
    }

    pub fn maxTagsId(self: *const Self) u8 {
        if (self.n_tags == 0)
            return 0;

        var i: usize = 0;
        var tag_id: u8 = 0;
        while (i < self.n_tags) : (i += 1) {
            tag_id = @max(tag_id, self.tags[i].header.id);
        }
        return tag_id;
    }

    // TODO: handle more than the first 3 tags
    pub fn tagColor(self: *const Self, tags: u8) color.Rgb {
        // TODO: distinct color for tag #4
        if (@popCount(tags) > 3 or ((tags >> 3) & 1) == 1)
            return color.white;

        const f = 28;
        const m: u8 = f *% (5 * (tags & 0x01) + 3 * ((tags >> 1) & 0x01) + ((tags >> 2) & 0x01));
        return .{
            .r = self.color.r +% m,
            .g = self.color.g +% m,
            .b = self.color.b +% m,
        };
    }

    pub fn tagsFromNames(self: *const Self, names_it: *std.mem.SplitIterator(u8, .sequence)) u8 {
        var link_tags: u8 = 0;
        const tags = self.tags[0..self.n_tags];
        while (names_it.next()) |name| {
            for (tags) |tag| {
                if (std.mem.eql(u8, name, tag.getName())) {
                    link_tags ^= (@as(u5, 1) << (tag.header.id - 1));
                    break;
                }
            } else {
                var buf = std.mem.zeroes([max_tags * tag_name_max_len + 8]u8); // +8 for ", "
                var fba = std.io.fixedBufferStream(&buf);
                var w = fba.writer();
                for (tags, 0..) |tag, i| {
                    w.writeAll(tag.getName()) catch unreachable;
                    if (i < tags.len - 1)
                        w.writeAll(", ") catch unreachable;
                }
                printAndExit("Chain '{d}' has no tag '{s}', available tags: [{s}]\n", .{ self.id, name, fba.getWritten() });
            }
        }
        return link_tags;
    }
};

comptime {
    std.debug.assert(@sizeOf(ChainMeta) == 8);
    std.debug.assert(@sizeOf(Chain) == 256);
}

const ChainDb = struct {
    allocator: Allocator,
    file: std.fs.File,
    show: Show,
    meta: ChainMeta = undefined,
    chains: std.ArrayList(Chain) = undefined,
    filtered_chains: std.ArrayList(*Chain) = undefined,
    materialized: bool = false,

    const Self = @This();

    fn materialize(self: *Self) !void {
        std.debug.assert(!self.materialized);
        try self.file.seekTo(0);
        var r = self.file.reader();
        const stat = try self.file.stat();
        // Pre-allocate space for one additional chain
        var bytes = try self.allocator.alloc(u8, stat.size + @sizeOf(Chain));
        _ = try r.readAll(bytes);

        self.meta = @bitCast(bytes[0..@sizeOf(ChainMeta)].*);
        const chain_bytes: [*]Chain = @ptrCast(@alignCast(bytes[@sizeOf(ChainMeta)..]));
        self.chains = std.ArrayList(Chain).fromOwnedSlice(self.allocator, chain_bytes[0..self.meta.len]);
        self.chains.capacity = self.meta.len + 1;
        self.filtered_chains = try std.ArrayList(*Chain).initCapacity(self.allocator, self.meta.len + 1);
        self.refilter();

        self.materialized = true;
    }

    fn refilter(self: *Self) void {
        self.filtered_chains.clearRetainingCapacity();
        for (self.chains.items) |*chain| {
            const include = (self.show == .all) or
                (self.show == .stopped and !chain.isActive()) or
                (self.show == .active and chain.isActive());
            if (include)
                self.filtered_chains.appendAssumeCapacity(chain);
        }
    }

    fn persist(self: *Self) !void {
        std.debug.assert(self.materialized);

        try self.file.seekTo(0);
        var w = self.file.writer();
        try w.writeStruct(self.meta);
        try w.writeAll(std.mem.sliceAsBytes(self.chains.items));
        try self.file.setEndPos(@sizeOf(ChainMeta) + self.chains.items.len * @sizeOf(Chain));
    }

    fn getByIndex(self: *Self, index: u16) *Chain {
        std.debug.assert(self.materialized);
        return self.filtered_chains.items[index - 1];
    }

    fn indexToId(self: *const Self, index: usize)?u16 {
        std.debug.assert(self.materialized);
        if (index == 0 or index > self.filtered_chains.items.len) return null;
        return self.filtered_chains.items[index - 1].id;
    }

    fn getChains(self: Self) []*Chain {
        std.debug.assert(self.materialized);
        return self.filtered_chains.items;
    }

    fn add(self: *Self, chain: *Chain) !void {
        std.debug.assert(self.materialized);
        self.meta.len += 1;
        self.meta.id_counter += 1;
        self.chains.appendAssumeCapacity(chain.*);
        self.filtered_chains.appendAssumeCapacity(&self.chains.items[self.chains.items.len - 1]);
    }

    fn delete(self: *Self, index: u16) void {
        std.debug.assert(self.materialized);
        const removed = self.filtered_chains.orderedRemove(index - 1);
        for (self.chains.items, 0..) |*chain, i| {
            if (chain.id == removed.id) {
                _ = self.chains.orderedRemove(i);
                break;
            }
        } else unreachable;
        self.meta.len -= 1;
        self.refilter();
    }
};

pub const LinkMeta = extern struct {
    _padding1: u16 = 0,
    len: u16,
    _padding2: u32 = 0,
};

pub const Link = extern struct {
    _padding1: u16 = 0,
    chain_id: u16,
    tags: u8, // bitmap
    _padding2: u8 = 0,
    _padding3: u16 = 0,
    timestamp: i64,

    const Self = @This();

    pub fn localAtStartOfDay(self: *const Self) i64 {
        return date.localAtStartOfDay(self.timestamp);
    }

    pub fn local(self: *const Self) i64 {
        return date.utcToLocal(self.timestamp);
    }

    pub fn toLocalDate(self: *const Self) LocalDate {
        return LocalDate.epochToLocal(self.timestamp);
    }
};

comptime {
    std.debug.assert(@sizeOf(LinkMeta) == 8);
    std.debug.assert(@sizeOf(Link) == 16);
}

const LinkDb = struct {
    allocator: Allocator,
    file: std.fs.File,
    meta: LinkMeta = undefined,
    links: std.ArrayList(Link) = undefined,
    materialized: bool = false,
    first_write_index: usize = NO_WRITE,

    const NO_WRITE = std.math.maxInt(usize);
    const Self = @This();

    fn materialize(self: *Self, n_chains: usize) !void {
        std.debug.assert(!self.materialized);

        const stat = try self.file.stat();
        var bytes = try self.allocator.alloc(u8, stat.size + n_chains * @sizeOf(Link));

        try self.file.seekTo(0);
        var r = self.file.reader();
        _ = try r.readAll(bytes);

        self.meta = @bitCast(bytes[0..@sizeOf(LinkMeta)].*);
        var link_bytes: [*]Link = @ptrCast(@alignCast(bytes[@sizeOf(LinkMeta)..]));
        const n_links = @divExact(stat.size - @sizeOf(LinkMeta), @sizeOf(Link));
        self.links = std.ArrayList(Link).fromOwnedSlice(self.allocator, link_bytes[0..n_links]);
        self.links.capacity += n_chains;

        self.materialized = true;
    }

    fn getLinks(self: *Self) []Link {
        std.debug.assert(self.materialized);
        return self.links.items;
    }

    fn getAndSortLinks(self: *Self, local_date: ?LocalDate) []Link {
        std.debug.assert(self.materialized);
        const S = struct {
            fn first(_: void, ts: i64, lhs: Link) bool {
                return ts <= lhs.timestamp;
            }
        };
        const i = if (local_date) |d|
            lowerBound(Link, d.prev().toEpoch(), self.links.items, {}, S.first)
        else
            0;
        var links_in_range = self.links.items[i..];
        std.sort.pdq(Link, links_in_range, {}, orderLinks);
        return links_in_range;
    }

    fn getLinksForChain(self: *Self, chain_id: u16, local_date: ?LocalDate) []Link {
        var links = self.getAndSortLinks(local_date);
        const chain_start = LinkDb.chainStartIndex(links, chain_id) orelse return &.{};
        const chain_end = LinkDb.chainEndIndex(links, chain_id).?; // if there's a start there's an end
        return links[chain_start .. chain_end];
    }

    fn getInsertIndex(links: []Link, chain_id: u16, timestamp: i64) struct { index: usize, occupied: bool } {
        const S = struct {
            fn first(_: void, ts: i64, lhs: Link) bool {
                return ts <= lhs.localAtStartOfDay();
            }
        };
        var i = lowerBound(Link, timestamp, links, {}, S.first);
        const day = date.localAtStartOfDay(timestamp);
        std.log.debug("getInsertIndex chain id {d} timestamp {d} -> i {d} len {d}", .{chain_id, timestamp, i, links.len});

        if (i == links.len) {
            while (i > 0) {
                i -= 1;
                const other = links[i];
                if (other.localAtStartOfDay() != day) {
                    break;
                }
            }
        }

        std.log.debug("  i {d} day {d} links len {d}", .{i, day, links.len});
        while (i < links.len) : (i += 1) {
            const link = links[i];
            const link_day = link.localAtStartOfDay();
            std.log.debug("  loop -> i {d} day {d} link day {d}", .{i, day, link_day});
            if (link_day > day) return .{ .index = i, .occupied = false };
            if (link.chain_id == chain_id and link_day == day) {
                return .{ .index = i, .occupied = true };
            }
        }
        return .{ .index = i, .occupied = false };
    }

    fn add(self: *Self, link: Link) !void {
        std.debug.assert(self.materialized);

        const result = LinkDb.getInsertIndex(self.links.items, link.chain_id, link.timestamp);
        if (result.occupied) {
            var w = std.io.getStdOut().writer();
            try w.print("Link already exists on date {s}, skipping\n", .{link.toLocalDate().asString()});
            return;
        }

        self.meta.len += 1;
        const i = result.index;
        self.links.insertAssumeCapacity(i, link);
        if (i < self.first_write_index)
            self.first_write_index = i;
    }

    fn remove(self: *Self, chain_id: u16, day: i64) bool {
        std.debug.assert(self.materialized);
        const result = LinkDb.getInsertIndex(self.links.items, chain_id, day);
        if (!result.occupied) return false;

        self.meta.len -= 1;
        const i = result.index;
        _ = self.links.orderedRemove(i);
        if (i < self.first_write_index)
            self.first_write_index = i;
        return true;
    }

    fn persist(self: *Self) !void {
        std.debug.assert(self.materialized);
        try self.verify();

        if (self.first_write_index == NO_WRITE) return;
        var w = self.file.writer();

        try self.file.seekTo(0);
        try w.writeStruct(self.meta);

        const write_start = @sizeOf(LinkMeta) + self.first_write_index * @sizeOf(Link);
        std.log.debug("LinkDb.persist -> items len {d} meta len {d} fwi {d} write start {d}", .{self.links.items.len, self.meta.len, self.first_write_index, write_start});
        try self.file.seekTo(write_start);
        const link_bytes = std.mem.sliceAsBytes(self.links.items[self.first_write_index..]);
        try w.writeAll(link_bytes);
        try self.file.setEndPos(@sizeOf(LinkMeta) + self.links.items.len * @sizeOf(Link));
    }

    fn chainStartIndex(links: []Link, chain_id: u16) ?usize {
        const S = struct {
            fn first(_: void, cid: u16, lhs: Link) bool {
                return cid <= lhs.chain_id;
            }
        };
        var index = lowerBound(Link, chain_id, links, {}, S.first);
        if (index == links.len) return null;
        return if (links[index].chain_id == chain_id)
            index
        else
            null;
    }

    fn chainEndIndex(links: []Link, chain_id: u16) ?usize {
        const S = struct {
            fn last(_: void, cid: u16, lhs: Link) bool {
                return cid < lhs.chain_id;
            }
        };
        const index = lowerBound(Link, chain_id, links, {}, S.last);
        return if (links[index - 1].chain_id == chain_id)
            index
        else
            null;
    }

    fn verify(self: *Self) !void {
        if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) return;

        std.debug.assert(self.materialized);
        const ChainIdAndDate = struct {
            chain_id: u16,
            timestamp: i64,
        };
        var seen = std.AutoHashMap(ChainIdAndDate, void).init(self.allocator);
        defer seen.deinit();
        var n_links: usize = 0;
        for (self.links.items, 0..) |link, i| {
            const chain_id_and_date = .{
                .chain_id = link.chain_id,
                .timestamp = link.localAtStartOfDay()
            };
            if (seen.contains(chain_id_and_date)) {
                std.log.info("LINK DB INCONSISTENT! Duplicate link i {d} {}", .{i, chain_id_and_date});
                panic();
            }
            try seen.put(chain_id_and_date, {});
            n_links += 1;
        }
        if (n_links != self.meta.len) {
            std.log.info("LINK DB INCONSISTENT! meta len and actual link count differ, meta len {d}, actual len {d}", .{self.meta.len, n_links});
            panic();
        }
    }
};

fn orderLinks(ctx: void, a: Link, b: Link) bool {
    _ = ctx;
    if (a.chain_id == b.chain_id)
        return a.timestamp < b.timestamp;
    return a.chain_id < b.chain_id;
}

fn orderLinksTimestamp(ctx: void, a: Link, b: Link) bool {
    _ = ctx;
    return a.timestamp < b.timestamp;
}

const Stats = struct {
    longest_gap: usize,
    longest_streak: usize,
    times_broken: usize,
    fulfillment: [32]u8,
};

pub fn computeStats(chain: *const Chain, links: []const Link) Stats {
    if (links.len == 0) {
        var stats = Stats{
            .longest_streak = 0,
            .longest_gap = 0,
            .times_broken = 0,
            .fulfillment = std.mem.zeroes([32]u8),
        };
        _ = std.fmt.bufPrint(&stats.fulfillment, "0/0 (100%)", .{}) catch unreachable;
        return stats;
    }
    switch (chain.kind) {
        .daily => {
            var streak: usize = 0;
            var max_streak: usize = 0;
            var max_gap: usize = 0;
            var times_broken: usize = 0;
            var i: usize = 1;
            while (i < links.len) : (i += 1) {
                const prev = links[i - 1].local();
                const curr = links[i].local();
                const days = date.daysBetween(prev, curr);
                if (days > max_gap)
                    max_gap = days;
                if (days == 0) {
                    streak += 1;
                } else {
                    if (streak > 0)
                        times_broken += 1;
                    max_streak = @max(streak, max_streak);
                    streak = 0;
                }
            }

            const first_link_start = links[0].localAtStartOfDay();
            const end = if (chain.isActive())
                date.epochAtStartOfDay(date.epochNowLocal())
            else
                chain.stopped;
            // +2 because we include both the start date and the end date in the count
            const n_days = date.daysBetween(first_link_start, end) + 2;
            const percentage = @as(f32, @floatFromInt(links.len)) / @as(f32, @floatFromInt(n_days)) * 100;
            var fulfillment = std.mem.zeroes([32]u8);
            _ = std.fmt.bufPrint(&fulfillment, "{d}/{d} ({d:.2}%)", .{ links.len, n_days, percentage }) catch unreachable;

            const last_link_at_start_of_day = links[links.len - 1].localAtStartOfDay();
            const days = date.daysBetween(last_link_at_start_of_day, end);
            if (days > max_gap)
                max_gap = days + 1; // +1 since there is no link on `now`
            if (days > 0)
                times_broken += 1;

            return .{
                // +1 because we're counting the number of links, not the days
                // https://en.wikipedia.org/wiki/Off-by-one_error?useskin=vector#Fencepost_error
                // ██━━██━━██ -> 2 links, 3 days
                .longest_streak = @max(streak, max_streak) + 1,
                .longest_gap = max_gap,
                .times_broken = times_broken,
                .fulfillment = fulfillment,
            };
        },
        // TODO: handle chains spanning multiple years
        .weekly => {
            var week_is_linked = std.mem.zeroes([52]u8);
            var min_week: usize = 53;
            var max_week: usize = 0;
            for (links) |link| {
                const week = date.getWeekNumberFromEpoch(link.local());
                week_is_linked[week] += 1;
                min_week = @min(week, min_week);
                max_week = @max(week, max_week);
            }
            var gap: usize = 0;
            var max_gap: usize = 0;
            var streak: usize = 0;
            var max_streak: usize = 0;
            var times_broken: usize = 0;
            var weeks_completed: usize = 0;
            const weeks = week_is_linked[min_week .. max_week + 1];
            for (weeks) |n| {
                if (n < chain.min_days) {
                    gap += 1;
                    if (streak > 0)
                        times_broken += 1;
                    max_streak = @max(streak, max_streak);
                    streak = 0;
                } else {
                    max_gap = @max(gap, max_gap);
                    gap = 0;
                    streak += 1;
                    weeks_completed += 1;
                }
            }

            const percentage = @as(f32, @floatFromInt(weeks_completed)) / @as(f32, @floatFromInt(weeks.len)) * 100;
            var fulfillment = std.mem.zeroes([32]u8);
            _ = std.fmt.bufPrint(&fulfillment, "{d}/{d} ({d:.2}%)", .{ weeks_completed, weeks.len, percentage }) catch unreachable;

            return .{
                .longest_gap = @max(gap, max_gap),
                .longest_streak = @max(streak, max_streak),
                .times_broken = times_broken,
                .fulfillment = fulfillment,
            };
        },
    }
}

pub const Command = enum {
    add,
    delete,
    display,
    @"export",
    help,
    import,
    info, // TODO: better name
    link,
    modify,
    tag,
    unlink,
    version,
};

var scratch = std.mem.zeroes([256]u8);
var err_buf = std.mem.zeroes([13]u8);

fn trunc(str: []const u8) []const u8 {
    if (str.len <= err_buf.len) {
        const n = @min(str.len, err_buf.len);
        std.mem.copy(u8, &err_buf, str[0..n]);
        return err_buf[0..n];
    } else {
        std.mem.copy(u8, &err_buf, str[0..10]);
        std.mem.copy(u8, err_buf[10..err_buf.len], "...");
        return err_buf[0..];
    }
}

pub fn scratchPrint(comptime str: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&scratch, str, args) catch panic();
}


fn formatEnumValuesForPrint(comptime E: type, allocator: Allocator) ![]const u8 {
    var strs: [@typeInfo(E).Enum.fields.len][]const u8 = undefined;
    inline for (comptime std.enums.values(E), 0..) |e, i| {
        strs[i] = @tagName(e);
    }
    const values = try std.mem.join(allocator, ", ", &strs);
    return scratchPrint("[{s}]", .{values});
}

// TODO: can the error message by generated lazily somehow?
fn parseIntOrExit(comptime T: type, str: []const u8, err_msg: []const u8) T {
    return std.fmt.parseInt(T, str, 10) catch |err| {
        var w = std.io.getStdOut().writer();
        w.writeAll(err_msg) catch panic();
        w.writeAll(", ") catch panic();
        w.writeAll(switch (err) {
            error.InvalidCharacter => "expected integer",
            error.Overflow => "integer too large",
        }) catch panic();
        w.writeByte('\n') catch panic();
        std.process.exit(0);
    };
}

fn printHelpAndExit(message: ?[]const u8) noreturn {
    var stdout = std.io.getStdOut();
    var w = stdout.writer();
    if (message) |m| {
        w.writeAll(m) catch panic();
    }
    w.writeAll(help.help_str) catch panic();
    std.process.exit(0);
}

fn parseCommandOrExit(str: []const u8) Command {
    return std.meta.stringToEnum(Command, str) orelse {
        const msg = scratchPrint("Invalid command '{s}'\n", .{trunc(str)});
        printHelpAndExit(msg);
    };
}

fn checkNumberOfArgs(allocator: Allocator, args: []const []const u8, max: usize) !void {
    if (args.len == 0) return;

    // The first element of `args` is the command which doesn't count
    const len = args.len - 1;
    if (len > max) {
        const extra_args = try std.mem.join(allocator, ", ", args[max + 1..]);
        printAndExit("Expected at most {} arguments, got {}, extra: [{s}]\n", .{max, len, extra_args});
    }
}

fn optionalArg(args: []const []const u8, index: usize) ?[]const u8 {
    return if (args.len > index) args[index] else null;
}

fn expectArg(args: []const []const u8, index: usize, comptime name: []const u8) []const u8 {
    if (optionalArg(args, index)) |a| {
        return a;
    } else {
        const msg = scratchPrint("Expected '{s}' argument\n", .{name});
        printHelpAndExit(msg);
    }
}

fn printAndExit(comptime fmt: []const u8, args: anytype) noreturn {
    var w = std.io.getStdOut().writer();
    w.print(fmt, args) catch panic();
    std.process.exit(0);
}

const IndexAndId = struct { index: u16, id: u16 };

fn parseAndValidateChainIndex(chain_db: *ChainDb, str: []const u8) !IndexAndId {
    const index = parseChainIndex(str);
    const cid = validateChainIndex(chain_db, index);
    return .{ .id = cid, .index = index };
}

fn parseChainIndex(str: []const u8) u16 {
    const err_msg = scratchPrint("Invalid chain id '{s}'", .{trunc(str)});
    const index = parseIntOrExit(u16, str, err_msg);
    if (index == 0)
        printAndExit("Invalid chain index '{d}' (chain index must be > 0)\n", .{index});
    return index;
}

fn validateChainIndex(chain_db: *ChainDb, index: u16) u16 {
    return chain_db.indexToId(index) orelse printAndExit("No chain found with index '{d}'\n", .{index});
}

fn validateNameLen(name: []const u8) void {
    if (name.len > chain_name_max_len) {
        printAndExit("Invalid name '{s}...', name must be < {d} characters\n", .{ name[0..10], chain_name_max_len });
    }
}

fn validateTagNameLen(name: []const u8) void {
    if (name.len > tag_name_max_len) {
        printAndExit("Invalid tag name '{s}...', name must be < {d} characters\n", .{ name[0..10], tag_name_max_len });
    }
}

fn parseMinDaysOrExit(str: []const u8) u8 {
    const err_msg = scratchPrint("Invalid min_days '{s}'", .{trunc(str)});
    const min_days = parseIntOrExit(u8, str, err_msg);
    if (min_days <= 0 or min_days > 7) {
        printAndExit("Invalid min_days '{d}', min: 0, max: 7\n", .{min_days});
    }
    return min_days;
}

fn parseLocalDateOrExit(str: []const u8, label: []const u8) LocalDate {
    const S = struct {
        fn printDateHelpAndExit(str_: []const u8, label_: []const u8, msg: []const u8) noreturn {
            printAndExit("Invalid {s} date '{s}', {s}\n\nValid date formats:\n{s}\n", .{label_, str_, msg, help.dates_help});
        }
    };

    if (std.mem.eql(u8, str, "y") or std.mem.eql(u8, str, "yesterday")) {
        return LocalDate.fromEpoch(date.epochNowLocal() - date.secs_per_day);
    }

    if (std.mem.eql(u8, str, "t") or std.mem.eql(u8, str, "today")) {
        return LocalDate.fromEpoch(date.epochNowLocal());
    }

    // Weekdays: mon/monday, tue/tuesday etc.
    if (str.len >= 3) {
        if (std.meta.stringToEnum(date.Weekday, str[0..3])) |target_day| {

            const name = date.weekday_names[@intFromEnum(target_day)];
            if (str.len > name.len or !std.mem.eql(u8, str, name[0..str.len]))
                S.printDateHelpAndExit(str, label, "not a weekday");

            const now = date.epochNowLocal();
            const today = date.getWeekdayFromEpoch(now);
            const diff = @as(i64, @intCast(@intFromEnum(today))) - @as(i64, @intCast(@intFromEnum(target_day)));
            const n_days = (diff + @as(i64, if (diff >= 0) 0 else 7));
            const target_day_epoch = now - n_days * date.secs_per_day;
            return LocalDate.fromEpoch(target_day_epoch);
        }
    }

    // Ordinals: 1st, 2nd, 3rd...
    if (
         std.mem.endsWith(u8, str, "st") or
         std.mem.endsWith(u8, str, "nd") or
         std.mem.endsWith(u8, str, "th") or
         std.mem.endsWith(u8, str, "rd")
    ) {
        var today = LocalDate.fromEpoch(date.epochNowLocal());

        // For errors, TODO make lazy
        const last_month = today.oneMonthAgo();
        const last_month_name = date.monthName(last_month.month);
        const last_month_n_days = date.getDaysInMonth(last_month.year, last_month.month);
        const out_of_range_msg = scratchPrint("out of range for {s} which has {d} days", .{last_month_name, last_month_n_days});

        const day_number_signed = std.fmt.parseInt(i64, str[0..str.len - 2], 10) catch |err| switch (err) {
            error.Overflow => S.printDateHelpAndExit(str, label, out_of_range_msg),
            else => S.printDateHelpAndExit(str, label, "does not match any format"),
        };
        if (day_number_signed < 1)
            S.printDateHelpAndExit(str, label, "does not match any format");
        if (day_number_signed > 31)
            S.printDateHelpAndExit(str, label, out_of_range_msg);
        const day_number: u8 = @intCast(day_number_signed);
        return if (day_number <= today.day)
            LocalDate.init(today.year, today.month, day_number) catch unreachable
        else
            today.prevMonthAtDay(day_number) catch |err| switch (err) {
                error.DayOutOfRange => S.printDateHelpAndExit(str, label, out_of_range_msg),
                else => unreachable,
            };
    }

    // Offset: `n` days ago
    if (std.ascii.isDigit(str[0]) and str.len <= 2) {
        const offset = std.fmt.parseInt(i64, str, 10) catch S.printDateHelpAndExit(str, label, "does not match any format");
        var epoch = date.epochNowLocal() - offset * date.secs_per_day;
        return LocalDate.fromEpoch(epoch);
    }

    return LocalDate.parse(str) catch |err| {
        const msg = switch (err) {
            error.BadFormat => "does not match any format",
            error.InvalidCharacter => "does not match any format",
            error.YearBefore2022 => "year before 2022 not supported",
            error.MonthOutOfRange => scratchPrint("month '{s}' out of range", .{str[4..6]}),
            error.DayOutOfRange => scratchPrint("day '{s}' out of range", .{str[6..8]}),
        };
        S.printDateHelpAndExit(str, label, msg);
    };
}

const Range = struct {
    start: LocalDate,
    end: LocalDate,
};

fn parseRangeOrExit(start_date_str: ?[]const u8, end_date_str: ?[]const u8) Range {
    const end_timestamp = if (end_date_str) |str|
        parseLocalDateOrExit(str, "end").toEpoch()
    else
        date.epochNow();

    const start_timestamp = if (start_date_str) |str|
        parseLocalDateOrExit(str, "start").toEpoch()
    else
        end_timestamp - 30 * date.secs_per_day;

    if (start_timestamp >= end_timestamp) {
        printAndExit("Invalid date range: start date >= end date\n", .{});
    }

    const n_days = @divFloor(end_timestamp - start_timestamp, date.secs_per_day);
    if (n_days > 50) {
        printAndExit("Invalid date range: range must be less than 50 days, got {d}\n", .{n_days});
    }

    return .{
        .start = LocalDate.epochToLocal(start_timestamp),
        .end = LocalDate.epochToLocal(end_timestamp),
    };
}

fn parseChainIndexes(allocator: Allocator, chain_db: *ChainDb, str: []const u8) ![]IndexAndId {
    var cids = std.ArrayList(IndexAndId).init(allocator);
    var seen = std.AutoHashMap(u16, void).init(allocator);
    defer seen.deinit();

    var index_iterator = std.mem.split(u8, str, ",");
    while (index_iterator.next()) |index| {
        // Range "<start index>-<end index>"
        if (std.mem.indexOf(u8, index, "-")) |dash_index| {
            const start = parseChainIndex(index[0..dash_index]);
            const end = parseChainIndex(index[dash_index + 1 ..]);
            if (start >= end) {
                printAndExit("Invalid chain index range: start {d} >= end {d}\n", .{ start, end });
            }
            var i: u16 = start;
            while (i <= end) : (i += 1) {
                if (seen.contains(i)) continue;
                const cid = validateChainIndex(chain_db, i);
                try cids.append(.{ .index = i, .id = cid });
                try seen.put(i, {});
            }
            // Single "<index>"
        } else {
            const cid_and_index = try parseAndValidateChainIndex(chain_db, index);
            if (!seen.contains(cid_and_index.index)) {
                try cids.append(cid_and_index);
                try seen.put(cid_and_index.index, {});
            }
        }
    }
    return cids.toOwnedSlice();
}

const Files = struct {
    chains: std.fs.File,
    links: std.fs.File,

    fn close(self: @This()) void {
        self.chains.close();
        self.links.close();
    }
};

fn getConfigDirPath() ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const app_data_local = std.os.windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}");
            var dir_path_ptr: [*:0]u16 = undefined;
            const hresult = std.os.windows.shell32.SHGetKnownFolderPath(
                &app_data_local,
                std.os.windows.KF_FLAG_CREATE,
                null,
                &dir_path_ptr,
            );
            switch (hresult) {
                std.os.windows.S_OK => {
                    defer std.os.windows.ole32.CoTaskMemFree(@ptrCast(dir_path_ptr));
                    return std.unicode.utf16leToUtf8Alloc(std.heap.c_allocator, std.mem.span(dir_path_ptr));
                },
                else => printAndExit("Could not open AppData/Local directory\n", .{}),
            }
        },
        else => return std.os.getenv("HOME") orelse printAndExit("Could not find 'HOME' directory\n", .{}),
    }
}

fn openOrCreateDbFiles(data_dir_path: ?[]const u8, suffix: []const u8) !Files {
    var sow = std.io.getStdOut().writer();

    var habu: struct { dir: std.fs.Dir, path: []const u8} = if (data_dir_path) |ddp| blk: {
        if (!std.fs.path.isAbsolute(ddp))
            printAndExit("Expected absolute path, got '{s}'\n", .{ddp});
        var data_dir = std.fs.openDirAbsolute(ddp, .{}) catch |err| switch (err) {
            error.FileNotFound => printAndExit("Could not open data dir at '{s}'\n", .{ddp}),
            else => return err,
        };
        break :blk .{ .dir = data_dir, .path = ddp };
    } else blk: {
        const config_dir_path = try getConfigDirPath();
        var config_dir = try std.fs.openDirAbsolute(config_dir_path, .{});
        defer config_dir.close();

        const habu_dir_path = switch (builtin.os.tag) {
            .windows => "habu",
            else => ".habu",
        };
        var habu_dir = config_dir.openDir(habu_dir_path, .{}) catch |err| switch (err) {
            error.FileNotFound => dir: {
                const dir = try config_dir.makeOpenPath(habu_dir_path, .{});
                try sow.print("Created data dir at {s}/{s} (to remove habu, delete this directory)\n", .{config_dir_path, habu_dir_path});
                break :dir dir;
            },
            else => return err,
        };
        break :blk .{ .dir = habu_dir, .path = habu_dir_path };
    };
    var habu_dir = habu.dir;
    const habu_dir_path = habu.path;
    defer habu_dir.close();

    const chains_filename = scratchPrint("chains.bin{s}", .{suffix});
    var chains = try habu_dir.createFile(chains_filename, .{ .read = true, .truncate = false, .lock = .exclusive });
    {
        const stat = try chains.stat();
        if (stat.size == 0) {
            const meta = ChainMeta{ .id_counter = 0, .len = 0 };
            var w = chains.writer();
            try w.writeStruct(meta);
            std.log.debug("Wrote {s} to {s}", .{chains_filename, habu_dir_path});
        }
    }

    const links_filename = scratchPrint("links.bin{s}", .{suffix});
    var links = try habu_dir.createFile(links_filename, .{ .read = true, .truncate = false, .lock = .exclusive });
    {
        const stat = try links.stat();
        if (stat.size == 0) {
            const meta = LinkMeta{ .len = 0 };
            var w = links.writer();
            try w.writeStruct(meta);
            std.log.debug("Wrote {s} to {s}", .{links_filename, habu_dir_path});
        }
    }

    return .{
        .chains = chains,
        .links = links,
    };
}

const Show = enum {
    all,
    stopped,
    active,
};

const Options = struct {
    data_dir: ?[]const u8 = null,
    show: Show = .active,
};

fn parseOptionsAndPrepareArgs(allocator: Allocator, args: [][]const u8, options: *Options) ![][]const u8 {
    var args_array = std.ArrayList([]const u8).fromOwnedSlice(allocator, args);
    var i: usize = 0;
    while (i < args_array.items.len) {
        var hit = false;
        const arg = args_array.items[i];
        if (std.mem.eql(u8, arg, "--data-dir")) {
            if (i == args_array.items.len - 1) printAndExit("Missing path argument to --data-dir\n", .{});
            _ = args_array.orderedRemove(i);
            options.data_dir = args_array.orderedRemove(i);
            hit = true;
        } else if (std.mem.eql(u8, arg, "--show")) {
            if (i == args_array.items.len - 1) printAndExit("Missing argument to --show, expected one of {s}\n", .{try formatEnumValuesForPrint(Show, allocator)});
            _ = args_array.orderedRemove(i);
            const show_str = args_array.orderedRemove(i);
            options.show = std.meta.stringToEnum(Show, show_str) orelse
                printAndExit("Invalid argument to --show, expected one of {s}, got {s}\n", .{try formatEnumValuesForPrint(Show, allocator), show_str});
            hit = true;
        }
        if (!hit)
            i += 1;
    }
    // Remove path to binary from args to make args zero-indexed.
    _ = args_array.orderedRemove(0);
    return args_array.toOwnedSlice();
}

pub fn main() !void {
    const old_code_page = if (builtin.os.tag == .windows) std.os.windows.kernel32.GetConsoleOutputCP() else undefined;
    if (builtin.os.tag == .windows)
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);

    var c_allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(c_allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    const start = try std.time.Instant.now();
    defer {
        const end = std.time.Instant.now() catch unreachable;
        std.log.debug("finished in {}", .{std.fmt.fmtDuration(end.since(start))});
    }
    try date.initTimetype(allocator);

    var stdout_writer = std.io.getStdOut().writer();
    var buffered_writer = std.io.bufferedWriter(stdout_writer);
    var sow = buffered_writer.writer();
    defer buffered_writer.flush() catch panic();

    var args: [][]const u8 = try std.process.argsAlloc(allocator);
    var options: Options = .{};
    args = try parseOptionsAndPrepareArgs(allocator, args, &options);

    var files = try openOrCreateDbFiles(options.data_dir, "");
    defer files.close();
    var chain_db = ChainDb{ .allocator = allocator, .file = files.chains, .show = options.show };
    var link_db = LinkDb{ .allocator = allocator, .file = files.links };

    const command = if (optionalArg(args, 0)) |command_str|
        parseCommandOrExit(command_str)
    else
        .display;

    switch (command) {
        .add => {
            try checkNumberOfArgs(allocator, args, 3);
            const name = expectArg(args, 1, "name");
            validateNameLen(name);

            const kind_str = expectArg(args, 2, "kind");
            const kind = std.meta.stringToEnum(Kind, kind_str) orelse
                printAndExit("Invalid kind '{s}', expected one of {s}\n", .{trunc(kind_str), try formatEnumValuesForPrint(Kind, allocator)});

            const min_days = blk: {
                if (kind == .weekly) {
                    const min_days_str = expectArg(args, 3, "min_days");
                    break :blk parseMinDaysOrExit(min_days_str);
                } else {
                    break :blk 0;
                }
            };

            try chain_db.materialize();

            var chain = Chain{
                .id = chain_db.meta.id_counter,
                .name = std.mem.zeroes([128]u8),
                .name_len = @as(u16, @intCast(name.len)),
                .kind = kind,
                .color = color.colors[chain_db.meta.len % color.colors.len],
                .min_days = min_days,
                .created = date.epochNow(),
                .stopped = ACTIVE,
                .n_tags = 0,
                .tags = std.mem.zeroes([max_tags]Tag),
            };
            std.mem.copy(u8, &chain.name, name);

            try chain_db.add(&chain);
            try chain_db.persist();

            try link_db.materialize(chain_db.meta.len);
            const chains = chain_db.getChains();
            const range = parseRangeOrExit(null, null);
            const links = link_db.getAndSortLinks(range.start);
            try tui.drawChains(chains, links, range.start, range.end);

        },
        .info => {
            try checkNumberOfArgs(allocator, args, 2);
            try chain_db.materialize();
            const index_str = expectArg(args, 1, "index");
            const cid_and_index = try parseAndValidateChainIndex(&chain_db, index_str);
            var chain = chain_db.getByIndex(cid_and_index.index);

            try link_db.materialize(chain_db.meta.len);

            const date_arg = optionalArg(args, 2);
            // Show link info
            if (date_arg) |str| {
                const link_date = parseLocalDateOrExit(str, "link");
                const chain_links = link_db.getLinksForChain(cid_and_index.id, link_date.prev());
                const result = LinkDb.getInsertIndex(chain_links, cid_and_index.id, link_date.toEpoch());
                if (!result.occupied)
                    printAndExit("No link found at date '{s}' for chain {d}\n", .{trunc(str), cid_and_index.index});

                try tui.drawLinkDetails(chain, chain_links, result.index);
            } else { // Show chain info
                const range = if (chain.isActive())
                    parseRangeOrExit(null, null)
                else Range{
                    .start = LocalDate.fromEpoch(chain.stopped - 30 * date.secs_per_day),
                    .end = LocalDate.fromEpoch(chain.stopped),
                };
                const chain_links = link_db.getLinksForChain(cid_and_index.id, null);
                try tui.drawChainDetails(chain, chain_links, range.start, range.end);
            }
        },
        .@"export" => {
            try checkNumberOfArgs(allocator, args, 0);
            try chain_db.materialize();
            const chains = chain_db.getChains();

            try link_db.materialize(chain_db.meta.len);
            var links = link_db.getAndSortLinks(null);

            var jw = std.json.writeStreamMaxDepth(sow, .{ .whitespace = .indent_4 }, 8);

            try jw.beginArray();
            for (chains) |chain| {
                try jw.beginObject();

                try jw.objectField("id");
                try jw.write(chain.id);

                try jw.objectField("name");
                try jw.write(chain.name[0..chain.name_len]);

                try jw.objectField("created");
                try jw.write(chain.created);

                try jw.objectField("stopped");
                try jw.write(chain.stopped);

                try jw.objectField("kind");
                try jw.write(@tagName(chain.kind));

                try jw.objectField("color");
                try jw.write(&chain.color.toHex());

                try jw.objectField("min_days");
                try jw.write(chain.min_days);

                if (chain.n_tags > 0) {
                    try jw.objectField("tags");
                    try jw.beginArray();
                    var i: usize = 0;
                    while (i < chain.n_tags) : (i += 1) {
                        const tag = chain.tags[i];
                        try jw.beginObject();
                        try jw.objectField("id");
                        try jw.write(tag.header.id);
                        try jw.objectField("name");
                        try jw.write(tag.getName());
                        try jw.endObject();
                    }
                    try jw.endArray();
                }

                {
                    try jw.objectField("links");
                    try jw.beginArray();
                    var i: usize = 0;
                    while (i < links.len and links[i].chain_id != chain.id) : (i += 1) {}
                    while (i < links.len) : (i += 1) {
                        const link = links[i];
                        if (link.chain_id != chain.id)
                            break;
                        try jw.beginObject();
                        try jw.objectField("timestamp");
                        try jw.write(link.timestamp);
                        try jw.endObject();
                    }
                    try jw.endArray();
                }

                try jw.endObject();
            }
            try jw.endArray();
            try sow.writeByte('\n');
        },
        .import => {
            try checkNumberOfArgs(allocator, args, 0);
            var r = std.io.getStdIn().reader();
            const bytes = try r.readAllAlloc(allocator, 200_000);
            var root = (try std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{}));

            var all_chains = std.ArrayList(Chain).init(allocator);
            var all_links = std.ArrayList(Link).init(allocator);

            var chain_meta = ChainMeta{
                .id_counter = 0,
                .len = 0,
            };
            var link_meta = LinkMeta{
                .len = 0,
            };
            for (root.array.items) |v| {
                const chain_object = v.object;
                const name = chain_object.get("name").?.string;
                var name_buf = std.mem.zeroes([chain_name_max_len]u8);
                std.mem.copy(u8, &name_buf, name);

                const n_tags: u8 = if (chain_object.get("n_tags")) |n| @intCast(n.integer) else 0;
                var tags = std.mem.zeroes([4]Tag);
                if (n_tags > 0) {
                    const tag_objects = chain_object.get("tags").?.array;
                    for (tag_objects.items, 0..) |value, i| {
                        const tag_object = value.object;
                        tags[i] = Tag{
                            .header = .{
                                .id = @as(u3, @intCast(tag_object.get("id").?.integer)),
                                .len = undefined,
                            },
                            .name = undefined,
                        };
                        const tag_name = tag_object.get("name").?.string;
                        std.mem.copy(u8, &tags[i].name, tag_name);
                        tags[i].header.len = @as(u5, @intCast(tag_name.len));
                    }
                }

                const chain = Chain{
                    .name = name_buf,
                    .created = @as(i64, @intCast(chain_object.get("created").?.integer)),
                    .stopped = @as(i64, @intCast(chain_object.get("stopped").?.integer)),
                    .color = try color.Rgb.fromHex(chain_object.get("color").?.string[1..]),
                    .id = @as(u16, @intCast(chain_object.get("id").?.integer)),
                    .name_len = @as(u16, @intCast(name.len)),
                    .kind = std.meta.stringToEnum(Kind, chain_object.get("kind").?.string).?,
                    .min_days = @as(u8, @intCast(chain_object.get("min_days").?.integer)), // `0` means N/A
                    .n_tags = n_tags,
                    .tags = tags,
                };

                chain_meta.len += 1;
                chain_meta.id_counter = @max(chain_meta.id_counter, chain.id);

                try all_chains.append(chain);

                const links = chain_object.get("links").?.array;
                for (links.items) |lv| {
                    const link_object = lv.object;
                    const link = Link{
                        .chain_id = chain.id,
                        .tags = 0,
                        .timestamp = @as(i64, @intCast(link_object.get("timestamp").?.integer)),
                    };

                    link_meta.len += 1;

                    try all_links.append(link);
                }
            }

            std.sort.pdq(Link, all_links.items, {}, orderLinksTimestamp);

            chain_meta.id_counter += 1;

            var imported_files = try openOrCreateDbFiles(options.data_dir, ".import");
            defer imported_files.close();

            var cw = imported_files.chains.writer();
            try imported_files.chains.seekTo(0);
            try cw.writeStruct(chain_meta);
            const chain_bytes = std.mem.sliceAsBytes(all_chains.items);
            try cw.writeAll(chain_bytes);
            try imported_files.chains.setEndPos(@sizeOf(ChainMeta) + chain_bytes.len);

            var lw = imported_files.links.writer();
            try imported_files.links.seekTo(0);
            try lw.writeStruct(link_meta);
            const link_bytes = std.mem.sliceAsBytes(all_links.items);
            try lw.writeAll(link_bytes);
            try imported_files.links.setEndPos(@sizeOf(LinkMeta) + link_bytes.len);
        },
        .display => {
            try checkNumberOfArgs(allocator, args, 2);
            try chain_db.materialize();
            if (chain_db.meta.len == 0) {
                printAndExit("No chains to display, use `habu add` to add a chain or `habu help` for a full list of commands.\n", .{});
            }
            const chains = chain_db.getChains();

            const range = parseRangeOrExit(optionalArg(args, 1), optionalArg(args, 2));

            try link_db.materialize(chain_db.meta.len);
            const links = link_db.getAndSortLinks(range.start);

            try tui.drawChains(chains, links, range.start, range.end);
        },
        .help => {
            try checkNumberOfArgs(allocator, args, 1);
            const sub_command = if (optionalArg(args, 1)) |str|
                parseCommandOrExit(str)
            else
                printHelpAndExit(null);

            const help_str = help.commandHelp(sub_command);
            if (help_str) |str| {
                try sow.writeAll(str);
            } else {
                printAndExit("No additional help avaiable for subcommand '{s}'\n", .{@tagName(sub_command)});
            }
        },
        .modify => {
            try checkNumberOfArgs(allocator, args, 3);
            try chain_db.materialize();
            const index_str = expectArg(args, 1, "id");
            const cid_and_index = try parseAndValidateChainIndex(&chain_db, index_str);

            const field = expectArg(args, 2, "field");
            const value = expectArg(args, 3, "value");
            var chain = chain_db.getByIndex(cid_and_index.index);

            if (std.mem.eql(u8, field, "color")) {
                const new_color = try color.Rgb.fromHex(value);
                chain.color = new_color;
            } else if (std.mem.eql(u8, field, "name")) {
                validateNameLen(value);
                var name_buf = std.mem.zeroes([chain_name_max_len]u8);
                std.mem.copy(u8, &name_buf, value);
                chain.name = name_buf;
                chain.name_len = @as(u16, @intCast(value.len));
            } else if (std.mem.eql(u8, field, "min_days")) {
                if (chain.kind != .weekly) {
                    try printHelpAndExit("Cannot modify min_days of non-weekly chain");
                }
                chain.min_days = parseMinDaysOrExit(value);
            } else if (std.mem.eql(u8, field, "tags")) {
                const op = value;
                if (std.mem.eql(u8, op, "add")) {
                    if (chain.n_tags >= max_tags) {
                        printAndExit("Max tags ({d}) exceeded\n", .{max_tags});
                    }

                    const name = expectArg(args, 4, "name");
                    validateTagNameLen(name);
                    var name_buf = std.mem.zeroes([tag_name_max_len]u8);
                    std.mem.copy(u8, &name_buf, name[0..@min(name.len, name_buf.len)]);
                    chain.tags[chain.n_tags] = Tag{
                        .header = .{
                            .id = @as(u3, @intCast(chain.maxTagsId() + 1)),
                            .len = @as(u5, @intCast(name.len)),
                        },
                        .name = name_buf,
                    };
                    chain.n_tags += 1;
                } else if (std.mem.eql(u8, op, "delete")) {
                    printAndExit("TODO: implement tag delete\n", .{});
                } else if (std.mem.eql(u8, op, "rename")) {
                    printAndExit("TODO: implement tag rename\n", .{});
                }
            } else if (std.mem.eql(u8, field, "stopped")) {
                chain.stopped = if (std.mem.eql(u8, value, "false"))
                    ACTIVE
                else
                    parseLocalDateOrExit(value, "stop").toEpoch();
                chain_db.refilter();
            } else {
                const msg = scratchPrint("Invalid field '{s}', expected one of: color, name, min_days\n", .{trunc(field)});
                try printHelpAndExit(msg);
            }

            try chain_db.persist();

            try link_db.materialize(chain_db.meta.len);
            const chains = chain_db.getChains();
            const range = parseRangeOrExit(null, null);
            const links = link_db.getAndSortLinks(range.start);
            try tui.drawChains(chains, links, range.start, range.end);
        },
        .delete => {
            try checkNumberOfArgs(allocator, args, 1);
            try chain_db.materialize();
            const index_str = expectArg(args, 1, "index");
            const cid_and_index = try parseAndValidateChainIndex(&chain_db, index_str);

            chain_db.delete(cid_and_index.index);
            try chain_db.persist();

            try link_db.materialize(chain_db.meta.len);
            const chains = chain_db.getChains();
            const range = parseRangeOrExit(null, null);
            const links = link_db.getAndSortLinks(range.start);
            try tui.drawChains(chains, links, range.start, range.end);
        },
        .link, .unlink => {
            try chain_db.materialize();
            try link_db.materialize(chain_db.meta.len);

            const index_str = expectArg(args, 1, "index");
            const cids_and_indexes = try parseChainIndexes(allocator, &chain_db, index_str);

            const start_date_str = optionalArg(args, 2);
            const timestamp = if (start_date_str) |start_date|
                parseLocalDateOrExit(start_date, "link").midnightInLocal()
            else
                date.epochNow();

            for (cids_and_indexes) |cid_and_index| {
                switch (command) {
                    .link => {
                        try checkNumberOfArgs(allocator, args, 3);
                        var link = Link{
                            .chain_id = cid_and_index.id,
                            .tags = 0,
                            .timestamp = timestamp,
                        };

                        const tags_str = optionalArg(args, 3);
                        if (tags_str) |str| {
                            const chain = chain_db.getByIndex(cid_and_index.index);
                            var it = std.mem.split(u8, str, ",");
                            link.tags = chain.tagsFromNames(&it);
                        }

                        try link_db.add(link);
                    },
                    .unlink => {
                        try checkNumberOfArgs(allocator, args, 2);
                        const removed = link_db.remove(cid_and_index.id, timestamp);
                        if (!removed) {
                            const date_str = start_date_str orelse &LocalDate.fromEpoch(timestamp).asString();
                            try sow.print("No link found on {s}\n", .{date_str});
                        }
                    },
                    else => unreachable,
                }
            }

            buffered_writer.flush() catch panic();

            try link_db.persist();

            const chains = chain_db.getChains();
            const range = parseRangeOrExit(null, null);
            const links = link_db.getAndSortLinks(range.start);
            try tui.drawChains(chains, links, range.start, range.end);
        },
        .tag => {
            try checkNumberOfArgs(allocator, args, 3);
            const index_str = expectArg(args, 1, "index");
            try chain_db.materialize();
            const cid_and_index = try parseAndValidateChainIndex(&chain_db, index_str);

            const date_str = expectArg(args, 2, "date");
            const link_date = parseLocalDateOrExit(date_str, "link").toEpoch();

            try link_db.materialize(chain_db.meta.len);
            var result = LinkDb.getInsertIndex(link_db.links.items, cid_and_index.id, link_date);
            if (!result.occupied)
                printAndExit("No link found at date '{s}' for chain {d}\n", .{trunc(date_str), cid_and_index.index});
            var index = result.index;

            var link = &link_db.links.items[index];
            link_db.first_write_index = index;

            const chain = chain_db.getByIndex(cid_and_index.index);
            if (chain.n_tags == 0) {
                printAndExit("Chain '{d}' has no tags\n", .{chain.id});
            }

            const tag_names = expectArg(args, 3, "tags");
            var it = std.mem.split(u8, tag_names, ",");
            link.tags = chain.tagsFromNames(&it);

            try link_db.persist();
        },
        .version => {
            try sow.print("version: {s}\n", .{build_options.version});
            try sow.print("commit hash: {s}\n", .{build_options.git_commit_hash});
            if (optionalArg(args, 1)) |verbose| {
                if (std.mem.eql(u8, verbose, "-v")) {
                    const offset_ns = date.utcOffset(date.epochNowLocal()) * std.time.ns_per_s;
                    try sow.print("UTC offset: {}\n", .{std.fmt.fmtDurationSigned(offset_ns)});
                }
            }
        }
    }

    if (builtin.os.tag == .windows)
        _ = std.os.windows.kernel32.SetConsoleOutputCP(old_code_page);
}
