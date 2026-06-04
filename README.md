# zclay_wgpu

A WebGPU renderer for [Clay](https://github.com/nicbarker/clay) UI layouts, written in Zig. It handles window creation, GPU setup, font rasterization, image loading, DPI scaling, and scroll input so you can focus on building your UI with Clay.

Requires Zig 0.16.0 or later.

## Quickstart

### 1. Add the dependency

In `build.zig.zon`:

```zig
.dependencies = .{
    .zclay_wgpu = .{
        .url = "git+https://github.com/thomasgoossen04/zclay_wgpu#COMMIT",
        .hash = "...",
    },
},
```

Run `zig fetch --save <url>` to fill in the hash automatically.

### 2. Wire up the build

In `build.zig`:

```zig
const zclay_wgpu = b.dependency("zclay_wgpu", .{});
@import("zclay_wgpu").addTo(exe);
```

`addTo` imports the module and links all required native libraries (Dawn, GLFW).

### 3. Write your app

```zig
const std = @import("std");
const zcw = @import("zclay_wgpu");
const clay = zcw.clay;

const font_data = @embedFile("MyFont.ttf");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var window = try zcw.Window.init("My App", 1280, 720, io);
    window.setFpsTarget(60);
    defer window.deinit();

    var renderer = try zcw.Renderer.init(init.gpa, window, true);
    defer renderer.deinit();

    const font_id = try renderer.loadFont(font_data);

    // Initialize Clay — must happen after Renderer.init
    const clay_mem = try init.gpa.alloc(u8, clay.minMemorySize());
    defer init.gpa.free(clay_mem);
    _ = clay.initialize(clay.Arena.init(clay_mem), .{ .w = 1280, .h = 720 }, .{});
    clay.setMeasureTextFunction(void, {}, renderer.measureText);

    while (!window.shouldClose()) {
        window.beginFrame(io);
        const back_buffer = renderer.beginFrame();

        clay.UI()(.{
            .id = .ID("Root"),
            .layout = .{ .sizing = .grow, .direction = .top_to_bottom },
        })({
            clay.text("Hello, world!", .{
                .font_id = font_id,
                .font_size = 24,
                .color = .{ 255, 255, 255, 255 },
            });
        });

        renderer.endFrame(back_buffer);
        window.endFrame(io);
    }
}
```

For a complete example with images, scrolling, tabs, and profiling, see `example/main.zig`.

### UI layout

Clay drives all layout and hit-testing. Refer to the [Clay documentation](https://github.com/nicbarker/clay) for the full API: sizing, padding, child alignment, borders, corner radii, scroll containers, and the debug overlay (toggle with `clay.setDebugModeEnabled(true)`).

The Zig bindings are provided by [zclay](https://github.com/johan0A/clay-zig-bindings).
