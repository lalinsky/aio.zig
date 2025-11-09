const Completion = @import("../completion.zig").Completion;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetShutdown = @import("../completion.zig").NetShutdown;
const NetClose = @import("../completion.zig").NetClose;
const net = @import("../os/net.zig");

/// Helper to handle socket open operation
pub fn handleNetOpen(c: *Completion) void {
    const data = c.cast(NetOpen);
    if (net.socket(data.domain, data.socket_type, data.protocol, data.flags)) |handle| {
        c.setResult(.net_open, handle);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle bind operation with automatic getsockname call
pub fn handleNetBind(c: *Completion) void {
    const data = c.cast(NetBind);
    if (net.bind(data.handle, data.addr, data.addr_len.*)) |_| {
        // Update the address with the actual bound address
        if (net.getsockname(data.handle, data.addr, data.addr_len)) |_| {
            c.setResult(.net_bind, {});
        } else |err| {
            c.setError(err);
        }
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle listen operation
pub fn handleNetListen(c: *Completion) void {
    const data = c.cast(NetListen);
    if (net.listen(data.handle, data.backlog)) |_| {
        c.setResult(.net_listen, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle shutdown operation
pub fn handleNetShutdown(c: *Completion) void {
    const data = c.cast(NetShutdown);
    if (net.shutdown(data.handle, data.how)) |_| {
        c.setResult(.net_shutdown, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle close operation
pub fn handleNetClose(c: *Completion) void {
    const data = c.cast(NetClose);
    net.close(data.handle);
    c.setResult(.net_close, {});
}
