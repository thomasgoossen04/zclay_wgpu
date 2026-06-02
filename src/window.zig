const glfw = @import("zglfw");
const std = @import("std");

// Accumulated scroll delta — reset each frame via consumeScrollDelta()
var g_scroll_x: f32 = 0;
var g_scroll_y: f32 = 0;

fn scrollCb(_: *glfw.Window, x: f64, y: f64) callconv(.c) void {
    g_scroll_x += @floatCast(x);
    g_scroll_y += @floatCast(y);
}

pub fn takeScrollDelta() [2]f32 {
    const d = .{ g_scroll_x, g_scroll_y };
    g_scroll_x = 0;
    g_scroll_y = 0;
    return d;
}

pub const Window = struct {
    window: *glfw.Window,
    init_w: u32,
    init_h: u32,
    frame_start: std.Io.Timestamp,

    // 0 means automatic
    fps_target: u64,

    pub fn init(title: [:0]const u8, w: u32, h: u32, io: std.Io) !Window {
        try glfw.init();
        glfw.windowHint(.client_api, .no_api);
        const n_win = try glfw.createWindow(@intCast(w), @intCast(h), title, null, null);
        _ = n_win.setScrollCallback(scrollCb);
        glfw.pollEvents();
        return .{
            .window = n_win,
            .init_w = w,
            .init_h = h,
            .frame_start = std.Io.Clock.awake.now(io),
            .fps_target = 0,
        };
    }

    pub fn beginFrame(self: *Window, io: std.Io) void {
        self.frame_start = std.Io.Clock.awake.now(io);
        glfw.pollEvents();
    }

    pub fn endFrame(self: Window, io: std.Io) void {
        // Dawn ignores .fifo on X11; sleep the remaining budget to cap at 60 fps.
        const target_ns: u64 = if (self.fps_target == 0) getRefreshRateNs() else hzToNs(self.fps_target);
        const elapsed_ns = self.frame_start.untilNow(io, .awake).toNanoseconds();
        if (elapsed_ns < target_ns) {
            io.sleep(.fromNanoseconds(target_ns - elapsed_ns), .awake) catch {};
        }
    }

    pub fn shouldClose(self: Window) bool {
        return self.window.shouldClose();
    }

    /// Returns accumulated scroll since last call and resets it.
    pub fn consumeScrollDelta(self: Window) [2]f32 {
        _ = self;
        return takeScrollDelta();
    }

    pub fn mouseDown(self: Window) bool {
        return self.window.getMouseButton(.left) == .press;
    }

    pub fn keyPressed(self: Window, key: glfw.Key) bool {
        return self.window.getKey(key) == .press;
    }

    pub fn deinit(self: Window) void {
        self.window.destroy();
        glfw.terminate();
    }

    pub fn setFpsTarget(self: *Window, fps: u64) void {
        self.fps_target = fps;
    }

    pub fn hzToNs(hz: u64) u64 {
        return 1_000_000_000 / hz;
    }

    // Falls back to 60fps if it cannot find it
    pub fn getRefreshRateNs() u64 {
        const monitor = glfw.Monitor.getPrimary() orelse return 16_666_667;
        const mode = monitor.getVideoMode() catch return 16_666_667;
        const hz: u64 = if (mode.refresh_rate > 0) @intCast(mode.refresh_rate) else 60;
        return 1_000_000_000 / hz;
    }

    pub fn getRefreshRateHz() u64 {
        const monitor = glfw.Monitor.getPrimary() orelse return 60;
        const mode = monitor.getVideoMode() catch return 60;
        const hz: u64 = if (mode.refresh_rate > 0) @intCast(mode.refresh_rate) else 60;
        return hz;
    }
};
