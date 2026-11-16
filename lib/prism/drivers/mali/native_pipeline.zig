//! Shader storage for programmable native Valhall pipelines. Code sections are
//! sized independently; shader length is not limited by the probe templates.
const std = @import("std");
const mali = @import("mali");
const descriptors = mali.descriptors;
const Stage = mali.NativeGraphicsPipeline.Stage;

pub fn create(
    session: *mali.Session,
    vertex: Stage,
    varying: ?Stage,
    fragment: Stage,
    layout: mali.NativeGraphicsPipeline.VertexLayout,
) mali.graphics.Error!mali.NativeGraphicsPipeline {
    for ([_]?Stage{ vertex, varying, fragment }) |optional| {
        if (optional) |stage| {
            if (stage.code.len == 0 or stage.code.len % 8 != 0 or stage.register_count == 0 or stage.register_count > 64)
                return error.InvalidShader;
        }
    }
    const varying_offset = std.mem.alignForward(usize, vertex.code.len, 128);
    const fragment_offset = std.mem.alignForward(usize, varying_offset + if (varying) |stage| stage.code.len else @as(usize, 0), 128);
    const spd_offset = std.mem.alignForward(usize, fragment_offset + fragment.code.len, 64);
    const tsd_offset = spd_offset + 128;
    const bo = try session.allocBo(std.mem.alignForward(usize, tsd_offset + 64, 4096), .{ .executable = true });
    errdefer session.freeBo(bo);
    @memset(bo.cpu, 0);
    for ([_]?Stage{ vertex, varying, fragment }, [_]usize{ 0, varying_offset, fragment_offset }, 0..) |optional, offset, i| {
        if (optional) |stage| {
            @memcpy(bo.cpu[offset..][0..stage.code.len], stage.code);
            var spd = descriptors.ShaderProgram.init(
                if (i == 2) .fragment else .vertex,
                bo.gpu_va + offset,
                stage.preload,
                if (stage.register_count <= 32) .per_thread_32 else .per_thread_64,
            );
            spd.words[0] |= stage.descriptor_flags;
            copyWords(bo.cpu, spd_offset + i * 32, &spd.words);
        }
    }
    const storage = descriptors.LocalStorage.empty();
    copyWords(bo.cpu, tsd_offset, &storage.words);
    return .{
        .bo = bo,
        .vertex_spd_va = bo.gpu_va + spd_offset,
        .varying_spd_va = if (varying != null) bo.gpu_va + spd_offset + 32 else 0,
        .fragment_spd_va = bo.gpu_va + spd_offset + 64,
        .tsd_va = bo.gpu_va + tsd_offset,
        .vertex_layout = layout,
        .blend = .replace,
    };
}

fn copyWords(bytes: []u8, offset: usize, words: []const u32) void {
    for (words, 0..) |word, i| std.mem.writeInt(u32, bytes[offset + i * 4 ..][0..4], word, .little);
}

/// Constant RGBA followed by the v10 fixed-function blend epilogue. Color
/// materialization uses Valhall's full-width IADD_IMM, independent of FAUs.
pub fn constantFragment(color: [4]f32) [72]u8 {
    var code: [72]u8 = undefined;
    const words = [_]u64{
        0x4000_c000_0000_0000,
        0x087d_bc02_00ea_d07c,
        0,
        0,
        0,
        0,
        0x787f_4008_323c_0084,
        0x0110_f000_0000_00c0,
        0x002f_c110_0000_85c0,
    };
    for (words, 0..) |word, i| std.mem.writeInt(u64, code[i * 8 ..][0..8], word, .little);
    for (color, 0..) |channel, i| {
        const bits: u32 = @bitCast(channel);
        const flow: u64 = if (i == 0) 0x68 else if (i == 3) 0x48 else 0;
        const raw = 0x0110_c000_0000_00c0 | (@as(u64, i) << 40) | (@as(u64, bits) << 8) | (flow << 56);
        std.mem.writeInt(u64, code[16 + i * 8 ..][0..8], raw, .little);
    }
    return code;
}

/// Full-screen depth attachment load: interpolate UV, sample linear D32F,
/// then export the sample through Valhall's native ZS_EMIT instruction.
pub fn createDepthLoad(session: *mali.Session) mali.graphics.Error!mali.NativeGraphicsPipeline {
    var template = try mali.NativeGraphicsPipeline.createImage(session);
    defer template.deinit(session);
    var stages: [2][]const u8 = undefined;
    for ([_]u64{ template.vertex_spd_va, template.varying_spd_va }, &stages) |address, *code| {
        const descriptor = template.bo.cpu[@intCast(address - template.bo.gpu_va)..];
        const binary = std.mem.readInt(u64, descriptor[8..16], .little);
        code.* = template.bo.cpu[@intCast(binary - template.bo.gpu_va)..][0..512];
    }
    const words = [_]u64{
        0x005c_8004_1200_003d, // LD_VAR_BUF_IMM UV.xy, slot 0
        0x0891_c400_0000_0086, // texture/sampler handle, wait for UV
        0x0091_c500_0000_00c0,
        0x0128_40b4_17c4_2004, // TEX_SINGLE RGBA, 2D, implicit LOD
        0x0891_c800_0000_00c0, // wait for texture result
        0x4000_c000_0000_0000, // wait0126 before ATEST
        0x087d_bc02_00ea_d07c, // ATEST with alpha 1, preserves coverage
        0x787e_bc02_023c_c004, // ZS_EMIT.z depth=r4, coverage=r60, end
    };
    var fragment: [words.len * 8]u8 = undefined;
    for (words, 0..) |word, i| std.mem.writeInt(u64, fragment[i * 8 ..][0..8], word, .little);
    return create(
        session,
        .{ .code = stages[0], .register_count = 6, .preload = 0x3800 },
        .{ .code = stages[1], .register_count = 8, .preload = 0x3800, .descriptor_flags = 0 },
        .{ .code = &fragment, .register_count = 9, .preload = 0x3000 },
        .textured_color,
    );
}

/// Same depth-only export as attachment loading, taking the value from FAU u0.w0.
pub fn createDepthClear(session: *mali.Session) mali.graphics.Error!mali.NativeGraphicsPipeline {
    const pipeline = try createDepthLoad(session);
    const descriptor = pipeline.bo.cpu[@intCast(pipeline.fragment_spd_va - pipeline.bo.gpu_va)..];
    const binary = std.mem.readInt(u64, descriptor[8..16], .little);
    const code = pipeline.bo.cpu[@intCast(binary - pipeline.bo.gpu_va)..];
    const words = [_]u64{
        0x0091_c400_0000_0080, // MOV r4, FAU u0.w0 (clear depth)
        0x4000_c000_0000_0000, // wait0126 before ATEST
        0x087d_bc02_00ea_d07c, // preserve incoming coverage
        0x787e_bc02_023c_c004, // ZS_EMIT.z r4, coverage r60, end
    };
    for (words, 0..) |word, i| std.mem.writeInt(u64, code[i * 8 ..][0..8], word, .little);
    return pipeline;
}
