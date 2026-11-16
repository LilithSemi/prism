//! GLSL ES 1.00 shader front end: thin seam onto Vulcan's vulcan-glsl compiler.
//! Emits SPIR-V with the same glslang-style shapes spirv.zig already lowers natively.
//! No change to the SPIR-V -> native lowering path is needed.

const std = @import("std");
const glsl = @import("vulcan-glsl");
const hal = @import("hal.zig");

pub const Error = glsl.SpirvError;

/// The pipeline stage a GLSL shader compiles for. Re-exported from Vulcan. Mapped from
/// the HAL `ShaderStage` by `compileToSpirv`.
pub const Stage = glsl.Stage;
pub const UniformScalarType = enum { float, int, uint, bool };

/// Compile GLSL ES 1.00 source for `stage` to a SPIR-V binary (a `[]u32` word stream).
/// Caller owns the result (free it). The stage resolves GLSL ES 1.00 `varying` (an
/// `out` in a vertex shader, an `in` in a fragment shader) and the implicit
/// `gl_FragColor` color output.
pub fn compileShaderToSpirv(allocator: std.mem.Allocator, source: []const u8, stage: Stage) Error![]u32 {
    const normalized = try normalizeSource(allocator, source);
    defer allocator.free(normalized);
    var compiled = try glsl.compileShaderWithLayout(allocator, normalized, stage);
    defer compiled.deinit(allocator);
    return nameInterface(allocator, compiled.spirv, compiled.attributes, compiled.outputs);
}

// SPIR-V locations are assigned independently in each GLSL stage. Retain
// source names as standard OpName debug instructions so native pipeline
// linkers can match varyings when the FS declares a subset or different order.
fn nameInterface(allocator: std.mem.Allocator, words: []const u32, inputs: anytype, outputs: anytype) std.mem.Allocator.Error![]u32 {
    const locations = try allocator.alloc(?u32, words[3]);
    defer allocator.free(locations);
    @memset(locations, null);
    const storage = try allocator.alloc(u32, words[3]);
    defer allocator.free(storage);
    @memset(storage, 0);
    var cursor: usize = 5;
    var insertion: usize = words.len;
    while (cursor < words.len) {
        const opcode = words[cursor] & 0xffff;
        const count = words[cursor] >> 16;
        if (insertion == words.len and (opcode == 71 or opcode == 72 or (opcode >= 19 and opcode <= 39))) insertion = cursor;
        if (opcode == 71 and count == 4 and words[cursor + 2] == 30) locations[words[cursor + 1]] = words[cursor + 3];
        if (opcode == 59 and count >= 4) storage[words[cursor + 2]] = words[cursor + 3];
        cursor += count;
    }
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, words[0..insertion]);
    inline for (.{ inputs, outputs }, .{ @as(u32, 1), @as(u32, 3) }) |members, kind| {
        for (members) |member| {
            if (member.name.len == 0) continue;
            for (locations, storage, 0..) |location, variable_kind, id| {
                if (location != member.location or variable_kind != kind) continue;
                const name_words = (member.name.len + 4) / 4;
                const start = result.items.len;
                try result.resize(allocator, start + name_words + 2);
                result.items[start] = (@as(u32, @intCast(name_words + 2)) << 16) | 5;
                result.items[start + 1] = @intCast(id);
                @memset(result.items[start + 2 ..], 0);
                @memcpy(std.mem.sliceAsBytes(result.items[start + 2 ..])[0..member.name.len], member.name);
            }
        }
    }
    try result.appendSlice(allocator, words[insertion..]);
    return result.toOwnedSlice(allocator);
}

/// The pinned compiler supports scalar comparisons but not the bool constructor.
/// Lower bool(x) to ((x) != 0), evaluating x once and retaining source newlines.
/// Precision qualifiers are advisory in Prism's f32 shader ABI. Remove them
/// before parsing, including local qualifiers the pinned parser does not accept.
/// Do this at Prism's GLSL entry points so all drivers receive identical SPIR-V.
fn normalizeSource(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var constructors: std.ArrayList(usize) = .empty;
    defer constructors.deinit(allocator);
    var depth: usize = 0;
    var cursor: usize = 0;
    var copied: usize = 0;
    var braces: usize = 0;
    var in_function = false;
    var previous: []const u8 = "";
    while (sourceToken(source, &cursor)) |token| {
        // The pinned parser accepts compound bodies of if/for statements,
        // but not a standalone compound statement. An always-taken if keeps
        // the block's scope and execution semantics, including local names.
        if (std.mem.eql(u8, token.text, "{")) {
            if (braces == 0 and std.mem.eql(u8, previous, ")")) in_function = true;
            if (in_function and braces != 0 and
                (std.mem.eql(u8, previous, ";") or std.mem.eql(u8, previous, "{") or std.mem.eql(u8, previous, "}")))
            {
                try result.appendSlice(allocator, source[copied..token.start]);
                try result.appendSlice(allocator, "if (true) ");
                copied = token.start;
            }
            braces += 1;
        } else if (std.mem.eql(u8, token.text, "}")) {
            braces -|= 1;
            if (braces == 0) in_function = false;
        }
        if (std.mem.eql(u8, token.text, "highp") or std.mem.eql(u8, token.text, "mediump") or std.mem.eql(u8, token.text, "lowp")) {
            try result.appendSlice(allocator, source[copied..token.start]);
            copied = token.end;
        } else if (std.mem.eql(u8, token.text, "bool")) {
            var lookahead = cursor;
            if (sourceToken(source, &lookahead)) |next| {
                if (std.mem.eql(u8, next.text, "(")) {
                    try result.appendSlice(allocator, source[copied..token.start]);
                    try result.append(allocator, '(');
                    copied = token.end;
                    try constructors.append(allocator, depth + 1);
                }
            }
        } else if (std.mem.eql(u8, token.text, "(")) {
            depth += 1;
        } else if (std.mem.eql(u8, token.text, ")")) {
            if (constructors.items.len != 0 and constructors.items[constructors.items.len - 1] == depth) {
                try result.appendSlice(allocator, source[copied..token.end]);
                try result.appendSlice(allocator, " != 0)");
                copied = token.end;
                constructors.items.len -= 1;
            }
            depth -|= 1;
        }
        previous = token.text;
    }
    try result.appendSlice(allocator, source[copied..]);
    return result.toOwnedSlice(allocator);
}

const SourceToken = struct { text: []const u8, start: usize, end: usize };

// Default-block storage is scalarized to f32 by the compiler. Retain the
// source-level type separately for glGetActiveUniform: applications use it to
// choose the appropriate glUniform* setter, even though the HAL ABI is f32.
fn declaredUniformScalarType(source: []const u8, name: []const u8) UniformScalarType {
    var cursor: usize = 0;
    while (sourceToken(source, &cursor)) |token| {
        if (!std.mem.eql(u8, token.text, "uniform")) continue;
        var ty = sourceToken(source, &cursor) orelse break;
        if (std.mem.eql(u8, ty.text, "lowp") or std.mem.eql(u8, ty.text, "mediump") or std.mem.eql(u8, ty.text, "highp"))
            ty = sourceToken(source, &cursor) orelse break;
        const scalar: UniformScalarType = if (std.mem.eql(u8, ty.text, "int") or std.mem.startsWith(u8, ty.text, "ivec")) .int else if (std.mem.eql(u8, ty.text, "uint") or std.mem.startsWith(u8, ty.text, "uvec")) .uint else if (std.mem.eql(u8, ty.text, "bool") or std.mem.startsWith(u8, ty.text, "bvec")) .bool else .float;
        while (sourceToken(source, &cursor)) |decl| {
            if (std.mem.eql(u8, decl.text, ";") or std.mem.eql(u8, decl.text, "{")) break;
            if (std.mem.eql(u8, decl.text, name)) return scalar;
        }
    }
    return .float;
}

fn sourceToken(source: []const u8, cursor: *usize) ?SourceToken {
    while (cursor.* < source.len) {
        const start = cursor.*;
        if (std.ascii.isWhitespace(source[start])) {
            cursor.* += 1;
        } else if (std.mem.startsWith(u8, source[start..], "//")) {
            while (cursor.* < source.len and source[cursor.*] != '\n') cursor.* += 1;
        } else if (std.mem.startsWith(u8, source[start..], "/*")) {
            cursor.* += 2;
            while (cursor.* < source.len and !std.mem.startsWith(u8, source[cursor.*..], "*/")) cursor.* += 1;
            cursor.* = @min(source.len, cursor.* + 2);
        } else if (source[start] == '"') {
            cursor.* += 1;
            while (cursor.* < source.len) {
                const ch = source[cursor.*];
                cursor.* += 1;
                if (ch == '"') break;
                if (ch == '\\' and cursor.* < source.len) cursor.* += 1;
            }
        } else {
            cursor.* += 1;
            if (std.ascii.isAlphanumeric(source[start]) or source[start] == '_') {
                while (cursor.* < source.len and (std.ascii.isAlphanumeric(source[cursor.*]) or source[cursor.*] == '_')) cursor.* += 1;
            }
            return .{ .text = source[start..cursor.*], .start = start, .end = cursor.* };
        }
    }
    return null;
}

/// Compile GLSL ES source for a HAL `ShaderStage` (the EGL/GLES caller's stage type)
/// to a SPIR-V *byte* stream the HAL `createShaderModule`/`prism.spirv.parseSpirv`
/// path consumes. Caller owns the returned bytes (free with the same allocator).
pub fn compileForStage(allocator: std.mem.Allocator, source: []const u8, stage: hal.ShaderStage) Error![]u8 {
    const vk_stage: Stage = switch (stage) {
        .vertex => .vertex,
        .fragment => .fragment,
        .compute => .compute,
    };
    const words = try compileShaderToSpirv(allocator, source, vk_stage);
    defer allocator.free(words);
    const bytes = try allocator.alloc(u8, words.len * 4);
    @memcpy(bytes, std.mem.sliceAsBytes(words));
    return bytes;
}

/// One member of the default uniform block: its name (heap-duped), byte offset within the
/// block, and float count. Re-exported from Vulcan's lowering so the GLES layer can resolve
/// glGetUniformLocation + write glUniform* bytes at the matching offset.
pub const UniformMember = struct {
    scalar_type: UniformScalarType = .float,
    name: []const u8,
    /// Byte offset of this uniform within the default uniform block (tight-packed std140
    /// for the all-vec4/mat4 case es2gears uses).
    offset: u32,
    /// Number of floats one element occupies (mat4 = 16, vec4 = 4, scalar = 1). For an
    /// array uniform this is the per-element stride. For a scalar uniform it is the whole
    /// member.
    float_count: u32,
    /// Matrix dimension (2/3/4) for a matN uniform, else 0.
    mat_dim: u8,
    /// Array length for an array uniform (`uniform vec3 c[3];` -> 3), else 1. Element `i`
    /// of the array lives at byte `offset + i * float_count * 4`.
    array_len: u32 = 1,
};

/// One `uniform sampler2D` member: its name (heap-duped) and SPIR-V binding. Samplers
/// start at binding 2. Bindings 0/1 are reserved for the per-stage default uniform
/// blocks, so a sampler descriptor never shares the nvidia backend's shared-constant-bank
/// slot the uniform-block pointer uses. The GLES layer maps a sampler name -> binding so
/// the texture unit set via glUniform1i binds the right texture at draw time.
pub const SamplerMember = struct {
    name: []const u8,
    binding: u32,
    /// true for a `samplerCube` (sampled by a vec3 direction). false for a plain sampler2D.
    /// The GLES layer resolves a cube sampler's texture from GL_TEXTURE_CUBE_MAP at draw.
    cube: bool = false,
    /// true for a `sampler3D` (a vec3 coordinate into a volume). Resolved from GL_TEXTURE_3D.
    tex3d: bool = false,
    /// true for a `sampler2DArray` (a vec3 (u,v,layer)). Resolved from GL_TEXTURE_2D_ARRAY.
    tex2darray: bool = false,
};

/// One vertex-attribute member (re-exported from Vulcan): its name (heap-duped) and the
/// pipeline location the GLSL lowering assigned it. The GLES layer records these at link
/// time and resolves glGetAttribLocation/glGetActiveAttrib + the draw-time vertex layout
/// against them, instead of a name-substring heuristic.
pub const AttributeMember = struct {
    name: []const u8,
    location: u32,
    /// Component count (1 scalar, 2..4 vector), reported by glGetActiveAttrib.
    components: u8,
};

/// One vertex-shader output varying (re-exported from Vulcan): its name (heap-duped) and the
/// pipeline location the GLSL lowering assigned it, plus the component count. The GLES layer
/// records these at link time and maps a glTransformFeedbackVaryings capture name to the VS
/// output slot (location*4 + component) the software driver reads when capturing transform
/// feedback. Builtins (gl_Position/gl_PointSize) are not surfaced here.
pub const OutputMember = struct {
    name: []const u8,
    location: u32,
    components: u8,
};

/// One named uniform interface block (re-exported from Vulcan): its name (heap-duped), its
/// GL binding point (`layout(binding=N)`, else its declaration index), and its byte size
/// (GL_UNIFORM_BLOCK_DATA_SIZE). The GLES layer resolves glGetUniformBlockIndex to this and
/// routes the glBindBufferBase'd buffer to the block at draw time.
pub const UniformBlock = struct {
    name: []const u8,
    binding: u32,
    byte_offset: u32,
    /// std140 block size (GL_UNIFORM_BLOCK_DATA_SIZE), rounded up to 16.
    byte_size: u32,
    /// The std140<->tight repack table (one entry per member, see prism.glsl.UniformBlockMember).
    /// For an all-16-byte-member block each entry is an identity copy. Heap-owned. Freed by
    /// CompiledShader.deinit. Empty only for a block with no members.
    members: []const UniformBlockMember = &.{},
};

/// One member of a named uniform block (re-exported from Vulcan): how to repack it from a
/// std140 user buffer (glBindBufferBase) into the tight layout the shader reads. All offsets
/// are block-relative. The host copies `unit_count` chunks of `copy_bytes`. Chunk `u` moves
/// `std140_offset + u*std140_stride` (user buffer) to `tight_offset + u*tight_stride` (tight UBO).
pub const UniformBlockMember = glsl.UniformBlockMember;

/// A compiled shader: SPIR-V bytes + the default-uniform-block layout + the sampler
/// members + the vertex attributes + the named uniform blocks. Caller owns all and frees
/// them via `deinit`.
pub const CompiledShader = struct {
    spirv: []u8,
    uniforms: []UniformMember,
    samplers: []SamplerMember,
    attributes: []AttributeMember,
    outputs: []OutputMember,
    uniform_blocks: []UniformBlock,
    block_size: u32,

    pub fn deinit(self: *CompiledShader, allocator: std.mem.Allocator) void {
        allocator.free(self.spirv);
        for (self.uniforms) |u| allocator.free(u.name);
        allocator.free(self.uniforms);
        for (self.samplers) |s| allocator.free(s.name);
        allocator.free(self.samplers);
        for (self.attributes) |a| allocator.free(a.name);
        allocator.free(self.attributes);
        for (self.outputs) |o| allocator.free(o.name);
        allocator.free(self.outputs);
        for (self.uniform_blocks) |b| {
            allocator.free(b.name);
            allocator.free(b.members);
        }
        allocator.free(self.uniform_blocks);
        self.* = undefined;
    }
};

/// Compile GLSL ES source for a HAL `ShaderStage` to SPIR-V bytes and the
/// default-uniform-block layout (name -> byte offset), so the GLES layer can implement
/// glGetUniformLocation + glUniform*. Caller owns the result (`deinit`).
pub fn compileForStageWithLayout(allocator: std.mem.Allocator, source: []const u8, stage: hal.ShaderStage) Error!CompiledShader {
    const vk_stage: Stage = switch (stage) {
        .vertex => .vertex,
        .fragment => .fragment,
        .compute => .compute,
    };
    const normalized = try normalizeSource(allocator, source);
    defer allocator.free(normalized);
    var c = try glsl.compileShaderWithLayout(allocator, normalized, vk_stage);
    const named = nameInterface(allocator, c.spirv, c.attributes, c.outputs) catch |err| {
        c.deinit(allocator);
        return err;
    };
    allocator.free(c.spirv);
    c.spirv = named;
    // Transfer the SPIR-V words into a byte buffer. Transfer the uniform names verbatim.
    const bytes = allocator.alloc(u8, c.spirv.len * 4) catch |e| {
        c.deinit(allocator);
        return e;
    };
    @memcpy(bytes, std.mem.sliceAsBytes(c.spirv));
    allocator.free(c.spirv);
    c.spirv = &.{};

    const members = allocator.alloc(UniformMember, c.uniforms.len) catch |e| {
        c.deinit(allocator);
        allocator.free(bytes);
        return e;
    };
    for (c.uniforms, 0..) |u, i| {
        members[i] = .{ .name = u.name, .offset = u.offset_floats * 4, .float_count = u.float_count, .mat_dim = u.mat_dim, .array_len = u.array_len, .scalar_type = declaredUniformScalarType(source, u.name) };
    }
    // Transfer the sampler members (name -> binding). Names transferred verbatim.
    const samplers = allocator.alloc(SamplerMember, c.samplers.len) catch |e| {
        c.deinit(allocator);
        allocator.free(bytes);
        allocator.free(members);
        return e;
    };
    for (c.samplers, 0..) |s, i| samplers[i] = .{ .name = s.name, .binding = s.binding, .cube = s.cube, .tex3d = s.tex3d, .tex2darray = s.tex2darray };
    // Transfer the attribute members (name -> location + components). Names transferred verbatim.
    const attributes = allocator.alloc(AttributeMember, c.attributes.len) catch |e| {
        c.deinit(allocator);
        allocator.free(bytes);
        allocator.free(members);
        allocator.free(samplers);
        return e;
    };
    for (c.attributes, 0..) |a, i| attributes[i] = .{ .name = a.name, .location = a.location, .components = a.components };
    // Transfer the VS output varyings (name -> location + components). Names transferred verbatim.
    const outputs = allocator.alloc(OutputMember, c.outputs.len) catch |e| {
        c.deinit(allocator);
        allocator.free(bytes);
        allocator.free(members);
        allocator.free(samplers);
        allocator.free(attributes);
        return e;
    };
    for (c.outputs, 0..) |o, i| outputs[i] = .{ .name = o.name, .location = o.location, .components = o.components };
    // Transfer the named uniform blocks (names transferred verbatim).
    const uniform_blocks = allocator.alloc(UniformBlock, c.uniform_blocks.len) catch |e| {
        c.deinit(allocator);
        allocator.free(bytes);
        allocator.free(members);
        allocator.free(samplers);
        allocator.free(attributes);
        allocator.free(outputs);
        return e;
    };
    // Transfer both the name and the std140 member table verbatim (freed by our deinit).
    for (c.uniform_blocks, 0..) |b, i| uniform_blocks[i] = .{ .name = b.name, .binding = b.binding, .byte_offset = b.byte_offset, .byte_size = b.byte_size, .members = b.members };
    const block_size = c.block_size;
    // Free the vulcan member arrays (not the names, which were transferred above).
    allocator.free(c.uniforms);
    c.uniforms = &.{};
    allocator.free(c.samplers);
    c.samplers = &.{};
    allocator.free(c.attributes);
    c.attributes = &.{};
    allocator.free(c.outputs);
    c.outputs = &.{};
    allocator.free(c.uniform_blocks);
    c.uniform_blocks = &.{};
    return .{ .spirv = bytes, .uniforms = members, .samplers = samplers, .attributes = attributes, .outputs = outputs, .uniform_blocks = uniform_blocks, .block_size = block_size };
}

test "glsl: the gradient-triangle VS+FS compile from GLSL ES 1.00 source to SPIR-V bytes" {
    const gpa = std.testing.allocator;
    const vs_src =
        \\attribute vec2 aPos;
        \\attribute vec3 aColor;
        \\varying vec3 vColor;
        \\void main() { gl_Position = vec4(aPos, 0.0, 1.0); vColor = aColor; }
    ;
    const fs_src =
        \\precision mediump float;
        \\varying vec3 vColor;
        \\void main() { gl_FragColor = vec4(vColor, 1.0); }
    ;
    const vs = try compileForStage(gpa, vs_src, .vertex);
    defer gpa.free(vs);
    const fs = try compileForStage(gpa, fs_src, .fragment);
    defer gpa.free(fs);
    // SPIR-V magic in the first word (little-endian bytes).
    try std.testing.expectEqual(@as(u8, 0x03), vs[0]);
    try std.testing.expectEqual(@as(u8, 0x02), vs[1]);
    try std.testing.expect(vs.len % 4 == 0 and fs.len % 4 == 0);

    // Both lower back to Vulcan IR through Prism's SPIR-V seam (the draw-time path).
    const prism_spirv = @import("spirv.zig");
    var vf = try prism_spirv.parseSpirv(gpa, vs);
    vf.deinit();
    var ff = try prism_spirv.parseSpirv(gpa, fs);
    ff.deinit();
}

test "glsl: the es2gears VS compiles + surfaces its uniform layout + round-trips" {
    const gpa = std.testing.allocator;
    const vs_src =
        \\attribute vec3 position;
        \\attribute vec3 normal;
        \\uniform mat4 ModelViewProjectionMatrix;
        \\uniform mat4 NormalMatrix;
        \\uniform vec4 LightSourcePosition;
        \\uniform vec4 MaterialColor;
        \\varying vec4 Color;
        \\void main(void) {
        \\  vec3 N = normalize(vec3(NormalMatrix * vec4(normal, 1.0)));
        \\  vec3 L = normalize(LightSourcePosition.xyz);
        \\  float diffuse = max(dot(N, L), 0.0);
        \\  float ambient = 0.2;
        \\  Color = vec4((ambient + diffuse) * MaterialColor.xyz, MaterialColor.a);
        \\  gl_Position = ModelViewProjectionMatrix * vec4(position, 1.0);
        \\}
    ;
    var c = try compileForStageWithLayout(gpa, vs_src, .vertex);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), c.uniforms.len);
    try std.testing.expectEqualStrings("ModelViewProjectionMatrix", c.uniforms[0].name);
    try std.testing.expectEqual(@as(u32, 0), c.uniforms[0].offset);
    try std.testing.expectEqual(@as(u32, 64), c.uniforms[1].offset); // NormalMatrix @ byte 64
    try std.testing.expectEqual(@as(u32, 128), c.uniforms[2].offset); // LightSourcePosition @ 128
    try std.testing.expectEqual(@as(u32, 144), c.uniforms[3].offset); // MaterialColor @ 144
    try std.testing.expectEqual(@as(u32, 160), c.block_size);
    // Round-trips through Prism's SPIR-V seam (the draw-time path).
    const prism_spirv = @import("spirv.zig");
    var vf = try prism_spirv.parseSpirv(gpa, c.spirv);
    vf.deinit();
}

test "glsl: a textured FS surfaces its sampler members + coexisting UBO uniforms" {
    const gpa = std.testing.allocator;
    const fs_src =
        \\precision mediump float;
        \\uniform sampler2D uTex;
        \\uniform vec4 uTint;
        \\varying vec2 vUV;
        \\void main(void) { gl_FragColor = texture2D(uTex, vUV) * uTint; }
    ;
    var c = try compileForStageWithLayout(gpa, fs_src, .fragment);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), c.samplers.len);
    try std.testing.expectEqualStrings("uTex", c.samplers[0].name);
    // The first sampler is at binding 2: bindings 0 and 1 are reserved for the per-stage default
    // uniform blocks (VS block at 0, FS block at 1, the `uTint` block here), so the sampler
    // descriptor never shares the shared-constant-bank slot a uniform-block pointer uses (which
    // made a textured + uniform shader render black, or fault the GPU, on the nvidia backend).
    // Coexisting UBO uniform still lives at its block's byte offset 0.
    try std.testing.expectEqual(@as(u32, 2), c.samplers[0].binding);
    // The non-sampler uniform is a UBO member (byte offset 0, 4 floats).
    try std.testing.expectEqual(@as(usize, 1), c.uniforms.len);
    try std.testing.expectEqualStrings("uTint", c.uniforms[0].name);
    try std.testing.expectEqual(@as(u32, 0), c.uniforms[0].offset);
    // Round-trips through Prism's SPIR-V seam.
    const prism_spirv = @import("spirv.zig");
    var ff = try prism_spirv.parseSpirv(gpa, c.spirv);
    ff.deinit();
}

test "glsl: a malformed shader surfaces a compile error (no crash)" {
    const gpa = std.testing.allocator;
    // Missing semicolon / garbage: the frontend must return an error, not panic.
    try std.testing.expectError(error.ParseError, compileForStage(gpa, "void main( { ", .fragment));
    // No main() is a defined failure too.
    try std.testing.expectError(error.MissingMain, compileForStage(gpa, "float x;", .vertex));
}

test "GLSL scalar bool constructors lower without touching comments or declarations" {
    const allocator = std.testing.allocator;
    const input = "bool flag; // bool(fake)\nif (bool /* keep */ (bool(x + f(2)))) flag = true;";
    const lowered = try normalizeSource(allocator, input);
    defer allocator.free(lowered);
    try std.testing.expectEqualStrings("bool flag; // bool(fake)\nif (( /* keep */ (((x + f(2)) != 0)) != 0)) flag = true;", lowered);
}

test "GLSL Luanti texture-enable condition compiles through both entry points" {
    const allocator = std.testing.allocator;
    const source =
        \\precision mediump float;
        \\uniform int enabled;
        \\uniform sampler2D image;
        \\varying vec2 uv;
        \\varying vec4 color;
        \\void main() {
        \\    vec4 result = color;
        \\    if (bool(enabled)) result *= texture2D(image, uv);
        \\    gl_FragColor = result;
        \\}
    ;
    const words = try compileShaderToSpirv(allocator, source, .fragment);
    defer allocator.free(words);
    var compiled = try compileForStageWithLayout(allocator, source, .fragment);
    defer compiled.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), compiled.uniforms.len);
    try std.testing.expectEqualStrings("enabled", compiled.uniforms[0].name);
    try std.testing.expectEqual(UniformScalarType.int, compiled.uniforms[0].scalar_type);
    try std.testing.expectEqual(@as(usize, 1), compiled.samplers.len);
}

test "GLSL precision-qualified locals used by Luanti postprocessing compile" {
    const allocator = std.testing.allocator;
    const source =
        \\precision mediump float;
        \\highp vec3 dither(highp vec2 position) {
        \\    highp vec3 noise = vec3(dot(position, vec2(171.0, 231.0)));
        \\    return fract(noise / vec3(103.0, 71.0, 97.0));
        \\}
        \\void main() { gl_FragColor = vec4(dither(gl_FragCoord.xy), 1.0); }
    ;
    const words = try compileShaderToSpirv(allocator, source, .fragment);
    defer allocator.free(words);
    try std.testing.expect(words.len > 5);
}

test "GLSL postprocessing compound statements retain their lexical scopes" {
    const allocator = std.testing.allocator;
    const source =
        \\precision mediump float;
        \\uniform float exposure;
        \\uniform sampler2D rendered;
        \\varying vec2 uv;
        \\void main() {
        \\    vec4 color = texture2D(rendered, uv);
        \\    { color.rgb *= exposure; }
        \\    { float scale = 0.5; color.rgb *= scale; }
        \\    { float scale = 0.75; color.rgb *= scale; }
        \\    gl_FragColor = color;
        \\}
    ;
    const words = try compileShaderToSpirv(allocator, source, .fragment);
    defer allocator.free(words);
    var compiled = try compileForStageWithLayout(allocator, source, .fragment);
    defer compiled.deinit(allocator);
    try std.testing.expect(words.len > 5);
}
