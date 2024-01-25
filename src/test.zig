const std = @import("std");
const date = @import("date.zig");
const main = @import("main.zig");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;


const Allocator = std.mem.Allocator;
const LocalDate = date.LocalDate;
const ChainDb = main.ChainDb;
const LinkDb = main.LinkDb;
const Link = main.Link;

var allocator = std.heap.c_allocator;
const print_output = true;

const TmpDb = struct {
    tmpdir: testing.TmpDir,
    path: []const u8,
    files: ?main.Files,

    const Self = @This();

    fn init() !Self {
        var s = Self{
            .tmpdir = testing.tmpDir(.{}),
            .files = null,
            .path = undefined,
        };
        _ = try s.tmpdir.dir.makeOpenPath("db", .{});
        s.path = try s.tmpdir.dir.realpathAlloc(allocator, "db");
        return s;
    }

    fn linkDb(self: *Self) LinkDb {
        self.loadFiles();
        return main.LinkDb{ .allocator = allocator, .file = self.files.?.links };
    }

    fn chainDb(self: *Self) ChainDb {
        self.loadFiles();
        return main.ChainDb{ .allocator = allocator, .file = self.files.?.chains, .show = .all };
    }

    fn loadFiles(self: *Self) void {
        if (self.files) |_| {
            return;
        } else {
            self.files = main.openOrCreateDbFiles(self.path, "") catch unreachable;
        }
    }

    fn unloadFiles(self: *Self) void {
        if (self.files) |*fs| fs.close();
        self.files = null;
    }

    fn deinit(self: *Self) void {
        if (self.files) |*fs| fs.close();
        self.tmpdir.cleanup();
        allocator.free(self.path);
    }
};

test "basic" {
    var db = try TmpDb.init();
    defer db.deinit();

    const commands = [_][]const u8{
        "",
        "add Foo daily",
        "link 1 20240101",
    };

    for (commands) |arg| {
        try runCommand(db.path, arg);
    }

    var chain_db = db.chainDb();
    try chain_db.materialize();
    const meta = chain_db.meta;
    try expectEqual(@as(u16, 1), meta.id_counter);
    try expectEqual(@as(u16, 1), meta.len);
    try expectEqual(@as(u32, 0), meta._padding);

    try expectEqual(chain_db.chains.items.len, 1);
    const chain = chain_db.chains.items[0];

    try testing.expectEqualSlices(u8, "Foo", chain.name[0..chain.name_len]);
    // try expectEqual(created, chain.);
    try expectEqual(@as(u16, 0), chain.id);
    var k: main.Kind = .daily;
    try expectEqual(k, chain.kind);
    // try expectEqual(.color, chain.kind);
    try expectEqual(@as(u8, 0), chain.min_days);
    try expectEqual(@as(i64, 0), chain.min_days);
    try expectEqual(@as(u8, 0), chain.n_tags);
    for (chain.tags) |tag| {
        try expectEqual(@as(main.Tag, @bitCast(@as(u128, 0))), tag);
    }
    try expectEqual(@as(i64, 0), chain.stopped);

    var link_db = db.linkDb();
    try link_db.materialize(chain_db.meta.len);

    try expectEqual(link_db.links.items.len, 1);
    try expectEqual(@as(i64, 0), link_db.links.items[0].chain_id);
    try expectEqual(@as(i64, 1704063600), link_db.links.items[0].timestamp);
}

test "linking same day twice" {
    var db = try TmpDb.init();
    defer db.deinit();

    const commands = [_][]const u8{
        "",
        "add Foo daily",
        "link 1 20240101",
    };

    for (commands) |arg| {
        try runCommand(db.path, arg);
    }

    {
        defer db.unloadFiles();

        var link_db = db.linkDb();
        try link_db.materialize(1);

        const meta = link_db.meta;
        try expectEqual(@as(u16, 1), meta.len);

        try expectEqualSlices(Link, &.{ Link{ .chain_id = 0, .timestamp = 1704063600, .tags = 0}}, link_db.links.items);
    }

    try runCommand(db.path, "link 1 20240101");
    {
        var link_db = db.linkDb();
        try link_db.materialize(1);

        const meta = link_db.meta;
        try expectEqual(@as(u16, 1), meta.len);

        try expectEqualSlices(Link, &.{ Link{ .chain_id = 0, .timestamp = 1704063600, .tags = 0}}, link_db.links.items);
    }
}

test "parse date" {
    try testDateParse(try LocalDate.init(2023, 1, 1), "20230101");
}

fn testDateParse(expected: LocalDate, str: []const u8) !void {
    const parsed = main.parseLocalDateOrExit(str, "");
    try expectEqual(expected, parsed);
}

fn runCommand(db_path: []const u8, input: []const u8) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("./zig-out/bin/habu");
    try argv.append("--data-dir");
    try argv.append(db_path);
    try argv.append("--transitions");
    try argv.append(europe_stockholm_transitions_json);
    for (try splitArg(input)) |arg| {
        try argv.append(arg);
    }
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv.items,
    });
    if (print_output) {
        std.debug.print("{s} >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>\n", .{input});
        std.debug.print("\n{s}", .{result.stdout});
        std.debug.print("\n{s}", .{result.stderr});
        std.debug.print("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n", .{});
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn splitArg(arg: []const u8) ![]const []const u8 {
    var it = std.mem.split(u8, arg, " ");
    var args = std.ArrayList([]const u8).init(allocator);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try args.append(part);
    }
    return args.toOwnedSlice();
}

const europe_stockholm_transitions_json =
\\ [
\\   { "ts": 1667091600, "offset": 3600 },
\\   { "ts": 1679792400, "offset": 7200 },
\\   { "ts": 1698541200, "offset": 3600 },
\\   { "ts": 1711846800, "offset": 7200 },
\\   { "ts": 1729990800, "offset": 3600 },
\\   { "ts": 1743296400, "offset": 7200 },
\\   { "ts": 1761440400, "offset": 3600 },
\\   { "ts": 1774746000, "offset": 7200 },
\\   { "ts": 1792890000, "offset": 3600 },
\\   { "ts": 1806195600, "offset": 7200 },
\\   { "ts": 1824944400, "offset": 3600 },
\\   { "ts": 1837645200, "offset": 7200 },
\\   { "ts": 1856394000, "offset": 3600 },
\\   { "ts": 1869094800, "offset": 7200 },
\\   { "ts": 1887843600, "offset": 3600 },
\\   { "ts": 1901149200, "offset": 7200 },
\\   { "ts": 1919293200, "offset": 3600 },
\\   { "ts": 1932598800, "offset": 7200 },
\\   { "ts": 1950742800, "offset": 3600 },
\\   { "ts": 1964048400, "offset": 7200 },
\\   { "ts": 1982797200, "offset": 3600 },
\\   { "ts": 1995498000, "offset": 7200 },
\\   { "ts": 2014246800, "offset": 3600 },
\\   { "ts": 2026947600, "offset": 7200 },
\\   { "ts": 2045696400, "offset": 3600 },
\\   { "ts": 2058397200, "offset": 7200 },
\\   { "ts": 2077146000, "offset": 3600 },
\\   { "ts": 2090451600, "offset": 7200 },
\\   { "ts": 2108595600, "offset": 3600 },
\\   { "ts": 2121901200, "offset": 7200 },
\\   { "ts": 2140045200, "offset": 3600 }
\\ ]
;

const utc_transitions_json =
\\ [
\\   { "ts": 1667091600, "offset": 0 },
\\   { "ts": 1679792400, "offset": 0 },
\\   { "ts": 1698541200, "offset": 0 },
\\   { "ts": 1711846800, "offset": 0 },
\\   { "ts": 1729990800, "offset": 0 },
\\   { "ts": 1743296400, "offset": 0 },
\\   { "ts": 1761440400, "offset": 0 },
\\   { "ts": 1774746000, "offset": 0 },
\\   { "ts": 1792890000, "offset": 0 },
\\   { "ts": 1806195600, "offset": 0 },
\\   { "ts": 1824944400, "offset": 0 },
\\   { "ts": 1837645200, "offset": 0 },
\\   { "ts": 1856394000, "offset": 0 },
\\   { "ts": 1869094800, "offset": 0 },
\\   { "ts": 1887843600, "offset": 0 },
\\   { "ts": 1901149200, "offset": 0 },
\\   { "ts": 1919293200, "offset": 0 },
\\   { "ts": 1932598800, "offset": 0 },
\\   { "ts": 1950742800, "offset": 0 },
\\   { "ts": 1964048400, "offset": 0 },
\\   { "ts": 1982797200, "offset": 0 },
\\   { "ts": 1995498000, "offset": 0 },
\\   { "ts": 2014246800, "offset": 0 },
\\   { "ts": 2026947600, "offset": 0 },
\\   { "ts": 2045696400, "offset": 0 },
\\   { "ts": 2058397200, "offset": 0 },
\\   { "ts": 2077146000, "offset": 0 },
\\   { "ts": 2090451600, "offset": 0 },
\\   { "ts": 2108595600, "offset": 0 },
\\   { "ts": 2121901200, "offset": 0 },
\\   { "ts": 2140045200, "offset": 0 }
\\ ]
;
