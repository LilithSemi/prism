const std = @import("std");
const mali = @import("mali");
const hal = @import("../../hal.zig");

pub const Resource = struct {
    kind: hal.ResourceKind,
    desc: hal.ResourceDesc,
    bo: mali.Bo,
    gpa: std.mem.Allocator,
    /// HAL image mappings are tightly packed even when Panthor's linear image
    /// descriptor needs a padded GPU row stride. Null for buffers and images
    /// whose packed and GPU strides already match.
    cpu_shadow: ?[]u8 = null,
    cpu_dirty: bool = false,
    gpu_dirty: bool = false,
    byte_size: usize,
    width: u32 = 0,
    height: u32 = 0,
    row_stride: u32 = 0,
    format: hal.Format = .rgba8_unorm,
    dma_fd: ?std.posix.fd_t = null,

    pub fn map(self: *Resource) []u8 {
        const shadow = self.cpu_shadow orelse return self.bo.cpu[0..self.byte_size];
        if (self.gpu_dirty) {
            self.unpackRows(shadow);
            self.gpu_dirty = false;
        }
        // The HAL cannot distinguish a read mapping from a write mapping. Mark
        // it dirty conservatively; uploading unchanged bytes is harmless.
        self.cpu_dirty = true;
        return shadow;
    }

    pub fn syncForGpu(self: *Resource) void {
        const shadow = self.cpu_shadow orelse return;
        if (!self.cpu_dirty) return;
        self.packRows(shadow);
        self.cpu_dirty = false;
        self.gpu_dirty = false;
    }

    pub fn markGpuWritten(self: *Resource) void {
        if (self.cpu_shadow == null) return;
        self.cpu_dirty = false;
        self.gpu_dirty = true;
    }

    pub fn deinitShadow(self: *Resource) void {
        if (self.cpu_shadow) |shadow| self.gpa.free(shadow);
        self.cpu_shadow = null;
    }

    fn packRows(self: *Resource, shadow: []const u8) void {
        const packed_stride = @as(usize, self.width) * 4;
        for (0..self.height) |y| {
            @memcpy(self.bo.cpu[y * self.row_stride ..][0..packed_stride], shadow[y * packed_stride ..][0..packed_stride]);
        }
    }

    fn unpackRows(self: *Resource, shadow: []u8) void {
        const packed_stride = @as(usize, self.width) * 4;
        for (0..self.height) |y| {
            @memcpy(shadow[y * packed_stride ..][0..packed_stride], self.bo.cpu[y * self.row_stride ..][0..packed_stride]);
        }
    }
};
