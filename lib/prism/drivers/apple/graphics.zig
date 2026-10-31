//! Native G13 graphics shader lowering. SPIR-V -> Vulcan scalar IR -> AGX ISA.
//! Unsupported IR is rejected before any GPU submission.
//! ISA fields follow Mesa's src/asahi/compiler/agx_pack.c and dougallj/applegpu.
const std = @import("std");
const hal = @import("../../hal.zig");
const spirv = @import("../../spirv.zig");
const ir = @import("vulcan-ir");
const gpu = @import("vulcan-gpu");
const F = ir.function;
const Function = F.Function;
const Value = F.Value;

pub const Program = struct {
    bytes: [16384]u8 = @splat(0),
    len: usize = 0,
    registers: u32 = 16, // number of 16-bit halves, including hardware preloads
    inputs: [32]u32 = @splat(0),
    input_count: u32 = 0,
    // Generic scalar slot -> packed UVS index. Position occupies UVS 0..3.
    outputs: [32]?u32 = @splat(null),
    varying_count: u32 = 0,

    fn emit(self: *Program, raw: u64, size: usize) hal.Error!void {
        if (self.len + size > self.bytes.len) return error.Unsupported;
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, raw, .little);
        @memcpy(self.bytes[self.len..][0..size], bytes[0..size]);
        self.len += size;
    }

    fn dest(reg: u32) u64 {
        return (@as(u64, reg) * 8) | 2;
    }
    fn source(reg: u32) u64 {
        const halves: u64 = @as(u64, reg) * 2;
        return (halves & 63) | 0x240 | ((halves >> 6) << 10);
    }
    pub fn mov(self: *Program, reg: u32, bits: u32) hal.Error!void {
        const d = dest(reg);
        try self.emit(0x62 | ((d & 255) << 7) | (1 << 15) | (@as(u64, bits) << 16) | ((d >> 8) << 60), 8);
    }
    fn binary(self: *Program, opcode: u8, dst: u32, a: u32, b: u32, negate: bool) hal.Error!void {
        const d = dest(dst);
        const sa = source(a);
        const sb = source(b);
        try self.emit(opcode | ((d & 255) << 7) | (1 << 15) |
            ((sa & 1023) << 16) | ((sb & 1023) << 28) |
            (@as(u64, @intFromBool(negate)) << 39) |
            ((d >> 8) << 44) | ((sa >> 10) << 42) | ((sb >> 10) << 40), 6);
    }
    fn imad(self: *Program, dst: u32, a: u32, b: u32, c: u32) hal.Error!void {
        const d = dest(dst);
        const sa = source(a);
        const sb = source(b);
        const sc = source(c);
        try self.emit(0x1e | ((d & 255) << 7) | ((sa & 1023) << 16) |
            ((sb & 1023) << 28) | ((sc & 1023) << 40) |
            ((d >> 8) << 60) | ((sa >> 10) << 58) | ((sb >> 10) << 56) | ((sc >> 10) << 54), 8);
    }
    fn fetch(self: *Program, dst: u32, offset: u32) hal.Error!void {
        // r0_r1 = buffer base, r5 = vertex index, r3 = stride in words.
        try self.mov(2, offset / 4);
        try self.imad(4, 5, 3, 2);
        const reg: u64 = @as(u64, dst) * 2;
        const offset_reg: u64 = 8; // r4 in half-register units
        try self.emit(0x05 | (2 << 7) | ((reg & 63) << 10) | ((offset_reg & 15) << 20) |
            (1 << 25) | (1 << 26) | ((offset_reg >> 4) << 32) |
            ((reg >> 6) << 40) | (4 << 44) | (1 << 47) | (1 << 49) | (1 << 52), 8);
        try self.emit(0x38, 2); // scoreboard wait before consuming the load
    }
    fn interpolate(self: *Program, dst: u32, cf: u32) hal.Error!void {
        const d = dest(dst);
        // iterproj at pixel center, cf0 supplies 1/W, one scalar channel.
        try self.emit(0x61 | ((d & 255) << 7) | (1 << 15) |
            (@as(u64, cf & 63) << 16) | ((d >> 8) << 56) | (@as(u64, cf >> 6) << 58), 8);
    }
    fn storeVarying(self: *Program, reg: u32, slot: u32, last: bool) hal.Error!void {
        const halves: u64 = @as(u64, reg) * 2;
        try self.emit(0x80000011 | (@as(u64, @intFromBool(last)) << 7) |
            ((halves & 63) << 9) | (@as(u64, slot & 63) << 16) |
            (1 << 23) | ((halves >> 6) << 24) | (@as(u64, slot >> 6) << 26), 4);
    }
    pub fn patchVertexBase(self: *Program, va: u64) void {
        // The first two long mov_imm instructions materialize the 64-bit VA.
        std.mem.writeInt(u32, self.bytes[2..6], @truncate(va), .little);
        std.mem.writeInt(u32, self.bytes[10..14], @truncate(va >> 32), .little);
    }

    pub fn coverage() Program {
        var p: Program = .{};
        for (0..4) |i| p.mov(@intCast(i), @bitCast(@as(f32, 1))) catch unreachable;
        p.emit(0x00000c48, 4) catch unreachable;
        p.emit(0x0300fcf004000109, 8) catch unreachable;
        p.emit(0x88, 2) catch unreachable;
        for (0..8) |_| p.emit(0x08, 2) catch unreachable;
        return p;
    }
};

fn attr(func: *const Function, value: Value, key: []const u8) ?u32 {
    var it = func.attributesOf(.{ .value = value });
    while (it.next()) |a| switch (a) {
        .custom => |c| {
            if (!std.mem.eql(u8, c.namespace, "vulcan.gpu") or !std.mem.eql(u8, c.key, key)) continue;
            return switch (c.value) {
                .int => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
                else => null,
            };
        },
        else => {},
    };
    return null;
}

fn index(value: Value) usize {
    return @backingInt(value);
}
fn regOf(regs: []const ?u32, value: Value) hal.Error!u32 {
    return regs[index(value)] orelse error.Unsupported;
}

pub fn compile(gpa: std.mem.Allocator, code: []const u8, stage: hal.ShaderStage, layout: hal.VertexLayout, color_format: hal.Format) hal.Error!Program {
    try validateInterface(code, stage);
    var func = spirv.parseSpirv(gpa, code) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    defer func.deinit();
    // Control flow, descriptors, textures and non-f32 types require further
    // lowering. Refuse them rather than silently treating a shader as passthrough.
    if (func.blockCount() != 1) return error.Unsupported;
    const block: F.Block = @fromBackingInt(@intCast(0));
    switch (func.terminator(block) orelse return error.Unsupported) {
        .ret => {},
        else => return error.Unsupported,
    }
    const regs = gpa.alloc(?u32, func.valueCount()) catch return error.OutOfMemory;
    defer gpa.free(regs);
    @memset(regs, null);
    var p: Program = .{};
    var next: u32 = 8;
    if (stage == .vertex) {
        if (layout.stride % 4 != 0) return error.Unsupported;
        try p.mov(0, 0);
        try p.mov(1, 0);
        try p.mov(3, layout.stride / 4);
    }
    for (func.blockParams(block)) |param| {
        if (gpu.attrs.builtinOf(&func, param)) |bi| {
            regs[index(param)] = switch (bi) {
                .vertex_index => 5,
                .instance_index => 6,
                else => return error.Unsupported,
            };
            continue;
        }
        const slot = attr(&func, param, "attr") orelse return error.Unsupported;
        if (slot < 0x80 or slot >= 0x100 or slot % 4 != 0) return error.Unsupported;
        if (next >= 128 or p.input_count == p.inputs.len) return error.Unsupported;
        switch (func.types.type_kind(func.valueType(param))) {
            .float => |f| if (f != .f32) return error.Unsupported,
            else => return error.Unsupported,
        }
        regs[index(param)] = next;
        if (stage == .vertex) {
            const loc = (slot - 0x80) / 16;
            const component = (slot % 16) / 4;
            var offset: ?u32 = null;
            for (layout.attributes) |a| if (a.location == loc) {
                const count: u32 = switch (a.format) {
                    .r32_float => 1,
                    .r32g32_float => 2,
                    .r32g32b32_float => 3,
                    .r32g32b32a32_float => 4,
                    else => return error.Unsupported,
                };
                if (a.offset % 4 != 0 or @as(u64, a.offset) + count * 4 > layout.stride) return error.InvalidArgument;
                if (component < count) offset = a.offset + component * 4;
            };
            if (offset) |o| try p.fetch(next, o) else try p.mov(next, @bitCast(@as(f32, if (component == 3) 1 else 0)));
        } else {
            p.inputs[p.input_count] = (slot - 0x80) / 4;
            p.input_count += 1;
            try p.interpolate(next, p.input_count);
        }
        next += 1;
    }
    var outputs: [36]?u32 = @splat(null);
    for (func.blockInsts(block)) |inst| {
        const op = func.opcode(inst);
        if (op == .store) {
            const s = op.store;
            if (s.mask != null or s.@"volatile") return error.Unsupported;
            switch (func.types.type_kind(func.valueType(s.value))) {
                .float => |f| if (f != .f32) return error.Unsupported,
                else => return error.Unsupported,
            }
            const slot = attr(&func, s.ptr, if (stage == .vertex) "out_attr" else "color_out") orelse return error.Unsupported;
            const out: u32 = if (stage == .vertex) blk: {
                if (slot >= 0x70 and slot < 0x80) break :blk (slot - 0x70) / 4;
                if (slot >= 0x80 and slot < 0x100) break :blk 4 + (slot - 0x80) / 4;
                return error.Unsupported;
            } else if (slot < 4) slot else return error.Unsupported;
            outputs[out] = try regOf(regs, s.value);
            continue;
        }
        const result = func.instResult(inst) orelse return error.Unsupported;
        if (attr(&func, result, "out_attr") != null or attr(&func, result, "color_out") != null) continue;
        if (next >= 127) return error.Unsupported;
        const dst = next;
        next += 1;
        regs[index(result)] = dst;
        switch (op) {
            .fconst => |f| {
                switch (func.types.type_kind(func.valueType(result))) {
                    .float => |kind| if (kind != .f32) return error.Unsupported,
                    else => return error.Unsupported,
                }
                try p.mov(dst, @bitCast(@as(f32, @floatCast(f))));
            },
            .iconst => |n| try p.mov(dst, @truncate(@as(u64, @bitCast(n)))),
            .arith => |a| {
                switch (func.types.type_kind(func.valueType(result))) {
                    .float => |f| if (f != .f32) return error.Unsupported,
                    else => return error.Unsupported,
                }
                const lhs = try regOf(regs, a.lhs);
                const rhs = try regOf(regs, a.rhs);
                switch (a.op) {
                    .add, .sub => try p.binary(0x2a, dst, lhs, rhs, a.op == .sub),
                    .mul => try p.binary(0x1a, dst, lhs, rhs, false),
                    else => return error.Unsupported,
                }
            },
            else => return error.Unsupported,
        }
    }
    if (stage == .vertex) {
        for (outputs[0..4]) |o| if (o == null) return error.Unsupported;
        for (outputs[4..], 0..) |o, i| if (o != null) {
            p.outputs[i] = 4 + p.varying_count;
            p.varying_count += 1;
        };
        var remaining: u32 = 4 + p.varying_count;
        for (outputs, 0..) |o, i| if (o) |reg| {
            remaining -= 1;
            try p.storeVarying(reg, if (i < 4) @intCast(i) else p.outputs[i - 4].?, remaining == 0);
        };
    } else {
        // Gather color in r0..r3, away from all allocated SSA registers.
        try p.mov(4, 0);
        for (0..4) |i| {
            const channel = if (color_format == .bgra8_unorm and (i == 0 or i == 2)) 2 - i else i;
            try p.binary(0x2a, @intCast(i), outputs[channel] orelse return error.Unsupported, 4, false);
        }
        try p.emit(0x00000c48, 4); // wait_pix 12
        try p.emit(0x0300fcf004000109, 8); // st_tile r0_r1_r2_r3, u8norm, RGBA, all samples
    }
    try p.emit(0x88, 2);
    // Trap footer as emitted by the AGX compiler.
    for (0..8) |_| try p.emit(0x08, 2);
    p.registers = next * 2;
    return p;
}

fn validateInterface(code: []const u8, stage: hal.ShaderStage) hal.Error!void {
    const op = spirv.opcodes;
    if (code.len < 20 or code.len % 4 != 0 or std.mem.readInt(u32, code[0..4], .little) != 0x07230203)
        return error.InvalidArgument;
    var offset: usize = 20;
    var entries: u32 = 0;
    while (offset < code.len) {
        const header = std.mem.readInt(u32, code[offset..][0..4], .little);
        const bytes = @as(usize, header >> 16) * 4;
        if (bytes == 0 or bytes > code.len - offset) return error.InvalidArgument;
        const instruction = code[offset..][0..bytes];
        const opcode = header & 0xffff;
        if (opcode == op.EntryPoint) {
            if (bytes < 16) return error.InvalidArgument;
            const model = std.mem.readInt(u32, instruction[4..8], .little);
            if (model != @as(u32, if (stage == .vertex) 0 else 4)) return error.Unsupported;
            entries += 1;
        } else if (opcode == op.Decorate or opcode == op.MemberDecorate) {
            const position: usize = if (opcode == op.Decorate) 8 else 12;
            if (bytes < position + 4) return error.InvalidArgument;
            const decoration = std.mem.readInt(u32, instruction[position..][0..4], .little);
            // The shared IR currently does not retain interpolation qualifiers.
            // Reject NoPerspective/Flat/Patch/Centroid/Sample before lowering.
            if (decoration >= 13 and decoration <= 17) return error.Unsupported;
        } else if (opcode == op.ExecutionMode) {
            if (bytes < 12) return error.InvalidArgument;
            if (std.mem.readInt(u32, instruction[8..12], .little) != 7) return error.Unsupported;
        }
        offset += bytes;
    }
    if (entries != 1) return error.Unsupported;
}
