//! Vulkan HAL driver entry point.
//!
//! Android guarantees a Vulkan loader from API 24. Linux, macOS, and Windows
//! builds can opt into a system Vulkan loader; presentation remains Android-only.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("../driver.zig");
const hal = @import("../hal.zig");
const Device = @import("vulkan/device.zig").Device;

const State = struct {};
var state: State = .{};

const supported = builtin.abi.isAndroid() or switch (builtin.os.tag) {
    .linux, .macos, .windows => true,
    else => false,
};

fn available(_: *anyopaque, _: std.Io) bool {
    return supported;
}

fn createDevice(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io) drv.Error!hal.Device {
    _ = io;
    if (!supported) return error.Unsupported;
    return Device.create(gpa);
}

const vtable = drv.Driver.VTable{
    .isAvailable = &available,
    .createDevice = &createDevice,
};

pub const driver = drv.Driver{
    .name = "vulkan",
    .ptr = &state,
    .vtable = &vtable,
};

test "Vulkan driver is available when compiled in" {
    try std.testing.expectEqual(supported, driver.isAvailable(std.testing.io));
}
