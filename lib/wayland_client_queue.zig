//! Keep driver-owned Wayland events off the application's event queue. A WSI
//! roundtrip or buffer wait must not dispatch the application's window callbacks.
const std = @import("std");
extern "c" fn wl_display_create_queue(display: *anyopaque) ?*anyopaque;
extern "c" fn wl_event_queue_destroy(queue: *anyopaque) void;
extern "c" fn wl_proxy_create_wrapper(proxy: *anyopaque) ?*anyopaque;
extern "c" fn wl_proxy_wrapper_destroy(proxy: *anyopaque) void;
extern "c" fn wl_proxy_set_queue(proxy: *anyopaque, queue: *anyopaque) void;
extern "c" fn wl_display_roundtrip_queue(display: *anyopaque, queue: *anyopaque) c_int;
extern "c" fn wl_display_dispatch_queue_pending(display: *anyopaque, queue: *anyopaque) c_int;
extern "c" fn wl_display_prepare_read_queue(display: *anyopaque, queue: *anyopaque) c_int;
extern "c" fn wl_display_read_events(display: *anyopaque) c_int;
extern "c" fn wl_display_cancel_read(display: *anyopaque) void;
extern "c" fn wl_display_flush(display: *anyopaque) c_int;
extern "c" fn wl_display_get_fd(display: *anyopaque) c_int;

pub const Error = error{ OutOfMemory, Disconnected, Timeout };
pub const Queue = struct {
    display: *anyopaque,
    queue: *anyopaque,

    pub fn init(display: *anyopaque) Error!Queue {
        return .{ .display = display, .queue = wl_display_create_queue(display) orelse return error.OutOfMemory };
    }
    pub fn deinit(self: Queue) void {
        wl_event_queue_destroy(self.queue);
    }
    pub fn wrap(self: Queue, proxy: *anyopaque) Error!*anyopaque {
        const wrapper = wl_proxy_create_wrapper(proxy) orelse return error.OutOfMemory;
        wl_proxy_set_queue(wrapper, self.queue);
        return wrapper;
    }
    pub fn destroyWrapper(wrapper: *anyopaque) void {
        wl_proxy_wrapper_destroy(wrapper);
    }
    pub fn roundtrip(self: Queue) Error!void {
        if (wl_display_roundtrip_queue(self.display, self.queue) < 0) return error.Disconnected;
    }
    pub fn pending(self: Queue) Error!void {
        if (wl_display_dispatch_queue_pending(self.display, self.queue) < 0) return error.Disconnected;
    }
    pub fn wait(self: Queue, timeout_ns: u64) Error!void {
        while (wl_display_prepare_read_queue(self.display, self.queue) != 0) try self.pending();
        var prepared = true;
        defer if (prepared) wl_display_cancel_read(self.display);
        // EAGAIN on a nonblocking socket is harmless here; a later wait retries
        // the flush. No application callbacks run while waiting for releases.
        _ = wl_display_flush(self.display);
        var pollfd = [_]std.c.pollfd{.{ .fd = wl_display_get_fd(self.display), .events = std.c.POLL.IN, .revents = 0 }};
        const timeout_ms: c_int = if (timeout_ns == std.math.maxInt(u64)) -1 else @intCast(@min(timeout_ns / 1_000_000 + @intFromBool(timeout_ns % 1_000_000 != 0), std.math.maxInt(c_int)));
        const n = std.c.poll(&pollfd, 1, timeout_ms);
        if (n == 0) return error.Timeout;
        if (n < 0 or pollfd[0].revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL) != 0) return error.Disconnected;
        prepared = false;
        if (wl_display_read_events(self.display) < 0) return error.Disconnected;
        try self.pending();
    }
};
