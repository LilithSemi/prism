const std = @import("std");
const mali = @import("mali");
const hal = @import("../../hal.zig");
const Device = @import("device.zig").Device;
const merr = @import("device.zig").merr;
const Resource = @import("resource.zig").Resource;
const Surface = @import("surface.zig").Surface;
const Pipeline = @import("graphics.zig").Pipeline;

const Draw = struct { vertex_count: u32, first_vertex: u32 };

const Command = union(enum) {
    set_render_target: *Resource,
    clear: hal.Color,
    bind_pipeline: *Pipeline,
    bind_vertex_buffer: *Resource,
    bind_texture: hal.TextureBinding,
    set_scissor: ?hal.ScissorRect,
    draw: Draw,
};

pub const CommandBuffer = struct {
    gpa: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(Command) = .empty,

    fn create(gpa: std.mem.Allocator) hal.Error!hal.CommandBuffer {
        const self = gpa.create(CommandBuffer) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn setRenderTarget(ptr: *anyopaque, handle: *hal.Resource) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        const resource: *Resource = @ptrCast(@alignCast(handle));
        if (resource.kind != .image or resource.format != .rgba8_unorm) return error.Unsupported;
        self.commands.append(self.gpa, .{ .set_render_target = resource }) catch return error.OutOfMemory;
    }

    fn clear(ptr: *anyopaque, color: hal.Color) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.append(self.gpa, .{ .clear = color }) catch return error.OutOfMemory;
    }

    fn bindPipeline(ptr: *anyopaque, pipeline: *hal.Pipeline) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.append(self.gpa, .{ .bind_pipeline = @ptrCast(@alignCast(pipeline)) }) catch return error.OutOfMemory;
    }

    fn bindVertexBuffer(ptr: *anyopaque, buffer: *hal.Resource) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.append(self.gpa, .{ .bind_vertex_buffer = @ptrCast(@alignCast(buffer)) }) catch return error.OutOfMemory;
    }

    fn bindTexture(ptr: *anyopaque, binding: hal.TextureBinding) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.append(self.gpa, .{ .bind_texture = binding }) catch return error.OutOfMemory;
    }

    fn draw(ptr: *anyopaque, vertex_count: u32, first_vertex: u32) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.append(self.gpa, .{ .draw = .{ .vertex_count = vertex_count, .first_vertex = first_vertex } }) catch return error.OutOfMemory;
    }

    fn setScissor(ptr: *anyopaque, rect: ?hal.ScissorRect) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.append(self.gpa, .{ .set_scissor = rect }) catch return error.OutOfMemory;
    }

    fn reset(ptr: *anyopaque) void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        self.commands.clearRetainingCapacity();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        const gpa = self.gpa;
        self.commands.deinit(gpa);
        gpa.destroy(self);
    }

    const vtable = hal.CommandBuffer.VTable{
        .setRenderTarget = &setRenderTarget,
        .clear = &clear,
        .bindPipeline = &bindPipeline,
        .bindVertexBuffer = &bindVertexBuffer,
        .bindTexture = &bindTexture,
        .setScissor = &setScissor,
        .draw = &draw,
        .reset = &reset,
        .deinit = &deinit,
    };
};

pub const Context = struct {
    dev: *Device,

    pub fn create(dev: *Device) hal.Error!hal.Context {
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
        const buffer: *CommandBuffer = @ptrCast(@alignCast(cb.ptr));
        var work = try plan(self.dev.gpa, buffer);
        defer work.deinit(self.dev.gpa);
        const target = work.target orelse return;
        const image = mali.Image{
            .bo = target.bo,
            .width = @intCast(target.width),
            .height = @intCast(target.height),
            .row_stride = target.row_stride,
        };
        if (work.draws.items.len != 0) {
            const draws = self.dev.gpa.alloc(mali.graphics.DrawRgba8, work.draws.items.len) catch return error.OutOfMemory;
            defer self.dev.gpa.free(draws);
            for (work.draws.items, draws) |planned, *native| {
                if (planned.texture) |binding| bindingResource(binding).syncForGpu();
                const offset = @as(usize, planned.draw.first_vertex) * planned.pipeline.stride;
                native.* = .{
                    .pipeline = planned.pipeline.native,
                    .vertices = .{
                        .handle = planned.vertex.bo.handle,
                        .gpu_va = planned.vertex.bo.gpu_va + offset,
                        .cpu = planned.vertex.bo.cpu[offset..],
                        .size = planned.vertex.bo.size - offset,
                    },
                    .vertex_count = planned.draw.vertex_count,
                    .texture = if (planned.texture) |binding| textureImage(binding.image) else null,
                    .texture_swizzle = if (planned.texture) |binding| packedSwizzle(binding.swizzle) else 0x688,
                    .texture_min_filter = if (planned.texture) |binding| samplerFilter(binding.min_filter) else .linear,
                    .texture_mag_filter = if (planned.texture) |binding| samplerFilter(binding.filter) else .linear,
                    .texture_address_u = if (planned.texture) |binding| samplerAddress(binding.address_u) else .clamp_to_edge,
                    .texture_address_v = if (planned.texture) |binding| samplerAddress(binding.address_v) else .clamp_to_edge,
                    .scissor = planned.scissor,
                };
            }
            mali.graphics.drawBatchRgba8(
                &self.dev.session,
                image,
                draws,
                packedColor(work.clear.?),
                5_000_000_000,
            ) catch |err| return merr(err);
            target.markGpuWritten();
        } else if (work.clear) |color| {
            mali.graphics.clearRgba8(&self.dev.session, image, colorBytes(color), 5_000_000_000) catch |err| return merr(err);
            target.markGpuWritten();
        }
    }

    fn present(ptr: *anyopaque, opaque_surface: *hal.Surface, opaque_source: *hal.Resource) hal.Error!void {
        _ = ptr;
        const surface: *Surface = @ptrCast(@alignCast(opaque_surface));
        const source: *Resource = @ptrCast(@alignCast(opaque_source));
        if (source.kind != .image or source.format != .rgba8_unorm) return error.Unsupported;
        source.syncForGpu();
        const dst = try surface.platform.currentBuffer();
        if (dst.format != .rgba8_unorm and dst.format != .bgra8_unorm) return error.Unsupported;
        const copy_width = @min(source.width, dst.width);
        const copy_height = @min(source.height, dst.height);
        for (0..copy_height) |y| {
            const src_row = source.bo.cpu[y * source.row_stride ..][0 .. copy_width * 4];
            const dst_row = dst.bytes[y * dst.stride ..][0 .. copy_width * 4];
            if (dst.format == .rgba8_unorm) {
                @memcpy(dst_row, src_row);
            } else {
                for (0..copy_width) |x| {
                    const offset = x * 4;
                    dst_row[offset + 0] = src_row[offset + 2];
                    dst_row[offset + 1] = src_row[offset + 1];
                    dst_row[offset + 2] = src_row[offset + 0];
                    dst_row[offset + 3] = src_row[offset + 3];
                }
            }
        }
        try surface.platform.commit();
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

const Work = struct {
    target: ?*Resource = null,
    clear: ?hal.Color = null,
    pipeline: ?*Pipeline = null,
    vertex: ?*Resource = null,
    texture: ?hal.TextureBinding = null,
    scissor: ?hal.ScissorRect = null,
    draws: std.ArrayListUnmanaged(PlannedDraw) = .empty,

    fn deinit(self: *Work, gpa: std.mem.Allocator) void {
        self.draws.deinit(gpa);
        self.* = undefined;
    }
};

const PlannedDraw = struct {
    pipeline: *Pipeline,
    vertex: *Resource,
    texture: ?hal.TextureBinding,
    draw: Draw,
    scissor: ?mali.graphics.Scissor,
};

/// Validate the complete command stream before the first GPU side effect.
fn plan(gpa: std.mem.Allocator, buffer: *const CommandBuffer) hal.Error!Work {
    var work: Work = .{};
    errdefer work.deinit(gpa);
    for (buffer.commands.items) |command| switch (command) {
        .set_render_target => |resource| {
            if (resource.kind != .image or resource.format != .rgba8_unorm) return error.InvalidArgument;
            if (work.target != null and work.target != resource) return error.Unsupported;
            work.target = resource;
        },
        .clear => |color| {
            if (work.target == null or work.draws.items.len != 0) return error.InvalidArgument;
            if (work.scissor != null) return error.Unsupported;
            work.clear = color;
        },
        .bind_pipeline => |pipeline| work.pipeline = pipeline,
        .bind_vertex_buffer => |vertex| {
            if (vertex.kind != .buffer) return error.InvalidArgument;
            work.vertex = vertex;
        },
        .bind_texture => |binding| {
            const texture: *Resource = @ptrCast(@alignCast(binding.image));
            if (texture.kind != .image or texture.format != .rgba8_unorm or
                binding.mip_filter != .none or binding.max_anisotropy != 1 or
                binding.base_level != 0 or binding.lod_bias != 0 or
                binding.compare_enable)
                return error.Unsupported;
            work.texture = binding;
        },
        .set_scissor => |rect| work.scissor = rect,
        .draw => |draw_call| {
            const pipeline = work.pipeline orelse return error.InvalidArgument;
            const vertex = work.vertex orelse return error.InvalidArgument;
            const texture = if (pipeline.requires_texture)
                work.texture orelse return error.InvalidArgument
            else
                null;
            if (work.target == null or work.clear == null or draw_call.vertex_count == 0 or draw_call.vertex_count % 3 != 0)
                return error.InvalidArgument;
            const first_byte = std.math.mul(u64, draw_call.first_vertex, pipeline.stride) catch return error.InvalidArgument;
            const draw_bytes = std.math.mul(u64, draw_call.vertex_count, pipeline.stride) catch return error.InvalidArgument;
            const end = std.math.add(u64, first_byte, draw_bytes) catch return error.InvalidArgument;
            if (end > vertex.bo.size) return error.InvalidArgument;
            const scissor = try clippedScissor(work.scissor, work.target.?);
            // A fully clipped draw has no visible side effects, but all of its
            // bindings and bounds above were still validated.
            if (work.scissor != null and scissor == null) continue;
            work.draws.append(gpa, .{
                .pipeline = pipeline,
                .vertex = vertex,
                .texture = texture,
                .draw = draw_call,
                .scissor = scissor,
            }) catch return error.OutOfMemory;
        },
    };
    return work;
}

fn textureImage(handle: *hal.Resource) mali.Image {
    const resource: *Resource = @ptrCast(@alignCast(handle));
    return .{
        .bo = resource.bo,
        .width = @intCast(resource.width),
        .height = @intCast(resource.height),
        .row_stride = resource.row_stride,
    };
}

fn bindingResource(binding: hal.TextureBinding) *Resource {
    return @ptrCast(@alignCast(binding.image));
}

fn packedSwizzle(swizzle: [4]hal.Swizzle) u12 {
    var result: u12 = 0;
    for (swizzle, 0..) |channel_, index_| {
        const component: u12 = switch (channel_) {
            .r => 0,
            .g => 1,
            .b => 2,
            .a => 3,
            .zero => 4,
            .one => 5,
        };
        result |= component << @intCast(index_ * 3);
    }
    return result;
}

fn samplerFilter(filter: hal.Filter) mali.descriptors.SamplerLinearClamp.Filter {
    return switch (filter) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn samplerAddress(mode: hal.AddressMode) mali.descriptors.SamplerLinearClamp.AddressMode {
    return switch (mode) {
        .repeat => .repeat,
        .clamp_to_edge => .clamp_to_edge,
        .mirrored_repeat => .mirrored_repeat,
    };
}

fn clippedScissor(rect: ?hal.ScissorRect, target: *const Resource) hal.Error!?mali.graphics.Scissor {
    const source = rect orelse return null;
    if (source.width == 0 or source.height == 0) return null;
    const x0 = @max(@as(i64, 0), source.x);
    const y0 = @max(@as(i64, 0), source.y);
    const source_x1 = std.math.add(i64, source.x, @as(i64, source.width)) catch return error.InvalidArgument;
    const source_y1 = std.math.add(i64, source.y, @as(i64, source.height)) catch return error.InvalidArgument;
    const x1 = @min(@as(i64, target.width), source_x1);
    const y1 = @min(@as(i64, target.height), source_y1);
    if (x0 >= x1 or y0 >= y1) return null;
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

fn colorBytes(color: hal.Color) [4]u8 {
    return .{ channel(color.r), channel(color.g), channel(color.b), channel(color.a) };
}

fn packedColor(color: hal.Color) u32 {
    const bytes = colorBytes(color);
    return std.mem.readInt(u32, &bytes, .little);
}

fn channel(value: f32) u8 {
    const clamped = @max(0.0, @min(1.0, value));
    return @intFromFloat(@round(clamped * 255.0));
}

test "Mali clear color conversion clamps and rounds HAL colors" {
    try std.testing.expectEqual([4]u8{ 0, 128, 255, 255 }, colorBytes(.{ .r = -1, .g = 0.5, .b = 2, .a = 1 }));
    try std.testing.expectEqual(@as(u12, 0x688), packedSwizzle(.{ .r, .g, .b, .a }));
    try std.testing.expectEqual(@as(u12, 0x16d), packedSwizzle(.{ .one, .one, .one, .r }));
}

test "Mali command buffer records native graphics state without dereferencing handles" {
    const cb = try CommandBuffer.create(std.testing.allocator);
    defer cb.deinit();
    var pipeline: u64 = 0;
    var vertex: u64 = 0;
    try cb.bindPipeline(@ptrCast(&pipeline));
    try cb.bindVertexBuffer(@ptrCast(&vertex));
    try cb.draw(3, 0);
    const internal: *CommandBuffer = @ptrCast(@alignCast(cb.ptr));
    try std.testing.expectEqual(@as(usize, 3), internal.commands.items.len);
}

test "Mali submit planning validates a complete draw and vertex bounds before GPU work" {
    var target_bytes: [256]u8 = @splat(0);
    var vertex_bytes: [32]u8 = @splat(0);
    var target = Resource{
        .kind = .image,
        .desc = .{ .image = .{ .width = 8, .height = 8, .format = .rgba8_unorm } },
        .bo = .{ .handle = 1, .gpu_va = 0x1000, .cpu = &target_bytes, .size = target_bytes.len },
        .gpa = std.testing.allocator,
        .byte_size = target_bytes.len,
        .width = 8,
        .height = 8,
        .row_stride = 32,
    };
    var vertex = Resource{
        .kind = .buffer,
        .desc = .{ .buffer = .{ .size = vertex_bytes.len } },
        .bo = .{ .handle = 2, .gpu_va = 0x2000, .cpu = &vertex_bytes, .size = vertex_bytes.len },
        .gpa = std.testing.allocator,
        .byte_size = vertex_bytes.len,
    };
    var pipeline = Pipeline{ .native = undefined, .stride = 8, .requires_texture = false };
    const cb = try CommandBuffer.create(std.testing.allocator);
    defer cb.deinit();
    try cb.setRenderTarget(@ptrCast(&target));
    try cb.clear(.{ .b = 1 });
    try cb.bindPipeline(@ptrCast(&pipeline));
    try cb.bindVertexBuffer(@ptrCast(&vertex));
    try cb.setScissor(.{ .x = -2, .y = 2, .width = 6, .height = 4 });
    try cb.draw(3, 1);
    try cb.draw(3, 0);
    const internal: *CommandBuffer = @ptrCast(@alignCast(cb.ptr));
    var work = try plan(std.testing.allocator, internal);
    defer work.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), work.draws.items.len);
    try std.testing.expectEqual(@as(u32, 1), work.draws.items[0].draw.first_vertex);
    try std.testing.expectEqual(@as(u32, 0), work.draws.items[1].draw.first_vertex);
    try std.testing.expectEqual(mali.graphics.Scissor{ .x = 0, .y = 2, .width = 4, .height = 4 }, work.draws.items[0].scissor.?);

    vertex.bo.size = 24;
    try std.testing.expectError(error.InvalidArgument, plan(std.testing.allocator, internal));
}

test "Mali planning carries Phantom texture state into a textured draw" {
    var target_bytes: [256]u8 = @splat(0);
    var vertex_bytes: [96]u8 = @splat(0);
    var texture_bytes: [256]u8 = @splat(0);
    var target = Resource{
        .kind = .image,
        .desc = .{ .image = .{ .width = 8, .height = 8, .format = .rgba8_unorm } },
        .bo = .{ .handle = 1, .gpu_va = 0x1000, .cpu = &target_bytes, .size = target_bytes.len },
        .gpa = std.testing.allocator,
        .byte_size = target_bytes.len,
        .width = 8,
        .height = 8,
        .row_stride = 32,
    };
    var vertex = Resource{
        .kind = .buffer,
        .desc = .{ .buffer = .{ .size = vertex_bytes.len } },
        .bo = .{ .handle = 2, .gpu_va = 0x2000, .cpu = &vertex_bytes, .size = vertex_bytes.len },
        .gpa = std.testing.allocator,
        .byte_size = vertex_bytes.len,
    };
    var texture = Resource{
        .kind = .image,
        .desc = .{ .image = .{ .width = 8, .height = 8, .format = .rgba8_unorm } },
        .bo = .{ .handle = 3, .gpu_va = 0x3000, .cpu = &texture_bytes, .size = texture_bytes.len },
        .gpa = std.testing.allocator,
        .byte_size = texture_bytes.len,
        .width = 8,
        .height = 8,
        .row_stride = 32,
    };
    var pipeline = Pipeline{ .native = undefined, .stride = 32, .requires_texture = true };
    const cb = try CommandBuffer.create(std.testing.allocator);
    defer cb.deinit();
    try cb.setRenderTarget(@ptrCast(&target));
    try cb.clear(.{ .b = 1 });
    try cb.bindPipeline(@ptrCast(&pipeline));
    try cb.bindVertexBuffer(@ptrCast(&vertex));
    try cb.bindTexture(.{
        .binding = 2,
        .image = @ptrCast(&texture),
        .filter = .nearest,
        .min_filter = .nearest,
        .swizzle = .{ .one, .one, .one, .r },
    });
    try cb.draw(3, 0);

    const internal: *CommandBuffer = @ptrCast(@alignCast(cb.ptr));
    var work = try plan(std.testing.allocator, internal);
    defer work.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), work.draws.items.len);
    const binding = work.draws.items[0].texture.?;
    try std.testing.expectEqual(@as(*hal.Resource, @ptrCast(&texture)), binding.image);
    try std.testing.expectEqual(hal.Filter.nearest, binding.filter);
    try std.testing.expectEqual(hal.Filter.nearest, binding.min_filter);
    try std.testing.expectEqual(@as(u12, 0x16d), packedSwizzle(binding.swizzle));
}
