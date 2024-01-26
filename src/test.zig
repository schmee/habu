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

const TestDb = struct {
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
        return main.LinkDb{ .allocator = allocator, .file = self.files.?.links };
    }

    fn chainDb(self: *Self) ChainDb {
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
    var db = try TestDb.init();
    defer db.deinit();

    const commands = [_][]const u8{
        "",
        "add Foo daily",
        "link 1 20240101",
    };

    for (commands) |arg| {
        try run(db.path, arg);
    }

    db.loadFiles();
    defer db.unloadFiles();

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
    var db = try TestDb.init();
    defer db.deinit();

    const commands = [_][]const u8{
        "",
        "add Foo daily",
        "link 1 20240101",
    };

    for (commands) |arg| {
        try run(db.path, arg);
    }

    {
        db.loadFiles();
        defer db.unloadFiles();

        var link_db = db.linkDb();
        try link_db.materialize(1);

        const meta = link_db.meta;
        try expectEqual(@as(u16, 1), meta.len);

        try expectEqualSlices(Link, &.{ Link{ .chain_id = 0, .timestamp = 1704063600, .tags = 0}}, link_db.links.items);
    }

    try run(db.path, "link 1 20240101");
    {
        db.loadFiles();
        defer db.unloadFiles();

        var link_db = db.linkDb();
        try link_db.materialize(1);

        const meta = link_db.meta;
        try expectEqual(@as(u16, 1), meta.len);

        try expectEqualSlices(Link, &.{ Link{ .chain_id = 0, .timestamp = 1704063600, .tags = 0}}, link_db.links.items);
    }
}

test "linking / unlinking" {
    var db = try TestDb.init();
    defer db.deinit();

    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    var prng = std.rand.DefaultPrng.init(@bitCast(seed));
    var random = prng.random();

    var commands = [_][]const u8{
        "link 1 20240101",
        "link 2 20240102",
        "link 1 20240103",
        "link 2 20240104",
        "link 1 20240105",
        "link 2 20240106",
        "link 1 20240107",
        "link 2 20240108",
        "link 1 20240109",
        "link 2 20240110",
    };

    try run(db.path, "add foo daily");
    try run(db.path, "add bar daily");
    random.shuffle([]const u8, &commands);
    for (commands) |arg| {
        try run(db.path, arg);
    }

    const expected = [_]Link{
        Link{ .chain_id = 0, .timestamp = 1704063600, .tags = 0},
        Link{ .chain_id = 1, .timestamp = 1704150000, .tags = 0},
        Link{ .chain_id = 0, .timestamp = 1704236400, .tags = 0},
        Link{ .chain_id = 1, .timestamp = 1704322800, .tags = 0},
        Link{ .chain_id = 0, .timestamp = 1704409200, .tags = 0},
        Link{ .chain_id = 1, .timestamp = 1704495600, .tags = 0},
        Link{ .chain_id = 0, .timestamp = 1704582000, .tags = 0},
        Link{ .chain_id = 1, .timestamp = 1704668400, .tags = 0},
        Link{ .chain_id = 0, .timestamp = 1704754800, .tags = 0},
        Link{ .chain_id = 1, .timestamp = 1704841200, .tags = 0},
    };

    {
        db.loadFiles();
        defer db.unloadFiles();

        var link_db = db.linkDb();
        try link_db.materialize(2);

        const meta = link_db.meta;
        try expectEqual(@as(u16, 10), meta.len);

        try expectEqualSlices(
            Link,
            &expected,
            link_db.links.items
        );
    }

    var links_array = std.ArrayList(Link).fromOwnedSlice(allocator, try allocator.dupe(Link, &expected));

    const S = struct {
        input: []const u8,
        timestamp: i64,
    };

    var unlink_commands = [_]S{
        .{ .input = "unlink 1 20240101", .timestamp = 1704063600 },
        .{ .input = "unlink 2 20240102", .timestamp = 1704150000 },
        .{ .input = "unlink 1 20240103", .timestamp = 1704236400 },
        .{ .input = "unlink 2 20240104", .timestamp = 1704322800 },
        .{ .input = "unlink 1 20240105", .timestamp = 1704409200 },
        .{ .input = "unlink 2 20240106", .timestamp = 1704495600 },
        .{ .input = "unlink 1 20240107", .timestamp = 1704582000 },
        .{ .input = "unlink 2 20240108", .timestamp = 1704668400 },
        .{ .input = "unlink 1 20240109", .timestamp = 1704754800 },
        .{ .input = "unlink 2 20240110", .timestamp = 1704841200 },
    };

    random.shuffle(S, &unlink_commands);

    for (unlink_commands, 1..) |command, i| {
        try run(db.path, command.input);

        db.loadFiles();
        defer db.unloadFiles();

        for (links_array.items, 0..) |link, j| {
            if (link.timestamp == command.timestamp) {
                _ = links_array.orderedRemove(j);
                break;
            }
        }

        var link_db = db.linkDb();
        try link_db.materialize(2);

        const meta = link_db.meta;
        try expectEqual(@as(u16, 10 - @as(u16, @intCast(i))), meta.len);

        try expectEqualSlices(
            Link,
            links_array.items,
            link_db.links.items
        );
    }
}


test "parse date" {
    try testDateParse(try LocalDate.init(2023, 1, 1), "20230101");
}

test "parse date error" {
    var db = try TestDb.init();
    defer db.deinit();

    try testDateParseError(db, "Invalid link date '2023011', does not match any format", "link 1 2023011");
    try testDateParseError(db, "Invalid link date '-123', does not match any format", "link 1 -123");
    try testDateParseError(db, "Invalid link date 'asdf', does not match any format", "link 1 asdf");
    try testDateParseError(db, "Invalid link date '100', does not match any format", "link 1 100");
    try testDateParseError(db, "Invalid link date '99th', out of range for December which has 31 days", "link 1 99th");
    try testDateParseError(db, "Invalid link date '0th', does not match any format", "link 1 0th");
    try testDateParseError(db, "Invalid link date '20100101', year before 2022 not supported", "link 1 20100101");
}

fn testDateParse(expected: LocalDate, input: []const u8) !void {
    const parsed = main.parseLocalDateOrExit(input, "");
    try expectEqual(expected, parsed);
}

fn testDateParseError(db: TestDb, expected: []const u8, input: []const u8) !void {
    try run(db.path, "add foo daily");

    const result = try runCapture(db.path, input);
    var it = std.mem.split(u8, result.stdout, "\n");
    const msg = it.next().?;

    try expectEqualSlices(u8, expected, msg);
}

fn run(db_path: []const u8, input: []const u8) !void {
    var result = try runCapture(db_path, input);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runCapture(db_path: []const u8, input: []const u8) !std.ChildProcess.ExecResult {
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
    return result;
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
