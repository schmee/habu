const std = @import("std");
const epoch = std.time.epoch;

const Allocator = std.mem.Allocator;

pub const secs_per_day: i64 = 60 * 60 * 24;
pub const max_weeks_per_year: u8 = 53;

const Weekday = enum(u3) {
    mon = 0,
    tue,
    wed,
    thu,
    fri,
    sat,
    sun,
};

const weekday_20220101: Weekday = .sat;
const instant_20220101: i64 = 1640995200;

var tz_init: bool = false;
var transitions: ?[]const std.tz.Transition = null;

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

    pub fn parse(yyyymmdd: []const u8) !Self {
        if (yyyymmdd.len != 8) return error.BadFormat;

        const year = std.fmt.parseInt(u16, yyyymmdd[0..4], 10) catch |err| switch (err) {
            error.Overflow => unreachable, // all four-digit numbers fit into a u16
            else => |e| return e,
        };
        if (year < 2022) return error.YearBefore2022;

        const month = std.fmt.parseInt(u8, yyyymmdd[4..6], 10) catch |err| switch (err) {
            error.Overflow => unreachable, // all two-digit numbers fit into a u8
            else => |e| return e,
        };
        if (month < 1 or month > 12) return error.MonthOutOfRange;

        const leap_year_kind = if (epoch.isLeapYear(year)) epoch.YearLeapKind.leap else epoch.YearLeapKind.not_leap;
        const days_in_month = epoch.getDaysInMonth(leap_year_kind, @as(epoch.Month, @enumFromInt(month)));
        const day = std.fmt.parseInt(u8, yyyymmdd[6..8], 10) catch |err| switch (err) {
            error.Overflow => unreachable, // all two-digit numbers fit into a u8
            else => |e| return e,
        };

        if (day > days_in_month) return error.DayOutOfRange;

        return .{
            .year = year,
            .month = month,
            .day = day,
            .local = true,
        };
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
        var m: u16 = 1;
        const leap_year_kind = if (epoch.isLeapYear(self.year)) epoch.YearLeapKind.leap else epoch.YearLeapKind.not_leap;
        while (m < self.month) : (m += 1) {
            instant += epoch.getDaysInMonth(leap_year_kind, @as(epoch.Month, @enumFromInt(m))) * secs_per_day;
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

pub fn initTimetype(allocator: Allocator) !void {
    const timezones: ?std.Tz = getUserTimeZoneDb(allocator) catch |err| switch (err) {
        error.FileNotFound => null, // Assume UTC
        else => return err,
    };
    if (timezones) |tz| {
        for (tz.transitions, 0..) |t, i| {
            if (t.ts > instant_20220101) {
                transitions = tz.transitions[i - 1 ..];
                break;
            }
        }
    }
    tz_init = true;
}

// `initTimetype` MUST be called before any of these functions are used!

fn utcOffset(instant: i64) i64 {
    std.debug.assert(tz_init);
    std.debug.assert(instant > instant_20220101);
    if (transitions) |trans| {
        for (trans, 0..) |t, i| {
            if (t.ts > instant) {
                return trans[i - 1].timetype.offset;
            }
        }
    } else {
        return 0;
    }
    unreachable;
}

pub inline fn utcToLocal(instant: i64) i64 {
    std.debug.assert(tz_init);
    return instant + utcOffset(instant);
}

pub inline fn localToUtc(instant: i64) i64 {
    std.debug.assert(tz_init);
    return instant - utcOffset(instant);
}

pub fn localAtStartOfDay(instant: i64) i64 {
    return epochAtStartOfDay(utcToLocal(instant));
}

pub fn epochNowLocal() i64 {
    std.debug.assert(tz_init);
    return utcToLocal(epochNow());
}

pub fn getUserTimeZoneDb(allocator: Allocator) !std.Tz {
    var etc = try std.fs.openDirAbsolute("/etc", .{});
    var tz_file = try etc.openFile("localtime", .{});
    defer tz_file.close();

    return std.Tz.parse(allocator, tz_file.reader());
}
