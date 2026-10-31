# prism

Userspace graphics stack

## Features

- Vulkan & OpenGL support
- No C dependencies
- SPIR-V

## Drivers

- Apple (Asahi)
- NVIDIA
- Software

## Running glmark2 and demos

On Linux, use a running Wayland session and the system EGL/GLES and Vulkan
loaders. Install glmark2 with its Wayland/GLES2 variant, `mesa-demos`, and
`vulkan-tools` (for `vulkaninfo` and `vkcube`). The Nix development shell
(`nix develop`) includes glmark2, Mesa demos, and Vulkan tools.

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
  glmark2-es2-wayland --size 800x600

__EGL_VENDOR_LIBRARY_FILENAMES="$PRISM_PREFIX/share/glvnd/egl_vendor.d/50_prism.json" \
  es2gears_wayland
```

`eglinfo` should report `EGL vendor string: Prism`. `glmark2-wayland` is the
desktop OpenGL/EGL variant; `glmark2-es2-wayland` uses OpenGL ES. Use the EGL
variants rather than GLX programs such as plain `glmark2`, `glxgears`, or
`glxinfo`: Prism's GLX vendor is currently a stub.

### Vulkan: diagnostics and a demo

glmark2 and the Mesa EGL demos above use EGL. To exercise Prism's Vulkan ICD,
use Vulkan Tools and select the installed manifest with `VK_DRIVER_FILES`:

```sh
VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vulkaninfo --summary

VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vkcube --wsi wayland
```

Mesa's `vkgears` has no `--wsi` option. Run it from the Wayland session:

```sh
VK_DRIVER_FILES="$PRISM_PREFIX/share/vulkan/icd.d/prism.json" \
  vkgears -info
```

Prism currently presents Vulkan windows through Wayland. Older Vulkan loaders
use `VK_ICD_FILENAMES` in place of `VK_DRIVER_FILES`. The generated manifests
contain absolute library paths, so rebuild after moving the checkout or changing
the install prefix. The overrides above affect only the launched command.

See the [libglvnd vendor selection source](https://github.com/NVIDIA/libglvnd/blob/master/src/EGL/libeglvendor.c)
and [Vulkan loader driver discovery documentation](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md#overriding-the-default-driver-discovery)
for the loader override details.
