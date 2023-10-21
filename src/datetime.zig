const std = @import("std");

const DateTime = @This();

// Default to Unix Epoch
timestamp: i64 = 0,
years: usize = 1970,
months: u8 = 1,
days: u8 = 1,
weekday: u8 = 4,
hours: u8 = 0,
minutes: u8 = 0,
seconds: u8 = 0,
tz: ?i16 = null, // -1200 -> 1200

/// 1 Indexed (index 0 == 0) because Date formatting months start at 1
pub const DAYS_IN_MONTH = [_]u8{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

/// 1 Indexed (index 0 == undefined) because Date formatting months start at 1
pub const MONTHS = [_][]const u8{
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

pub const WEEKDAYS = [_][]const u8{
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
};

pub fn now() DateTime {
    return fromEpoch(std.time.timestamp()) catch unreachable;
}

pub fn today() DateTime {
    var self = now();
    self.hours = 0;
    self.minutes = 0;
    self.seconds = 0;
    return self;
}

fn leapYear(year: usize) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn leapDays(year: usize) u9 {
    if (leapYear(year)) return 366;
    return 365;
}

fn daysAtYear(year: usize) usize {
    const y = year - 1;
    return y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
}

test "dby" {
    try std.testing.expectEqual(@as(usize, 1461), daysAtYear(5));
    try std.testing.expectEqual(@as(usize, 36524), daysAtYear(101));
    try std.testing.expectEqual(@as(usize, 146097), daysAtYear(401));
    try std.testing.expectEqual(@as(usize, 719162), daysAtYear(1970));
}

fn yearsFrom(epoch: usize) usize {
    const days = epoch / 60 / 60 / 24 + 719162;
    var year = days / 365;
    while (days < daysAtYear(year)) year -= 1;
    std.debug.assert(days >= daysAtYear(year));
    return year;
}

fn monthsFrom(year: usize, days: usize) struct { u8, usize } {
    std.debug.assert(days <= 366);
    var m: u8 = 1;
    var d: usize = days;
    if (d >= 60 and leapYear(year)) {
        d -= 1; // LOL
    }
    while (d > DAYS_IN_MONTH[m]) {
        d -= DAYS_IN_MONTH[m];
        m += 1;
    }
    return .{ m, d };
}

pub fn fromEpochTz(sts: i64, tz: ?i16) !DateTime {
    if (sts < 0) return error.UnsupportedTimeStamp;

    var self: DateTime = undefined;
    self.timestamp = sts;
    self.tz = tz;

    const ts: u64 = @intCast(sts + (tz orelse 0) * 60);

    self.seconds = @truncate(ts % 60);
    self.minutes = @truncate(ts / 60 % 60);
    self.hours = @truncate(ts / 60 / 60 % 24);

    self.years = yearsFrom(ts);
    self.weekday = @truncate((ts / 60 / 60 / 24 + 4) % 7);

    var days = 719162 + ts / 60 / 60 / 24 - daysAtYear(self.years);
    const both = monthsFrom(self.years, days);
    self.months = both[0];
    self.days = @truncate(both[1] + 1);

    return self;
}

pub fn fromEpoch(sts: i64) !DateTime {
    var ts = try fromEpochTz(sts, null);
    return ts;
}

/// Accepts a Unix Epoch int as a string of numbers
pub fn fromEpochStr(str: []const u8) !DateTime {
    var int = try std.fmt.parseInt(i64, str, 10);
    return fromEpoch(int);
}

/// Accepts a Unix Epoch int as a string of numbers and timezone in -HHMM format
pub fn fromEpochTzStr(str: []const u8, tzstr: []const u8) !DateTime {
    var epoch = try std.fmt.parseInt(i64, str, 10);
    const tzm = try std.fmt.parseInt(i16, tzstr[tzstr.len - 2 .. tzstr.len], 10);
    const tzh = try std.fmt.parseInt(i16, tzstr[0 .. tzstr.len - 2], 10);
    const tz = tzh * 60 + tzm;
    return fromEpochTz(epoch, tz);
}

pub fn format(self: DateTime, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    return out.print("{}-{}-{} {s} {:0>2}:{:0>2}:{:0>2}", .{
        self.years,
        self.months,
        self.days,
        WEEKDAYS[self.weekday],
        self.hours,
        self.minutes,
        self.seconds,
    });
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
    try std.testing.expectEqual(this.years, today_.years);
    try std.testing.expectEqual(this.months, today_.months);
    try std.testing.expectEqual(this.days, today_.days);
    try std.testing.expectEqual(this.weekday, today_.weekday);
    try std.testing.expectEqual(today_.hours, 0);
    try std.testing.expectEqual(today_.minutes, 0);
    try std.testing.expectEqual(today_.seconds, 0);
}

test "datetime" {
    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 0,
        .years = 1970,
        .months = 1,
        .days = 1,
        .weekday = 4,
        .hours = 0,
        .minutes = 0,
        .seconds = 0,
    }, try DateTime.fromEpoch(0));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1697312998,
        .years = 2023,
        .months = 10,
        .days = 14,
        .weekday = 6,
        .hours = 19,
        .minutes = 49,
        .seconds = 58,
    }, try DateTime.fromEpoch(1697312998));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148799,
        .years = 1998,
        .months = 12,
        .days = 31,
        .weekday = 4,
        .hours = 23,
        .minutes = 59,
        .seconds = 59,
    }, try DateTime.fromEpoch(915148799));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148800,
        .years = 1999,
        .months = 1,
        .days = 1,
        .weekday = 5,
        .hours = 0,
        .minutes = 0,
        .seconds = 0,
    }, try DateTime.fromEpoch(915148800));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1002131014,
        .years = 2001,
        .months = 10,
        .days = 3,
        .weekday = 3,
        .hours = 17,
        .minutes = 43,
        .seconds = 34,
    }, try DateTime.fromEpoch(1002131014));
}
