// Default to Unix Epoch
timestamp: i64,
year: usize,
month: Month,
day: Day,
weekday: u3,
hours: u6,
minutes: u6,
seconds: u6,
tz: ?Tz = null,

flags: Flags = .default,

const DateTime = @This();

pub const unix_epoch: DateTime = .{
    .timestamp = 0,
    .years = 1970,
    .month = 1,
    .day = 1,
    .weekday = 4,
    .hours = 0,
    .minutes = 0,
    .seconds = 0,
    .tz = null,
    .flags = .default,
};

pub const Month = enum(u4) {
    undefined,
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
};

pub const Day = enum(u5) {
    undefined,
    _,
};

pub const Weekday = enum(u3) {
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
};

pub const Tz = packed struct(i17) {
    /// Timezone offset in seconds
    /// -1200h -> 1200h
    /// -43200 -> 43200
    seconds: i17,

    pub const Minutes = i11;
    pub const Hours = i5;

    pub fn fromStr(str: []const u8) !Tz {
        const tzm: Minutes = try std.fmt.parseInt(Minutes, str[str.len - 2 .. str.len], 10);
        const tzh: Hours = try std.fmt.parseInt(Hours, str[0 .. str.len - 2], 10);
        var secs: i17 = tzh;
        secs *= 60;
        secs += tzm;
        secs *= 60;
        return .{ .seconds = secs };
    }
};

pub const Flags = struct {
    has_date: bool,
    has_time: bool,

    pub const default: Flags = .{
        .has_date = true,
        .has_time = true,
    };
};

/// 1 Indexed (index 0 == 0) because Date formatting month start at 1
pub const day_IN_MONTH = [_]u8{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

pub const Names = struct {
    /// 1 Indexed (index 0 == undefined) because Date formatting month start at 1
    pub const Month = [_][]const u8{
        undefined,
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

    pub const Day = [_][]const u8{
        "Sunday",
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
    };
};

pub fn now() DateTime {
    return fromEpoch(std.time.timestamp());
}

pub fn today() DateTime {
    var self = now();
    return self.timeTruncate();
}

pub fn timeTruncate(self: DateTime) DateTime {
    var output = self;
    const offset = @as(i64, self.hours) * 60 * 60 + @as(i64, self.minutes) * 60 + self.seconds;
    output.timestamp -|= offset;
    output.hours = 0;
    output.minutes = 0;
    output.seconds = 0;
    output.flags.has_time = false;
    return output;
}

fn leapYear(year: usize) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn leapday(year: usize) u9 {
    if (leapYear(year)) return 366;
    return 365;
}

fn dayAtYear(year: usize) usize {
    const y = year - 1;
    return y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
}

test "dby" {
    try std.testing.expectEqual(@as(usize, 1461), dayAtYear(5));
    try std.testing.expectEqual(@as(usize, 36524), dayAtYear(101));
    try std.testing.expectEqual(@as(usize, 146097), dayAtYear(401));
    try std.testing.expectEqual(@as(usize, 719162), dayAtYear(1970));
}

fn yearsFrom(epoch: usize) usize {
    const day = epoch / 60 / 60 / 24 + 719162;
    var year = day / 365;
    while (day < dayAtYear(year)) year -= 1;
    std.debug.assert(day >= dayAtYear(year));
    return year;
}

fn monthFrom(year: usize, day: usize) struct { Month, Day } {
    std.debug.assert(day <= 366);
    var m: u8 = 1;
    var d: usize = day;
    if (d > 60 and leapYear(year)) {
        d -= 1; // LOL
    }
    while (d > day_IN_MONTH[m]) {
        d -= day_IN_MONTH[m];
        m += 1;
    }
    return .{ @enumFromInt(m), @enumFromInt(d) };
}

pub fn currentMonth() []const u8 {
    const n = now();
    return Names.Month[n.month];
}

pub fn monthSlice(self: DateTime) []const u8 {
    return Names.Month[self.month];
}

pub fn weekdaySlice(self: DateTime) []const u8 {
    return Names.Day[self.weekday];
}

pub fn fromEpochTz(sts: i64, tzz: ?Tz) DateTime {
    if (sts < 0) unreachable; // return error.UnsupportedTimeStamp;

    const tz: Tz = tzz orelse .{ .seconds = 0 };
    const ts: u64 = @intCast(sts + tz.seconds);

    const seconds: u6 = @truncate(ts % 60);
    const minutes: u6 = @truncate(ts / 60 % 60);
    const hours: u6 = @truncate(ts / 60 / 60 % 24);

    const years: usize = yearsFrom(ts);
    const weekday: u3 = @truncate((ts / 60 / 60 / 24 + 4) % 7);

    const day = 719162 + ts / 60 / 60 / 24 - dayAtYear(years);
    const month, const month_day = monthFrom(years, day + 1);

    return .{
        .timestamp = sts,
        .tz = if (tzz) |_| tz else null,
        .year = years,
        .month = month,
        .day = month_day,
        .weekday = weekday,
        .hours = hours,
        .minutes = minutes,
        .seconds = seconds,
    };
}

pub fn fromEpoch(sts: i64) DateTime {
    const ts = fromEpochTz(sts, null);
    return ts;
}

/// Accepts a Unix Epoch int as a string of numbers
pub fn fromEpochStr(str: []const u8) !DateTime {
    const int = try std.fmt.parseInt(i64, str, 10);
    return fromEpoch(int);
}

/// Accepts a Unix Epoch int as a string of numbers and timezone in -HHMM format
pub fn fromEpochTzStr(str: []const u8, tzstr: []const u8) !DateTime {
    const epoch = try std.fmt.parseInt(i64, str, 10);
    const tz: Tz = try .fromStr(tzstr);
    return fromEpochTz(epoch, tz);
}

pub fn format(self: DateTime, comptime fstr: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    if (comptime eql(u8, fstr, "dtime")) {
        return out.print(
            "{s} {:0>2}:{:0>2}:{:0>2}",
            .{ Names.Day[self.weekday], self.hours, self.minutes, self.seconds },
        );
    } else if (comptime eql(u8, fstr, "day")) {
        return out.print(
            "{s}",
            .{self.weekdaySlice()},
        );
    } else if (comptime eql(u8, fstr, "time") or eql(u8, fstr, "HH:mm:ss")) {
        return out.print(
            "{:0>2}:{:0>2}:{:0>2}",
            .{ self.hours, self.minutes, self.seconds },
        );
    } else if (comptime eql(u8, fstr, "Y-m-d")) {
        return out.print(
            "{}-{:0>2}-{:0>2}",
            .{ self.year, @intFromEnum(self.month), @intFromEnum(self.day) },
        );
    }

    if (self.flags.has_date) {
        try out.print(
            "{}-{:0>2}-{:0>2} {s}",
            .{ self.year, @intFromEnum(self.month), @intFromEnum(self.day), Names.Day[self.weekday] },
        );
    }
    if (self.flags.has_time) {
        try out.print(
            "{:0>2}:{:0>2}:{:0>2}",
            .{ self.hours, self.minutes, self.seconds },
        );
    }
}

test "now" {
    const timestamp = std.time.timestamp();
    // If this breaks, I know... I KNOW, non-deterministic tests... and I'm sorry!
    const this = now();
    try std.testing.expectEqual(timestamp, this.timestamp);
}

test "today" {
    const this = now();
    const today_ = today();
    try std.testing.expectEqual(this.year, today_.year);
    try std.testing.expectEqual(this.month, today_.month);
    try std.testing.expectEqual(this.day, today_.day);
    try std.testing.expectEqual(this.weekday, today_.weekday);
    try std.testing.expectEqual(today_.hours, 0);
    try std.testing.expectEqual(today_.minutes, 0);
    try std.testing.expectEqual(today_.seconds, 0);
}

test "datetime" {
    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 0,
        .year = 1970,
        .month = @enumFromInt(1),
        .day = @enumFromInt(1),
        .weekday = 4,
        .hours = 0,
        .minutes = 0,
        .seconds = 0,
    }, DateTime.fromEpoch(0));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1697312998,
        .year = 2023,
        .month = @enumFromInt(10),
        .day = @enumFromInt(14),
        .weekday = 6,
        .hours = 19,
        .minutes = 49,
        .seconds = 58,
    }, DateTime.fromEpoch(1697312998));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148799,
        .year = 1998,
        .month = @enumFromInt(12),
        .day = @enumFromInt(31),
        .weekday = 4,
        .hours = 23,
        .minutes = 59,
        .seconds = 59,
    }, DateTime.fromEpoch(915148799));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148800,
        .year = 1999,
        .month = @enumFromInt(1),
        .day = @enumFromInt(1),
        .weekday = 5,
        .hours = 0,
        .minutes = 0,
        .seconds = 0,
    }, DateTime.fromEpoch(915148800));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1002131014,
        .year = 2001,
        .month = @enumFromInt(10),
        .day = @enumFromInt(3),
        .weekday = 3,
        .hours = 17,
        .minutes = 43,
        .seconds = 34,
    }, DateTime.fromEpoch(1002131014));
}

const std = @import("std");
const eql = std.mem.eql;
