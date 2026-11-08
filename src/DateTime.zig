// Default to Unix Epoch
timestamp: i96,
year: Year,
month: Month,
day: Day,
weekday: u8,
hour: u8,
minute: u8,
second: u8,
tz: ?Tz = null,

flags: Flags = .default,

const DateTime = @This();

pub const unix_epoch: DateTime = .{
    .timestamp = 0,
    .year = .unix_epoch,
    .month = 1,
    .day = 1,
    .weekday = 4,
    .hour = 0,
    .minute = 0,
    .second = 0,
    .tz = null,
    .flags = .default,
};

// TODO fix to i64
pub const Year = enum(u64) {
    unix_epoch = 1970,
    _,
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

pub const Tz = packed struct(i96) {
    /// Timezone offset in seconds
    /// -1200h...1200h
    /// -43200...43200
    seconds: i96,

    pub const zero: Tz = .{ .seconds = 0 };

    pub const Minutes = i96;
    pub const Hours = i96;

    pub fn fromStr(str: []const u8) !Tz {
        const tzm: Minutes = try std.fmt.parseInt(Minutes, str[str.len - 2 .. str.len], 10);
        const tzh: Hours = try std.fmt.parseInt(Hours, str[0 .. str.len - 2], 10);
        var secs: i96 = tzh;
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

pub const Scale = struct {
    seconds: i96 = 0,

    pub fn secs(s: i96) Scale {
        return .{
            .seconds = s,
        };
    }

    pub fn mins(m: i96) Scale {
        return .{
            .seconds = m * 60,
        };
    }

    pub fn hours(h: i96) Scale {
        return .{
            .seconds = h * 3600,
        };
    }

    pub fn days(d: i96) Scale {
        return .{
            .seconds = d * 86400,
        };
    }
};

pub fn tzAdjusted(dt: DateTime) i96 {
    const tz: Tz = dt.tz orelse .zero;
    return dt.timestamp + tz.seconds;
}

pub fn now(io: std.Io) DateTime {
    return fromEpoch(std.Io.Clock.real.now(io).toSeconds());
}

pub fn today(io: std.Io) DateTime {
    var self = now(io);
    self.truncateTime();
    return self;
}

pub fn truncateTime(time: *DateTime) void {
    const new_offset = @as(i64, time.hour) * 3600 + @as(i64, time.minute) * 60 + time.second;
    time.timestamp -|= new_offset;
    time.hour = 0;
    time.minute = 0;
    time.second = 0;
    time.flags.has_time = false;
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
    return .{ @fromBackingInt(@intCast(m)), @fromBackingInt(@intCast(d)) };
}

pub fn currentMonth() []const u8 {
    const n = now();
    return Names.Month[n.month];
}

pub fn monthSlice(self: DateTime) []const u8 {
    return Names.Month[@backingInt(self.month)];
}

pub fn weekdaySlice(self: DateTime) []const u8 {
    return Names.Day[self.weekday];
}

pub fn fromEpochTz(sts: i96, tzz: ?Tz) DateTime {
    if (sts < 0) unreachable; // return error.UnsupportedTimeStamp;

    const tz: Tz = tzz orelse .zero;
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
        .year = @fromBackingInt(years),
        .month = month,
        .day = month_day,
        .weekday = weekday,
        .hour = hours,
        .minute = minutes,
        .second = seconds,
    };
}

pub fn fromEpoch(sts: i96) DateTime {
    const ts = fromEpochTz(sts, null);
    return ts;
}

/// Accepts a Unix Epoch int as a string of numbers
pub fn fromEpochStr(str: []const u8) !DateTime {
    const int = try std.fmt.parseInt(i64, str, 10);
    return fromEpoch(int);
}

/// Accepts a Unix Epoch in seconds and timezone in -HHMM format
pub fn fromEpochTzStr(epoch: i96, tzstr: []const u8) !DateTime {
    const tz: Tz = try .fromStr(tzstr);
    return fromEpochTz(epoch, tz);
}

/// Accepts a Unix Epoch int as a string of numbers and timezone in -HHMM format
pub fn fromEpochStrTzStr(str: []const u8, tzstr: []const u8) !DateTime {
    const epoch = try std.fmt.parseInt(i64, str, 10);
    const tz: ?Tz = .fromStr(tzstr) catch |err| if (err) return err else null;
    return fromEpochTz(epoch, tz);
}

pub fn add(datetime: *DateTime, scale: Scale) void {
    const new: i96 = datetime.timestamp + scale.seconds;
    datetime.* = .fromEpoch(new);
}

pub fn sub(datetime: *DateTime, scale: Scale) void {
    const new: i96 = datetime.timestamp - scale.seconds;
    datetime.* = .fromEpoch(new);
}

pub fn fmtTime(self: DateTime, w: *Writer) !void {
    return w.print(
        "{:0>2}:{:0>2}:{:0>2}",
        .{ self.hour, self.minute, self.second },
    );
}

pub fn fmtDay(self: DateTime, w: *Writer) !void {
    return w.print(
        "{s}",
        .{self.weekdaySlice()},
    );
}

pub fn fmtYMD(self: DateTime, w: *Writer) !void {
    return w.print(
        "{d}-{:0>2}-{:0>2}",
        .{ @backingInt(self.year), @backingInt(self.month), @backingInt(self.day) },
    );
}

pub fn fmtDTime(self: DateTime, w: *Writer) !void {
    return w.print(
        "{s} {:0>2}:{:0>2}:{:0>2}",
        .{ Names.Day[self.weekday], self.hour, self.minute, self.second },
    );
}

pub fn format(self: DateTime, w: *Writer) !void {
    if (self.flags.has_date) {
        try w.print(
            "{d}-{d:0>2}-{d:0>2} {s}",
            .{ @backingInt(self.year), @backingInt(self.month), @backingInt(self.day), Names.Day[self.weekday] },
        );
    }

    if (self.flags.has_date and self.flags.has_time) try w.writeByte(' ');

    if (self.flags.has_time) {
        try w.print(
            "{:0>2}:{:0>2}:{:0>2}",
            .{ self.hour, self.minute, self.second },
        );
    }
}

test format {
    const now_ish: DateTime = .fromEpoch(1794092808);
    var b: [200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    try now_ish.format(&w);
    try std.testing.expectEqualStrings("2026-11-07 Saturday 23:06:48", w.buffered());
}

pub fn fromActor(actor: Actor) !DateTime {
    return .fromEpochTzStr(actor.timestamp, actor.tzstr);
}

pub fn fromActorAdj(actor: Actor) !i96 {
    return (try fromEpochTzStr(actor.timestamp, actor.tzstr)).tzAdjusted();
}

test "now" {
    const timestamp = std.Io.Clock.real.now(std.testing.io);
    // If this breaks, I know... I KNOW, non-deterministic tests... and I'm sorry!
    const this = now(std.testing.io);
    try std.testing.expectEqual(timestamp.toSeconds(), this.timestamp);
}

test "today" {
    const this = now(std.testing.io);
    const today_ = today(std.testing.io);
    try std.testing.expectEqual(this.year, today_.year);
    try std.testing.expectEqual(this.month, today_.month);
    try std.testing.expectEqual(this.day, today_.day);
    try std.testing.expectEqual(this.weekday, today_.weekday);
    try std.testing.expectEqual(today_.hour, 0);
    try std.testing.expectEqual(today_.minute, 0);
    try std.testing.expectEqual(today_.second, 0);
}

test "datetime" {
    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 0,
        .year = @fromBackingInt(1970),
        .month = @fromBackingInt(1),
        .day = @fromBackingInt(1),
        .weekday = 4,
        .hour = 0,
        .minute = 0,
        .second = 0,
    }, DateTime.fromEpoch(0));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1697312998,
        .year = @fromBackingInt(2023),
        .month = @fromBackingInt(10),
        .day = @fromBackingInt(14),
        .weekday = 6,
        .hour = 19,
        .minute = 49,
        .second = 58,
    }, DateTime.fromEpoch(1697312998));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148799,
        .year = @fromBackingInt(1998),
        .month = @fromBackingInt(12),
        .day = @fromBackingInt(31),
        .weekday = 4,
        .hour = 23,
        .minute = 59,
        .second = 59,
    }, DateTime.fromEpoch(915148799));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 915148800,
        .year = @fromBackingInt(1999),
        .month = @fromBackingInt(1),
        .day = @fromBackingInt(1),
        .weekday = 5,
        .hour = 0,
        .minute = 0,
        .second = 0,
    }, DateTime.fromEpoch(915148800));

    try std.testing.expectEqualDeep(DateTime{
        .timestamp = 1002131014,
        .year = @fromBackingInt(2001),
        .month = @fromBackingInt(10),
        .day = @fromBackingInt(3),
        .weekday = 3,
        .hour = 17,
        .minute = 43,
        .second = 34,
    }, DateTime.fromEpoch(1002131014));
}

const std = @import("std");
const Writer = std.Io.Writer;
const eql = std.mem.eql;
const Actor = @import("git/Actor.zig");
