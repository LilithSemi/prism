const std = @import("std");
const hal = @import("../../hal.zig");
const glsl = @import("../../glsl.zig");
const driver = @import("../apple.zig").driver;

fn testDraw(gradient: bool, format: hal.Format, with_uniforms: bool) !void {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    if (!dev.caps().graphics) return error.SkipZigTest;
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa, if (with_uniforms)
        \\attribute vec2 p;
        \\attribute vec3 c;
        \\varying vec3 color;
        \\uniform mat4 transform;
        \\void main() { gl_Position = transform * vec4(p, 0.0, 1.0); color = c; }
    else if (gradient)
        \\attribute vec2 p;
        \\attribute vec3 c;
        \\varying vec3 color;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); color = c; }
    else
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p * 0.8, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa, if (with_uniforms)
        \\precision mediump float;
        \\varying vec3 color;
        \\uniform vec4 tint;
        \\void main() { gl_FragColor = vec4(color * 0.75 + 0.05, 1.0) * tint; }
    else if (gradient)
        \\precision mediump float;
        \\varying vec3 color;
        \\void main() { gl_FragColor = vec4(color * 0.75 + 0.1 - 0.05, 1.0); }
    else
        \\precision mediump float;
        \\void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 0.0); }
    , .fragment);
    defer gpa.free(fs_code);
    const pipe = blk: {
        const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
        defer dev.destroyShaderModule(vs);
        const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
        defer dev.destroyShaderModule(fs);
        const compiled = try dev.createPipeline(.{
            .vertex = vs,
            .fragment = fs,
            .vertex_layout = .{ .stride = 20, .attributes = if (gradient) &.{
                .{ .location = 0, .format = .r32g32_float, .offset = 0 },
                .{ .location = 1, .format = .r32g32b32_float, .offset = 8 },
            } else &.{.{ .location = 0, .format = .r32g32_float, .offset = 0 }} },
            .color_format = format,
        });
        break :blk compiled;
    };
    defer dev.destroyPipeline(pipe);
    const vertices = [_][5]f32{
        .{ 0, 0, 0, 0, 0 },       .{ 0, 0, 0, 0, 0 },      .{ 0, 0, 0, 0, 0 },
        .{ -0.8, -0.8, 1, 0, 0 }, .{ 0.8, -0.8, 0, 1, 0 }, .{ 0, 0.8, 0, 0, 1 },
    };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(vertices)), .usage = .{ .vertex = true } } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&vertices));
    const transform = try dev.createResource(.{ .buffer = .{ .size = 64 } });
    defer dev.destroyResource(transform);
    const tint = try dev.createResource(.{ .buffer = .{ .size = 16 } });
    defer dev.destroyResource(tint);
    var matrix: [16]f32 = @splat(0);
    for (0..4) |i| matrix[i * 5] = 1;
    @memcpy(try dev.mapResource(transform), std.mem.asBytes(&matrix));
    @memcpy(try dev.mapResource(tint), std.mem.asBytes(&@as([4]f32, .{ 1, 1, 1, 1 })));
    const width = 65;
    const height = 37;
    const target = try dev.createResource(.{ .image = .{ .width = width, .height = height, .format = format, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 0, .b = 0.5, .a = 1 });
    try cb.bindPipeline(pipe);
    if (with_uniforms) {
        try cb.bindUniformBuffer(0, transform);
        try cb.bindUniformBuffer(1, tint);
    }
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 3);
    // Cross the native pass batch boundary without losing the earlier color.
    for (0..33) |_| try cb.draw(3, 0); // Degenerate prefix leaves it intact.
    try ctx.submit(cb);
    const pixels = try dev.mapResource(target);
    const center = (height / 2 * width + width / 2) * 4;
    const px = pixels[center..][0..4];
    if (gradient) {
        try std.testing.expect(px[0] > 40 and px[1] > 40 and px[2] > 90);
        const left = (height / 3 * width + width / 3) * 4;
        const right = (height / 3 * width + width * 2 / 3) * 4;
        try std.testing.expect(pixels[left] > pixels[right] + 40);
        try std.testing.expect(pixels[right + 1] > pixels[left + 1] + 40);
    } else {
        try std.testing.expectEqualSlices(u8, if (format == .rgba8_unorm) &.{ 255, 0, 0, 0 } else &.{ 0, 0, 255, 0 }, px);
    }
    try std.testing.expectEqualSlices(u8, if (format == .rgba8_unorm) &.{ 0, 0, 128, 255 } else &.{ 128, 0, 0, 255 }, pixels[0..4]);
    // The same resources and pipeline must survive another submission.
    var expected: [4]u8 = undefined;
    @memcpy(&expected, px);
    try ctx.submit(cb);
    const again = try dev.mapResource(target);
    try std.testing.expectEqualSlices(u8, &expected, again[center..][0..4]);

    // Separate clear and draw submissions, as used by EGL/GLES. Covered pixels
    // with alpha zero still overwrite the image; uncovered green pixels survive.
    cb.reset();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 1, .b = 0, .a = 1 });
    try ctx.submit(cb);
    cb.reset();
    try cb.setRenderTarget(target);
    try cb.bindPipeline(pipe);
    if (with_uniforms) {
        try cb.bindUniformBuffer(0, transform);
        try cb.bindUniformBuffer(1, tint);
    }
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 3);
    try ctx.submit(cb);
    const preserved = try dev.mapResource(target);
    try std.testing.expectEqualSlices(u8, &expected, preserved[center..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, preserved[0..4]);

    // Change the vertex buffer without rebuilding the pipeline. Move the whole
    // triangle out of clip space: the former center must now stay green.
    var moved = vertices;
    for (moved[3..]) |*v| v[0] += 4;
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&moved));
    cb.reset();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 1, .b = 0, .a = 1 });
    try cb.bindPipeline(pipe);
    if (with_uniforms) {
        try cb.bindUniformBuffer(0, transform);
        try cb.bindUniformBuffer(1, tint);
    }
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 3);
    try ctx.submit(cb);
    const shifted = try dev.mapResource(target);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, shifted[center..][0..4]);
    if (with_uniforms) {
        // The original vertices are in view. A changed matrix moves them out,
        // proving the next submission reads the updated UBO on the GPU.
        @memcpy(try dev.mapResource(vb), std.mem.asBytes(&vertices));
        matrix[12] = 4;
        @memcpy(try dev.mapResource(transform), std.mem.asBytes(&matrix));
        try ctx.submit(cb);
        try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, (try dev.mapResource(target))[center..][0..4]);
        matrix[12] = 0;
        @memcpy(try dev.mapResource(transform), std.mem.asBytes(&matrix));
        @memcpy(try dev.mapResource(tint), std.mem.asBytes(&@as([4]f32, .{ 0, 1, 1, 1 })));
        try ctx.submit(cb);
        const tinted = (try dev.mapResource(target))[center..][0..4];
        try std.testing.expectEqual(@as(u8, 0), tinted[0]);
        try std.testing.expect(tinted[1] > 40 and tinted[2] > 90);
    }
}

test "apple GPU native SPIR-V solid draw fetches vertex buffer with first_vertex" {
    try testDraw(false, .rgba8_unorm, false);
}
test "apple GPU native SPIR-V gradient draw interpolates varying color" {
    try testDraw(true, .rgba8_unorm, false);
}

test "apple GPU native SPIR-V BGRA draw preserves channel order" {
    try testDraw(false, .bgra8_unorm, false);
}

test "apple native graphics wins automatic selection when available" {
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const probe = try driver.createDevice(std.testing.allocator, std.testing.io);
    const supported = probe.caps().graphics;
    probe.deinit();
    if (!supported) return error.SkipZigTest;
    const selected = @import("../../drivers.zig").createBestDevice(std.testing.allocator, std.testing.io) orelse return error.TestUnexpectedResult;
    defer selected.device.deinit();
    try std.testing.expectEqualStrings("apple", selected.driver.name);
    try std.testing.expect(selected.device.caps().graphics);
    try std.testing.expect(selected.device.caps().spirv);
}

test "apple GPU depth rejects a farther overlapping triangle and stores depth" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa,
        \\attribute vec3 p;
        \\attribute vec3 c;
        \\varying vec3 color;
        \\void main() { gl_Position = vec4(p, 1.0); color = c; }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\varying vec3 color;
        \\void main() { gl_FragColor = vec4(color, 1.0); }
    , .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const pipe = try dev.createPipeline(.{
        .vertex = vs,
        .fragment = fs,
        .vertex_layout = .{ .stride = 24, .attributes = &.{
            .{ .location = 0, .format = .r32g32b32_float, .offset = 0 },
            .{ .location = 1, .format = .r32g32b32_float, .offset = 12 },
        } },
        .depth = .{ .test_enable = true, .write_enable = true },
        .color_format = .rgba8_unorm,
    });
    defer dev.destroyPipeline(pipe);
    const vertices = [_][6]f32{
        .{ -0.8, -0.8, 0.2, 1, 0, 0 }, .{ 0.8, -0.8, 0.2, 1, 0, 0 }, .{ 0, 0.8, 0.2, 1, 0, 0 },
        .{ -0.8, -0.8, 0.7, 0, 0, 1 }, .{ 0.8, -0.8, 0.7, 0, 0, 1 }, .{ 0, 0.8, 0.7, 0, 0, 1 },
    };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(vertices)) } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&vertices));
    const color = try dev.createResource(.{ .image = .{ .width = 300, .height = 300, .format = .rgba8_unorm } });
    defer dev.destroyResource(color);
    const depth = try dev.createResource(.{ .image = .{ .width = 300, .height = 300, .format = .depth32_float } });
    defer dev.destroyResource(depth);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(color);
    try cb.clear(.{ .r = 0, .g = 1, .b = 0, .a = 1 });
    try cb.setDepthTarget(depth, 1);
    try ctx.submit(cb);
    cb.reset();
    try cb.setRenderTarget(color);
    try cb.setDepthTarget(depth, 1);
    try ctx.submit(cb);
    cb.reset();
    try cb.setRenderTarget(color);
    try cb.setDepthTarget(depth, null);
    try cb.bindPipeline(pipe);
    try cb.bindVertexBuffer(vb);
    try cb.draw(6, 0);
    try ctx.submit(cb);
    const offset = (150 * 300 + 150) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, (try dev.mapResource(color))[offset..][0..4]);
    const z = std.mem.readInt(u32, (try dev.mapResource(depth))[offset..][0..4], .little);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), @as(f32, @bitCast(z)), 0.001);
    // Load the stored depth in a later submission: the farther blue triangle
    // must still fail, while the previously rendered color remains untouched.
    cb.reset();
    try cb.setRenderTarget(color);
    try cb.setDepthTarget(depth, null);
    try cb.bindPipeline(pipe);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 3);
    try ctx.submit(cb);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, (try dev.mapResource(color))[offset..][0..4]);
}

test "apple GPU native uniform matrices and fragment tint update between submissions" {
    try testDraw(true, .rgba8_unorm, true);
}

test "apple GPU samples a bound 2D texture with nearest and linear filtering" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\attribute vec2 uv;
        \\varying vec2 texcoord;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); texcoord = uv; }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\uniform sampler2D image;
        \\varying vec2 texcoord;
        \\void main() { gl_FragColor = texture2D(image, texcoord); }
    , .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const pipe = try dev.createPipeline(.{
        .vertex = vs,
        .fragment = fs,
        .color_format = .rgba8_unorm,
        .vertex_layout = .{ .stride = 16, .attributes = &.{
            .{ .location = 0, .format = .r32g32_float, .offset = 0 },
            .{ .location = 1, .format = .r32g32_float, .offset = 8 },
        } },
    });
    defer dev.destroyPipeline(pipe);
    const vertices = [_][4]f32{ .{ -1, -1, 0, 0 }, .{ 3, -1, 2, 0 }, .{ -1, 3, 0, 2 } };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(vertices)) } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&vertices));
    const image = try dev.createResource(.{ .image = .{ .width = 2, .height = 2, .format = .rgba8_unorm } });
    defer dev.destroyResource(image);
    @memcpy(try dev.mapResource(image), &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 });
    const color = try dev.createResource(.{ .image = .{ .width = 64, .height = 64, .format = .rgba8_unorm } });
    defer dev.destroyResource(color);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    for ([_]hal.Filter{ .nearest, .linear }) |filter| {
        cb.reset();
        try cb.setRenderTarget(color);
        try cb.clear(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
        try cb.bindPipeline(pipe);
        try cb.bindVertexBuffer(vb);
        try cb.bindTexture(.{ .binding = 2, .image = image, .filter = filter, .min_filter = filter, .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
        try cb.draw(3, 0);
        try ctx.submit(cb);
        const pixels = try dev.mapResource(color);
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[(8 * 64 + 8) * 4 ..][0..4]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, pixels[(8 * 64 + 56) * 4 ..][0..4]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels[(56 * 64 + 8) * 4 ..][0..4]);
        if (filter == .linear) {
            const center = pixels[(32 * 64 + 32) * 4 ..][0..4];
            for (center[0..3]) |c| try std.testing.expect(c >= 115 and c <= 140);
        }
    }
}

test "apple native compiler accepts cube derivative lighting and branching sRGB shader" {
    const program = try @import("graphics.zig").compile(std.testing.allocator, @embedFile("../../testdata_vkcube_fs.spv"), .fragment, .{ .stride = 0, .attributes = &.{} }, .rgba8_unorm);
    try std.testing.expectEqual(@as(u8, 1 << 1), program.texture_mask);
}

test "apple GPU cube vertex pulling uses changing UBO array indices" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = @embedFile("../nvidia/vkcube_vs.spv") });
    defer dev.destroyShaderModule(vs);
    const fs_code = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
    , .fragment);
    defer gpa.free(fs_code);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const pipe = try dev.createPipeline(.{ .vertex = vs, .fragment = fs, .color_format = .rgba8_unorm, .vertex_layout = .{ .stride = 0, .attributes = &.{} } });
    defer dev.destroyPipeline(pipe);
    const ubo = try dev.createResource(.{ .buffer = .{ .size = 1216 } });
    defer dev.destroyResource(ubo);
    var data: [304]f32 = @splat(0);
    for (0..4) |i| data[i * 5] = 1;
    const positions = [_][4]f32{ .{ -0.8, -0.8, 0.2, 1 }, .{ 0.8, -0.8, 0.2, 1 }, .{ 0, 0.8, 0.2, 1 } };
    @memcpy(std.mem.sliceAsBytes(data[16..28]), std.mem.asBytes(&positions));
    @memcpy(try dev.mapResource(ubo), std.mem.asBytes(&data));
    const target = try dev.createResource(.{ .image = .{ .width = 64, .height = 64, .format = .rgba8_unorm } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 1, .b = 0, .a = 1 });
    try cb.bindPipeline(pipe);
    try cb.bindUniformBuffer(0, ubo);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, (try dev.mapResource(target))[(32 * 64 + 32) * 4 ..][0..4]);
}

test "apple native compiler accepts Mesa vkgears shaders" {
    const graphics = @import("graphics.zig");
    const layout: hal.VertexLayout = .{ .stride = 24, .attributes = &.{
        .{ .location = 0, .format = .r32g32b32_float, .offset = 0 },
        .{ .location = 1, .format = .r32g32b32_float, .offset = 12 },
    } };
    _ = try graphics.compile(std.testing.allocator, @embedFile("testdata_vkgears_vs.spv"), .vertex, layout, .rgba8_unorm);
    _ = try graphics.compile(std.testing.allocator, @embedFile("testdata_vkgears_fs.spv"), .fragment, layout, .rgba8_unorm);
}

test "apple GPU Mesa gear shader keeps projection and push constants separate" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try @import("../../spirv.zig").bindPushConstants(gpa, @embedFile("testdata_vkgears_vs.spv"), 1);
    defer gpa.free(vs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = @embedFile("testdata_vkgears_fs.spv") });
    defer dev.destroyShaderModule(fs);
    const pipe = try dev.createPipeline(.{ .vertex = vs, .fragment = fs, .color_format = .rgba8_unorm, .vertex_layout = .{ .stride = 24, .attributes = &.{
        .{ .location = 0, .format = .r32g32b32_float, .offset = 0 },
        .{ .location = 1, .format = .r32g32b32_float, .offset = 12 },
    } } });
    defer dev.destroyPipeline(pipe);
    const projection = try dev.createResource(.{ .buffer = .{ .size = 64 } });
    defer dev.destroyResource(projection);
    const pc = try dev.createResource(.{ .buffer = .{ .size = 80 } });
    defer dev.destroyResource(pc);
    var matrix: [16]f32 = @splat(0);
    for (0..4) |i| matrix[i * 5] = 1;
    @memcpy(try dev.mapResource(projection), std.mem.asBytes(&matrix));
    const pushed = try dev.mapResource(pc);
    @memcpy(pushed[0..64], std.mem.asBytes(&matrix));
    @memcpy(pushed[64..80], std.mem.asBytes(&@as([4]f32, .{ 1, 0, 0, 1 })));
    const vertices = [_][6]f32{ .{ -0.8, -0.8, 0.2, 0, 0, 1 }, .{ 0.8, -0.8, 0.2, 0, 0, 1 }, .{ 0, 0.8, 0.2, 0, 0, 1 } };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(vertices)) } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&vertices));
    const target = try dev.createResource(.{ .image = .{ .width = 64, .height = 64, .format = .rgba8_unorm } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try cb.bindPipeline(pipe);
    try cb.bindUniformBuffer(0, projection);
    try cb.bindUniformBuffer(1, pc);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    const pixel = (try dev.mapResource(target))[(32 * 64 + 32) * 4 ..][0..4];
    try std.testing.expect(pixel[0] > 100);
    try std.testing.expectEqual(@as(u8, 0), pixel[1]);
    try std.testing.expectEqual(@as(u8, 0), pixel[2]);
    // Exercise the same perspective range as vkgears, including negative view Z.
    var frustum: [16]f32 = @splat(0);
    frustum[0] = 5;
    frustum[5] = -5;
    frustum[10] = -1.0909091;
    frustum[11] = -1;
    frustum[14] = -5.4545455;
    @memcpy(try dev.mapResource(projection), std.mem.asBytes(&frustum));
    matrix[14] = -40;
    @memcpy(pushed[0..64], std.mem.asBytes(&matrix));
    try ctx.submit(cb);
    const perspective = (try dev.mapResource(target))[(32 * 64 + 32) * 4 ..][0..4];
    try std.testing.expect(perspective[0] > 100);
}

test "apple GPU explicit LOD reads an uploaded mip level" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\uniform sampler2D image;
        \\void main() { gl_FragColor = texture2DLod(image, vec2(0.5), 2.0); }
    , .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const pipe = try dev.createPipeline(.{ .vertex = vs, .fragment = fs, .color_format = .rgba8_unorm, .vertex_layout = .{ .stride = 8, .attributes = &.{.{ .location = 0, .format = .r32g32_float, .offset = 0 }} } });
    defer dev.destroyPipeline(pipe);
    const positions = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(positions)) } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&positions));
    const image = try dev.createResource(.{ .image = .{ .width = 8, .height = 8, .format = .rgba8_unorm, .mip_levels = 4 } });
    defer dev.destroyResource(image);
    const pixels = try dev.mapResource(image);
    var offset: usize = 0;
    for ([_]usize{ 64, 16, 4, 1 }, [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 255, 255 } }) |count, color| {
        for (0..count) |_| {
            @memcpy(pixels[offset..][0..4], &color);
            offset += 4;
        }
    }
    const target = try dev.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .rgba8_unorm } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try cb.bindPipeline(pipe);
    try cb.bindTexture(.{ .binding = 2, .image = image, .mip_filter = .nearest });
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, (try dev.mapResource(target))[(16 * 32 + 16) * 4 ..][0..4]);
}

test "apple GPU fragment coordinates and transcendental operations" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa,
        \\precision highp float;
        \\void main() { gl_FragColor = vec4(gl_FragCoord.xy / 64.0, sin(1.57079632679), exp2(log2(0.25))); }
    , .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    const pipe = try dev.createPipeline(.{ .vertex = vs, .fragment = fs, .color_format = .rgba8_unorm, .vertex_layout = .{ .stride = 8, .attributes = &.{.{ .location = 0, .format = .r32g32_float, .offset = 0 }} } });
    defer dev.destroyPipeline(pipe);
    const positions = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(positions)) } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&positions));
    const target = try dev.createResource(.{ .image = .{ .width = 64, .height = 64, .format = .rgba8_unorm } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try cb.bindPipeline(pipe);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    const pixel = (try dev.mapResource(target))[(32 * 64 + 32) * 4 ..][0..4];
    try std.testing.expect(pixel[0] >= 128 and pixel[0] <= 130);
    try std.testing.expect(pixel[1] >= 128 and pixel[1] <= 130);
    try std.testing.expect(pixel[2] >= 254);
    try std.testing.expectEqual(@as(u8, 64), pixel[3]);
}

test "apple GPU blends against tile color and preserves it across submissions" {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 0.5); }
    , .fragment);
    defer gpa.free(fs_code);
    const vs = try dev.createShaderModule(.{ .stage = .vertex, .code = vs_code });
    defer dev.destroyShaderModule(vs);
    const fs = try dev.createShaderModule(.{ .stage = .fragment, .code = fs_code });
    defer dev.destroyShaderModule(fs);
    var desc: hal.PipelineDesc = .{ .vertex = vs, .fragment = fs, .color_format = .rgba8_unorm, .vertex_layout = .{ .stride = 8, .attributes = &.{.{ .location = 0, .format = .r32g32_float, .offset = 0 }} }, .blend = .{ .enable = true, .src_color = .src_alpha, .dst_color = .one_minus_src_alpha, .src_alpha = .one, .dst_alpha = .one_minus_src_alpha } };
    const pipe = try dev.createPipeline(desc);
    defer dev.destroyPipeline(pipe);
    const positions = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const vb = try dev.createResource(.{ .buffer = .{ .size = @sizeOf(@TypeOf(positions)) } });
    defer dev.destroyResource(vb);
    @memcpy(try dev.mapResource(vb), std.mem.asBytes(&positions));
    const target = try dev.createResource(.{ .image = .{ .width = 32, .height = 32, .format = .rgba8_unorm } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 0, .b = 1, .a = 1 });
    try cb.bindPipeline(pipe);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    var pixel = (try dev.mapResource(target))[(16 * 32 + 16) * 4 ..][0..4];
    try std.testing.expect(pixel[0] >= 127 and pixel[0] <= 129);
    try std.testing.expect(pixel[2] >= 127 and pixel[2] <= 129);
    try std.testing.expectEqual(@as(u8, 255), pixel[3]);
    cb.reset();
    try cb.setRenderTarget(target);
    try cb.bindPipeline(pipe);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    pixel = (try dev.mapResource(target))[(16 * 32 + 16) * 4 ..][0..4];
    try std.testing.expect(pixel[0] >= 190 and pixel[0] <= 193);
    try std.testing.expect(pixel[2] >= 63 and pixel[2] <= 65);
    desc.blend.enable = false;
    desc.blend.write_mask = .{ false, false, false, true };
    const masked = try dev.createPipeline(desc);
    defer dev.destroyPipeline(masked);
    cb.reset();
    try cb.setRenderTarget(target);
    try cb.bindPipeline(masked);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 0);
    try ctx.submit(cb);
    pixel = (try dev.mapResource(target))[(16 * 32 + 16) * 4 ..][0..4];
    try std.testing.expect(pixel[0] >= 190 and pixel[0] <= 193);
    try std.testing.expect(pixel[2] >= 63 and pixel[2] <= 65);
    try std.testing.expectEqual(@as(u8, 128), pixel[3]);
}
