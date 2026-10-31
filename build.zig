const std = @import("std");

fn supportsVulkan(target: std.Target) bool {
    return target.abi.isAndroid() or switch (target.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

pub fn defaultDrivers(target: std.Target) []const u8 {
    if (target.abi.isAndroid()) return "vulkan";
    if (target.os.tag == .linux) return "software,apple,nvidia,virgl";
    return "software";
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
        "nvidia",
        "virgl",
        "vulkan",
    };
    const drivers_opt = b.option([]const u8, "drivers", "Comma-separated drivers to compile in") orelse defaultDrivers(target.result);
    var enabled = std.StringHashMap(void).init(b.allocator);
    {
        var it = std.mem.splitScalar(u8, drivers_opt, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            var ok = false;
            for (known_drivers) |k| {
                if (std.mem.eql(u8, k, name)) ok = true;
            }
            if (!ok) std.debug.panic("unknown driver: {s}", .{name});
            enabled.put(name, {}) catch @panic("OOM");
        }
    }

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    inline for (known_drivers) |name| {
        options.addOption(bool, "driver_" ++ name, enabled.contains(name));
    }

    const wl_dep = b.dependency("wayland", .{ .target = target, .optimize = optimize });
    const nvidia_dep = b.dependency("nvidia", .{ .target = target, .optimize = optimize });
    const asahi_dep = b.dependency("asahi", .{ .target = target, .optimize = optimize });
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

    const prism = b.addModule("prism", .{
        .root_source_file = b.path("lib/prism.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
            .{ .name = "wayland", .module = wl_dep.module("wayland") },
            .{ .name = "nvidia", .module = nvidia_dep.module("nvidia") },
            .{ .name = "asahi", .module = asahi_dep.module("asahi") },
            .{ .name = "drm", .module = drm_dep.module("drm") },
            .{ .name = "gbm", .module = gbm_dep.module("gbm") },
            .{ .name = "vulcan-ir", .module = vulcan_dep.module("vulcan-ir") },
            .{ .name = "vulcan-gpu", .module = vulcan_dep.module("vulcan-gpu") },
            .{ .name = "vulcan-spirv", .module = vulcan_dep.module("vulcan-spirv") },
            .{ .name = "vulcan-target", .module = vulcan_dep.module("vulcan-target") },
            .{ .name = "vulcan-glsl", .module = vulcan_dep.module("vulcan-glsl") },
            .{ .name = "vulkan-zig", .module = vulkan_zig },
        },
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
        const wayland_hosts = target.result.os.tag == .linux;
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
            const wl_imports = [_]std.Build.Module.Import{
                .{ .name = "prism", .module = prism },
                .{ .name = "wayland", .module = wl_dep.module("wayland") },
            };
            const base_imports = [_]std.Build.Module.Import{
                .{ .name = "prism", .module = prism },
            };
            const fmod = b.createModule(.{
                .root_source_file = b.path(fe.root),
                .target = target,
                .optimize = optimize,
                .imports = if (fe.wayland) &wl_imports else &base_imports,
            });
            if (fe.wayland) {
                // The libwayland present path links libwayland-client (the wl_* C API),
                // bound at runtime to the host app's already-loaded copy.
                fmod.link_libc = true;
                fmod.linkSystemLibrary("wayland-client", .{});
            }
            b.installArtifact(b.addLibrary(.{ .name = fe.name, .root_module = fmod, .linkage = .dynamic }));
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
    // over Wayland. Wayland presentation is Linux-only, so the example is too.
    if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        const triangle_mod = b.createModule(.{
            .root_source_file = b.path("examples/triangle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "prism", .module = prism }},
        });
        const triangle_exe = b.addExecutable(.{ .name = "triangle", .root_module = triangle_mod });
        b.installArtifact(triangle_exe);
        b.step("run-triangle", "Run the triangle on Wayland (needs a compositor)").dependOn(&b.addRunArtifact(triangle_exe).step);
    }

    // Render the loader/vendor JSON templates, replacing @LIBDIR@ with the install lib dir.
    // They describe the Vulkan ICD and the EGL vendor library, both Linux-only. The install
    // prefix is known only while the install step runs, so the substitution runs there too.
    if (target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
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
