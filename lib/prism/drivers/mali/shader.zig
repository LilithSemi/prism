const std = @import("std");
const hal = @import("../../hal.zig");

pub const ShaderModule = struct {
    stage: hal.ShaderStage,
    code: []u8,

    pub fn create(gpa: std.mem.Allocator, desc: hal.ShaderModuleDesc) hal.Error!*ShaderModule {
        if (desc.code.len == 0) return error.InvalidArgument;
        if (desc.stage != .compute and
            (desc.code.len < 20 or desc.code.len % 4 != 0 or std.mem.readInt(u32, desc.code[0..4], .little) != 0x0723_0203))
            return error.InvalidArgument;
        const self = gpa.create(ShaderModule) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        const code = gpa.dupe(u8, desc.code) catch return error.OutOfMemory;
        self.* = .{ .stage = desc.stage, .code = code };
        return self;
    }

    pub fn destroy(self: *ShaderModule, gpa: std.mem.Allocator) void {
        gpa.free(self.code);
        gpa.destroy(self);
    }
};

test "Mali shader modules own their input bytes" {
    const input = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const module = try ShaderModule.create(std.testing.allocator, .{ .stage = .compute, .code = &input });
    defer module.destroy(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &input, module.code);
}
