const std = @import("std");
const windows = std.os.windows;
const net = @import("../os/net.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;

// Winsock extension function GUIDs
const WSAID_ACCEPTEX = windows.GUID{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSAID_CONNECTEX = windows.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

// Winsock extension function types
const LPFN_ACCEPTEX = *const fn (
    sListenSocket: windows.ws2_32.SOCKET,
    sAcceptSocket: windows.ws2_32.SOCKET,
    lpOutputBuffer: *anyopaque,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    lpdwBytesReceived: *windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

const LPFN_CONNECTEX = *const fn (
    s: windows.ws2_32.SOCKET,
    name: *const windows.ws2_32.sockaddr,
    namelen: c_int,
    lpSendBuffer: ?*const anyopaque,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: ?*windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

const SIO_GET_EXTENSION_FUNCTION_POINTER = windows.ws2_32._WSAIORW(windows.ws2_32.IOC_WS2, 6);

fn loadWinsockExtension(comptime T: type, sock: windows.ws2_32.SOCKET, guid: windows.GUID) !T {
    var func_ptr: T = undefined;
    var bytes: windows.DWORD = 0;

    const rc = windows.ws2_32.WSAIoctl(
        sock,
        SIO_GET_EXTENSION_FUNCTION_POINTER,
        @constCast(&guid),
        @sizeOf(windows.GUID),
        &func_ptr,
        @sizeOf(T),
        &bytes,
        null,
        null,
    );

    if (rc != 0) {
        return error.Unexpected;
    }

    return func_ptr;
}

pub const NetHandle = net.fd_t;

pub const supports_file_ops = true;

const ExtensionFunctions = struct {
    acceptex: LPFN_ACCEPTEX,
    connectex: LPFN_CONNECTEX,
};

pub const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    refcount: usize = 0,
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    // Cache of extension function pointers per address family
    // Key: address family (AF_INET, AF_INET6), Value: ExtensionFunctions
    // AcceptEx/ConnectEx are STREAM-only, so family is sufficient
    extension_cache: std.AutoHashMapUnmanaged(u16, ExtensionFunctions) = .{},

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

    pub fn release(self: *SharedState, allocator: std.mem.Allocator) void {
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

            // Clear extension function cache
            self.extension_cache.deinit(allocator);
            self.extension_cache = .{};
        }
    }

    /// Get extension functions for a given address family, loading on-demand if needed
    pub fn getExtensions(self: *SharedState, allocator: std.mem.Allocator, family: u16) !*const ExtensionFunctions {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already cached
        if (self.extension_cache.get(family)) |funcs| {
            return &funcs;
        }

        // Not cached - load extension functions
        const funcs = try self.loadExtensionFunctions(family);

        // Cache for future use
        try self.extension_cache.put(allocator, family, funcs);

        return self.extension_cache.getPtr(family).?;
    }

    fn loadExtensionFunctions(self: *SharedState, family: u16) !ExtensionFunctions {
        _ = self;

        // Create a temporary socket for the specified family
        const sock = try net.socket(family, windows.SOCK.STREAM, windows.IPPROTO.TCP);
        defer net.close(sock);

        // Load AcceptEx
        const acceptex = try loadWinsockExtension(LPFN_ACCEPTEX, sock, WSAID_ACCEPTEX);

        // Load ConnectEx
        const connectex = try loadWinsockExtension(LPFN_CONNECTEX, sock, WSAID_CONNECTEX);

        return .{
            .acceptex = acceptex,
            .connectex = connectex,
        };
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
    errdefer shared_state.release(allocator);

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
    self.shared_state.release(self.allocator);
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
