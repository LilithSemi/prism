//! Panthor v10 submission for Prism's native graphics pipelines.
//! Uses mali.zig's BO, descriptor and CSF APIs. Draw state belongs here rather
//! than in mali.zig's fixed-state sample pipelines.
const std = @import("std");
const mali = @import("mali");
const hal = @import("../../hal.zig");
const csf = mali.csf;
const descriptors = mali.descriptors;
const session_mod = mali.session;
const Image = mali.Image;
pub const Error = mali.graphics.Error;
pub const BlendMode = enum { replace, src_alpha, src_alpha_both };
pub const Texture = struct {
    image: Image,
    swizzle: u12 = 0x688,
    min_filter: descriptors.SamplerLinearClamp.Filter = .linear,
    mag_filter: descriptors.SamplerLinearClamp.Filter = .linear,
    address_u: descriptors.SamplerLinearClamp.AddressMode = .clamp_to_edge,
    address_v: descriptors.SamplerLinearClamp.AddressMode = .clamp_to_edge,
    depth: bool = false,
};
const state_stride = 8192;
/// Scratch storage is reusable after drawBatchCached's completion fence.
/// Keep one per context so independent contexts never rewrite each other's work.
pub const Cache = struct {
    vertices: ?mali.Bo = null,
    color: ?mali.NativeGraphicsPipeline = null,
    depth: ?mali.NativeGraphicsPipeline = null,
    depth_clear: ?mali.NativeGraphicsPipeline = null,
    state: ?mali.Bo = null,
    commands: ?mali.CommandBuffer = null,

    pub fn deinit(self: *Cache, session: *session_mod.Session) void {
        if (self.commands) |*command| session.destroyCommandBuffer(command);
        if (self.state) |bo| session.freeBo(bo);
        if (self.depth_clear) |*pipeline| pipeline.deinit(session);
        if (self.depth) |*pipeline| pipeline.deinit(session);
        if (self.color) |*pipeline| pipeline.deinit(session);
        if (self.vertices) |bo| session.freeBo(bo);
        self.* = .{};
    }

    fn quad(self: *Cache, session: *session_mod.Session) Error!mali.Bo {
        if (self.vertices) |vertices| return vertices;
        const positions = [_]f32{
            -1, -1, 0, 0, 1, 1, 1, 1,
            1,  -1, 1, 0, 1, 1, 1, 1,
            -1, 1,  0, 1, 1, 1, 1, 1,
            -1, 1,  0, 1, 1, 1, 1, 1,
            1,  -1, 1, 0, 1, 1, 1, 1,
            1,  1,  1, 1, 1, 1, 1, 1,
        };
        const vertices = try session.allocBo(@sizeOf(@TypeOf(positions)), .{});
        @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
        self.vertices = vertices;
        return vertices;
    }

    pub fn clearDepth(self: *Cache, session: *session_mod.Session, target: Image, value: f32) Error!Draw {
        const vertices = try self.quad(session);
        if (self.depth_clear == null)
            self.depth_clear = try @import("native_pipeline.zig").createDepthClear(session);
        return .{
            .pipeline = self.depth_clear.?,
            .vertices = vertices,
            .vertex_count = 6,
            // The shared textured vertex template requires a descriptor, but
            // the depth-clear fragment stage performs no texture reads.
            .texture = target,
            .texture_depth = true,
            .depth_target = target,
            .constant_depth = value,
            .shader_depth = true,
            .depth = .{ .test_enable = true, .write_enable = true, .compare_op = .always },
        };
    }

    fn stateBuffer(self: *Cache, session: *session_mod.Session, size: u64) Error!mali.Bo {
        if (self.state) |bo| if (bo.size >= size) return bo;
        const fresh = try session.allocBo(size, .{});
        if (self.state) |old| session.freeBo(old);
        self.state = fresh;
        return fresh;
    }

    fn commandBuffer(self: *Cache, session: *session_mod.Session, size: u64) Error!*mali.CommandBuffer {
        if (self.commands == null or self.commands.?.bo.size < size) {
            const fresh = try session.createCommandBuffer(size);
            if (self.commands) |*old| session.destroyCommandBuffer(old);
            self.commands = fresh;
        }
        self.commands.?.reset();
        return &self.commands.?;
    }
};
pub const Draw = struct {
    pipeline: mali.NativeGraphicsPipeline,
    vertices: mali.Bo,
    vertex_count: u32,
    texture: ?Image = null,
    textures: [8]?Texture = @splat(null),
    texture_swizzle: u12 = 0x688,
    texture_min_filter: descriptors.SamplerLinearClamp.Filter = .linear,
    texture_mag_filter: descriptors.SamplerLinearClamp.Filter = .linear,
    texture_address_u: descriptors.SamplerLinearClamp.AddressMode = .clamp_to_edge,
    texture_address_v: descriptors.SamplerLinearClamp.AddressMode = .clamp_to_edge,
    scissor: ?mali.graphics.Scissor = null,
    viewport: ?hal.Viewport = null,
    blend: BlendMode = .replace,
    cull: hal.CullState = .{},
    /// Per-draw fixed-function depth state. Attachment and initial contents
    /// are shared by the batch and taken from its first draw.
    depth: hal.DepthState = .{},
    depth_clear: f32 = 1,
    constant_depth: ?f32 = null,
    /// Optional attachment, interpreted as linear D32 float memory.
    depth_target: ?Image = null,
    depth_load: bool = false,
    shader_depth: bool = false,
    shader_coverage: bool = false,
    texture_depth: bool = false,
    stride: u32 = 0,
    attributes: []const hal.VertexAttribute = &.{},
    /// Default-block ABI: vertex binding 0, fragment binding 1. User words
    /// follow the fixed driver FAU header in each stage's push block.
    vertex_uniforms: []const u8 = &.{},
    varying_size: ?u32 = null,
    fragment_uniforms: []const u8 = &.{},
};
pub fn drawBatch(
    session: *session_mod.Session,
    image: Image,
    draws: []const Draw,
    clear_rgba8: ?u32,
    timeout_ns: u64,
) Error!void {
    var cache: Cache = .{};
    defer cache.deinit(session);
    return drawBatchCached(session, image, draws, clear_rgba8, timeout_ns, &cache);
}

pub fn drawBatchCached(
    session: *session_mod.Session,
    image: Image,
    draws: []const Draw,
    clear_rgba8: ?u32,
    timeout_ns: u64,
    cache: *Cache,
) Error!void {
    if (draws.len == 0 or image.width == 0 or image.height == 0) return error.InvalidImage;
    const load_depth = draws[0].depth_load;
    if (clear_rgba8 != null and !load_depth) return drawBatchClear(session, image, draws, clear_rgba8.?, timeout_ns, cache);
    const target = draws[0].depth_target;
    if (load_depth and target == null) return error.InvalidImage;
    // The first primitives load each pixel's old attachment value into tile
    // memory. Nearest filtering and identity coordinates ensure that a tile
    // reads only its own pixels, before its later draws and final writeback.
    // This is an ordered tile load, so no CPU snapshot of either uncached
    // attachment is needed. Submission invalidates texture caches beforehand.
    const vertices = try cache.quad(session);
    if (clear_rgba8 == null and cache.color == null)
        cache.color = try mali.NativeGraphicsPipeline.createImage(session);
    if (load_depth and cache.depth == null)
        cache.depth = try @import("native_pipeline.zig").createDepthLoad(session);
    const count: usize = @intFromBool(clear_rgba8 == null) + @as(usize, @intFromBool(load_depth));
    const batch = try std.heap.page_allocator.alloc(Draw, draws.len + count);
    defer std.heap.page_allocator.free(batch);
    var offset: usize = 0;
    if (clear_rgba8 == null) {
        batch[offset] = .{
            .pipeline = cache.color.?,
            .vertices = vertices,
            .vertex_count = 6,
            .texture = image,
            .texture_min_filter = .nearest,
            .texture_mag_filter = .nearest,
            .depth_target = target,
            .depth_clear = draws[0].depth_clear,
        };
        offset += 1;
    }
    if (load_depth) {
        batch[offset] = .{
            .pipeline = cache.depth.?,
            .vertices = vertices,
            .vertex_count = 6,
            .texture = target.?,
            .texture_depth = true,
            .texture_min_filter = .nearest,
            .texture_mag_filter = .nearest,
            .depth_target = target,
            .depth_clear = draws[0].depth_clear,
            .shader_depth = true,
            .depth = .{ .test_enable = true, .write_enable = true, .compare_op = .always },
        };
        offset += 1;
    }
    @memcpy(batch[offset..], draws);
    return drawBatchClear(session, image, batch, clear_rgba8 orelse 0, timeout_ns, cache);
}

fn drawBatchClear(
    session: *session_mod.Session,
    image: Image,
    draws: []const Draw,
    clear_rgba8: u32,
    timeout_ns: u64,
    cache: *Cache,
) Error!void {
    if (image.width == 0 or image.height == 0 or draws.len == 0 or
        image.bo.size < @as(u64, image.row_stride) * image.height)
        return error.InvalidImage;
    const depth_target = draws[0].depth_target;
    if (depth_target) |target| {
        if (target.width != image.width or target.height != image.height or target.bo.size < @as(u64, target.row_stride) * target.height) return error.InvalidImage;
    }
    for (draws) |draw| {
        if (draw.depth_target) |target| {
            if (depth_target == null or target.bo.gpu_va != depth_target.?.bo.gpu_va) return error.InvalidImage;
        } else if (depth_target != null) return error.InvalidImage;
        if (draw.vertex_uniforms.len > 952 or draw.fragment_uniforms.len > 992 or
            draw.vertex_uniforms.len % 4 != 0 or draw.fragment_uniforms.len % 4 != 0)
            return error.InvalidImage;
        if (draw.vertex_count == 0 or draw.vertex_count % 3 != 0 or
            draw.vertices.size < @as(u64, draw.vertex_count) * vertexStride(draw))
            return error.InvalidImage;
        for (draw.attributes) |attribute| {
            const components = floatComponents(attribute.format) orelse return error.InvalidImage;
            if (attribute.location >= 16 or @as(u64, attribute.offset) + @as(u64, components) * 4 > vertexStride(draw))
                return error.InvalidImage;
        }
        if (draw.pipeline.vertex_layout == .textured_color and textureAt(draw, 0) == null)
            return error.InvalidImage;
        for (0..8) |slot| if (textureAt(draw, slot)) |binding| {
            const texture = binding.image;
            if (texture.width == 0 or texture.height == 0 or
                texture.bo.size < @as(u64, texture.row_stride) * texture.height)
                return error.InvalidImage;
        };
        if (draw.scissor) |clip| {
            if (clip.width == 0 or clip.height == 0 or clip.x >= image.width or clip.y >= image.height or
                @as(u32, clip.x) + clip.width > image.width or @as(u32, clip.y) + clip.height > image.height)
                return error.InvalidImage;
        }
    }

    const draw_count: u64 = std.math.cast(u64, draws.len) orelse return error.InvalidImage;
    const state_size = std.math.mul(u64, draw_count, state_stride) catch return error.InvalidImage;
    const state = try cache.stateBuffer(session, state_size);
    @memset(state.cpu[0..@intCast(state_size)], 0);

    // Match PanVK's v10 vertex driver set exactly: 16 attribute descriptors,
    // one dummy sampler, then vertex-buffer descriptors. IDVS validates this
    // fixed ABI even when a shader consumes only location zero.
    const vertex_buffer_descriptor_index: u32 = 17;
    const vertex_buffer_offset: usize = vertex_buffer_descriptor_index * 32;
    const vertex_driver_set_size: u64 = 18 * 32;
    // Resource tables are 64-byte aligned arrays of four 16-byte entries.
    // Fragment table entry 1 points at the user descriptor set containing a
    // Texture followed by its Sampler; shaders address them as handles
    // 0x01000000 and 0x01000001.
    const vertex_resource_offset: usize = 576;
    const fragment_resource_offset: usize = 640;
    const fragment_descriptors_offset: usize = 4096;
    const texture_plane_offset: usize = 4608;
    // Reserve 1 KiB for each stage's FAU data, after all fixed descriptors.
    // Vertex words u3..u8 contain the secondary varying-store offsets.
    const vertex_fau_offset = 2048;
    const blend_offset = 960;
    const fragment_fau_offset = 3072;
    const depth_stencil_offset = 1024;
    const tiler_offset = 1088;
    const fbd_offset = 1216;
    const zs_offset = 1344;
    const rt_offset: usize = if (depth_target != null) 1408 else 1344;

    const half_width: u32 = @bitCast(@as(f32, @floatFromInt(image.width)) * 0.5);
    const half_height: u32 = @bitCast(@as(f32, @floatFromInt(image.height)) * 0.5);
    // u0..u2 are viewport scale/bias and Z. u3..u8 are the offsets selected
    // by Mesa's secondary vertex shaders when writing compact generic
    // varyings. vec2+vec4 and vec2+vec4+vec4 layouts align each vec4 to 16
    // bytes, hence the gap between 4 and 16. u4.w0 remains 12 for the primary
    // position shader's W store.
    const full_viewport_fau = [_]u32{
        half_width,  half_height,
        0x3f80_0000, half_width,
        half_height, 0,
        4,           8,
        12,          16,
        20,          24,
        28,          32,
        36,          40,
        44,          0,
    };
    for (draws, 0..) |draw, draw_index| {
        var vertex_fau = full_viewport_fau;
        if (draw.viewport) |vp| {
            const sx = @as(f32, @floatFromInt(vp.width)) * 0.5;
            const sy = @as(f32, @floatFromInt(vp.height)) * 0.5;
            vertex_fau[0] = @bitCast(sx);
            vertex_fau[1] = @bitCast(sy);
            vertex_fau[2] = @bitCast(vp.depth_far - vp.depth_near);
            vertex_fau[3] = @bitCast(@as(f32, @floatFromInt(vp.x)) + sx);
            vertex_fau[4] = @bitCast(@as(f32, @floatFromInt(vp.y)) + sy);
            vertex_fau[5] = @bitCast(vp.depth_near);
        }
        const state_offset = draw_index * state_stride;
        const state_cpu = state.cpu[state_offset..][0..state_stride];
        const state_va = state.gpu_va + state_offset;
        const stride = vertexStride(draw);
        if (draw.attributes.len != 0) {
            for (draw.attributes) |attribute| {
                const descriptor = descriptors.VertexAttributeF32.init(floatComponents(attribute.format).?, attribute.offset, vertex_buffer_descriptor_index, stride);
                copyWords(state_cpu, attribute.location * 32, &descriptor.words);
            }
        } else {
            const position = descriptors.VertexAttributeF32.init(2, 0, vertex_buffer_descriptor_index, stride);
            copyWords(state_cpu, 0, &position.words);
            if (draw.pipeline.vertex_layout == .position_color) {
                const color = descriptors.VertexAttributeF32.init(3, 8, vertex_buffer_descriptor_index, stride);
                copyWords(state_cpu, 32, &color.words);
            } else if (draw.pipeline.vertex_layout == .textured_color) {
                const uv = descriptors.VertexAttributeF32.init(2, 8, vertex_buffer_descriptor_index, stride);
                const color = descriptors.VertexAttributeF32.init(4, 16, vertex_buffer_descriptor_index, stride);
                copyWords(state_cpu, 32, &uv.words);
                copyWords(state_cpu, 64, &color.words);
            } else if (draw.pipeline.vertex_layout == .rrect) {
                const local = descriptors.VertexAttributeF32.init(2, 8, vertex_buffer_descriptor_index, stride);
                const params = descriptors.VertexAttributeF32.init(4, 16, vertex_buffer_descriptor_index, stride);
                const color = descriptors.VertexAttributeF32.init(4, 32, vertex_buffer_descriptor_index, stride);
                copyWords(state_cpu, 32, &local.words);
                copyWords(state_cpu, 64, &params.words);
                copyWords(state_cpu, 96, &color.words);
            }
        }
        const dummy_sampler = descriptors.SamplerLinearClamp.init();
        copyWords(state_cpu, 16 * 32, &dummy_sampler.words);
        const vertex_buffer = descriptors.Buffer.init(draw.vertices.gpu_va, draw.vertex_count * stride);
        copyWords(state_cpu, vertex_buffer_offset, &vertex_buffer.words);
        const vertex_resource = descriptors.Resource.init(state_va, vertex_driver_set_size, true);
        copyWords(state_cpu, vertex_resource_offset, &vertex_resource.words);
        const fragment_resource = descriptors.Resource.init(state_va + 160, 32, true);
        copyWords(state_cpu, fragment_resource_offset, &fragment_resource.words);
        const descriptor_set_resource = descriptors.Resource.init(state_va + fragment_descriptors_offset, 8 * 64, true);
        copyWords(state_cpu, fragment_resource_offset + 16, &descriptor_set_resource.words);
        for (0..8) |slot| if (textureAt(draw, slot)) |binding| {
            const texture = binding.image;
            var texture_header = descriptors.TextureRgba8.initSwizzle(
                texture.width,
                texture.height,
                state_va + texture_plane_offset + slot * 32,
                binding.swizzle,
            );
            if (binding.depth) texture_header.words[0] = 2 | (2 << 4) | (@as(u32, 0x000a_7000) << 10);
            const sampler = descriptors.SamplerLinearClamp.initState(
                binding.min_filter,
                binding.mag_filter,
                binding.address_u,
                binding.address_v,
            );
            const texture_size: u32 = @intCast(@as(u64, texture.row_stride) * texture.height);
            const plane = descriptors.GenericPlaneRgba8.init(
                texture.bo.gpu_va,
                texture_size,
                texture.row_stride,
                texture.width,
                texture.height,
            );
            copyWords(state_cpu, fragment_descriptors_offset + slot * 64, &texture_header.words);
            copyWords(state_cpu, fragment_descriptors_offset + slot * 64 + 32, &sampler.words);
            copyWords(state_cpu, texture_plane_offset + slot * 32, &plane.words);
        };
        copyWords(state_cpu, vertex_fau_offset, &vertex_fau);
        @memcpy(state_cpu[vertex_fau_offset + @sizeOf(@TypeOf(vertex_fau)) ..][0..draw.vertex_uniforms.len], draw.vertex_uniforms);
        // Fixed-function RGBA8 blend descriptors captured from Mesa 26.2
        // PanVK. The alpha mode is PhantomUI's SRC_ALPHA / ONE_MINUS_SRC_ALPHA
        // RGB and ONE / ONE_MINUS_SRC_ALPHA alpha equation.
        const blend = blendDescriptor(draw.blend);
        const fragment_blend = blendFauDescriptor(draw.blend);
        // PanVK's lowered texture shaders load a Valhall-packed combined
        // texture/sampler handle from u3.w0. Resource table 1 contains the
        // Texture at descriptor 0 and Sampler at descriptor 1. TEX_SINGLE's
        // compact encoding is:
        //   tex_table[31:27] | tex_index[25:16] |
        //   sampler_table[15:11] | sampler_index[9:0].
        const texture_handle: u32 = if (textureAt(draw, 0) != null) 0x0800_0801 else 0;
        const fragment_fau = [_]u32{
            if (draw.constant_depth) |value| @bitCast(value) else 0, 0,                 0,              0,
            fragment_blend[0],                                       fragment_blend[1], texture_handle, 0,
        };
        copyWords(state_cpu, blend_offset, &blend);
        copyWords(state_cpu, fragment_fau_offset, &fragment_fau);
        @memcpy(state_cpu[fragment_fau_offset + @sizeOf(@TypeOf(fragment_fau)) ..][0..draw.fragment_uniforms.len], draw.fragment_uniforms);
        var depth_stencil: [16]u32 = @splat(0);
        depth_stencil[0] = 7;
        const depth_function: u32 = if (draw.depth.test_enable) compareFunction(draw.depth.compare_op) else 7;
        depth_stencil[4] = 0x00c0_0000 | (@as(u32, if (draw.shader_depth) 3 else 2) << 25) | (depth_function << 29) |
            (if (draw.depth.test_enable and draw.depth.write_enable) @as(u32, 1) << 27 else 0) |
            (if (draw.depth.bias_enable) @as(u32, 1) << 28 else 0);
        depth_stencil[5] = @bitCast(draw.depth.bias_constant);
        depth_stencil[6] = @bitCast(draw.depth.bias_slope);
        depth_stencil[7] = @bitCast(draw.depth.bias_clamp);
        copyWords(state_cpu, depth_stencil_offset, &depth_stencil);
    }

    const tiler = descriptors.TilerContext.init(
        image.width,
        image.height,
        session.tiler_resources.gpu_va,
        session.tiler_resources.gpu_va + 4096,
    );
    copyWords(state.cpu, tiler_offset, &tiler.words);
    var fbd = descriptors.FramebufferRgba8.init(
        image.width,
        image.height,
        session.sample_positions.gpu_va,
        state.gpu_va + tiler_offset,
    );
    const depth_active = for (draws) |draw| {
        if (draw.depth.test_enable) break true;
    } else false;
    if (depth_active or depth_target != null) {
        fbd.words[12] = 2 << 16; // D32 tile-buffer storage
        fbd.words[13] = @bitCast(draws[0].depth_clear);
    }
    if (depth_target) |target| {
        fbd.words[12] |= (1 << 18) | (1 << 21); // store Z and attach ZS descriptor
        var zs: [16]u32 = @splat(0);
        zs[0] = 14 | (2 << 4) | (@as(u32, 1) << 31); // linear D32, write clean tiles
        zs[8] = @truncate(target.bo.gpu_va);
        zs[9] = @truncate(target.bo.gpu_va >> 32);
        zs[10] = target.row_stride;
        zs[11] = @intCast(@as(u64, target.row_stride) * target.height);
        copyWords(state.cpu, zs_offset, &zs);
    }
    copyWords(state.cpu, fbd_offset, &fbd.words);
    const surface_stride: u32 = @intCast(@as(u64, image.row_stride) * image.height);
    const rt = descriptors.RenderTargetRgba8.init(image.bo.gpu_va, image.row_stride, surface_stride, clear_rgba8);
    copyWords(state.cpu, rt_offset, &rt.words);

    const command_extra = std.math.mul(u64, draw_count, 512) catch return error.InvalidImage;
    const command_size = std.math.add(u64, 4096, command_extra) catch return error.InvalidImage;
    const tiling_command = try cache.commandBuffer(session, command_size);
    const vt = &tiling_command.encoder;
    try vt.requestResources(.{ .tiler = true, .idvs = true });
    try vt.move48(62, session.tiler_heap.context_gpu_va);
    try vt.heapSet(62);
    try vt.move32(62, 0);
    try vt.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 62, .signal_slot = 0 });
    try vt.wait(1, false);
    try vt.heapOperation(0, 0, 0);
    for (draws, 0..) |draw, draw_index| {
        const state_va = state.gpu_va + @as(u64, @intCast(draw_index)) * state_stride;
        const pipeline = draw.pipeline;
        try vt.move48(0, state_va + vertex_resource_offset + 4);
        try vt.move48(4, state_va + fragment_resource_offset + 4);
        try vt.move64(8, state_va + vertex_fau_offset | (fauCount(72, draw.vertex_uniforms.len) << 56));
        try vt.move64(12, state_va + fragment_fau_offset | (fauCount(32, draw.fragment_uniforms.len) << 56));
        try vt.move48(16, pipeline.vertex_spd_va);
        try vt.move48(18, pipeline.varying_spd_va);
        try vt.move48(20, pipeline.fragment_spd_va);
        try vt.move48(24, pipeline.tsd_va);
        try vt.move48(40, state.gpu_va + tiler_offset);
        const bbox_min: u32, const bbox_max: u32 = if (draw.scissor) |clip| .{
            @as(u32, clip.x) | (@as(u32, clip.y) << 16),
            (@as(u32, clip.x) + clip.width - 1) | ((@as(u32, clip.y) + clip.height - 1) << 16),
        } else .{
            0,
            (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16),
        };
        try vt.move32(42, bbox_min);
        try vt.move32(43, bbox_max);
        try vt.move32(44, 0);
        try vt.move32(45, 0x3f80_0000);
        try vt.move32(48, draw.varying_size orelse varyingSize(pipeline.vertex_layout));
        try vt.move48(50, state_va + blend_offset | 1);
        try vt.move48(52, state_va + depth_stencil_offset);
        try vt.move48(54, 0);
        try vt.move32(56, if (pipeline.varying_spd_va == 0) 0x0043_0008 else 0x0047_0008);
        var flags = drawFlags(draw.blend, draw.cull);
        if (draw.shader_depth or draw.shader_coverage) flags = (flags & ~@as(u32, 0x3f)) | 0x3c;
        if (draw.shader_coverage) flags |= 1 << 20; // discard determines coverage before Z update
        try vt.move32(57, flags);
        try vt.move32(58, 0x0001_ffff);
        try vt.move32(38, 0x0000_1000);
        try vt.move32(32, 0);
        try vt.move32(33, draw.vertex_count);
        try vt.move32(34, 1);
        try vt.move32(35, 0);
        try vt.move32(36, 0);
        try vt.move32(37, 0);
        // Match Mesa's v10 CSF convention: slots 0-2 are reserved for
        // load/store and deferred work, while render iterations start at 3.
        try vt.setScoreboardEntry(3, 0);
        try vt.runIdvs(.{ .malloc_enable = true, .fragment_srt_select = true });
        try vt.wait(1 << 3, false);
    }
    try vt.finishTiling(false);
    try vt.wait(1 << 3, false);
    try vt.heapOperation(1, 0, 0);
    try vt.move32(62, 0);
    try vt.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 62, .signal_slot = 0 });
    try vt.wait(1, false);
    // The scoreboard waits above finish tiling on the GPU. Continue into the
    // fragment phase in this same stream instead of fencing back to the CPU
    // and allocating/submitting a second command buffer for every render pass.
    const frag = vt;
    try frag.requestResources(.{ .fragment = true });
    try frag.move48(0, session.tiler_heap.context_gpu_va);
    try frag.heapSet(0);
    try frag.move32(0, 0);
    try frag.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 2, .latest_flush_id_register = 0, .signal_slot = 0 });
    try frag.wait(1, false);
    try frag.move48(csf.fragment_register.framebuffer_descriptor, descriptors.FramebufferRgba8.taggedPointer(state.gpu_va + fbd_offset) | (if (depth_target != null) @as(u64, 2) else 0));
    try frag.move32(csf.fragment_register.bounding_box_min, 0);
    try frag.move32(csf.fragment_register.bounding_box_max, (@as(u32, image.width) - 1) | ((@as(u32, image.height) - 1) << 16));
    try frag.setScoreboardEntry(3, 0);
    try frag.runFragment(false, 0, false);
    try frag.move48(4, state.gpu_va + tiler_offset);
    try frag.loadMultiple(10, 4, 0x000f, 40);
    try frag.wait(1, false);
    try frag.finishFragment(true, 10, 12, 1 << 3, 4);
    try frag.wait(1 << 4, false);
    try frag.move32(0, 0);
    try frag.flushCache(.{ .l2_mode = 3, .lsc_mode = 3, .other_mode = 0, .latest_flush_id_register = 0, .signal_slot = 0 });
    try frag.wait(1, false);
    try tiling_command.submitAndWait(&session.dev, session.group, @backingInt(session_mod.Queue.vertex_tiler), &.{}, timeout_ns);
}

// Mesa's v10 Blend Function encodes A + B*C in twelve bits. Src-alpha
// interpolation is dest + (src-dest)*src_alpha, encoded as 0x503. The
// premultiplied alpha equation is src + dest*(1-src_alpha), encoded 0xd32.
fn blendDescriptor(mode: BlendMode) [4]u32 {
    return switch (mode) {
        .replace => .{ 0x0000_0a00, 0xf012_2122, 0x0000_0019, 0x000e_d000 },
        .src_alpha => .{ 0x0000_0a01, 0xf0d3_2503, 0x0000_001a, 0x000e_d000 },
        .src_alpha_both => .{ 0x0000_0a01, 0xf050_3503, 0x0000_001a, 0x000e_d000 },
    };
}
fn blendFauDescriptor(mode: BlendMode) [2]u32 {
    return if (mode == .replace) .{ 0x19, 0x000e_d000 } else .{ 0x1a, 0x000e_d000 };
}
fn drawFlags(mode: BlendMode, cull: hal.CullState) u32 {
    // DCD Flags 0: front-face CCW bit 16, cull front/back bits 17/18.
    var flags: u32 = if (mode == .replace) 0x0080_002b else 0x0080_002a;
    if (cull.front_face == .counter_clockwise) flags |= 1 << 16;
    flags |= switch (cull.mode) {
        .none => 0,
        .front => @as(u32, 1) << 17,
        .back => @as(u32, 1) << 18,
    };
    return flags;
}
fn copyWords(destination: []u8, offset: usize, words: []const u32) void {
    const bytes = std.mem.sliceAsBytes(words);
    @memcpy(destination[offset..][0..bytes.len], bytes);
}

fn varyingSize(layout: mali.NativeGraphicsPipeline.VertexLayout) u32 {
    return switch (layout) {
        .position => 0,
        .position_color => 12,
        .textured_color => 32,
        .rrect => 48,
    };
}

fn vertexStride(draw: Draw) u32 {
    return if (draw.stride != 0) draw.stride else draw.pipeline.vertex_layout.stride();
}

pub fn floatComponents(format: hal.Format) ?u3 {
    return switch (format) {
        .r32g32_float => 2,
        .r32g32b32_float => 3,
        .r32g32b32a32_float => 4,
        else => null,
    };
}

test "Mali native draw executes separate and shared alpha factors on the GPU" {
    var session = mali.Session.open(std.testing.allocator) catch return error.SkipZigTest;
    defer session.deinit();
    if (session.info.architecture_major != 10) return error.SkipZigTest;
    var image = try mali.Image.create(&session, 32, 32);
    defer image.deinit(&session);
    var pipeline = try mali.NativeGraphicsPipeline.createConstantColor(&session, .{ 1, 0, 0, 0.5 });
    defer pipeline.deinit(&session);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    const vertices = try session.allocBo(@sizeOf(@TypeOf(positions)), .{});
    defer session.freeBo(vertices);
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const center = 16 * image.row_stride + 16 * 4;
    for ([_]BlendMode{ .src_alpha, .src_alpha_both }, [_]u8{ 160, 96 }) |mode, expected_alpha| {
        try drawBatch(&session, image, &.{.{
            .pipeline = pipeline,
            .vertices = vertices,
            .vertex_count = 3,
            .blend = mode,
        }}, 0x40ff0000, 5_000_000_000);
        const pixel = image.pixels()[center..][0..4];
        try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(pixel[0])), 2);
        try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(pixel[2])), 2);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected_alpha)), @as(f32, @floatFromInt(pixel[3])), 2);
    }
}

test "Mali native front and back culling reverse with the declared front face" {
    var session = mali.Session.open(std.testing.allocator) catch return error.SkipZigTest;
    defer session.deinit();
    if (session.info.architecture_major != 10) return error.SkipZigTest;
    var image = try mali.Image.create(&session, 32, 32);
    defer image.deinit(&session);
    var pipeline = try mali.NativeGraphicsPipeline.createConstantColor(&session, .{ 1, 0, 0, 1 });
    defer pipeline.deinit(&session);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    const vertices = try session.allocBo(@sizeOf(@TypeOf(positions)), .{});
    defer session.freeBo(vertices);
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const center = 16 * image.row_stride + 16 * 4;
    var red: [4]u8 = undefined;
    const states = [_]hal.CullState{
        .{ .mode = .back, .front_face = .counter_clockwise },
        .{ .mode = .back, .front_face = .clockwise },
        .{ .mode = .front, .front_face = .counter_clockwise },
        .{ .mode = .front, .front_face = .clockwise },
    };
    for (states, &red) |cull, *result| {
        try drawBatch(&session, image, &.{.{
            .pipeline = pipeline,
            .vertices = vertices,
            .vertex_count = 3,
            .cull = cull,
        }}, 0xffff0000, 5_000_000_000);
        result.* = image.pixels()[center];
    }
    try std.testing.expect(red[0] != red[1]);
    try std.testing.expectEqual(red[0], red[3]);
    try std.testing.expectEqual(red[1], red[2]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 255, 0 }, &red);
}

// Hardware FAU counts are in 64-bit units. State BOs are zero-initialized,
// including padding when an odd number of scalar words is uploaded.
fn fauCount(header_bytes: usize, uniform_bytes: usize) u64 {
    return @intCast((header_bytes + uniform_bytes + 7) / 8);
}

test "Mali programmable stages read per-draw fragment uniforms on the GPU" {
    var session = mali.Session.open(std.testing.allocator) catch return error.SkipZigTest;
    defer session.deinit();
    if (session.info.architecture_major != 10) return error.SkipZigTest;
    var image = try mali.Image.create(&session, 32, 32);
    defer image.deinit(&session);
    var fragment: [1024]u8 = @splat(0);
    const constant = @import("native_pipeline.zig").constantFragment(.{ 0, 0, 0, 1 });
    @memcpy(fragment[0..constant.len], &constant);
    const spirv = try @import("../../glsl.zig").compileForStage(std.testing.allocator,
        \\attribute vec2 position;
        \\uniform mat4 projection;
        \\void main() { gl_Position = projection * vec4(position, 0.0, 1.0); }
    , .vertex);
    defer std.testing.allocator.free(spirv);
    const vertex = try @import("vertex.zig").compile(std.testing.allocator, spirv);
    defer vertex.deinit(std.testing.allocator);
    for (0..4) |channel_index| {
        const instruction = fragment[16 + channel_index * 8 ..][0..8];
        const old = std.mem.readInt(u64, instruction, .little);
        // MOV.i32 rN, u(4 + N/2).w(N%2). Retain the probe's waits.
        const mov: u64 = 0x0091_c000_0000_0088 | (@as(u64, channel_index) << 40) | @as(u64, channel_index);
        std.mem.writeInt(u64, instruction, mov | (old & 0xf800_0000_0000_0000), .little);
    }
    var pipeline = try @import("native_pipeline.zig").create(
        &session,
        .{ .code = vertex.code, .register_count = 59, .preload = 0x3800 },
        null,
        .{ .code = &fragment, .register_count = 4, .preload = 0x3000 },
        .position,
    );
    defer pipeline.deinit(&session);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    const vertices = try session.allocBo(@sizeOf(@TypeOf(positions)), .{});
    defer session.freeBo(vertices);
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const first = [_]f32{ 1, 0, 0.25, 1 };
    const second = [_]f32{ 0, 1, 0.75, 1 };
    var projection = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try drawBatch(&session, image, &.{
        .{ .pipeline = pipeline, .vertices = vertices, .vertex_count = 3, .vertex_uniforms = std.mem.asBytes(&projection), .fragment_uniforms = std.mem.asBytes(&first), .scissor = .{ .x = 0, .y = 0, .width = 16, .height = 32 } },
        .{ .pipeline = pipeline, .vertices = vertices, .vertex_count = 3, .vertex_uniforms = std.mem.asBytes(&projection), .fragment_uniforms = std.mem.asBytes(&second), .scissor = .{ .x = 16, .y = 0, .width = 16, .height = 32 } },
    }, 0xff00_0000, 5_000_000_000);
    const pixels = image.pixels();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 64, 255 }, pixels[16 * image.row_stride + 8 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 191, 255 }, pixels[16 * image.row_stride + 24 * 4 ..][0..4]);
    // The same input geometry moves entirely offscreen when the vertex
    // uniform matrix changes. This detects a passthrough substitution.
    projection[12] = 4;
    try drawBatch(&session, image, &.{.{
        .pipeline = pipeline,
        .vertices = vertices,
        .vertex_count = 3,
        .vertex_uniforms = std.mem.asBytes(&projection),
        .fragment_uniforms = std.mem.asBytes(&first),
    }}, 0xffff_0000, 5_000_000_000);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.pixels()[16 * image.row_stride + 16 * 4 ..][0..4]);
}

test "Mali GPU attachment load preserves pixels across separate draw submissions" {
    var session = mali.Session.open(std.testing.allocator) catch return error.SkipZigTest;
    defer session.deinit();
    if (session.info.architecture_major != 10) return error.SkipZigTest;
    var image = try mali.Image.create(&session, 65, 49);
    defer image.deinit(&session);
    var red = try mali.NativeGraphicsPipeline.createConstantColor(&session, .{ 1, 0, 0, 0.5 });
    defer red.deinit(&session);
    var green = try mali.NativeGraphicsPipeline.createConstantColor(&session, .{ 0, 1, 0, 1 });
    defer green.deinit(&session);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    const vertices = try session.allocBo(@sizeOf(@TypeOf(positions)), .{});
    defer session.freeBo(vertices);
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    try drawBatch(&session, image, &.{.{ .pipeline = red, .vertices = vertices, .vertex_count = 3 }}, 0xffff0000, 5_000_000_000);
    try drawBatch(&session, image, &.{.{
        .pipeline = green,
        .vertices = vertices,
        .vertex_count = 3,
        .scissor = .{ .x = 0, .y = 0, .width = 16, .height = 32 },
    }}, null, 5_000_000_000);
    const pixels = image.pixels();
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, pixels[16 * image.row_stride + 8 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, pixels[16 * image.row_stride + 24 * 4 ..][0..4]);
    var expected: [65 * 49][4]u8 = @splat(.{ 255, 0, 0, 128 });
    for (0..32) |y| for (0..16) |x| {
        expected[y * 65 + x] = .{ 0, 255, 0, 255 };
    };
    // Cross tile edges and partial edge tiles repeatedly, preserving alpha and
    // all pixels outside each new patch across independent fragment jobs.
    var cache: Cache = .{};
    defer cache.deinit(&session);
    var cached_handles: ?[3]u32 = null;
    for (0..12) |iteration| {
        const x = (iteration * 13) % 61;
        const y = (iteration * 7) % 45;
        const is_red = iteration % 2 == 0;
        try drawBatchCached(&session, image, &.{.{
            .pipeline = if (is_red) red else green,
            .vertices = vertices,
            .vertex_count = 3,
            .scissor = .{ .x = @intCast(x), .y = @intCast(y), .width = 5, .height = 5 },
        }}, null, 5_000_000_000, &cache);
        const handles = [3]u32{ cache.vertices.?.handle, cache.state.?.handle, cache.commands.?.bo.handle };
        if (cached_handles) |previous| try std.testing.expectEqual(previous, handles);
        cached_handles = handles;
        for (y..y + 5) |py| for (x..x + 5) |px| {
            expected[py * 65 + px] = if (is_red) .{ 255, 0, 0, 128 } else .{ 0, 255, 0, 255 };
        };
        for (0..49) |py| {
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected[py * 65 ..][0..65]), image.pixels()[py * image.row_stride ..][0 .. 65 * 4]);
        }
    }
}

fn compareFunction(compare: hal.CompareOp) u32 {
    return switch (compare) {
        .never => 0,
        .less => 1,
        .equal => 2,
        .less_or_equal => 3,
        .greater => 4,
        .not_equal => 5,
        .greater_or_equal => 6,
        .always => 7,
    };
}

test "Mali native depth comparisons occlude in both draw orders and honor write disable" {
    var session = mali.Session.open(std.testing.allocator) catch return error.SkipZigTest;
    defer session.deinit();
    if (session.info.architecture_major != 10) return error.SkipZigTest;
    var image = try mali.Image.create(&session, 32, 32);
    defer image.deinit(&session);
    var depth_image = try mali.Image.create(&session, 32, 32);
    defer depth_image.deinit(&session);
    const gpa = std.testing.allocator;
    const spirv = try @import("../../glsl.zig").compileForStage(gpa,
        \\attribute vec3 position;
        \\void main() { gl_Position = vec4(position, 1.0); }
    , .vertex);
    defer gpa.free(spirv);
    const vertex = try @import("vertex.zig").compile(gpa, spirv);
    defer vertex.deinit(gpa);
    const native = @import("native_pipeline.zig");
    const red_code = native.constantFragment(.{ 1, 0, 0, 1 });
    const green_code = native.constantFragment(.{ 0, 1, 0, 1 });
    var red = try native.create(&session, .{ .code = vertex.code, .register_count = 59, .preload = 0x3800 }, null, .{ .code = &red_code, .register_count = 4, .preload = 0x3000 }, .position);
    defer red.deinit(&session);
    var green = try native.create(&session, .{ .code = vertex.code, .register_count = 59, .preload = 0x3800 }, null, .{ .code = &green_code, .register_count = 4, .preload = 0x3000 }, .position);
    defer green.deinit(&session);
    const near = [_]f32{ -1, -1, -0.5, 3, -1, -0.5, -1, 3, -0.5 };
    const far = [_]f32{ -1, -1, 0.5, 3, -1, 0.5, -1, 3, 0.5 };
    const near_bo = try session.allocBo(@sizeOf(@TypeOf(near)), .{});
    defer session.freeBo(near_bo);
    const far_bo = try session.allocBo(@sizeOf(@TypeOf(far)), .{});
    defer session.freeBo(far_bo);
    @memcpy(near_bo.cpu[0..@sizeOf(@TypeOf(near))], std.mem.asBytes(&near));
    @memcpy(far_bo.cpu[0..@sizeOf(@TypeOf(far))], std.mem.asBytes(&far));
    const attributes = [_]hal.VertexAttribute{.{ .location = 0, .format = .r32g32b32_float, .offset = 0 }};
    var draws = [_]Draw{
        .{ .pipeline = red, .vertices = near_bo, .vertex_count = 3, .stride = 12, .attributes = &attributes, .depth_target = depth_image, .depth = .{ .test_enable = true, .write_enable = true, .compare_op = .less } },
        .{ .pipeline = green, .vertices = far_bo, .vertex_count = 3, .stride = 12, .attributes = &attributes, .depth_target = depth_image, .depth = .{ .test_enable = true, .write_enable = true, .compare_op = .less } },
    };
    const center = 16 * image.row_stride + 16 * 4;
    try drawBatch(&session, image, &draws, 0xffff0000, 5_000_000_000);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels()[center..][0..4]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), @as(f32, @bitCast(std.mem.readInt(u32, depth_image.pixels()[center..][0..4], .little))), 0.0001);
    var resumed = draws[1];
    resumed.depth_load = true;
    // A new submission clears color to blue but loads the existing near Z.
    // The farther green triangle must remain occluded by the loaded depth.
    try drawBatch(&session, image, &.{resumed}, 0xffff0000, 5_000_000_000);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, image.pixels()[center..][0..4]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), @as(f32, @bitCast(std.mem.readInt(u32, depth_image.pixels()[center..][0..4], .little))), 0.0001);
    std.mem.swap(Draw, &draws[0], &draws[1]);
    try drawBatch(&session, image, &draws, 0xffff0000, 5_000_000_000);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels()[center..][0..4]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), @as(f32, @bitCast(std.mem.readInt(u32, depth_image.pixels()[center..][0..4], .little))), 0.0001);
    std.mem.swap(Draw, &draws[0], &draws[1]);
    draws[0].depth.write_enable = false;
    try drawBatch(&session, image, &draws, 0xffff0000, 5_000_000_000);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, image.pixels()[center..][0..4]);
    draws[0].depth.write_enable = true;
    for ([_]f32{ 0, 16, -16 }) |bias| {
        draws[0].depth.bias_enable = bias != 0;
        draws[0].depth.bias_constant = if (bias == 0) 16 else bias;
        try drawBatch(&session, image, draws[0..1], 0xffff0000, 5_000_000_000);
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels()[center..][0..4]);
        const stored: f32 = @bitCast(std.mem.readInt(u32, depth_image.pixels()[center..][0..4], .little));
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), stored, 0.001);
        if (bias > 0) try std.testing.expect(stored > 0.25) else if (bias < 0) try std.testing.expect(stored < 0.25) else try std.testing.expectEqual(@as(f32, 0.25), stored);
    }
}

test "Mali native SFUs execute fog pow sqrt and log2 from uniform values" {
    const gpa = std.testing.allocator;
    var session = mali.Session.open(gpa) catch return error.SkipZigTest;
    defer session.deinit();
    if (session.info.architecture_major != 10) return error.SkipZigTest;
    var image = try mali.Image.create(&session, 32, 32);
    defer image.deinit(&session);
    var template = try mali.NativeGraphicsPipeline.createProbe(&session);
    defer template.deinit(&session);
    const descriptor = template.bo.cpu[@intCast(template.vertex_spd_va - template.bo.gpu_va)..];
    const code_va = std.mem.readInt(u64, descriptor[8..16], .little);
    const vertex = template.bo.cpu[@intCast(code_va - template.bo.gpu_va)..][0..512];
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const math = @import("math.zig");
    const emitter = math.Emitter{ .gpa = gpa, .code = &code };
    try emitter.emit(math.dest(0x91, 4) | 0x88);
    try emitter.emit(math.dest(0x91, 5) | 0x89);
    try emitter.pow(10, 4, 5);
    try emitter.sqrt(11, 4);
    try emitter.log2(12, 4);
    try emitter.constant(48, 0x3e80_0000);
    try emitter.constant(49, 0x3f80_0000);
    try emitter.fma(12, 12, 48, 49);
    var epilogue = @import("native_pipeline.zig").constantFragment(.{ 0, 0, 0, 1 });
    for (0..3) |i| {
        const instruction = epilogue[16 + i * 8 ..][0..8];
        const flow = std.mem.readInt(u64, instruction, .little) & 0xf800_0000_0000_0000;
        std.mem.writeInt(u64, instruction, math.dest(0x91, @intCast(i)) | @as(u64, 10 + i) | flow, .little);
    }
    try code.appendSlice(gpa, &epilogue);
    var pipeline = try @import("native_pipeline.zig").create(
        &session,
        .{ .code = vertex, .register_count = 6, .preload = 0x3800 },
        null,
        .{ .code = code.items, .register_count = 59, .preload = 0x3000 },
        .position,
    );
    defer pipeline.deinit(&session);
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    const vertices = try session.allocBo(@sizeOf(@TypeOf(positions)), .{});
    defer session.freeBo(vertices);
    @memcpy(vertices.cpu[0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    for ([_][2]f32{ .{ 0.25, 1.5 }, .{ 0.1, 0.75 }, .{ 0.8, 2 }, .{ 1, 1 } }) |input| {
        try drawBatch(&session, image, &.{.{ .pipeline = pipeline, .vertices = vertices, .vertex_count = 3, .fragment_uniforms = std.mem.asBytes(&input) }}, 0xffff0000, 5_000_000_000);
        const expected = [_]f32{ std.math.pow(f32, input[0], input[1]), @sqrt(input[0]), @log2(input[0]) * 0.25 + 1 };
        const pixel = image.pixels()[16 * image.row_stride + 16 * 4 ..][0..4];
        for (pixel[0..3], expected) |actual, channel_expected| try std.testing.expectApproxEqAbs(channel_expected * 255, @as(f32, @floatFromInt(actual)), 2);
    }
}

fn textureAt(draw: Draw, slot: usize) ?Texture {
    if (draw.textures[slot]) |texture| return texture;
    if (slot != 0) return null;
    const image = draw.texture orelse return null;
    return .{ .image = image, .swizzle = draw.texture_swizzle, .min_filter = draw.texture_min_filter, .mag_filter = draw.texture_mag_filter, .address_u = draw.texture_address_u, .address_v = draw.texture_address_v, .depth = draw.texture_depth };
}
