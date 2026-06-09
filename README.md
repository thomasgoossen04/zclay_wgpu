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

Run `zig fetch --save git+https://github.com/thomasgoossen04/zclay_wgpu` to add this repo automatically.

For the wgpu implementation you are required to add the native dawn implementations for each platform,
so a full dependency list might look something like this:

```zig
    .dependencies = .{
        .zclay_wgpu = .{
            .url = "git+https://github.com/thomasgoossen04/zclay_wgpu.git#687c6c8b4c3d7f6b91d460ce5153c402208e1e44",
            .hash = "zclay_wgpu-0.1.0-C9syw5-uAwDE15A6JuCav9FRzXCY3TU4Rrys_goIDv68",
        },
        .dawn_x86_64_windows_gnu = .{
            .url = "https://github.com/michal-z/webgpu_dawn-x86_64-windows-gnu/archive/d3a68014e6b6b53fd330a0ccba99e4dcfffddae5.tar.gz",
            .hash = "N-V-__8AAGsYnAT5RIzeAu881RveLghQ1EidqgVBVx10gVTo",
        },
        .dawn_x86_64_linux_gnu = .{
            .url = "https://github.com/michal-z/webgpu_dawn-x86_64-linux-gnu/archive/7d70db023bf254546024629cbec5ee6113e12a42.tar.gz",
            .hash = "N-V-__8AAK7XUQNKNRnv1J6i189jtURJKjp3HTftoyD4Y4CB",
        },
        .dawn_aarch64_linux_gnu = .{
            .url = "https://github.com/michal-z/webgpu_dawn-aarch64-linux-gnu/archive/c1f55e740a62f6942ff046e709ecd509a005dbeb.tar.gz",
            .hash = "N-V-__8AAJ-wTwNc0T9oSflO92iO6IxrdMeRil37UU-KQD_M",
        },
        .dawn_aarch64_macos = .{
            .url = "https://github.com/michal-z/webgpu_dawn-aarch64-macos/archive/d2360cdfff0cf4a780cb77aa47c57aca03cc6dfe.tar.gz",
            .hash = "N-V-__8AALVIRAIf5nfpx8-4mEo2RGsynVryPQPcHk95qFM5",
        },
        .dawn_x86_64_macos = .{
            .url = "https://github.com/michal-z/webgpu_dawn-x86_64-macos/archive/901716b10b31ce3e0d3fe479326b41e91d59c661.tar.gz",
            .hash = "N-V-__8AAIz1QAKx8C8vft2YoHjGTjEAkH2QMR2UiAo8xZJ-",
        },
    },
```

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
    defer window.deinit();

    var renderer = try zcw.Renderer.init(init.gpa, window, true);
    defer renderer.deinit();

    const font_id = try renderer.loadFont(font_data);
    
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
