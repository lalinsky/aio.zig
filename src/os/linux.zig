const std = @import("std");
const posix = std.posix;

/// Create an eventfd for async notifications
pub fn eventfd(initval: u32, flags: u32) !i32 {
    const rc = std.os.linux.eventfd(initval, flags);
    if (rc < 0) {
        return switch (std.os.linux.getErrno(@intCast(-rc))) {
            .INVAL => error.InvalidFlags,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.NoDevice,
            .NOMEM => error.SystemResources,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    return @intCast(rc);
}

/// Read the eventfd counter (8 bytes)
pub fn eventfd_read(fd: i32) !u64 {
    var value: u64 = undefined;
    const bytes = std.mem.asBytes(&value);
    const n = try posix.read(fd, bytes);
    if (n != 8) return error.UnexpectedReadSize;
    return value;
}

/// Write to the eventfd counter (8 bytes)
pub fn eventfd_write(fd: i32, value: u64) !void {
    const bytes = std.mem.asBytes(&value);
    _ = try posix.write(fd, bytes);
}

/// Eventfd flags
pub const EFD = struct {
    pub const CLOEXEC = std.os.linux.EFD.CLOEXEC;
    pub const NONBLOCK = std.os.linux.EFD.NONBLOCK;
    pub const SEMAPHORE = std.os.linux.EFD.SEMAPHORE;
};

/// Extended arguments for io_uring_enter2 with IORING_ENTER_EXT_ARG
pub const io_uring_getevents_arg = extern struct {
    sigmask: u64 = 0,
    sigmask_sz: u32 = 0,
    pad: u32 = 0,
    ts: u64 = 0,
};

/// io_uring_enter2 syscall (kernel 5.11+)
/// This version supports extended arguments including timeout
pub fn io_uring_enter2(
    fd: i32,
    to_submit: u32,
    min_complete: u32,
    flags: u32,
    arg: ?*const io_uring_getevents_arg,
    argsz: usize,
) !u32 {
    const linux = std.os.linux;
    const SYS_io_uring_enter = 426; // syscall number for io_uring_enter2

    const rc = linux.syscall6(
        @enumFromInt(SYS_io_uring_enter),
        @as(usize, @bitCast(@as(isize, fd))),
        to_submit,
        min_complete,
        flags,
        @intFromPtr(arg),
        argsz,
    );

    return switch (linux.E.init(rc)) {
        .SUCCESS => @intCast(rc),
        .TIME => 0, // Timeout expired - this is normal, return 0 completions
        .AGAIN => error.WouldBlock,
        .BADF => error.FileDescriptorInvalid,
        .BUSY => error.DeviceBusy,
        .FAULT => error.InvalidAddress,
        .INTR => error.SignalInterrupt,
        .INVAL => error.SubmissionQueueEntryInvalid,
        .OPNOTSUPP => error.OpcodeNotSupported,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}
