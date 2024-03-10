const std = @import("std");
const DT = @import("datetime.zig");

pub const Humanize = @This();

seconds: i64,

pub const Width = enum {
    seconds,
    minutes,
    hours,
    days,
    weeks,
    months,
    years,
    decades,
    centuries,
    millenia,
    you_broke_time_itself,
};

const MINS_2 = 120;
const HOURS_2 = MINS_2 * 60;
const DAYS_2 = HOURS_2 * 24;
const WEEKS_2 = 1209600;
const MONTHS_2 = 5270400; // 61 days
const YEARS_2 = 45792000;
const DECADES_2 = YEARS_2 * 10;
const CENTURIES_2 = DECADES_2 * 10;
const MILLENIA_2 = CENTURIES_2 * 10;

pub fn unix(time: i64) Humanize {
    return .{
        .seconds = time - std.time.timestamp(),
    };
}

pub fn delta(origin: i64, diff: i64) Humanize {
    return .{
        .seconds = diff - origin,
    };
}

fn abs(in: i64) i64 {
    return @intCast(@abs(in));
}

fn width(self: Humanize) Width {
    if (abs(self.seconds) < MINS_2) return .seconds;
    if (abs(self.seconds) < HOURS_2) return .minutes;
    if (abs(self.seconds) < DAYS_2) return .hours;
    if (abs(self.seconds) < WEEKS_2) return .days;
    if (abs(self.seconds) < MONTHS_2) return .weeks;
    if (abs(self.seconds) < YEARS_2) return .months;
    if (abs(self.seconds) < DECADES_2) return .years;
    if (abs(self.seconds) < CENTURIES_2) return .decades;
    if (abs(self.seconds) < MILLENIA_2) return .centuries;
    return .you_broke_time_itself;
}

fn reduced(self: Humanize) i16 {
    return @truncate(abs(switch (self.width()) {
        .seconds => self.seconds,
        .minutes => @divTrunc(self.seconds, 60),
        .hours => @divTrunc(self.seconds, 60 * 60),
        .days => @divTrunc(self.seconds, 60 * 60 * 24),
        .weeks => @divTrunc(self.seconds, 60 * 60 * 24 * 7),
        .months => @divTrunc(self.seconds, 60 * 60 * 24 * 30),
        .years => @divTrunc(self.seconds, 60 * 60 * 24 * 365),
        .decades => @divTrunc(self.seconds, 60 * 60 * 24 * 3650),
        .centuries => @divTrunc(self.seconds, 60 * 60 * 24 * 36500),
        .millenia => @divTrunc(self.seconds, 60 * 60 * 24 * 365000),
        .you_broke_time_itself => 0,
    }));
}

pub fn format(self: Humanize, comptime f: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    if (f.len > 0) return error.NotImplemented;

    if (self.seconds < 0) {
        try out.print("{} {s} ago", .{ self.reduced(), @tagName(self.width()) });
    } else {
        try out.print("{} {s} in the future", .{ self.reduced(), @tagName(self.width()) });
    }
}

pub fn printAlloc(self: Humanize, a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "{}", .{self});
}
