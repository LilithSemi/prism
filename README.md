# prism

Userspace graphics stack

## Features

- Vulkan & OpenGL support
- No C dependencies
- SPIR-V

## Drivers

- Apple (Asahi)
- Arm Mali (Panthor)
- NVIDIA
- Software

## Running glmark2 and demos

On Linux, the native Prism example can present through either Wayland or X11
(Wayland is preferred when both are available). EGL/GLES, GLX, and Vulkan support
both native Wayland and X11 application windows. Install glmark2, `mesa-demos`, and
`vulkan-tools` (for `vulkaninfo` and `vkcube`). The Nix development shell
(`nix develop`) includes glmark2, Mesa demos, and Vulkan tools.

Display backends are selected by repeating `-Ddisplay-backends`, for example
`-Ddisplay-backends=headless -Ddisplay-backends=x11`. Linux enables headless,
DRM, GBM, Wayland, and X11 by default; freestanding targets default to headless
and virtio-gpu. Pass an empty value or repeat the option with any desired
backends for a smaller build. Disabled X11 and Wayland backends do not fetch or
run their protocol generators. Drivers use the same repeated-option form.

From the repository root, build the libraries and their loader manifests:

```sh
zig build -Doptimize=ReleaseFast
PRISM_PREFIX="$PWD/zig-out"
```

### EGL: glmark2 and Mesa demos

Select Prism's EGL vendor for each command with libglvnd's
`__EGL_VENDOR_LIBRARY_FILENAMES` override:

```sh
__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  eglinfo -B -p wayland

__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  eglinfo -B -p x11

__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  glmark2-es2-wayland --size 800x600

__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  es2gears_wayland

__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  glmark2-es2
```

`eglinfo` should report `EGL vendor string: Prism`. `glmark2-wayland` is the
desktop OpenGL/EGL variant; `glmark2-es2-wayland` uses OpenGL ES. Use the EGL
X11 variant (`glmark2-es2`) when running under X11.

### GLX

GLVND loads Prism's GLX vendor by name. The versioned `libGLX_prism.so.0`
installed in `zig-out/lib` is ready for stock Xlib applications:

```sh
LD_LIBRARY_PATH="$PRISM_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
__GLX_VENDOR_LIBRARY_NAME=prism \
  glxinfo -B

LD_LIBRARY_PATH="$PRISM_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
__GLX_VENDOR_LIBRARY_NAME=prism \
  glmark2
```

### Luanti

The Nix development shell includes Luanti from nixpkgs with its GLES renderer
enabled (`nix build .#luanti` builds the same package). Stock desktop builds of
Luanti may omit that renderer. Select its OpenGL ES renderer with
`video_driver = ogles2`; its default desktop OpenGL renderer requires a newer
API than Prism advertises. Copy the example configuration before running, since
Luanti saves settings to its configuration file:

```sh
cp examples/luanti.conf /tmp/prism-luanti.conf
__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  luanti --config /tmp/prism-luanti.conf
```

On Wayland, add `SDL_VIDEODRIVER=wayland` to use direct DMA-buf presentation
on Mali when the compositor supports it. Use a `ReleaseFast` build for gameplay.
For an X11 session, add `SDL_VIDEODRIVER=x11 SDL_VIDEO_X11_FORCE_EGL=1` to the
command's environment. `PRISM_FORCE_SW=1` selects the software driver for
diagnostics. Luanti's startup log should identify `OpenGL ES 2.0 Prism` and
`Renderer: Prism`.

### Vulkan: diagnostics and a demo

glmark2 and the Mesa EGL demos above use EGL. To exercise Prism's Vulkan ICD,
use Vulkan Tools and select the installed manifest with `VK_DRIVER_FILES`:

```sh
VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vulkaninfo --summary

VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vkcube --wsi wayland

VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vkcube --wsi xcb
```

Mesa's `vkgears` has no `--wsi` option. Run it from the Wayland session:

```sh
VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vkgears -info
```

The Wayland path uses the application's `wl_display`/`wl_surface`; the X11 path
accepts standard XCB connections and application-owned window XIDs. Older Vulkan
loaders use `VK_ICD_FILENAMES` in place of `VK_DRIVER_FILES`. The generated manifests
contain absolute library paths, so rebuild after moving the checkout or changing
the install prefix. The overrides above affect only the launched command.

See the [libglvnd vendor selection source](https://github.com/NVIDIA/libglvnd/blob/master/src/EGL/libeglvendor.c)
and [Vulkan loader driver discovery documentation](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md#overriding-the-default-driver-discovery)
for the loader override details.
