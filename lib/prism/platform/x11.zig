//! X11 platform backend built on x11.zig's zero-C client and generated core
//! protocol bindings. Windows are presented with chunked ZPixmap PutImage
//! requests, so this works with an ordinary X server and under Xvfb.

const std = @import("std");
const hal = @import("../hal.zig");
const platform = @import("../platform.zig");
const x11 = @import("x11");
const xproto = @import("xproto");

const event_exposure: u32 = 1 << 15;
const event_structure_notify: u32 = 1 << 17;
const atom_atom: u32 = 4;
const atom_string: u32 = 31;
const atom_wm_name: u32 = 39;
const atom_wm_class: u32 = 67;

/// Return DISPLAY from an environment map. Keeping this small helper public
/// mirrors Wayland's resolveSocketPath and makes probing side-effect free.
pub fn resolveDisplay(environ: *const std.process.Environ.Map) error{NoDisplay}![]const u8 {
    return environ.get("DISPLAY") orelse error.NoDisplay;
}

fn internAtom(client: *x11.Client, gpa: std.mem.Allocator, name: []const u8) !u32 {
    const cookie = try xproto.intern_atom(client, gpa, false, name);
    var xe: x11.wire.XError = undefined;
    var reply = try client.awaitReply(@TypeOf(cookie).ReplyType, cookie, &xe);
    defer reply.deinit();
    return xproto.decodeInternAtomReply(reply.bytes).atom;
}

const X11Surface = struct {
    gpa: std.mem.Allocator,
    client: *x11.Client,
    window: u32,
    gc: u32,
    width: u32,
    height: u32,
    stride: u32,
    depth: u8,
    max_request_bytes: usize,
    pixels: []u8,
    wm_protocols: u32,
    wm_delete_window: u32,
    owns_window: bool,

    fn currentBuffer(ptr: *anyopaque) hal.Error!platform.Buffer {
        const self: *X11Surface = @ptrCast(@alignCast(ptr));
        // Foreign-window clients (EGL/GLX/Vulkan) drive their own event loop.
        // Query geometry at present time so a host-side resize updates Prism's
        // staging buffer without requiring that host to pump our connection.
        if (!self.owns_window) try self.refreshGeometry();
        return .{
            .bytes = self.pixels,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            // The common TrueColor root visual uses 0x00RRGGBB pixels. On a
            // little-endian host its ZPixmap bytes are B,G,R,X.
            .format = .bgra8_unorm,
        };
    }

    fn refreshGeometry(self: *X11Surface) hal.Error!void {
        const cookie = xproto.get_geometry(self.client, self.window) catch return error.DeviceLost;
        var xe: x11.wire.XError = undefined;
        var reply = self.client.awaitReply(xproto.GetGeometryReply, cookie, &xe) catch return error.DeviceLost;
        defer reply.deinit();
        const geometry = xproto.decodeGetGeometryReply(reply.bytes);
        if (geometry.depth != self.depth) return error.InitializationFailed;
        try self.resize(geometry.width, geometry.height);
    }

    fn sendFrame(self: *X11Surface) hal.Error!void {
        if (self.width == 0 or self.height == 0) return;
        // PutImage has a 24-byte request prefix. Core X11 request lengths are
        // u16 units; split by complete scanlines to stay below the server's
        // setup-advertised maximum without requiring BIG-REQUESTS.
        const payload_limit = self.max_request_bytes -| 24;
        const rows_per_request = payload_limit / self.stride;
        if (rows_per_request == 0) return error.InitializationFailed;

        var y: u32 = 0;
        while (y < self.height) {
            const rows: u32 = @intCast(@min(@as(usize, self.height - y), rows_per_request));
            const begin = @as(usize, y) * self.stride;
            const end = begin + @as(usize, rows) * self.stride;
            _ = xproto.put_image(
                self.client,
                self.gpa,
                2, // ZPixmap
                self.window,
                self.gc,
                @intCast(self.width),
                @intCast(rows),
                0,
                @intCast(y),
                0,
                self.depth,
                self.pixels[begin..end],
            ) catch return error.DeviceLost;
            y += rows;
        }
    }

    fn sendRegion(self: *X11Surface, x: u32, y: u32, width: u32, height: u32) hal.Error!void {
        if (x >= self.width or y >= self.height) return;
        const clipped_width = @min(width, self.width - x);
        const clipped_height = @min(height, self.height - y);
        if (clipped_width == 0 or clipped_height == 0) return;
        // A narrow damage rectangle is non-contiguous in the full framebuffer.
        // Send one naturally 32-bit-padded ZPixmap scanline per request instead
        // of retransmitting the entire window after an Expose event.
        var row: u32 = 0;
        while (row < clipped_height) : (row += 1) {
            const begin = @as(usize, y + row) * self.stride + @as(usize, x) * 4;
            const end = begin + @as(usize, clipped_width) * 4;
            _ = xproto.put_image(
                self.client,
                self.gpa,
                2,
                self.window,
                self.gc,
                @intCast(clipped_width),
                1,
                @intCast(x),
                @intCast(y + row),
                0,
                self.depth,
                self.pixels[begin..end],
            ) catch return error.DeviceLost;
        }
    }

    fn commit(ptr: *anyopaque) hal.Error!void {
        const self: *X11Surface = @ptrCast(@alignCast(ptr));
        try self.sendFrame();
    }

    fn resize(self: *X11Surface, width: u32, height: u32) hal.Error!void {
        if (width == 0 or height == 0 or (width == self.width and height == self.height)) return;
        // PutImage's destination coordinates are signed 16-bit.
        if (height > std.math.maxInt(i16)) return error.InitializationFailed;
        const stride = std.math.mul(u32, width, 4) catch return error.OutOfMemory;
        const len = std.math.mul(usize, stride, height) catch return error.OutOfMemory;
        const pixels = self.gpa.alloc(u8, len) catch return error.OutOfMemory;
        @memset(pixels, 0);
        self.gpa.free(self.pixels);
        self.pixels = pixels;
        self.width = width;
        self.height = height;
        self.stride = stride;
    }

    fn processEvents(ptr: *anyopaque) hal.Error!platform.WindowEvent {
        const self: *X11Surface = @ptrCast(@alignCast(ptr));
        const incoming = self.client.nextEvent() catch return error.DeviceLost;
        switch (incoming) {
            .err => return error.DeviceLost,
            .event => |raw| switch (xproto.decodeEvent(&raw.bytes)) {
                .configure_notify => |ev| {
                    if (ev.window == self.window and ev.width != 0 and ev.height != 0 and
                        (ev.width != self.width or ev.height != self.height))
                    {
                        try self.resize(ev.width, ev.height);
                        return .resized;
                    }
                },
                .expose => |ev| {
                    if (ev.window == self.window)
                        try self.sendRegion(@intCast(ev.x), @intCast(ev.y), ev.width, ev.height);
                },
                .destroy_notify => |ev| if (ev.window == self.window) return .closed,
                .client_message => |ev| {
                    // The generated binding currently leaves ClientMessage's
                    // union opaque; its first 32-bit datum is wire bytes 12..16.
                    if (ev.window == self.window and ev.type == self.wm_protocols and
                        raw.bytes[1] == 32 and
                        std.mem.readInt(u32, raw.bytes[12..16], @import("builtin").cpu.arch.endian()) == self.wm_delete_window)
                    {
                        return .closed;
                    }
                },
                else => {},
            },
        }
        return .none;
    }

    fn size(ptr: *anyopaque) [2]u32 {
        const self: *X11Surface = @ptrCast(@alignCast(ptr));
        return .{ self.width, self.height };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *X11Surface = @ptrCast(@alignCast(ptr));
        _ = xproto.free_gc(self.client, self.gc) catch {};
        if (self.owns_window) _ = xproto.destroy_window(self.client, self.window) catch {};
        self.gpa.free(self.pixels);
        self.gpa.destroy(self);
    }

    const vtable = platform.Surface.VTable{
        .currentBuffer = currentBuffer,
        .commit = commit,
        .processEvents = processEvents,
        .size = size,
        .deinit = deinit,
    };
};

const X11Display = struct {
    gpa: std.mem.Allocator,
    client: x11.Client,
    screen: x11.wire.Screen,
    depth: u8,
    max_request_bytes: usize,
    wm_protocols: u32,
    wm_delete_window: u32,

    fn createSurface(ptr: *anyopaque, desc: platform.SurfaceDesc) hal.Error!platform.Surface {
        const self: *X11Display = @ptrCast(@alignCast(ptr));
        if (desc.width == 0 or desc.height == 0 or
            desc.width > std.math.maxInt(u16) or desc.height > std.math.maxInt(i16))
            return error.InitializationFailed;

        const stride = std.math.mul(u32, desc.width, 4) catch return error.OutOfMemory;
        const len = std.math.mul(usize, stride, desc.height) catch return error.OutOfMemory;
        const pixels = self.gpa.alloc(u8, len) catch return error.OutOfMemory;
        errdefer self.gpa.free(pixels);
        @memset(pixels, 0);

        const window = self.client.generateId();
        _ = xproto.create_window(
            &self.client,
            self.gpa,
            self.depth,
            window,
            self.screen.root,
            0,
            0,
            @intCast(desc.width),
            @intCast(desc.height),
            0,
            1, // InputOutput
            self.screen.root_visual,
            .{
                .background_pixel = self.screen.black_pixel,
                .border_pixel = self.screen.black_pixel,
                .event_mask = event_exposure | event_structure_notify,
            },
        ) catch return error.InitializationFailed;
        errdefer _ = xproto.destroy_window(&self.client, window) catch {};

        const gc = self.client.generateId();
        _ = xproto.create_gc(&self.client, self.gpa, gc, window, .{ .graphics_exposures = 0 }) catch
            return error.InitializationFailed;
        errdefer _ = xproto.free_gc(&self.client, gc) catch {};

        const delete_atom_bytes = std.mem.asBytes(&self.wm_delete_window);
        _ = xproto.change_property(
            &self.client,
            self.gpa,
            0, // Replace
            window,
            self.wm_protocols,
            atom_atom,
            32,
            1,
            delete_atom_bytes,
        ) catch return error.InitializationFailed;
        _ = xproto.change_property(
            &self.client,
            self.gpa,
            0,
            window,
            atom_wm_name,
            atom_string,
            8,
            5,
            "Prism",
        ) catch return error.InitializationFailed;
        // WM_CLASS is two consecutive NUL-terminated strings: instance, class.
        const wm_class = "prism\x00Prism\x00";
        _ = xproto.change_property(
            &self.client,
            self.gpa,
            0,
            window,
            atom_wm_class,
            atom_string,
            8,
            wm_class.len,
            wm_class,
        ) catch return error.InitializationFailed;
        _ = xproto.map_window(&self.client, window) catch return error.InitializationFailed;

        // A reply-bearing request is a creation barrier: asynchronous errors
        // from CreateWindow/CreateGC/MapWindow are observed before returning.
        const geometry_cookie = xproto.get_geometry(&self.client, window) catch return error.InitializationFailed;
        var xe: x11.wire.XError = undefined;
        var geometry = self.client.awaitReply(xproto.GetGeometryReply, geometry_cookie, &xe) catch
            return error.InitializationFailed;
        geometry.deinit();

        const surface = self.gpa.create(X11Surface) catch return error.OutOfMemory;
        surface.* = .{
            .gpa = self.gpa,
            .client = &self.client,
            .window = window,
            .gc = gc,
            .width = desc.width,
            .height = desc.height,
            .stride = stride,
            .depth = self.depth,
            .max_request_bytes = self.max_request_bytes,
            .pixels = pixels,
            .wm_protocols = self.wm_protocols,
            .wm_delete_window = self.wm_delete_window,
            .owns_window = true,
        };
        return .{ .ptr = surface, .vtable = &X11Surface.vtable };
    }

    fn createForeignSurface(self: *X11Display, window: u32) hal.Error!platform.Surface {
        // Query the application's existing drawable instead of assuming the
        // root visual dimensions. A separate X11 connection may render to the
        // same server-side XID; XIDs are connection-independent resources.
        const geometry_cookie = xproto.get_geometry(&self.client, window) catch return error.InitializationFailed;
        var xe: x11.wire.XError = undefined;
        var reply = self.client.awaitReply(xproto.GetGeometryReply, geometry_cookie, &xe) catch
            return error.InitializationFailed;
        defer reply.deinit();
        const geometry = xproto.decodeGetGeometryReply(reply.bytes);
        if (geometry.width == 0 or geometry.height == 0 or geometry.depth != self.depth)
            return error.InitializationFailed;

        // Event selection is per client, so this does not replace the host
        // application's mask. It lets Prism observe resize/expose/destroy on
        // application-owned windows through its own x11.zig connection.
        _ = xproto.change_window_attributes(
            &self.client,
            self.gpa,
            window,
            .{ .event_mask = event_exposure | event_structure_notify },
        ) catch return error.InitializationFailed;

        const gc = self.client.generateId();
        _ = xproto.create_gc(&self.client, self.gpa, gc, window, .{ .graphics_exposures = 0 }) catch
            return error.InitializationFailed;
        errdefer _ = xproto.free_gc(&self.client, gc) catch {};

        const stride = std.math.mul(u32, geometry.width, 4) catch return error.OutOfMemory;
        const len = std.math.mul(usize, stride, geometry.height) catch return error.OutOfMemory;
        const pixels = self.gpa.alloc(u8, len) catch return error.OutOfMemory;
        errdefer self.gpa.free(pixels);
        @memset(pixels, 0);

        const surface = self.gpa.create(X11Surface) catch return error.OutOfMemory;
        surface.* = .{
            .gpa = self.gpa,
            .client = &self.client,
            .window = window,
            .gc = gc,
            .width = geometry.width,
            .height = geometry.height,
            .stride = stride,
            .depth = geometry.depth,
            .max_request_bytes = self.max_request_bytes,
            .pixels = pixels,
            .wm_protocols = self.wm_protocols,
            .wm_delete_window = self.wm_delete_window,
            .owns_window = false,
        };
        return .{ .ptr = surface, .vtable = &X11Surface.vtable };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *X11Display = @ptrCast(@alignCast(ptr));
        self.client.close();
        self.gpa.destroy(self);
    }

    const vtable = platform.Display.VTable{ .createSurface = createSurface, .deinit = deinit };
};

/// Connect to an X server. `display_name` follows DISPLAY syntax (for example
/// `:99`); pass an environment map so x11.zig can discover Xauthority.
pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    display_name: []const u8,
    environ: ?*const std.process.Environ.Map,
) hal.Error!platform.Display {
    var client = x11.Client.open(gpa, io, display_name, null, environ) catch
        return error.InitializationFailed;
    errdefer client.close();

    const screen = client.defaultScreen() orelse return error.InitializationFailed;
    // Prism exposes a BGRA8 framebuffer. Require the ubiquitous TrueColor
    // 0x00RRGGBB root visual and a 32-bpp ZPixmap format for its root depth.
    var matching_format = false;
    var formats = client.conn.setup.formats();
    while (formats.next()) |format| {
        if (format.depth == screen.root_depth and format.bits_per_pixel == 32 and format.scanline_pad <= 32) {
            matching_format = true;
            break;
        }
    }
    if (!matching_format) return error.InitializationFailed;

    var matching_visual = false;
    var depths = screen.depths();
    while (depths.next()) |depth| {
        if (depth.depth != screen.root_depth) continue;
        var visuals = depth.visuals();
        while (visuals.next()) |visual| {
            if (visual.visual_id == screen.root_visual and visual.class == 4 and
                visual.red_mask == 0x00ff0000 and visual.green_mask == 0x0000ff00 and
                visual.blue_mask == 0x000000ff)
            {
                matching_visual = true;
                break;
            }
        }
    }
    if (!matching_visual) return error.InitializationFailed;

    const wm_protocols = internAtom(&client, gpa, "WM_PROTOCOLS") catch return error.InitializationFailed;
    const wm_delete_window = internAtom(&client, gpa, "WM_DELETE_WINDOW") catch return error.InitializationFailed;
    const setup_max_units = std.mem.readInt(u16, client.conn.setup.raw[26..28], @import("builtin").cpu.arch.endian());

    const display = gpa.create(X11Display) catch return error.OutOfMemory;
    display.* = .{
        .gpa = gpa,
        .client = client,
        .screen = screen,
        .depth = screen.root_depth,
        .max_request_bytes = @as(usize, setup_max_units) * 4,
        .wm_protocols = wm_protocols,
        .wm_delete_window = wm_delete_window,
    };
    return .{ .ptr = display, .vtable = &X11Display.vtable };
}

/// A platform surface over an application-owned X11 window. Prism owns its
/// private X11 connection and GC, but never maps or destroys `window`.
pub const ForeignWindow = struct {
    display: platform.Display,
    surface: platform.Surface,

    pub fn deinit(self: *ForeignWindow) void {
        self.surface.deinit();
        self.display.deinit();
        self.* = undefined;
    }
};

/// Connect independently to DISPLAY and wrap an existing XID. This is the
/// common native-window bridge used by EGL X11, Vulkan XCB, and GLX; it avoids
/// depending on either libX11 or libxcb while remaining compatible with windows
/// those libraries created.
pub fn wrapWindow(
    gpa: std.mem.Allocator,
    io: std.Io,
    display_name: []const u8,
    environ: ?*const std.process.Environ.Map,
    window: u32,
) hal.Error!ForeignWindow {
    var display = try create(gpa, io, display_name, environ);
    errdefer display.deinit();
    const impl: *X11Display = @ptrCast(@alignCast(display.ptr));
    const surface = try impl.createForeignSurface(window);
    return .{ .display = display, .surface = surface };
}

/// Query the server's default root visual without retaining a connection.
/// EGL uses this for EGL_NATIVE_VISUAL_ID so Xlib clients create a window whose
/// depth/visual matches the X11 presenter.
pub fn defaultVisualId(
    gpa: std.mem.Allocator,
    io: std.Io,
    display_name: []const u8,
    environ: ?*const std.process.Environ.Map,
) hal.Error!u32 {
    var client = x11.Client.open(gpa, io, display_name, null, environ) catch
        return error.InitializationFailed;
    defer client.close();
    const screen = client.defaultScreen() orelse return error.InitializationFailed;
    return screen.root_visual;
}

test "resolveDisplay reads DISPLAY" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("DISPLAY", ":42");
    try std.testing.expectEqualStrings(":42", try resolveDisplay(&env));
}
