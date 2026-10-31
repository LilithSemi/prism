const std = @import("std");
const asahi = @import("asahi");
const hal = @import("../../hal.zig");
const Resource = @import("resource.zig").Resource;
const AppleDevice = @import("device.zig").Device;
const aserr = @import("device.zig").aserr;
const Surface = @import("surface.zig").Surface;

/// A recorded command. The command buffer appends these. GPU work is built and
/// replayed in Context.submit (mirroring the nvidia / software drivers).
const Command = union(enum) {
    set_render_target: *Resource,
    clear: hal.Color,
    bind_pipeline: *hal.Pipeline,
    bind_vertex_buffer: *Resource,
    draw: struct { vertex_count: u32, first_vertex: u32 },
};

pub const CommandBuffer = struct {
    gpa: std.mem.Allocator,
    cmds: std.ArrayListUnmanaged(Command) = .empty,

    fn create(gpa: std.mem.Allocator) hal.Error!hal.CommandBuffer {
        const self = gpa.create(CommandBuffer) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setRenderTarget(ptr: *anyopaque, target: *hal.Resource) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.cmds.append(self.gpa, .{ .set_render_target = @ptrCast(@alignCast(target)) }) catch return error.OutOfMemory;
    }
    fn clear(ptr: *anyopaque, color: hal.Color) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.cmds.append(self.gpa, .{ .clear = color }) catch return error.OutOfMemory;
    }
    fn bindPipeline(ptr: *anyopaque, pipeline: *hal.Pipeline) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.cmds.append(self.gpa, .{ .bind_pipeline = pipeline }) catch return error.OutOfMemory;
    }
    fn bindVertexBuffer(ptr: *anyopaque, buffer: *hal.Resource) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.cmds.append(self.gpa, .{ .bind_vertex_buffer = @ptrCast(@alignCast(buffer)) }) catch return error.OutOfMemory;
    }
    fn draw(ptr: *anyopaque, vertex_count: u32, first_vertex: u32) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.cmds.append(self.gpa, .{ .draw = .{ .vertex_count = vertex_count, .first_vertex = first_vertex } }) catch return error.OutOfMemory;
    }
    fn reset(ptr: *anyopaque) void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.cmds.clearRetainingCapacity();
    }
    fn deinit(ptr: *anyopaque) void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        const gpa = self.gpa;
        self.cmds.deinit(gpa);
        gpa.destroy(self);
    }

    const vtable = hal.CommandBuffer.VTable{
        .setRenderTarget = &setRenderTarget,
        .clear = &clear,
        .bindPipeline = &bindPipeline,
        .bindVertexBuffer = &bindVertexBuffer,
        .draw = &draw,
        .reset = &reset,
        .deinit = &deinit,
    };
};

/// Records are validated before GPU work, then replayed as synchronous native
/// render passes. Draws without a clear preserve the target's existing pixels.
pub const Context = struct {
    dev: *AppleDevice,

    pub fn create(dev: *AppleDevice) hal.Error!hal.Context {
        const self = dev.gpa.create(Context) catch return error.OutOfMemory;
        self.* = .{ .dev = dev };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn beginCommands(ptr: *anyopaque) hal.Error!hal.CommandBuffer {
        const self: *Context = @ptrCast(@alignCast(ptr));
        return CommandBuffer.create(self.dev.gpa);
    }

    fn submit(ptr: *anyopaque, cb: hal.CommandBuffer) hal.Error!void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const buf: *CommandBuffer = @ptrCast(@alignCast(cb.ptr));

        try self.replay(buf, false);
        try self.replay(buf, true);
    }

    fn replay(self: *Context, buf: *CommandBuffer, execute: bool) hal.Error!void {
        const Render = @import("render.zig");
        const Pipeline = @import("pipeline.zig").Pipeline;
        var target: ?*Resource = null;
        var clear_color: ?hal.Color = null;
        var pipeline: ?*Pipeline = null;
        var vertex: ?*Resource = null;
        var draws: [32]Render.Draw = undefined;
        var count: usize = 0;
        for (buf.cmds.items) |cmd| switch (cmd) {
            .set_render_target => |t| {
                if (t.kind != .image) return error.InvalidArgument;
                if (target == t) continue;
                if (target) |old| try self.finishPass(old, clear_color, draws[0..count], execute);
                target = t;
                clear_color = null;
                count = 0;
            },
            .clear => |c| {
                const t = target orelse return error.InvalidArgument;
                try self.finishPass(t, clear_color, draws[0..count], execute);
                clear_color = c;
                count = 0;
            },
            .bind_pipeline => |p| pipeline = @ptrCast(@alignCast(p)),
            .bind_vertex_buffer => |v| vertex = v,
            .draw => |d| {
                if (target == null or pipeline == null or vertex == null) return error.InvalidArgument;
                if (count == draws.len) return error.Unsupported;
                draws[count] = .{ .pipeline = pipeline.?, .vertex = vertex.?, .count = d.vertex_count, .first = d.first_vertex };
                count += 1;
            },
        };
        try self.finishPass(target orelse return error.InvalidArgument, clear_color, draws[0..count], execute);
    }

    fn finishPass(self: *Context, target: *Resource, color: ?hal.Color, draws: []const @import("render.zig").Draw, execute: bool) hal.Error!void {
        if (draws.len != 0) {
            try @import("render.zig").validate(target, draws);
            if (execute) try @import("render.zig").run(self.dev, target, color, draws);
        } else if (color) |c| {
            if (execute) try self.clearTarget(target, c);
        }
    }

    fn clearTarget(self: *Context, target: *Resource, c: hal.Color) hal.Error!void {
        // AGX linear image strides must be multiples of 16 bytes (Mesa
        // src/asahi/layout/layout.c). The library derives stride from width;
        // use a padded temporary when the HAL's packed row is unaligned.
        const width = std.mem.alignForward(u32, target.width, 4);
        const temporary = if (width != target.width)
            try self.dev.halDevice().createResource(.{ .buffer = .{ .size = @as(usize, width) * target.height * 4 } })
        else
            null;
        defer if (temporary) |res| self.dev.halDevice().destroyResource(res);
        const output: *Resource = if (temporary) |res| @ptrCast(@alignCast(res)) else target;
        // The clear render pass clears an arbitrary W x H RGBA8 image (the
        // size-dependent cmd_render/PBE/region-clip/isp_merge fields scale with
        // target.width/height). clearColorTo writes `c` to the target BO (its
        // gpu_va + size) on the GPU.
        asahi.clearColorTo(
            &self.dev.dev,
            self.dev.vm_id,
            self.dev.queue_id,
            output.bo.gpu_va,
            output.bo.size,
            width,
            target.height,
            if (target.format == .bgra8_unorm) .{ c.b, c.g, c.r, c.a } else .{ c.r, c.g, c.b, c.a },
        ) catch |e| return aserr(e);
        asahi.cleanInvalidateToPoC(output.bo.cpu);
        if (temporary != null) {
            const row = @as(usize, target.width) * 4;
            for (0..target.height) |y| {
                @memcpy(target.bo.cpu[y * row ..][0..row], output.bo.cpu[y * width * 4 ..][0..row]);
            }
            asahi.cleanToPoC(target.bo.cpu);
        }
    }

    fn present(ptr: *anyopaque, surface: *hal.Surface, source: *hal.Resource) hal.Error!void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        _ = self;
        const surf: *Surface = @ptrCast(@alignCast(surface));
        const src: *Resource = @ptrCast(@alignCast(source));
        if (src.kind != .image) return error.InvalidArgument;
        asahi.cleanInvalidateToPoC(src.bo.cpu);

        // The GPU wrote the source framebuffer (the clear's fence already flushed
        // it to memory). CPU-blit it into the platform surface's current buffer.
        const src_bytes = src.bo.cpu;
        const src_w = src.width;
        const src_stride: u32 = src.width * 4; // linear RGBA8, 4 bytes/pixel

        const dstbuf = try surf.platform.currentBuffer();
        if (dstbuf.format != .rgba8_unorm and dstbuf.format != .bgra8_unorm) return error.Unsupported;
        // The source render target is linear RGBA8 (byte0=R,1=G,2=B,3=A). A bgra8
        // surface buffer wants B,G,R,A: swap the red/blue lanes. An rgba8 buffer
        // blits straight across.
        const swap = dstbuf.format != src.format;
        const copy_w = @min(src_w, dstbuf.width);
        const copy_h = @min(src.height, dstbuf.height);
        var y: u32 = 0;
        while (y < copy_h) : (y += 1) {
            const src_row = src_bytes[@as(usize, y) * src_stride ..][0 .. copy_w * 4];
            const dst_row = dstbuf.bytes[@as(usize, y) * dstbuf.stride ..][0 .. copy_w * 4];
            if (swap) {
                var x: usize = 0;
                while (x < copy_w) : (x += 1) {
                    const o = x * 4;
                    dst_row[o + 0] = src_row[o + 2]; // B <- R
                    dst_row[o + 1] = src_row[o + 1]; // G
                    dst_row[o + 2] = src_row[o + 0]; // R <- B
                    dst_row[o + 3] = src_row[o + 3]; // A
                }
            } else {
                @memcpy(dst_row, src_row);
            }
        }
        try surf.platform.commit();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        self.dev.gpa.destroy(self);
    }

    const vtable = hal.Context.VTable{
        .beginCommands = &beginCommands,
        .submit = &submit,
        .present = &present,
        .deinit = &deinit,
    };
};

test {
    _ = @import("surface.zig");
}

test "apple draw without render state is rejected before touching the GPU" {
    // No GPU needed: drive only the record + the submit-replay's draw rejection by
    // building a Context shell over a fake device pointer that submit never
    // dereferences before checking for a bound render target and vertex buffer.
    const gpa = std.testing.allocator;

    // A CommandBuffer that records a pipeline bind + a draw.
    const cb = try CommandBuffer.create(gpa);
    defer cb.deinit();
    // bindPipeline / draw take opaque pointers we never dereference here.
    var dummy_pipe: u64 = 0;
    try cb.bindPipeline(@ptrCast(&dummy_pipe));
    try cb.draw(3, 0);

    // submit must see the draw record and reject the whole submission.
    var devshell: AppleDevice = undefined;
    var ctx = Context{ .dev = &devshell };
    try std.testing.expectError(error.InvalidArgument, Context.submit(&ctx, cb));
}

test "apple submit with neither RT nor clear is InvalidArgument (no GPU touched)" {
    const gpa = std.testing.allocator;
    const cb = try CommandBuffer.create(gpa);
    defer cb.deinit();
    // empty command buffer: no render target -> InvalidArgument before any GPU op.
    var devshell: AppleDevice = undefined;
    var ctx = Context{ .dev = &devshell };
    try std.testing.expectError(error.InvalidArgument, Context.submit(&ctx, cb));
}

test "apple GPU clears multiple targets in order and presents both channel orders" {
    const driver = @import("../apple.zig").driver;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(std.testing.allocator, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const platform = @import("../../platform.zig");
    const display = try platform.headless.create(std.testing.allocator);
    defer display.deinit();

    const rgba = try dev.createResource(.{ .image = .{ .width = 65, .height = 37, .format = .rgba8_unorm } });
    defer dev.destroyResource(rgba);
    const bgra = try dev.createResource(.{ .image = .{ .width = 65, .height = 37, .format = .bgra8_unorm } });
    defer dev.destroyResource(bgra);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(rgba);
    try cb.clear(.{ .r = 1, .g = 0, .b = 0, .a = 1 });
    try cb.setRenderTarget(bgra);
    try cb.clear(.{ .r = 0, .g = 0, .b = 1, .a = 1 });
    try ctx.submit(cb);
    const red = [_]u8{ 255, 0, 0, 255 };
    for ([_]*hal.Resource{ rgba, bgra }) |res| {
        const bytes = try dev.mapResource(res);
        var i: usize = 0;
        while (i < bytes.len) : (i += 4) {
            try std.testing.expectEqualSlices(u8, &red, bytes[i..][0..4]);
        }
    }

    inline for (.{ hal.Format.rgba8_unorm, hal.Format.bgra8_unorm }) |format| {
        var surface = try display.createSurface(.{ .width = 65, .height = 37, .format = format });
        defer surface.deinit();
        const hs = try dev.createSurface(@ptrCast(&surface));
        defer dev.destroySurface(hs);
        try ctx.present(hs, bgra);
        const pixels = try surface.currentBuffer();
        const expected = if (format == .rgba8_unorm) [_]u8{ 0, 0, 255, 255 } else red;
        try std.testing.expectEqualSlices(u8, &expected, pixels.bytes[0..4]);
    }

    // Re-submit after all fixed-VA render infrastructure was released.
    cb.reset();
    try cb.setRenderTarget(rgba);
    try cb.clear(.{ .r = 0, .g = 1, .b = 0, .a = 1 });
    try ctx.submit(cb);
    const green = [_]u8{ 0, 255, 0, 255 };
    try std.testing.expectEqualSlices(u8, &green, (try dev.mapResource(rgba))[0..4]);
}
