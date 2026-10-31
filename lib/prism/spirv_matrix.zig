//! Expand matrix SSA composites into column vectors before the scalar IR front
//! end. Matrix buffers keep their declared column stride; no floating-point
//! arithmetic is introduced for a column extraction or a matrix constructor.
const std = @import("std");
const spirv = @import("vulcan-spirv");
const op = spirv.opcodes;
const Builder = spirv.binary.Builder;
const Error = std.mem.Allocator.Error || error{ InvalidSpirv, Unsupported };
const Matrix = struct { vector: u32, columns: u32, stride: u32 = 16 };
const Columns = struct { ids: [4]u32 = @splat(0), len: u32 = 0 };
const Pointer = struct { storage: u32, pointee: u32 };

pub fn expand(gpa: std.mem.Allocator, words: []const u32) Error![]u32 {
    var reader = spirv.binary.Reader.init(words) catch return error.InvalidSpirv;
    const bound = reader.header.id_bound;
    const matrices = try gpa.alloc(?Matrix, bound);
    defer gpa.free(matrices);
    @memset(matrices, null);
    const pointers = try gpa.alloc(?Pointer, bound);
    defer gpa.free(pointers);
    @memset(pointers, null);
    const types = try gpa.alloc(u32, bound);
    defer gpa.free(types);
    @memset(types, 0);
    const columns = try gpa.alloc(Columns, bound);
    defer gpa.free(columns);
    @memset(columns, .{});
    var needed = false;
    // Only modules using matrix SSA extraction/construction need this expansion.
    while (reader.next() catch return error.InvalidSpirv) |inst| {
        const a = inst.operands;
        switch (inst.opcode) {
            op.TypeMatrix => {
                if (a.len != 3 or a[0] >= bound or a[1] >= bound or a[2] < 2 or a[2] > 4) return error.InvalidSpirv;
                matrices[a[0]] = .{ .vector = a[1], .columns = a[2] };
            },
            op.TypePointer => {
                if (a.len != 3 or a[0] >= bound or a[2] >= bound) return error.InvalidSpirv;
                pointers[a[0]] = .{ .storage = a[1], .pointee = a[2] };
            },
            op.Load, op.CompositeConstruct, op.CopyObject => {
                if (a.len < 2 or a[1] >= bound or a[0] >= bound) return error.InvalidSpirv;
                types[a[1]] = a[0];
                if (inst.opcode == op.CompositeConstruct and matrices[a[0]] != null) needed = true;
            },
            op.CompositeExtract => {
                if (a.len < 4 or a[2] >= bound) return error.InvalidSpirv;
                if (matrices[types[a[2]]] != null) needed = true;
            },
            else => {},
        }
    }
    if (!needed) return gpa.dupe(u32, words);
    // Resolve MatrixStride from the enclosing block member before replacing a
    // matrix's buffer type with its column array. Row-major memory is left for
    // a dedicated transpose expansion rather than reinterpreted as column-major.
    reader.pos = 5;
    while (reader.next() catch return error.InvalidSpirv) |inst| {
        if (inst.opcode != op.MemberDecorate or inst.operands.len < 3) continue;
        const a = inst.operands;
        var scan = spirv.binary.Reader.init(words) catch return error.InvalidSpirv;
        while (scan.next() catch return error.InvalidSpirv) |decl| {
            if (decl.opcode != op.TypeStruct or decl.operands[0] != a[0]) continue;
            if (a[1] + 1 >= decl.operands.len) return error.InvalidSpirv;
            const ty = decl.operands[a[1] + 1];
            if (ty >= bound) return error.InvalidSpirv;
            if (matrices[ty]) |*matrix| {
                if (a[2] == 4) return error.Unsupported; // RowMajor
                if (a[2] == op.Decoration.matrix_stride) {
                    if (a.len < 4) return error.InvalidSpirv;
                    matrix.stride = a[3];
                }
            }
        }
    }
    var out = try Builder.init(gpa, bound);
    defer out.deinit(gpa);
    @memcpy(out.words.items[0..5], words[0..5]);
    var declarations = try Builder.init(gpa, bound);
    defer declarations.deinit(gpa);
    const integer = freshId(&out);
    var index_ids: [5]u32 = undefined;
    for (&index_ids) |*id| id.* = freshId(&out);
    // Per original pointer type, a pointer to one column (same storage class).
    const column_pointer = try gpa.alloc(u32, bound);
    defer gpa.free(column_pointer);
    @memset(column_pointer, 0);
    for (pointers, 0..) |pointer, i| if (pointer) |p| {
        if (matrices[p.pointee]) |matrix| {
            const id = freshId(&out);
            column_pointer[i] = id;
            try declarations.emit(gpa, op.TypePointer, &.{ id, p.storage, matrix.vector });
        }
    };
    reader.pos = 5;
    var declared_indices = false;
    var declared_pointers = false;
    var annotated = false;
    while (reader.next() catch return error.InvalidSpirv) |inst| {
        const a = inst.operands;
        if (!annotated and inst.opcode >= op.TypeVoid and inst.opcode <= op.TypePointer) {
            for (matrices, 0..) |matrix, id| if (matrix) |m| try out.emit(gpa, op.Decorate, &.{ @intCast(id), op.Decoration.array_stride, m.stride });
            annotated = true;
        }
        if (inst.opcode == op.TypeMatrix) {
            if (!declared_indices) {
                try out.emit(gpa, op.TypeInt, &.{ integer, 32, 0 });
                for (index_ids, 0..) |id, i| try out.emit(gpa, op.Constant, &.{ integer, id, @intCast(i) });
                declared_indices = true;
            }
            try out.emit(gpa, op.TypeArray, &.{ a[0], a[1], index_ids[a[2]] });
            continue;
        }
        if (!declared_pointers and inst.opcode == op.Function) {
            try out.words.appendSlice(gpa, declarations.words.items[5..]);
            declared_pointers = true;
        }
        if (inst.opcode == op.MemberDecorate and a.len >= 3 and (a[2] == 4 or a[2] == 5 or a[2] == op.Decoration.matrix_stride)) {
            var scan = spirv.binary.Reader.init(words) catch return error.InvalidSpirv;
            var transformed = false;
            while (scan.next() catch return error.InvalidSpirv) |decl| {
                if (decl.opcode == op.TypeStruct and decl.operands.len > a[1] + 1 and decl.operands[0] == a[0]) {
                    const member_type = decl.operands[a[1] + 1];
                    if (member_type >= bound) return error.InvalidSpirv;
                    transformed = matrices[member_type] != null;
                }
            }
            if (transformed) continue;
        }
        switch (inst.opcode) {
            op.Load => if (matrices[a[0]]) |matrix| {
                // The original result is an array of column vectors now. Keep
                // it as a valid SSA aggregate for debug names and copies too.
                var c: Columns = .{ .len = matrix.columns };
                // Find the pointer type of this access-chain/variable result.
                var scan = spirv.binary.Reader.init(words) catch return error.InvalidSpirv;
                var ptr_type: u32 = 0;
                while (scan.next() catch return error.InvalidSpirv) |definition| {
                    if ((definition.opcode == op.AccessChain or definition.opcode == op.Variable or definition.opcode == op.InBoundsAccessChain) and definition.operands.len >= 2 and definition.operands[1] == a[2]) ptr_type = definition.operands[0];
                }
                if (ptr_type == 0 or column_pointer[ptr_type] == 0) return error.Unsupported;
                for (0..matrix.columns) |i| {
                    const pointer = freshId(&out);
                    c.ids[i] = freshId(&out);
                    try out.emit(gpa, op.AccessChain, &.{ column_pointer[ptr_type], pointer, a[2], index_ids[i] });
                    try out.emit(gpa, op.Load, &.{ matrix.vector, c.ids[i], pointer });
                }
                columns[a[1]] = c;
                continue;
            },
            op.CompositeConstruct => if (matrices[a[0]]) |matrix| {
                if (a.len != matrix.columns + 2) return error.InvalidSpirv;
                columns[a[1]].len = matrix.columns;
                @memcpy(columns[a[1]].ids[0..matrix.columns], a[2..]);
                continue;
            },
            op.CompositeExtract => if (columns[a[2]].len != 0) {
                const c = columns[a[2]];
                if (a[3] >= c.len) return error.InvalidSpirv;
                if (a.len == 4) try out.emit(gpa, op.CopyObject, &.{ a[0], a[1], c.ids[a[3]] }) else if (a.len == 5) try out.emit(gpa, op.CompositeExtract, &.{ a[0], a[1], c.ids[a[3]], a[4] }) else return error.Unsupported;
                continue;
            },
            op.CopyObject => if (columns[a[2]].len != 0) {
                columns[a[1]] = columns[a[2]];
                continue;
            },
            op.MatrixTimesVector => {
                try multiply(gpa, &out, matrices[a[0]] orelse .{ .vector = a[0], .columns = columns[a[2]].len }, a[0], a[1], columns[a[2]], a[3], words);
                continue;
            },
            else => {},
        }
        // Debug names of removed matrix SSA values would reference undefined ids.
        if (inst.opcode == op.Name and a.len >= 1 and types[a[0]] != 0 and matrices[types[a[0]]] != null) continue;
        try out.emit(gpa, inst.opcode, a);
    }
    return gpa.dupe(u32, out.words.items);
}

fn multiply(gpa: std.mem.Allocator, out: *Builder, matrix: Matrix, result_type: u32, result: u32, cols: Columns, vector: u32, words: []const u32) Error!void {
    if (cols.len < 2 or cols.len > 4) return error.Unsupported;
    var reader = spirv.binary.Reader.init(words) catch return error.InvalidSpirv;
    var scalar: u32 = 0;
    while (reader.next() catch return error.InvalidSpirv) |inst| if (inst.opcode == op.TypeVector and inst.operands[0] == result_type) {
        scalar = inst.operands[1];
    };
    if (scalar == 0) return error.Unsupported;
    var sum: u32 = 0;
    for (cols.ids[0..cols.len], 0..) |column, i| {
        const component = freshId(out);
        const product = freshId(out);
        try out.emit(gpa, op.CompositeExtract, &.{ scalar, component, vector, @intCast(i) });
        try out.emit(gpa, op.VectorTimesScalar, &.{ matrix.vector, product, column, component });
        if (i == 0) sum = product else {
            const next = if (i + 1 == cols.len) result else freshId(out);
            try out.emit(gpa, op.FAdd, &.{ result_type, next, sum, product });
            sum = next;
        }
    }
}

fn freshId(out: *Builder) u32 {
    const id = out.words.items[3];
    out.words.items[3] += 1;
    return id;
}
