const std = @import("std");
const prism = @import("prism");
const egl = @import("prism-egl/egl.zig");
const vendor_egl = @import("prism-egl/vendor.zig");

const Display = anyopaque;
const GLXDrawable = usize;
const GLXWindow = usize;
const GLXPixmap = usize;
const GLXPbuffer = usize;
const GLXContext = ?*anyopaque;
const GLXFBConfig = ?*anyopaque;
const Bool = c_int;
const Proc = ?*const fn () callconv(.c) void;
const XVisualInfo = extern struct {
    visual: ?*anyopaque,
    visualid: usize,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: usize,
    green_mask: usize,
    blue_mask: usize,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};

const GLX_SUCCESS = 0;
const GLX_BAD_ATTRIBUTE = 2;
const GLX_BUFFER_SIZE = 2;
const GLX_LEVEL = 3;
const GLX_DOUBLEBUFFER = 5;
const GLX_STEREO = 6;
const GLX_AUX_BUFFERS = 7;
const GLX_RED_SIZE = 8;
const GLX_GREEN_SIZE = 9;
const GLX_BLUE_SIZE = 10;
const GLX_ALPHA_SIZE = 11;
const GLX_DEPTH_SIZE = 12;
const GLX_STENCIL_SIZE = 13;
const GLX_ACCUM_RED_SIZE = 14;
const GLX_ACCUM_GREEN_SIZE = 15;
const GLX_ACCUM_BLUE_SIZE = 16;
const GLX_ACCUM_ALPHA_SIZE = 17;
const GLX_RGBA = 4;
const GLX_CONFIG_CAVEAT = 0x20;
const GLX_X_VISUAL_TYPE = 0x22;
const GLX_TRANSPARENT_TYPE = 0x23;
const GLX_NONE = 0x8000;
const GLX_TRUE_COLOR = 0x8002;
const GLX_DRAWABLE_TYPE = 0x8010;
const GLX_RENDER_TYPE = 0x8011;
const GLX_X_RENDERABLE = 0x8012;
const GLX_FBCONFIG_ID = 0x8013;
const GLX_VISUAL_ID = 0x800B;
const GLX_SCREEN = 0x800C;
const GLX_WINDOW_BIT = 1;
const GLX_RGBA_BIT = 1;
const GLX_SAMPLE_BUFFERS = 100000;
const GLX_SAMPLES = 100001;

const ApiExports = extern struct {
    getDynDispatch: ?*const anyopaque,
    getCurrentDynDispatch: ?*const anyopaque,
    fetchDispatchEntry: ?*const anyopaque,
    getCurrentContext: ?*const fn () callconv(.c) GLXContext,
    addVendorContextMapping: ?*const fn (*Display, GLXContext, *anyopaque) callconv(.c) c_int,
    removeVendorContextMapping: ?*const fn (*Display, GLXContext) callconv(.c) void,
    vendorFromContext: ?*const anyopaque,
    addVendorFBConfigMapping: ?*const fn (*Display, GLXFBConfig, *anyopaque) callconv(.c) c_int,
    removeVendorFBConfigMapping: ?*const fn (*Display, GLXFBConfig) callconv(.c) void,
    vendorFromFBConfig: ?*const anyopaque,
    addVendorDrawableMapping: ?*const fn (*Display, GLXDrawable, *anyopaque) callconv(.c) c_int,
    removeVendorDrawableMapping: ?*const fn (*Display, GLXDrawable) callconv(.c) void,
    vendorFromDrawable: ?*const anyopaque,
};

const ApiImports = extern struct {
    isScreenSupported: ?*const fn (*Display, c_int) callconv(.c) Bool,
    getProcAddress: ?*const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    getDispatchAddress: ?*const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    setDispatchIndex: ?*const fn ([*:0]const u8, c_int) callconv(.c) void,
    notifyError: ?*const anyopaque,
    isPatchSupported: ?*const anyopaque,
    initiatePatch: ?*const anyopaque,
    releasePatch: ?*const anyopaque,
    patchThreadAttach: ?*const anyopaque,
};

var api_exports: ?*const ApiExports = null;
var vendor_id: ?*anyopaque = null;
var fb_config_token: u8 = 0;

fn debugEnabled() bool {
    return std.c.getenv("PRISM_GLX_DEBUG") != null;
}

const Context = struct {
    x_display: *Display,
    egl_display: egl.EGLDisplay,
    egl_context: egl.EGLContext,
    egl_surface: egl.EGLSurface = egl.EGL_NO_SURFACE,
    drawable: GLXDrawable = 0,
    pending_delete: bool = false,
};

threadlocal var current: ?*Context = null;
extern fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn XGetVisualInfo(display: *Display, mask: c_long, template: *XVisualInfo, count: *c_int) callconv(.c) ?[*]XVisualInfo;
extern fn XFree(data: ?*anyopaque) callconv(.c) c_int;
extern fn XSync(display: *Display, discard: Bool) callconv(.c) c_int;

fn visualForScreen(dpy: *Display, screen: c_int) ?[*]XVisualInfo {
    var template = std.mem.zeroes(XVisualInfo);
    template.screen = screen;
    template.depth = 24;
    template.class = 4; // TrueColor
    var count: c_int = 0;
    return XGetVisualInfo(dpy, 0x2 | 0x4 | 0x8, &template, &count);
}

fn configHandle() GLXFBConfig {
    return @ptrCast(&fb_config_token);
}

fn allocConfigs(dpy: *Display, count: *c_int) ?[*]GLXFBConfig {
    const raw = malloc(@sizeOf(GLXFBConfig)) orelse {
        count.* = 0;
        return null;
    };
    const out: [*]GLXFBConfig = @ptrCast(@alignCast(raw));
    out[0] = configHandle();
    count.* = 1;
    if (api_exports) |api| {
        if (api.addVendorFBConfigMapping) |add| {
            const rc = add(dpy, out[0], vendor_id.?);
            if (debugEnabled()) std.debug.print("[prism-glx] FBConfig mapping rc={d}, handle=0x{x}\n", .{ rc, @intFromPtr(out[0].?) });
        }
    }
    return out;
}

fn isScreenSupported(display: *Display, screen: c_int) callconv(.c) Bool {
    _ = display;
    return @intFromBool(prism.platform.x11_enabled and screen >= 0);
}

fn setDispatchIndex(name: [*:0]const u8, index: c_int) callconv(.c) void {
    _ = name;
    _ = index;
}

fn asOpaque(comptime f: anytype) *anyopaque {
    return @ptrCast(@constCast(&f));
}

fn lookup(name_z: [*:0]const u8) ?*anyopaque {
    const name = std.mem.span(name_z);
    const map = .{
        .{ "glXChooseFBConfig", asOpaque(glXChooseFBConfig) },
        .{ "glXGetFBConfigs", asOpaque(glXGetFBConfigs) },
        .{ "glXGetFBConfigAttrib", asOpaque(glXGetFBConfigAttrib) },
        .{ "glXGetVisualFromFBConfig", asOpaque(glXGetVisualFromFBConfig) },
        .{ "glXChooseVisual", asOpaque(glXChooseVisual) },
        .{ "glXCopyContext", asOpaque(glXCopyContext) },
        .{ "glXCreateContext", asOpaque(glXCreateContext) },
        .{ "glXCreateGLXPixmap", asOpaque(glXCreateGLXPixmap) },
        .{ "glXDestroyGLXPixmap", asOpaque(glXDestroyGLXPixmap) },
        .{ "glXGetConfig", asOpaque(glXGetConfig) },
        .{ "glXCreateNewContext", asOpaque(glXCreateNewContext) },
        .{ "glXCreateContextAttribsARB", asOpaque(glXCreateContextAttribsARB) },
        .{ "glXDestroyContext", asOpaque(glXDestroyContext) },
        .{ "glXMakeCurrent", asOpaque(glXMakeCurrent) },
        .{ "glXMakeContextCurrent", asOpaque(glXMakeContextCurrent) },
        .{ "glXSwapBuffers", asOpaque(glXSwapBuffers) },
        .{ "glXUseXFont", asOpaque(glXUseXFont) },
        .{ "glXWaitGL", asOpaque(glXWaitGL) },
        .{ "glXWaitX", asOpaque(glXWaitX) },
        .{ "glXQueryVersion", asOpaque(glXQueryVersion) },
        .{ "glXQueryExtensionsString", asOpaque(glXQueryExtensionsString) },
        .{ "glXGetClientString", asOpaque(glXGetClientString) },
        .{ "glXQueryServerString", asOpaque(glXQueryServerString) },
        .{ "glXIsDirect", asOpaque(glXIsDirect) },
        .{ "glXGetCurrentContext", asOpaque(glXGetCurrentContext) },
        .{ "glXGetCurrentDrawable", asOpaque(glXGetCurrentDrawable) },
        .{ "glXGetCurrentReadDrawable", asOpaque(glXGetCurrentReadDrawable) },
        .{ "glXGetCurrentDisplay", asOpaque(glXGetCurrentDisplay) },
        .{ "glXCreateWindow", asOpaque(glXCreateWindow) },
        .{ "glXCreatePixmap", asOpaque(glXCreatePixmap) },
        .{ "glXCreatePbuffer", asOpaque(glXCreatePbuffer) },
        .{ "glXDestroyWindow", asOpaque(glXDestroyWindow) },
        .{ "glXDestroyPixmap", asOpaque(glXDestroyPixmap) },
        .{ "glXDestroyPbuffer", asOpaque(glXDestroyPbuffer) },
        .{ "glXGetSelectedEvent", asOpaque(glXGetSelectedEvent) },
        .{ "glXQueryContext", asOpaque(glXQueryContext) },
        .{ "glXQueryDrawable", asOpaque(glXQueryDrawable) },
        .{ "glXSelectEvent", asOpaque(glXSelectEvent) },
        .{ "glXGetProcAddress", asOpaque(glXGetProcAddress) },
        .{ "glXGetProcAddressARB", asOpaque(glXGetProcAddress) },
    };
    inline for (map) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    if (vendor_egl.lookupProc(name)) |proc| return @ptrCast(@constCast(proc));
    return null;
}

fn getProcAddress(name: [*:0]const u8) callconv(.c) ?*anyopaque {
    return lookup(name);
}

fn getDispatchAddress(name: [*:0]const u8) callconv(.c) ?*anyopaque {
    if (std.mem.startsWith(u8, std.mem.span(name), "glX")) return lookup(name);
    return null;
}

export fn __glx_Main(version: u32, exports: ?*const ApiExports, vendor: ?*anyopaque, imports: ?*ApiImports) callconv(.c) Bool {
    if (version >> 16 != 1 or exports == null or vendor == null or imports == null) return 0;
    api_exports = exports;
    vendor_id = vendor;
    imports.?.* = .{
        .isScreenSupported = isScreenSupported,
        .getProcAddress = getProcAddress,
        .getDispatchAddress = getDispatchAddress,
        .setDispatchIndex = setDispatchIndex,
        .notifyError = null,
        .isPatchSupported = null,
        .initiatePatch = null,
        .releasePatch = null,
        .patchThreadAttach = null,
    };
    return 1;
}

pub export fn glXChooseFBConfig(dpy: *Display, screen: c_int, attribs: ?[*]const c_int, count: *c_int) callconv(.c) ?[*]GLXFBConfig {
    _ = screen;
    _ = attribs;
    return allocConfigs(dpy, count);
}

pub export fn glXGetFBConfigs(dpy: *Display, screen: c_int, count: *c_int) callconv(.c) ?[*]GLXFBConfig {
    return glXChooseFBConfig(dpy, screen, null, count);
}

pub export fn glXGetFBConfigAttrib(dpy: *Display, config: GLXFBConfig, attribute: c_int, value: *c_int) callconv(.c) c_int {
    if (config != configHandle()) return GLX_BAD_ATTRIBUTE;
    value.* = switch (attribute) {
        GLX_FBCONFIG_ID => 1,
        GLX_VISUAL_ID => blk: {
            const visuals = visualForScreen(dpy, 0) orelse break :blk 0;
            defer _ = XFree(visuals);
            break :blk @intCast(visuals[0].visualid);
        },
        GLX_SCREEN,
        GLX_LEVEL,
        GLX_AUX_BUFFERS,
        GLX_STEREO,
        GLX_SAMPLE_BUFFERS,
        GLX_SAMPLES,
        GLX_ACCUM_RED_SIZE,
        GLX_ACCUM_GREEN_SIZE,
        GLX_ACCUM_BLUE_SIZE,
        GLX_ACCUM_ALPHA_SIZE,
        => 0,
        GLX_CONFIG_CAVEAT, GLX_TRANSPARENT_TYPE => GLX_NONE,
        GLX_X_VISUAL_TYPE => GLX_TRUE_COLOR,
        GLX_BUFFER_SIZE => 32,
        GLX_RED_SIZE, GLX_GREEN_SIZE, GLX_BLUE_SIZE, GLX_ALPHA_SIZE => 8,
        GLX_DEPTH_SIZE => 24,
        GLX_STENCIL_SIZE => 8,
        GLX_DOUBLEBUFFER, GLX_X_RENDERABLE => 1,
        GLX_RENDER_TYPE => GLX_RGBA_BIT,
        GLX_DRAWABLE_TYPE => GLX_WINDOW_BIT,
        else => {
            if (debugEnabled()) std.debug.print("[prism-glx] unsupported FBConfig attribute 0x{x}\n", .{attribute});
            return GLX_BAD_ATTRIBUTE;
        },
    };
    return GLX_SUCCESS;
}

pub export fn glXGetVisualFromFBConfig(dpy: *Display, config: GLXFBConfig) callconv(.c) ?*XVisualInfo {
    if (debugEnabled()) std.debug.print("[prism-glx] glXGetVisualFromFBConfig handle={?}\n", .{config});
    if (config != configHandle()) return null;
    const visuals = visualForScreen(dpy, 0) orelse return null;
    if (debugEnabled()) std.debug.print("[prism-glx] visual id=0x{x}, depth={d}\n", .{ visuals[0].visualid, visuals[0].depth });
    return &visuals[0];
}

pub export fn glXChooseVisual(dpy: *Display, screen: c_int, attribs: ?[*]const c_int) callconv(.c) ?*XVisualInfo {
    _ = attribs;
    const visuals = visualForScreen(dpy, screen) orelse return null;
    return &visuals[0];
}

pub export fn glXCopyContext(dpy: *Display, src: GLXContext, dst: GLXContext, mask: c_ulong) callconv(.c) void {
    _ = dpy;
    _ = src;
    _ = dst;
    _ = mask;
}

pub export fn glXCreateContext(dpy: *Display, visual: *XVisualInfo, share: GLXContext, direct: Bool) callconv(.c) GLXContext {
    _ = visual;
    _ = direct;
    return createContext(dpy, share);
}

fn addDrawableMapping(dpy: *Display, drawable: GLXDrawable) void {
    if (api_exports) |api| {
        if (api.addVendorDrawableMapping) |add| _ = add(dpy, drawable, vendor_id.?);
    }
}

fn removeDrawableMapping(dpy: *Display, drawable: GLXDrawable) void {
    if (api_exports) |api| if (api.removeVendorDrawableMapping) |remove| remove(dpy, drawable);
}

pub export fn glXCreateGLXPixmap(dpy: *Display, visual: *XVisualInfo, pixmap: usize) callconv(.c) GLXPixmap {
    _ = visual;
    addDrawableMapping(dpy, pixmap);
    return pixmap;
}

pub export fn glXDestroyGLXPixmap(dpy: *Display, pixmap: GLXPixmap) callconv(.c) void {
    removeDrawableMapping(dpy, pixmap);
}

pub export fn glXGetConfig(dpy: *Display, visual: *XVisualInfo, attribute: c_int, value: *c_int) callconv(.c) c_int {
    _ = dpy;
    value.* = switch (attribute) {
        1, GLX_RGBA, GLX_DOUBLEBUFFER => 1,
        GLX_BUFFER_SIZE => 32,
        GLX_RED_SIZE, GLX_GREEN_SIZE, GLX_BLUE_SIZE, GLX_ALPHA_SIZE => 8,
        GLX_DEPTH_SIZE => visual.depth,
        GLX_STENCIL_SIZE => 8,
        GLX_LEVEL,
        GLX_STEREO,
        GLX_AUX_BUFFERS,
        GLX_ACCUM_RED_SIZE,
        GLX_ACCUM_GREEN_SIZE,
        GLX_ACCUM_BLUE_SIZE,
        GLX_ACCUM_ALPHA_SIZE,
        => 0,
        else => return GLX_BAD_ATTRIBUTE,
    };
    return GLX_SUCCESS;
}

fn createContext(dpy: *Display, share: GLXContext) GLXContext {
    const edpy = vendor_egl.eglGetPlatformDisplay(egl.EGL_PLATFORM_X11_KHR, dpy, null);
    if (edpy == egl.EGL_NO_DISPLAY or vendor_egl.eglInitialize(edpy, null, null) == egl.EGL_FALSE) {
        if (debugEnabled()) std.debug.print("[prism-glx] display initialization failed: EGL 0x{x}\n", .{vendor_egl.eglGetError()});
        return null;
    }
    _ = vendor_egl.eglBindAPI(egl.EGL_OPENGL_API);
    const shared = if (share) |raw| @as(*Context, @ptrCast(@alignCast(raw))).egl_context else egl.EGL_NO_CONTEXT;
    const ectx = vendor_egl.eglCreateContext(edpy, vendor_egl.defaultConfig(), shared, null);
    if (ectx == egl.EGL_NO_CONTEXT) {
        if (debugEnabled()) std.debug.print("[prism-glx] context creation failed: EGL 0x{x}\n", .{vendor_egl.eglGetError()});
        return null;
    }
    const ctx = std.heap.c_allocator.create(Context) catch return null;
    ctx.* = .{ .x_display = dpy, .egl_display = edpy, .egl_context = ectx };
    const handle: GLXContext = @ptrCast(ctx);
    if (api_exports) |api| {
        if (api.addVendorContextMapping) |add| {
            const rc = add(dpy, handle, vendor_id.?);
            if (debugEnabled()) std.debug.print("[prism-glx] context mapping rc={d}, handle={?}\n", .{ rc, handle });
        }
    }
    return handle;
}

pub export fn glXCreateNewContext(dpy: *Display, config: GLXFBConfig, render_type: c_int, share: GLXContext, direct: Bool) callconv(.c) GLXContext {
    _ = config;
    _ = render_type;
    _ = direct;
    return createContext(dpy, share);
}

pub export fn glXCreateContextAttribsARB(dpy: *Display, config: GLXFBConfig, share: GLXContext, direct: Bool, attribs: ?[*]const c_int) callconv(.c) GLXContext {
    _ = config;
    _ = direct;
    _ = attribs;
    return createContext(dpy, share);
}

pub export fn glXDestroyContext(dpy: *Display, handle: GLXContext) callconv(.c) void {
    if (debugEnabled()) {
        const loader_current = if (api_exports) |api| if (api.getCurrentContext) |get| get() else null else null;
        std.debug.print("[prism-glx] destroyContext {?}; loader current={?}, vendor current={?}\n", .{ handle, loader_current, glXGetCurrentContext() });
    }
    const ctx: *Context = @ptrCast(@alignCast(handle orelse return));
    if (api_exports) |api| if (api.removeVendorContextMapping) |remove| remove(dpy, handle);
    if (current == ctx) {
        // GLX permits deletion while current. GLVND retains that context until
        // it is released, so preserve both the EGL state and unique handle.
        ctx.pending_delete = true;
        return;
    }
    destroyContextStorage(ctx);
}

fn destroyContextStorage(ctx: *Context) void {
    if (ctx.egl_surface != egl.EGL_NO_SURFACE) _ = vendor_egl.eglDestroySurface(ctx.egl_display, ctx.egl_surface);
    _ = vendor_egl.eglDestroyContext(ctx.egl_display, ctx.egl_context);
    std.heap.c_allocator.destroy(ctx);
}

fn makeCurrent(dpy: *Display, drawable: GLXDrawable, handle: GLXContext) Bool {
    if (debugEnabled()) std.debug.print("[prism-glx] makeCurrent drawable=0x{x} context={?}\n", .{ drawable, handle });
    if (handle == null) {
        const old = current;
        if (old) |ctx| _ = vendor_egl.eglMakeCurrent(ctx.egl_display, null, null, null);
        current = null;
        if (old) |ctx| if (ctx.pending_delete) destroyContextStorage(ctx);
        return 1;
    }
    const ctx: *Context = @ptrCast(@alignCast(handle.?));
    const old = current;
    if (ctx.egl_surface == egl.EGL_NO_SURFACE or ctx.drawable != drawable) {
        if (ctx.egl_surface != egl.EGL_NO_SURFACE) _ = vendor_egl.eglDestroySurface(ctx.egl_display, ctx.egl_surface);
        // The Prism presenter uses its own X11 connection. Flush creation of
        // an application-owned drawable before that connection queries its XID.
        _ = XSync(dpy, 0);
        ctx.egl_surface = vendor_egl.eglCreateWindowSurface(ctx.egl_display, vendor_egl.defaultConfig(), @ptrFromInt(drawable), null);
        if (ctx.egl_surface == egl.EGL_NO_SURFACE) {
            if (debugEnabled()) std.debug.print("[prism-glx] window surface for XID 0x{x} failed: EGL 0x{x}\n", .{ drawable, vendor_egl.eglGetError() });
            return 0;
        }
        ctx.drawable = drawable;
        if (api_exports) |api| {
            if (api.addVendorDrawableMapping) |add| _ = add(dpy, drawable, vendor_id.?);
        }
    }
    if (vendor_egl.eglMakeCurrent(ctx.egl_display, ctx.egl_surface, ctx.egl_surface, ctx.egl_context) == egl.EGL_FALSE) {
        if (debugEnabled()) std.debug.print("[prism-glx] eglMakeCurrent failed: EGL 0x{x}\n", .{vendor_egl.eglGetError()});
        return 0;
    }
    if (debugEnabled()) std.debug.print("[prism-glx] bound XID 0x{x}\n", .{drawable});
    current = ctx;
    if (old) |previous| if (previous != ctx and previous.pending_delete) destroyContextStorage(previous);
    return 1;
}

pub export fn glXMakeCurrent(dpy: *Display, drawable: GLXDrawable, ctx: GLXContext) callconv(.c) Bool {
    return makeCurrent(dpy, drawable, ctx);
}

pub export fn glXMakeContextCurrent(dpy: *Display, draw: GLXDrawable, read: GLXDrawable, ctx: GLXContext) callconv(.c) Bool {
    if (draw != read) return 0;
    return makeCurrent(dpy, draw, ctx);
}

pub export fn glXSwapBuffers(dpy: *Display, drawable: GLXDrawable) callconv(.c) void {
    _ = dpy;
    if (current) |ctx| {
        if (ctx.drawable == drawable) _ = vendor_egl.eglSwapBuffers(ctx.egl_display, ctx.egl_surface);
    }
}

pub export fn glXUseXFont(font: usize, first: c_int, count: c_int, list: c_int) callconv(.c) void {
    _ = font;
    _ = first;
    _ = count;
    _ = list;
}

pub export fn glXWaitGL() callconv(.c) void {
    vendor_egl.glFinish();
}

pub export fn glXWaitX() callconv(.c) void {}

pub export fn glXQueryVersion(dpy: *Display, major: *c_int, minor: *c_int) callconv(.c) Bool {
    _ = dpy;
    major.* = 1;
    minor.* = 4;
    return 1;
}

const extensions: [*:0]const u8 = "GLX_ARB_create_context GLX_ARB_create_context_profile GLX_EXT_libglvnd";
const vendor_string: [*:0]const u8 = "Prism";
const version_string: [*:0]const u8 = "1.4 Prism";
pub export fn glXQueryExtensionsString(dpy: *Display, screen: c_int) callconv(.c) [*:0]const u8 {
    _ = dpy;
    _ = screen;
    return extensions;
}
pub export fn glXGetClientString(dpy: *Display, name: c_int) callconv(.c) [*:0]const u8 {
    _ = dpy;
    return if (name == 1) vendor_string else version_string;
}
pub export fn glXQueryServerString(dpy: *Display, screen: c_int, name: c_int) callconv(.c) [*:0]const u8 {
    _ = screen;
    return glXGetClientString(dpy, name);
}
pub export fn glXIsDirect(dpy: *Display, ctx: GLXContext) callconv(.c) Bool {
    _ = dpy;
    return @intFromBool(ctx != null);
}
pub export fn glXGetCurrentContext() callconv(.c) GLXContext {
    return if (current) |ctx| @ptrCast(ctx) else null;
}
pub export fn glXGetCurrentDrawable() callconv(.c) GLXDrawable {
    return if (current) |ctx| ctx.drawable else 0;
}
pub export fn glXGetCurrentReadDrawable() callconv(.c) GLXDrawable {
    return glXGetCurrentDrawable();
}
pub export fn glXGetCurrentDisplay() callconv(.c) ?*Display {
    return if (current) |ctx| ctx.x_display else null;
}
pub export fn glXCreateWindow(dpy: *Display, config: GLXFBConfig, win: usize, attribs: ?[*]const c_int) callconv(.c) GLXWindow {
    _ = config;
    _ = attribs;
    addDrawableMapping(dpy, win);
    return win;
}
pub export fn glXDestroyWindow(dpy: *Display, win: GLXWindow) callconv(.c) void {
    removeDrawableMapping(dpy, win);
}
pub export fn glXCreatePixmap(dpy: *Display, config: GLXFBConfig, pixmap: usize, attribs: ?[*]const c_int) callconv(.c) GLXPixmap {
    _ = config;
    _ = attribs;
    addDrawableMapping(dpy, pixmap);
    return pixmap;
}
pub export fn glXDestroyPixmap(dpy: *Display, pixmap: GLXPixmap) callconv(.c) void {
    removeDrawableMapping(dpy, pixmap);
}
pub export fn glXCreatePbuffer(dpy: *Display, config: GLXFBConfig, attribs: ?[*]const c_int) callconv(.c) GLXPbuffer {
    _ = dpy;
    _ = config;
    _ = attribs;
    return 0;
}
pub export fn glXDestroyPbuffer(dpy: *Display, pbuffer: GLXPbuffer) callconv(.c) void {
    _ = dpy;
    _ = pbuffer;
}
pub export fn glXGetSelectedEvent(dpy: *Display, drawable: GLXDrawable, mask: *c_ulong) callconv(.c) void {
    _ = dpy;
    _ = drawable;
    mask.* = 0;
}
pub export fn glXSelectEvent(dpy: *Display, drawable: GLXDrawable, mask: c_ulong) callconv(.c) void {
    _ = dpy;
    _ = drawable;
    _ = mask;
}
pub export fn glXQueryContext(dpy: *Display, handle: GLXContext, attribute: c_int, value: *c_int) callconv(.c) c_int {
    _ = dpy;
    _ = handle;
    value.* = switch (attribute) {
        GLX_FBCONFIG_ID => 1,
        GLX_RENDER_TYPE => GLX_RGBA_BIT,
        GLX_SCREEN => 0,
        else => return GLX_BAD_ATTRIBUTE,
    };
    return GLX_SUCCESS;
}
pub export fn glXQueryDrawable(dpy: *Display, drawable: GLXDrawable, attribute: c_int, value: *c_uint) callconv(.c) void {
    _ = dpy;
    _ = drawable;
    _ = attribute;
    value.* = 0;
}
pub export fn glXGetProcAddress(name: [*:0]const u8) callconv(.c) Proc {
    return if (lookup(name)) |p| @ptrCast(@alignCast(p)) else null;
}

test "GLVND handshake installs required callbacks" {
    defer {
        api_exports = null;
        vendor_id = null;
    }
    var imports: ApiImports = undefined;
    var exports: ApiExports = std.mem.zeroes(ApiExports);
    var token: u8 = 0;
    try std.testing.expectEqual(@as(Bool, 1), __glx_Main(0x00010000, &exports, &token, &imports));
    try std.testing.expect(imports.isScreenSupported != null);
    try std.testing.expect(imports.getProcAddress != null);
    try std.testing.expect(imports.getDispatchAddress != null);
    try std.testing.expect(imports.setDispatchIndex != null);
}

test "every required GLX 1.4 vendor entry point resolves" {
    const required = [_][:0]const u8{
        "glXChooseVisual",          "glXCopyContext",        "glXCreateContext",
        "glXCreateGLXPixmap",       "glXDestroyContext",     "glXDestroyGLXPixmap",
        "glXGetConfig",             "glXIsDirect",           "glXMakeCurrent",
        "glXSwapBuffers",           "glXUseXFont",           "glXWaitGL",
        "glXWaitX",                 "glXQueryServerString",  "glXGetClientString",
        "glXQueryExtensionsString", "glXChooseFBConfig",     "glXCreateNewContext",
        "glXCreatePbuffer",         "glXCreatePixmap",       "glXCreateWindow",
        "glXDestroyPbuffer",        "glXDestroyPixmap",      "glXDestroyWindow",
        "glXGetFBConfigAttrib",     "glXGetFBConfigs",       "glXGetSelectedEvent",
        "glXGetVisualFromFBConfig", "glXMakeContextCurrent", "glXQueryContext",
        "glXQueryDrawable",         "glXSelectEvent",
    };
    for (required) |name| try std.testing.expect(lookup(name.ptr) != null);
}
