const std = @import("std");
const hal = @import("../../hal.zig");
const glsl = @import("../../glsl.zig");
const driver = @import("../apple.zig").driver;

fn testDraw(gradient: bool, format: hal.Format) !void {
    const gpa = std.testing.allocator;
    if (!driver.isAvailable(std.testing.io)) return error.SkipZigTest;
    const dev = try driver.createDevice(gpa, std.testing.io);
    defer dev.deinit();
    if (!dev.caps().graphics) return error.SkipZigTest;
    const ctx = try dev.createContext();
    defer ctx.deinit();
    const vs_code = try glsl.compileForStage(gpa, if (gradient)
        \\attribute vec2 p;
        \\attribute vec3 c;
        \\varying vec3 color;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); color = c; }
    else
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p * 0.8, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(vs_code);
    const fs_code = try glsl.compileForStage(gpa, if (gradient)
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
    const width = 65;
    const height = 37;
    const target = try dev.createResource(.{ .image = .{ .width = width, .height = height, .format = format, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const cb = try ctx.beginCommands();
    defer cb.deinit();
    try cb.setRenderTarget(target);
    try cb.clear(.{ .r = 0, .g = 0, .b = 0.5, .a = 1 });
    try cb.bindPipeline(pipe);
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 3);
    try cb.draw(3, 0); // Degenerate prefix must not replace the preceding draw.
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
    try cb.bindVertexBuffer(vb);
    try cb.draw(3, 3);
    try ctx.submit(cb);
    const shifted = try dev.mapResource(target);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, shifted[center..][0..4]);
}

test "apple GPU native SPIR-V solid draw fetches vertex buffer with first_vertex" {
    try testDraw(false, .rgba8_unorm);
}
test "apple GPU native SPIR-V gradient draw interpolates varying color" {
    try testDraw(true, .rgba8_unorm);
}

test "apple GPU native SPIR-V BGRA draw preserves channel order" {
    try testDraw(false, .bgra8_unorm);
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
