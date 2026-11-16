//! Native Valhall fragment interpolation and direct RGBA outputs.
const std = @import("std");
const F = @import("vulcan-ir").function;
const Error = error{ Unsupported, OutOfMemory };
const Scalar = union(enum) { unknown, register: u6, constant: u32, fau: u8, uniform: usize, sample: struct { allocation: usize, offset: usize }, sampler: u3, function, math_function, discard_function };
pub const Program = struct { code: []u8, uses_varyings: bool, requires_texture: bool, writes_coverage: bool, texture_mask: u8, uniform_bytes: usize };

pub fn compile(gpa: std.mem.Allocator, vertex: []const u8, spirv: []const u8, available: u32) Error!Program {
    const slots = try @import("varyings.zig").link(gpa, vertex, spirv);
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
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    var next: u6 = 4;
    var used: [48]bool = @splat(false);
    const last_use = try lastUses(gpa, &func, block);
    defer gpa.free(last_use);
    var uses_varyings = false;
    for (func.blockParams(block)) |param| {
        if (tagged(&func, param, "discard_fn")) {
            values[idx(param)] = .discard_function;
            continue;
        }
        if (tagged(&func, param, "math_fn")) {
            values[idx(param)] = .math_function;
            continue;
        }
        if (tagged(&func, param, "sampler_fn")) {
            values[idx(param)] = .function;
            continue;
        }
        if (tagged(&func, param, "sampler_desc")) {
            const binding = attr(&func, param, "binding") orelse return error.Unsupported;
            if (binding < 2 or binding >= 10) return error.Unsupported;
            values[idx(param)] = .{ .sampler = @intCast(binding - 2) };
            continue;
        }
        if (attr(&func, param, "binding")) |binding| {
            if (binding != 1) return error.Unsupported;
            values[idx(param)] = .{ .uniform = 0 };
            continue;
        }
        if (last_use[idx(param)] == 0) continue;
        const slot = attr(&func, param, "attr") orelse return error.Unsupported;
        if (slot < 0x80 or slot >= 0x100 or slot % 4 != 0 or !isF32(&func, param)) return error.Unsupported;
        const offset = slots[(slot - 0x80) / 4] orelse return error.Unsupported;
        if (available & (@as(u32, 1) << @as(u5, @intCast(offset / 4))) == 0 or next >= 48) return error.Unsupported;
        // Scalar smooth interpolation at the pixel center, slot 0. Wait
        // before any instruction reads the staging register.
        try emit(gpa, &code, 0x005c_8002_0200_003d | (@as(u64, next) << 40) | (@as(u64, offset) << 16));
        try emit(gpa, &code, 0x0891_fa00_0000_00c0);
        values[idx(param)] = .{ .register = next };
        used[next] = true;
        next += 1;
        uses_varyings = true;
    }
    var outputs: [4]Scalar = @splat(.unknown);
    var uniform_bytes: usize = 0;
    var texture_mask: u8 = 0;
    var writes_coverage = false;
    var sample_allocation: ?usize = null;
    var sample_valid: [4]bool = @splat(false);
    var sampled: [4]u6 = undefined;
    for (func.blockInsts(block), 0..) |inst, instruction_index| {
        switch (func.opcode(inst)) {
            .iconst => |n| if (func.instResult(inst)) |result| {
                values[idx(result)] = .{ .constant = @truncate(@as(u64, @bitCast(n))) };
            },
            .alloca => {
                values[idx(func.instResult(inst).?)] = .{ .sample = .{ .allocation = idx(func.instResult(inst).?), .offset = 0 } };
            },
            .arith => |a| {
                const left = values[idx(a.lhs)];
                const right = values[idx(a.rhs)];
                const result = func.instResult(inst).?;
                if ((left == .uniform or left == .sample) and right == .constant and a.op == .add) {
                    const offset = if (left == .uniform) left.uniform else left.sample.offset;
                    const sum = std.math.add(usize, offset, right.constant) catch return error.Unsupported;
                    values[idx(result)] = if (left == .uniform) .{ .uniform = sum } else .{ .sample = .{ .allocation = left.sample.allocation, .offset = sum } };
                } else {
                    if (!isF32(&func, result)) return error.Unsupported;
                    const l = try source(gpa, &code, left, 48);
                    const r = try source(gpa, &code, right, 49);
                    const dest = try allocate(&used);
                    const raw = switch (a.op) {
                        .mul => destination(0xb2, dest) | l | (@as(u64, r) << 8) | (@as(u64, 0xc0) << 16),
                        .div => blk: {
                            try emit(gpa, &code, destination(0x9c, 52) | r);
                            break :blk destination(0xb2, dest) | l | (@as(u64, 52) << 8) | (@as(u64, 0xc0) << 16);
                        },
                        .add, .sub => destination(0xa4, dest) | l | (@as(u64, r) << 8) | (if (a.op == .sub) @as(u64, 1) << 36 else 0),
                        else => return error.Unsupported,
                    };
                    try emit(gpa, &code, raw);
                    values[idx(result)] = .{ .register = dest };
                }
            },
            .load => |load| {
                if (load.mask != null or load.@"volatile" or !isF32(&func, func.instResult(inst).?)) return error.Unsupported;
                const address = values[idx(load.ptr)];
                if (address == .sample) {
                    if (sample_allocation != address.sample.allocation or address.sample.offset >= 16 or address.sample.offset % 4 != 0) return error.Unsupported;
                    const component = address.sample.offset / 4;
                    if (!sample_valid[component]) return error.Unsupported;
                    values[idx(func.instResult(inst).?)] = .{ .register = sampled[component] };
                    sample_valid[component] = false;
                } else if (address == .uniform) {
                    if (address.uniform >= 992 or address.uniform % 4 != 0) return error.Unsupported;
                    const word_index = 8 + address.uniform / 4;
                    values[idx(func.instResult(inst).?)] = .{ .fau = @intCast(word_index) };
                    uniform_bytes = @max(uniform_bytes, address.uniform + 4);
                } else return error.Unsupported;
            },
            .convert => |convert| {
                const value = values[idx(convert.value)];
                if (value != .constant or !isF32(&func, func.instResult(inst).?)) return error.Unsupported;
                const kind = func.types.type_kind(func.valueType(convert.value));
                if (kind != .int or kind.int.bits != 32) return error.Unsupported;
                const number: f32 = if (kind.int.signedness == .signed) @floatFromInt(@as(i32, @bitCast(value.constant))) else @floatFromInt(value.constant);
                values[idx(func.instResult(inst).?)] = .{ .constant = @bitCast(number) };
            },
            .icmp => |compare| {
                const a = try source(gpa, &code, values[idx(compare.lhs)], 48);
                const b = try source(gpa, &code, values[idx(compare.rhs)], 49);
                const dest = try allocate(&used);
                const condition: u64 = switch (compare.op) {
                    .eq => 0,
                    .ne => 3,
                    .lt => 4,
                    .le => 5,
                    .gt => 1,
                    .ge => 2,
                };
                try emit(gpa, &code, destination(0x110, 50) | 0x1c0);
                const opcode: u64 = if (isF32(&func, compare.lhs)) 0x154 else 0x150;
                try emit(gpa, &code, destination(opcode, dest) | (condition << 32) | a | (@as(u64, b) << 8) | (@as(u64, 50) << 16) | (@as(u64, 0xc0) << 24));
                values[idx(func.instResult(inst).?)] = .{ .register = dest };
            },
            .select => |select| {
                const condition = values[idx(select.cond)];
                const yes = values[idx(select.then)];
                const no = values[idx(select.@"else")];
                if (condition == .constant) {
                    const chosen = if (condition.constant != 0) yes else no;
                    if (chosen == .register) {
                        const dest = try allocate(&used);
                        try emit(gpa, &code, destination(0x91, dest) | chosen.register);
                        values[idx(func.instResult(inst).?)] = .{ .register = dest };
                    } else values[idx(func.instResult(inst).?)] = chosen;
                } else {
                    const c = try source(gpa, &code, condition, 48);
                    const a = try source(gpa, &code, yes, 49);
                    const b = try source(gpa, &code, no, 50);
                    const dest = try allocate(&used);
                    try emit(gpa, &code, destination(0x150, dest) | (@as(u64, 3) << 32) | c | (@as(u64, 0xc0) << 8) | (@as(u64, a) << 16) | (@as(u64, b) << 24));
                    values[idx(func.instResult(inst).?)] = .{ .register = dest };
                }
            },
            .unary => |unary| {
                const result = func.instResult(inst) orelse return error.Unsupported;
                if (!isF32(&func, result)) return error.Unsupported;
                const input = try source(gpa, &code, values[idx(unary.value)], 48);
                const dest = try allocate(&used);
                const math = @import("math.zig").Emitter{ .gpa = gpa, .code = &code };
                switch (unary.op) {
                    .sqrt => try math.sqrt(dest, input),
                    .floor, .ceil, .trunc, .nearest => {
                        const rounding: u64 = switch (unary.op) {
                            .floor => 2,
                            .ceil => 1,
                            .trunc => 3,
                            else => 0,
                        };
                        try emit(gpa, &code, destination(0x90, dest) | (13 << 16) | (rounding << 30) | input);
                    },
                    .reinterpret => try emit(gpa, &code, destination(0x91, dest) | input),
                }
                values[idx(result)] = .{ .register = dest };
            },
            .call_indirect => |call| {
                const args = func.valueList(call.args);
                if (values[idx(call.target)] == .discard_function) {
                    writes_coverage = true;
                    // ATEST consumes r60's incoming coverage. Clear covered
                    // samples only when this discard's original block executes.
                    if (args.len == 0) {
                        try emit(gpa, &code, destination(0x91, 60) | 0xc0);
                    } else if (args.len == 1) {
                        const condition = try source(gpa, &code, values[idx(args[0])], 48);
                        try emit(gpa, &code, destination(0x150, 60) | (@as(u64, 3) << 32) | condition | (@as(u64, 0xc0) << 8) | (@as(u64, 0xc0) << 16) | (@as(u64, 60) << 24));
                    } else return error.Unsupported;
                } else if (values[idx(call.target)] == .math_function) {
                    if (args.len != 3 or values[idx(args[0])] != .constant or values[idx(args[0])].constant != 0) return error.Unsupported;
                    const a = try source(gpa, &code, values[idx(args[1])], 48);
                    const b = try source(gpa, &code, values[idx(args[2])], 49);
                    const dest = try allocate(&used);
                    const math = @import("math.zig").Emitter{ .gpa = gpa, .code = &code };
                    try math.pow(dest, a, b);
                    values[idx(func.instResult(inst) orelse return error.Unsupported)] = .{ .register = dest };
                } else {
                    if (values[idx(call.target)] != .function or args.len != 5 or values[idx(args[0])] != .sampler or values[idx(args[4])] != .sample) return error.Unsupported;
                    for (sample_valid) |valid| if (valid) return error.Unsupported;
                    const lod = values[idx(args[3])];
                    if (lod != .constant or @as(f32, @bitCast(lod.constant)) != -1.0e30) return error.Unsupported;
                    const u = try source(gpa, &code, values[idx(args[1])], 50);
                    const v = try source(gpa, &code, values[idx(args[2])], 51);
                    try emit(gpa, &code, destination(0x91, 48) | u);
                    try emit(gpa, &code, destination(0x91, 49) | v);
                    const slot = values[idx(args[0])].sampler;
                    const handle: u32 = 0x0800_0800 | (@as(u32, slot) * 2 << 16) | (@as(u32, slot) * 2 + 1);
                    try emit(gpa, &code, destination(0x110, 56) | 0xc0 | (@as(u64, handle) << 8));
                    try emit(gpa, &code, destination(0x91, 57) | 0xc0);
                    const tex: u64 = (0x128 << 48) | (@as(u64, 1) << 46) | (@as(u64, 48) << 40) | (@as(u64, 1) << 39) | (@as(u64, 3) << 36) | (@as(u64, 2) << 33) | (@as(u64, 1) << 28) | (@as(u64, 1) << 26) | (@as(u64, 15) << 22) | (@as(u64, 52) << 16) | (@as(u64, 1) << 13) | 56;
                    try emit(gpa, &code, tex);
                    try emit(gpa, &code, 0x0891_fa00_0000_00c0);
                    for (&sampled, 0..) |*reg, component| {
                        reg.* = try allocate(&used);
                        try emit(gpa, &code, destination(0x91, reg.*) | @as(u64, 52 + component));
                    }
                    texture_mask |= @as(u8, 1) << slot;
                    sample_allocation = values[idx(args[4])].sample.allocation;
                    sample_valid = @splat(true);
                }
            },
            .fconst => |n| {
                const result = func.instResult(inst) orelse return error.Unsupported;
                if (!isF32(&func, result)) return error.Unsupported;
                values[idx(result)] = .{ .constant = @bitCast(@as(f32, @floatCast(n))) };
            },
            .store => |store| {
                const slot = attr(&func, store.ptr, "color_out") orelse return error.Unsupported;
                if (slot >= 4 or store.mask != null or store.@"volatile" or !isF32(&func, store.value)) return error.Unsupported;
                outputs[slot] = values[idx(store.value)];
            },
            else => return error.Unsupported,
        }
        for (values, last_use) |*value, last| {
            if (last == instruction_index + 1 and value.* == .register) {
                used[value.register] = false;
                value.* = .unknown;
            }
        }
    }
    var epilogue = @import("native_pipeline.zig").constantFragment(.{ 0, 0, 0, 1 });
    for (outputs, 0..) |output, i| {
        const instruction = epilogue[16 + i * 8 ..][0..8];
        const flow = std.mem.readInt(u64, instruction, .little) & 0xf800_0000_0000_0000;
        const dest: u64 = (@as(u64, i) | 0xc0) << 40;
        const raw = switch (output) {
            .unknown => return error.Unsupported,
            .register => |reg| 0x0091_0000_0000_0000 | dest | reg,
            .constant => |bits| 0x0110_0000_0000_00c0 | dest | (@as(u64, bits) << 8),
            .fau => |word| 0x0091_0000_0000_0080 | dest | @as(u64, word % 64) | (@as(u64, word / 64) << 57),
            else => return error.Unsupported,
        };
        std.mem.writeInt(u64, instruction, raw | flow, .little);
    }
    try code.appendSlice(gpa, &epilogue);
    return .{ .code = try code.toOwnedSlice(gpa), .uses_varyings = uses_varyings, .requires_texture = texture_mask != 0, .writes_coverage = writes_coverage, .texture_mask = texture_mask, .uniform_bytes = uniform_bytes };
}
fn emit(gpa: std.mem.Allocator, code: *std.ArrayList(u8), raw: u64) Error!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, raw, .little);
    try code.appendSlice(gpa, &bytes);
}
fn idx(value: F.Value) usize {
    return @backingInt(value);
}
fn isF32(func: *const F.Function, value: F.Value) bool {
    return switch (func.types.type_kind(func.valueType(value))) {
        .float => |kind| kind == .f32,
        else => false,
    };
}
fn attr(func: *const F.Function, value: F.Value, key: []const u8) ?u32 {
    var attrs = func.attributesOf(.{ .value = value });
    while (attrs.next()) |a| switch (a) {
        .custom => |c| if (std.mem.eql(u8, c.namespace, "vulcan.gpu") and std.mem.eql(u8, c.key, key)) {
            return switch (c.value) {
                .int => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
                else => null,
            };
        },
        else => {},
    };
    return null;
}

fn allocate(used: *[48]bool) Error!u6 {
    for (used[4..], 4..) |*busy, i| if (!busy.*) {
        busy.* = true;
        return @intCast(i);
    };
    return error.Unsupported;
}

fn destination(opcode: u64, reg: u6) u64 {
    return (opcode << 48) | ((@as(u64, reg) | 0xc0) << 40);
}
fn source(gpa: std.mem.Allocator, code: *std.ArrayList(u8), value: Scalar, scratch: u6) Error!u6 {
    return switch (value) {
        .register => |reg| reg,
        .constant => |bits| blk: {
            try emit(gpa, code, destination(0x110, scratch) | 0xc0 | (@as(u64, bits) << 8));
            break :blk scratch;
        },
        .fau => |word| blk: {
            try emit(gpa, code, destination(0x91, scratch) | 0x80 | @as(u64, word % 64) | (@as(u64, word / 64) << 57));
            break :blk scratch;
        },
        else => error.Unsupported,
    };
}
fn tagged(func: *const F.Function, value: F.Value, key: []const u8) bool {
    var attrs = func.attributesOf(.{ .value = value });
    while (attrs.next()) |a| switch (a) {
        .custom => |c| if (std.mem.eql(u8, c.namespace, "vulcan.gpu") and std.mem.eql(u8, c.key, key)) {
            return true;
        },
        else => {},
    };
    return false;
}

pub fn inputMask(gpa: std.mem.Allocator, vertex: []const u8, spirv: []const u8) Error!u32 {
    const slots = try @import("varyings.zig").link(gpa, vertex, spirv);
    var func = @import("../apple/spirv_sampling.zig").parse(gpa, spirv) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    defer func.deinit();
    @import("../apple/flatten.zig").run(&func) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    const last_use = try lastUses(gpa, &func, @fromBackingInt(0));
    defer gpa.free(last_use);
    var mask: u32 = 0;
    for (func.blockParams(@fromBackingInt(0))) |param| {
        if (last_use[idx(param)] == 0) continue;
        const slot = attr(&func, param, "attr") orelse continue;
        if (slot < 0x80 or slot >= 0x100 or slot % 4 != 0) return error.Unsupported;
        const offset = slots[(slot - 0x80) / 4] orelse return error.Unsupported;
        mask |= @as(u32, 1) << @as(u5, @intCast(offset / 4));
    }
    return mask;
}

fn lastUses(gpa: std.mem.Allocator, func: *const F.Function, block: F.Block) Error![]usize {
    const last = try gpa.alloc(usize, func.valueCount());
    @memset(last, 0);
    const instructions = func.blockInsts(block);
    for (instructions, 0..) |inst, i| switch (func.opcode(inst)) {
        .arith => |a| {
            mark(last, a.lhs, i + 1);
            mark(last, a.rhs, i + 1);
        },
        .icmp => |a| {
            mark(last, a.lhs, i + 1);
            mark(last, a.rhs, i + 1);
        },
        .select => |s| {
            mark(last, s.cond, i + 1);
            mark(last, s.then, i + 1);
            mark(last, s.@"else", i + 1);
        },
        .load => |l| mark(last, l.ptr, i + 1),
        .convert => |c| mark(last, c.value, i + 1),
        .unary => |u| mark(last, u.value, i + 1),
        .store => |s| mark(last, s.value, instructions.len + 1),
        .call_indirect => |c| {
            mark(last, c.target, i + 1);
            for (func.valueList(c.args)) |arg| mark(last, arg, i + 1);
        },
        else => {},
    };
    return last;
}
fn mark(last: []usize, value: F.Value, position: usize) void {
    last[idx(value)] = @max(last[idx(value)], position);
}
