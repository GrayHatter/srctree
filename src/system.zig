pub const page_size_min = std.heap.page_size_min;
pub const MMapError = std.posix.MMapError;

pub const MMapOptions = struct {
    prot: u32 = std.posix.PROT.READ,
    flags: system.MAP = .{ .TYPE = .SHARED },
    offset: u64 = 0,
};

pub fn mmap(fd: fd_t, length: usize, options: MMapOptions) MMapError![]align(page_size_min) u8 {
    return std.posix.mmap(null, length, options.prot, options.flags, fd, options.offset);
}

pub fn munmap(ptr: []align(page_size_min) const u8) void {
    return std.posix.munmap(ptr);
}

const system = std.posix.system;
const fd_t = system.fd_t;

const std = @import("std");
