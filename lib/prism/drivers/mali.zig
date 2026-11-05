const std = @import("std");
const drv = @import("../driver.zig");
const mali = @import("mali");
const MaliDevice = @import("mali/device.zig").Device;

const State = struct {};
var state: State = .{};

fn available(ptr: *anyopaque, io: std.Io) bool {
    _ = ptr;
    _ = io;
    if (@import("builtin").os.tag != .linux or @import("builtin").cpu.arch != .aarch64) return false;
    var dev = mali.Device.open(std.heap.page_allocator) catch return false;
    defer dev.deinit();
    return dev.driver == .panthor;
}

fn createDevice(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io) drv.Error!drv.Device {
    _ = ptr;
    _ = io;
    return MaliDevice.create(gpa);
}

const vtable = drv.Driver.VTable{ .isAvailable = &available, .createDevice = &createDevice };

pub const driver = drv.Driver{
    .name = "mali",
    .ptr = &state,
    .vtable = &vtable,
    .drm_driver = "panthor",
};

test {
    _ = @import("mali/device.zig");
    _ = @import("mali/context.zig");
}

test "mali driver is associated with the Panthor DRM driver" {
    try std.testing.expectEqualStrings("mali", driver.name);
    try std.testing.expectEqualStrings("panthor", driver.drm_driver.?);
}
