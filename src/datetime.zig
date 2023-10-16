const std = @import("std");

const DateTime = @This();

timestamp: i64,
years: usize,
months: u8,
days: u8,
hours: u8,
minutes: u8,
seconds: u8,
tz: ?i8 = null,

const DAYS_IN_MONTH = [_]u8{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

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

pub fn fromEpoch(sts: i64) !DateTime {
    if (sts < 0) return error.UnsupportedTimeStamp;
    const ts: u64 = @intCast(sts);

    var self: DateTime = undefined;
    self.timestamp = sts;

    self.seconds = @truncate(ts % 60);
    self.minutes = @truncate(ts / 60 % 60);
    self.hours = @truncate(ts / 60 / 60 % 24);

    self.years = yearsFrom(ts);
    var days = 719162 + ts / 60 / 60 / 24 - daysAtYear(self.years);
    const both = monthsFrom(self.years, days);
    self.months = both[0];
    self.days = @truncate(both[1] + 1);

    self.tz = null;

    return self;
}

pub fn fromEpochStr(str: []const u8) !DateTime {
    var int = try std.fmt.parseInt(i64, str, 10);
    return fromEpoch(int);
}

pub fn format(self: DateTime, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    return out.print("{}-{}-{} {:0>2}:{:0>2}:{:0>2}", .{
        self.years,
        self.months,
        self.days,
        self.hours,
        self.minutes,
        self.seconds,
    });
}

test "datetime" {
    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1697312998,
        .years = 2023,
        .months = 10,
        .days = 14,
        .hours = 19,
        .minutes = 49,
        .seconds = 58,
    }, try DateTime.fromEpoch(1697312998));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148799,
        .years = 1998,
        .months = 12,
        .days = 31,
        .hours = 23,
        .minutes = 59,
        .seconds = 59,
    }, try DateTime.fromEpoch(915148799));
    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148800,
        .years = 1999,
        .months = 1,
        .days = 1,
        .hours = 0,
        .minutes = 0,
        .seconds = 0,
    }, try DateTime.fromEpoch(915148800));
}
