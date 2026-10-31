//! Uncompressed RGBA8 AGX mip layout. Large levels use 16-KiB tiles;
//! the small mip tail uses progressively smaller Morton-ordered tiles.
const std = @import("std");

pub const Level = struct { offset: usize, width: u32, height: u32, tile: u32 };
pub const Layout = struct { levels: [15]Level = undefined, count: u8, size: usize };

fn pot(n: u32) u32 {
    return std.math.ceilPowerOfTwo(u32, n) catch unreachable;
}
fn minify(n: u32, level: usize) u32 {
    return @max(1, n >> @intCast(level));
}

pub fn layout(width: u32, height: u32, count: u8) Layout {
    var tail: usize = 0;
    while (minify(width, tail) >= 64 and minify(height, tail) >= 64) tail += 1;
    const tiles_x = (width + 63) / 64;
    const tiles_y = (height + 63) / 64;
    var out: Layout = .{ .count = count, .size = 0 };
    var padded_w = pot(minify(width, tail));
    var padded_h = pot(minify(height, tail));
    for (0..count) |level| {
        const w = minify(width, level);
        const h = minify(height, level);
        const tile = if (level < tail) 64 else pot(minify(@min(width, height), level));
        out.levels[level] = .{ .offset = out.size, .width = w, .height = h, .tile = tile };
        if (level < tail) {
            const low_mask = (@as(u32, 1) << @intCast(level)) - 1;
            const pad_x = tiles_x & low_mask != 0;
            const pad_y = tiles_y & low_mask != 0;
            const tiles = ((tiles_x * tiles_y) >> @intCast(2 * level)) +
                (if (pad_x) tiles_y >> @intCast(level) else 0) +
                (if (pad_y) tiles_x >> @intCast(level) else 0) +
                @as(u32, @intFromBool(pad_x and pad_y));
            out.size += @as(usize, tiles) * 16384;
        } else {
            out.size += @as(usize, padded_w) * padded_h * 4;
            padded_w = @max(1, padded_w / 2);
            padded_h = @max(1, padded_h / 2);
        }
        out.size = std.mem.alignForward(usize, out.size, 128);
    }
    return out;
}

pub fn texelOffset(level: Level, x: usize, y: usize) usize {
    var morton: usize = 0;
    var bit: usize = 0;
    while ((@as(usize, 1) << @intCast(bit)) < level.tile) : (bit += 1) {
        morton |= (((x % level.tile) >> @intCast(bit)) & 1) << @intCast(bit * 2);
        morton |= (((y % level.tile) >> @intCast(bit)) & 1) << @intCast(bit * 2 + 1);
    }
    const columns = (@as(usize, level.width) + level.tile - 1) / level.tile;
    return level.offset + (((y / level.tile) * columns + x / level.tile) * level.tile * level.tile + morton) * 4;
}

pub fn upload(out: []u8, pixels: []const u8, desc: Layout) void {
    var source: usize = 0;
    for (desc.levels[0..desc.count]) |level| {
        for (0..level.height) |y| for (0..level.width) |x| {
            const src = source + (y * level.width + x) * 4;
            @memcpy(out[texelOffset(level, x, y)..][0..4], pixels[src..][0..4]);
        };
        source += @as(usize, level.width) * level.height * 4;
    }
}

test "AGX mip offsets stay within allocation for rectangular and odd-sized images" {
    for ([_][2]u32{ .{ 256, 256 }, .{ 129, 65 }, .{ 33, 17 }, .{ 8, 8 } }) |size| {
        const count: u8 = @intCast(1 + std.math.log2_int(u32, @max(size[0], size[1])));
        const desc = layout(size[0], size[1], count);
        for (desc.levels[0..count]) |level| {
            try std.testing.expect(texelOffset(level, level.width - 1, level.height - 1) + 4 <= desc.size);
        }
    }
}
