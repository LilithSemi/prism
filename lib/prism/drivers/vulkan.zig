//! Vulkan HAL driver entry point.
//!
//! Android guarantees a Vulkan loader from API 24 and is the first supported
//! host. Platform selection stays here so the same driver can use a desktop
//! Vulkan loader when a host surface implementation is added.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("../driver.zig");
const hal = @import("../hal.zig");
const Device = @import("vulkan/device.zig").Device;

const State = struct {};
var state: State = .{};

fn available(_: *anyopaque) bool {
    return builtin.abi.isAndroid();
}

fn createDevice(_: *anyopaque, gpa: std.mem.Allocator, io: std.Io) drv.Error!hal.Device {
    _ = io;
    if (!builtin.abi.isAndroid()) return error.Unsupported;
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

test "Android Vulkan driver is unavailable on a host test build" {
    if (!builtin.abi.isAndroid()) try std.testing.expect(!driver.isAvailable());
}
