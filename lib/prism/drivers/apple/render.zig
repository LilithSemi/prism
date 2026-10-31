//! HAL render passes using asahi.zig's G13 command and state encoders.
const std = @import("std");
const asahi = @import("asahi");
const r = asahi.render;
const hal = @import("../../hal.zig");
const Device = @import("device.zig").Device;
const aserr = @import("device.zig").aserr;
const Resource = @import("resource.zig").Resource;
const Pipeline = @import("pipeline.zig").Pipeline;
const PAGE = asahi.PAGE;

pub const Draw = struct {
    pipeline: *Pipeline,
    vertex: ?*Resource,
    count: u32,
    first: u32,
    uniforms: [8]?*Resource = @splat(null),
    textures: [8]?hal.TextureBinding = @splat(null),
};

pub const Depth = struct { resource: *Resource, clear: ?f32 };

fn depthOffset(x: usize, y: usize, width: usize) usize {
    var morton: usize = 0;
    for (0..6) |i| {
        const shift: u6 = @intCast(i);
        morton |= ((x >> shift) & 1) << @intCast(2 * i);
        morton |= ((y >> shift) & 1) << @intCast(2 * i + 1);
    }
    return (((y / 64) * (width / 64) + x / 64) * 4096 + morton) * 4;
}

fn put(buf: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], value, .little);
}
fn get(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

fn put64(buf: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, buf[offset..][0..8], value, .little);
}

fn wrap(mode: hal.AddressMode) u64 {
    return switch (mode) {
        .clamp_to_edge => 0,
        .repeat => 1,
        .mirrored_repeat => 2,
    };
}

fn textureDescriptor(out: []u8, binding: hal.TextureBinding, image: *Resource, va: u64, stride: u32) void {
    var channels: u64 = 0;
    for (binding.swizzle, 0..) |swizzle, i| {
        var channel: u64 = switch (swizzle) {
            .r => 0,
            .g => 1,
            .b => 2,
            .a => 3,
            .one => 4,
            .zero => 5,
        };
        if (image.format == .bgra8_unorm and channel < 3 and channel != 1) channel = 2 - channel;
        channels |= channel << @intCast(16 + i * 3);
    }
    const mipmaps = image.desc.image.mip_levels > 1;
    const first = @min(binding.base_level, image.desc.image.mip_levels - 1);
    const last = @min(binding.max_level, image.desc.image.mip_levels - 1);
    put64(out, 0, 2 | (if (mipmaps) @as(u64, 2 << 4) else 0) | (0x28 << 6) | channels | (@as(u64, image.width - 1) << 28) | (@as(u64, image.height - 1) << 42) | (@as(u64, first) << 56) | (@as(u64, last) << 60));
    put64(out, 8, ((va >> 4) << 2) | (if (mipmaps) @as(u64, 1 << 38) else @as(u64, (stride - 16) / 16) << 46));
    put64(out, 16, 0);
}

fn samplerDescriptor(out: []u8, binding: hal.TextureBinding) void {
    const min_lod: u64 = @intFromFloat(std.math.clamp(binding.min_lod * 64, 0, 896));
    const max_lod: u64 = @intFromFloat(std.math.clamp(binding.max_lod * 64, 0, 896));
    const mip: u64 = switch (binding.mip_filter) {
        .none => 0,
        .nearest => 1,
        .linear => 2,
    };
    put64(out, 0, min_lod | (max_lod << 10) | (mip << 27) | (@as(u64, @intFromBool(binding.filter == .linear)) << 23) |
        (@as(u64, @intFromBool(binding.min_filter == .linear)) << 25) |
        (wrap(binding.address_u) << 29) | (wrap(binding.address_v) << 32));
}

pub fn validate(target: *Resource, draws: []const Draw) hal.Error!void {
    if (target.kind != .image) return error.InvalidArgument;
    if (draws.len > 32) return error.Unsupported;
    var vs_bytes: usize = 0;
    var fs_bytes: usize = 0;
    for (draws) |draw| {
        for ([_]*const @import("graphics.zig").Program{ &draw.pipeline.vertex, &draw.pipeline.fragment }) |program| {
            for (program.uniform_patches[0..program.uniform_patch_count]) |patch| {
                const buffer = draw.uniforms[patch.binding] orelse return error.InvalidArgument;
                if (buffer.kind != .buffer or @as(u64, patch.byte_offset) + 4 > buffer.desc.buffer.size) return error.InvalidArgument;
            }
            for (0..8) |unit| if (program.texture_mask & (@as(u8, 1) << @intCast(unit)) != 0) {
                const binding = draw.textures[unit] orelse return error.InvalidArgument;
                const image: *Resource = @ptrCast(@alignCast(binding.image));
                if (image.kind != .image or (image.format != .rgba8_unorm and image.format != .bgra8_unorm)) return error.Unsupported;
            };
        }
        if (draw.pipeline.color_format != target.format) return error.InvalidArgument;
        if (draw.count % 3 != 0) return error.Unsupported;
        const end = (@as(u64, draw.first) + draw.count) * draw.pipeline.stride;
        if (draw.vertex) |vertex| {
            if (vertex.kind != .buffer or end > vertex.desc.buffer.size) return error.InvalidArgument;
        } else if (draw.pipeline.stride != 0) return error.InvalidArgument;
        vs_bytes = std.mem.alignForward(usize, vs_bytes, 64) + draw.pipeline.vertex.len;
        fs_bytes = std.mem.alignForward(usize, fs_bytes, 64) + draw.pipeline.fragment.len;
    }
    if (vs_bytes > 32 * 16384 or fs_bytes > 32 * 16384) return error.Unsupported;
}

fn bindings(out: []u8, vs: *const @import("graphics.zig").Program, fs: *const @import("graphics.zig").Program) u32 {
    if (fs.input_count == 0) return 0;
    // One coefficient for reciprocal W, followed by the linked user scalars.
    put(out, 0, (1 + vs.varying_count) | ((1 + fs.input_count) << 8));
    put(out, 4, 3 << 2); // W, linear interpolation, UVS base slot 0
    for (fs.inputs[0..fs.input_count], 0..) |slot, i| {
        const uvs = vs.outputs[slot].?;
        put(out, 8 + i * 4, (7 << 2) | ((uvs - 3) << 8) | (@as(u32, @intCast(i + 1)) << 16));
    }
    return fs.input_count + 1;
}

pub fn run(dev: *Device, target: *Resource, clear: ?hal.Color, draws: []const Draw, depth: ?Depth) hal.Error!void {
    try validate(target, draws);
    if (depth) |d| {
        if (d.resource.width != target.width or d.resource.height != target.height) return error.InvalidArgument;
    }

    try runPass(dev, target, clear, draws, depth);
}

fn runPass(dev: *Device, target: *Resource, clear: ?hal.Color, draws: []const Draw, depth: ?Depth) hal.Error!void {
    // Fixed render infrastructure lives below HAL resource VAs. Each pass is
    // synchronous, so a completed pass can safely reuse these VA slots.
    var bos: [19]asahi.Bo = undefined;
    var vertex_bytes: usize = 0;
    var fragment_bytes: usize = 0;
    for (draws) |draw| {
        vertex_bytes = std.mem.alignForward(usize, vertex_bytes, 64) + draw.pipeline.vertex.len;
        fragment_bytes = std.mem.alignForward(usize, fragment_bytes, 64) + draw.pipeline.fragment.len;
    }
    var allocated: usize = 0;
    defer for (bos[0..allocated]) |bo| dev.dev.freeBo(dev.vm_id, bo);
    for (&bos, 0..) |*bo, i| {
        const size = if (i == 0) @max(PAGE, std.mem.alignForward(usize, vertex_bytes, PAGE)) else if (i == 1) @max(PAGE, std.mem.alignForward(usize, fragment_bytes, PAGE)) else PAGE;
        // Shader streams grow with the number of draws. Give them separate VA
        // ranges so larger programs cannot overlap the per-pass state pages.
        const va = asahi.USC_EXEC_BASE + if (i == 0) @as(u64, 0x0100_0000) else if (i == 1) @as(u64, 0x0200_0000) else (i + 1) * PAGE;
        bo.* = dev.dev.allocBo(dev.vm_id, size, va) catch |e| return aserr(e);
        allocated += 1;
        @memset(bo.cpu, 0);
    }
    const vs_code = bos[0];
    const fs_code = bos[1];
    const eot_code = bos[2];
    const vs_usc = bos[3];
    const fs_usc = bos[4];
    const bg_usc = bos[5];
    const eot_usc = bos[6];
    const vdm = bos[7];
    const ppp = bos[8];
    const pbe = bos[9];
    const cf = bos[10];
    const bg_code = bos[11];
    const init_ppp = bos[12];
    const scissor = bos[13];
    const dbias = bos[14];
    const viewport = bos[15];
    const sampler = bos[16];
    const dummy_uniform = bos[17];
    const texture_descriptors = bos[18];
    var uploads: std.ArrayList(*hal.Resource) = .empty;
    defer {
        for (uploads.items) |res| dev.halDevice().destroyResource(res);
        uploads.deinit(dev.gpa);
    }
    const depth_width = std.mem.alignForward(u32, target.width, 64);
    const depth_height = std.mem.alignForward(u32, target.height, 64);
    const depth_bo = if (depth != null) dev.dev.allocBo(dev.vm_id, @as(u64, depth_width) * depth_height * 4, asahi.USC_EXEC_BASE + 0x1000_0000) catch |e| return aserr(e) else null;
    defer if (depth_bo) |bo| dev.dev.freeBo(dev.vm_id, bo);
    if (depth) |d| {
        const bo = depth_bo.?;
        asahi.cleanInvalidateToPoC(d.resource.bo.cpu);
        if (d.clear == null) {
            for (0..target.height) |y| for (0..target.width) |x| {
                const offset = (y * target.width + x) * 4;
                @memcpy(bo.cpu[depthOffset(x, y, depth_width)..][0..4], d.resource.bo.cpu[offset..][0..4]);
            };
        }
        asahi.cleanToPoC(bo.cpu);
    }

    const stride = std.mem.alignForward(u32, target.width * 4, 16);
    const temporary = if (stride != target.width * 4)
        try dev.halDevice().createResource(.{ .buffer = .{ .size = @as(usize, stride) * target.height } })
    else
        null;
    defer if (temporary) |res| dev.halDevice().destroyResource(res);
    const output: *Resource = if (temporary) |res| @ptrCast(@alignCast(res)) else target;
    _ = r.buildEotShader(eot_code.cpu);
    if (clear) |color| {
        _ = r.buildBgClearShaderColor(bg_code.cpu, if (target.format == .bgra8_unorm) .{ color.b, color.g, color.r, color.a } else .{ color.r, color.g, color.b, color.a });
        _ = r.buildBgUsc(bg_usc.cpu, @intCast(bg_code.gpu_va - asahi.USC_EXEC_BASE), 8);
    } else {
        if (temporary != null) {
            const row = @as(usize, target.width) * 4;
            for (0..target.height) |y| @memcpy(output.bo.cpu[y * stride ..][0..row], target.bo.cpu[y * row ..][0..row]);
        }
        asahi.cleanToPoC(output.bo.cpu);
        const program = @import("graphics.zig").Program.backgroundLoad();
        @memcpy(bg_code.cpu[0..program.len], program.bytes[0..program.len]);
        var physical = target.*;
        physical.format = .rgba8_unorm;
        physical.desc.image.mip_levels = 1;
        textureDescriptor(texture_descriptors.cpu[8192..], .{ .binding = 0, .image = @ptrCast(target) }, &physical, output.bo.gpu_va, stride);
        put64(bg_usc.cpu, 0, 0xdd | (1 << 20) | (((texture_descriptors.gpu_va + 8192) >> 3) << 27));
        put64(bg_usc.cpu, 8, 0x9d | (1 << 20) | ((sampler.gpu_va >> 3) << 27));
        _ = r.buildBgUsc(bg_usc.cpu[16..], @intCast(bg_code.gpu_va - asahi.USC_EXEC_BASE), program.registers);
    }
    _ = r.buildEotUsc(eot_usc.cpu, @intCast(eot_code.gpu_va - asahi.USC_EXEC_BASE), 2, pbe.gpu_va);
    _ = r.buildPbe(pbe.cpu, output.bo.gpu_va, stride, target.width, target.height);
    _ = r.buildTxfSampler(sampler.cpu);
    const init_len = r.buildInitPpp(init_ppp.cpu);
    _ = r.buildScissor(scissor.cpu, target.width, target.height);
    _ = r.buildDepthBias(dbias.cpu);
    const viewport_len = r.buildViewportScissorPpp(viewport.cpu, target.width, target.height);

    var vs_offset: usize = 0;
    var fs_offset: usize = 0;
    // A clear/zero-vertex pass still requires a valid barrier + terminate stream.
    put(vdm.cpu, 0, (1 << 29) | (1 << 3));
    var stream_len: usize = 4;
    for (draws, 0..) |draw, i| {
        if (draw.count == 0) continue;
        vs_offset = std.mem.alignForward(usize, vs_offset, 64);
        fs_offset = std.mem.alignForward(usize, fs_offset, 64);
        var vertex = draw.pipeline.vertex;
        vertex.patchVertexBase(if (draw.vertex) |v| v.bo.gpu_va else 0);
        var bases: [8]u64 = @splat(0);
        for (draw.uniforms, 0..) |resource, binding| if (resource) |res| {
            bases[binding] = res.bo.gpu_va;
            asahi.cleanToPoC(res.bo.cpu);
        };
        try vertex.patchUniforms(&bases);
        @memcpy(vs_code.cpu[vs_offset..][0..vertex.len], vertex.bytes[0..vertex.len]);
        var fragment_program = draw.pipeline.fragment;
        try fragment_program.patchUniforms(&bases);
        const fragment = &fragment_program;
        @memcpy(fs_code.cpu[fs_offset..][0..fragment.len], fragment.bytes[0..fragment.len]);
        const usc_offset = i * 64;
        const sampler_va = sampler.gpu_va + i * 128;
        _ = r.buildTxfSampler(sampler.cpu[i * 128 ..]);
        for (draw.textures, 0..) |binding, unit| if (binding) |b| {
            const image: *Resource = @ptrCast(@alignCast(b.image));
            const image_stride = std.mem.alignForward(u32, image.width * 4, 16);
            var image_va = image.bo.gpu_va;
            asahi.cleanToPoC(image.bo.cpu);
            const tiled = image.desc.image.mip_levels > 1;
            const mip_layout = @import("texture.zig").layout(image.width, image.height, image.desc.image.mip_levels);
            if (tiled or image_stride != image.width * 4) {
                const upload = try dev.halDevice().createResource(.{ .buffer = .{ .size = if (tiled) mip_layout.size else @as(usize, image_stride) * image.height } });
                uploads.append(dev.gpa, upload) catch {
                    dev.halDevice().destroyResource(upload);
                    return error.OutOfMemory;
                };
                const res: *Resource = @ptrCast(@alignCast(upload));
                if (tiled) {
                    @import("texture.zig").upload(res.bo.cpu, image.bo.cpu, mip_layout);
                } else for (0..image.height) |y| @memcpy(res.bo.cpu[y * image_stride ..][0 .. image.width * 4], image.bo.cpu[y * image.width * 4 ..][0 .. image.width * 4]);
                asahi.cleanToPoC(res.bo.cpu);
                image_va = res.bo.gpu_va;
            }
            textureDescriptor(texture_descriptors.cpu[i * 256 + unit * 24 ..], b, image, image_va, image_stride);
            samplerDescriptor(sampler.cpu[i * 128 + (unit + 1) * 8 ..], b);
        };
        _ = r.buildVsUsc(vs_usc.cpu[usc_offset..], @intCast(vs_code.gpu_va + vs_offset - asahi.USC_EXEC_BASE), vertex.registers, sampler.gpu_va);
        const prefix: usize = if (fragment.texture_mask != 0) 8 else 0;
        if (prefix != 0) put64(fs_usc.cpu, usc_offset, 0xdd | (8 << 20) | (((texture_descriptors.gpu_va + i * 256) >> 3) << 27));
        _ = r.buildFsUsc(fs_usc.cpu[usc_offset + prefix ..], @intCast(fs_code.gpu_va + fs_offset - asahi.USC_EXEC_BASE), fragment.registers, sampler_va, dummy_uniform.gpu_va);
        if (prefix != 0) put(fs_usc.cpu, usc_offset + prefix, (get(fs_usc.cpu, usc_offset + prefix) & ~@as(u32, 127 << 20)) | (9 << 20));
        // buildFsUsc: sampler(8), uniform(8), shared(4), shader(6).
        // Set loads_varyings in the SHADER word when coefficients are used.
        if (fragment.input_count != 0) fs_usc.cpu[usc_offset + prefix + 21] |= 1;
        const ppp_offset = i * 256;
        const cf_offset = i * 256;
        const cf_count = bindings(cf.cpu[cf_offset..], &vertex, fragment);
        const ppp_len = r.buildPpp(ppp.cpu[ppp_offset..], @intCast(fs_usc.gpu_va + usc_offset - asahi.USC_EXEC_BASE));
        const state = ppp.cpu[ppp_offset..][0..ppp_len];
        if (draw.pipeline.blend.enable or !std.mem.allEqual(bool, &draw.pipeline.blend.write_mask, true)) {
            put(state, 4, get(state, 4) | (1 << 29)); // translucent, reads destination tile color
            put(state, 8, get(state, 8) | (1 << 29));
        }
        const ds = draw.pipeline.depth;
        const compare: u32 = if (ds.test_enable and depth != null) switch (ds.compare_op) {
            .never => 0,
            .less => 1,
            .equal => 2,
            .less_or_equal => 3,
            .greater => 4,
            .not_equal => 5,
            .greater_or_equal => 6,
            .always => 7,
        } else 7;
        for ([_]usize{ 12, 16, 20, 24 }) |offset| {
            put(state, offset, (compare << 24) | (@as(u32, @intFromBool(!ds.test_enable or !ds.write_enable or depth == null)) << 21));
        }
        const cull = draw.pipeline.cull;
        put(state, 40, get(state, 40) |
            @as(u32, @intFromBool(cull.mode == .front)) |
            (@as(u32, @intFromBool(cull.mode == .back)) << 1) |
            (@as(u32, @intFromBool(cull.front_face == .counter_clockwise)) << 16));
        // buildPpp emits a fixed set of records; patch the variable linkage.
        put(state, 28, if (vertex.varying_count != 0) 1 << 16 else 0); // Output Select
        put(state, 32, vertex.varying_count); // Varying Counts 32: smooth
        put(state, 48, get(state, 48) | (cf_count << 16)); // FS Word 0
        if (prefix != 0) put(state, 48, (get(state, 48) & ~@as(u32, 7 << 9)) | (3 << 9));
        put(state, 56, if (cf_count != 0) @intCast(cf.gpu_va + cf_offset - asahi.USC_EXEC_BASE) else 0); // CF bindings, USC-relative
        put(state, ppp_len - 4, 4 + vertex.varying_count);
        var one: [128]u8 = @splat(0);
        const n = r.buildVdmStream(&one, @intCast(vs_usc.gpu_va + usc_offset - asahi.USC_EXEC_BASE), ppp.gpu_va + ppp_offset, @intCast(ppp_len / 4), init_ppp.gpu_va, @intCast(init_len / 4), viewport.gpu_va, @intCast(viewport_len / 4));
        put(&one, 24, (4 + vertex.varying_count) * 0x101); // VDM vertex outputs
        put(&one, n - 16, draw.count);
        put(&one, n - 8, draw.first);
        @memcpy(vdm.cpu[stream_len..][0 .. n - 8], one[4 .. n - 4]);
        stream_len += n - 8;
        vs_offset += vertex.len;
        fs_offset += fragment.len;
        if (draw.vertex) |v| asahi.cleanToPoC(v.bo.cpu);
    }
    put(vdm.cpu, stream_len, 6 << 29);
    stream_len += 4;
    const bg = asahi.uapi.drm_asahi_bg_eot{ .usc = @as(u32, @intCast(bg_usc.gpu_va - asahi.USC_EXEC_BASE)) | 4, .rsrc_spec = (r.buildCounts(if (clear == null) 1 else 0, true) | (if (clear == null) @as(u32, 1 << 9) else 0)) };
    const eot = asahi.uapi.drm_asahi_bg_eot{ .usc = @as(u32, @intCast(eot_usc.gpu_va - asahi.USC_EXEC_BASE)) | 4, .rsrc_spec = r.buildCounts(1, false) };
    var command: [1024]u8 = @splat(0);
    const cmd_len = r.buildCmdbuf(&command, vdm.gpu_va, stream_len, output.bo.gpu_va, output.bo.size, bg, eot, scissor.gpu_va, dbias.gpu_va, target.width, target.height);
    if (depth) |d| {
        const offset = 2 * @sizeOf(asahi.uapi.drm_asahi_cmd_header) + @sizeOf(asahi.uapi.drm_asahi_attachment);
        const body: *align(1) asahi.uapi.drm_asahi_cmd_render = @ptrCast(&command[offset]);
        body.depth = .{ .base = depth_bo.?.gpu_va, .comp_base = 0, .stride = @intCast((depth_bo.?.size - PAGE) | 1), .comp_stride = 0 };
        // The backing uses paged GPU tiles, not a whole-image Morton swizzle.
        body.zls_ctrl = (1 << 19) | (if (d.clear == null) @as(u64, 1 << 15) else 0);
        body.isp_zls_pixels = (depth_width - 1) | ((depth_height - 1) << 15);
        body.isp_bgobjdepth = @bitCast(d.clear orelse @as(f32, 1));
    }
    for (bos) |bo| asahi.cleanToPoC(bo.cpu);
    const sync = dev.dev.syncobjCreate(false) catch |e| return aserr(e);
    defer dev.dev.syncobjDestroy(sync);
    const signals = [_]asahi.uapi.drm_asahi_sync{asahi.Device.binarySync(sync)};
    dev.dev.submit(dev.queue_id, command[0..cmd_len], &.{}, &signals) catch |e| return aserr(e);
    dev.dev.syncobjWait(&.{sync}, 1_000_000_000) catch |e| return aserr(e);
    asahi.cleanInvalidateToPoC(output.bo.cpu);
    if (depth) |d| {
        const bo = depth_bo.?;
        asahi.cleanInvalidateToPoC(bo.cpu);
        for (0..target.height) |y| for (0..target.width) |x| {
            const offset = (y * target.width + x) * 4;
            @memcpy(d.resource.bo.cpu[offset..][0..4], bo.cpu[depthOffset(x, y, depth_width)..][0..4]);
        };
        asahi.cleanToPoC(d.resource.bo.cpu);
    }
    if (temporary != null) {
        const row = @as(usize, target.width) * 4;
        for (0..target.height) |y| @memcpy(target.bo.cpu[y * row ..][0..row], output.bo.cpu[y * stride ..][0..row]);
        asahi.cleanToPoC(target.bo.cpu);
    }
}
