const std = @import("std");
const builtin = @import("builtin");
const epoch = std.time.epoch;
const windows = std.os.windows;

const Allocator = std.mem.Allocator;

pub const secs_per_day: i64 = 60 * 60 * 24;
pub const max_weeks_per_year: u8 = 53;

pub const Weekday = enum(u3) {
    mon = 0,
    tue,
    wed,
    thu,
    fri,
    sat,
    sun,
};

pub const weekday_names = [_][]const u8{
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
};

const month_names = [_][]const u8{
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
};

const start_year: i64 = 2022;
const weekday_20220101: Weekday = .sat;
const instant_20220101: i64 = 1640995200;

var tz_init: bool = false;
var transitions: ?[]const Transition = null;

pub fn getWeekdayFromEpoch(instant: i64) Weekday {
    std.debug.assert(instant > instant_20220101);
    const n_days = @divFloor(instant - instant_20220101, secs_per_day);
    return @as(Weekday, @enumFromInt(@mod(n_days - 2, 7)));
}

pub fn getWeekNumberFromEpoch(instant: i64) u64 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(instant)) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const day = if (year_day.day == 0) epoch.getDaysInYear(year_day.year) else year_day.day - 1;
    return @divFloor(day, 7) + 1;
}

pub const LocalDate = struct {
    year: u16,
    day: u8,
    month: u8,
    local: bool, // TODO: packed struct

    const Self = @This();

    pub fn init(year: u16, month: u8, day: u8) !Self {
        if (year < 2022) return error.YearBefore2022;
        if (month < 1 or month > 12) return error.MonthOutOfRange;
        if (day > getDaysInMonth(year, month)) return error.DayOutOfRange;

        return .{
            .year = year,
            .month = month,
            .day = day,
            .local = true,
        };
    }

    pub fn parse(yyyymmdd: []const u8) !Self {
        if (yyyymmdd.len != 8) return error.BadFormat;

        const year = std.fmt.parseInt(u16, yyyymmdd[0..4], 10) catch |err| switch (err) {
            error.Overflow => unreachable, // all four-digit numbers fit into a u16
            else => |e| return e,
        };

        const month = std.fmt.parseInt(u8, yyyymmdd[4..6], 10) catch |err| switch (err) {
            error.Overflow => unreachable, // all two-digit numbers fit into a u8
            else => |e| return e,
        };

        const day = std.fmt.parseInt(u8, yyyymmdd[6..8], 10) catch |err| switch (err) {
            error.Overflow => unreachable, // all two-digit numbers fit into a u8
            else => |e| return e,
        };

        return Self.init(year, month, day);
    }

    pub fn fromEpoch(instant: i64) LocalDate {
        const es = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(instant)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        return .{
            .year = yd.year,
            .month = md.month.numeric(),
            .day = md.day_index + 1,
            .local = false,
        };
    }

    pub fn epochToLocal(instant: i64) LocalDate {
        var ld = Self.fromEpoch(instant + utcOffset(instant));
        ld.local = true;
        return ld;
    }

    pub fn toEpoch(self: Self) i64 {
        var instant: i64 = 0;
        var y: u16 = 1970;
        while (y < self.year) : (y += 1) {
            instant += epoch.getDaysInYear(y) * secs_per_day;
        }
        var m: u8 = 1;
        while (m < self.month) : (m += 1) {
            instant += getDaysInMonth(self.year, m) * secs_per_day;
        }
        return instant + (self.day - 1) * secs_per_day;
    }

    pub fn midnightInLocal(self: Self) i64 {
        const instant = self.toEpoch();
        return instant - utcOffset(instant);
    }

    pub fn asString(self: Self) [10]u8 {
        var buf: [10]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day }) catch unreachable;
        return buf;
    }

    pub fn compare(self: Self, other: Self) std.math.Order {
        return switch (std.math.order(self.year, other.year)) {
            .lt => .lt,
            .gt => .gt,
            .eq => switch (std.math.order(self.month, other.month)) {
                .lt => .lt,
                .gt => .gt,
                .eq => std.math.order(self.day, other.day),
            },
        };
    }

    pub fn next(self: Self) Self {
        var next_day = (self.day + 1) % (getDaysInMonth(self.year, self.month) + 1);
        if (next_day == 0) next_day += 1;
        var month = if (next_day < self.day) (self.month + 1) % 13 else self.month;
        if (month == 0) month += 1;
        const year = if (self.month == 12 and month == 1) self.year + 1 else self.year;
        return .{
            .year = year,
            .month = month,
            .day = next_day,
            .local = self.local,
        };
    }

    pub fn prev(self: Self) Self {
        var prev_day = (self.day - 1) % (getDaysInMonth(self.year, self.month) + 1);
        if (prev_day == 0) prev_day += 1;
        var month = if (prev_day < self.day) (self.month - 1) % 13 else self.month;
        if (month == 0) month += 1;
        const year = if (self.month == 1 and month == 12) self.year - 1 else self.year;
        return .{
            .year = year,
            .month = month,
            .day = prev_day,
            .local = self.local,
        };
    }

    pub fn oneMonthAgo(self: Self) Self {
        var month = (self.month - 1) % 13;
        if (month == 0) month += 1;
        const year = if (self.month == 1 and month == 12) self.year - 1 else self.year;
        return .{
            .year = year,
            .month = month,
            .day = @min(self.day, getDaysInMonth(year, month)),
            .local = false,
        };
    }

    pub fn prevMonthAtDay(self: Self, day: u8) !Self {
        var month = (self.month - 1) % 13;
        if (month == 0) month += 1;
        const year = if (self.month == 1 and month == 12) self.year - 1 else self.year;
        return Self.init(year, month, day);
    }

    pub fn atStartOfWeek(self: Self) Self {
        var instant = self.toEpoch();
        const day_of_week = getWeekdayFromEpoch(instant);
        const ordinal = @intFromEnum(day_of_week);
        if (ordinal == 0)
            return self;
        return LocalDate.fromEpoch(instant - ordinal * secs_per_day);
    }
};

pub fn getDaysInMonth(year: u16, month: u8) u8 {
    const leap_year_kind: epoch.YearLeapKind = if (epoch.isLeapYear(year))
        .leap
    else
        .not_leap;
    const month_enum = @as(epoch.Month, @enumFromInt(month));
    return epoch.getDaysInMonth(leap_year_kind, month_enum);
}

pub const LocalDateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    const Self = @This();

    pub fn fromEpoch(instant: i64) Self {
        const es = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(instant)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();

        return .{
            .year = yd.year,
            .month = md.month.numeric(),
            .day = md.day_index + 1,
            .hour = ds.getHoursIntoDay(),
            .minute = ds.getMinutesIntoHour(),
            .second = ds.getSecondsIntoMinute(),
        };
    }

    pub fn asString(self: Self) [19]u8 {
        var buf: [19]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
        }) catch unreachable;
        return buf;
    }
};

pub fn monthName(month: u8) []const u8 {
    return month_names[month - 1];
}

pub fn epochAtStartOfDay(instant: i64) i64 {
    const es = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(instant)) };
    const ds = es.getDaySeconds();
    return @as(i64, @intCast(instant - ds.secs));
}

pub fn daysBetween(a: i64, b: i64) u64 {
    std.debug.assert(b >= a);
    return @divFloor(@as(u64, @intCast(b - a)), secs_per_day) -| 1;
}

pub fn epochNow() i64 {
    return std.time.timestamp();
}

pub const Transition = struct {
    ts: i64,
    offset: i32,
};

pub fn initTimetype(allocator: Allocator) !void {
    switch (builtin.os.tag) {
        .windows => try initTimetypeWindows(allocator),
        else => try initTimetypePosix(allocator),
    }
}

pub fn initTimetypePosix(allocator: Allocator) !void {
    defer tz_init = true;
    var db = getUserTimeZoneDb(allocator) catch |err| switch (err) {
        error.FileNotFound => return, // Assume UTC
        else => return err,
    };
    defer db.deinit();
    var transitions_array = std.ArrayList(Transition).init(allocator);
    for (db.transitions) |t| {
        if (t.ts < instant_20220101) continue;
        try transitions_array.append(.{
            .ts = t.ts,
            .offset = t.timetype.offset,
        });
    }
    transitions = try transitions_array.toOwnedSlice();
}

pub fn initTimetypeWindows(allocator: Allocator) !void {
    defer tz_init = true;

    var tz: TIME_DYNAMIC_ZONE_INFORMATION = undefined;
    const result = GetDynamicTimeZoneInformation(&tz);
    if (result == TIME_ZONE_ID_INVALID ) {
        return error.InvalidTimezone;
    }

    var local_time: SYSTEMTIME = undefined;
    GetLocalTime(&local_time);

    var year: u16 = @intCast(start_year);
    const end_year = local_time.year + 1;
    var transitions_array = std.ArrayList(Transition).init(allocator);
    while (year <= end_year) : (year += 1) {
        try transitions_array.append(transitionFromTz("standard", tz, year));
        try transitions_array.append(transitionFromTz("daylight", tz, year));
    }

    const S = struct {
        fn order(_: void, a: Transition, b: Transition) bool {
            return a.ts < b.ts;
        }
    };
    std.sort.pdq(Transition, transitions_array.items, {}, S.order);
    transitions = try transitions_array.toOwnedSlice();
}

const TIME_ZONE_ID_INVALID: windows.DWORD = 0xffffffff;

// https://learn.microsoft.com/en-us/windows/win32/api/minwinbase/ns-minwinbase-systemtime
const SYSTEMTIME = extern struct {
    year: windows.WORD,
    month: windows.WORD,
    day_of_week: windows.WORD,
    day: windows.WORD,
    hour: windows.WORD,
    minute: windows.WORD,
    second: windows.WORD,
    milliseconds: windows.WORD,
};

// https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/ns-timezoneapi-dynamic_time_zone_information
const TIME_DYNAMIC_ZONE_INFORMATION = extern struct {
    bias: windows.LONG,
    standard_name: [32]windows.WCHAR,
    standard_date: SYSTEMTIME,
    standard_bias: windows.LONG,
    daylight_name: [32]windows.WCHAR,
    daylight_date: SYSTEMTIME,
    daylight_bias: windows.LONG,
    timezone_key_name: [128]windows.WCHAR,
    dynamic_daylight_time_disabled: bool,
};

pub extern "kernel32" fn GetLocalTime(ptr: *SYSTEMTIME) callconv(windows.WINAPI) void;
pub extern "kernel32" fn GetDynamicTimeZoneInformation(ptr: *TIME_DYNAMIC_ZONE_INFORMATION) callconv(windows.WINAPI) windows.DWORD;

fn transitionFromTz(comptime prefix: []const u8, tz: TIME_DYNAMIC_ZONE_INFORMATION, year: u16) Transition {
    const the_date = @field(tz, prefix ++ "_date");
    const first_half: LocalDate = .{
        .year = year,
        .month = @intCast(the_date.month),
        .day = @intCast(the_date.day),
        .local = true,
    };
    const ts = first_half.toEpoch() +
        (the_date.hour) * 60 * 60 +
        the_date.minute * 60 +
        the_date.second;
    const bias = @field(tz, prefix ++ "_bias");
    const offset = -(tz.bias - bias) * 60;
    return .{
        .ts = ts - offset,
        .offset = offset,
    };
}

// `initTimetype` MUST be called before any of these functions are used!

pub fn utcOffset(instant: i64) i64 {
    std.debug.assert(tz_init);
    std.debug.assert(instant > instant_20220101);
    if (transitions) |trans| {
        for (trans, 0..) |t, i| {
            if (t.ts > instant) {
                return trans[i - 1].offset;
            }
        }
    } else {
        return 0;
    }
    unreachable;
}

pub inline fn utcToLocal(instant: i64) i64 {
    return instant + utcOffset(instant);
}

pub inline fn localToUtc(instant: i64) i64 {
    return instant - utcOffset(instant);
}

pub fn localAtStartOfDay(instant: i64) i64 {
    return epochAtStartOfDay(utcToLocal(instant));
}

pub fn epochNowLocal() i64 {
    return utcToLocal(epochNow());
}

pub fn getUserTimeZoneDb(allocator: Allocator) !std.Tz {
    var etc = try std.fs.openDirAbsolute("/etc", .{});
    var tz_file = try etc.openFile("localtime", .{});
    defer tz_file.close();

    return std.Tz.parse(allocator, tz_file.reader());
}
