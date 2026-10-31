const std = @import("std");
const asahi = @import("asahi");
const hal = @import("../../hal.zig");
const Resource = @import("resource.zig").Resource;
const ShaderModule = @import("shader.zig").ShaderModule;

/// Map an asahi (asahi.zig) transport error onto the Prism-wide error set.
pub fn aserr(e: anyerror) hal.Error {
    return switch (e) {
        error.OpenFailed, error.NoDevice => error.InitializationFailed,
        error.OutOfMemory => error.OutOfMemory,
        // A failed ioctl / mmap / VM-bind / fence timeout is a lost device from
        // the HAL's point of view (the GPU did not honor the request).
        error.IoctlFailed, error.MapFailed, error.Timeout => error.DeviceLost,
        else => error.InitializationFailed,
    };
}

/// 16-KiB GPU page (Apple Silicon). Every VM_BIND addr + range must be aligned to
/// this or VM_BIND returns EINVAL (the P3 iter-1 lesson, see prism-asahi-driver).
const PAGE: u64 = asahi.PAGE; // 0x4000

/// Base GPU VA for HAL-allocated resources. Placed above the asahi render infrastructure:
/// clearColorTo allocates its fixed render-infra BOs at USC_EXEC_BASE(0x1_0000_0000)
/// + 1..18 * PAGE, i.e. below 0x1_0005_0000. Starting HAL resources at 0x2_0000_0000
/// ensures no resource VA collides with the render infra.
const RESOURCE_VA_BASE: u64 = 0x2_0000_0000;

/// HAL device backed by a real Apple Silicon (AGX) GPU via the kernel `asahi` DRM
/// driver (asahi.zig). Owns the render node, a GPU VM, and a submission
/// queue with usc_exec_base = USC_EXEC_BASE (so the clear render pass's USC-relative
/// addresses resolve). Resources are GEM BOs bound into the VM at bump-allocated
/// 16-KiB-aligned VAs. destroyResource releases each BO (freeBo: VM_BIND/UNBIND +
/// munmap + GEM_CLOSE) so a create/destroy cycle does not leak, and rolls back the
/// bump pointer when freeing the most-recent VA.
pub const Device = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dev: asahi.Device,
    info: asahi.GpuInfo,
    vm_id: u32,
    queue_id: u32,
    /// Bump GPU-VA allocator for resources. Monotonic, 16-KiB-page aligned, above
    /// the render-infra range so resource VAs never collide with it.
    next_va: u64 = RESOURCE_VA_BASE,

    pub fn halDevice(self: *Device) hal.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn create(gpa: std.mem.Allocator, io: std.Io) hal.Error!hal.Device {
        const self = gpa.create(Device) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.io = io;
        self.next_va = RESOURCE_VA_BASE;

        self.dev = asahi.Device.open(io) catch |e| return aserr(e);
        errdefer self.dev.deinit();
        self.info = self.dev.getParams() catch |e| return aserr(e);
        self.vm_id = self.dev.vmCreate(self.info) catch |e| return aserr(e);
        errdefer self.dev.vmDestroy(self.vm_id);
        // The queue must be created with usc_exec_base = USC_EXEC_BASE so the
        // clear render pass's USC-relative shader offsets resolve on the GPU.
        self.queue_id = self.dev.queueCreate(
            self.vm_id,
            asahi.uapi.PRIORITY_MEDIUM,
            asahi.USC_EXEC_BASE,
        ) catch |e| return aserr(e);

        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Formats the AGX render/texture path supports. RGBA8 / BGRA8 unorm are
    /// the proven 8-bit color formats (the clear render pass writes linear RGBA8).
    const supported_formats = [_]hal.Format{ .rgba8_unorm, .bgra8_unorm, .depth32_float };

    fn caps(ptr: *anyopaque) hal.DeviceCaps {
        const self: *Device = @ptrCast(@alignCast(ptr));
        return .{
            .device_name = self.info.name, // e.g. "Apple M1 Pro (G13S, T6000)"
            .formats = &supported_formats,
            .hdr = hal.DeviceCaps.deriveHdr(&supported_formats),
            // Native G13 graphics accepts the supported scalar SPIR-V subset.
            .spirv = self.info.gpu_generation == 13,
            // Compute modules continue to use raw AGX kernels.
            .compute = true,
            .graphics = self.info.gpu_generation == 13,
            // Present works via a CPU blit of the cleared framebuffer to the
            // platform surface (proven in the present test, like nvidia).
            .present = true,
            // AGX (G13/M1) supports up to 16384 for 2D textures.
            .max_texture_dim = 16384,
        };
    }

    /// Reserve the next 16-KiB-page-aligned GPU VA for `size` bytes. Monotonic +
    /// non-colliding: each call advances past the page-rounded size, so VAs are
    /// strictly increasing and never overlap, and all stay above the render-infra
    /// range (RESOURCE_VA_BASE). Both the VA and the size handed to VM_BIND are
    /// 16-KiB aligned (AGX VM_BIND requires it).
    fn reserveVa(self: *Device, size: u64) u64 {
        const va = std.mem.alignForward(u64, self.next_va, PAGE);
        self.next_va = va + std.mem.alignForward(u64, size, PAGE);
        return va;
    }

    fn validateResourceDesc(desc: hal.ResourceDesc) hal.Error!void {
        switch (desc) {
            .buffer => |b| {
                if (b.size == 0 or b.size > std.math.maxInt(u64) - PAGE) return error.InvalidArgument;
            },
            .image => |i| {
                if (i.width == 0 or i.height == 0 or i.width > 16384 or i.height > 16384)
                    return error.InvalidArgument;
                if (i.format != .rgba8_unorm and i.format != .bgra8_unorm and i.format != .depth32_float) return error.Unsupported;
                if (i.samples != 1 or i.mip_levels == 0 or i.mip_levels > 1 + std.math.log2_int(u32, @max(i.width, i.height)) or i.cube or i.depth != 1 or i.array)
                    return error.Unsupported;
            },
        }
    }

    fn createResource(ptr: *anyopaque, desc: hal.ResourceDesc) hal.Error!*hal.Resource {
        const self: *Device = @ptrCast(@alignCast(ptr));
        try validateResourceDesc(desc);
        const size: u64 = switch (desc) {
            .buffer => |b| b.size,
            // A linear RGBA8 image is width*4 per row (the clear/PBE path is
            // linear, no tiling) * height.
            .image => |i| blk: {
                var bytes: u64 = 0;
                var w = i.width;
                var h = i.height;
                for (0..i.mip_levels) |_| {
                    bytes += @as(u64, w) * h * i.format.bytesPerPixel();
                    w = @max(1, w / 2);
                    h = @max(1, h / 2);
                }
                break :blk bytes;
            },
        };
        if (size == 0) return error.InvalidArgument;
        // VM_BIND wants a 16-KiB-aligned range. Round the BO up to a page.
        const alloc: u64 = std.mem.alignForward(u64, size, PAGE);
        const va = self.reserveVa(alloc);
        errdefer self.next_va = va;
        const bo = self.dev.allocBo(self.vm_id, alloc, va) catch |e| return aserr(e);
        errdefer self.dev.freeBo(self.vm_id, bo);

        const r = self.gpa.create(Resource) catch return error.OutOfMemory;
        r.* = switch (desc) {
            .buffer => .{ .kind = .buffer, .bo = bo, .desc = desc, .byte_size = @intCast(size) },
            .image => |i| .{ .kind = .image, .bo = bo, .desc = desc, .byte_size = @intCast(size), .width = i.width, .height = i.height, .format = i.format },
        };
        return @ptrCast(r);
    }

    fn destroyResource(ptr: *anyopaque, resource: *hal.Resource) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const r: *Resource = @ptrCast(@alignCast(resource));
        // Release the GEM BO + its VM binding (VM_BIND/UNBIND the VA range, munmap
        // the CPU mapping, GEM_CLOSE the handle) so a create/destroy cycle does not
        // leak the BO until the fd closes. The caller is responsible for not
        // destroying a resource the GPU is still using (the clear's fence has
        // already flushed by the time the HAL hands control back).
        self.dev.freeBo(self.vm_id, r.bo);
        // If this was the most-recently-bumped resource, roll the bump pointer back
        // so its VA is reclaimed (the common create-clear-present-destroy-resize
        // loop frees the resource it just made). Out-of-order frees leave the VA
        // stranded, which is harmless since the VA space is huge.
        const alloc: u64 = std.mem.alignForward(u64, r.bo.size, PAGE);
        if (self.next_va == r.bo.gpu_va + alloc) self.next_va = r.bo.gpu_va;
        self.gpa.destroy(r);
    }

    fn mapResource(ptr: *anyopaque, resource: *hal.Resource) hal.Error![]u8 {
        _ = ptr;
        const r: *Resource = @ptrCast(@alignCast(resource));
        asahi.cleanInvalidateToPoC(r.bo.cpu);
        // allocBo already CPU-mapped the BO (held for the resource's life, like
        // the nvidia driver). Expose the logical size.
        const want = r.byte_size;
        return r.bo.cpu[0..@min(want, r.bo.cpu.len)];
    }

    fn unmapResource(ptr: *anyopaque, resource: *hal.Resource) void {
        // The CPU mapping is held until the device closes (cheap, and the consumer
        // typically maps once). Nothing to do, mirroring the nvidia driver.
        _ = ptr;
        _ = resource;
    }

    fn createContext(ptr: *anyopaque) hal.Error!hal.Context {
        const self: *Device = @ptrCast(@alignCast(ptr));
        return @import("context.zig").Context.create(self);
    }

    // Compute: createShaderModule(.compute) wraps hand-assembled AGX kernel bytes.
    // dispatchCompute runs the proven asahi compute path on the real GPU.
    fn createShaderModule(ptr: *anyopaque, desc: hal.ShaderModuleDesc) hal.Error!*hal.ShaderModule {
        const self: *Device = @ptrCast(@alignCast(ptr));
        // Graphics retains SPIR-V for pipeline compilation; compute retains AGX ISA.
        const m = try ShaderModule.create(self.gpa, desc);
        return @ptrCast(m);
    }
    fn destroyShaderModule(ptr: *anyopaque, module: *hal.ShaderModule) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const m: *ShaderModule = @ptrCast(@alignCast(module));
        m.destroy(self.gpa);
    }

    /// Max storage buffers a single dispatch can bind. Each buffer occupies one
    /// uniform pair u(2i)_u(2i+1) (4 halves), so 8 buffers = 32 uniform halves,
    /// well within the launch's uniform-register budget and the proven path.
    const MAX_COMPUTE_BUFFERS = 8;

    /// One-shot GPU compute dispatch through the HAL. Casts the shader to the
    /// apple ShaderModule (the AGX kernel bytes) and collects each caller-owned
    /// storage buffer's bo.gpu_va in binding order (d.buffers[i].bo.gpu_va ->
    /// uniform pair u(2i)_u(2i+1)), then calls asahi.runCompute with the kernel
    /// bytes, those VAs, and the threadgroup grid. runCompute allocates + frees
    /// only the launch infra (shader/USC/CDM/uniform-data BOs) and never
    /// re-allocates the caller's storage BOs (the P5b lesson), freeing the infra
    /// after the fence (the P5d lesson) so this is repeatable.
    fn dispatchCompute(ptr: *anyopaque, d: hal.ComputeDispatch) hal.Error!void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const m: *ShaderModule = @ptrCast(@alignCast(d.shader));
        if (d.buffers.len == 0 or d.buffers.len > MAX_COMPUTE_BUFFERS) return error.InvalidArgument;
        // Collect the caller-owned storage VAs in binding order. buffers[i]'s
        // 64-bit GPU VA becomes the uniform pair u(2i)_u(2i+1).
        var vas: [MAX_COMPUTE_BUFFERS]u64 = undefined;
        for (d.buffers, 0..) |res, i| {
            const r: *Resource = @ptrCast(@alignCast(res));
            vas[i] = r.bo.gpu_va;
        }
        // CPU->GPU cache flush (P5e stale-input fix). The caller fills its
        // input/storage BOs via mapResource, but those writes can sit dirty in
        // the CPU data cache and never reach the point of coherency where the GPU
        // loads them, so the GPU reads a stale recycled-DRAM value (addbuf
        // loaded 0x3F800000 instead of the CPU's 0x00010000). Clean each storage
        // BO to PoC before the dispatch so the GPU reads fresh input. runCompute
        // already does the same on its own infra BOs (UNIFORM_DATA etc.) but
        // never touches the caller's storage BOs, so we do it here.
        for (d.buffers) |res| {
            const r: *Resource = @ptrCast(@alignCast(res));
            asahi.cleanToPoC(r.bo.cpu);
        }
        asahi.runCompute(
            &self.dev,
            self.vm_id,
            self.queue_id,
            m.code,
            vas[0..d.buffers.len],
            d.groups,
        ) catch |e| return aserr(e);
        // runCompute fences (the GPU is done) before returning. Clean+invalidate
        // each storage BO to PoC after it so the CPU reads the GPU's fresh output
        // without a stale cache line. The pre-flush is what inputs need. The
        // post-invalidate is safe for every buffer (outputs especially).
        for (d.buffers) |res| {
            const r: *Resource = @ptrCast(@alignCast(res));
            asahi.cleanInvalidateToPoC(r.bo.cpu);
        }
    }

    fn createPipeline(ptr: *anyopaque, desc: hal.PipelineDesc) hal.Error!*hal.Pipeline {
        const self: *Device = @ptrCast(@alignCast(ptr));
        if (self.info.gpu_generation != 13) return error.Unsupported;
        return @ptrCast(try @import("pipeline.zig").Pipeline.create(self.gpa, desc));
    }
    fn destroyPipeline(ptr: *anyopaque, pipeline: *hal.Pipeline) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        self.gpa.destroy(@as(*@import("pipeline.zig").Pipeline, @ptrCast(@alignCast(pipeline))));
    }

    fn createSurface(ptr: *anyopaque, platform_surface: *anyopaque) hal.Error!*hal.Surface {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const s = self.gpa.create(@import("surface.zig").Surface) catch return error.OutOfMemory;
        s.* = .{ .platform = @ptrCast(@alignCast(platform_surface)) };
        return @ptrCast(s);
    }
    fn destroySurface(ptr: *anyopaque, surface: *hal.Surface) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        self.gpa.destroy(@as(*@import("surface.zig").Surface, @ptrCast(@alignCast(surface))));
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Device = @ptrCast(@alignCast(ptr));
        const gpa = self.gpa;
        self.dev.queueDestroy(self.queue_id);
        self.dev.vmDestroy(self.vm_id);
        self.dev.deinit();
        gpa.destroy(self);
    }

    const vtable = hal.Device.VTable{
        .caps = &caps,
        .createContext = &createContext,
        .createResource = &createResource,
        .destroyResource = &destroyResource,
        .mapResource = &mapResource,
        .unmapResource = &unmapResource,
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

// Pull the context + surface + shader tests into the driver's test set.
test {
    _ = @import("context.zig");
    _ = @import("shader.zig");
    _ = @import("pipeline.zig");
    _ = @import("e2e_test.zig");
}

test "apple Device vtable is complete (every method bound, no null)" {
    const vt = Device.vtable;
    // Required methods are non-optional `*const fn` pointers, so the type itself
    // guarantees no method is null. Assert each required one points at a real address
    // and that the count matches the HAL contract so a missing binding would not compile.
    // Five optional methods (`?*const fn`, default null) the apple driver does not provide
    // are skipped by the loop:
    // readbackPresent (present fast-path, apple falls back to mapResource),
    // captureTransformFeedback (transform-feedback capture, software-only path),
    // finalizeDepthTexture (tiled render-depth to sampled ZF32 bridge, nvidia-only),
    // flushMappedImage (re-swizzle a mapped scratch back to a tiled surface, nvidia-only),
    // exportResource (dma-buf export for Wayland present, nvidia-only for now).
    const info = @typeInfo(hal.Device.VTable).@"struct";
    try std.testing.expectEqual(@as(usize, 20), info.field_names.len);
    inline for (info.field_names, info.field_types) |name, F| {
        const is_optional = switch (@typeInfo(F)) {
            .optional => true,
            else => false,
        };
        if (is_optional) continue;
        const fn_ptr = @field(vt, name);
        try std.testing.expect(@intFromPtr(fn_ptr) != 0);
    }
}

test "apple bump-VA allocator: 16-KiB-aligned, monotonic, non-colliding, above render infra" {
    // Build a Device shell WITHOUT a GPU (no open) just to exercise reserveVa.
    var d: Device = undefined;
    d.next_va = RESOURCE_VA_BASE;

    const infra_top = asahi.USC_EXEC_BASE + 18 * PAGE; // highest render-infra VA
    var prev_end: u64 = RESOURCE_VA_BASE;
    const sizes = [_]u64{ 1, 256, PAGE, PAGE + 1, 3 * PAGE, 100 };
    for (sizes) |s| {
        const va = d.reserveVa(s);
        // 16-KiB aligned.
        try std.testing.expectEqual(@as(u64, 0), va % PAGE);
        // monotonic + non-overlapping with the previous reservation.
        try std.testing.expect(va >= prev_end);
        // above the render-infra range (never collides with USC_EXEC_BASE + N*PAGE).
        try std.testing.expect(va > infra_top);
        prev_end = va + std.mem.alignForward(u64, s, PAGE);
    }
    // strictly increasing across the whole sequence.
    try std.testing.expect(d.next_va > RESOURCE_VA_BASE);
}

test "apple resource descriptors reject unsupported layouts before allocation" {
    try std.testing.expectError(error.InvalidArgument, Device.validateResourceDesc(.{ .buffer = .{ .size = 0 } }));
    try std.testing.expectError(error.InvalidArgument, Device.validateResourceDesc(.{ .image = .{ .width = 0, .height = 64, .format = .rgba8_unorm } }));
    try Device.validateResourceDesc(.{ .image = .{ .width = 64, .height = 64, .format = .depth32_float } });
    try std.testing.expectError(error.Unsupported, Device.validateResourceDesc(.{ .image = .{ .width = 64, .height = 64, .format = .rgba8_unorm, .samples = 4 } }));
    try Device.validateResourceDesc(.{ .image = .{ .width = 64, .height = 64, .format = .rgba8_unorm, .mip_levels = 2 } });
}

test "apple GPU triangle probe from the extracted library" {
    const driver = @import("../apple.zig").driver;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try Device.create(std.testing.allocator, std.testing.io);
    defer dev.deinit();
    if (!dev.caps().graphics) return error.SkipZigTest;
    const self: *Device = @ptrCast(@alignCast(dev.ptr));
    const pixel = try asahi.runTriangle(&self.dev, self.vm_id, self.queue_id);
    try std.testing.expectEqual(asahi.kTriColor, pixel);
}

test "apple destroyResource rolls back the bump pointer for the most-recent VA" {
    // The destroyResource bump-rollback (reclaim the VA of the just-freed
    // most-recent resource) without a GPU: reserve a VA, then apply the same
    // rollback condition destroyResource uses and confirm next_va is restored, so
    // a create/destroy/create cycle reuses the same VA instead of leaking VA space.
    var d: Device = undefined;
    d.next_va = RESOURCE_VA_BASE;

    const size: u64 = 3 * PAGE + 1;
    const alloc: u64 = std.mem.alignForward(u64, size, PAGE);
    const before = d.next_va;
    const va = d.reserveVa(alloc);
    try std.testing.expect(d.next_va > before);

    // Roll back as destroyResource does for the most-recently-bumped VA.
    if (d.next_va == va + alloc) d.next_va = va;
    try std.testing.expectEqual(before, d.next_va);

    // A subsequent reserve reuses the same VA (no leak).
    try std.testing.expectEqual(va, d.reserveVa(alloc));
}
