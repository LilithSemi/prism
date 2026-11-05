const std = @import("std");

fn supportsVulkan(target: std.Target) bool {
    return target.abi.isAndroid() or switch (target.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn defaultDrivers(target: std.Target) []const []const u8 {
    if (target.abi.isAndroid()) return &.{"vulkan"};
    if (target.os.tag == .linux) return &.{ "software", "apple", "mali", "nvidia", "virgl" };
    return &.{"software"};
}

pub fn defaultDisplayBackends(target: std.Target) []const []const u8 {
    if (target.os.tag == .freestanding) return &.{ "headless", "virtio_gpu" };
    if (target.os.tag == .linux and !target.abi.isAndroid()) return &.{ "headless", "drm", "gbm", "wayland", "x11" };
    return &.{"headless"};
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Prism version string") orelse @import("build.zig.zon").version;

    // -Ddrivers selects which drivers are compiled in, passed to the code as
    // per-driver comptime flags in build_options. lib/prism/drivers.zig builds its
    // list from them. An unselected driver's source is never analyzed.
    const known_drivers = [_][]const u8{
        "software",
        "apple",
        "mali",
        "nvidia",
        "virgl",
        "vulkan",
    };
    const drivers_opt = b.option([]const []const u8, "drivers", "Driver to compile in; repeat to select multiple drivers") orelse defaultDrivers(target.result);
    var enabled = std.StringHashMap(void).init(b.allocator);
    for (drivers_opt) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        var ok = false;
        for (known_drivers) |k| {
            if (std.mem.eql(u8, k, name)) ok = true;
        }
        if (!ok) std.debug.panic("unknown driver: {s}", .{name});
        enabled.put(name, {}) catch @panic("OOM");
    }

    // -Ddisplay-backends controls the presentation integrations. Keep this
    // separate from drivers: a headless/DRM-only build still has graphics
    // drivers, but should not fetch or execute Wayland/X11 protocol tooling.
    const known_display_backends = [_][]const u8{ "headless", "drm", "gbm", "wayland", "x11", "virtio_gpu" };
    const display_backends_opt = b.option(
        []const []const u8,
        "display-backends",
        "Display backend to compile in; repeat to select multiple backends",
    ) orelse defaultDisplayBackends(target.result);
    var display_backends = std.StringHashMap(void).init(b.allocator);
    for (display_backends_opt) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        var ok = false;
        for (known_display_backends) |known| {
            if (std.mem.eql(u8, known, name)) ok = true;
        }
        if (!ok) std.debug.panic("unknown display backend: {s}", .{name});
        display_backends.put(name, {}) catch @panic("OOM");
    }
    const linux_host = target.result.os.tag == .linux and !target.result.abi.isAndroid();
    if (!linux_host and (display_backends.contains("drm") or display_backends.contains("gbm") or
        display_backends.contains("wayland") or display_backends.contains("x11")))
        @panic("drm, gbm, wayland, and x11 display backends require a non-Android Linux target");
    if (target.result.os.tag != .freestanding and display_backends.contains("virtio_gpu"))
        @panic("the virtio_gpu display backend requires a freestanding target");
    const enable_headless = display_backends.contains("headless");
    const enable_drm = display_backends.contains("drm");
    const enable_gbm = display_backends.contains("gbm");
    const enable_wayland = display_backends.contains("wayland");
    const enable_x11 = display_backends.contains("x11");
    const enable_virtio_gpu = display_backends.contains("virtio_gpu");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    inline for (known_drivers) |name| {
        options.addOption(bool, "driver_" ++ name, enabled.contains(name));
    }
    options.addOption(bool, "display_headless", enable_headless);
    options.addOption(bool, "display_drm", enable_drm);
    options.addOption(bool, "display_gbm", enable_gbm);
    options.addOption(bool, "display_wayland", enable_wayland);
    options.addOption(bool, "display_x11", enable_x11);
    options.addOption(bool, "display_virtio_gpu", enable_virtio_gpu);

    const wl_dep: ?*std.Build.Dependency = if (enable_wayland)
        b.dependency("wayland", .{ .target = target, .optimize = optimize })
    else
        null;

    var x11_module: ?*std.Build.Module = null;
    var xproto_module: ?*std.Build.Module = null;
    if (enable_x11) {
        const x11_dep = b.dependency("x11", .{ .target = target, .optimize = optimize });
        const xcbproto_dep = b.dependency("xcbproto", .{});

        // Generate the core X11 protocol bindings from xcbproto. This block is
        // deliberately conditional: x11-gen-host is absent from non-X11 builds.
        const xproto_gen = b.addRunArtifact(x11_dep.artifact("x11-gen-host"));
        xproto_gen.addFileArg(xcbproto_dep.path("src/xproto.xml"));
        const xproto = b.createModule(.{
            .root_source_file = xproto_gen.addOutputFileArg("xproto.zig"),
            .target = target,
            .optimize = optimize,
        });
        const x11 = x11_dep.module("x11");
        xproto.addImport("x11", x11);
        x11_module = x11;
        xproto_module = xproto;
    }

    const nvidia_dep = b.dependency("nvidia", .{ .target = target, .optimize = optimize });
    const asahi_dep = b.dependency("asahi", .{ .target = target, .optimize = optimize });
    const mali_dep = b.dependency("mali", .{ .target = target, .optimize = optimize });
    const vulcan_dep = b.dependency("vulcan", .{ .target = target, .optimize = optimize });
    const drm_dep = b.dependency("drm", .{ .target = target, .optimize = optimize });
    const gbm_dep = b.dependency("gbm", .{ .target = target, .optimize = optimize });

    const vulkan_headers_dep = b.dependency("vulkan_headers", .{});
    const vulkan_zig_dep = b.dependency("vulkan_zig", .{});
    const vulkan_zig_generate = b.addRunArtifact(vulkan_zig_dep.artifact("vulkan-zig-generator"));
    vulkan_zig_generate.addFileArg(vulkan_headers_dep.path("registry/vk.xml"));
    const vulkan_zig = b.createModule(.{
        .root_source_file = vulkan_zig_generate.addOutputFileArg("vk.zig"),
    });

    var prism_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    prism_imports.appendSlice(b.allocator, &.{
        .{ .name = "build-options", .module = options.createModule() },
        .{ .name = "nvidia", .module = nvidia_dep.module("nvidia") },
        .{ .name = "asahi", .module = asahi_dep.module("asahi") },
        .{ .name = "mali", .module = mali_dep.module("mali") },
        .{ .name = "drm", .module = drm_dep.module("drm") },
        .{ .name = "gbm", .module = gbm_dep.module("gbm") },
        .{ .name = "vulcan-ir", .module = vulcan_dep.module("vulcan-ir") },
        .{ .name = "vulcan-gpu", .module = vulcan_dep.module("vulcan-gpu") },
        .{ .name = "vulcan-spirv", .module = vulcan_dep.module("vulcan-spirv") },
        .{ .name = "vulcan-target", .module = vulcan_dep.module("vulcan-target") },
        .{ .name = "vulcan-glsl", .module = vulcan_dep.module("vulcan-glsl") },
        .{ .name = "vulkan-zig", .module = vulkan_zig },
    }) catch @panic("OOM");
    if (wl_dep) |dep|
        prism_imports.append(b.allocator, .{ .name = "wayland", .module = dep.module("wayland") }) catch @panic("OOM");
    if (x11_module) |module|
        prism_imports.append(b.allocator, .{ .name = "x11", .module = module }) catch @panic("OOM");
    if (xproto_module) |module|
        prism_imports.append(b.allocator, .{ .name = "xproto", .module = module }) catch @panic("OOM");

    const prism = b.addModule("prism", .{
        .root_source_file = b.path("lib/prism.zig"),
        .target = target,
        .optimize = optimize,
        .imports = prism_imports.items,
    });
    if (enabled.contains("vulkan")) {
        // The Vulkan loader uses the platform C runtime internally. Declaring
        // libc here ensures Zig executables importing prism use the libc-aware
        // startup path before the loader calls malloc/calloc.
        prism.link_libc = true;
        if (target.result.abi.isAndroid()) {
            // Android supplies its Vulkan loader as a platform library; there is
            // no target pkg-config environment to consult.
            prism.linkSystemLibrary("vulkan", .{ .use_pkg_config = .no });
        } else if (supportsVulkan(target.result)) {
            // Vulkan is opt-in on desktop targets because this is Prism's one
            // driver that depends on a non-Zig system package.
            prism.linkSystemLibrary("vulkan", .{ .use_pkg_config = .force });
        }
    }

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Core library linkage") orelse .dynamic;
    b.installArtifact(b.addLibrary(.{ .name = "prism", .root_module = prism, .linkage = linkage }));

    // One test runner: the prism module pulls in every internal test via its
    // file-path import graph (lib/prism.zig references the test-only files too).
    const test_step = b.step("test", "Run all Prism tests");
    const prism_tests = b.addRunArtifact(b.addTest(.{ .root_module = prism }));
    prism_tests.addPassthruArgs();
    test_step.dependOn(&prism_tests.step);

    // The GLX vendor, EGL/GLVND vendor, and Vulkan ICD shared libraries.
    if (!target.result.cpu.arch.isWasm() and target.result.os.tag != .uefi and !target.result.abi.isAndroid()) {
        // The EGL vendor and the Vulkan ICD present over Wayland and link the
        // system libwayland-client, which exists only on Linux. The GLX vendor
        // speaks X11 and needs no wayland, so it keeps the wider gate. The CI's
        // aarch64-darwin check builds `zig build install`, and these two cannot
        // exist there at all.
        const wayland_hosts = target.result.os.tag == .linux and enable_wayland;
        const Frontend = struct { name: []const u8, root: []const u8, wayland: bool };
        for ([_]Frontend{
            .{ .name = "GLX_prism", .root = "lib/prism-gl.zig", .wayland = false },
            .{ .name = "EGL_prism", .root = "lib/prism-egl.zig", .wayland = true },
            .{ .name = "prism-vk", .root = "lib/prism-vk.zig", .wayland = true },
        }) |fe| {
            if (fe.wayland and !wayland_hosts) continue;
            // The ICD's wsi_wayland.zig and the EGL vendor's wl_egl_window.zig both use
            // wayland.shm for the wl_shm present pool, so both need Prism's Zig wayland
            // library directly.
            const base_imports = [_]std.Build.Module.Import{
                .{ .name = "prism", .module = prism },
            };
            const fmod = b.createModule(.{
                .root_source_file = b.path(fe.root),
                .target = target,
                .optimize = optimize,
                .imports = &base_imports,
            });
            if (fe.wayland) {
                fmod.addImport("wayland", wl_dep.?.module("wayland"));
                // The libwayland present path links libwayland-client (the wl_* C API),
                // bound at runtime to the host app's already-loaded copy.
                fmod.link_libc = true;
                fmod.linkSystemLibrary("wayland-client", .{});
            }
            b.installArtifact(b.addLibrary(.{ .name = fe.name, .root_module = fmod, .linkage = .dynamic }));
            // EGL's oracle suite exercises its surfaceless platform extensively.
            // The library still compiles for a Wayland-only configuration, but
            // those tests are not applicable when headless was not selected.
            if (std.mem.eql(u8, fe.name, "EGL_prism") and !enable_headless) continue;
            const frontend_tests = b.addRunArtifact(b.addTest(.{ .root_module = fmod }));
            frontend_tests.addPassthruArgs();
            test_step.dependOn(&frontend_tests.step);
        }
    }

    // prism-info probes hardware through the platform backends, and the Wayland
    // one pulls the wayland client's Linux-only syscall layer into analysis on
    // darwin. The tool has no darwin consumer: lattice uses the prism module.
    if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        const info_mod = b.createModule(.{
            .root_source_file = b.path("tools/prism-info.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "prism", .module = prism }},
        });
        const info_exe = b.addExecutable(.{ .name = "prism-info", .root_module = info_mod });
        b.installArtifact(info_exe);
        b.step("run-info", "Run prism-info").dependOn(&b.addRunArtifact(info_exe).step);
        const info_tests = b.addRunArtifact(b.addTest(.{ .root_module = info_mod }));
        info_tests.addPassthruArgs();
        test_step.dependOn(&info_tests.step);
    }

    // Triangle example: best available driver with a software fallback, presented
    // through Wayland/X11. The window-system backends are Linux-only.
    if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        const triangle_mod = b.createModule(.{
            .root_source_file = b.path("examples/triangle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "prism", .module = prism }},
        });
        const triangle_exe = b.addExecutable(.{ .name = "triangle", .root_module = triangle_mod });
        b.installArtifact(triangle_exe);
        b.step("run-triangle", "Run the triangle on Wayland or X11").dependOn(&b.addRunArtifact(triangle_exe).step);
    }

    // Render the loader/vendor JSON templates, replacing @LIBDIR@ with the install lib dir.
    // They describe the Vulkan ICD and the EGL vendor library, both Linux-only. The install
    // prefix is known only while the install step runs, so the substitution runs there too.
    if (target.result.os.tag == .linux and !target.result.abi.isAndroid() and enable_wayland) {
        inline for (.{
            .{ "data/vulkan/icd.d/prism.json.in", "share/vulkan/icd.d/prism.json" },
            .{ "data/glvnd/egl_vendor.d/50_prism.json.in", "share/glvnd/egl_vendor.d/50_prism.json" },
        }) |pair| {
            const render = b.addSystemCommand(&.{"sed"});
            render.addDirectoryArg2(.{ .relative = .{ .base = .install_lib } }, .{
                .prefix = "s|@LIBDIR@|",
                .suffix = "|g",
                .make_absolute = true,
            });
            render.addFileArg(b.path(pair[0]));
            const out = render.captureStdOut(.{ .basename = std.fs.path.basename(pair[1]) });
            b.getInstallStep().dependOn(&b.addInstallFile(out, pair[1]).step);
        }
    }
}
