const std = @import("std");
const mali = @import("mali");
const hal = @import("../../hal.zig");
const Resource = @import("resource.zig").Resource;
const ShaderModule = @import("shader.zig").ShaderModule;
const graphics = @import("graphics.zig");
const Pipeline = graphics.Pipeline;

test {
    _ = graphics;
}

pub fn merr(err: anyerror) hal.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArgument, error.InvalidImage, error.InvalidShader => error.InvalidArgument,
        error.UnsupportedDriver => error.Unsupported,
        error.Timeout, error.IoctlFailed, error.MapFailed => error.DeviceLost,
        else => error.InitializationFailed,
    };
}

pub const Device = struct {
    gpa: std.mem.Allocator,
    session: mali.Session,

    const formats = [_]hal.Format{.rgba8_unorm};

    pub fn create(gpa: std.mem.Allocator) hal.Error!hal.Device {
        const self = gpa.create(Device) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .session = mali.Session.open(gpa) catch |err| return merr(err),
        };
        return self.halDevice();
    }

    pub fn halDevice(self: *Device) hal.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn caps(ptr: *anyopaque) hal.DeviceCaps {
        const self: *Device = @ptrCast(@alignCast(ptr));
        return .{
            .device_name = self.session.info.name,
            .formats = &formats,
            .hdr = false,
            // Graphics currently accepts a semantically validated passthrough
            // vertex shader plus arbitrary constant RGBA fragment output.
            .spirv = true,
            .compute = true,
            .graphics = true,
            .present = true,
            .max_texture_dim = std.math.maxInt(u16),
        };
    }

    fn createContext(ptr: *anyopaque) hal.Error!hal.Context {
        return @import("context.zig").Context.create(@ptrCast(@alignCast(ptr)));
    }

    fn createResource(ptr: *anyopaque, desc: hal.ResourceDesc) hal.Error!*hal.Resource {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const resource = self.gpa.create(Resource) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(resource);

        var byte_size: usize = 0;
        var width: u32 = 0;
        var height: u32 = 0;
        var row_stride: u32 = 0;
        var gpu_byte_size: usize = 0;
        var format: hal.Format = .rgba8_unorm;
        switch (desc) {
            .buffer => |buffer| {
                if (buffer.size == 0) return error.InvalidArgument;
                byte_size = buffer.size;
                gpu_byte_size = byte_size;
            },
            .image => |image| {
                if (image.width == 0 or image.height == 0 or image.width > std.math.maxInt(u16) or
                    image.height > std.math.maxInt(u16) or image.format != .rgba8_unorm or
                    image.samples != 1 or image.mip_levels != 1 or image.cube or image.depth != 1 or image.array)
                    return error.Unsupported;
                const packed_row = std.math.mul(u32, image.width, 4) catch return error.InvalidArgument;
                row_stride = std.mem.alignForward(u32, packed_row, 64);
                byte_size = std.math.mul(usize, packed_row, image.height) catch return error.InvalidArgument;
                gpu_byte_size = std.math.mul(usize, row_stride, image.height) catch return error.InvalidArgument;
                width = image.width;
                height = image.height;
                format = image.format;
            },
        }
        const bo = self.session.allocBo(gpu_byte_size, allocationOptions(desc)) catch |err| return merr(err);
        errdefer self.session.freeBo(bo);
        @memset(bo.cpu, 0);
        const cpu_shadow = if (row_stride != 0 and row_stride != width * 4)
            self.gpa.alloc(u8, byte_size) catch return error.OutOfMemory
        else
            null;
        if (cpu_shadow) |shadow| @memset(shadow, 0);
        resource.* = .{
            .kind = std.meta.activeTag(desc),
            .desc = desc,
            .bo = bo,
            .gpa = self.gpa,
            .cpu_shadow = cpu_shadow,
            .byte_size = byte_size,
            .width = width,
            .height = height,
            .row_stride = row_stride,
            .format = format,
        };
        return @ptrCast(resource);
    }

    fn destroyResource(ptr: *anyopaque, handle: *hal.Resource) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const resource: *Resource = @ptrCast(@alignCast(handle));
        if (resource.dma_fd) |fd| _ = std.os.linux.close(fd);
        resource.deinitShadow();
        self.session.freeBo(resource.bo);
        self.gpa.destroy(resource);
    }

    fn mapResource(ptr: *anyopaque, handle: *hal.Resource) hal.Error![]u8 {
        _ = ptr;
        const resource: *Resource = @ptrCast(@alignCast(handle));
        return resource.map();
    }

    fn unmapResource(ptr: *anyopaque, handle: *hal.Resource) void {
        _ = ptr;
        _ = handle;
    }

    fn exportResource(ptr: *anyopaque, handle: *hal.Resource) hal.Error!hal.DmaBufDesc {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const resource: *Resource = @ptrCast(@alignCast(handle));
        if (resource.kind != .image or resource.format != .rgba8_unorm) return error.Unsupported;
        resource.syncForGpu();
        if (resource.dma_fd == null)
            resource.dma_fd = self.session.dev.boExportDmaBuf(resource.bo) catch |err| return merr(err);
        return .{
            .fd = resource.dma_fd.?,
            .width = resource.width,
            .height = resource.height,
            .format = 0x3432_4241, // DRM_FORMAT_ABGR8888 (RGBA byte order)
            .stride = resource.row_stride,
            .offset = 0,
            .modifier = 0,
        };
    }

    fn createShaderModule(ptr: *anyopaque, desc: hal.ShaderModuleDesc) hal.Error!*hal.ShaderModule {
        const self: *Device = @ptrCast(@alignCast(ptr));
        return @ptrCast(try ShaderModule.create(self.gpa, desc));
    }

    fn destroyShaderModule(ptr: *anyopaque, handle: *hal.ShaderModule) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const module: *ShaderModule = @ptrCast(@alignCast(handle));
        module.destroy(self.gpa);
    }

    fn dispatchCompute(ptr: *anyopaque, dispatch: hal.ComputeDispatch) hal.Error!void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const module: *ShaderModule = @ptrCast(@alignCast(dispatch.shader));
        if (module.stage != .compute or dispatch.buffers.len > 64 or
            (module.code.len >= 4 and std.mem.readInt(u32, module.code[0..4], .little) == 0x0723_0203))
            return error.Unsupported;
        var kernel = mali.ComputeKernel.create(&self.session, module.code, 32, 0) catch |err| return merr(err);
        defer kernel.deinit(&self.session);
        var bos: [64]mali.Bo = undefined;
        for (dispatch.buffers, 0..) |handle, i| {
            const resource: *Resource = @ptrCast(@alignCast(handle));
            if (resource.kind != .buffer) return error.InvalidArgument;
            bos[i] = resource.bo;
        }
        mali.compute.dispatchBuffers(&self.session, kernel, bos[0..dispatch.buffers.len], .{
            .x = dispatch.groups[0],
            .y = dispatch.groups[1],
            .z = dispatch.groups[2],
        }, 5_000_000_000) catch |err| return merr(err);
    }

    fn createPipeline(ptr: *anyopaque, desc: hal.PipelineDesc) hal.Error!*hal.Pipeline {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const pipeline = self.gpa.create(Pipeline) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(pipeline);
        pipeline.* = try Pipeline.create(&self.session, self.gpa, desc);
        return @ptrCast(pipeline);
    }

    fn destroyPipeline(ptr: *anyopaque, handle: *hal.Pipeline) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const pipeline: *Pipeline = @ptrCast(@alignCast(handle));
        pipeline.deinit(&self.session);
        self.gpa.destroy(pipeline);
    }

    fn createSurface(ptr: *anyopaque, platform_surface: *anyopaque) hal.Error!*hal.Surface {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const surface = self.gpa.create(@import("surface.zig").Surface) catch return error.OutOfMemory;
        surface.* = .{ .platform = @ptrCast(@alignCast(platform_surface)) };
        return @ptrCast(surface);
    }

    fn destroySurface(ptr: *anyopaque, handle: *hal.Surface) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        self.gpa.destroy(@as(*@import("surface.zig").Surface, @ptrCast(@alignCast(handle))));
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const gpa = self.gpa;
        self.session.deinit();
        gpa.destroy(self);
    }

    pub const vtable = hal.Device.VTable{
        .caps = &caps,
        .createContext = &createContext,
        .createResource = &createResource,
        .destroyResource = &destroyResource,
        .mapResource = &mapResource,
        .unmapResource = &unmapResource,
        .exportResource = &exportResource,
        .createShaderModule = &createShaderModule,
        .destroyShaderModule = &destroyShaderModule,
        .dispatchCompute = &dispatchCompute,
        .createPipeline = &createPipeline,
        .destroyPipeline = &destroyPipeline,
        .createSurface = &createSurface,
        .destroySurface = &destroySurface,
        .deinit = &deinit,
    };
};

/// Panthor's exclusive-VM BO optimization is incompatible with PRIME export.
/// Prism may present any image through dma-buf even when its caller did not
/// predict that at resource creation, so images must be shareable from birth.
/// Ordinary buffers retain the private fast path.
fn allocationOptions(desc: hal.ResourceDesc) mali.BoOptions {
    return switch (desc) {
        .buffer => .{},
        .image => .{ .exportable = true },
    };
}

test "Mali capability set exposes the validated native graphics subset" {
    var shell: Device = undefined;
    shell.session.info.name = "Mali test";
    const c = Device.caps(&shell);
    try std.testing.expect(c.compute and c.present);
    try std.testing.expect(c.graphics and c.spirv);
    try std.testing.expectEqual(hal.Format.rgba8_unorm, c.formats[0]);
}

test "Mali images are PRIME-exportable while buffers remain private" {
    try std.testing.expect(!allocationOptions(.{ .buffer = .{ .size = 16 } }).exportable);
    try std.testing.expect(allocationOptions(.{ .image = .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
    } }).exportable);
}
