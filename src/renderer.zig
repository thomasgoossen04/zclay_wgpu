const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zglfw = @import("zglfw");
const std = @import("std");
const builtin = @import("builtin");
const Window = @import("window.zig").Window;
const clay = @import("zclay");
const rc = @import("render_commands.zig");
const font = @import("font.zig");

pub const HardwareInfo = struct {
    gpu: [128]u8 = .{0} ** 128,
    gpu_len: usize = 0,
    backend: [24]u8 = .{0} ** 24,
    backend_len: usize = 0,
    adapter_type: [24]u8 = .{0} ** 24,
    adapter_type_len: usize = 0,
    display: [32]u8 = .{0} ** 32,
    display_len: usize = 0,
    cpu_arch: []const u8 = @tagName(builtin.cpu.arch),
    os_name: []const u8 = @tagName(builtin.os.tag),
};

const max_vertices: u32 = 65536;
const max_indices: u32 = 196608;
const max_draw_calls: u32 = 256;

const geom_wgsl = @embedFile("clay.wgsl");
const text_wgsl = @embedFile("clay_text.wgsl");

const Uniforms = extern struct { projection: [16]f32 };

fn orthoProjection(w: f32, h: f32) [16]f32 {
    return .{
        2.0 / w, 0,        0, 0,
        0,       -2.0 / h, 0, 0,
        0,       0,        1, 0,
        -1,      1,        0, 1,
    };
}

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    glfw_window: *zglfw.Window,
    clay_memory: []u8,

    geom_pipeline: zgpu.RenderPipelineHandle,
    geom_bg: zgpu.BindGroupHandle,
    text_pipeline: zgpu.RenderPipelineHandle,
    text_bg: zgpu.BindGroupHandle,

    vertex_buf: zgpu.BufferHandle,
    index_buf: zgpu.BufferHandle,
    uniform_buf: zgpu.BufferHandle,

    cpu_verts: []rc.Vertex,
    cpu_idxs: []u32,
    cpu_dcs: []rc.DrawCall,

    font_atlas: font.FontAtlas,
    last_time: f64,

    last_cmds_hash: u64 = 0,
    cached_vertex_count: u32 = 0,
    cached_index_count: u32 = 0,
    cached_draw_call_count: u32 = 0,

    msaa_texture: zgpu.TextureHandle = .{},
    msaa_view: zgpu.TextureViewHandle = .{},
    msaa_size: [2]u32 = .{ 0, 0 },
    /// False when ui_scale is so large the clay coordinate space is too small to lay out.
    ui_fits: bool = true,

    pub fn init(allocator: std.mem.Allocator, window: Window, low_power: bool) !Renderer {
        const power_pref: wgpu.PowerPreference = if (low_power) .low_power else .high_performance;
        const gctx = try zgpu.GraphicsContext.create(
            allocator,
            .{
                .window = window.window,
                .fn_getTime = @ptrCast(&zglfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
                .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
                .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
                .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
                .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
            },
            .{
                .present_mode = .fifo,
                .power_preference = power_pref,
            },
        );

        const clay_memory = try allocator.alloc(u8, clay.minMemorySize());
        _ = clay.initialize(
            clay.Arena.init(clay_memory),
            .{ .w = @floatFromInt(window.init_w), .h = @floatFromInt(window.init_h) },
            .{},
        );
        // Fallback measurement (no font yet); upgraded in loadFont
        clay.setMeasureTextFunction(void, {}, fallbackMeasureText);

        const dpi_scale = window.window.getContentScale()[0];
        const atlas = try font.FontAtlas.init(allocator, gctx, dpi_scale);

        const uniform_buf = gctx.createBuffer(.{
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(Uniforms),
        });

        const vertex_attribs = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = @offsetOf(rc.Vertex, "color"), .shader_location = 1 },
            .{ .format = .float32x2, .offset = @offsetOf(rc.Vertex, "uv"), .shader_location = 2 },
        };
        const vbl = wgpu.VertexBufferLayout{
            .array_stride = @sizeOf(rc.Vertex),
            .attribute_count = vertex_attribs.len,
            .attributes = &vertex_attribs,
        };
        const blend = wgpu.BlendState{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
            .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
        };
        const color_target = wgpu.ColorTargetState{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &blend,
        };

        // ── Geometry pipeline ──────────────────────────────────────────────
        const bgl_geom = gctx.createBindGroupLayout(&.{.{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .buffer = .{ .binding_type = .uniform, .min_binding_size = @sizeOf(Uniforms) },
        }});
        defer gctx.releaseResource(bgl_geom);

        const geom_shader = zgpu.createWgslShaderModule(gctx.device, geom_wgsl, "clay_geom");
        defer geom_shader.release();

        const geom_frag = wgpu.FragmentState{
            .module = geom_shader,
            .entry_point = "fs",
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };
        const geom_pl = gctx.createPipelineLayout(&.{bgl_geom});
        defer gctx.releaseResource(geom_pl);
        const geom_pipeline = gctx.createRenderPipeline(geom_pl, .{
            .vertex = .{ .module = geom_shader, .entry_point = "vs", .buffer_count = 1, .buffers = @ptrCast(&vbl) },
            .fragment = &geom_frag,
            .primitive = .{ .topology = .triangle_list },
            .multisample = .{ .count = 4 },
        });

        const geom_bg = gctx.createBindGroup(bgl_geom, &.{.{
            .binding = 0,
            .buffer_handle = uniform_buf,
            .offset = 0,
            .size = @sizeOf(Uniforms),
        }});

        // ── Text pipeline ──────────────────────────────────────────────────
        const bgl_text = gctx.createBindGroupLayout(&.{
            .{
                .binding = 0,
                .visibility = .{ .vertex = true },
                .buffer = .{ .binding_type = .uniform, .min_binding_size = @sizeOf(Uniforms) },
            },
            .{
                .binding = 1,
                .visibility = .{ .fragment = true },
                .texture = .{ .sample_type = .float, .view_dimension = .tvdim_2d, .multisampled = false },
            },
            .{
                .binding = 2,
                .visibility = .{ .fragment = true },
                .sampler = .{ .binding_type = .filtering },
            },
        });
        defer gctx.releaseResource(bgl_text);

        const text_shader = zgpu.createWgslShaderModule(gctx.device, text_wgsl, "clay_text");
        defer text_shader.release();

        const text_frag = wgpu.FragmentState{
            .module = text_shader,
            .entry_point = "fs",
            .target_count = 1,
            .targets = @ptrCast(&color_target),
        };
        const text_pl = gctx.createPipelineLayout(&.{bgl_text});
        defer gctx.releaseResource(text_pl);
        const text_pipeline = gctx.createRenderPipeline(text_pl, .{
            .vertex = .{ .module = text_shader, .entry_point = "vs", .buffer_count = 1, .buffers = @ptrCast(&vbl) },
            .fragment = &text_frag,
            .primitive = .{ .topology = .triangle_list },
            .multisample = .{ .count = 4 },
        });

        const text_bg = gctx.createBindGroup(bgl_text, &.{
            .{ .binding = 0, .buffer_handle = uniform_buf, .offset = 0, .size = @sizeOf(Uniforms) },
            .{ .binding = 1, .texture_view_handle = atlas.texture_view },
            .{ .binding = 2, .sampler_handle = atlas.sampler },
        });

        // ── Geometry buffers ───────────────────────────────────────────────
        const vertex_buf = gctx.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = max_vertices * @sizeOf(rc.Vertex),
        });
        const index_buf = gctx.createBuffer(.{
            .usage = .{ .index = true, .copy_dst = true },
            .size = max_indices * @sizeOf(u32),
        });

        const cpu_verts = try allocator.alloc(rc.Vertex, max_vertices);
        const cpu_idxs = try allocator.alloc(u32, max_indices);
        const cpu_dcs = try allocator.alloc(rc.DrawCall, max_draw_calls);

        return .{
            .alloc = allocator,
            .gctx = gctx,
            .glfw_window = window.window,
            .clay_memory = clay_memory,
            .geom_pipeline = geom_pipeline,
            .geom_bg = geom_bg,
            .text_pipeline = text_pipeline,
            .text_bg = text_bg,
            .vertex_buf = vertex_buf,
            .index_buf = index_buf,
            .uniform_buf = uniform_buf,
            .cpu_verts = cpu_verts,
            .cpu_idxs = cpu_idxs,
            .cpu_dcs = cpu_dcs,
            .font_atlas = atlas,
            .last_time = zglfw.getTime(),
        };
    }

    /// Set a global scale multiplier for all text (1.0 = default, 1.5 = 50% larger).
    /// Takes effect immediately on the next frame.
    pub fn setUiScale(self: *Renderer, scale: f32) void {
        self.font_atlas.setUiScale(scale);
    }

    /// Load a TrueType font and return its font_id for use in clay text elements.
    pub fn loadFont(self: *Renderer, font_data: []const u8) !u16 {
        const id = try self.font_atlas.addFont(font_data);
        clay.setMeasureTextFunction(*font.FontAtlas, &self.font_atlas, font.measureTextFn);
        return id;
    }

    pub fn beginFrame(self: *Renderer) wgpu.TextureView {
        _ = self.font_atlas.updateDpiScale(self.glfw_window.getContentScale()[0]);

        const win = self.glfw_window.getSize();
        const ui = self.font_atlas.ui_scale;
        const clay_w = @as(f32, @floatFromInt(win[0])) / ui;
        const clay_h = @as(f32, @floatFromInt(win[1])) / ui;
        clay.setLayoutDimensions(.{ .w = clay_w, .h = clay_h });
        self.ui_fits = clay_w >= 200.0 and clay_h >= 150.0;

        // setPointerState must come before updateScrollContainers
        const cursor = self.glfw_window.getCursorPos();
        const btn = self.glfw_window.getMouseButton(.left);
        const ptr_pos = clay.Vector2{
            .x = @as(f32, @floatCast(cursor[0])) / ui,
            .y = @as(f32, @floatCast(cursor[1])) / ui,
        };
        clay.setPointerState(ptr_pos, btn == .press);

        // Delta time
        const now = zglfw.getTime();
        const dt: f32 = @floatCast(now - self.last_time);
        self.last_time = now;

        // Scroll delta: convert from scroll steps to clay-coordinate pixels
        const scroll_speed: f32 = 40.0;
        const raw = @import("window.zig").takeScrollDelta();
        clay.updateScrollContainers(true, .{
            .x = raw[0] * scroll_speed / ui,
            .y = raw[1] * scroll_speed / ui,
        }, dt);

        clay.beginLayout();
        return self.gctx.swapchain.getCurrentTextureView();
    }

    pub fn endFrame(self: *Renderer, back_buffer: wgpu.TextureView) void {
        const cmds = clay.endLayout();

        // If the framebuffer was just resized, back_buffer is already at the new size
        // but swapchain_descriptor still holds the old size. The MSAA resolve would see
        // a size mismatch and produce garbage. Skip this frame so present() can catch up.
        const raw_fb = self.glfw_window.getFramebufferSize();
        const gctx = self.gctx;
        if (@as(u32, @intCast(raw_fb[0])) != gctx.swapchain_descriptor.width or
            @as(u32, @intCast(raw_fb[1])) != gctx.swapchain_descriptor.height)
        {
            back_buffer.release();
            _ = gctx.present();
            return;
        }

        const fb_w = gctx.swapchain_descriptor.width;
        const fb_h = gctx.swapchain_descriptor.height;
        const win = self.glfw_window.getSize();
        const ui = self.font_atlas.ui_scale;
        const clay_w = @as(f32, @floatFromInt(win[0])) / ui;
        const clay_h = @as(f32, @floatFromInt(win[1])) / ui;
        // Physical pixels per clay coordinate unit
        const dpi_x: f32 = @as(f32, @floatFromInt(fb_w)) / clay_w;
        const dpi_y: f32 = @as(f32, @floatFromInt(fb_h)) / clay_h;

        const uniforms = Uniforms{ .projection = orthoProjection(clay_w, clay_h) };
        gctx.queue.writeBuffer(gctx.lookupResource(self.uniform_buf).?, 0, Uniforms, &.{uniforms});

        // Only update the gpu buffers if there is something new to show
        const new_hash = hashCmds(cmds);
        if (new_hash != self.last_cmds_hash or self.font_atlas.dirty) {
            self.font_atlas.flush();
            const result = rc.build(cmds, self.cpu_verts, self.cpu_idxs, self.cpu_dcs, &self.font_atlas);

            if (result.vertex_count > 0) {
                gctx.queue.writeBuffer(gctx.lookupResource(self.vertex_buf).?, 0, rc.Vertex, self.cpu_verts[0..result.vertex_count]);
                gctx.queue.writeBuffer(gctx.lookupResource(self.index_buf).?, 0, u32, self.cpu_idxs[0..result.index_count]);
            }

            self.last_cmds_hash = new_hash;
            self.cached_vertex_count = result.vertex_count;
            self.cached_index_count = result.index_count;
            self.cached_draw_call_count = result.draw_call_count;
        }

        // Recreate MSAA texture if framebuffer size changed
        if (self.msaa_size[0] != fb_w or self.msaa_size[1] != fb_h) {
            if (self.msaa_size[0] > 0) {
                gctx.releaseResource(self.msaa_view);
                gctx.destroyResource(self.msaa_texture);
            }
            self.msaa_texture = gctx.createTexture(.{
                .usage = .{ .render_attachment = true },
                .dimension = .tdim_2d,
                .size = .{ .width = fb_w, .height = fb_h, .depth_or_array_layers = 1 },
                .format = zgpu.GraphicsContext.swapchain_format,
                .mip_level_count = 1,
                .sample_count = 4,
            });
            self.msaa_view = gctx.createTextureView(self.msaa_texture, .{});
            self.msaa_size = .{ fb_w, fb_h };
        }

        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        const msaa_view = gctx.lookupResource(self.msaa_view).?;
        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = msaa_view,
            .resolve_target = back_buffer,
            .load_op = .clear,
            .store_op = .discard,
            .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
        }};
        const pass = encoder.beginRenderPass(.{
            .color_attachment_count = 1,
            .color_attachments = &color_attachments,
        });

        if (self.cached_vertex_count > 0 and self.cached_draw_call_count > 0) {
            pass.setVertexBuffer(0, gctx.lookupResource(self.vertex_buf).?, 0, self.cached_vertex_count * @sizeOf(rc.Vertex));
            pass.setIndexBuffer(gctx.lookupResource(self.index_buf).?, .uint32, 0, self.cached_index_count * @sizeOf(u32));

            const geom_bg = gctx.lookupResource(self.geom_bg).?;
            const text_bg = gctx.lookupResource(self.text_bg).?;
            const geom_pipe = gctx.lookupResource(self.geom_pipeline).?;
            const text_pipe = gctx.lookupResource(self.text_pipeline).?;

            var active_text: ?bool = null;

            for (self.cpu_dcs[0..self.cached_draw_call_count]) |dc| {
                // Scissor from clay is in logical pixels — convert to physical, then
                // clamp to framebuffer bounds (elements at the edge can produce x+w > fb_w).
                const s: [4]u32 = if (dc.scissor) |ls| .{
                    @intFromFloat(@floor(@as(f32, @floatFromInt(ls[0])) * dpi_x)),
                    @intFromFloat(@floor(@as(f32, @floatFromInt(ls[1])) * dpi_y)),
                    @intFromFloat(@ceil(@as(f32, @floatFromInt(ls[2])) * dpi_x)),
                    @intFromFloat(@ceil(@as(f32, @floatFromInt(ls[3])) * dpi_y)),
                } else .{ 0, 0, fb_w, fb_h };
                const sx = @min(s[0], fb_w);
                const sy = @min(s[1], fb_h);
                pass.setScissorRect(sx, sy, @min(s[2], fb_w - sx), @min(s[3], fb_h - sy));

                if (active_text == null or active_text.? != dc.is_text) {
                    if (dc.is_text) {
                        pass.setPipeline(text_pipe);
                        pass.setBindGroup(0, text_bg, null);
                    } else {
                        pass.setPipeline(geom_pipe);
                        pass.setBindGroup(0, geom_bg, null);
                    }
                    active_text = dc.is_text;
                }

                pass.drawIndexed(dc.index_count, 1, dc.index_start, 0, 0);
            }
        }

        zgpu.endReleasePass(pass);

        const cmd_buf = encoder.finish(null);
        defer cmd_buf.release();
        gctx.queue.submit(&.{cmd_buf});

        back_buffer.release();
        _ = gctx.present();
    }

    pub fn getHardwareInfo(self: *const Renderer) HardwareInfo {
        const adapter = self.gctx.device.getAdapter();
        defer adapter.release();

        var props: wgpu.AdapterProperties = std.mem.zeroes(wgpu.AdapterProperties);
        adapter.getProperties(&props);

        var info = HardwareInfo{};
        info.gpu_len = copyStr(&info.gpu, std.mem.span(props.name));
        info.backend_len = copyStr(&info.backend, backendDisplayName(props.backend_type));
        info.adapter_type_len = copyStr(&info.adapter_type, adapterTypeDisplayName(props.adapter_type));

        if (zglfw.Monitor.getPrimary()) |mon| {
            if (mon.getVideoMode()) |vm| {
                if (std.fmt.bufPrint(&info.display, "{d}x{d} @{d}Hz", .{
                    vm.width, vm.height, vm.refresh_rate,
                })) |s| {
                    info.display_len = s.len;
                } else |_| {}
            } else |_| {}
        }

        return info;
    }

    pub fn deinit(self: *Renderer) void {
        self.font_atlas.deinit();
        self.alloc.free(self.cpu_verts);
        self.alloc.free(self.cpu_idxs);
        self.alloc.free(self.cpu_dcs);
        self.alloc.free(self.clay_memory);
        self.gctx.destroy(self.alloc);
    }

    pub fn getPointerState(self: *Renderer) clay.PointerData {
        const pos = self.glfw_window.getCursorPos();
        const btn = self.glfw_window.getMouseButton(.left);
        const ui = self.font_atlas.ui_scale;
        return .{
            .position = .{ .x = @as(f32, @floatCast(pos[0])) / ui, .y = @as(f32, @floatCast(pos[1])) / ui },
            .state = switch (btn) {
                .press => .pressed,
                else => .released,
            },
        };
    }
};

fn copyStr(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn backendDisplayName(bt: wgpu.BackendType) []const u8 {
    return switch (bt) {
        .vulkan => "Vulkan",
        .metal => "Metal",
        .d3d12 => "Direct3D 12",
        .d3d11 => "Direct3D 11",
        .opengl => "OpenGL",
        .opengles => "OpenGL ES",
        .webgpu => "WebGPU",
        else => "Unknown",
    };
}

fn adapterTypeDisplayName(at: wgpu.AdapterType) []const u8 {
    return switch (at) {
        .discrete_gpu => "Discrete GPU",
        .integrated_gpu => "Integrated GPU",
        .cpu => "Software",
        .unknown => "Unknown",
    };
}

fn hashCmds(cmds: []const clay.RenderCommand) u64 {
    var h = std.hash.Wyhash.init(0);
    for (cmds) |cmd| {
        h.update(std.mem.asBytes(&cmd.bounding_box));
        h.update(std.mem.asBytes(&cmd.z_index));
        h.update(std.mem.asBytes(&cmd.command_type));
        switch (cmd.command_type) {
            .text => {
                const td = cmd.render_data.text;
                // Dereference the pointer — hashing the address would miss text changes
                // when clay reuses the same arena slot with new string content.
                h.update(td.string_contents.chars[0..@intCast(td.string_contents.length)]);
                h.update(std.mem.asBytes(&td.text_color));
                h.update(std.mem.asBytes(&td.font_id));
                h.update(std.mem.asBytes(&td.font_size));
                h.update(std.mem.asBytes(&td.letter_spacing));
                h.update(std.mem.asBytes(&td.line_height));
            },
            else => {
                // No content-relevant pointers in rectangle/border/scissor/image data.
                h.update(std.mem.asBytes(&cmd.render_data));
            },
        }
    }
    return h.final();
}

fn fallbackMeasureText(text: []const u8, config: *clay.TextElementConfig, _: void) clay.Dimensions {
    const char_width = @as(f32, @floatFromInt(config.font_size)) * 0.6;
    return .{
        .w = @as(f32, @floatFromInt(text.len)) * char_width,
        .h = @as(f32, @floatFromInt(config.font_size)),
    };
}
