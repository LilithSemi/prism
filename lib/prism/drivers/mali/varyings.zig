//! Link GLSL varying names across separately compiled SPIR-V stages. Vertex
//! locations define the native packet; fragment declaration order may differ.
const std = @import("std");
const Error = error{ Unsupported, OutOfMemory };
const Entry = struct { name: []const u8, location: u32 };
const Interface = struct {
    entries: [32]Entry = undefined,
    len: usize = 0,
};
pub fn link(gpa: std.mem.Allocator, vertex: []const u8, fragment: []const u8) Error![32]?u8 {
    const outputs = try reflect(gpa, vertex, 3);
    const inputs = try reflect(gpa, fragment, 1);
    var result: [32]?u8 = @splat(null);
    for (inputs.entries[0..inputs.len]) |input| {
        if (input.location >= 8) return error.Unsupported;
        var matched = false;
        for (outputs.entries[0..outputs.len]) |output| {
            if (output.location >= 8) return error.Unsupported;
            // Named GLSL interfaces link by name. SPIR-V binary applications
            // may omit OpName and then use the explicit location ABI.
            if (if (input.name.len != 0 and output.name.len != 0)
                std.mem.eql(u8, input.name, output.name)
            else
                input.location == output.location)
            {
                for (0..4) |component| result[input.location * 4 + component] = @intCast(output.location * 16 + component * 4);
                matched = true;
                break;
            }
        }
        if (!matched) return error.Unsupported;
    }
    return result;
}
fn reflect(gpa: std.mem.Allocator, code: []const u8, storage: u32) Error!Interface {
    if (code.len < 20 or code.len % 4 != 0 or word(code, 0) != 0x0723_0203) return error.Unsupported;
    const bound = word(code, 3);
    // Reject impossible IDs before allocating from an untrusted header.
    if (bound == 0 or bound > code.len) return error.Unsupported;
    const names = try gpa.alloc([]const u8, bound);
    defer gpa.free(names);
    @memset(names, &.{});
    const locations = try gpa.alloc(?u32, bound);
    defer gpa.free(locations);
    @memset(locations, null);
    const variables = try gpa.alloc(bool, bound);
    defer gpa.free(variables);
    @memset(variables, false);
    var cursor: usize = 5;
    while (cursor < code.len / 4) {
        const header = word(code, cursor);
        const count = header >> 16;
        const opcode = header & 0xffff;
        if (count == 0 or count > code.len / 4 - cursor) return error.Unsupported;
        switch (opcode) {
            5 => { // OpName
                if (count < 3) return error.Unsupported;
                const id = word(code, cursor + 1);
                if (id >= bound) return error.Unsupported;
                const bytes = code[(cursor + 2) * 4 .. (cursor + count) * 4];
                const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.Unsupported;
                names[id] = bytes[0..end];
            },
            71 => { // OpDecorate Location
                if (count < 3) return error.Unsupported;
                const id = word(code, cursor + 1);
                if (id >= bound) return error.Unsupported;
                if (word(code, cursor + 2) == 30) {
                    if (count != 4) return error.Unsupported;
                    locations[id] = word(code, cursor + 3);
                }
            },
            59 => { // OpVariable
                if (count < 4) return error.Unsupported;
                const id = word(code, cursor + 2);
                if (id >= bound) return error.Unsupported;
                variables[id] = word(code, cursor + 3) == storage;
            },
            else => {},
        }
        cursor += count;
    }
    var result: Interface = .{};
    for (variables, locations, names) |variable, location, name| {
        if (variable and location != null) {
            if (result.len == result.entries.len) return error.Unsupported;
            result.entries[result.len] = .{ .name = name, .location = location.? };
            result.len += 1;
        }
    }
    return result;
}
fn word(code: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, code[index * 4 ..][0..4], .little);
}
