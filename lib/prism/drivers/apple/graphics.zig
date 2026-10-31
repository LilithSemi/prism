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
    texture_mask: u8 = 0,
    uniform_patches: [256]struct { offset: u32, binding: u32, byte_offset: u32 } = undefined,
    uniform_patch_count: u32 = 0,

    pub fn patchUniforms(self: *Program, bases: []const u64) hal.Error!void {
        for (self.uniform_patches[0..self.uniform_patch_count]) |patch| {
            if (patch.binding >= bases.len or bases[patch.binding] == 0) return error.InvalidArgument;
            const va = bases[patch.binding];
            std.mem.writeInt(u32, self.bytes[patch.offset + 2 ..][0..4], @truncate(va), .little);
            std.mem.writeInt(u32, self.bytes[patch.offset + 10 ..][0..4], @truncate(va >> 32), .little);
        }
    }

    fn uniformLoad(self: *Program, dst: u32, binding: u32, byte_offset: u32, dynamic: ?u32) hal.Error!void {
        if (byte_offset % 4 != 0 or self.uniform_patch_count == self.uniform_patches.len) return error.Unsupported;
        self.uniform_patches[self.uniform_patch_count] = .{ .offset = @intCast(self.len), .binding = binding, .byte_offset = byte_offset };
        self.uniform_patch_count += 1;
        try self.mov(0, 0);
        try self.mov(1, 0);
        if (dynamic) |offset| {
            try self.shiftRight(4, offset, 2);
            if (byte_offset != 0) {
                try self.mov(2, byte_offset / 4);
                try self.mov(3, 1);
                try self.imad(4, 4, 3, 2);
            }
        } else try self.mov(4, byte_offset / 4);
        const reg: u64 = @as(u64, dst) * 2;
        try self.emit(0x05 | (2 << 7) | ((reg & 63) << 10) | (8 << 20) |
            (1 << 25) | (1 << 26) | ((reg >> 6) << 40) |
            (4 << 44) | (1 << 47) | (1 << 49) | (1 << 52), 8);
        try self.emit(0x38, 2);
    }

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
    fn unary(self: *Program, opcode: u32, dst: u32, src: u32) hal.Error!void {
        const d = dest(dst);
        const s = source(src);
        try self.emit(0x0a | (@as(u64, opcode) << 28) | ((d & 255) << 7) |
            (1 << 15) | ((s & 1023) << 16) | ((d >> 8) << 44) | ((s >> 10) << 42), 6);
    }
    fn floatToHalf(self: *Program, dst: u32, src: u32) hal.Error!void {
        // FADD with a 16-bit destination rounds to binary16. Texture LODs use
        // a half register even when the shader's scalar arithmetic is f32.
        const d: u64 = @as(u64, dst) * 8;
        const a = source(src);
        const b = source(4);
        try self.emit(0x2a | ((d & 255) << 7) | (1 << 15) |
            ((a & 1023) << 16) | ((b & 1023) << 28) |
            ((d >> 8) << 44) | ((a >> 10) << 42) | ((b >> 10) << 40), 6);
    }
    fn convert(self: *Program, dst: u32, src: u32, operation: u32, half: bool) hal.Error!void {
        const d = dest(dst);
        const s = if (half) (@as(u64, src) * 2 & 63) | 0x40 | ((@as(u64, src) * 2 >> 6) << 10) else source(src);
        try self.emit(0x803e | ((d & 255) << 7) | (@as(u64, operation) << 16) |
            (if (operation == 6 or operation == 7 or operation == 10 or operation == 11) @as(u64, 1 << 26) else 0) |
            ((s & 1023) << 28) | ((d >> 8) << 44) | ((s >> 10) << 40), 6);
    }
    fn fragmentCoordinate(self: *Program, dst: u32, component: u32) hal.Error!void {
        const sr: u64 = 80 + component;
        // Pixel coordinates are unsigned 16-bit integers in sr80/sr81.
        try self.emit(0x72 | (34 << 7) | ((sr & 63) << 16) | ((sr >> 6) << 26), 4);
        try self.convert(dst, 4, 10, false);
        try self.mov(4, @bitCast(@as(f32, 0.5)));
        try self.binary(0x2a, dst, dst, 4, false);
    }
    fn cmpsel(self: *Program, float: bool, condition: u32, dst: u32, a: u32, b: u32, yes: u32, no: u32) hal.Error!void {
        const d = dest(dst);
        const sources = [_]u64{ source(a), source(b), ((@as(u64, yes) * 2) & 63) | 0x40 | (((@as(u64, yes) * 2) >> 6) << 10), ((@as(u64, no) * 2) & 63) | 0x40 | (((@as(u64, no) * 2) >> 6) << 10) };
        var raw: u64 = @as(u64, if (float) @as(u32, 0x02) else 0x12) | ((d & 255) << 7) | (1 << 15) | (@as(u64, condition) << 61);
        var extend: u64 = (d >> 8) << 12;
        for (sources, 0..) |s, i| {
            raw |= (s & 1023) << @intCast(16 + i * 12);
            extend |= (s >> 10) << @intCast(10 - i * 2);
        }
        try self.emit(raw, 8);
        try self.emit(extend, 2);
    }
    fn shiftRight(self: *Program, dst: u32, src: u32, shift: u32) hal.Error!void {
        try self.mov(2, shift);
        const d = dest(dst);
        const a = source(src);
        const b = source(2);
        try self.emit(0x0400802e | ((d & 255) << 7) | ((a & 1023) << 16) |
            ((b & 1023) << 28) | ((d >> 8) << 60) | ((a >> 10) << 58) | ((b >> 10) << 56), 8);
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
    fn blendFactor(self: *Program, dst: u32, factor: hal.BlendFactor, channel: u32, constant: [4]f32, format: hal.Format) hal.Error!void {
        const logical = if (format == .bgra8_unorm and (channel == 0 or channel == 2)) 2 - channel else channel;
        switch (factor) {
            .zero => try self.mov(dst, 0),
            .one => try self.mov(dst, @bitCast(@as(f32, 1))),
            .constant_color, .one_minus_constant_color => try self.mov(dst, @bitCast(if (factor == .constant_color) constant[logical] else 1 - constant[logical])),
            .constant_alpha, .one_minus_constant_alpha => try self.mov(dst, @bitCast(if (factor == .constant_alpha) constant[3] else 1 - constant[3])),
            .src_alpha_saturate => {
                if (channel == 3) return self.mov(dst, @bitCast(@as(f32, 1)));
                try self.mov(15, @bitCast(@as(f32, 1)));
                try self.binary(0x2a, 14, 15, 7, true);
                try self.cmpsel(true, 1, dst, 3, 14, 3, 14);
            },
            else => {
                const reg: u32 = switch (factor) {
                    .src_color, .one_minus_src_color => channel,
                    .src_alpha, .one_minus_src_alpha => 3,
                    .dst_color, .one_minus_dst_color => channel + 4,
                    .dst_alpha, .one_minus_dst_alpha => 7,
                    else => unreachable,
                };
                const inverse = factor == .one_minus_src_color or factor == .one_minus_src_alpha or factor == .one_minus_dst_color or factor == .one_minus_dst_alpha;
                try self.mov(15, @bitCast(@as(f32, if (inverse) 1 else 0)));
                if (inverse) try self.binary(0x2a, dst, 15, reg, true) else try self.binary(0x2a, dst, reg, 15, false);
            },
        }
    }

    fn blendColor(self: *Program, state: hal.BlendState, format: hal.Format) hal.Error!void {
        // Read the on-chip destination only after earlier fragments finish.
        try self.emit(0x00000c48, 4);
        const d = dest(4);
        try self.emit(0x49 | (((d >> 1) & 127) << 8) | (4 << 24) | (1 << 35) |
            (15 << 36) | (63 << 42) | (3 << 56) | ((d >> 8) << 60), 8);
        for (0..4) |index_| {
            const c: u32 = @intCast(index_);
            const logical = if (format == .bgra8_unorm and (c == 0 or c == 2)) 2 - c else c;
            if (!state.write_mask[logical]) {
                try self.mov(15, 0);
                try self.binary(0x2a, c + 8, c + 4, 15, false);
                continue;
            }
            if (!state.enable) {
                try self.mov(15, 0);
                try self.binary(0x2a, c + 8, c, 15, false);
                continue;
            }
            const equation = if (c == 3) state.alpha_op else state.color_op;
            if (equation == .min or equation == .max) {
                try self.cmpsel(true, if (equation == .min) 1 else 2, c + 8, c, c + 4, c, c + 4);
            } else {
                try self.blendFactor(12, if (c == 3) state.src_alpha else state.src_color, c, state.constant, format);
                try self.blendFactor(13, if (c == 3) state.dst_alpha else state.dst_color, c, state.constant, format);
                try self.binary(0x1a, 12, c, 12, false);
                try self.binary(0x1a, 13, c + 4, 13, false);
                if (equation == .reverse_subtract) try self.binary(0x2a, c + 8, 13, 12, true) else try self.binary(0x2a, c + 8, 12, 13, equation == .subtract);
            }
        }
        try self.mov(15, 0);
        for (0..4) |c| try self.binary(0x2a, @intCast(c), @intCast(c + 8), 15, false);
    }
    pub fn patchVertexBase(self: *Program, va: u64) void {
        // The first two long mov_imm instructions materialize the 64-bit VA.
        std.mem.writeInt(u32, self.bytes[2..6], @truncate(va), .little);
        std.mem.writeInt(u32, self.bytes[10..14], @truncate(va >> 32), .little);
    }

    pub fn backgroundLoad() Program {
        var p: Program = .{};
        // Pixel coordinates are packed as two u16 values for a non-MSAA txf.
        p.mov(4, 0) catch unreachable;
        for ([_]u32{ 80, 81 }, 0..) |sr, component| {
            const half: u64 = 8 + component;
            const d = half << 2;
            p.emit(0x72 | ((d & 255) << 7) | (@as(u64, sr & 63) << 16) | (@as(u64, sr >> 6) << 26), 4) catch unreachable;
        }
        // texture_load r0..r3, packed coords r4, texture 0, reserved txf sampler.
        p.emit(0x71 | (1 << 8) | (8 << 16) | (2 << 40) | (12 << 43) | (1 << 47) | (15 << 48), 8) catch unreachable;
        p.emit(0x38, 2) catch unreachable;
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

const Pointer = struct {
    kind: enum { uniform, sampler, local, gradient } = .uniform,
    binding: u32,
    offset: u32 = 0,
    local_reg: u32 = 0,
    dynamic: ?u32 = null,
};

fn tagged(func: *const Function, value: Value, key: []const u8) bool {
    var it = func.attributesOf(.{ .value = value });
    while (it.next()) |a| switch (a) {
        .custom => |c| if (std.mem.eql(u8, c.namespace, "vulcan.gpu") and std.mem.eql(u8, c.key, key)) return true,
        else => {},
    };
    return false;
}

fn markUses(func: *const Function, value: anytype, last: []usize, position: usize) void {
    const T = @TypeOf(value);
    if (T == Value) {
        last[index(value)] = position;
    } else if (T == F.ValueList) {
        for (func.valueList(value)) |v| last[index(v)] = position;
    } else switch (@typeInfo(T)) {
        .@"struct" => inline for (@typeInfo(T).@"struct".field_names) |name| markUses(func, @field(value, name), last, position),
        .@"union" => switch (value) {
            inline else => |payload| markUses(func, payload, last, position),
        },
        .optional => if (value) |v| {
            markUses(func, v, last, position);
        },
        else => {},
    }
}

fn allocateReg(used: *[128]bool, high: *u32) hal.Error!u32 {
    for (8..128) |r| if (!used[r]) {
        used[r] = true;
        high.* = @max(high.*, @as(u32, @intCast(r + 1)));
        return @intCast(r);
    };
    return error.Unsupported;
}

pub fn compile(gpa: std.mem.Allocator, code: []const u8, stage: hal.ShaderStage, layout: hal.VertexLayout, color_format: hal.Format) hal.Error!Program {
    return compileWithBlend(gpa, code, stage, layout, color_format, .{});
}

pub fn compileWithBlend(gpa: std.mem.Allocator, code: []const u8, stage: hal.ShaderStage, layout: hal.VertexLayout, color_format: hal.Format, blend: hal.BlendState) hal.Error!Program {
    try validateInterface(code, stage);
    var func = @import("spirv_sampling.zig").parse(gpa, code) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    defer func.deinit();
    @import("flatten.zig").run(&func) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    const block: F.Block = @fromBackingInt(@intCast(0));
    switch (func.terminator(block) orelse return error.Unsupported) {
        .ret => {},
        else => return error.Unsupported,
    }
    const regs = gpa.alloc(?u32, func.valueCount()) catch return error.OutOfMemory;
    defer gpa.free(regs);
    @memset(regs, null);
    var p: Program = .{};
    const pointers = gpa.alloc(?Pointer, func.valueCount()) catch return error.OutOfMemory;
    defer gpa.free(pointers);
    @memset(pointers, null);
    const constants = gpa.alloc(?u32, func.valueCount()) catch return error.OutOfMemory;
    defer gpa.free(constants);
    @memset(constants, null);
    const last = gpa.alloc(usize, func.valueCount()) catch return error.OutOfMemory;
    defer gpa.free(last);
    @memset(last, 0);
    const insts = func.blockInsts(block);
    var gradients: [64]u32 = undefined;
    var gradient_count: usize = 0;
    var attrs = func.attributesOf(.func);
    while (attrs.next()) |attribute| switch (attribute) {
        .custom => |a| if (std.mem.eql(u8, a.namespace, "vulcan.gpu") and std.mem.eql(u8, a.key, "grad_slot")) {
            if (gradient_count == gradients.len) return error.Unsupported;
            gradients[gradient_count] = switch (a.value) {
                .int => |n| @intCast(n),
                else => return error.Unsupported,
            };
            gradient_count += 1;
        },
        else => {},
    };
    for (insts, 0..) |inst, i| markUses(&func, func.opcode(inst), last, i + 1);
    // Output stores are emitted together at the end of the shader.
    for (insts) |inst| switch (func.opcode(inst)) {
        .store => |st| last[index(st.value)] = insts.len + 1,
        else => {},
    };
    for (func.blockParams(block)) |param| if (attr(&func, param, "attr")) |slot| {
        for (gradients[0..gradient_count]) |g| if (g >> 1 == slot) {
            last[index(param)] = insts.len + 1;
        };
    };
    var used: [128]bool = @splat(false);
    var high: u32 = 8;
    if (stage == .vertex) {
        if (layout.stride % 4 != 0) return error.Unsupported;
        try p.mov(0, 0);
        try p.mov(1, 0);
        try p.mov(3, layout.stride / 4);
    }
    for (func.blockParams(block)) |param| {
        if (last[index(param)] == 0) continue;
        if (gpu.attrs.builtinOf(&func, param)) |bi| {
            if (bi == .frag_coord) {
                const component = attr(&func, param, "bicomp") orelse 0;
                if (stage != .fragment or component > 1) return error.Unsupported;
                const dst = try allocateReg(&used, &high);
                regs[index(param)] = dst;
                try p.fragmentCoordinate(dst, component);
                continue;
            }
            regs[index(param)] = switch (bi) {
                .vertex_index => 5,
                .instance_index => 6,
                else => return error.Unsupported,
            };
            continue;
        }
        if (func.types.type_kind(func.valueType(param)) == .ptr) {
            if (tagged(&func, param, "sampler_fn") or tagged(&func, param, "math_fn")) continue;
            if (tagged(&func, param, "grad_buf")) {
                pointers[index(param)] = .{ .binding = 0, .kind = .gradient };
                continue;
            }
            const binding = attr(&func, param, "binding") orelse return error.Unsupported;
            if (binding >= 8) return error.Unsupported;
            pointers[index(param)] = .{ .binding = binding, .kind = if (tagged(&func, param, "sampler_desc")) .sampler else .uniform };
            continue;
        }
        const slot = attr(&func, param, "attr") orelse return error.Unsupported;
        if (slot < 0x80 or slot >= 0x100 or slot % 4 != 0) return error.Unsupported;
        if (p.input_count == p.inputs.len) return error.Unsupported;
        const next = try allocateReg(&used, &high);
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
    }
    var outputs: [36]?u32 = @splat(null);
    for (insts, 0..) |inst, position| {
        for (regs, 0..) |r, v| if (r) |physical| {
            if (physical >= 8 and last[v] < position + 1) {
                used[physical] = false;
                regs[v] = null;
            }
        };
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
        if (op == .call_indirect) {
            const call = op.call_indirect;
            if (tagged(&func, call.target, "math_fn")) {
                const args = func.valueList(call.args);
                if (args.len != 3) return error.Unsupported;
                const operation = constants[index(args[0])] orelse return error.Unsupported;
                const result = func.instResult(inst) orelse return error.Unsupported;
                const dst = try allocateReg(&used, &high);
                regs[index(result)] = dst;
                const a = try regOf(regs, args[1]);
                const b = try regOf(regs, args[2]);
                switch (operation) {
                    0 => {
                        try p.unary(12, 2, a);
                        try p.binary(0x1a, 2, 2, b, false);
                        try p.unary(13, dst, 2);
                    },
                    1 => {
                        try p.mov(4, @bitCast(@as(f32, 1.4426950408889634)));
                        try p.binary(0x1a, 2, a, 4, false);
                        try p.unary(13, dst, 2);
                    },
                    2 => {
                        try p.unary(12, 2, a);
                        try p.mov(4, @bitCast(@as(f32, 0.6931471805599453)));
                        try p.binary(0x1a, dst, 2, 4, false);
                    },
                    3 => try p.unary(13, dst, a),
                    4 => try p.unary(12, dst, a),
                    5, 6 => {
                        try p.mov(4, @bitCast(@as(f32, 0.15915494309189535)));
                        try p.binary(0x1a, 2, a, 4, false);
                        if (operation == 6) {
                            try p.mov(4, @bitCast(@as(f32, 0.25)));
                            try p.binary(0x2a, 2, 2, 4, false);
                        }
                        try p.unary(0, 3, 2);
                        try p.binary(0x2a, 2, 2, 3, true);
                        try p.mov(4, @bitCast(@as(f32, 4)));
                        try p.binary(0x1a, 2, 2, 4, false);
                        try p.unary(10, 3, 2);
                        try p.unary(14, 2, 3);
                        try p.binary(0x1a, dst, 2, 3, false);
                    },
                    else => return error.Unsupported,
                }
                continue;
            }
            if (!tagged(&func, call.target, "sampler_fn") or stage != .fragment) return error.Unsupported;
            const args = func.valueList(call.args);
            if (args.len != 5) return error.Unsupported;
            const descriptor = pointers[index(args[0])] orelse return error.Unsupported;
            const out = pointers[index(args[4])] orelse return error.Unsupported;
            if (descriptor.kind != .sampler or out.kind != .local) return error.Unsupported;
            const u = try regOf(regs, args[1]);
            const v = try regOf(regs, args[2]);
            const lod = try regOf(regs, args[3]);
            const definition = func.definingInst(args[3]);
            const automatic = if (definition) |def| switch (func.opcode(def)) {
                .fconst => |f| f < -1.0e20,
                else => false,
            } else false;
            try p.mov(4, 0);
            try p.binary(0x2a, 0, u, 4, false);
            try p.binary(0x2a, 1, v, 4, false);
            if (!automatic) {
                const constant: ?f64 = if (definition) |def| switch (func.opcode(def)) {
                    .fconst => |f| f,
                    else => null,
                } else null;
                if (constant) |f| try p.mov(2, @as(u16, @bitCast(@as(f16, @floatCast(f))))) else try p.floatToHalf(2, lod);
            }
            const R: u64 = out.local_reg * 2;
            const D: u64 = if (automatic) 0 else 4;
            const extend: u32 = @intCast(((R >> 6) << 8) | ((D >> 6) << 12));
            const raw = @as(u64, 0x31) | (1 << 8) | ((R & 63) << 9) |
                (@as(u64, @intFromBool(extend != 0)) << 15) | ((D & 63) << 24) |
                (@as(u64, descriptor.binding) << 32) | (2 << 40) | (12 << 43) |
                (15 << 48) | (@as(u64, if (automatic) @as(u32, 0) else 6) << 52) |
                (@as(u64, descriptor.binding + 1) << 56);
            try p.emit(raw, 8);
            if (extend != 0) try p.emit(extend, 4);
            try p.emit(0x38, 2);
            p.texture_mask |= @as(u8, 1) << @intCast(descriptor.binding);
            continue;
        }
        const result = func.instResult(inst) orelse return error.Unsupported;
        if (attr(&func, result, "out_attr") != null or attr(&func, result, "color_out") != null) continue;
        if (func.types.type_kind(func.valueType(result)) == .ptr) {
            const pointer = switch (op) {
                .alloca => blk: {
                    // Texture result vectors stay resident in four consecutive
                    // registers until their scalar loads have been emitted.
                    var base: ?u32 = null;
                    for (8..125) |r| {
                        if (!used[r] and !used[r + 1] and !used[r + 2] and !used[r + 3]) {
                            base = @intCast(r);
                            for (r..r + 4) |j| used[j] = true;
                            high = @max(high, @as(u32, @intCast(r + 4)));
                            break;
                        }
                    }
                    break :blk Pointer{ .kind = .local, .binding = 0, .local_reg = base orelse return error.Unsupported };
                },
                .arith => |a| blk: {
                    if (a.op != .add) return error.Unsupported;
                    const base = pointers[index(a.lhs)] orelse return error.Unsupported;
                    var ptr = base;
                    if (constants[index(a.rhs)]) |offset| {
                        ptr.offset = std.math.add(u32, base.offset, offset) catch return error.Unsupported;
                    } else {
                        if (base.kind != .uniform) return error.Unsupported;
                        const rhs = try regOf(regs, a.rhs);
                        const dst = try allocateReg(&used, &high);
                        try p.mov(2, 1);
                        try p.mov(4, 0);
                        try p.imad(dst, rhs, 2, base.dynamic orelse 4);
                        ptr.dynamic = dst;
                        regs[index(result)] = dst;
                    }
                    if (base.dynamic != null and ptr.dynamic == base.dynamic) {
                        const dst = try allocateReg(&used, &high);
                        try p.mov(2, 1);
                        try p.mov(4, 0);
                        try p.imad(dst, base.dynamic.?, 2, 4);
                        ptr.dynamic = dst;
                        regs[index(result)] = dst;
                    }
                    break :blk ptr;
                },
                .arith_imm => |a| blk: {
                    if (a.op != .add or a.imm < 0 or a.imm > std.math.maxInt(u32)) return error.Unsupported;
                    const base = pointers[index(a.lhs)] orelse return error.Unsupported;
                    var ptr = base;
                    ptr.offset = std.math.add(u32, base.offset, @intCast(a.imm)) catch return error.Unsupported;
                    if (base.dynamic) |offset| {
                        const dst = try allocateReg(&used, &high);
                        try p.mov(2, 1);
                        try p.mov(4, 0);
                        try p.imad(dst, offset, 2, 4);
                        ptr.dynamic = dst;
                        regs[index(result)] = dst;
                    }
                    break :blk ptr;
                },
                else => return error.Unsupported,
            };
            pointers[index(result)] = pointer;
            continue;
        }
        const dst = try allocateReg(&used, &high);
        regs[index(result)] = dst;
        switch (op) {
            .fconst => |f| {
                switch (func.types.type_kind(func.valueType(result))) {
                    .float => |kind| if (kind != .f32) return error.Unsupported,
                    else => return error.Unsupported,
                }
                try p.mov(dst, @bitCast(@as(f32, @floatCast(f))));
            },
            .iconst => |n| {
                constants[index(result)] = @truncate(@as(u64, @bitCast(n)));
                try p.mov(dst, constants[index(result)].?);
            },
            .load => |load| {
                if (load.mask != null or load.@"volatile") return error.Unsupported;
                const pointer = pointers[index(load.ptr)] orelse return error.Unsupported;
                switch (pointer.kind) {
                    .uniform => try p.uniformLoad(dst, pointer.binding, pointer.offset, pointer.dynamic),
                    .local => {
                        if (pointer.offset >= 16 or pointer.offset % 4 != 0) return error.Unsupported;
                        try p.mov(4, 0);
                        try p.binary(0x2a, dst, pointer.local_reg + pointer.offset / 4, 4, false);
                    },
                    .sampler => return error.Unsupported,
                    .gradient => {
                        if (pointer.offset % 4 != 0 or pointer.offset / 4 >= gradient_count) return error.Unsupported;
                        const gradient = gradients[pointer.offset / 4];
                        var input: ?u32 = null;
                        for (func.blockParams(block)) |param| if (attr(&func, param, "attr") == gradient >> 1) {
                            input = try regOf(regs, param);
                        };
                        try p.unary(if (gradient & 1 == 0) 4 else 6, dst, input orelse return error.Unsupported);
                    },
                }
            },
            .unary => |u| {
                const src = try regOf(regs, u.value);
                switch (u.op) {
                    .reinterpret => {
                        try p.mov(2, 1);
                        try p.mov(4, 0);
                        try p.imad(dst, src, 2, 4);
                    },
                    .sqrt => {
                        try p.unary(9, 2, src);
                        try p.binary(0x1a, dst, src, 2, false);
                        try p.mov(4, 0);
                        try p.cmpsel(true, 0, dst, src, 4, 4, dst);
                    },
                    .floor => try p.unary(0, dst, src),
                    .ceil => try p.unary(16, dst, src),
                    .trunc => try p.unary(32, dst, src),
                    .nearest => try p.unary(48, dst, src),
                }
            },
            .convert => |c| {
                const src = try regOf(regs, c.value);
                const from = func.types.type_kind(func.valueType(c.value));
                const to = func.types.type_kind(func.valueType(result));
                if (from == .float and to == .int and to.int.bits == 32) {
                    try p.convert(dst, src, if (to.int.signedness == .signed) 9 else 8, false);
                } else if (from == .int and from.int.bits == 32 and to == .float) {
                    try p.convert(dst, src, if (from.int.signedness == .signed) 11 else 10, false);
                } else if (from == .int and to == .int and from.int.bits == 32 and to.int.bits == 32) {
                    try p.mov(2, 1);
                    try p.mov(4, 0);
                    try p.imad(dst, src, 2, 4);
                } else return error.Unsupported;
            },
            .icmp => |c| {
                const a = try regOf(regs, c.lhs);
                const b = try regOf(regs, c.rhs);
                try p.mov(2, 1);
                try p.mov(4, 0);
                const float = func.types.type_kind(func.valueType(c.lhs)) == .float;
                var inverted = c.op == .ne;
                const condition: u32 = if (float) switch (c.op) {
                    .eq, .ne => 0,
                    .lt => 1,
                    .gt => 2,
                    .ge => 5,
                    .le => 6,
                } else blk: {
                    const signed = switch (func.types.type_kind(func.valueType(c.lhs))) {
                        .int => |i| i.signedness == .signed,
                        else => false,
                    };
                    const base: u32 = switch (c.op) {
                        .eq, .ne => 0,
                        .lt, .ge => 1,
                        .gt, .le => 2,
                    };
                    inverted = c.op == .ne or c.op == .ge or c.op == .le;
                    break :blk base + if (signed) @as(u32, 4) else 0;
                };
                try p.cmpsel(float, condition, dst, a, b, if (inverted) 4 else 2, if (inverted) 2 else 4);
            },
            .select => |s| {
                const condition = try regOf(regs, s.cond);
                const yes = try regOf(regs, s.then);
                const no = try regOf(regs, s.@"else");
                try p.mov(4, 0);
                try p.cmpsel(false, 0, dst, condition, 4, no, yes);
            },
            .arith => |a| {
                if (func.types.type_kind(func.valueType(result)) == .int) {
                    const lhs = try regOf(regs, a.lhs);
                    const rhs = try regOf(regs, a.rhs);
                    try p.mov(2, 1);
                    try p.mov(4, 0);
                    switch (a.op) {
                        .add => try p.imad(dst, lhs, 2, rhs),
                        .mul => try p.imad(dst, lhs, rhs, 4),
                        .sub => {
                            try p.mov(2, 0xffffffff);
                            try p.imad(dst, rhs, 2, lhs);
                        },
                        .shl => {
                            const shift = constants[index(a.rhs)] orelse return error.Unsupported;
                            if (shift >= 32) return error.Unsupported;
                            try p.mov(2, @as(u32, 1) << @intCast(shift));
                            try p.imad(dst, lhs, 2, 4);
                        },
                        .shr => try p.shiftRight(dst, lhs, constants[index(a.rhs)] orelse return error.Unsupported),
                        else => return error.Unsupported,
                    }
                    if (constants[index(a.lhs)]) |left| if (constants[index(a.rhs)]) |right| {
                        constants[index(result)] = switch (a.op) {
                            .add => left +% right,
                            .sub => left -% right,
                            .mul => left *% right,
                            else => null,
                        };
                    };
                    continue;
                }
                switch (func.types.type_kind(func.valueType(result))) {
                    .float => |f| if (f != .f32) return error.Unsupported,
                    else => return error.Unsupported,
                }
                const lhs = try regOf(regs, a.lhs);
                const rhs = try regOf(regs, a.rhs);
                switch (a.op) {
                    .add, .sub => try p.binary(0x2a, dst, lhs, rhs, a.op == .sub),
                    .mul => try p.binary(0x1a, dst, lhs, rhs, false),
                    .div => {
                        try p.unary(8, 2, rhs);
                        try p.binary(0x1a, dst, lhs, 2, false);
                    },
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
        if (blend.enable or !std.mem.eql(bool, &blend.write_mask, &.{ true, true, true, true })) {
            try p.blendColor(blend, color_format);
            high = @max(high, 16);
        }
        try p.emit(0x00000c48, 4); // wait_pix 12
        try p.emit(0x0300fcf004000109, 8);
    }
    try p.emit(0x88, 2);
    // Trap footer as emitted by the AGX compiler.
    for (0..8) |_| try p.emit(0x08, 2);
    p.registers = high * 2;
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
