//! Vulkan-backed Prism HAL device.
//!
//! Rendering uses ordinary Vulkan images on Android, Linux, macOS, and Windows. Android
//! presentation blits the completed image directly into an ANativeWindow
//! swapchain without a CPU readback; Linux is currently headless-only.
const std = @import("std");
const builtin = @import("builtin");
const hal = @import("../../hal.zig");

const vk = @import("vulkan-zig");

extern "vulkan" fn vkCreateInstance(*const vk.InstanceCreateInfo, ?*const vk.AllocationCallbacks, *vk.Instance) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyInstance(vk.Instance, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkEnumeratePhysicalDevices(vk.Instance, *u32, ?[*]vk.PhysicalDevice) callconv(.c) vk.Result;
extern "vulkan" fn vkGetPhysicalDeviceQueueFamilyProperties(vk.PhysicalDevice, *u32, ?[*]vk.QueueFamilyProperties) callconv(.c) void;
extern "vulkan" fn vkGetPhysicalDeviceProperties(vk.PhysicalDevice, *vk.PhysicalDeviceProperties) callconv(.c) void;
extern "vulkan" fn vkGetPhysicalDeviceMemoryProperties(vk.PhysicalDevice, *vk.PhysicalDeviceMemoryProperties) callconv(.c) void;
extern "vulkan" fn vkCreateDevice(vk.PhysicalDevice, *const vk.DeviceCreateInfo, ?*const vk.AllocationCallbacks, *vk.Device) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyDevice(vk.Device, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkGetDeviceQueue(vk.Device, u32, u32, *vk.Queue) callconv(.c) void;
extern "vulkan" fn vkDeviceWaitIdle(vk.Device) callconv(.c) vk.Result;
extern "vulkan" fn vkQueueWaitIdle(vk.Queue) callconv(.c) vk.Result;
extern "vulkan" fn vkCreateCommandPool(vk.Device, *const vk.CommandPoolCreateInfo, ?*const vk.AllocationCallbacks, *vk.CommandPool) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyCommandPool(vk.Device, vk.CommandPool, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkResetCommandPool(vk.Device, vk.CommandPool, vk.CommandPoolResetFlags) callconv(.c) vk.Result;
extern "vulkan" fn vkAllocateCommandBuffers(vk.Device, *const vk.CommandBufferAllocateInfo, *vk.CommandBuffer) callconv(.c) vk.Result;
extern "vulkan" fn vkBeginCommandBuffer(vk.CommandBuffer, *const vk.CommandBufferBeginInfo) callconv(.c) vk.Result;
extern "vulkan" fn vkEndCommandBuffer(vk.CommandBuffer) callconv(.c) vk.Result;
extern "vulkan" fn vkQueueSubmit(vk.Queue, u32, [*]const vk.SubmitInfo, vk.Fence) callconv(.c) vk.Result;
extern "vulkan" fn vkCreateRenderPass(vk.Device, *const vk.RenderPassCreateInfo, ?*const vk.AllocationCallbacks, *vk.RenderPass) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyRenderPass(vk.Device, vk.RenderPass, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateDescriptorSetLayout(vk.Device, *const vk.DescriptorSetLayoutCreateInfo, ?*const vk.AllocationCallbacks, *vk.DescriptorSetLayout) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyDescriptorSetLayout(vk.Device, vk.DescriptorSetLayout, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreatePipelineLayout(vk.Device, *const vk.PipelineLayoutCreateInfo, ?*const vk.AllocationCallbacks, *vk.PipelineLayout) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyPipelineLayout(vk.Device, vk.PipelineLayout, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateSampler(vk.Device, *const vk.SamplerCreateInfo, ?*const vk.AllocationCallbacks, *vk.Sampler) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroySampler(vk.Device, vk.Sampler, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateBuffer(vk.Device, *const vk.BufferCreateInfo, ?*const vk.AllocationCallbacks, *vk.Buffer) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyBuffer(vk.Device, vk.Buffer, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkGetBufferMemoryRequirements(vk.Device, vk.Buffer, *vk.MemoryRequirements) callconv(.c) void;
extern "vulkan" fn vkAllocateMemory(vk.Device, *const vk.MemoryAllocateInfo, ?*const vk.AllocationCallbacks, *vk.DeviceMemory) callconv(.c) vk.Result;
extern "vulkan" fn vkFreeMemory(vk.Device, vk.DeviceMemory, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkBindBufferMemory(vk.Device, vk.Buffer, vk.DeviceMemory, vk.DeviceSize) callconv(.c) vk.Result;
extern "vulkan" fn vkMapMemory(vk.Device, vk.DeviceMemory, vk.DeviceSize, vk.DeviceSize, vk.MemoryMapFlags, *?*anyopaque) callconv(.c) vk.Result;
extern "vulkan" fn vkUnmapMemory(vk.Device, vk.DeviceMemory) callconv(.c) void;
extern "vulkan" fn vkCreateImage(vk.Device, *const vk.ImageCreateInfo, ?*const vk.AllocationCallbacks, *vk.Image) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyImage(vk.Device, vk.Image, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkGetImageMemoryRequirements(vk.Device, vk.Image, *vk.MemoryRequirements) callconv(.c) void;
extern "vulkan" fn vkBindImageMemory(vk.Device, vk.Image, vk.DeviceMemory, vk.DeviceSize) callconv(.c) vk.Result;
extern "vulkan" fn vkCreateImageView(vk.Device, *const vk.ImageViewCreateInfo, ?*const vk.AllocationCallbacks, *vk.ImageView) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyImageView(vk.Device, vk.ImageView, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateShaderModule(vk.Device, *const vk.ShaderModuleCreateInfo, ?*const vk.AllocationCallbacks, *vk.ShaderModule) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyShaderModule(vk.Device, vk.ShaderModule, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateGraphicsPipelines(vk.Device, vk.PipelineCache, u32, [*]const vk.GraphicsPipelineCreateInfo, ?*const vk.AllocationCallbacks, [*]vk.Pipeline) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyPipeline(vk.Device, vk.Pipeline, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateFramebuffer(vk.Device, *const vk.FramebufferCreateInfo, ?*const vk.AllocationCallbacks, *vk.Framebuffer) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyFramebuffer(vk.Device, vk.Framebuffer, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCreateDescriptorPool(vk.Device, *const vk.DescriptorPoolCreateInfo, ?*const vk.AllocationCallbacks, *vk.DescriptorPool) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroyDescriptorPool(vk.Device, vk.DescriptorPool, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkAllocateDescriptorSets(vk.Device, *const vk.DescriptorSetAllocateInfo, [*]vk.DescriptorSet) callconv(.c) vk.Result;
extern "vulkan" fn vkUpdateDescriptorSets(vk.Device, u32, [*]const vk.WriteDescriptorSet, u32, ?*const vk.CopyDescriptorSet) callconv(.c) void;
extern "vulkan" fn vkCmdPipelineBarrier(vk.CommandBuffer, vk.PipelineStageFlags, vk.PipelineStageFlags, vk.DependencyFlags, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, [*]const vk.ImageMemoryBarrier) callconv(.c) void;
extern "vulkan" fn vkCmdCopyBufferToImage(vk.CommandBuffer, vk.Buffer, vk.Image, vk.ImageLayout, u32, [*]const vk.BufferImageCopy) callconv(.c) void;
extern "vulkan" fn vkCmdCopyImageToBuffer(vk.CommandBuffer, vk.Image, vk.ImageLayout, vk.Buffer, u32, [*]const vk.BufferImageCopy) callconv(.c) void;
extern "vulkan" fn vkCmdBeginRenderPass(vk.CommandBuffer, *const vk.RenderPassBeginInfo, vk.SubpassContents) callconv(.c) void;
extern "vulkan" fn vkCmdEndRenderPass(vk.CommandBuffer) callconv(.c) void;
extern "vulkan" fn vkCmdSetViewport(vk.CommandBuffer, u32, u32, [*]const vk.Viewport) callconv(.c) void;
extern "vulkan" fn vkCmdSetScissor(vk.CommandBuffer, u32, u32, [*]const vk.Rect2D) callconv(.c) void;
extern "vulkan" fn vkCmdBindPipeline(vk.CommandBuffer, vk.PipelineBindPoint, vk.Pipeline) callconv(.c) void;
extern "vulkan" fn vkCmdBindVertexBuffers(vk.CommandBuffer, u32, u32, [*]const vk.Buffer, [*]const vk.DeviceSize) callconv(.c) void;
extern "vulkan" fn vkCmdBindDescriptorSets(vk.CommandBuffer, vk.PipelineBindPoint, vk.PipelineLayout, u32, u32, [*]const vk.DescriptorSet, u32, ?[*]const u32) callconv(.c) void;
extern "vulkan" fn vkCmdDraw(vk.CommandBuffer, u32, u32, u32, u32) callconv(.c) void;
extern "vulkan" fn vkCreateAndroidSurfaceKHR(vk.Instance, *const vk.AndroidSurfaceCreateInfoKHR, ?*const vk.AllocationCallbacks, *vk.SurfaceKHR) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroySurfaceKHR(vk.Instance, vk.SurfaceKHR, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkGetPhysicalDeviceSurfaceSupportKHR(vk.PhysicalDevice, u32, vk.SurfaceKHR, *vk.Bool32) callconv(.c) vk.Result;
extern "vulkan" fn vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vk.PhysicalDevice, vk.SurfaceKHR, *vk.SurfaceCapabilitiesKHR) callconv(.c) vk.Result;
extern "vulkan" fn vkGetPhysicalDeviceSurfaceFormatsKHR(vk.PhysicalDevice, vk.SurfaceKHR, *u32, ?[*]vk.SurfaceFormatKHR) callconv(.c) vk.Result;
extern "vulkan" fn vkCreateSwapchainKHR(vk.Device, *const vk.SwapchainCreateInfoKHR, ?*const vk.AllocationCallbacks, *vk.SwapchainKHR) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroySwapchainKHR(vk.Device, vk.SwapchainKHR, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkGetSwapchainImagesKHR(vk.Device, vk.SwapchainKHR, *u32, ?[*]vk.Image) callconv(.c) vk.Result;
extern "vulkan" fn vkAcquireNextImageKHR(vk.Device, vk.SwapchainKHR, u64, vk.Semaphore, vk.Fence, *u32) callconv(.c) vk.Result;
extern "vulkan" fn vkQueuePresentKHR(vk.Queue, *const vk.PresentInfoKHR) callconv(.c) vk.Result;
extern "vulkan" fn vkCreateSemaphore(vk.Device, *const vk.SemaphoreCreateInfo, ?*const vk.AllocationCallbacks, *vk.Semaphore) callconv(.c) vk.Result;
extern "vulkan" fn vkDestroySemaphore(vk.Device, vk.Semaphore, ?*const vk.AllocationCallbacks) callconv(.c) void;
extern "vulkan" fn vkCmdBlitImage(vk.CommandBuffer, vk.Image, vk.ImageLayout, vk.Image, vk.ImageLayout, u32, [*]const vk.ImageBlit, vk.Filter) callconv(.c) void;

const formats = [_]hal.Format{ .rgba8_unorm, .bgra8_unorm };

pub const Device = struct {
    gpa: std.mem.Allocator,
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    queue: vk.Queue,
    queue_family: u32,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    command_pool: vk.CommandPool,
    render_pass: vk.RenderPass,
    descriptor_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    linear_sampler: vk.Sampler,
    nearest_sampler: vk.Sampler,

    const ResourceKind = enum { buffer, image };
    const Resource = struct {
        owner: *Device,
        kind: ResourceKind,
        buffer: vk.Buffer,
        buffer_memory: vk.DeviceMemory,
        mapped: [*]u8,
        size: usize,
        image: vk.Image = .null,
        image_memory: vk.DeviceMemory = .null,
        image_view: vk.ImageView = .null,
        coverage_view: vk.ImageView = .null,
        width: u32 = 0,
        height: u32 = 0,
        format: hal.Format = .rgba8_unorm,
        layout: vk.ImageLayout = .undefined,
        cpu_dirty: bool = false,
        gpu_dirty: bool = false,
    };

    const Shader = struct { owner: *Device, handle: vk.ShaderModule, stage: hal.ShaderStage };
    const Pipeline = struct { owner: *Device, handle: vk.Pipeline };
    const PresentSurface = struct {
        owner: *Device,
        handle: vk.SurfaceKHR,
        swapchain: vk.SwapchainKHR = .null,
        format: vk.SurfaceFormatKHR = undefined,
        extent: vk.Extent2D = .{ .width = 0, .height = 0 },
        images: []vk.Image = &.{},
        layouts: []vk.ImageLayout = &.{},
        image_available: vk.Semaphore = .null,
        render_finished: vk.Semaphore = .null,
        needs_rebuild: bool = true,
    };
    const Command = union(enum) {
        set_render_target: *Resource,
        clear: hal.Color,
        bind_pipeline: *Pipeline,
        bind_vertex_buffer: *Resource,
        bind_texture: hal.TextureBinding,
        set_scissor: ?hal.ScissorRect,
        draw: struct { count: u32, first: u32 },
    };

    const RecordedCommands = struct {
        gpa: std.mem.Allocator,
        commands: std.ArrayListUnmanaged(Command) = .empty,

        fn append(self: *RecordedCommands, command: Command) hal.Error!void {
            self.commands.append(self.gpa, command) catch return error.OutOfMemory;
        }
        fn setRenderTarget(ptr: *anyopaque, target: *hal.Resource) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .set_render_target = resource(target) });
        }
        fn clear(ptr: *anyopaque, color: hal.Color) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .clear = color });
        }
        fn bindPipeline(ptr: *anyopaque, value: *hal.Pipeline) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .bind_pipeline = pipeline(value) });
        }
        fn bindVertexBuffer(ptr: *anyopaque, buffer: *hal.Resource) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .bind_vertex_buffer = resource(buffer) });
        }
        fn bindTexture(ptr: *anyopaque, binding: hal.TextureBinding) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .bind_texture = binding });
        }
        fn setScissor(ptr: *anyopaque, rect: ?hal.ScissorRect) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .set_scissor = rect });
        }
        fn draw(ptr: *anyopaque, count: u32, first: u32) hal.Error!void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            try self.append(.{ .draw = .{ .count = count, .first = first } });
        }
        fn reset(ptr: *anyopaque) void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            self.commands.clearRetainingCapacity();
        }
        fn deinit(ptr: *anyopaque) void {
            const self: *RecordedCommands = @ptrCast(@alignCast(ptr));
            const gpa = self.gpa;
            self.commands.deinit(gpa);
            gpa.destroy(self);
        }
        const vtable = hal.CommandBuffer.VTable{
            .setRenderTarget = &setRenderTarget,
            .clear = &clear,
            .bindPipeline = &bindPipeline,
            .bindVertexBuffer = &bindVertexBuffer,
            .bindTexture = &bindTexture,
            .draw = &draw,
            .setScissor = &setScissor,
            .reset = &reset,
            .deinit = &RecordedCommands.deinit,
        };
    };

    const Context = struct {
        owner: *Device,
        fn beginCommands(ptr: *anyopaque) hal.Error!hal.CommandBuffer {
            const self: *Context = @ptrCast(@alignCast(ptr));
            const commands = self.owner.gpa.create(RecordedCommands) catch return error.OutOfMemory;
            commands.* = .{ .gpa = self.owner.gpa };
            return .{ .ptr = commands, .vtable = &RecordedCommands.vtable };
        }
        fn submit(ptr: *anyopaque, command_buffer: hal.CommandBuffer) hal.Error!void {
            const self: *Context = @ptrCast(@alignCast(ptr));
            const commands: *RecordedCommands = @ptrCast(@alignCast(command_buffer.ptr));
            try self.owner.execute(commands.commands.items);
        }
        fn present(ptr: *anyopaque, opaque_surface: *hal.Surface, source: *hal.Resource) hal.Error!void {
            const self: *Context = @ptrCast(@alignCast(ptr));
            try self.owner.presentSurface(surface(opaque_surface), resource(source));
        }
        fn deinit(ptr: *anyopaque) void {
            const self: *Context = @ptrCast(@alignCast(ptr));
            self.owner.gpa.destroy(self);
        }
        const vtable = hal.Context.VTable{
            .beginCommands = &beginCommands,
            .submit = &submit,
            .present = &present,
            .deinit = &Context.deinit,
        };
    };

    pub fn create(gpa: std.mem.Allocator) hal.Error!hal.Device {
        const self = gpa.create(Device) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        var app_info: vk.ApplicationInfo = .{
            .p_application_name = "Prism",
            .application_version = 1,
            .p_engine_name = "Prism",
            .engine_version = 1,
            .api_version = vk.API_VERSION_1_0.toU32(),
        };
        const instance_extensions: []const [*:0]const u8 = if (builtin.abi.isAndroid())
            &.{ "VK_KHR_surface", "VK_KHR_android_surface" }
        else
            &.{};
        var instance_info: vk.InstanceCreateInfo = .{
            .flags = .{},
            .p_application_info = &app_info,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = instance_extensions.len,
            .pp_enabled_extension_names = instance_extensions.ptr,
        };
        var instance: vk.Instance = undefined;
        try check(vkCreateInstance(&instance_info, null, &instance));
        errdefer vkDestroyInstance(instance, null);

        var physical_count: u32 = 0;
        try check(vkEnumeratePhysicalDevices(instance, &physical_count, null));
        if (physical_count == 0) return error.Unsupported;
        const physicals = gpa.alloc(vk.PhysicalDevice, physical_count) catch return error.OutOfMemory;
        defer gpa.free(physicals);
        try check(vkEnumeratePhysicalDevices(instance, &physical_count, physicals.ptr));
        var physical: ?vk.PhysicalDevice = null;
        var family: u32 = 0;
        for (physicals[0..physical_count]) |candidate| {
            if (graphicsQueueFamily(gpa, candidate)) |candidate_family| {
                physical = candidate;
                family = candidate_family;
                break;
            }
        }
        const selected_physical = physical orelse return error.Unsupported;

        const priority: f32 = 1;
        var queue_info: vk.DeviceQueueCreateInfo = .{
            .flags = .{},
            .queue_family_index = family,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&priority),
        };
        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var device_info: vk.DeviceCreateInfo = .{
            .flags = .{},
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_info),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .p_enabled_features = null,
        };
        var logical: vk.Device = undefined;
        try check(vkCreateDevice(selected_physical, &device_info, null, &logical));
        errdefer vkDestroyDevice(logical, null);
        var queue: vk.Queue = undefined;
        vkGetDeviceQueue(logical, family, 0, &queue);
        var properties: vk.PhysicalDeviceProperties = undefined;
        vkGetPhysicalDeviceProperties(selected_physical, &properties);
        var memory_properties: vk.PhysicalDeviceMemoryProperties = undefined;
        vkGetPhysicalDeviceMemoryProperties(selected_physical, &memory_properties);
        self.* = .{
            .gpa = gpa,
            .instance = instance,
            .physical_device = selected_physical,
            .device = logical,
            .queue = queue,
            .queue_family = family,
            .properties = properties,
            .memory_properties = memory_properties,
            .command_pool = .null,
            .render_pass = .null,
            .descriptor_layout = .null,
            .pipeline_layout = .null,
            .linear_sampler = .null,
            .nearest_sampler = .null,
        };
        errdefer self.destroySharedObjects();
        try self.createSharedObjects();
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn createSharedObjects(self: *Device) hal.Error!void {
        var pool_info: vk.CommandPoolCreateInfo = .{
            .flags = .{ .reset_command_buffer = true },
            .queue_family_index = self.queue_family,
        };
        try check(vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
        var attachment: vk.AttachmentDescription = .{
            .flags = .{},
            .format = .r8g8b8a8_unorm,
            .samples = .{ .@"1" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .color_attachment_optimal,
            .final_layout = .color_attachment_optimal,
        };
        var color_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
        var subpass: vk.SubpassDescription = std.mem.zeroes(vk.SubpassDescription);
        subpass.pipeline_bind_point = .graphics;
        subpass.color_attachment_count = 1;
        subpass.p_color_attachments = @ptrCast(&color_ref);
        var render_pass_info: vk.RenderPassCreateInfo = .{
            .flags = .{},
            .attachment_count = 1,
            .p_attachments = @ptrCast(&attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 0,
            .p_dependencies = null,
        };
        try check(vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass));
        var descriptor_binding: vk.DescriptorSetLayoutBinding = .{
            .binding = 2,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment = true },
            .p_immutable_samplers = null,
        };
        var descriptor_info: vk.DescriptorSetLayoutCreateInfo = .{
            .flags = .{},
            .binding_count = 1,
            .p_bindings = @ptrCast(&descriptor_binding),
        };
        try check(vkCreateDescriptorSetLayout(self.device, &descriptor_info, null, &self.descriptor_layout));
        var pipeline_layout_info: vk.PipelineLayoutCreateInfo = .{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptor_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = null,
        };
        try check(vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout));
        self.linear_sampler = try self.createSampler(.linear);
        self.nearest_sampler = try self.createSampler(.nearest);
    }

    fn createSampler(self: *Device, filter: vk.Filter) hal.Error!vk.Sampler {
        var info: vk.SamplerCreateInfo = .{
            .flags = .{},
            .mag_filter = filter,
            .min_filter = filter,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .int_transparent_black,
            .unnormalized_coordinates = .false,
        };
        var sampler: vk.Sampler = .null;
        try check(vkCreateSampler(self.device, &info, null, &sampler));
        return sampler;
    }

    fn destroySharedObjects(self: *Device) void {
        if (self.nearest_sampler != .null) vkDestroySampler(self.device, self.nearest_sampler, null);
        if (self.linear_sampler != .null) vkDestroySampler(self.device, self.linear_sampler, null);
        if (self.pipeline_layout != .null) vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        if (self.descriptor_layout != .null) vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
        if (self.render_pass != .null) vkDestroyRenderPass(self.device, self.render_pass, null);
        if (self.command_pool != .null) vkDestroyCommandPool(self.device, self.command_pool, null);
    }

    fn graphicsQueueFamily(gpa: std.mem.Allocator, physical: vk.PhysicalDevice) ?u32 {
        var count: u32 = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, null);
        if (count == 0) return null;
        const properties = gpa.alloc(vk.QueueFamilyProperties, count) catch return null;
        defer gpa.free(properties);
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, properties.ptr);
        for (properties[0..count], 0..) |property, index| {
            if (property.queue_count > 0 and property.queue_flags.graphics) return @intCast(index);
        }
        return null;
    }
    fn check(result: vk.Result) hal.Error!void {
        return switch (result) {
            .success, .incomplete => {},
            .error_out_of_host_memory, .error_out_of_device_memory => error.OutOfMemory,
            .error_device_lost => error.DeviceLost,
            .error_feature_not_present, .error_extension_not_present, .error_format_not_supported => error.Unsupported,
            else => error.InitializationFailed,
        };
    }
    fn cast(ptr: *anyopaque) *Device {
        return @ptrCast(@alignCast(ptr));
    }
    fn resource(value: *hal.Resource) *Resource {
        return @ptrCast(@alignCast(value));
    }
    fn surface(value: *hal.Surface) *PresentSurface {
        return @ptrCast(@alignCast(value));
    }
    fn pipeline(value: *hal.Pipeline) *Pipeline {
        return @ptrCast(@alignCast(value));
    }

    fn caps(ptr: *anyopaque) hal.DeviceCaps {
        const self = cast(ptr);
        const bytes: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.properties.device_name)), 0);
        return .{
            .device_name = bytes,
            .formats = &formats,
            .hdr = false,
            .spirv = true,
            .compute = false,
            .graphics = true,
            .present = true,
            .max_texture_dim = self.properties.limits.max_image_dimension_2d,
        };
    }
    fn createContext(ptr: *anyopaque) hal.Error!hal.Context {
        const self = cast(ptr);
        const context = self.gpa.create(Context) catch return error.OutOfMemory;
        context.* = .{ .owner = self };
        return .{ .ptr = context, .vtable = &Context.vtable };
    }
    fn createResource(ptr: *anyopaque, desc: hal.ResourceDesc) hal.Error!*hal.Resource {
        const self = cast(ptr);
        return switch (desc) {
            .buffer => |buffer_desc| @ptrCast(try self.createBufferResource(buffer_desc.size)),
            .image => |image_desc| @ptrCast(try self.createImageResource(image_desc)),
        };
    }
    fn createBufferResource(self: *Device, size: usize) hal.Error!*Resource {
        const value = self.gpa.create(Resource) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(value);
        const allocation = try self.createMappedBuffer(size, .{ .vertex_buffer = true, .transfer_src = true, .transfer_dst = true });
        value.* = .{ .owner = self, .kind = .buffer, .buffer = allocation.buffer, .buffer_memory = allocation.memory, .mapped = allocation.mapped, .size = size };
        return value;
    }
    fn createImageResource(self: *Device, desc: anytype) hal.Error!*Resource {
        if (desc.format != .rgba8_unorm or desc.samples != 1 or desc.depth != 1 or desc.cube or desc.array or desc.mip_levels != 1) return error.Unsupported;
        const byte_size = std.math.mul(usize, @as(usize, desc.width) * 4, desc.height) catch return error.OutOfMemory;
        const staging = try self.createMappedBuffer(byte_size, .{ .transfer_src = true, .transfer_dst = true });
        errdefer self.destroyMappedBuffer(staging.buffer, staging.memory);
        var image_info: vk.ImageCreateInfo = .{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_src = true, .transfer_dst = true, .sampled = true, .color_attachment = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
            .initial_layout = .undefined,
        };
        var image: vk.Image = .null;
        try check(vkCreateImage(self.device, &image_info, null, &image));
        errdefer vkDestroyImage(self.device, image, null);
        var requirements: vk.MemoryRequirements = undefined;
        vkGetImageMemoryRequirements(self.device, image, &requirements);
        const memory_type = self.memoryType(requirements.memory_type_bits, .{ .device_local = true }) orelse self.memoryType(requirements.memory_type_bits, .{}) orelse return error.Unsupported;
        var alloc_info: vk.MemoryAllocateInfo = .{ .allocation_size = requirements.size, .memory_type_index = memory_type };
        var image_memory: vk.DeviceMemory = .null;
        try check(vkAllocateMemory(self.device, &alloc_info, null, &image_memory));
        errdefer vkFreeMemory(self.device, image_memory, null);
        try check(vkBindImageMemory(self.device, image, image_memory, 0));
        const image_view = try self.createImageView(image, .identity);
        errdefer vkDestroyImageView(self.device, image_view, null);
        const value = self.gpa.create(Resource) catch return error.OutOfMemory;
        value.* = .{
            .owner = self,
            .kind = .image,
            .buffer = staging.buffer,
            .buffer_memory = staging.memory,
            .mapped = staging.mapped,
            .size = byte_size,
            .image = image,
            .image_memory = image_memory,
            .image_view = image_view,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
        };
        @memset(value.mapped[0..byte_size], 0);
        value.cpu_dirty = true;
        return value;
    }

    const ViewKind = enum { identity, coverage };
    fn createImageView(self: *Device, image: vk.Image, kind: ViewKind) hal.Error!vk.ImageView {
        const identity = .identity;
        const components: vk.ComponentMapping = switch (kind) {
            .identity => .{ .r = identity, .g = identity, .b = identity, .a = identity },
            .coverage => .{ .r = .one, .g = .one, .b = .one, .a = .r },
        };
        var info: vk.ImageViewCreateInfo = .{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = components,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        };
        var view: vk.ImageView = .null;
        try check(vkCreateImageView(self.device, &info, null, &view));
        return view;
    }

    const MappedBuffer = struct { buffer: vk.Buffer, memory: vk.DeviceMemory, mapped: [*]u8 };
    fn createMappedBuffer(self: *Device, size: usize, usage: vk.BufferUsageFlags) hal.Error!MappedBuffer {
        var info: vk.BufferCreateInfo = .{
            .flags = .{},
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = null,
        };
        var buffer: vk.Buffer = .null;
        try check(vkCreateBuffer(self.device, &info, null, &buffer));
        errdefer vkDestroyBuffer(self.device, buffer, null);
        var requirements: vk.MemoryRequirements = undefined;
        vkGetBufferMemoryRequirements(self.device, buffer, &requirements);
        const memory_type = self.memoryType(requirements.memory_type_bits, .{ .host_visible = true, .host_coherent = true }) orelse return error.Unsupported;
        var alloc_info: vk.MemoryAllocateInfo = .{ .allocation_size = requirements.size, .memory_type_index = memory_type };
        var memory: vk.DeviceMemory = .null;
        try check(vkAllocateMemory(self.device, &alloc_info, null, &memory));
        errdefer vkFreeMemory(self.device, memory, null);
        try check(vkBindBufferMemory(self.device, buffer, memory, 0));
        var mapped: ?*anyopaque = null;
        try check(vkMapMemory(self.device, memory, 0, requirements.size, .{}, &mapped));
        return .{ .buffer = buffer, .memory = memory, .mapped = @ptrCast(mapped.?) };
    }
    fn destroyMappedBuffer(self: *Device, buffer: vk.Buffer, memory: vk.DeviceMemory) void {
        vkUnmapMemory(self.device, memory);
        vkDestroyBuffer(self.device, buffer, null);
        vkFreeMemory(self.device, memory, null);
    }
    fn destroyResource(_: *anyopaque, opaque_resource: *hal.Resource) void {
        const value = resource(opaque_resource);
        const self = value.owner;
        if (value.kind == .image) {
            if (value.coverage_view != .null) vkDestroyImageView(self.device, value.coverage_view, null);
            vkDestroyImageView(self.device, value.image_view, null);
            vkDestroyImage(self.device, value.image, null);
            vkFreeMemory(self.device, value.image_memory, null);
        }
        self.destroyMappedBuffer(value.buffer, value.buffer_memory);
        self.gpa.destroy(value);
    }
    fn mapResource(_: *anyopaque, opaque_resource: *hal.Resource) hal.Error![]u8 {
        const value = resource(opaque_resource);
        if (value.kind == .image and value.gpu_dirty) try value.owner.download(value);
        if (value.kind == .image) value.cpu_dirty = true;
        return value.mapped[0..value.size];
    }
    fn unmapResource(_: *anyopaque, _: *hal.Resource) void {}

    fn createShader(ptr: *anyopaque, desc: hal.ShaderModuleDesc) hal.Error!*hal.ShaderModule {
        const self = cast(ptr);
        if (desc.code.len == 0 or desc.code.len % 4 != 0) return error.InvalidArgument;
        var info: vk.ShaderModuleCreateInfo = .{
            .flags = .{},
            .code_size = desc.code.len,
            .p_code = @ptrCast(@alignCast(desc.code.ptr)),
        };
        var handle: vk.ShaderModule = .null;
        try check(vkCreateShaderModule(self.device, &info, null, &handle));
        errdefer vkDestroyShaderModule(self.device, handle, null);
        const value = self.gpa.create(Shader) catch return error.OutOfMemory;
        value.* = .{ .owner = self, .handle = handle, .stage = desc.stage };
        return @ptrCast(value);
    }
    fn destroyShader(_: *anyopaque, opaque_shader: *hal.ShaderModule) void {
        const value: *Shader = @ptrCast(@alignCast(opaque_shader));
        vkDestroyShaderModule(value.owner.device, value.handle, null);
        value.owner.gpa.destroy(value);
    }

    fn createPipeline(ptr: *anyopaque, desc: hal.PipelineDesc) hal.Error!*hal.Pipeline {
        const self = cast(ptr);
        if (desc.topology != .triangle_list or desc.samples != 1 or desc.color_format != .rgba8_unorm) return error.Unsupported;
        const vertex_shader: *Shader = @ptrCast(@alignCast(desc.vertex));
        const fragment_shader: *Shader = @ptrCast(@alignCast(desc.fragment));
        var stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .flags = .{}, .stage = .{ .vertex = true }, .module = vertex_shader.handle, .p_name = "main", .p_specialization_info = null },
            .{ .flags = .{}, .stage = .{ .fragment = true }, .module = fragment_shader.handle, .p_name = "main", .p_specialization_info = null },
        };
        const attributes = self.gpa.alloc(vk.VertexInputAttributeDescription, desc.vertex_layout.attributes.len) catch return error.OutOfMemory;
        defer self.gpa.free(attributes);
        for (desc.vertex_layout.attributes, attributes) |attribute, *out| out.* = .{
            .location = attribute.location,
            .binding = 0,
            .format = vertexFormat(attribute.format) orelse return error.Unsupported,
            .offset = attribute.offset,
        };
        var binding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = desc.vertex_layout.stride, .input_rate = .vertex };
        var vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = @intCast(attributes.len),
            .p_vertex_attribute_descriptions = attributes.ptr,
        };
        var input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };
        var viewport: vk.Viewport = .{ .x = 0, .y = 0, .width = 1, .height = 1, .min_depth = 0, .max_depth = 1 };
        var scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 1, .height = 1 } };
        var viewport_state: vk.PipelineViewportStateCreateInfo = .{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = @ptrCast(&viewport),
            .scissor_count = 1,
            .p_scissors = @ptrCast(&scissor),
        };
        var rasterization: vk.PipelineRasterizationStateCreateInfo = .{
            .flags = .{},
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .counter_clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        var multisample: vk.PipelineMultisampleStateCreateInfo = .{
            .flags = .{},
            .rasterization_samples = .{ .@"1" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        var blend_attachment: vk.PipelineColorBlendAttachmentState = .{
            .blend_enable = vk.Bool32.fromBool(desc.blend.enable),
            .src_color_blend_factor = blendFactor(desc.blend.src_color),
            .dst_color_blend_factor = blendFactor(desc.blend.dst_color),
            .color_blend_op = .add,
            .src_alpha_blend_factor = blendFactor(desc.blend.src_alpha),
            .dst_alpha_blend_factor = blendFactor(desc.blend.dst_alpha),
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
        };
        var color_blend: vk.PipelineColorBlendStateCreateInfo = .{
            .flags = .{},
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&blend_attachment),
            .blend_constants = .{ 0, 0, 0, 0 },
        };
        var dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        var dynamic: vk.PipelineDynamicStateCreateInfo = .{
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        var pipeline_info: vk.GraphicsPipelineCreateInfo = .{
            .flags = .{},
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic,
            .layout = self.pipeline_layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null,
            .base_pipeline_index = -1,
        };
        var handle: vk.Pipeline = .null;
        try check(vkCreateGraphicsPipelines(self.device, .null, 1, @ptrCast(&pipeline_info), null, @ptrCast(&handle)));
        errdefer vkDestroyPipeline(self.device, handle, null);
        const value = self.gpa.create(Pipeline) catch return error.OutOfMemory;
        value.* = .{ .owner = self, .handle = handle };
        return @ptrCast(value);
    }
    fn vertexFormat(format: hal.Format) ?vk.Format {
        return switch (format) {
            .r32_float => .r32_sfloat,
            .r32g32_float => .r32g32_sfloat,
            .r32g32b32_float => .r32g32b32_sfloat,
            .r32g32b32a32_float => .r32g32b32a32_sfloat,
            else => null,
        };
    }
    fn blendFactor(factor: hal.BlendFactor) vk.BlendFactor {
        return switch (factor) {
            .zero => .zero,
            .one => .one,
            .src_color => .src_color,
            .one_minus_src_color => .one_minus_src_color,
            .dst_color => .dst_color,
            .one_minus_dst_color => .one_minus_dst_color,
            .src_alpha => .src_alpha,
            .one_minus_src_alpha => .one_minus_src_alpha,
            .dst_alpha => .dst_alpha,
            .one_minus_dst_alpha => .one_minus_dst_alpha,
            .constant_color => .constant_color,
            .one_minus_constant_color => .one_minus_constant_color,
            .constant_alpha => .constant_alpha,
            .one_minus_constant_alpha => .one_minus_constant_alpha,
            .src_alpha_saturate => .src_alpha_saturate,
        };
    }
    fn destroyPipeline(_: *anyopaque, opaque_pipeline: *hal.Pipeline) void {
        const value = pipeline(opaque_pipeline);
        vkDestroyPipeline(value.owner.device, value.handle, null);
        value.owner.gpa.destroy(value);
    }

    fn execute(self: *Device, commands: []const Command) hal.Error!void {
        var target: ?*Resource = null;
        var clear_color = hal.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
        for (commands) |command| switch (command) {
            .set_render_target => |value| target = value,
            .clear => |value| clear_color = value,
            .bind_texture => |binding| {
                const texture = resource(binding.image);
                if (texture.cpu_dirty) try self.upload(texture);
            },
            else => {},
        };
        const render_target = target orelse return error.InvalidArgument;
        if (render_target.kind != .image) return error.InvalidArgument;
        render_target.cpu_dirty = false;
        const command_buffer = try self.beginOneShot();
        self.transition(command_buffer, render_target, .color_attachment_optimal);
        var framebuffer_info: vk.FramebufferCreateInfo = .{
            .flags = .{},
            .render_pass = self.render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&render_target.image_view),
            .width = render_target.width,
            .height = render_target.height,
            .layers = 1,
        };
        var framebuffer: vk.Framebuffer = .null;
        try check(vkCreateFramebuffer(self.device, &framebuffer_info, null, &framebuffer));
        defer vkDestroyFramebuffer(self.device, framebuffer, null);
        var pool_size: vk.DescriptorPoolSize = .{ .type = .combined_image_sampler, .descriptor_count = 256 };
        var descriptor_pool_info: vk.DescriptorPoolCreateInfo = .{
            .flags = .{},
            .max_sets = 256,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        };
        var descriptor_pool: vk.DescriptorPool = .null;
        try check(vkCreateDescriptorPool(self.device, &descriptor_pool_info, null, &descriptor_pool));
        defer vkDestroyDescriptorPool(self.device, descriptor_pool, null);
        var clear_value: vk.ClearValue = undefined;
        clear_value.color.float_32 = .{ clear_color.r, clear_color.g, clear_color.b, clear_color.a };
        var begin_info: vk.RenderPassBeginInfo = .{
            .render_pass = self.render_pass,
            .framebuffer = framebuffer,
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = render_target.width, .height = render_target.height } },
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear_value),
        };
        vkCmdBeginRenderPass(command_buffer, &begin_info, .@"inline");
        var viewport: vk.Viewport = .{ .x = 0, .y = 0, .width = @floatFromInt(render_target.width), .height = @floatFromInt(render_target.height), .min_depth = 0, .max_depth = 1 };
        vkCmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
        var full_scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = render_target.width, .height = render_target.height } };
        vkCmdSetScissor(command_buffer, 0, 1, @ptrCast(&full_scissor));
        for (commands) |command| switch (command) {
            .bind_pipeline => |value| vkCmdBindPipeline(command_buffer, .graphics, value.handle),
            .bind_vertex_buffer => |value| {
                const offset: vk.DeviceSize = 0;
                vkCmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&value.buffer), @ptrCast(&offset));
            },
            .bind_texture => |binding_value| {
                const texture = resource(binding_value.image);
                const view = try self.textureView(texture, binding_value.swizzle);
                var alloc_info: vk.DescriptorSetAllocateInfo = .{
                    .descriptor_pool = descriptor_pool,
                    .descriptor_set_count = 1,
                    .p_set_layouts = @ptrCast(&self.descriptor_layout),
                };
                var descriptor: vk.DescriptorSet = .null;
                try check(vkAllocateDescriptorSets(self.device, &alloc_info, @ptrCast(&descriptor)));
                var image_info: vk.DescriptorImageInfo = .{
                    .sampler = if (binding_value.filter == .linear) self.linear_sampler else self.nearest_sampler,
                    .image_view = view,
                    .image_layout = .shader_read_only_optimal,
                };
                var write: vk.WriteDescriptorSet = .{
                    .dst_set = descriptor,
                    .dst_binding = binding_value.binding,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .combined_image_sampler,
                    .p_image_info = @ptrCast(&image_info),
                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
                vkUpdateDescriptorSets(self.device, 1, @ptrCast(&write), 0, null);
                vkCmdBindDescriptorSets(command_buffer, .graphics, self.pipeline_layout, 0, 1, @ptrCast(&descriptor), 0, null);
            },
            .set_scissor => |rect| {
                var value = if (rect) |r| vk.Rect2D{
                    .offset = .{ .x = @max(0, r.x), .y = @max(0, r.y) },
                    .extent = .{
                        .width = @min(r.width, render_target.width -| @as(u32, @intCast(@max(0, r.x)))),
                        .height = @min(r.height, render_target.height -| @as(u32, @intCast(@max(0, r.y)))),
                    },
                } else full_scissor;
                vkCmdSetScissor(command_buffer, 0, 1, @ptrCast(&value));
            },
            .draw => |value| vkCmdDraw(command_buffer, value.count, 1, value.first, 0),
            else => {},
        };
        vkCmdEndRenderPass(command_buffer);
        try self.endOneShot(command_buffer);
        render_target.layout = .color_attachment_optimal;
        render_target.gpu_dirty = true;
    }

    fn textureView(self: *Device, texture: *Resource, swizzle: [4]hal.Swizzle) hal.Error!vk.ImageView {
        if (std.meta.eql(swizzle, [4]hal.Swizzle{ .r, .g, .b, .a })) return texture.image_view;
        const coverage = [4]hal.Swizzle{ .one, .one, .one, .r };
        if (!std.meta.eql(swizzle, coverage)) return error.Unsupported;
        if (texture.coverage_view == .null) texture.coverage_view = try self.createImageView(texture.image, .coverage);
        return texture.coverage_view;
    }
    fn upload(self: *Device, image: *Resource) hal.Error!void {
        const command_buffer = try self.beginOneShot();
        self.transition(command_buffer, image, .transfer_dst_optimal);
        var region: vk.BufferImageCopy = std.mem.zeroes(vk.BufferImageCopy);
        region.image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
        region.image_extent = .{ .width = image.width, .height = image.height, .depth = 1 };
        vkCmdCopyBufferToImage(command_buffer, image.buffer, image.image, .transfer_dst_optimal, 1, @ptrCast(&region));
        self.transition(command_buffer, image, .shader_read_only_optimal);
        try self.endOneShot(command_buffer);
        image.cpu_dirty = false;
        image.gpu_dirty = false;
    }
    fn download(self: *Device, image: *Resource) hal.Error!void {
        const command_buffer = try self.beginOneShot();
        self.transition(command_buffer, image, .transfer_src_optimal);
        var region: vk.BufferImageCopy = std.mem.zeroes(vk.BufferImageCopy);
        region.image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
        region.image_extent = .{ .width = image.width, .height = image.height, .depth = 1 };
        vkCmdCopyImageToBuffer(command_buffer, image.image, .transfer_src_optimal, image.buffer, 1, @ptrCast(&region));
        try self.endOneShot(command_buffer);
        image.gpu_dirty = false;
    }
    fn transition(_: *Device, command_buffer: vk.CommandBuffer, image: *Resource, next: vk.ImageLayout) void {
        if (image.layout == next) return;
        var barrier: vk.ImageMemoryBarrier = .{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .old_layout = image.layout,
            .new_layout = next,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image.image,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        };
        barrier.src_access_mask = switch (image.layout) {
            .color_attachment_optimal => .{ .color_attachment_write = true },
            .transfer_dst_optimal => .{ .transfer_write = true },
            .transfer_src_optimal => .{ .transfer_read = true },
            .shader_read_only_optimal => .{ .shader_read = true },
            else => .{},
        };
        barrier.dst_access_mask = switch (next) {
            .color_attachment_optimal => .{ .color_attachment_write = true },
            .transfer_dst_optimal => .{ .transfer_write = true },
            .transfer_src_optimal => .{ .transfer_read = true },
            .shader_read_only_optimal => .{ .shader_read = true },
            else => .{},
        };
        vkCmdPipelineBarrier(command_buffer, .{ .all_commands = true }, .{ .all_commands = true }, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
        image.layout = next;
    }
    fn beginOneShot(self: *Device) hal.Error!vk.CommandBuffer {
        try check(vkResetCommandPool(self.device, self.command_pool, .{}));
        var alloc_info: vk.CommandBufferAllocateInfo = .{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var command_buffer: vk.CommandBuffer = undefined;
        try check(vkAllocateCommandBuffers(self.device, &alloc_info, &command_buffer));
        var begin_info: vk.CommandBufferBeginInfo = .{
            .flags = .{ .one_time_submit = true },
            .p_inheritance_info = null,
        };
        try check(vkBeginCommandBuffer(command_buffer, &begin_info));
        return command_buffer;
    }
    fn endOneShot(self: *Device, command_buffer: vk.CommandBuffer) hal.Error!void {
        try check(vkEndCommandBuffer(command_buffer));
        var submit_info: vk.SubmitInfo = .{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = null,
            .p_wait_dst_stage_mask = null,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = null,
        };
        try check(vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), .null));
        try check(vkQueueWaitIdle(self.queue));
    }
    fn memoryType(self: *const Device, allowed: u32, required: vk.MemoryPropertyFlags) ?u32 {
        var index: u32 = 0;
        while (index < self.memory_properties.memory_type_count) : (index += 1) {
            const bit = @as(u32, 1) << @intCast(index);
            const memory_type = self.memory_properties.memory_types[index];
            if (allowed & bit != 0 and memory_type.property_flags.contains(required)) return index;
        }
        return null;
    }
    fn createSurface(ptr: *anyopaque, platform_surface: *anyopaque) hal.Error!*hal.Surface {
        if (!builtin.abi.isAndroid()) return error.Unsupported;

        const self = cast(ptr);
        const value = self.gpa.create(PresentSurface) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(value);

        var info: vk.AndroidSurfaceCreateInfoKHR = .{
            .flags = .{},
            .window = @ptrCast(platform_surface),
        };
        var handle: vk.SurfaceKHR = .null;
        try check(vkCreateAndroidSurfaceKHR(self.instance, &info, null, &handle));
        errdefer vkDestroySurfaceKHR(self.instance, handle, null);

        var supported: vk.Bool32 = .false;
        try check(vkGetPhysicalDeviceSurfaceSupportKHR(self.physical_device, self.queue_family, handle, &supported));
        if (supported != .true) return error.Unsupported;

        value.* = .{ .owner = self, .handle = handle };
        errdefer destroySwapchain(value);
        var semaphore_info: vk.SemaphoreCreateInfo = .{ .flags = .{} };
        try check(vkCreateSemaphore(self.device, &semaphore_info, null, &value.image_available));
        errdefer vkDestroySemaphore(self.device, value.image_available, null);
        try check(vkCreateSemaphore(self.device, &semaphore_info, null, &value.render_finished));
        return @ptrCast(value);
    }

    fn destroySurface(_: *anyopaque, opaque_surface: *hal.Surface) void {
        const value = surface(opaque_surface);
        const self = value.owner;
        _ = vkDeviceWaitIdle(self.device);
        destroySwapchain(value);
        if (value.render_finished != .null) vkDestroySemaphore(self.device, value.render_finished, null);
        if (value.image_available != .null) vkDestroySemaphore(self.device, value.image_available, null);
        vkDestroySurfaceKHR(self.instance, value.handle, null);
        self.gpa.destroy(value);
    }

    fn destroySwapchain(self: *PresentSurface) void {
        if (self.swapchain != .null) vkDestroySwapchainKHR(self.owner.device, self.swapchain, null);
        if (self.images.len != 0) self.owner.gpa.free(self.images);
        if (self.layouts.len != 0) self.owner.gpa.free(self.layouts);
        self.swapchain = .null;
        self.images = &.{};
        self.layouts = &.{};
    }

    fn rebuildSwapchain(self: *Device, target: *PresentSurface, desired_width: u32, desired_height: u32) hal.Error!void {
        _ = vkDeviceWaitIdle(self.device);
        var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
        try check(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, target.handle, &capabilities));
        if (!capabilities.supported_usage_flags.transfer_dst) return error.Unsupported;

        var format_count: u32 = 0;
        try check(vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, target.handle, &format_count, null));
        if (format_count == 0) return error.Unsupported;
        const available_formats = self.gpa.alloc(vk.SurfaceFormatKHR, format_count) catch return error.OutOfMemory;
        defer self.gpa.free(available_formats);
        try check(vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, target.handle, &format_count, available_formats.ptr));
        const chosen_format = chooseSurfaceFormat(available_formats[0..format_count]);

        const variable_extent = capabilities.current_extent.width == std.math.maxInt(u32);
        const extent = if (variable_extent) vk.Extent2D{
            .width = std.math.clamp(desired_width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
            .height = std.math.clamp(desired_height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
        } else capabilities.current_extent;
        if (extent.width == 0 or extent.height == 0) return error.Unsupported;

        var image_count = capabilities.min_image_count + 1;
        if (capabilities.max_image_count != 0) image_count = @min(image_count, capabilities.max_image_count);
        const alpha: vk.CompositeAlphaFlagsKHR = if (capabilities.supported_composite_alpha.opaque_khr)
            .{ .opaque_khr = true }
        else if (capabilities.supported_composite_alpha.pre_multiplied_khr)
            .{ .pre_multiplied_khr = true }
        else if (capabilities.supported_composite_alpha.post_multiplied_khr)
            .{ .post_multiplied_khr = true }
        else
            .{ .inherit_khr = true };
        var info: vk.SwapchainCreateInfoKHR = .{
            .flags = .{},
            .surface = target.handle,
            .min_image_count = image_count,
            .image_format = chosen_format.format,
            .image_color_space = chosen_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .transfer_dst = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = capabilities.current_transform,
            .composite_alpha = alpha,
            .present_mode = .fifo_khr,
            .clipped = .true,
            .old_swapchain = target.swapchain,
        };
        var replacement: vk.SwapchainKHR = .null;
        try check(vkCreateSwapchainKHR(self.device, &info, null, &replacement));
        errdefer vkDestroySwapchainKHR(self.device, replacement, null);

        var actual_count: u32 = 0;
        try check(vkGetSwapchainImagesKHR(self.device, replacement, &actual_count, null));
        const images = self.gpa.alloc(vk.Image, actual_count) catch return error.OutOfMemory;
        errdefer self.gpa.free(images);
        try check(vkGetSwapchainImagesKHR(self.device, replacement, &actual_count, images.ptr));
        const layouts = self.gpa.alloc(vk.ImageLayout, actual_count) catch return error.OutOfMemory;
        errdefer self.gpa.free(layouts);
        @memset(layouts, .undefined);

        const old_swapchain = target.swapchain;
        const old_images = target.images;
        const old_layouts = target.layouts;
        target.swapchain = replacement;
        target.format = chosen_format;
        target.extent = extent;
        target.images = images;
        target.layouts = layouts;
        target.needs_rebuild = false;
        if (old_swapchain != .null) vkDestroySwapchainKHR(self.device, old_swapchain, null);
        if (old_images.len != 0) self.gpa.free(old_images);
        if (old_layouts.len != 0) self.gpa.free(old_layouts);
    }

    fn chooseSurfaceFormat(available: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
        if (available.len == 1 and available[0].format == .undefined) {
            return .{ .format = .r8g8b8a8_unorm, .color_space = available[0].color_space };
        }
        for (available) |format| {
            if (format.format == .r8g8b8a8_unorm and format.color_space == .srgb_nonlinear_khr) return format;
        }
        for (available) |format| {
            if (format.format == .b8g8r8a8_unorm and format.color_space == .srgb_nonlinear_khr) return format;
        }
        return available[0];
    }

    fn presentSurface(self: *Device, target: *PresentSurface, source: *Resource) hal.Error!void {
        if (source.kind != .image) return error.InvalidArgument;
        if (target.needs_rebuild or target.swapchain == .null) try self.rebuildSwapchain(target, source.width, source.height);

        var image_index: u32 = 0;
        var acquire_result = vkAcquireNextImageKHR(self.device, target.swapchain, std.math.maxInt(u64), target.image_available, .null, &image_index);
        if (acquire_result == .error_out_of_date_khr) {
            try self.rebuildSwapchain(target, source.width, source.height);
            acquire_result = vkAcquireNextImageKHR(self.device, target.swapchain, std.math.maxInt(u64), target.image_available, .null, &image_index);
        }
        const acquired_suboptimal = acquire_result == .suboptimal_khr;
        if (!acquired_suboptimal) try check(acquire_result);
        if (image_index >= target.images.len) return error.DeviceLost;

        const command_buffer = try self.beginOneShot();
        self.transition(command_buffer, source, .transfer_src_optimal);
        transitionImage(command_buffer, target.images[image_index], target.layouts[image_index], .transfer_dst_optimal);
        var blit: vk.ImageBlit = .{
            .src_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .src_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{ .x = @intCast(source.width), .y = @intCast(source.height), .z = 1 },
            },
            .dst_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .dst_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{ .x = @intCast(target.extent.width), .y = @intCast(target.extent.height), .z = 1 },
            },
        };
        vkCmdBlitImage(command_buffer, source.image, .transfer_src_optimal, target.images[image_index], .transfer_dst_optimal, 1, @ptrCast(&blit), .nearest);
        transitionImage(command_buffer, target.images[image_index], .transfer_dst_optimal, .present_src_khr);
        target.layouts[image_index] = .present_src_khr;
        try check(vkEndCommandBuffer(command_buffer));

        var wait_stage: vk.PipelineStageFlags = .{ .transfer = true };
        var submit_info: vk.SubmitInfo = .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&target.image_available),
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&target.render_finished),
        };
        try check(vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), .null));
        var present_info: vk.PresentInfoKHR = .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&target.render_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&target.swapchain),
            .p_image_indices = @ptrCast(&image_index),
            .p_results = null,
        };
        const present_result = vkQueuePresentKHR(self.queue, &present_info);
        try check(vkQueueWaitIdle(self.queue));
        if (present_result == .error_out_of_date_khr or present_result == .suboptimal_khr or acquired_suboptimal) {
            target.needs_rebuild = true;
        } else {
            try check(present_result);
        }
    }

    fn transitionImage(command_buffer: vk.CommandBuffer, image: vk.Image, old: vk.ImageLayout, next: vk.ImageLayout) void {
        var barrier: vk.ImageMemoryBarrier = .{
            .src_access_mask = accessForLayout(old),
            .dst_access_mask = accessForLayout(next),
            .old_layout = old,
            .new_layout = next,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        };
        vkCmdPipelineBarrier(command_buffer, .{ .all_commands = true }, .{ .all_commands = true }, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
    }

    fn accessForLayout(layout: vk.ImageLayout) vk.AccessFlags {
        return switch (layout) {
            .color_attachment_optimal => .{ .color_attachment_write = true },
            .transfer_dst_optimal => .{ .transfer_write = true },
            .transfer_src_optimal => .{ .transfer_read = true },
            .shader_read_only_optimal => .{ .shader_read = true },
            else => .{},
        };
    }

    fn dispatch(_: *anyopaque, _: hal.ComputeDispatch) hal.Error!void {
        return error.NotImplemented;
    }
    fn deinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        _ = vkDeviceWaitIdle(self.device);
        self.destroySharedObjects();
        vkDestroyDevice(self.device, null);
        vkDestroyInstance(self.instance, null);
        const gpa = self.gpa;
        gpa.destroy(self);
    }
    const vtable = hal.Device.VTable{
        .caps = &caps,
        .createContext = &createContext,
        .createResource = &createResource,
        .destroyResource = &destroyResource,
        .mapResource = &mapResource,
        .unmapResource = &unmapResource,
        .createShaderModule = &createShader,
        .destroyShaderModule = &destroyShader,
        .dispatchCompute = &dispatch,
        .createPipeline = &createPipeline,
        .destroyPipeline = &destroyPipeline,
        .createSurface = &createSurface,
        .destroySurface = &destroySurface,
        .deinit = &deinit,
    };
};
