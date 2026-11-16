//! Scalar, straight-line GLSL vertex arithmetic lowered to native Valhall.
//! The driver FAU header occupies words 0..17; binding 0 starts at word 18.
const std = @import("std");
const ir = @import("vulcan-ir");
const F = ir.function;
const hal = @import("../../hal.zig");
const Value = F.Value;
const Function = F.Function;
const Error = error{ Unsupported, OutOfMemory };

pub const Program = struct {
    code: []u8,
    uniform_bytes: usize,
    attributes: u16,
    varying_code: ?[]u8 = null,
    varying_mask: u32 = 0,
    varying_size: u32 = 0,

    pub fn deinit(self: Program, gpa: std.mem.Allocator) void {
        gpa.free(self.code);
        if (self.varying_code) |code| gpa.free(code);
    }
};
const Scalar = union(enum) { unknown, integer: i64, float: u32, fau: u8, pointer: usize, register: u6 };

pub fn compile(gpa: std.mem.Allocator, spirv: []const u8) Error!Program {
    return compileWithMask(gpa, spirv, std.math.maxInt(u32));
}

pub fn compileWithMask(gpa: std.mem.Allocator, spirv: []const u8, varying_mask: u32) Error!Program {
    var func = @import("../apple/spirv_sampling.zig").parse(gpa, spirv) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    defer func.deinit();
    @import("../apple/flatten.zig").run(&func) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    const block: F.Block = @fromBackingInt(0);
    switch (func.terminator(block) orelse return error.Unsupported) {
        .ret => {},
        else => return error.Unsupported,
    }
    const values = try gpa.alloc(Scalar, func.valueCount());
    defer gpa.free(values);
    @memset(values, .unknown);
    const last_use = try gpa.alloc(usize, func.valueCount());
    defer gpa.free(last_use);
    @memset(last_use, 0);
    const live = try gpa.alloc(bool, func.valueCount());
    defer gpa.free(live);
    @memset(live, false);
    const insts = func.blockInsts(block);
    var reverse = insts.len;
    while (reverse != 0) {
        reverse -= 1;
        const inst = insts[reverse];
        const op = func.opcode(inst);
        if (op == .store) {
            const slot = attr(&func, op.store.ptr, "out_attr") orelse return error.Unsupported;
            if (!selectedOutput(slot, varying_mask)) continue;
            live[idx(op.store.value)] = true;
            last_use[idx(op.store.value)] = insts.len + 1;
        } else if (func.instResult(inst)) |result| {
            if (!live[idx(result)]) continue;
            switch (op) {
                .arith => |a| {
                    live[idx(a.lhs)] = true;
                    live[idx(a.rhs)] = true;
                    last_use[idx(a.lhs)] = @max(last_use[idx(a.lhs)], reverse + 1);
                    last_use[idx(a.rhs)] = @max(last_use[idx(a.rhs)], reverse + 1);
                },
                .load => |l| {
                    live[idx(l.ptr)] = true;
                    last_use[idx(l.ptr)] = @max(last_use[idx(l.ptr)], reverse + 1);
                },
                .icmp => |c| {
                    markUse(live, last_use, c.lhs, reverse + 1);
                    markUse(live, last_use, c.rhs, reverse + 1);
                },
                .select => |c| {
                    markUse(live, last_use, c.cond, reverse + 1);
                    markUse(live, last_use, c.then, reverse + 1);
                    markUse(live, last_use, c.@"else", reverse + 1);
                },
                .unary => |u| markUse(live, last_use, u.value, reverse + 1),
                .convert => |c| markUse(live, last_use, c.value, reverse + 1),
                .fconst, .iconst => {},
                else => return error.Unsupported,
            }
        } else return error.Unsupported;
    }
    var compiler = Compiler{ .gpa = gpa };
    defer compiler.code.deinit(gpa);
    var attributes: u16 = 0;
    for (func.blockParams(block)) |param| {
        if (attr(&func, param, "binding")) |binding| {
            if (binding != 0) return error.Unsupported;
            values[idx(param)] = .{ .pointer = 0 };
        } else if (attr(&func, param, "attr")) |slot| {
            if (slot < 0x80 or slot >= 0x180 or slot % 4 != 0 or !isF32(&func, param)) return error.Unsupported;
            if (last_use[idx(param)] == 0) continue;
            const location = (slot - 0x80) / 16;
            const component = ((slot - 0x80) % 16) / 4;
            const reg = try compiler.alloc();
            // Fetch vec4 into reserved scratch registers 52..55. The
            // descriptor supplies absent components according to its format.
            try compiler.emit(0x0066_8000_3200_3d3c | (@as(u64, 52) << 40) | (@as(u64, 4) << 33) | (@as(u64, location) << 20));
            try compiler.mov(58, 0xc0, @as(u64, 1) << 59);
            try compiler.mov(reg, @intCast(52 + component), 0);
            values[idx(param)] = .{ .register = reg };
            attributes |= @as(u16, 1) << @as(u4, @intCast(location));
        } else return error.Unsupported;
    }
    var outputs: [36]?u6 = @splat(null);
    var uniform_bytes: usize = 0;
    for (insts, 0..) |inst, i| {
        const result = func.instResult(inst);
        // Constants which are only frontend metadata need no GPU registers.
        const needed = if (result) |v| live[idx(v)] else true;
        if (!needed) continue;
        switch (func.opcode(inst)) {
            .iconst => |n| if (result) |v| {
                values[idx(v)] = .{ .integer = n };
            },
            .fconst => |n| if (needed) {
                values[idx(result.?)] = .{ .float = @bitCast(@as(f32, @floatCast(n))) };
            },
            .arith => |a| {
                const left = values[idx(a.lhs)];
                const right = values[idx(a.rhs)];
                if (left == .pointer and right == .integer and a.op == .add) {
                    const offset = std.math.add(i64, @intCast(left.pointer), right.integer) catch return error.Unsupported;
                    if (offset < 0) return error.Unsupported;
                    values[idx(result.?)] = .{ .pointer = @intCast(offset) };
                } else if (left == .integer and right == .integer) {
                    values[idx(result.?)] = .{ .integer = switch (a.op) {
                        .add => std.math.add(i64, left.integer, right.integer) catch return error.Unsupported,
                        .mul => std.math.mul(i64, left.integer, right.integer) catch return error.Unsupported,
                        else => return error.Unsupported,
                    } };
                } else {
                    if (!isF32(&func, result.?)) return error.Unsupported;
                    const l = try compiler.operand(left, 48);
                    const r = try compiler.operand(right, 49);
                    const reg = try compiler.alloc();
                    switch (a.op) {
                        .add, .sub => try compiler.emit(destination(0xa4, reg) | l | (@as(u64, r) << 8) | (if (a.op == .sub) @as(u64, 1) << 36 else 0)),
                        .mul => try compiler.fma(reg, l, r, 0xc0),
                        .div => {
                            try compiler.emit(destination(0x9c, 52) | r);
                            try compiler.fma(reg, l, 52, 0xc0);
                        },
                        else => return error.Unsupported,
                    }
                    values[idx(result.?)] = .{ .register = reg };
                }
            },
            .icmp => |compare| {
                const a = try compiler.operand(values[idx(compare.lhs)], 48);
                const b = try compiler.operand(values[idx(compare.rhs)], 49);
                const reg = try compiler.alloc();
                const condition: u64 = switch (compare.op) {
                    .eq => 0,
                    .ne => 3,
                    .lt => 4,
                    .le => 5,
                    .gt => 1,
                    .ge => 2,
                };
                try compiler.constant(50, 1);
                const kind = func.types.type_kind(func.valueType(compare.lhs));
                const opcode: u64 = if (isF32(&func, compare.lhs)) 0x154 else if (kind == .int and kind.int.signedness == .signed) 0x158 else 0x150;
                try compiler.emit(destination(opcode, reg) | (condition << 32) | a | (@as(u64, b) << 8) | (@as(u64, 50) << 16) | (@as(u64, 0xc0) << 24));
                values[idx(result.?)] = .{ .register = reg };
            },
            .select => |select| {
                const condition = values[idx(select.cond)];
                const yes = values[idx(select.then)];
                const no = values[idx(select.@"else")];
                if (condition == .integer) {
                    const value = if (condition.integer != 0) yes else no;
                    if (value == .integer) values[idx(result.?)] = value else {
                        const reg = try compiler.alloc();
                        try compiler.mov(reg, try compiler.operand(value, 48), 0);
                        values[idx(result.?)] = .{ .register = reg };
                    }
                } else {
                    const c = try compiler.operand(condition, 48);
                    const a = try compiler.operand(yes, 49);
                    const b = try compiler.operand(no, 50);
                    const reg = try compiler.alloc();
                    try compiler.emit(destination(0x150, reg) | (@as(u64, 3) << 32) | c | (@as(u64, 0xc0) << 8) | (@as(u64, a) << 16) | (@as(u64, b) << 24));
                    values[idx(result.?)] = .{ .register = reg };
                }
            },
            .unary => |unary| {
                if (!isF32(&func, result.?)) return error.Unsupported;
                const source = try compiler.operand(values[idx(unary.value)], 48);
                const reg = try compiler.alloc();
                switch (unary.op) {
                    .sqrt => {
                        const math = @import("math.zig").Emitter{ .gpa = gpa, .code = &compiler.code };
                        try math.sqrt(reg, source);
                    },
                    .floor, .ceil, .trunc, .nearest => {
                        const rounding: u64 = switch (unary.op) {
                            .floor => 2,
                            .ceil => 1,
                            .trunc => 3,
                            else => 0,
                        };
                        try compiler.emit(destination(0x90, reg) | (@as(u64, 13) << 16) | (rounding << 30) | source);
                    },
                    .reinterpret => try compiler.mov(reg, source, 0),
                }
                values[idx(result.?)] = .{ .register = reg };
            },
            .convert => |convert| {
                const value = values[idx(convert.value)];
                const kind = func.types.type_kind(func.valueType(convert.value));
                if (value != .integer or kind != .int or kind.int.bits != 32 or !isF32(&func, result.?)) return error.Unsupported;
                const number: f32 = if (kind.int.signedness == .signed) @floatFromInt(@as(i32, @truncate(value.integer))) else @floatFromInt(@as(u32, @truncate(@as(u64, @bitCast(value.integer)))));
                values[idx(result.?)] = .{ .float = @bitCast(number) };
            },
            .load => |load| {
                const address = values[idx(load.ptr)];
                if (address != .pointer or address.pointer % 4 != 0 or address.pointer >= 952 or load.mask != null or load.@"volatile" or !isF32(&func, result.?)) return error.Unsupported;
                const word = 18 + address.pointer / 4;
                values[idx(result.?)] = .{ .fau = @intCast(word) };
                uniform_bytes = @max(uniform_bytes, address.pointer + 4);
            },
            .store => |store| {
                if (store.mask != null or store.@"volatile") return error.Unsupported;
                const slot = attr(&func, store.ptr, "out_attr").?;
                if (!selectedOutput(slot, varying_mask)) continue;
                const value = values[idx(store.value)];
                if (!isF32(&func, store.value)) return error.Unsupported;
                outputs[(slot - 0x70) / 4] = if (value == .register) value.register else out: {
                    const reg = try compiler.alloc();
                    try compiler.mov(reg, try compiler.operand(value, 48), 0);
                    break :out reg;
                };
            },
            else => return error.Unsupported,
        }
        for (values, last_use) |*value, last| {
            if (last == i + 1 and value.* == .register) {
                compiler.used[value.register] = false;
                value.* = .unknown;
            }
        }
    }
    for (outputs[0..4]) |output| if (output == null) return error.Unsupported;
    var varying = Compiler{ .gpa = gpa };
    defer varying.code.deinit(gpa);
    var written_mask: u32 = 0;
    var varying_size: u32 = 0;
    for (outputs[4..], 0..) |output, i| if (output != null) {
        written_mask |= @as(u32, 1) << @as(u5, @intCast(i));
        varying_size = @intCast((i + 1) * 4);
    };
    if (written_mask != 0) {
        // IDVS invokes a separate vertex stage for live generic varyings.
        // Reuse the exact arithmetic, including matrix/uniform calculations,
        // then write the linked packet with external-stream stores.
        try varying.code.appendSlice(gpa, compiler.code.items);
        try varying.emit(0x005e_b804_0000_0d3b);
        try varying.mov(58, 0xc0, @as(u64, 1) << 59);
        for (outputs[4..], 0..) |output, i| if (output) |reg| {
            const is_last = (i + 1) * 4 == varying_size;
            try varying.emit(0x0061_4002_1a00_0038 | (@as(u64, reg) << 40) | (@as(u64, i * 4) << 8) | (@as(u64, if (is_last) 15 else 1) << 59));
        };
    }
    // Project to screen coordinates; keep reciprocal W for interpolation.
    try compiler.emit(destination(0x9c, 48) | outputs[3].?);
    try compiler.fma(49, outputs[0].?, 48, 0xc0);
    try compiler.mov(53, 0x83, 0); // viewport X bias
    try compiler.fma(49, 49, 0x80, 53);
    try compiler.fma(50, outputs[1].?, 48, 0xc0);
    try compiler.mov(53, 0x84, 0); // viewport Y bias
    try compiler.fma(50, 50, 0x81, 53);
    try compiler.fma(51, outputs[2].?, 48, 0xc0);
    try compiler.constant(53, 0x3f00_0000);
    try compiler.fma(51, 51, 53, 53);
    try compiler.mov(53, 0x85, 0); // viewport depth bias
    try compiler.fma(51, 51, 0x82, 53);
    // Position packet pointer, followed by four scalar stores. Wait for the
    // LEA before using the address and for each store before reusing slot 0.
    try compiler.emit(0x005e_8004_0000_0d3b | (@as(u64, 56) << 40));
    try compiler.mov(58, 0xc0, @as(u64, 1) << 59);
    for ([_]u6{ 49, 50, 51, 48 }, 0..) |reg, component| {
        try compiler.emit(0x0061_4002_1900_0038 | (@as(u64, reg) << 40) | (@as(u64, component * 4) << 8) | (@as(u64, if (component == 3) 15 else 1) << 59));
    }
    const code = try compiler.code.toOwnedSlice(gpa);
    errdefer gpa.free(code);
    return .{
        .code = code,
        .uniform_bytes = uniform_bytes,
        .attributes = attributes,
        .varying_code = if (written_mask != 0) try varying.code.toOwnedSlice(gpa) else null,
        .varying_mask = written_mask,
        .varying_size = varying_size,
    };
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    used: [48]bool = @splat(false),
    fn alloc(self: *Compiler) Error!u6 {
        for (&self.used, 0..) |*used, i| if (!used.*) {
            used.* = true;
            return @intCast(i);
        };
        return error.Unsupported;
    }
    fn emit(self: *Compiler, raw: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, raw, .little);
        try self.code.appendSlice(self.gpa, &bytes);
    }
    fn mov(self: *Compiler, dest: u6, source: u8, extra: u64) Error!void {
        try self.emit(destination(0x91, dest) | source | extra);
    }
    fn constant(self: *Compiler, dest: u6, bits: u32) Error!void {
        try self.emit(destination(0x110, dest) | 0xc0 | (@as(u64, bits) << 8));
    }
    fn operand(self: *Compiler, value: Scalar, scratch: u6) Error!u6 {
        return switch (value) {
            .register => |reg| reg,
            .integer => |number| blk: {
                try self.constant(scratch, @truncate(@as(u64, @bitCast(number))));
                break :blk scratch;
            },
            .float => |bits| blk: {
                try self.constant(scratch, bits);
                break :blk scratch;
            },
            .fau => |word| blk: {
                try self.mov(scratch, 0x80 | (word % 64), @as(u64, word / 64) << 57);
                break :blk scratch;
            },
            else => error.Unsupported,
        };
    }
    fn fma(self: *Compiler, dest: u6, a: u8, b: u8, c: u8) Error!void {
        try self.emit(destination(0xb2, dest) | a | (@as(u64, b) << 8) | (@as(u64, c) << 16));
    }
};
fn destination(opcode: u64, reg: u6) u64 {
    return (opcode << 48) | ((@as(u64, reg) | 0xc0) << 40);
}
fn idx(value: Value) usize {
    return @backingInt(value);
}
fn isF32(func: *const Function, value: Value) bool {
    return switch (func.types.type_kind(func.valueType(value))) {
        .float => |kind| kind == .f32,
        else => false,
    };
}
fn attr(func: *const Function, value: Value, key: []const u8) ?u32 {
    var attrs = func.attributesOf(.{ .value = value });
    while (attrs.next()) |a| switch (a) {
        .custom => |c| if (std.mem.eql(u8, c.namespace, "vulcan.gpu") and std.mem.eql(u8, c.key, key)) {
            return switch (c.value) {
                .int => |n| @intCast(n),
                else => null,
            };
        },
        else => {},
    };
    return null;
}

fn selectedOutput(slot: u32, mask: u32) bool {
    if (slot >= 0x70 and slot < 0x80 and slot % 4 == 0) return true;
    if (slot >= 0x80 and slot < 0x100 and slot % 4 == 0) return mask & (@as(u32, 1) << @as(u5, @intCast((slot - 0x80) / 4))) != 0;
    return false;
}

fn markUse(live: []bool, last: []usize, value: Value, position: usize) void {
    live[idx(value)] = true;
    last[idx(value)] = @max(last[idx(value)], position);
}
