//! CPU sampler ABI adaptation before Vulcan's target-independent lowering.
const std = @import("std");
const spirv = @import("vulcan-spirv");
const front = @import("../../spirv.zig");
const sampler = @import("sampler.zig");

/// Preserve implicit samples as host-sampler requests. Vulcan's default implicit
/// LOD lowering assumes float texture dimensions at descriptor offsets 16/20;
/// Prism's TexDesc has its own layout and the rasterizer supplies a fractional
/// implicit LOD. Expressing the sampler's sentinel as an explicit LOD operand
/// avoids injecting that target-specific descriptor math and derivative slots.
/// Explicit LODs in the caller's module are kept verbatim.
pub fn parse(gpa: std.mem.Allocator, code: []const u8) !front.Function {
    if (code.len == 0 or code.len % 4 != 0) return error.InvalidSpirv;
    const words = try gpa.alloc(u32, code.len / 4);
    defer gpa.free(words);
    @memcpy(std.mem.sliceAsBytes(words), code);
    var reader = try spirv.binary.Reader.init(words);
    const op = spirv.opcodes;
    var float_type: ?u32 = null;
    var implicit = false;
    while (try reader.next()) |inst| {
        if (inst.opcode == op.TypeFloat and inst.operands.len == 2 and inst.operands[1] == 32)
            float_type = inst.operands[0];
        if (inst.opcode == op.ImageSampleImplicitLod) implicit = true;
    }
    if (!implicit) return front.parseSpirv(gpa, code);
    const f32_id = float_type orelse return error.InvalidSpirv;
    const lod_id = reader.header.id_bound;
    if (lod_id == std.math.maxInt(u32)) return error.InvalidSpirv;
    var out = try spirv.binary.Builder.init(gpa, lod_id + 1);
    defer out.deinit(gpa);
    @memcpy(out.words.items[0..5], words[0..5]);
    out.words.items[3] = lod_id + 1;
    reader.pos = 5;
    var declared = false;
    while (try reader.next()) |inst| {
        if (!declared and inst.opcode == op.Function) {
            try out.emit(gpa, op.Constant, &.{ f32_id, lod_id, @bitCast(sampler.IMPLICIT_LOD_SENTINEL) });
            declared = true;
        }
        if (inst.opcode != op.ImageSampleImplicitLod) {
            try out.emit(gpa, inst.opcode, inst.operands);
            continue;
        }
        if (inst.operands.len < 4) return error.InvalidSpirv;
        const mask = if (inst.operands.len > 4) inst.operands[4] else 0;
        // Bias would precede Lod in the image operands and needs a separate host
        // ABI to combine it with the rasterizer LOD. Do not misread it as Lod.
        if (mask & 1 != 0) return error.Unsupported;
        const extra = if (inst.operands.len > 4) inst.operands[5..] else &.{};
        if (extra.len > std.math.maxInt(u16) - 7) return error.InvalidSpirv;
        const args = try gpa.alloc(u32, 6 + extra.len);
        defer gpa.free(args);
        @memcpy(args[0..4], inst.operands[0..4]);
        args[4] = mask | 2; // ImageOperands.Lod
        args[5] = lod_id;
        @memcpy(args[6..], extra);
        try out.emit(gpa, op.ImageSampleExplicitLod, args);
    }
    if (!declared) return error.InvalidSpirv;
    return front.parseSpirv(gpa, std.mem.sliceAsBytes(out.words.items));
}
