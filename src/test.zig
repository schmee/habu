const std = @import("std");
const date = @import("date.zig");
const main = @import("main.zig");
const color = @import("color.zig");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

const Allocator = std.mem.Allocator;
const LocalDate = date.LocalDate;
const ChainDb = main.ChainDb;
const LinkDb = main.LinkDb;
const Link = main.Link;

var allocator = std.heap.c_allocator;
const print_output = false;

test "basic" {
    // now = 2024-01-26T00:00:00Z
    var db = try TestDb.init(.{ .override_now = 1706227200 });
    defer db.deinit();

    try run(db, "add Foo daily");
    try run(db, "link 1 20240101");

    {
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

        try expectEqualSlices(u8, "Foo", chain.name[0..chain.name_len]);
        try expectEqual(@as(i64, 1706227200), chain.created);
        try expectEqual(@as(u16, 0), chain.id);
        var k: main.Kind = .daily;
        try expectEqual(k, chain.kind);
        try expectEqual(color.Rgb{ .r = 126, .g = 122, .b = 245 }, chain.color);
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

    try run(db, "delete 1");
    {
        db.loadFiles();
        defer db.unloadFiles();

        var chain_db = db.chainDb();
        try chain_db.materialize();
        const meta = chain_db.meta;
        try expectEqual(@as(u16, 1), meta.id_counter);
        try expectEqual(@as(u16, 0), meta.len);
        try expectEqual(@as(u32, 0), meta._padding);
        try expectEqual(chain_db.chains.items.len, 0);
    }
    try expectErrorMessage(db, "No chain found with index '1'", "link 1 20240101");
}

test "linking same day twice" {
    var db = try TestDb.init(.{});
    defer db.deinit();

    try run(db, "add foo daily");
    try run(db, "link 1 20240101");

    const links = &.{ Link{ .chain_id = 0, .timestamp = 1704063600 }};
    try expectLinks(&db, links);
    try expectErrorMessage(db, "Link already exists on date 2024-01-01, skipping",  "link 1 20240101");
    try expectLinks(&db, links);
}

test "link/unlink stress test" {
    var db = try TestDb.init(.{});
    defer db.deinit();

    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    var prng = std.rand.DefaultPrng.init(@bitCast(seed));
    var random = prng.random();

    const S = struct {
        chain_id: u16,
        date_str: []const u8,
        timestamp: i64,
    };

    var year = blk: {
        var dates: [365]S = undefined;
        var i: usize = 0;
        for (year_2023) |day| {
            const chain_id = random.uintLessThan(u16, 5);
            dates[i] = .{ .chain_id = chain_id, .date_str = day.date_str, .timestamp = day.timestamp };
            i += 1;
        }
        break :blk dates;
    };

    const links = blk: {
        var links: [365]Link = undefined;
        for (year, 0..) |day, i| {
            links[i] = Link{ .chain_id = day.chain_id, .timestamp = day.timestamp };
        }
        break :blk links;
    };

    try run(db, "add c1 daily");
    try run(db, "add c2 daily");
    try run(db, "add c3 weekly 4");
    try run(db, "add c4 daily");
    try run(db, "add c5 weekly 3");

    random.shuffle(S, &year);

    var buf = std.mem.zeroes([30]u8);
    for (year) |day| {
        const input = try std.fmt.bufPrint(&buf, "link {d} {s}", .{day.chain_id + 1, day.date_str});
        try run(db, input);
    }
    try expectLinks(&db, &links);

    var links_array = std.ArrayList(Link).fromOwnedSlice(allocator, try allocator.dupe(Link, &links));
    random.shuffle(S, &year);
    for (year) |day| {
        const input = try std.fmt.bufPrint(&buf, "unlink {d} {s}", .{day.chain_id + 1, day.date_str});
        try run(db, input);
        for (links_array.items, 0..) |link, j| {
            if (link.timestamp == day.timestamp) {
                _ = links_array.orderedRemove(j);
                break;
            }
        }
        try expectLinks(&db, links_array.items);
    }
}

test "link now" {
    // now = 2024-01-26T00:00:00Z
    var db = try TestDb.init(.{ .override_now = 1706227200 });
    defer db.deinit();

    try run(db, "add foo daily");
    try run(db, "link 1");
    try expectLinks(&db, &.{Link{ .chain_id = 0, .timestamp = 1706227200 }});
}

test "relative dates" {
    // now = 2024-01-26T00:00:00Z
    var db = try TestDb.init(.{ .override_now = 1706227200 });
    defer db.deinit();

    try run(db, "add foo daily");

    try run(db, "link 1 10"); // 2024-01-16
    try run(db, "link 1 11"); // 2024-01-15
    try run(db, "link 1 12"); // 2024-01-14

    try run(db, "link 1 mon"); // 2024-01-22
    try run(db, "link 1 tue"); // 2024-01-23
    try run(db, "link 1 wed"); // 2024-01-24
    try run(db, "link 1 thu"); // 2024-01-25
    try run(db, "link 1 fri"); // 2024-01-26
    try run(db, "link 1 sat"); // 2024-01-20
    try run(db, "link 1 sun"); // 2024-01-21

    try run(db, "link 1 1st"); // 2024-01-01
    try run(db, "link 1 2nd"); // 2024-01-02
    try run(db, "link 1 3rd"); // 2024-01-03
    try run(db, "link 1 10th"); // 2024-01-10

    const expected = [_]Link{
        Link{ .chain_id = 0, .timestamp = 1704063600 }, // 2024-01-01
        Link{ .chain_id = 0, .timestamp = 1704150000 }, // 2024-01-02
        Link{ .chain_id = 0, .timestamp = 1704236400 }, // 2024-01-03
        Link{ .chain_id = 0, .timestamp = 1704841200 }, // 2024-01-10

        Link{ .chain_id = 0, .timestamp = 1705186800 }, // 2024-01-14
        Link{ .chain_id = 0, .timestamp = 1705273200 }, // 2024-01-15
        Link{ .chain_id = 0, .timestamp = 1705359600 }, // 2024-01-16

        Link{ .chain_id = 0, .timestamp = 1705705200 }, // 2024-01-20
        Link{ .chain_id = 0, .timestamp = 1705791600 }, // 2024-01-21
        Link{ .chain_id = 0, .timestamp = 1705878000 }, // 2024-01-22
        Link{ .chain_id = 0, .timestamp = 1705964400 }, // 2024-01-23
        Link{ .chain_id = 0, .timestamp = 1706050800 }, // 2024-01-24
        Link{ .chain_id = 0, .timestamp = 1706137200 }, // 2024-01-25
        Link{ .chain_id = 0, .timestamp = 1706223600 }, // 2024-01-26
    };

    try expectLinks(&db, &expected);
}

test "parse date error" {
    var db = try TestDb.init(.{});
    defer db.deinit();

    try run(db, "add foo daily");

    try expectErrorMessage(db, "Invalid link date '2023011', does not match any format", "link 1 2023011");
    try expectErrorMessage(db, "Invalid link date '-123', does not match any format", "link 1 -123");
    try expectErrorMessage(db, "Invalid link date 'asdf', does not match any format", "link 1 asdf");
    try expectErrorMessage(db, "Invalid link date '100', does not match any format", "link 1 100");
    try expectErrorMessage(db, "Invalid link date '99th', out of range for December which has 31 days", "link 1 99th");
    try expectErrorMessage(db, "Invalid link date '0th', does not match any format", "link 1 0th");
    try expectErrorMessage(db, "Invalid link date '20100101', year before 2022 not supported", "link 1 20100101");
}

test "error messages" {
    // now = 2024-01-26T00:00:00Z
    var db = try TestDb.init(.{ .override_now = 1706227200 });
    defer db.deinit();

    try expectErrorMessage(db, "Expected 'kind' argument", "add foo");
    try expectErrorMessage(db, "No chain found with index '1'", "link 1");
    try expectErrorMessage(db, "No chain found with index '1'", "unlink 1");

    try run(db, "add foo daily");
    try expectErrorMessage(db, "No link found on 2024-01-26", "unlink 1");
}

const TestDb = struct {
    tmpdir: testing.TmpDir,
    path: []const u8,
    files: ?main.Files,
    override_now: ?i64,

    const Self = @This();

    fn init(args: struct { override_now: ?i64 = null}) !Self {
        const tmpdir = testing.tmpDir(.{});
        _ = try tmpdir.dir.makeOpenPath("db", .{});
        return .{
            .tmpdir = tmpdir,
            .files = null,
            .path = try tmpdir.dir.realpathAlloc(allocator, "db"),
            .override_now = args.override_now,
        };
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

fn expectLinks(db: *TestDb, expected: []const Link) !void {
    db.loadFiles();
    defer db.unloadFiles();

    var link_db = db.linkDb();
    try link_db.materialize(1);

    const meta = link_db.meta;
    try expectEqual(@as(u16, @intCast(expected.len)), meta.len);

    try expectEqualSlices(
        Link,
        expected,
        link_db.links.items
    );
}

fn expectErrorMessage(db: TestDb, message: []const u8, input: []const u8) !void {
    const result = try runCapture(db, input);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    var it = std.mem.split(u8, result.stdout, "\n");
    try expectEqualSlices(u8, message, it.next().?);
}

fn run(db: TestDb, input: []const u8) !void {
    var result = try runCapture(db, input);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runCapture(db: TestDb, input: []const u8) !std.ChildProcess.ExecResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("./zig-out/bin/habu");
    try argv.append("--data-dir");
    try argv.append(db.path);
    try argv.append("--transitions");
    try argv.append(europe_stockholm_transitions_json);
    if (db.override_now) |now| {
        try argv.append("--now");
        try argv.append(try std.fmt.allocPrint(allocator, "{d}", .{now}));
    }

    var it = std.mem.split(u8, input, " ");
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try argv.append(part);
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

const DateTime = struct {
    date_str: []const u8,
    timestamp: i64,
};

// Good 'ol Java
// public static void main(String[] args) {
//     var start = ZonedDateTime.of(LocalDate.of(2023, 1, 1), LocalTime.MIDNIGHT, ZoneId.of("Europe/Stockholm"));
//     while (start.getYear() == 2023) {
//         var dateStr = start.format(DateTimeFormatter.ofPattern("yyyyMMdd"));
//         var epoch = start.toInstant().toEpochMilli() / 1000;
//         System.out.format(".{ .date_str = \"%s%02d%02d\", .timestamp = %s },\n", start.getYear(), start.getMonthValue(), start.getDayOfMonth(), epoch);
//         start = start.plusDays(1);
//     }
// }
const year_2023 = [_]DateTime{
    .{ .date_str = "20230101", .timestamp = 1672527600 },
    .{ .date_str = "20230102", .timestamp = 1672614000 },
    .{ .date_str = "20230103", .timestamp = 1672700400 },
    .{ .date_str = "20230104", .timestamp = 1672786800 },
    .{ .date_str = "20230105", .timestamp = 1672873200 },
    .{ .date_str = "20230106", .timestamp = 1672959600 },
    .{ .date_str = "20230107", .timestamp = 1673046000 },
    .{ .date_str = "20230108", .timestamp = 1673132400 },
    .{ .date_str = "20230109", .timestamp = 1673218800 },
    .{ .date_str = "20230110", .timestamp = 1673305200 },
    .{ .date_str = "20230111", .timestamp = 1673391600 },
    .{ .date_str = "20230112", .timestamp = 1673478000 },
    .{ .date_str = "20230113", .timestamp = 1673564400 },
    .{ .date_str = "20230114", .timestamp = 1673650800 },
    .{ .date_str = "20230115", .timestamp = 1673737200 },
    .{ .date_str = "20230116", .timestamp = 1673823600 },
    .{ .date_str = "20230117", .timestamp = 1673910000 },
    .{ .date_str = "20230118", .timestamp = 1673996400 },
    .{ .date_str = "20230119", .timestamp = 1674082800 },
    .{ .date_str = "20230120", .timestamp = 1674169200 },
    .{ .date_str = "20230121", .timestamp = 1674255600 },
    .{ .date_str = "20230122", .timestamp = 1674342000 },
    .{ .date_str = "20230123", .timestamp = 1674428400 },
    .{ .date_str = "20230124", .timestamp = 1674514800 },
    .{ .date_str = "20230125", .timestamp = 1674601200 },
    .{ .date_str = "20230126", .timestamp = 1674687600 },
    .{ .date_str = "20230127", .timestamp = 1674774000 },
    .{ .date_str = "20230128", .timestamp = 1674860400 },
    .{ .date_str = "20230129", .timestamp = 1674946800 },
    .{ .date_str = "20230130", .timestamp = 1675033200 },
    .{ .date_str = "20230131", .timestamp = 1675119600 },
    .{ .date_str = "20230201", .timestamp = 1675206000 },
    .{ .date_str = "20230202", .timestamp = 1675292400 },
    .{ .date_str = "20230203", .timestamp = 1675378800 },
    .{ .date_str = "20230204", .timestamp = 1675465200 },
    .{ .date_str = "20230205", .timestamp = 1675551600 },
    .{ .date_str = "20230206", .timestamp = 1675638000 },
    .{ .date_str = "20230207", .timestamp = 1675724400 },
    .{ .date_str = "20230208", .timestamp = 1675810800 },
    .{ .date_str = "20230209", .timestamp = 1675897200 },
    .{ .date_str = "20230210", .timestamp = 1675983600 },
    .{ .date_str = "20230211", .timestamp = 1676070000 },
    .{ .date_str = "20230212", .timestamp = 1676156400 },
    .{ .date_str = "20230213", .timestamp = 1676242800 },
    .{ .date_str = "20230214", .timestamp = 1676329200 },
    .{ .date_str = "20230215", .timestamp = 1676415600 },
    .{ .date_str = "20230216", .timestamp = 1676502000 },
    .{ .date_str = "20230217", .timestamp = 1676588400 },
    .{ .date_str = "20230218", .timestamp = 1676674800 },
    .{ .date_str = "20230219", .timestamp = 1676761200 },
    .{ .date_str = "20230220", .timestamp = 1676847600 },
    .{ .date_str = "20230221", .timestamp = 1676934000 },
    .{ .date_str = "20230222", .timestamp = 1677020400 },
    .{ .date_str = "20230223", .timestamp = 1677106800 },
    .{ .date_str = "20230224", .timestamp = 1677193200 },
    .{ .date_str = "20230225", .timestamp = 1677279600 },
    .{ .date_str = "20230226", .timestamp = 1677366000 },
    .{ .date_str = "20230227", .timestamp = 1677452400 },
    .{ .date_str = "20230228", .timestamp = 1677538800 },
    .{ .date_str = "20230301", .timestamp = 1677625200 },
    .{ .date_str = "20230302", .timestamp = 1677711600 },
    .{ .date_str = "20230303", .timestamp = 1677798000 },
    .{ .date_str = "20230304", .timestamp = 1677884400 },
    .{ .date_str = "20230305", .timestamp = 1677970800 },
    .{ .date_str = "20230306", .timestamp = 1678057200 },
    .{ .date_str = "20230307", .timestamp = 1678143600 },
    .{ .date_str = "20230308", .timestamp = 1678230000 },
    .{ .date_str = "20230309", .timestamp = 1678316400 },
    .{ .date_str = "20230310", .timestamp = 1678402800 },
    .{ .date_str = "20230311", .timestamp = 1678489200 },
    .{ .date_str = "20230312", .timestamp = 1678575600 },
    .{ .date_str = "20230313", .timestamp = 1678662000 },
    .{ .date_str = "20230314", .timestamp = 1678748400 },
    .{ .date_str = "20230315", .timestamp = 1678834800 },
    .{ .date_str = "20230316", .timestamp = 1678921200 },
    .{ .date_str = "20230317", .timestamp = 1679007600 },
    .{ .date_str = "20230318", .timestamp = 1679094000 },
    .{ .date_str = "20230319", .timestamp = 1679180400 },
    .{ .date_str = "20230320", .timestamp = 1679266800 },
    .{ .date_str = "20230321", .timestamp = 1679353200 },
    .{ .date_str = "20230322", .timestamp = 1679439600 },
    .{ .date_str = "20230323", .timestamp = 1679526000 },
    .{ .date_str = "20230324", .timestamp = 1679612400 },
    .{ .date_str = "20230325", .timestamp = 1679698800 },
    .{ .date_str = "20230326", .timestamp = 1679785200 },
    .{ .date_str = "20230327", .timestamp = 1679868000 },
    .{ .date_str = "20230328", .timestamp = 1679954400 },
    .{ .date_str = "20230329", .timestamp = 1680040800 },
    .{ .date_str = "20230330", .timestamp = 1680127200 },
    .{ .date_str = "20230331", .timestamp = 1680213600 },
    .{ .date_str = "20230401", .timestamp = 1680300000 },
    .{ .date_str = "20230402", .timestamp = 1680386400 },
    .{ .date_str = "20230403", .timestamp = 1680472800 },
    .{ .date_str = "20230404", .timestamp = 1680559200 },
    .{ .date_str = "20230405", .timestamp = 1680645600 },
    .{ .date_str = "20230406", .timestamp = 1680732000 },
    .{ .date_str = "20230407", .timestamp = 1680818400 },
    .{ .date_str = "20230408", .timestamp = 1680904800 },
    .{ .date_str = "20230409", .timestamp = 1680991200 },
    .{ .date_str = "20230410", .timestamp = 1681077600 },
    .{ .date_str = "20230411", .timestamp = 1681164000 },
    .{ .date_str = "20230412", .timestamp = 1681250400 },
    .{ .date_str = "20230413", .timestamp = 1681336800 },
    .{ .date_str = "20230414", .timestamp = 1681423200 },
    .{ .date_str = "20230415", .timestamp = 1681509600 },
    .{ .date_str = "20230416", .timestamp = 1681596000 },
    .{ .date_str = "20230417", .timestamp = 1681682400 },
    .{ .date_str = "20230418", .timestamp = 1681768800 },
    .{ .date_str = "20230419", .timestamp = 1681855200 },
    .{ .date_str = "20230420", .timestamp = 1681941600 },
    .{ .date_str = "20230421", .timestamp = 1682028000 },
    .{ .date_str = "20230422", .timestamp = 1682114400 },
    .{ .date_str = "20230423", .timestamp = 1682200800 },
    .{ .date_str = "20230424", .timestamp = 1682287200 },
    .{ .date_str = "20230425", .timestamp = 1682373600 },
    .{ .date_str = "20230426", .timestamp = 1682460000 },
    .{ .date_str = "20230427", .timestamp = 1682546400 },
    .{ .date_str = "20230428", .timestamp = 1682632800 },
    .{ .date_str = "20230429", .timestamp = 1682719200 },
    .{ .date_str = "20230430", .timestamp = 1682805600 },
    .{ .date_str = "20230501", .timestamp = 1682892000 },
    .{ .date_str = "20230502", .timestamp = 1682978400 },
    .{ .date_str = "20230503", .timestamp = 1683064800 },
    .{ .date_str = "20230504", .timestamp = 1683151200 },
    .{ .date_str = "20230505", .timestamp = 1683237600 },
    .{ .date_str = "20230506", .timestamp = 1683324000 },
    .{ .date_str = "20230507", .timestamp = 1683410400 },
    .{ .date_str = "20230508", .timestamp = 1683496800 },
    .{ .date_str = "20230509", .timestamp = 1683583200 },
    .{ .date_str = "20230510", .timestamp = 1683669600 },
    .{ .date_str = "20230511", .timestamp = 1683756000 },
    .{ .date_str = "20230512", .timestamp = 1683842400 },
    .{ .date_str = "20230513", .timestamp = 1683928800 },
    .{ .date_str = "20230514", .timestamp = 1684015200 },
    .{ .date_str = "20230515", .timestamp = 1684101600 },
    .{ .date_str = "20230516", .timestamp = 1684188000 },
    .{ .date_str = "20230517", .timestamp = 1684274400 },
    .{ .date_str = "20230518", .timestamp = 1684360800 },
    .{ .date_str = "20230519", .timestamp = 1684447200 },
    .{ .date_str = "20230520", .timestamp = 1684533600 },
    .{ .date_str = "20230521", .timestamp = 1684620000 },
    .{ .date_str = "20230522", .timestamp = 1684706400 },
    .{ .date_str = "20230523", .timestamp = 1684792800 },
    .{ .date_str = "20230524", .timestamp = 1684879200 },
    .{ .date_str = "20230525", .timestamp = 1684965600 },
    .{ .date_str = "20230526", .timestamp = 1685052000 },
    .{ .date_str = "20230527", .timestamp = 1685138400 },
    .{ .date_str = "20230528", .timestamp = 1685224800 },
    .{ .date_str = "20230529", .timestamp = 1685311200 },
    .{ .date_str = "20230530", .timestamp = 1685397600 },
    .{ .date_str = "20230531", .timestamp = 1685484000 },
    .{ .date_str = "20230601", .timestamp = 1685570400 },
    .{ .date_str = "20230602", .timestamp = 1685656800 },
    .{ .date_str = "20230603", .timestamp = 1685743200 },
    .{ .date_str = "20230604", .timestamp = 1685829600 },
    .{ .date_str = "20230605", .timestamp = 1685916000 },
    .{ .date_str = "20230606", .timestamp = 1686002400 },
    .{ .date_str = "20230607", .timestamp = 1686088800 },
    .{ .date_str = "20230608", .timestamp = 1686175200 },
    .{ .date_str = "20230609", .timestamp = 1686261600 },
    .{ .date_str = "20230610", .timestamp = 1686348000 },
    .{ .date_str = "20230611", .timestamp = 1686434400 },
    .{ .date_str = "20230612", .timestamp = 1686520800 },
    .{ .date_str = "20230613", .timestamp = 1686607200 },
    .{ .date_str = "20230614", .timestamp = 1686693600 },
    .{ .date_str = "20230615", .timestamp = 1686780000 },
    .{ .date_str = "20230616", .timestamp = 1686866400 },
    .{ .date_str = "20230617", .timestamp = 1686952800 },
    .{ .date_str = "20230618", .timestamp = 1687039200 },
    .{ .date_str = "20230619", .timestamp = 1687125600 },
    .{ .date_str = "20230620", .timestamp = 1687212000 },
    .{ .date_str = "20230621", .timestamp = 1687298400 },
    .{ .date_str = "20230622", .timestamp = 1687384800 },
    .{ .date_str = "20230623", .timestamp = 1687471200 },
    .{ .date_str = "20230624", .timestamp = 1687557600 },
    .{ .date_str = "20230625", .timestamp = 1687644000 },
    .{ .date_str = "20230626", .timestamp = 1687730400 },
    .{ .date_str = "20230627", .timestamp = 1687816800 },
    .{ .date_str = "20230628", .timestamp = 1687903200 },
    .{ .date_str = "20230629", .timestamp = 1687989600 },
    .{ .date_str = "20230630", .timestamp = 1688076000 },
    .{ .date_str = "20230701", .timestamp = 1688162400 },
    .{ .date_str = "20230702", .timestamp = 1688248800 },
    .{ .date_str = "20230703", .timestamp = 1688335200 },
    .{ .date_str = "20230704", .timestamp = 1688421600 },
    .{ .date_str = "20230705", .timestamp = 1688508000 },
    .{ .date_str = "20230706", .timestamp = 1688594400 },
    .{ .date_str = "20230707", .timestamp = 1688680800 },
    .{ .date_str = "20230708", .timestamp = 1688767200 },
    .{ .date_str = "20230709", .timestamp = 1688853600 },
    .{ .date_str = "20230710", .timestamp = 1688940000 },
    .{ .date_str = "20230711", .timestamp = 1689026400 },
    .{ .date_str = "20230712", .timestamp = 1689112800 },
    .{ .date_str = "20230713", .timestamp = 1689199200 },
    .{ .date_str = "20230714", .timestamp = 1689285600 },
    .{ .date_str = "20230715", .timestamp = 1689372000 },
    .{ .date_str = "20230716", .timestamp = 1689458400 },
    .{ .date_str = "20230717", .timestamp = 1689544800 },
    .{ .date_str = "20230718", .timestamp = 1689631200 },
    .{ .date_str = "20230719", .timestamp = 1689717600 },
    .{ .date_str = "20230720", .timestamp = 1689804000 },
    .{ .date_str = "20230721", .timestamp = 1689890400 },
    .{ .date_str = "20230722", .timestamp = 1689976800 },
    .{ .date_str = "20230723", .timestamp = 1690063200 },
    .{ .date_str = "20230724", .timestamp = 1690149600 },
    .{ .date_str = "20230725", .timestamp = 1690236000 },
    .{ .date_str = "20230726", .timestamp = 1690322400 },
    .{ .date_str = "20230727", .timestamp = 1690408800 },
    .{ .date_str = "20230728", .timestamp = 1690495200 },
    .{ .date_str = "20230729", .timestamp = 1690581600 },
    .{ .date_str = "20230730", .timestamp = 1690668000 },
    .{ .date_str = "20230731", .timestamp = 1690754400 },
    .{ .date_str = "20230801", .timestamp = 1690840800 },
    .{ .date_str = "20230802", .timestamp = 1690927200 },
    .{ .date_str = "20230803", .timestamp = 1691013600 },
    .{ .date_str = "20230804", .timestamp = 1691100000 },
    .{ .date_str = "20230805", .timestamp = 1691186400 },
    .{ .date_str = "20230806", .timestamp = 1691272800 },
    .{ .date_str = "20230807", .timestamp = 1691359200 },
    .{ .date_str = "20230808", .timestamp = 1691445600 },
    .{ .date_str = "20230809", .timestamp = 1691532000 },
    .{ .date_str = "20230810", .timestamp = 1691618400 },
    .{ .date_str = "20230811", .timestamp = 1691704800 },
    .{ .date_str = "20230812", .timestamp = 1691791200 },
    .{ .date_str = "20230813", .timestamp = 1691877600 },
    .{ .date_str = "20230814", .timestamp = 1691964000 },
    .{ .date_str = "20230815", .timestamp = 1692050400 },
    .{ .date_str = "20230816", .timestamp = 1692136800 },
    .{ .date_str = "20230817", .timestamp = 1692223200 },
    .{ .date_str = "20230818", .timestamp = 1692309600 },
    .{ .date_str = "20230819", .timestamp = 1692396000 },
    .{ .date_str = "20230820", .timestamp = 1692482400 },
    .{ .date_str = "20230821", .timestamp = 1692568800 },
    .{ .date_str = "20230822", .timestamp = 1692655200 },
    .{ .date_str = "20230823", .timestamp = 1692741600 },
    .{ .date_str = "20230824", .timestamp = 1692828000 },
    .{ .date_str = "20230825", .timestamp = 1692914400 },
    .{ .date_str = "20230826", .timestamp = 1693000800 },
    .{ .date_str = "20230827", .timestamp = 1693087200 },
    .{ .date_str = "20230828", .timestamp = 1693173600 },
    .{ .date_str = "20230829", .timestamp = 1693260000 },
    .{ .date_str = "20230830", .timestamp = 1693346400 },
    .{ .date_str = "20230831", .timestamp = 1693432800 },
    .{ .date_str = "20230901", .timestamp = 1693519200 },
    .{ .date_str = "20230902", .timestamp = 1693605600 },
    .{ .date_str = "20230903", .timestamp = 1693692000 },
    .{ .date_str = "20230904", .timestamp = 1693778400 },
    .{ .date_str = "20230905", .timestamp = 1693864800 },
    .{ .date_str = "20230906", .timestamp = 1693951200 },
    .{ .date_str = "20230907", .timestamp = 1694037600 },
    .{ .date_str = "20230908", .timestamp = 1694124000 },
    .{ .date_str = "20230909", .timestamp = 1694210400 },
    .{ .date_str = "20230910", .timestamp = 1694296800 },
    .{ .date_str = "20230911", .timestamp = 1694383200 },
    .{ .date_str = "20230912", .timestamp = 1694469600 },
    .{ .date_str = "20230913", .timestamp = 1694556000 },
    .{ .date_str = "20230914", .timestamp = 1694642400 },
    .{ .date_str = "20230915", .timestamp = 1694728800 },
    .{ .date_str = "20230916", .timestamp = 1694815200 },
    .{ .date_str = "20230917", .timestamp = 1694901600 },
    .{ .date_str = "20230918", .timestamp = 1694988000 },
    .{ .date_str = "20230919", .timestamp = 1695074400 },
    .{ .date_str = "20230920", .timestamp = 1695160800 },
    .{ .date_str = "20230921", .timestamp = 1695247200 },
    .{ .date_str = "20230922", .timestamp = 1695333600 },
    .{ .date_str = "20230923", .timestamp = 1695420000 },
    .{ .date_str = "20230924", .timestamp = 1695506400 },
    .{ .date_str = "20230925", .timestamp = 1695592800 },
    .{ .date_str = "20230926", .timestamp = 1695679200 },
    .{ .date_str = "20230927", .timestamp = 1695765600 },
    .{ .date_str = "20230928", .timestamp = 1695852000 },
    .{ .date_str = "20230929", .timestamp = 1695938400 },
    .{ .date_str = "20230930", .timestamp = 1696024800 },
    .{ .date_str = "20231001", .timestamp = 1696111200 },
    .{ .date_str = "20231002", .timestamp = 1696197600 },
    .{ .date_str = "20231003", .timestamp = 1696284000 },
    .{ .date_str = "20231004", .timestamp = 1696370400 },
    .{ .date_str = "20231005", .timestamp = 1696456800 },
    .{ .date_str = "20231006", .timestamp = 1696543200 },
    .{ .date_str = "20231007", .timestamp = 1696629600 },
    .{ .date_str = "20231008", .timestamp = 1696716000 },
    .{ .date_str = "20231009", .timestamp = 1696802400 },
    .{ .date_str = "20231010", .timestamp = 1696888800 },
    .{ .date_str = "20231011", .timestamp = 1696975200 },
    .{ .date_str = "20231012", .timestamp = 1697061600 },
    .{ .date_str = "20231013", .timestamp = 1697148000 },
    .{ .date_str = "20231014", .timestamp = 1697234400 },
    .{ .date_str = "20231015", .timestamp = 1697320800 },
    .{ .date_str = "20231016", .timestamp = 1697407200 },
    .{ .date_str = "20231017", .timestamp = 1697493600 },
    .{ .date_str = "20231018", .timestamp = 1697580000 },
    .{ .date_str = "20231019", .timestamp = 1697666400 },
    .{ .date_str = "20231020", .timestamp = 1697752800 },
    .{ .date_str = "20231021", .timestamp = 1697839200 },
    .{ .date_str = "20231022", .timestamp = 1697925600 },
    .{ .date_str = "20231023", .timestamp = 1698012000 },
    .{ .date_str = "20231024", .timestamp = 1698098400 },
    .{ .date_str = "20231025", .timestamp = 1698184800 },
    .{ .date_str = "20231026", .timestamp = 1698271200 },
    .{ .date_str = "20231027", .timestamp = 1698357600 },
    .{ .date_str = "20231028", .timestamp = 1698444000 },
    .{ .date_str = "20231029", .timestamp = 1698530400 },
    .{ .date_str = "20231030", .timestamp = 1698620400 },
    .{ .date_str = "20231031", .timestamp = 1698706800 },
    .{ .date_str = "20231101", .timestamp = 1698793200 },
    .{ .date_str = "20231102", .timestamp = 1698879600 },
    .{ .date_str = "20231103", .timestamp = 1698966000 },
    .{ .date_str = "20231104", .timestamp = 1699052400 },
    .{ .date_str = "20231105", .timestamp = 1699138800 },
    .{ .date_str = "20231106", .timestamp = 1699225200 },
    .{ .date_str = "20231107", .timestamp = 1699311600 },
    .{ .date_str = "20231108", .timestamp = 1699398000 },
    .{ .date_str = "20231109", .timestamp = 1699484400 },
    .{ .date_str = "20231110", .timestamp = 1699570800 },
    .{ .date_str = "20231111", .timestamp = 1699657200 },
    .{ .date_str = "20231112", .timestamp = 1699743600 },
    .{ .date_str = "20231113", .timestamp = 1699830000 },
    .{ .date_str = "20231114", .timestamp = 1699916400 },
    .{ .date_str = "20231115", .timestamp = 1700002800 },
    .{ .date_str = "20231116", .timestamp = 1700089200 },
    .{ .date_str = "20231117", .timestamp = 1700175600 },
    .{ .date_str = "20231118", .timestamp = 1700262000 },
    .{ .date_str = "20231119", .timestamp = 1700348400 },
    .{ .date_str = "20231120", .timestamp = 1700434800 },
    .{ .date_str = "20231121", .timestamp = 1700521200 },
    .{ .date_str = "20231122", .timestamp = 1700607600 },
    .{ .date_str = "20231123", .timestamp = 1700694000 },
    .{ .date_str = "20231124", .timestamp = 1700780400 },
    .{ .date_str = "20231125", .timestamp = 1700866800 },
    .{ .date_str = "20231126", .timestamp = 1700953200 },
    .{ .date_str = "20231127", .timestamp = 1701039600 },
    .{ .date_str = "20231128", .timestamp = 1701126000 },
    .{ .date_str = "20231129", .timestamp = 1701212400 },
    .{ .date_str = "20231130", .timestamp = 1701298800 },
    .{ .date_str = "20231201", .timestamp = 1701385200 },
    .{ .date_str = "20231202", .timestamp = 1701471600 },
    .{ .date_str = "20231203", .timestamp = 1701558000 },
    .{ .date_str = "20231204", .timestamp = 1701644400 },
    .{ .date_str = "20231205", .timestamp = 1701730800 },
    .{ .date_str = "20231206", .timestamp = 1701817200 },
    .{ .date_str = "20231207", .timestamp = 1701903600 },
    .{ .date_str = "20231208", .timestamp = 1701990000 },
    .{ .date_str = "20231209", .timestamp = 1702076400 },
    .{ .date_str = "20231210", .timestamp = 1702162800 },
    .{ .date_str = "20231211", .timestamp = 1702249200 },
    .{ .date_str = "20231212", .timestamp = 1702335600 },
    .{ .date_str = "20231213", .timestamp = 1702422000 },
    .{ .date_str = "20231214", .timestamp = 1702508400 },
    .{ .date_str = "20231215", .timestamp = 1702594800 },
    .{ .date_str = "20231216", .timestamp = 1702681200 },
    .{ .date_str = "20231217", .timestamp = 1702767600 },
    .{ .date_str = "20231218", .timestamp = 1702854000 },
    .{ .date_str = "20231219", .timestamp = 1702940400 },
    .{ .date_str = "20231220", .timestamp = 1703026800 },
    .{ .date_str = "20231221", .timestamp = 1703113200 },
    .{ .date_str = "20231222", .timestamp = 1703199600 },
    .{ .date_str = "20231223", .timestamp = 1703286000 },
    .{ .date_str = "20231224", .timestamp = 1703372400 },
    .{ .date_str = "20231225", .timestamp = 1703458800 },
    .{ .date_str = "20231226", .timestamp = 1703545200 },
    .{ .date_str = "20231227", .timestamp = 1703631600 },
    .{ .date_str = "20231228", .timestamp = 1703718000 },
    .{ .date_str = "20231229", .timestamp = 1703804400 },
    .{ .date_str = "20231230", .timestamp = 1703890800 },
    .{ .date_str = "20231231", .timestamp = 1703977200 },
};
