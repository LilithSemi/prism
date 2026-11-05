//! Narrow, truthful SPIR-V lowering for the first native Mali graphics path.
//!
//! The vertex template is the PanVK-compiled Prism selection probe. We parse
//! SPIR-V into Vulcan's scalar IR, prove the passthrough-position semantics,
//! and generate a native immediate fragment program for any constant RGBA
//! output. Arbitrary modules are never silently substituted.

const std = @import("std");
const mali = @import("mali");
const hal = @import("../../hal.zig");
const ir = @import("vulcan-ir");
const F = ir.function;
const Function = F.Function;
const Value = F.Value;
const ShaderModule = @import("shader.zig").ShaderModule;

pub const Pipeline = struct {
    native: mali.NativeGraphicsPipeline,
    stride: u32,
    requires_texture: bool,

    pub fn create(session: *mali.Session, gpa: std.mem.Allocator, desc: hal.PipelineDesc) hal.Error!Pipeline {
        if (!supportedState(desc)) return error.Unsupported;
        const vertex: *ShaderModule = @ptrCast(@alignCast(desc.vertex));
        const fragment: *ShaderModule = @ptrCast(@alignCast(desc.fragment));
        if (vertex.stage != .vertex or fragment.stage != .fragment) return error.InvalidArgument;
        const vertex_meaning = try validateShader(gpa, vertex.code, .vertex);
        const fragment_meaning = try validateShader(gpa, fragment.code, .fragment);
        const native = switch (fragment_meaning) {
            .constant_color => |color_bits| constant: {
                if (vertex_meaning != .position or !supportedPositionLayout(desc.vertex_layout)) return error.Unsupported;
                var color: [4]f32 = undefined;
                for (color_bits, 0..) |bits, index_| color[index_] = @bitCast(bits);
                break :constant mali.NativeGraphicsPipeline.createConstantColor(session, color);
            },
            .vertex_color => color: {
                if (vertex_meaning != .position_color or !supportedColorLayout(desc.vertex_layout)) return error.Unsupported;
                break :color mali.NativeGraphicsPipeline.createVertexColor(session);
            },
            .rounded_rectangle => rrect: {
                if (vertex_meaning != .rounded_rectangle or !supportedRoundedRectangleLayout(desc.vertex_layout)) return error.Unsupported;
                break :rrect mali.NativeGraphicsPipeline.createRoundedRectangle(session);
            },
            .text => text: {
                if (vertex_meaning != .textured_color or !supportedTexturedLayout(desc.vertex_layout)) return error.Unsupported;
                break :text mali.NativeGraphicsPipeline.createText(session);
            },
            .image => image: {
                if (vertex_meaning != .textured_color or !supportedTexturedLayout(desc.vertex_layout)) return error.Unsupported;
                break :image mali.NativeGraphicsPipeline.createImage(session);
            },
            else => return error.Unsupported,
        };
        var native_pipeline = native catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidImage, error.InvalidShader, error.InvalidArgument => error.InvalidArgument,
            error.Timeout, error.IoctlFailed, error.MapFailed => error.DeviceLost,
            else => error.InitializationFailed,
        };
        native_pipeline.blend = if (desc.blend.enable) .src_alpha else .replace;
        return .{
            .native = native_pipeline,
            .stride = desc.vertex_layout.stride,
            .requires_texture = native_pipeline.vertex_layout == .textured_color,
        };
    }

    pub fn deinit(self: *Pipeline, session: *mali.Session) void {
        self.native.deinit(session);
        self.* = undefined;
    }
};

fn supportedPositionLayout(layout: hal.VertexLayout) bool {
    return layout.stride == 8 and layout.attributes.len == 1 and
        layout.attributes[0].location == 0 and layout.attributes[0].format == .r32g32_float and
        layout.attributes[0].offset == 0;
}

fn supportedColorLayout(layout: hal.VertexLayout) bool {
    return layout.stride == 20 and layout.attributes.len == 2 and
        layout.attributes[0].location == 0 and layout.attributes[0].format == .r32g32_float and
        layout.attributes[0].offset == 0 and layout.attributes[1].location == 1 and
        layout.attributes[1].format == .r32g32b32_float and layout.attributes[1].offset == 8;
}

fn supportedRoundedRectangleLayout(layout: hal.VertexLayout) bool {
    return layout.stride == 48 and layout.attributes.len == 4 and
        layout.attributes[0].location == 0 and layout.attributes[0].format == .r32g32_float and layout.attributes[0].offset == 0 and
        layout.attributes[1].location == 1 and layout.attributes[1].format == .r32g32_float and layout.attributes[1].offset == 8 and
        layout.attributes[2].location == 2 and layout.attributes[2].format == .r32g32b32a32_float and layout.attributes[2].offset == 16 and
        layout.attributes[3].location == 3 and layout.attributes[3].format == .r32g32b32a32_float and layout.attributes[3].offset == 32;
}

fn supportedTexturedLayout(layout: hal.VertexLayout) bool {
    return layout.stride == 32 and layout.attributes.len == 3 and
        layout.attributes[0].location == 0 and layout.attributes[0].format == .r32g32_float and layout.attributes[0].offset == 0 and
        layout.attributes[1].location == 1 and layout.attributes[1].format == .r32g32_float and layout.attributes[1].offset == 8 and
        layout.attributes[2].location == 2 and layout.attributes[2].format == .r32g32b32a32_float and layout.attributes[2].offset == 16;
}

fn supportedState(desc: hal.PipelineDesc) bool {
    return desc.color_format == .rgba8_unorm and desc.topology == .triangle_list and desc.line_width == 1 and
        std.meta.eql(desc.depth, hal.DepthState{}) and std.meta.eql(desc.cull, hal.CullState{}) and
        supportedBlend(desc.blend) and desc.samples == 1 and !desc.alpha_to_coverage and
        !desc.sample_coverage and desc.sample_coverage_value == 1 and !desc.sample_coverage_invert and
        std.meta.eql(desc.stencil, hal.StencilState{}) and desc.stencil_back == null;
}

fn supportedBlend(blend: hal.BlendState) bool {
    if (!blend.enable) return std.meta.eql(blend, hal.BlendState{});
    return blend.src_color == .src_alpha and blend.dst_color == .one_minus_src_alpha and
        blend.src_alpha == .one and blend.dst_alpha == .one_minus_src_alpha and
        blend.color_op == .add and blend.alpha_op == .add and
        std.meta.eql(blend.constant, [4]f32{ 0, 0, 0, 0 }) and
        std.meta.eql(blend.write_mask, [4]bool{ true, true, true, true });
}

const Scalar = union(enum) {
    unknown,
    attribute: u32,
    float: u32,
};

const ShaderMeaning = union(enum) {
    position,
    position_color,
    constant_color: [4]u32,
    vertex_color,
    rounded_rectangle,
    textured_color,
    text,
    image,
};

fn validateShader(gpa: std.mem.Allocator, code: []const u8, stage: hal.ShaderStage) hal.Error!ShaderMeaning {
    var func = @import("../apple/spirv_sampling.zig").parse(gpa, code) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;
    defer func.deinit();
    @import("../apple/flatten.zig").run(&func) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Unsupported;

    const block: F.Block = @fromBackingInt(0);
    switch (func.terminator(block) orelse return error.Unsupported) {
        .ret => {},
        else => return error.Unsupported,
    }
    const values = gpa.alloc(Scalar, func.valueCount()) catch return error.OutOfMemory;
    defer gpa.free(values);
    @memset(values, .unknown);

    const params = func.blockParams(block);
    if (stage == .fragment and params.len == 10) {
        const rendered = std.fmt.allocPrint(gpa, "{f}", .{&func}) catch return error.OutOfMemory;
        defer gpa.free(rendered);
        const fingerprint = std.hash.Wyhash.hash(0, rendered);
        return if (fingerprint == rrect_fragment_fingerprint) .rounded_rectangle else error.Unsupported;
    }
    if (stage == .fragment and params.len == 8) {
        const rendered = std.fmt.allocPrint(gpa, "{f}", .{&func}) catch return error.OutOfMemory;
        defer gpa.free(rendered);
        return switch (std.hash.Wyhash.hash(0, rendered)) {
            text_fragment_fingerprint => .text,
            image_fragment_fingerprint => .image,
            else => error.Unsupported,
        };
    }
    if (stage == .vertex) {
        if (params.len != 2 and params.len != 5 and params.len != 8 and params.len != 12) return error.Unsupported;
        const position_color_params = [_]u32{ 0x80, 0x84, 0x90, 0x94, 0x98 };
        const textured_params = [_]u32{ 0x80, 0x84, 0x90, 0x94, 0xa0, 0xa4, 0xa8, 0xac };
        const rrect_params = [_]u32{ 0x80, 0x84, 0x90, 0x94, 0xa0, 0xa4, 0xa8, 0xac, 0xb0, 0xb4, 0xb8, 0xbc };
        const expected_params: []const u32 = if (params.len == 12)
            &rrect_params
        else if (params.len == 8)
            &textured_params
        else
            position_color_params[0..params.len];
        for (params, expected_params) |param, expected| {
            if (!isF32(&func, param) or attr(&func, param, "attr") != expected) return error.Unsupported;
            values[index(param)] = .{ .attribute = expected };
        }
    } else if (stage == .fragment) {
        if (params.len != 0 and params.len != 3) return error.Unsupported;
        for (params, 0..) |param, component| {
            const expected: u32 = 0x80 + @as(u32, @intCast(component)) * 4;
            if (!isF32(&func, param) or attr(&func, param, "attr") != expected) return error.Unsupported;
            values[index(param)] = .{ .attribute = expected };
        }
    } else return error.Unsupported;

    var outputs: [14]?Scalar = @splat(null);
    for (func.blockInsts(block)) |inst| switch (func.opcode(inst)) {
        .fconst => |number| {
            const result = func.instResult(inst) orelse return error.Unsupported;
            if (!isF32(&func, result)) return error.Unsupported;
            values[index(result)] = .{ .float = @bitCast(@as(f32, @floatCast(number))) };
        },
        .iconst => {}, // output pointer tags produced by the SPIR-V frontend
        .store => |store| {
            if (store.mask != null or store.@"volatile" or !isF32(&func, store.value)) return error.Unsupported;
            const slot = attr(&func, store.ptr, if (stage == .vertex) "out_attr" else "color_out") orelse
                return error.Unsupported;
            const output: usize = if (stage == .vertex) switch (slot) {
                0x70 => 0,
                0x74 => 1,
                0x78 => 2,
                0x7c => 3,
                0x80 => 4,
                0x84 => 5,
                0x88 => 6,
                0x90 => 6,
                0x94 => 7,
                0x98 => 8,
                0x9c => 9,
                0xa0 => 10,
                0xa4 => 11,
                0xa8 => 12,
                0xac => 13,
                else => return error.Unsupported,
            } else if (slot < 4) @intCast(slot) else return error.Unsupported;
            if (outputs[output] != null) return error.Unsupported;
            outputs[output] = values[index(store.value)];
        },
        else => return error.Unsupported,
    };

    const zero: Scalar = .{ .float = @bitCast(@as(f32, 0)) };
    const one: Scalar = .{ .float = @bitCast(@as(f32, 1)) };
    if (stage == .vertex) {
        const expected_position = [4]Scalar{ .{ .attribute = 0x80 }, .{ .attribute = 0x84 }, zero, one };
        for (outputs[0..4], expected_position) |actual, want| {
            if (actual == null or !std.meta.eql(actual.?, want)) return error.Unsupported;
        }
        if (params.len == 2) {
            for (outputs[4..]) |output| if (output != null) return error.Unsupported;
            return .position;
        }
        if (params.len == 12) {
            const expected_rrect = [10]Scalar{
                .{ .attribute = 0x90 }, .{ .attribute = 0x94 },
                .{ .attribute = 0xa0 }, .{ .attribute = 0xa4 },
                .{ .attribute = 0xa8 }, .{ .attribute = 0xac },
                .{ .attribute = 0xb0 }, .{ .attribute = 0xb4 },
                .{ .attribute = 0xb8 }, .{ .attribute = 0xbc },
            };
            for (outputs[4..], expected_rrect) |actual, want| {
                if (actual == null or !std.meta.eql(actual.?, want)) return error.Unsupported;
            }
            return .rounded_rectangle;
        }
        if (params.len == 8) {
            const expected_textured = [6]Scalar{
                .{ .attribute = 0x90 }, .{ .attribute = 0x94 },
                .{ .attribute = 0xa0 }, .{ .attribute = 0xa4 },
                .{ .attribute = 0xa8 }, .{ .attribute = 0xac },
            };
            for (outputs[4..10], expected_textured) |actual, want| {
                if (actual == null or !std.meta.eql(actual.?, want)) return error.Unsupported;
            }
            for (outputs[10..]) |output| if (output != null) return error.Unsupported;
            return .textured_color;
        }
        const expected_color = [3]Scalar{
            .{ .attribute = 0x90 }, .{ .attribute = 0x94 }, .{ .attribute = 0x98 },
        };
        for (outputs[4..7], expected_color) |actual, want| {
            if (actual == null or !std.meta.eql(actual.?, want)) return error.Unsupported;
        }
        for (outputs[7..]) |output| if (output != null) return error.Unsupported;
        return .position_color;
    }
    for (outputs[4..]) |output| if (output != null) return error.Unsupported;
    if (params.len == 3) {
        const expected = [4]Scalar{
            .{ .attribute = 0x80 }, .{ .attribute = 0x84 }, .{ .attribute = 0x88 }, one,
        };
        for (outputs[0..4], expected) |actual, want| {
            if (actual == null or !std.meta.eql(actual.?, want)) return error.Unsupported;
        }
        return .vertex_color;
    }
    var color: [4]u32 = undefined;
    for (outputs[0..4], 0..) |actual, component| color[component] = switch (actual orelse return error.Unsupported) {
        .float => |bits| bits,
        else => return error.Unsupported,
    };
    return .{ .constant_color = color };
}

/// Fingerprint of PhantomUI's rounded-box SDF after SPIR-V parsing and CFG
/// flattening. Matching normalized scalar IR avoids substituting this fixed
/// Valhall template for a merely layout-compatible fragment shader.
const rrect_fragment_fingerprint: u64 = 0x9549_50e3_c417_a254;
const text_fragment_fingerprint: u64 = 0x1861_a990_b8eb_8f7d;
const image_fragment_fingerprint: u64 = 0xc77d_0d07_bc9c_f62b;

fn isF32(func: *const Function, value: Value) bool {
    return switch (func.types.type_kind(func.valueType(value))) {
        .float => |kind| kind == .f32,
        else => false,
    };
}

fn attr(func: *const Function, value: Value, key: []const u8) ?u32 {
    var it = func.attributesOf(.{ .value = value });
    while (it.next()) |attribute| switch (attribute) {
        .custom => |custom| {
            if (!std.mem.eql(u8, custom.namespace, "vulcan.gpu") or !std.mem.eql(u8, custom.key, key)) continue;
            return switch (custom.value) {
                .int => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else null,
                else => null,
            };
        },
        else => {},
    };
    return null;
}

fn index(value: Value) usize {
    return @backingInt(value);
}

test "Mali lowering accepts semantic constant-color shaders and rejects vertex substitutions" {
    const glsl = @import("../../glsl.zig");
    const gpa = std.testing.allocator;
    const vertex = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(vertex);
    const red = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
    , .fragment);
    defer gpa.free(red);
    const green = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }
    , .fragment);
    defer gpa.free(green);
    const mixed = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\void main() { gl_FragColor = vec4(0.25, 0.5, 0.75, 1.0); }
    , .fragment);
    defer gpa.free(mixed);
    const scaled = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\void main() { gl_Position = vec4(p * 0.5, 0.0, 1.0); }
    , .vertex);
    defer gpa.free(scaled);
    const color_vertex = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\attribute vec3 c;
        \\varying vec3 color;
        \\void main() { gl_Position = vec4(p, 0.0, 1.0); color = c; }
    , .vertex);
    defer gpa.free(color_vertex);
    const color_fragment = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\varying vec3 color;
        \\void main() { gl_FragColor = vec4(color, 1.0); }
    , .fragment);
    defer gpa.free(color_fragment);
    const rrect_vertex = try glsl.compileForStage(gpa,
        \\attribute vec2 aPos;
        \\attribute vec2 aLocal;
        \\attribute vec4 aParams;
        \\attribute vec4 aColor;
        \\varying vec2 vLocal;
        \\varying vec4 vParams;
        \\varying vec4 vColor;
        \\void main() { gl_Position = vec4(aPos, 0.0, 1.0); vLocal = aLocal; vParams = aParams; vColor = aColor; }
    , .vertex);
    defer gpa.free(rrect_vertex);
    const rrect_fragment = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\varying vec2 vLocal;
        \\varying vec4 vParams;
        \\varying vec4 vColor;
        \\float sdRoundedBox(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + vec2(r); return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r; }
        \\void main() { float d = sdRoundedBox(vLocal, vParams.xy, vParams.z); float sw = vParams.w; float cov; if (sw > 0.0) { cov = clamp(0.5 - (abs(d + sw * 0.5) - sw * 0.5), 0.0, 1.0); } else { cov = clamp(0.5 - d, 0.0, 1.0); } gl_FragColor = vec4(vColor.rgb, vColor.a * cov); }
    , .fragment);
    defer gpa.free(rrect_fragment);
    const textured_vertex = try glsl.compileForStage(gpa,
        \\attribute vec2 aPos;
        \\attribute vec2 aUV;
        \\attribute vec4 aColor;
        \\varying vec2 vUV;
        \\varying vec4 vColor;
        \\void main() { gl_Position = vec4(aPos, 0.0, 1.0); vUV = aUV; vColor = aColor; }
    , .vertex);
    defer gpa.free(textured_vertex);
    const text_fragment = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\uniform sampler2D uAtlas;
        \\varying vec2 vUV;
        \\varying vec4 vColor;
        \\void main() { float a = texture2D(uAtlas, vUV).a; gl_FragColor = vec4(vColor.rgb, vColor.a * a); }
    , .fragment);
    defer gpa.free(text_fragment);
    const image_fragment = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\uniform sampler2D uTex;
        \\varying vec2 vUV;
        \\varying vec4 vColor;
        \\void main() { vec4 t = texture2D(uTex, vUV); gl_FragColor = vec4(t.rgb, t.a * vColor.a); }
    , .fragment);
    defer gpa.free(image_fragment);

    try std.testing.expectEqual(ShaderMeaning.position, try validateShader(gpa, vertex, .vertex));
    try std.testing.expectEqual(ShaderMeaning{ .constant_color = .{ 0x3f800000, 0, 0, 0x3f800000 } }, try validateShader(gpa, red, .fragment));
    try std.testing.expectEqual(ShaderMeaning{ .constant_color = .{ 0, 0x3f800000, 0, 0x3f800000 } }, try validateShader(gpa, green, .fragment));
    try std.testing.expectEqual(ShaderMeaning{ .constant_color = .{ 0x3e800000, 0x3f000000, 0x3f400000, 0x3f800000 } }, try validateShader(gpa, mixed, .fragment));
    try std.testing.expectError(error.Unsupported, validateShader(gpa, scaled, .vertex));
    try std.testing.expectEqual(ShaderMeaning.position_color, try validateShader(gpa, color_vertex, .vertex));
    try std.testing.expectEqual(ShaderMeaning.vertex_color, try validateShader(gpa, color_fragment, .fragment));
    try std.testing.expectEqual(ShaderMeaning.rounded_rectangle, try validateShader(gpa, rrect_vertex, .vertex));
    try std.testing.expectEqual(ShaderMeaning.rounded_rectangle, try validateShader(gpa, rrect_fragment, .fragment));
    try std.testing.expectEqual(ShaderMeaning.textured_color, try validateShader(gpa, textured_vertex, .vertex));
    try std.testing.expectEqual(ShaderMeaning.text, try validateShader(gpa, text_fragment, .fragment));
    try std.testing.expectEqual(ShaderMeaning.image, try validateShader(gpa, image_fragment, .fragment));
}

test "Mali accepts PhantomUI's premultiplied-alpha destination equation only" {
    try std.testing.expect(supportedBlend(.{}));
    try std.testing.expect(supportedBlend(.{
        .enable = true,
        .src_color = .src_alpha,
        .dst_color = .one_minus_src_alpha,
        .src_alpha = .one,
        .dst_alpha = .one_minus_src_alpha,
    }));
    try std.testing.expect(!supportedBlend(.{ .enable = true }));
}
