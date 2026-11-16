const std = @import("std");
const mali = @import("mali");
const hal = @import("../../hal.zig");
const Device = @import("device.zig").Device;
const merr = @import("device.zig").merr;
const Resource = @import("resource.zig").Resource;
const Surface = @import("surface.zig").Surface;
const Pipeline = @import("graphics.zig").Pipeline;
const native_draw = @import("native_draw.zig");

const Draw = struct { vertex_count: u32, first_vertex: u32 };

const Command = union(enum) {
    set_render_target: *Resource,
    set_depth_target: struct { resource: *Resource, clear: ?f32 },
    clear: hal.Color,
    bind_pipeline: *Pipeline,
    bind_vertex_buffer: *Resource,
    bind_uniform_buffer: struct { binding: u32, bytes: []u8 },
    bind_texture: hal.TextureBinding,
    set_scissor: ?hal.ScissorRect,
    set_viewport: ?hal.Viewport,
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

    fn setDepthTarget(ptr: *anyopaque, handle: *hal.Resource, clear_value: ?f32) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        const resource: *Resource = @ptrCast(@alignCast(handle));
        if (resource.kind != .image or resource.format != .depth32_float) return error.Unsupported;
        if (clear_value) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidArgument;
        self.commands.append(self.gpa, .{ .set_depth_target = .{ .resource = resource, .clear = clear_value } }) catch return error.OutOfMemory;
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

    fn bindUniformBuffer(ptr: *anyopaque, binding: u32, handle: *hal.Resource) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        const resource: *Resource = @ptrCast(@alignCast(handle));
        if (binding >= 2) return error.Unsupported;
        if (resource.kind != .buffer) return error.InvalidArgument;
        // GLES reuses stage UBOs while a batch is still being recorded.
        // Own this binding's bytes so later uploads cannot change earlier draws.
        const bytes = self.gpa.dupe(u8, uniformBytes(resource)) catch return error.OutOfMemory;
        errdefer self.gpa.free(bytes);
        self.commands.append(self.gpa, .{ .bind_uniform_buffer = .{ .binding = binding, .bytes = bytes } }) catch return error.OutOfMemory;
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

    fn setViewport(ptr: *anyopaque, viewport: ?hal.Viewport) hal.Error!void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        if (viewport) |vp| {
            if (!std.math.isFinite(vp.depth_near) or !std.math.isFinite(vp.depth_far) or vp.depth_near < 0 or vp.depth_near > 1 or vp.depth_far < 0 or vp.depth_far > 1) return error.InvalidArgument;
        }
        self.commands.append(self.gpa, .{ .set_viewport = viewport }) catch return error.OutOfMemory;
    }

    fn reset(ptr: *anyopaque) void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        for (self.commands.items) |command| switch (command) {
            .bind_uniform_buffer => |binding| self.gpa.free(binding.bytes),
            else => {},
        };
        self.commands.clearRetainingCapacity();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *CommandBuffer = @ptrCast(@alignCast(ptr));
        const gpa = self.gpa;
        reset(ptr);
        self.commands.deinit(gpa);
        gpa.destroy(self);
    }

    const vtable = hal.CommandBuffer.VTable{
        .setRenderTarget = &setRenderTarget,
        .setDepthTarget = &setDepthTarget,
        .clear = &clear,
        .bindPipeline = &bindPipeline,
        .bindVertexBuffer = &bindVertexBuffer,
        .bindTexture = &bindTexture,
        .bindUniformBuffer = &bindUniformBuffer,
        .setScissor = &setScissor,
        .setViewport = &setViewport,
        .draw = &draw,
        .reset = &reset,
        .deinit = &deinit,
    };
};

pub const Context = struct {
    dev: *Device,
    profile: ?Profile = null,
    draw_cache: native_draw.Cache = .{},

    const Profile = struct {
        since: u64,
        frames: u64 = 0,
        submits: u64 = 0,
        submit_ns: u64 = 0,
        present_ns: u64 = 0,
        pipelines: u64 = 0,
    };

    fn now() u64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    pub fn create(dev: *Device) hal.Error!hal.Context {
        const self = dev.gpa.create(Context) catch return error.OutOfMemory;
        self.* = .{ .dev = dev };
        if (comptime @import("builtin").link_libc and !@import("builtin").is_test) {
            if (std.c.getenv("PRISM_MALI_PROFILE") != null)
                self.profile = .{ .since = now(), .pipelines = dev.pipeline_creations };
        }
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn beginCommands(ptr: *anyopaque) hal.Error!hal.CommandBuffer {
        const self: *Context = @ptrCast(@alignCast(ptr));
        return CommandBuffer.create(self.dev.gpa);
    }

    fn submit(ptr: *anyopaque, cb: hal.CommandBuffer) hal.Error!void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const started = if (self.profile != null) now() else 0;
        defer if (self.profile) |*profile| {
            profile.submits += 1;
            profile.submit_ns += now() - started;
        };
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
        if (work.depth) |depth| depth.syncForGpu();
        if (work.draws.items.len != 0) {
            const draws = self.dev.gpa.alloc(native_draw.Draw, work.draws.items.len + work.depth_clears.items.len) catch return error.OutOfMemory;
            defer self.dev.gpa.free(draws);
            var out: usize = 0;
            var clear_index: usize = 0;
            for (work.draws.items, 0..) |planned, draw_index| {
                while (clear_index < work.depth_clears.items.len and work.depth_clears.items[clear_index].before == draw_index) : (clear_index += 1) {
                    draws[out] = self.draw_cache.clearDepth(&self.dev.session, textureImage(@ptrCast(work.depth.?)), work.depth_clears.items[clear_index].value) catch |err| return merr(err);
                    out += 1;
                }
                const native = &draws[out];
                out += 1;
                for (planned.textures) |maybe| if (maybe) |binding| bindingResource(binding).syncForGpu();
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
                    .viewport = planned.viewport,
                    .blend = planned.pipeline.blend_mode,
                    .cull = planned.pipeline.cull,
                    .depth = planned.pipeline.depth,
                    .shader_coverage = planned.pipeline.writes_coverage,
                    .depth_target = if (work.depth) |depth| textureImage(@ptrCast(depth)) else null,
                    .depth_clear = work.depth_clear orelse 1,
                    .depth_load = work.depth != null and work.depth_clear == null,
                    .stride = planned.pipeline.stride,
                    .attributes = planned.pipeline.attributes[0..planned.pipeline.attribute_count],
                    .vertex_uniforms = planned.uniforms[0],
                    .varying_size = planned.pipeline.varying_size,
                    .fragment_uniforms = planned.uniforms[1],
                };
                for (planned.textures, 0..) |maybe, slot| if (maybe) |binding| {
                    native.textures[slot] = .{
                        .image = textureImage(binding.image),
                        .swizzle = packedSwizzle(binding.swizzle),
                        .min_filter = samplerFilter(binding.min_filter),
                        .mag_filter = samplerFilter(binding.filter),
                        .address_u = samplerAddress(binding.address_u),
                        .address_v = samplerAddress(binding.address_v),
                    };
                };
            }
            // A trailing clear still has an effect when no later visible draw
            // consumes it (including draws clipped entirely out of the target).
            while (clear_index < work.depth_clears.items.len) : (clear_index += 1) {
                draws[out] = self.draw_cache.clearDepth(&self.dev.session, textureImage(@ptrCast(work.depth.?)), work.depth_clears.items[clear_index].value) catch |err| return merr(err);
                out += 1;
            }
            std.debug.assert(out == draws.len);
            native_draw.drawBatchCached(
                &self.dev.session,
                image,
                draws,
                if (work.clear) |color| packedColor(color) else null,
                5_000_000_000,
                &self.draw_cache,
            ) catch |err| return merr(err);
            target.markGpuWritten();
            if (work.depth) |depth| depth.markGpuWritten();
        } else if (work.clear) |color| {
            mali.graphics.clearRgba8(&self.dev.session, image, colorBytes(color), 5_000_000_000) catch |err| return merr(err);
            target.markGpuWritten();
        }
        if (work.draws.items.len == 0) {
            if (work.depth_clear) |value| {
                const depth = work.depth orelse return error.InvalidArgument;
                const bits: u32 = @bitCast(value);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, bits, .little);
                // RGBA8 and D32F share a RAW32 linear storage layout. A native
                // raw clear through the RGBA8 view writes the exact depth bits.
                mali.graphics.clearRgba8(&self.dev.session, textureImage(@ptrCast(depth)), bytes, 5_000_000_000) catch |err| return merr(err);
                depth.markGpuWritten();
            }
        }
    }

    fn present(ptr: *anyopaque, opaque_surface: *hal.Surface, opaque_source: *hal.Resource) hal.Error!void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const started = if (self.profile != null) now() else 0;
        defer if (self.profile) |*profile| {
            const ended = now();
            profile.frames += 1;
            profile.present_ns += ended - started;
            if (ended - profile.since >= 5_000_000_000) {
                const frames: f64 = @floatFromInt(profile.frames);
                std.debug.print("[prism-mali] fps={d:.2} submit_ms/frame={d:.2} present_ms/frame={d:.2} submits/frame={d:.2} pipelines/frame={d:.2}\n", .{
                    frames * 1_000_000_000 / @as(f64, @floatFromInt(ended - profile.since)),
                    @as(f64, @floatFromInt(profile.submit_ns)) / frames / 1_000_000,
                    @as(f64, @floatFromInt(profile.present_ns)) / frames / 1_000_000,
                    @as(f64, @floatFromInt(profile.submits)) / frames,
                    @as(f64, @floatFromInt(self.dev.pipeline_creations - profile.pipelines)) / frames,
                });
                profile.* = .{ .since = ended, .pipelines = self.dev.pipeline_creations };
            }
        };
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
                // Panthor's default CPU mapping is uncached. Read it in bulk,
                // then convert in the platform's cached staging buffer. Scalar
                // byte reads from the GPU mapping dominate large-window frames.
                @memcpy(dst_row, src_row);
                swapRedBlue(dst_row);
            }
        }
        try surface.platform.commit();
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ptr));
        self.draw_cache.deinit(&self.dev.session);
        self.dev.gpa.destroy(self);
    }

    const vtable = hal.Context.VTable{
        .beginCommands = &beginCommands,
        .submit = &submit,
        .present = &present,
        .deinit = &deinit,
    };
};

// Keep conversion separate from the copy so optimization cannot turn it back
// into a byte-at-a-time gather from uncached GPU memory.
noinline fn swapRedBlue(row: []u8) void {
    var offset: usize = 0;
    while (offset + 4 <= row.len) : (offset += 4) {
        const pixel = std.mem.readInt(u32, row[offset..][0..4], .little);
        const swapped = (pixel & 0xff00ff00) | ((pixel & 0xff) << 16) | ((pixel >> 16) & 0xff);
        std.mem.writeInt(u32, row[offset..][0..4], swapped, .little);
    }
}

test "Mali presentation swaps red and blue in unaligned rows without changing alpha or padding" {
    var bytes = [_]u8{ 99, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 88 };
    swapRedBlue(bytes[1..13]);
    try std.testing.expectEqualSlices(u8, &.{ 99, 3, 2, 1, 4, 7, 6, 5, 8, 11, 10, 9, 12, 88 }, &bytes);
}

const Work = struct {
    target: ?*Resource = null,
    depth: ?*Resource = null,
    depth_clear: ?f32 = null,
    clear: ?hal.Color = null,
    pipeline: ?*Pipeline = null,
    vertex: ?*Resource = null,
    texture: ?hal.TextureBinding = null,
    textures: [8]?hal.TextureBinding = @splat(null),
    scissor: ?hal.ScissorRect = null,
    viewport: ?hal.Viewport = null,
    uniforms: [2][]const u8 = .{ &.{}, &.{} },
    draws: std.ArrayListUnmanaged(PlannedDraw) = .empty,
    depth_clears: std.ArrayListUnmanaged(struct { before: usize, value: f32 }) = .empty,

    fn deinit(self: *Work, gpa: std.mem.Allocator) void {
        self.draws.deinit(gpa);
        self.depth_clears.deinit(gpa);
        self.* = undefined;
    }
};

const PlannedDraw = struct {
    pipeline: *Pipeline,
    vertex: *Resource,
    texture: ?hal.TextureBinding,
    textures: [8]?hal.TextureBinding,
    draw: Draw,
    scissor: ?mali.graphics.Scissor,
    viewport: ?hal.Viewport,
    uniforms: [2][]const u8,
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
        .set_depth_target => |binding| {
            if (work.depth != null and work.depth != binding.resource) return error.Unsupported;
            work.depth = binding.resource;
            if (binding.clear) |value| {
                if (work.draws.items.len == 0) {
                    work.depth_clear = value;
                } else {
                    work.depth_clears.append(gpa, .{ .before = work.draws.items.len, .value = value }) catch return error.OutOfMemory;
                }
            }
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
        .bind_uniform_buffer => |binding| work.uniforms[binding.binding] = binding.bytes,
        .bind_texture => |binding| {
            const texture: *Resource = @ptrCast(@alignCast(binding.image));
            if (texture.kind != .image or texture.format != .rgba8_unorm or
                binding.mip_filter != .none or binding.max_anisotropy != 1 or
                binding.base_level != 0 or binding.lod_bias != 0 or
                binding.compare_enable)
                return error.Unsupported;
            if (binding.binding >= 10) return error.Unsupported;
            const slot = if (binding.binding >= 2) binding.binding - 2 else 0;
            work.textures[slot] = binding;
            work.texture = work.textures[0];
        },
        .set_scissor => |rect| work.scissor = rect,
        .set_viewport => |vp| work.viewport = vp,
        .draw => |draw_call| {
            const pipeline = work.pipeline orelse return error.InvalidArgument;
            const vertex = work.vertex orelse return error.InvalidArgument;
            if (pipeline.depth.test_enable and work.depth == null) return error.InvalidArgument;
            if (work.depth) |depth| {
                const target = work.target orelse return error.InvalidArgument;
                if (target.width != depth.width or target.height != depth.height) return error.InvalidArgument;
            }
            if (work.uniforms[0].len < pipeline.vertex_uniform_bytes or
                work.uniforms[1].len < pipeline.fragment_uniform_bytes) return error.InvalidArgument;
            const required = pipeline.texture_mask | @as(u8, if (pipeline.requires_texture and pipeline.texture_mask == 0) 1 else 0);
            for (work.textures, 0..) |binding, slot| {
                if (required & (@as(u8, 1) << @as(u3, @intCast(slot))) != 0 and binding == null) return error.InvalidArgument;
            }
            const texture = if (pipeline.requires_texture and required & 1 != 0)
                work.texture orelse return error.InvalidArgument
            else
                null;
            if (work.target == null or draw_call.vertex_count == 0 or draw_call.vertex_count % 3 != 0)
                return error.InvalidArgument;
            const first_byte = std.math.mul(u64, draw_call.first_vertex, pipeline.stride) catch return error.InvalidArgument;
            const draw_bytes = std.math.mul(u64, draw_call.vertex_count, pipeline.stride) catch return error.InvalidArgument;
            const end = std.math.add(u64, first_byte, draw_bytes) catch return error.InvalidArgument;
            if (end > vertex.bo.size) return error.InvalidArgument;
            const rect = viewportScissor(work.scissor, work.viewport);
            const scissor = try clippedScissor(rect, work.target.?);
            // A fully clipped draw has no visible side effects, but all of its
            // bindings and bounds above were still validated.
            if (rect != null and scissor == null) continue;
            work.draws.append(gpa, .{
                .pipeline = pipeline,
                .vertex = vertex,
                .texture = texture,
                .textures = work.textures,
                .draw = draw_call,
                .scissor = scissor,
                .viewport = work.viewport,
                .uniforms = work.uniforms,
            }) catch return error.OutOfMemory;
        },
    };
    return work;
}

fn uniformBytes(resource: ?*Resource) []const u8 {
    const buffer = resource orelse return &.{};
    return buffer.bo.cpu[0..buffer.byte_size];
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

fn viewportScissor(scissor: ?hal.ScissorRect, viewport: ?hal.Viewport) ?hal.ScissorRect {
    const vp = viewport orelse return scissor;
    const sc = scissor orelse return .{ .x = vp.x, .y = vp.y, .width = vp.width, .height = vp.height };
    const x = @max(sc.x, vp.x);
    const y = @max(sc.y, vp.y);
    const x1 = @min(@as(i64, sc.x) + sc.width, @as(i64, vp.x) + vp.width);
    const y1 = @min(@as(i64, sc.y) + sc.height, @as(i64, vp.y) + vp.height);
    return .{ .x = x, .y = y, .width = @intCast(@max(0, x1 - x)), .height = @intCast(@max(0, y1 - y)) };
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
    try cb.bindUniformBuffer(0, @ptrCast(&vertex));
    try cb.draw(3, 1);
    // Reusing and uploading a UBO must not change an earlier binding.
    @memset(&vertex_bytes, 42);
    var later_uniform = vertex;
    try cb.bindUniformBuffer(0, @ptrCast(&later_uniform));
    try cb.bindUniformBuffer(1, @ptrCast(&vertex));
    try cb.draw(3, 0);
    @memset(&vertex_bytes, 99);
    const internal: *CommandBuffer = @ptrCast(@alignCast(cb.ptr));
    var work = try plan(std.testing.allocator, internal);
    defer work.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), work.draws.items.len);
    try std.testing.expectEqual(@as(u32, 1), work.draws.items[0].draw.first_vertex);
    try std.testing.expectEqual(@as(u32, 0), work.draws.items[1].draw.first_vertex);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), work.draws.items[0].uniforms[0]);
    try std.testing.expectEqual(@as(usize, 0), work.draws.items[0].uniforms[1].len);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(42))), work.draws.items[1].uniforms[0]);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(42))), work.draws.items[1].uniforms[1]);
    try std.testing.expectError(error.Unsupported, cb.bindUniformBuffer(2, @ptrCast(&vertex)));
    try std.testing.expectError(error.InvalidArgument, cb.bindUniformBuffer(0, @ptrCast(&target)));
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

test "Mali HAL renders padded vertex layouts with Luanti alpha blending and culling" {
    const gpa = std.testing.allocator;
    const dev = Device.create(gpa) catch return error.SkipZigTest;
    defer dev.deinit();
    const internal: *Device = @ptrCast(@alignCast(dev.ptr));
    if (internal.session.info.architecture_major != 10) return error.SkipZigTest;
    const glsl = @import("../../glsl.zig");
    const vs_code = try glsl.compileForStage(gpa, "attribute vec2 position; void main() { gl_Position = vec4(position, 0.0, 1.0); }", .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa, "precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 0.5); }", .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const target = try dev.createResource(.{ .image = .{
        .width = 32,
        .height = 32,
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    } });
    defer dev.destroyResource(target);
    const positions = [_]f32{
        99, 99, 99, -1, -1, 0.25,
        99, 99, 99, 3,  -1, 0.25,
        99, 99, 99, -1, 3,  0.25,
    };
    const vertex = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(positions)), .usage = .{ .vertex = true } } });
    defer dev.destroyResource(vertex);
    @memcpy((try dev.mapResource(vertex))[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const ctx = try dev.createContext();
    defer ctx.deinit();
    var red: [2]u8 = undefined;
    for ([_]hal.FrontFace{ .counter_clockwise, .clockwise }, &red) |face, *result| {
        const pipeline = try dev.createPipeline(.{
            .vertex = vs,
            .fragment = fs,
            .vertex_layout = .{ .stride = 24, .attributes = &.{
                .{ .location = 5, .format = .r32g32b32_float, .offset = 0 },
                .{ .location = 0, .format = .r32g32b32_float, .offset = 12 },
            } },
            .color_format = .rgba8_unorm,
            .cull = .{ .mode = .back, .front_face = face },
            .blend = .{
                .enable = true,
                .src_color = .src_alpha,
                .dst_color = .one_minus_src_alpha,
                .src_alpha = .src_alpha,
                .dst_alpha = .one_minus_src_alpha,
            },
        });
        defer dev.destroyPipeline(pipeline);
        const commands = try ctx.beginCommands();
        defer commands.deinit();
        try commands.setRenderTarget(target);
        try commands.clear(.{ .b = 1, .a = 0.25 });
        try commands.bindPipeline(pipeline);
        try commands.bindVertexBuffer(vertex);
        try commands.draw(3, 0);
        try ctx.submit(commands);
        const center = (try dev.mapResource(target))[(16 * 32 + 16) * 4 ..][0..4];
        result.* = center[0];
        if (center[0] > 0) {
            try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(center[0])), 2);
            try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(center[2])), 2);
            try std.testing.expectApproxEqAbs(@as(f32, 96), @as(f32, @floatFromInt(center[3])), 2);
        } else {
            try std.testing.expectEqual(@as(u8, 255), center[2]);
        }
    }
    // HAL window coordinates grow downward: this triangle has positive
    // signed area and is clockwise, matching the software driver's facing.
    try std.testing.expectEqual(@as(u8, 0), red[0]);
    try std.testing.expect(red[1] > 0);
}

test "Mali HAL links Luanti 2D color by name and executes projection and BGRA swizzle" {
    try runLuanti2D(false, false, false, null);
}

test "Mali HAL executes Luanti texture-enable uniform and tinted sampling" {
    try runLuanti2D(true, false, false, null);
}

test "Mali HAL samples two independently bound textures" {
    try runLuanti2D(true, true, false, null);
}

test "Mali HAL conditional discard preserves untaken branch coverage" {
    try runLuanti2D(false, false, true, null);
}

test "Mali HAL applies an offset viewport and clips oversized triangles to it" {
    try runLuanti2D(false, false, false, .{ .x = 4, .y = 8, .width = 16, .height = 16 });
}

fn runLuanti2D(textured: bool, dual: bool, discarding: bool, viewport: ?hal.Viewport) !void {
    const gpa = std.testing.allocator;
    const dev = Device.create(gpa) catch return error.SkipZigTest;
    defer dev.deinit();
    const internal: *Device = @ptrCast(@alignCast(dev.ptr));
    if (internal.session.info.architecture_major != 10) return error.SkipZigTest;
    const glsl = @import("../../glsl.zig");
    var compiled = try glsl.compileForStageWithLayout(gpa,
        \\attribute vec4 inVertexPosition;
        \\attribute vec4 inVertexColor_raw;
        \\attribute vec2 inTexCoord0;
        \\uniform float uThickness;
        \\uniform vec4 unusedPadding[16];
        \\uniform mat4 uProjection;
        \\varying vec2 vTextureCoord;
        \\varying vec4 vVertexColor;
        \\varying vec4 unusedVaryingA;
        \\varying vec4 unusedVaryingB;
        \\varying vec4 unusedVaryingC;
        \\varying vec3 vEyeVec;
        \\void main() {
        \\    gl_Position = uProjection * (inVertexPosition + vec4(0.375, 0.375, 0.0, 0.0));
        \\    gl_PointSize = uThickness;
        \\    vEyeVec = vec3(3.0, 4.0, 0.0);
        \\    vTextureCoord = inTexCoord0;
        \\    vec4 color = inVertexColor_raw.bgra * vec4(-2.0, -2.0, -2.0, 1.0);
        \\    vVertexColor = clamp(abs(color), 0.0, vec4(1.0, 2.0, 2.0, 1.0)) / vec4(1.0, 2.0, 2.0, 1.0);
        \\    vVertexColor = sqrt(vVertexColor * vVertexColor);
        \\}
    , .vertex);
    defer compiled.deinit(gpa);
    // Color is location 1 in the VS, location 0 in this separately compiled FS.
    const fs_code = try glsl.compileForStage(gpa, if (discarding)
        \\precision mediump float;
        \\uniform int uTextureUsage;
        \\varying vec4 vVertexColor;
        \\varying vec3 vEyeVec;
        \\void main() {
        \\    if (uTextureUsage == 0) discard;
        \\    gl_FragColor = vVertexColor * (length(vEyeVec) * 0.2);
        \\}
    else if (dual)
        \\precision mediump float;
        \\uniform int uTextureUsage;
        \\uniform sampler2D uTextureUnit;
        \\uniform sampler2D uOverlay;
        \\varying vec2 vTextureCoord;
        \\varying vec4 vVertexColor;
        \\varying vec3 vEyeVec;
        \\void main() {
        \\    vec4 Color = vVertexColor;
        \\    if (bool(uTextureUsage)) Color *= texture2D(uTextureUnit, vTextureCoord) * texture2D(uOverlay, vTextureCoord);
        \\    gl_FragColor = Color * (length(vEyeVec) * 0.2);
        \\}
    else if (textured)
        \\precision mediump float;
        \\uniform int uTextureUsage;
        \\uniform sampler2D uTextureUnit;
        \\varying vec2 vTextureCoord;
        \\varying vec4 vVertexColor;
        \\varying vec3 vEyeVec;
        \\void main() {
        \\    vec4 Color = vVertexColor;
        \\    if (bool(uTextureUsage)) Color *= texture2D(uTextureUnit, vTextureCoord);
        \\    gl_FragColor = Color * (length(vEyeVec) * 0.2);
        \\}
    else
        \\precision mediump float;
        \\varying vec4 vVertexColor;
        \\varying vec3 vEyeVec;
        \\void main() { gl_FragColor = pow(vVertexColor, vec4(1.0)) * (length(vEyeVec) * 0.2); }
    , .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = compiled.spirv });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const target = try dev.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const positions = [_]f32{
        -1, -1, 0, 0.25, 0.5, 1, 0.75, 0, 0,
        3,  -1, 0, 0.25, 0.5, 1, 0.75, 1, 0,
        -1, 3,  0, 0.25, 0.5, 1, 0.75, 0, 1,
    };
    const vertex = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(positions)), .usage = .{ .vertex = true } } });
    defer dev.destroyResource(vertex);
    @memcpy((try dev.mapResource(vertex))[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const uniforms = try dev.createResource(.{ .buffer = .{ .size = compiled.block_size, .usage = .{ .uniform = true } } });
    defer dev.destroyResource(uniforms);
    const bytes = try dev.mapResource(uniforms);
    @memset(bytes, 0);
    const projection = [_]f32{ 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2 };
    for (compiled.uniforms) |uniform| {
        if (std.mem.eql(u8, uniform.name, "uProjection")) @memcpy(bytes[uniform.offset..][0..64], std.mem.asBytes(&projection));
    }
    const attributes = [_]hal.VertexAttribute{
        .{ .location = 0, .format = .r32g32b32_float, .offset = 0 },
        .{ .location = 1, .format = .r32g32b32a32_float, .offset = 12 },
        .{ .location = 2, .format = .r32g32_float, .offset = 28 },
    };
    const pipeline = try dev.createPipeline(.{
        .vertex = vs,
        .fragment = fs,
        .vertex_layout = .{ .stride = 36, .attributes = attributes[0..if (textured) @as(usize, 3) else 2] },
        .color_format = .rgba8_unorm,
        .line_width = 2, // Line width does not affect triangle rasterization.
        .depth = .{ .test_enable = discarding, .write_enable = discarding, .compare_op = .less },
    });
    defer dev.destroyPipeline(pipeline);
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const depth = if (discarding) try dev.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .depth32_float, .usage = .{ .render_target = true } } }) else null;
    defer if (depth) |resource| dev.destroyResource(resource);
    const texture = try dev.createResource(.{ .image = .{ .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .sampled = true } } });
    defer dev.destroyResource(texture);
    @memcpy((try dev.mapResource(texture))[0..4], &[_]u8{ 128, 64, 255, 128 });
    const overlay = try dev.createResource(.{ .image = .{ .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .sampled = true } } });
    defer dev.destroyResource(overlay);
    @memcpy((try dev.mapResource(overlay))[0..4], &[_]u8{ 64, 255, 128, 255 });
    const fs_uniforms = try dev.createResource(.{ .buffer = .{ .size = 4, .usage = .{ .uniform = true } } });
    defer dev.destroyResource(fs_uniforms);
    for (0..if (textured or discarding) @as(usize, 2) else 1) |enabled| {
        const flag: f32 = @floatFromInt(enabled);
        @memcpy((try dev.mapResource(fs_uniforms))[0..4], std.mem.asBytes(&flag));
        const commands = try ctx.beginCommands();
        defer commands.deinit();
        try commands.setRenderTarget(target);
        if (depth) |resource| try commands.setDepthTarget(resource, 1);
        try commands.clear(.{ .b = 1, .a = 1 });
        try commands.bindPipeline(pipeline);
        try commands.setViewport(viewport);
        try commands.bindUniformBuffer(0, uniforms);
        try commands.bindUniformBuffer(1, fs_uniforms);
        // A later GLES upload to the same UBO must leave this draw's binding intact.
        const later_flag: f32 = if (enabled == 0) 1 else 0;
        @memcpy((try dev.mapResource(fs_uniforms))[0..4], std.mem.asBytes(&later_flag));
        if (textured) try commands.bindTexture(.{ .image = texture, .binding = 2 });
        if (dual) try commands.bindTexture(.{ .image = overlay, .binding = 3 });
        try commands.bindVertexBuffer(vertex);
        try commands.draw(3, 0);
        try ctx.submit(commands);
        const pixel = (try dev.mapResource(target))[(16 * 32 + 16) * 4 ..][0..4];
        if (depth) |resource| {
            const stored: f32 = @bitCast(std.mem.readInt(u32, (try dev.mapResource(resource))[(16 * 32 + 16) * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(@as(f32, if (enabled == 0) 1 else 0.5), stored, 0.0001);
        }
        const expected: [4]f32 = if (discarding and enabled == 0) .{ 0, 0, 255, 255 } else if (discarding or enabled == 0) .{ 255, 128, 64, 191 } else if (dual) .{ 32, 32, 32, 96 } else .{ 128, 32, 64, 96 };
        for (pixel, expected) |actual, channel_expected| try std.testing.expectApproxEqAbs(channel_expected, @as(f32, @floatFromInt(actual)), 2);
        if (viewport) |vp| {
            const mapped = try dev.mapResource(target);
            const left: usize = @intCast(vp.x);
            const top: usize = @intCast(vp.y);
            // The VS shifts NDC by 0.375: mapping into this viewport puts
            // the triangle edge at (x+3,y+3), not at the full-target edge.
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, mapped[((top + 1) * 32 + left + 1) * 4 ..][0..4]);
            const inside = mapped[((top + 8) * 32 + left + 4) * 4 ..][0..4];
            for (inside, expected) |actual, wanted| try std.testing.expectApproxEqAbs(wanted, @as(f32, @floatFromInt(actual)), 2);
            for ([_]usize{ 4 * 32 + 4, 12 * 32 + 28, 28 * 32 + 12 }) |index| {
                try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, mapped[index * 4 ..][0..4]);
            }
        }
    }
}

test "Mali HAL depth clear and attachment load preserve occlusion between submissions" {
    const gpa = std.testing.allocator;
    const dev = Device.create(gpa) catch return error.SkipZigTest;
    defer dev.deinit();
    const internal: *Device = @ptrCast(@alignCast(dev.ptr));
    if (internal.session.info.architecture_major != 10) return error.SkipZigTest;
    const glsl = @import("../../glsl.zig");
    const vs_code = try glsl.compileForStage(gpa, "attribute vec3 p; void main() { gl_Position = vec4(p, 1.0); }", .vertex);
    defer gpa.free(vs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const color = try dev.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(color);
    const depth = try dev.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .depth32_float, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(depth);
    const positions = [_]f32{ -1, -1, -0.5, 3, -1, -0.5, -1, 3, -0.5, -1, -1, 0.5, 3, -1, 0.5, -1, 3, 0.5 };
    const vertex = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(positions)), .usage = .{ .vertex = true } } });
    defer dev.destroyResource(vertex);
    @memcpy((try dev.mapResource(vertex))[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const clear = try ctx.beginCommands();
    defer clear.deinit();
    try clear.setRenderTarget(color);
    try clear.setDepthTarget(depth, 1);
    try clear.clear(.{ .b = 1 });
    try ctx.submit(clear);
    const center = (16 * 32 + 16) * 4;
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1))), std.mem.readInt(u32, (try dev.mapResource(depth))[center..][0..4], .little));
    for ([_][]const u8{
        "precision mediump float; void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }",
        "precision mediump float; void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }",
    }, 0..) |source, i| {
        const fs_code = try glsl.compileForStage(gpa, source, .fragment);
        defer gpa.free(fs_code);
        const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
        defer dev.destroyShaderModule(fs);
        const pipeline = try dev.createPipeline(.{
            .vertex = vs,
            .fragment = fs,
            .vertex_layout = .{ .stride = 12, .attributes = &.{.{ .location = 0, .format = .r32g32b32_float, .offset = 0 }} },
            .color_format = .rgba8_unorm,
            .depth = .{ .test_enable = true, .write_enable = true, .compare_op = .less, .bias_enable = true, .bias_constant = 1, .bias_slope = 1 },
        });
        defer dev.destroyPipeline(pipeline);
        const commands = try ctx.beginCommands();
        defer commands.deinit();
        try commands.setRenderTarget(color);
        try commands.setDepthTarget(depth, null);
        try commands.bindPipeline(pipeline);
        try commands.bindVertexBuffer(vertex);
        try commands.draw(3, @intCast(i * 3));
        try ctx.submit(commands);
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, (try dev.mapResource(color))[center..][0..4]);
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), @as(f32, @bitCast(std.mem.readInt(u32, (try dev.mapResource(depth))[center..][0..4], .little))), 0.0001);
        if (i == 1) {
            const ordered = try ctx.beginCommands();
            defer ordered.deinit();
            try ordered.setRenderTarget(color);
            try ordered.setDepthTarget(depth, 1);
            try ordered.clear(.{ .b = 1 });
            try ordered.bindPipeline(pipeline);
            try ordered.bindVertexBuffer(vertex);
            try ordered.draw(3, 0); // Near geometry writes 0.25.
            try ordered.setDepthTarget(depth, 0.9);
            try ordered.draw(3, 3); // Far geometry now passes and writes 0.75.
            try ctx.submit(ordered);
            try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, (try dev.mapResource(color))[center..][0..4]);
            try std.testing.expectApproxEqAbs(@as(f32, 0.75), @as(f32, @bitCast(std.mem.readInt(u32, (try dev.mapResource(depth))[center..][0..4], .little))), 0.0001);

            const trailing = try ctx.beginCommands();
            defer trailing.deinit();
            try trailing.setRenderTarget(color);
            try trailing.setDepthTarget(depth, null);
            try trailing.bindPipeline(pipeline);
            try trailing.bindVertexBuffer(vertex);
            try trailing.draw(3, 0);
            try trailing.setDepthTarget(depth, 0.6); // Must execute even without another draw.
            try ctx.submit(trailing);
            try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, (try dev.mapResource(color))[center..][0..4]);
            try std.testing.expectApproxEqAbs(@as(f32, 0.6), @as(f32, @bitCast(std.mem.readInt(u32, (try dev.mapResource(depth))[center..][0..4], .little))), 0.0001);
        }
    }
}
