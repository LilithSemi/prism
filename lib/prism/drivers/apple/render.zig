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
    vertex: *Resource,
    count: u32,
    first: u32,
};

fn put(buf: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], value, .little);
}
fn get(buf: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buf[offset..][0..4], .little);
}

pub fn validate(target: *Resource, draws: []const Draw) hal.Error!void {
    if (target.kind != .image) return error.InvalidArgument;
    if (draws.len > 32) return error.Unsupported;
    var vs_bytes: usize = 0;
    var fs_bytes: usize = 0;
    for (draws) |draw| {
        if (draw.vertex.kind != .buffer or draw.pipeline.color_format != target.format) return error.InvalidArgument;
        if (draw.count % 3 != 0) return error.Unsupported;
        const end = (@as(u64, draw.first) + draw.count) * draw.pipeline.stride;
        if (end > draw.vertex.desc.buffer.size) return error.InvalidArgument;
        vs_bytes = std.mem.alignForward(usize, vs_bytes, 64) + draw.pipeline.vertex.len;
        fs_bytes = std.mem.alignForward(usize, fs_bytes, 64) + draw.pipeline.fragment.len;
    }
    if (vs_bytes > PAGE or fs_bytes > PAGE) return error.Unsupported;
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

pub fn run(dev: *Device, target: *Resource, clear: ?hal.Color, draws: []const Draw) hal.Error!void {
    try validate(target, draws);
    if (clear) |color| return runPass(dev, target, color, draws, false);

    // Until asahi.zig exposes a background-load program, preserve existing
    // pixels using a second GPU coverage pass. Both shading and rasterization
    // run on AGX; the CPU only copies pixels selected by the GPU coverage mask.
    // A separate mask preserves even covered fragments whose output alpha is 0.
    const device = dev.halDevice();
    const rendered = try device.createResource(target.desc);
    defer device.destroyResource(rendered);
    const coverage = try device.createResource(target.desc);
    defer device.destroyResource(coverage);
    const color: *Resource = @ptrCast(@alignCast(rendered));
    const mask: *Resource = @ptrCast(@alignCast(coverage));
    const zero: hal.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    try runPass(dev, color, zero, draws, false);
    try runPass(dev, mask, zero, draws, true);
    asahi.cleanInvalidateToPoC(target.bo.cpu);
    const size = @as(usize, target.width) * target.height * 4;
    var offset: usize = 0;
    while (offset < size) : (offset += 4) {
        if (mask.bo.cpu[offset] != 0)
            @memcpy(target.bo.cpu[offset..][0..4], color.bo.cpu[offset..][0..4]);
    }
    asahi.cleanToPoC(target.bo.cpu);
}

fn runPass(dev: *Device, target: *Resource, clear: hal.Color, draws: []const Draw, coverage: bool) hal.Error!void {
    // Fixed render infrastructure lives below HAL resource VAs. Each pass is
    // synchronous, so a completed pass can safely reuse these VA slots.
    var bos: [18]asahi.Bo = undefined;
    var allocated: usize = 0;
    defer for (bos[0..allocated]) |bo| dev.dev.freeBo(dev.vm_id, bo);
    for (&bos, 0..) |*bo, i| {
        bo.* = dev.dev.allocBo(dev.vm_id, PAGE, asahi.USC_EXEC_BASE + (i + 1) * PAGE) catch |e| return aserr(e);
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

    const stride = std.mem.alignForward(u32, target.width * 4, 16);
    const temporary = if (stride != target.width * 4)
        try dev.halDevice().createResource(.{ .buffer = .{ .size = @as(usize, stride) * target.height } })
    else
        null;
    defer if (temporary) |res| dev.halDevice().destroyResource(res);
    const output: *Resource = if (temporary) |res| @ptrCast(@alignCast(res)) else target;
    _ = r.buildEotShader(eot_code.cpu);
    _ = r.buildBgClearShaderColor(bg_code.cpu, if (target.format == .bgra8_unorm) .{ clear.b, clear.g, clear.r, clear.a } else .{ clear.r, clear.g, clear.b, clear.a });
    _ = r.buildBgUsc(bg_usc.cpu, @intCast(bg_code.gpu_va - asahi.USC_EXEC_BASE), 8);
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
    const coverage_program = @import("graphics.zig").Program.coverage();
    for (draws, 0..) |draw, i| {
        if (draw.count == 0) continue;
        vs_offset = std.mem.alignForward(usize, vs_offset, 64);
        fs_offset = std.mem.alignForward(usize, fs_offset, 64);
        var vertex = draw.pipeline.vertex;
        vertex.patchVertexBase(draw.vertex.bo.gpu_va);
        @memcpy(vs_code.cpu[vs_offset..][0..vertex.len], vertex.bytes[0..vertex.len]);
        const fragment = if (coverage) &coverage_program else &draw.pipeline.fragment;
        @memcpy(fs_code.cpu[fs_offset..][0..fragment.len], fragment.bytes[0..fragment.len]);
        const usc_offset = i * 64;
        _ = r.buildVsUsc(vs_usc.cpu[usc_offset..], @intCast(vs_code.gpu_va + vs_offset - asahi.USC_EXEC_BASE), vertex.registers, sampler.gpu_va);
        _ = r.buildFsUsc(fs_usc.cpu[usc_offset..], @intCast(fs_code.gpu_va + fs_offset - asahi.USC_EXEC_BASE), fragment.registers, sampler.gpu_va, dummy_uniform.gpu_va);
        // buildFsUsc: sampler(8), uniform(8), shared(4), shader(6).
        // Set loads_varyings in the SHADER word when coefficients are used.
        if (fragment.input_count != 0) fs_usc.cpu[usc_offset + 21] |= 1;
        const ppp_offset = i * 256;
        const cf_offset = i * 256;
        const cf_count = bindings(cf.cpu[cf_offset..], &vertex, fragment);
        const ppp_len = r.buildPpp(ppp.cpu[ppp_offset..], @intCast(fs_usc.gpu_va + usc_offset - asahi.USC_EXEC_BASE));
        const state = ppp.cpu[ppp_offset..][0..ppp_len];
        // buildPpp emits a fixed set of records; patch the variable linkage.
        put(state, 28, if (vertex.varying_count != 0) 1 << 16 else 0); // Output Select
        put(state, 32, vertex.varying_count); // Varying Counts 32: smooth
        put(state, 48, get(state, 48) | (cf_count << 16)); // FS Word 0
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
        asahi.cleanToPoC(draw.vertex.bo.cpu);
    }
    put(vdm.cpu, stream_len, 6 << 29);
    stream_len += 4;
    const bg = asahi.uapi.drm_asahi_bg_eot{ .usc = @as(u32, @intCast(bg_usc.gpu_va - asahi.USC_EXEC_BASE)) | 4, .rsrc_spec = r.buildCounts(0, true) };
    const eot = asahi.uapi.drm_asahi_bg_eot{ .usc = @as(u32, @intCast(eot_usc.gpu_va - asahi.USC_EXEC_BASE)) | 4, .rsrc_spec = r.buildCounts(1, false) };
    var command: [1024]u8 = @splat(0);
    const cmd_len = r.buildCmdbuf(&command, vdm.gpu_va, stream_len, output.bo.gpu_va, output.bo.size, bg, eot, scissor.gpu_va, dbias.gpu_va, target.width, target.height);
    for (bos) |bo| asahi.cleanToPoC(bo.cpu);
    const sync = dev.dev.syncobjCreate(false) catch |e| return aserr(e);
    defer dev.dev.syncobjDestroy(sync);
    const signals = [_]asahi.uapi.drm_asahi_sync{asahi.Device.binarySync(sync)};
    dev.dev.submit(dev.queue_id, command[0..cmd_len], &.{}, &signals) catch |e| return aserr(e);
    dev.dev.syncobjWait(&.{sync}, 1_000_000_000) catch |e| return aserr(e);
    asahi.cleanInvalidateToPoC(output.bo.cpu);
    if (temporary != null) {
        const row = @as(usize, target.width) * 4;
        for (0..target.height) |y| @memcpy(target.bo.cpu[y * row ..][0..row], output.bo.cpu[y * stride ..][0..row]);
        asahi.cleanToPoC(target.bo.cpu);
    }
}
