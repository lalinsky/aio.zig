const std = @import("std");
const windows = std.os.windows;
const net = @import("../os/net.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;

pub const NetHandle = net.fd_t;

pub const supports_file_ops = true;

pub const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    refcount: usize = 0,
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    pub fn acquire(self: *SharedState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.refcount == 0) {
            // First loop - create IOCP handle
            self.iocp = try windows.CreateIoCompletionPort(
                windows.INVALID_HANDLE_VALUE,
                null,
                0,
                0, // Use default number of concurrent threads
            );
        }
        self.refcount += 1;
    }

    pub fn release(self: *SharedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.refcount > 0);
        self.refcount -= 1;

        if (self.refcount == 0) {
            // Last loop - close IOCP handle
            if (self.iocp != windows.INVALID_HANDLE_VALUE) {
                windows.CloseHandle(self.iocp);
                self.iocp = windows.INVALID_HANDLE_VALUE;
            }
        }
    }
};

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = net.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

// Backend-specific data types (all empty for now)
pub const NetRecvData = struct {};
pub const NetSendData = struct {};
pub const NetRecvFromData = struct {};
pub const NetSendToData = struct {};
pub const FileOpenData = struct {};
pub const FileCreateData = struct {};
pub const FileRenameData = struct {};
pub const FileDeleteData = struct {};

const Self = @This();

const log = std.log.scoped(.aio_iocp);

allocator: std.mem.Allocator,
shared_state: *SharedState,
entries: []windows.OVERLAPPED_ENTRY,
queue_size: u16,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    // Acquire reference to shared state (creates IOCP handle if first loop)
    try shared_state.acquire();
    errdefer shared_state.release();

    const entries = try allocator.alloc(windows.OVERLAPPED_ENTRY, queue_size);
    errdefer allocator.free(entries);

    self.* = .{
        .allocator = allocator,
        .shared_state = shared_state,
        .entries = entries,
        .queue_size = queue_size,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.entries);
    // Release reference to shared state (closes IOCP handle if last loop)
    self.shared_state.release();
}

pub fn wake(self: *Self) void {
    _ = self;
    @panic("TODO: wake()");
}

pub fn wakeFromAnywhere(self: *Self) void {
    _ = self;
    @panic("TODO: wakeFromAnywhere()");
}

pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    _ = self;
    _ = state;
    _ = c;
    @panic("TODO: submit()");
}

pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    _ = self;
    _ = state;
    _ = target;
    @panic("TODO: cancel()");
}

pub fn poll(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    _ = state;

    const timeout: u32 = std.math.cast(u32, timeout_ms) orelse std.math.maxInt(u32);

    var num_entries: u32 = 0;
    const result = windows.kernel32.GetQueuedCompletionStatusEx(
        self.shared_state.iocp,
        self.entries.ptr,
        @intCast(self.entries.len),
        &num_entries,
        timeout,
        windows.FALSE, // Not alertable
    );

    if (result == windows.FALSE) {
        const err = windows.kernel32.GetLastError();
        switch (err) {
            .WAIT_TIMEOUT => return true, // Timed out
            else => {
                log.err("GetQueuedCompletionStatusEx failed: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    // TODO: Process completions
    if (num_entries > 0) {
        log.debug("Received {} completion(s)", .{num_entries});
    }

    return false; // Did not timeout
}
