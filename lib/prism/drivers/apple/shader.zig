const std = @import("std");
const hal = @import("../../hal.zig");

/// Owned shader code. Graphics modules contain SPIR-V, lowered to native AGX
/// during pipeline creation. Compute modules contain raw AGX kernel bytecode.
pub const ShaderModule = struct {
    stage: hal.ShaderStage,
    /// Owned copy of the caller-supplied shader code.
    code: []u8,

    pub fn create(gpa: std.mem.Allocator, desc: hal.ShaderModuleDesc) hal.Error!*ShaderModule {
        if (desc.code.len == 0) return error.InvalidArgument;
        if (desc.stage != .compute and (desc.code.len < 20 or desc.code.len % 4 != 0 or std.mem.readInt(u32, desc.code[0..4], .little) != 0x07230203)) return error.InvalidArgument;
        if (desc.stage == .compute and desc.code.len >= 4 and std.mem.readInt(u32, desc.code[0..4], .little) == 0x07230203)
            return error.Unsupported;
        const m = gpa.create(ShaderModule) catch return error.OutOfMemory;
        errdefer gpa.destroy(m);
        const owned = gpa.alloc(u8, desc.code.len) catch return error.OutOfMemory;
        @memcpy(owned, desc.code);
        m.* = .{ .stage = desc.stage, .code = owned };
        return m;
    }

    pub fn destroy(self: *ShaderModule, gpa: std.mem.Allocator) void {
        gpa.free(self.code);
        gpa.destroy(self);
    }
};

test "apple compute shader module wraps the AGX kernel bytes" {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{ 0x62, 0x01, 0x0d, 0xf0, 0xfe, 0xca };
    const m = try ShaderModule.create(gpa, .{ .stage = .compute, .code = &bytes });
    defer m.destroy(gpa);
    try std.testing.expectEqual(hal.ShaderStage.compute, m.stage);
    try std.testing.expectEqualSlices(u8, &bytes, m.code);
}

test "apple rejects malformed graphics shader modules" {
    const gpa = std.testing.allocator;
    const bytes: [8]u8 = @splat(0);
    try std.testing.expectError(error.InvalidArgument, ShaderModule.create(gpa, .{ .stage = .vertex, .code = &bytes }));
    try std.testing.expectError(error.InvalidArgument, ShaderModule.create(gpa, .{ .stage = .fragment, .code = &bytes }));
}
