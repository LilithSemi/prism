const builtin = @import("builtin");
const build_options = @import("build-options");

pub const Buffer = @import("platform/surface.zig").Buffer;
pub const SurfaceDesc = @import("platform/surface.zig").SurfaceDesc;
pub const WindowEvent = @import("platform/surface.zig").WindowEvent;
pub const Surface = @import("platform/surface.zig").Surface;
pub const Display = @import("platform/surface.zig").Display;

pub const headless_enabled = build_options.display_headless;
pub const drm_enabled = builtin.target.os.tag == .linux and build_options.display_drm;
pub const gbm_enabled = builtin.target.os.tag == .linux and build_options.display_gbm;
pub const wayland_enabled = builtin.target.os.tag == .linux and build_options.display_wayland;
pub const x11_enabled = builtin.target.os.tag == .linux and build_options.display_x11;
pub const virtio_gpu_enabled = builtin.target.os.tag == .freestanding and build_options.display_virtio_gpu;

// Disabled backends become empty namespaces.
pub const headless = if (headless_enabled) @import("platform/headless.zig") else struct {};

// Window-system and DRM backends use host networking/syscalls and their
// protocol subproject modules, none of which exist on freestanding targets. They are
// gated behind a comptime os check so a freestanding build never analyzes them.
pub const drm = if (drm_enabled) @import("platform/drm.zig") else struct {};
pub const wayland = if (wayland_enabled) @import("platform/wayland.zig") else struct {};
pub const x11 = if (x11_enabled) @import("platform/x11.zig") else struct {};

// GBM present backend: adapts the gbm package's Surface to a platform.Surface for
// the EGL GBM platform. The gbm package is portable, but the EGL frontend that
// drives it is host-only, so it is gated with the other host backends.
pub const gbm = if (gbm_enabled) @import("platform/gbm.zig") else struct {};

// virtio-gpu present backend (Conduit driver). Only meaningful on freestanding
// where the guest kernel owns the device and identity-maps it. Gated to
// freestanding so the Linux build never needs conduit.
pub const virtio_gpu = if (virtio_gpu_enabled) @import("platform/virtio_gpu.zig") else struct {};

// Rendering frontends use these as implementation details. In particular, EGL
// needs an allocator-backed display for context/config enumeration even when its
// only advertised native platform is Wayland. Keeping these imports in Prism's
// module preserves type identity; frontend modules must not import the files by
// path themselves.
pub const internal = struct {
    pub const headless = @import("platform/headless.zig");
    pub const gbm = if (builtin.target.os.tag == .linux) @import("platform/gbm.zig") else struct {};
};
