//! App-display Wayland presentation of exported HAL render targets.
const std = @import("std");
const prism = @import("prism");
const wl = @import("wl_egl_window.zig");
const Queue = @import("../wayland_client_queue.zig").Queue;
const Proxy = wl.wl_proxy;
const Resource = prism.hal.Resource;

const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const Interface = null,
};
const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};
const buffer_types = [_]?*const Interface{@ptrCast(@alignCast(&wl.wl_buffer_interface))};
const immediate_types = [_]?*const Interface{ @ptrCast(@alignCast(&wl.wl_buffer_interface)), null, null, null, null };
const params_types = [_]?*const Interface{&params_interface};
const manager_methods = [_]Message{
    .{ .name = "destroy", .signature = "" },
    .{ .name = "create_params", .signature = "n", .types = &params_types },
};
const manager_events = [_]Message{
    .{ .name = "format", .signature = "u" },
    .{ .name = "modifier", .signature = "3uuu" },
};
const manager_interface = Interface{
    .name = "zwp_linux_dmabuf_v1",
    .version = 3,
    .method_count = manager_methods.len,
    .methods = &manager_methods,
    .event_count = manager_events.len,
    .events = &manager_events,
};
const params_methods = [_]Message{
    .{ .name = "destroy", .signature = "" },
    .{ .name = "add", .signature = "huuuuu" },
    .{ .name = "create", .signature = "iiuu" },
    .{ .name = "create_immed", .signature = "2niiuu", .types = &immediate_types },
};
const params_events = [_]Message{
    .{ .name = "created", .signature = "n", .types = &buffer_types },
    .{ .name = "failed", .signature = "" },
};
const params_interface = Interface{
    .name = "zwp_linux_buffer_params_v1",
    .version = 3,
    .method_count = params_methods.len,
    .methods = &params_methods,
    .event_count = params_events.len,
    .events = &params_events,
};

const Probe = struct { name: u32 = 0, version: u32 = 0, compositor: u32 = 0, compositor_version: u32 = 0 };
fn global(data: ?*anyopaque, _: *Proxy, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void {
    const probe: *Probe = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(interface), "zwp_linux_dmabuf_v1")) {
        probe.name = name;
        probe.version = @min(version, 3);
    } else if (std.mem.eql(u8, std.mem.span(interface), "wl_compositor")) {
        probe.compositor = name;
        probe.compositor_version = @min(version, 4);
    }
}
fn removed(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}
const registry_listener = [_]?*const anyopaque{ @ptrCast(&global), @ptrCast(&removed) };
fn format(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}
fn modifier(_: ?*anyopaque, _: *Proxy, _: u32, _: u32, _: u32) callconv(.c) void {}
const manager_listener = [_]?*const anyopaque{ @ptrCast(&format), @ptrCast(&modifier) };

const Slot = struct {
    resource: ?*Resource = null,
    buffer: ?*Proxy = null,
    free: bool = true,
    failed: bool = false,
};

extern "c" fn wl_display_connect(name: ?[*:0]const u8) ?*wl.wl_display;
extern "c" fn wl_display_disconnect(display: *wl.wl_display) void;
extern "c" const wl_compositor_interface: anyopaque;
extern "c" const wl_surface_interface: anyopaque;

test "native Mali exports three render targets that the live Wayland compositor imports" {
    if (std.c.getenv("WAYLAND_DISPLAY") == null) return error.SkipZigTest;
    const driver = prism.drivers.select("mali", std.testing.io) orelse return error.SkipZigTest;
    const device = driver.createDevice(std.testing.allocator, std.testing.io) catch return error.SkipZigTest;
    defer device.deinit();
    const display = wl_display_connect(null) orelse return error.SkipZigTest;
    defer wl_display_disconnect(display);
    const queue = try Queue.init(display);
    defer queue.deinit();
    const wrapper = try queue.wrap(display);
    defer Queue.destroyWrapper(wrapper);
    const registry = wl.wl_proxy_marshal_flags(wrapper, 1, &wl.wl_registry_interface, 1, 0, @as(?*Proxy, null)) orelse return error.RegistryFailed;
    defer wl.wl_proxy_destroy(registry);
    var probe: Probe = .{};
    if (wl.wl_proxy_add_listener(registry, &registry_listener, &probe) != 0) return error.ListenerFailed;
    try queue.roundtrip();
    if (probe.name == 0 or probe.compositor == 0) return error.SkipZigTest;
    const compositor = wl.wl_proxy_marshal_flags(registry, 0, &wl_compositor_interface, probe.compositor_version, 0, probe.compositor, @as([*:0]const u8, "wl_compositor"), probe.compositor_version, @as(?*Proxy, null)) orelse return error.BindFailed;
    defer wl.wl_proxy_destroy(compositor);
    const surface = wl.wl_proxy_marshal_flags(compositor, 0, &wl_surface_interface, probe.compositor_version, 0, @as(?*Proxy, null)) orelse return error.SurfaceFailed;
    defer destroy(surface);
    const original = try device.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer device.destroyResource(original);
    {
        // An unroled surface never becomes a visible window. Importing these
        // buffers exercises the real C protocol metadata and export lifetime.
        const present = try Present.init(std.testing.allocator, device, display, surface, original, 32, 32);
        defer present.deinit(original);
        try std.testing.expectEqual(original, present.slots[0].resource.?);
        for (present.slots, 0..) |slot, index| {
            try std.testing.expect(slot.buffer != null);
            for (present.slots[0..index]) |previous|
                try std.testing.expect(previous.resource != slot.resource);
        }
    }
    try queue.roundtrip();
}
fn released(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data.?));
    slot.free = true;
}
const buffer_listener = [_]?*const anyopaque{@ptrCast(&released)};
fn created(data: ?*anyopaque, _: *Proxy, buffer: *Proxy) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data.?));
    slot.buffer = buffer;
    if (wl.wl_proxy_add_listener(buffer, &buffer_listener, slot) != 0) slot.failed = true;
}
fn failed(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data.?));
    slot.failed = true;
}
const params_listener = [_]?*const anyopaque{ @ptrCast(&created), @ptrCast(&failed) };

fn destroy(proxy: *Proxy) void {
    _ = wl.wl_proxy_marshal_flags(proxy, 0, null, wl.wl_proxy_get_version(proxy), 1);
}

pub const Present = struct {
    gpa: std.mem.Allocator,
    device: prism.hal.Device,
    display: *wl.wl_display,
    surface: *wl.wl_surface,
    queue: Queue,
    manager: ?*Proxy = null,
    slots: [3]Slot = @splat(.{}),
    current: usize = 0,
    width: u32,
    height: u32,

    /// Ownership of the caller's selected backbuffer follows presentAndAcquire.
    /// We own the other two images and retain the selected one during deinit.
    pub fn init(gpa: std.mem.Allocator, device: prism.hal.Device, display: *wl.wl_display, surface: *wl.wl_surface, original: *Resource, width: u32, height: u32) !*Present {
        if (device.vtable.exportResource == null) return error.Unsupported;
        const queue = try Queue.init(display);
        const self = gpa.create(Present) catch |err| {
            queue.deinit();
            return err;
        };
        self.* = .{ .gpa = gpa, .device = device, .display = display, .surface = surface, .queue = queue, .width = width, .height = height };
        errdefer self.deinit(original);
        const wrapper = try queue.wrap(display);
        defer Queue.destroyWrapper(wrapper);
        const registry = wl.wl_proxy_marshal_flags(wrapper, 1, &wl.wl_registry_interface, wl.wl_proxy_get_version(display), 0, @as(?*Proxy, null)) orelse return error.RegistryFailed;
        defer wl.wl_proxy_destroy(registry);
        var probe: Probe = .{};
        if (wl.wl_proxy_add_listener(registry, &registry_listener, &probe) != 0) return error.ListenerFailed;
        try queue.roundtrip();
        if (probe.name == 0) return error.Unsupported;
        const manager = wl.wl_proxy_marshal_flags(registry, 0, &manager_interface, probe.version, 0, probe.name, manager_interface.name, probe.version, @as(?*Proxy, null)) orelse return error.BindFailed;
        self.manager = manager;
        if (wl.wl_proxy_add_listener(manager, &manager_listener, null) != 0) return error.ListenerFailed;
        for (&self.slots, 0..) |*slot, index| {
            slot.resource = if (index == 0) original else try device.createResource(.{ .image = .{
                .width = width,
                .height = height,
                .format = .rgba8_unorm,
                .usage = .{ .render_target = true },
            } });
            const image = try device.exportResource(slot.resource.?);
            const params = wl.wl_proxy_marshal_flags(manager, 1, &params_interface, probe.version, 0, @as(?*Proxy, null)) orelse return error.ParamsFailed;
            defer destroy(params);
            if (wl.wl_proxy_add_listener(params, &params_listener, slot) != 0) return error.ListenerFailed;
            _ = wl.wl_proxy_marshal_flags(params, 1, null, probe.version, 0, @as(c_int, image.fd), @as(u32, 0), image.offset, image.stride, @as(u32, @truncate(image.modifier >> 32)), @as(u32, @truncate(image.modifier)));
            // Asynchronous create reports unsupported imports without killing
            // the application's Wayland connection, allowing the SHM fallback.
            _ = wl.wl_proxy_marshal_flags(params, 2, null, probe.version, 0, @as(i32, @intCast(width)), @as(i32, @intCast(height)), image.format, @as(u32, 0));
            try queue.roundtrip();
            if (slot.failed or slot.buffer == null) return error.ImportFailed;
        }
        self.slots[0].free = false; // Original already contains the first frame.
        return self;
    }

    /// Imported buffers can outlive our proxies: the compositor retains their
    /// dma-buf references until its reads complete. No image is written again
    /// until wl_buffer.release, including the image selected for the next frame.
    pub fn presentAndAcquire(self: *Present) !*Resource {
        const version = wl.wl_proxy_get_version(self.surface);
        _ = wl.wl_proxy_marshal_flags(self.surface, 1, null, version, 0, self.slots[self.current].buffer.?, @as(i32, 0), @as(i32, 0));
        _ = wl.wl_proxy_marshal_flags(self.surface, if (version >= 4) @as(u32, 9) else @as(u32, 2), null, version, 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(self.width)), @as(i32, @intCast(self.height)));
        _ = wl.wl_proxy_marshal_flags(self.surface, 6, null, version, 0);
        _ = wl.wl_display_flush(self.display);
        try self.queue.pending();
        while (true) {
            for (&self.slots, 0..) |*slot, index| if (slot.free) {
                slot.free = false;
                self.current = index;
                return slot.resource.?;
            };
            try self.queue.wait(std.math.maxInt(u64));
        }
    }

    pub fn deinit(self: *Present, keep: *Resource) void {
        for (self.slots) |slot| {
            if (slot.buffer) |buffer| destroy(buffer);
            if (slot.resource) |resource| if (resource != keep) self.device.destroyResource(resource);
        }
        if (self.manager) |manager| destroy(manager);
        self.queue.deinit();
        self.gpa.destroy(self);
    }
};
