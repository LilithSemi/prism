//! Valhall FP32 math sequences for terrain lighting and fog. Range reduction
//! follows Mesa's bifrost_compile.c (MIT), using the native Valhall SFUs.
const std = @import("std");
pub const Emitter = struct {
    gpa: std.mem.Allocator,
    code: *std.ArrayList(u8),

    pub fn emit(self: Emitter, raw: u64) std.mem.Allocator.Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, raw, .little);
        try self.code.appendSlice(self.gpa, &bytes);
    }
    pub fn constant(self: Emitter, reg: u6, bits: u32) std.mem.Allocator.Error!void {
        try self.emit(dest(0x110, reg) | 0xc0 | (@as(u64, bits) << 8));
    }
    pub fn fma(self: Emitter, reg: u6, a: u8, b: u8, c: u8) std.mem.Allocator.Error!void {
        try self.emit(dest(0xb2, reg) | a | (@as(u64, b) << 8) | (@as(u64, c) << 16));
    }
    /// Inputs/destination must avoid reserved scratch registers 50..58.
    pub fn log2(self: Emitter, reg: u6, value: u6) std.mem.Allocator.Error!void {
        try self.emit(dest(0x99, 50) | (2 << 16) | (1 << 25) | value); // FREXPE.log
        try self.emit(dest(0x90, 50) | (9 << 16) | 50); // S32_TO_F32
        try self.emit(dest(0x9c, 51) | (8 << 16) | value); // FLOGD
        try self.constant(52, 0xbf80_0000);
        try self.emit(dest(0xa4, 52) | (9 << 16) | 52 | (@as(u64, value) << 8)); // FADD_LSCALE
        try self.fma(reg, 51, 52, 50);
    }
    pub fn pow(self: Emitter, reg: u6, base: u6, exponent: u6) std.mem.Allocator.Error!void {
        // Keep log2(base) in the destination: log2's scratch set excludes it.
        try self.log2(reg, base);
        try self.constant(54, 24);
        // FMA_RSCALE forms exponent*log2(base)*2^24 for FEXP's 8:24 input.
        try self.emit(dest(0x160, 55) | exponent | (@as(u64, reg) << 8) | (@as(u64, 0xc0) << 16) | (@as(u64, 54) << 24) | (@as(u64, 1) << 34));
        try self.emit(dest(0x90, 56) | (12 << 16) | 55); // F32_TO_S32
        try self.emit(dest(0xa4, reg) | (8 << 16) | 56 | (@as(u64, 55) << 8)); // FEXP
    }
    pub fn sqrt(self: Emitter, reg: u6, value: u6) std.mem.Allocator.Error!void {
        try self.emit(dest(0x9c, 50) | (2 << 16) | value); // FRSQ
        try self.fma(reg, value, 50, 0xc0);
        // Multiplication by reciprocal sqrt needs explicit 0/Inf handling.
        try self.emit(dest(0x154, reg) | value | (@as(u64, 0xc0) << 8) | (@as(u64, 0xc0) << 16) | (@as(u64, reg) << 24));
        try self.constant(51, 0x7f80_0000);
        try self.emit(dest(0x154, reg) | value | (@as(u64, 51) << 8) | (@as(u64, 51) << 16) | (@as(u64, reg) << 24));
    }
};
pub fn dest(opcode: u64, reg: u6) u64 {
    return (opcode << 48) | ((@as(u64, reg) | 0xc0) << 40);
}
