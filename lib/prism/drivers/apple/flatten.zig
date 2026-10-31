//! If-convert acyclic shader control flow. Both sides execute on AGX and joins
//! select the value from the taken edge. Only output stores may have side effects;
//! memory accesses remain checked by the native compiler's binding validation.
const std = @import("std");
const ir = @import("vulcan-ir");
const F = ir.function;
const Function = F.Function;
const Block = F.Block;
const Value = F.Value;
const Inst = F.Inst;
const Error = error{ OutOfMemory, Unsupported };
const Edge = struct { target: Block, args: F.ValueList, guard: Value };

fn visit(func: *const Function, block: Block, state: []u8, order: *std.ArrayList(Block), gpa: std.mem.Allocator) Error!void {
    const i = @backingInt(block);
    if (state[i] == 1) return error.Unsupported; // loops need native execution masks
    if (state[i] == 2) return;
    state[i] = 1;
    var branch = false;
    for (func.blockInsts(block)) |inst| switch (func.opcode(inst)) {
        .@"if" => |cf| {
            if (branch) return error.Unsupported;
            branch = true;
            try visit(func, cf.then.target, state, order, gpa);
            try visit(func, cf.@"else".target, state, order, gpa);
        },
        else => if (branch) return error.Unsupported,
    };
    if (!branch) switch (func.terminator(block) orelse return error.Unsupported) {
        .jump => |edge| try visit(func, edge.target, state, order, gpa),
        .ret => {},
    };
    state[i] = 2;
    try order.append(gpa, block);
}

fn emit(func: *Function, out: *std.ArrayList(Inst), ty: ir.types.Type, op: F.Opcode) Error!Value {
    const v = try func.createInst(ty, op);
    try out.append(func.allocator, func.definingInst(v).?);
    return v;
}

fn outputSlot(func: *const Function, pointer: Value) ?usize {
    var it = func.attributesOf(.{ .value = pointer });
    while (it.next()) |attr| switch (attr) {
        .custom => |a| if (std.mem.eql(u8, a.namespace, "vulcan.gpu") and (std.mem.eql(u8, a.key, "out_attr") or std.mem.eql(u8, a.key, "color_out"))) {
            return switch (a.value) {
                .int => |n| if (n >= 0 and n < 256) @intCast(n) else null,
                else => null,
            };
        },
        else => {},
    };
    return null;
}

pub fn run(func: *Function) Error!void {
    if (func.blockCount() == 1) return;
    if (func.blockCount() > 512) return error.Unsupported;
    const gpa = func.allocator;
    const root: Block = @fromBackingInt(@intCast(0));
    const state = try gpa.alloc(u8, func.blockCount());
    defer gpa.free(state);
    @memset(state, 0);
    var order: std.ArrayList(Block) = .empty;
    defer order.deinit(gpa);
    try visit(func, root, state, &order, gpa);
    std.mem.reverse(Block, order.items);
    var linear: std.ArrayList(Inst) = .empty;
    defer linear.deinit(gpa);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    const bool_type = try func.types.intern(.bool);
    const yes = try emit(func, &linear, bool_type, .{ .iconst = 1 });
    const no = try emit(func, &linear, bool_type, .{ .iconst = 0 });
    var outputs: [256]?struct { ptr: Value, value: Value } = @splat(null);
    for (order.items) |block| {
        var guard = if (block == root) yes else no;
        for (edges.items) |edge| if (edge.target == block) {
            guard = try emit(func, &linear, bool_type, .{ .select = .{ .cond = edge.guard, .then = yes, .@"else" = guard } });
        };
        if (block != root) for (func.blockParams(block), 0..) |param, component| {
            var value: ?Value = null;
            for (edges.items) |edge| if (edge.target == block) {
                const args = func.valueList(edge.args);
                if (component >= args.len) return error.Unsupported;
                value = if (value) |previous| try emit(func, &linear, func.valueType(param), .{ .select = .{ .cond = edge.guard, .then = args[component], .@"else" = previous } }) else args[component];
            };
            func.replaceAllUses(param, value orelse return error.Unsupported);
        };
        var branch = false;
        for (func.blockInsts(block)) |inst| switch (func.opcode(inst)) {
            .@"if" => |cf| {
                branch = true;
                const take_then = try emit(func, &linear, bool_type, .{ .select = .{ .cond = guard, .then = cf.cond, .@"else" = no } });
                const negate = try emit(func, &linear, bool_type, .{ .select = .{ .cond = cf.cond, .then = no, .@"else" = yes } });
                const take_else = try emit(func, &linear, bool_type, .{ .select = .{ .cond = guard, .then = negate, .@"else" = no } });
                try edges.append(gpa, .{ .target = cf.then.target, .args = cf.then.args, .guard = take_then });
                try edges.append(gpa, .{ .target = cf.@"else".target, .args = cf.@"else".args, .guard = take_else });
            },
            .store => |st| {
                const slot = outputSlot(func, st.ptr) orelse return error.Unsupported;
                const previous = if (outputs[slot]) |o| o.value else try emit(func, &linear, func.valueType(st.value), .{ .fconst = 0 });
                const value = try emit(func, &linear, func.valueType(st.value), .{ .select = .{ .cond = guard, .then = st.value, .@"else" = previous } });
                outputs[slot] = .{ .ptr = st.ptr, .value = value };
                // Keep the pointer's defining instruction, which carries the
                // output attribute, in the linear stream too.
            },
            .call_indirect, .load, .alloca, .iconst, .fconst, .arith, .arith_imm, .icmp, .select, .unary, .convert => try linear.append(gpa, inst),
            else => return error.Unsupported,
        };
        if (!branch) switch (func.terminator(block).?) {
            .jump => |edge| try edges.append(gpa, .{ .target = edge.target, .args = edge.args, .guard = guard }),
            .ret => {},
        };
    }
    for (outputs) |out| if (out) |o| {
        const inst = try func.appendStmtRaw(root, .{ .store = .{ .ptr = o.ptr, .value = o.value } });
        try linear.append(gpa, inst);
    };
    try func.setBlockInsts(root, linear.items);
    func.setTerminator(root, .{ .ret = .{} });
}
