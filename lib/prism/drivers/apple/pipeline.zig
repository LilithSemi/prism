const std = @import("std");
const hal = @import("../../hal.zig");
const graphics = @import("graphics.zig");
const Shader = @import("shader.zig").ShaderModule;

pub const Pipeline = struct {
    vertex: graphics.Program,
    fragment: graphics.Program,
    stride: u32,
    color_format: hal.Format,
    depth: hal.DepthState,
    cull: hal.CullState,
    blend: hal.BlendState,

    pub fn create(gpa: std.mem.Allocator, desc: hal.PipelineDesc) hal.Error!*Pipeline {
        if (desc.depth.bias_enable) return error.Unsupported;
        if (desc.color_format != .rgba8_unorm and desc.color_format != .bgra8_unorm) return error.Unsupported;
        // Reject state that the native render pass does not implement yet.
        const supported: hal.PipelineDesc = .{
            .vertex = desc.vertex,
            .fragment = desc.fragment,
            .vertex_layout = desc.vertex_layout,
            .color_format = desc.color_format,
            .depth = desc.depth,
            .cull = desc.cull,
            .blend = desc.blend,
        };
        if (!std.meta.eql(desc, supported)) return error.Unsupported;
        const vs: *Shader = @ptrCast(@alignCast(desc.vertex));
        const fs: *Shader = @ptrCast(@alignCast(desc.fragment));
        if (vs.stage != .vertex or fs.stage != .fragment) return error.InvalidArgument;
        const p = gpa.create(Pipeline) catch return error.OutOfMemory;
        errdefer gpa.destroy(p);
        p.vertex = try graphics.compile(gpa, vs.code, .vertex, desc.vertex_layout, desc.color_format);
        p.fragment = try graphics.compileWithBlend(gpa, fs.code, .fragment, desc.vertex_layout, desc.color_format, desc.blend);
        for (p.fragment.inputs[0..p.fragment.input_count]) |slot| {
            if (p.vertex.outputs[slot] == null) return error.Unsupported;
        }
        p.stride = desc.vertex_layout.stride;
        p.color_format = desc.color_format;
        p.depth = desc.depth;
        p.cull = desc.cull;
        p.blend = desc.blend;
        return p;
    }
};

test "apple native graphics compiles changing SPIR-V and links interpolated color" {
    const glsl = @import("../../glsl.zig");
    const gpa = std.testing.allocator;
    const vs = try glsl.compileForStage(gpa,
        \\attribute vec2 p;
        \\attribute vec3 c;
        \\varying vec3 color;
        \\void main() { gl_Position = vec4(p * 0.5, 0.0, 1.0); color = c; }
    , .vertex);
    defer gpa.free(vs);
    const fs = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\varying vec3 color;
        \\void main() { gl_FragColor = vec4(color * 0.75 + 0.1, 1.0); }
    , .fragment);
    defer gpa.free(fs);
    const vs_mod = try Shader.create(gpa, .{ .stage = .vertex, .code = vs });
    defer vs_mod.destroy(gpa);
    const fs_mod = try Shader.create(gpa, .{ .stage = .fragment, .code = fs });
    defer fs_mod.destroy(gpa);
    const desc: hal.PipelineDesc = .{
        .vertex = @ptrCast(vs_mod),
        .fragment = @ptrCast(fs_mod),
        .vertex_layout = .{ .stride = 20, .attributes = &.{
            .{ .location = 0, .format = .r32g32_float, .offset = 0 },
            .{ .location = 1, .format = .r32g32b32_float, .offset = 8 },
        } },
        .color_format = .rgba8_unorm,
    };
    const p = try Pipeline.create(gpa, desc);
    defer gpa.destroy(p);
    try std.testing.expectEqual(@as(u32, 3), p.vertex.varying_count);
    try std.testing.expectEqual(@as(u32, 3), p.fragment.input_count);
    try std.testing.expect(p.vertex.len > 0 and p.fragment.len > 0);
    var unsupported = desc;
    unsupported.samples = 4;
    try std.testing.expectError(error.Unsupported, Pipeline.create(gpa, unsupported));
    unsupported = desc;
    unsupported.depth.bias_enable = true;
    try std.testing.expectError(error.Unsupported, Pipeline.create(gpa, unsupported));

    const textured = try glsl.compileForStage(gpa,
        \\precision mediump float;
        \\uniform sampler2D image;
        \\varying vec3 color;
        \\void main() { gl_FragColor = texture2D(image, color.xy); }
    , .fragment);
    defer gpa.free(textured);
    const texture_program = try graphics.compile(gpa, textured, .fragment, desc.vertex_layout, desc.color_format);
    try std.testing.expectEqual(@as(u8, 1 << 2), texture_program.texture_mask);
    try std.testing.expectError(error.Unsupported, graphics.compile(gpa, fs, .vertex, desc.vertex_layout, desc.color_format));
}
