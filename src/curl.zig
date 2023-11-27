const std = @import("std");

const cURL = @cImport({
    @cInclude("curl/curl.h");
});

const Allocator = std.mem.Allocator;

pub const CURLResult = struct {
    code: u8,
    content_type: ?[]u8,
    body: ?[]u8,
};

pub fn curlRequest(a: Allocator, uri: []const u8) !CURLResult {
    if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
        return error.CURLGlobalInitFailed;
    defer cURL.curl_global_cleanup();

    var buffer = std.ArrayList(u8).init(a);
    defer buffer.deinit();
    var c_uri: [*:0]u8 = try a.allocSentinel(u8, uri.len, 0);
    @memcpy(c_uri[0..uri.len], uri);

    const handle = cURL.curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer cURL.curl_easy_cleanup(handle);
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEFUNCTION, curlWriteCB) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_WRITEDATA, &buffer) != cURL.CURLE_OK)
        return error.CouldNotSetWriteCallback;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_USERAGENT, "srctree/0.0 (diff-patch-request)") != cURL.CURLE_OK)
        return error.CouldNotSetUserAgent;
    if (cURL.curl_easy_setopt(handle, cURL.CURLOPT_URL, c_uri) != cURL.CURLE_OK)
        return error.CouldNotSetURL;
    if (cURL.curl_easy_perform(handle) != cURL.CURLE_OK)
        return error.FailedToPerformRequest;
    var rcode: c_long = 0;
    if (cURL.curl_easy_getinfo(handle, cURL.CURLINFO_RESPONSE_CODE, &rcode) != cURL.CURLE_OK)
        return error.FailedToGetResponseCode;
    var c_content_type: [*:0]u8 = undefined;
    if (cURL.curl_easy_getinfo(handle, cURL.CURLINFO_CONTENT_TYPE, &c_content_type) != cURL.CURLE_OK)
        return error.FailedToGetContentType;
    // TODO fail on wrong content type

    // std.debug.print("code {}\n", .{rcode});
    // std.debug.print("code {s}\n", .{c_content_type});
    return .{
        .code = @as(u8, @truncate(@as(usize, @intCast(rcode)))),
        .content_type = try a.dupe(u8, std.mem.span(c_content_type)),
        .body = try buffer.toOwnedSlice(),
    };
}

fn curlWriteCB(data: *anyopaque, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    var buffer: *std.ArrayList(u8) = @alignCast(@ptrCast(user_data));
    var typed_data: [*]u8 = @ptrCast(data);
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;
    return nmemb * size;
}
