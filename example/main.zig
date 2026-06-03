const std = @import("std");
const zcw = @import("zclay_wgpu");
const clay = zcw.clay;

// ── Counting allocator ────────────────────────────────────────────────────────
const CountingAllocator = struct {
    child: std.mem.Allocator,
    current: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.current += len;
            if (self.current > self.peak) self.peak = self.current;
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            self.current += new_len - memory.len;
            if (self.current > self.peak) self.peak = self.current;
        } else {
            self.current -= memory.len - new_len;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > memory.len) {
                self.current += new_len - memory.len;
                if (self.current > self.peak) self.peak = self.current;
            } else {
                self.current -= memory.len - new_len;
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.current -= memory.len;
    }
};

fn fmtBytes(buf: []u8, n: usize) []const u8 {
    if (n >= 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f32, @floatFromInt(n)) / (1024.0 * 1024.0)}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} KB", .{@as(f32, @floatFromInt(n)) / 1024.0}) catch "?";
}

// ── Palette ───────────────────────────────────────────────────────────────────
const bg: clay.Color = .{ 10, 12, 20, 255 };
const surface: clay.Color = .{ 18, 22, 36, 255 };
const card: clay.Color = .{ 26, 32, 52, 255 };
const card_hover: clay.Color = .{ 34, 42, 68, 255 };
const accent: clay.Color = .{ 99, 102, 241, 255 };
const accent_hover: clay.Color = .{ 79, 82, 221, 255 };
const accent_dim: clay.Color = .{ 40, 42, 100, 255 };
const danger: clay.Color = .{ 239, 68, 68, 255 };
const danger_hover: clay.Color = .{ 209, 48, 48, 255 };
const success: clay.Color = .{ 34, 197, 94, 255 };
const warning: clay.Color = .{ 234, 179, 8, 255 };
const text: clay.Color = .{ 241, 245, 249, 255 };
const text_muted: clay.Color = .{ 100, 116, 139, 255 };
const border: clay.Color = .{ 38, 45, 72, 255 };
const transparent: clay.Color = .{ 0, 0, 0, 0 };

// ── App state ─────────────────────────────────────────────────────────────────
const Tab = enum(u8) { overview, analytics, users, settings, profiling };

const State = struct {
    tab: Tab = .overview,
    counter: i32 = 0,
    log_count: u32 = 0,
    last_action: []const u8 = "None",
    debug_mode: bool = false,
    log_buf: [64]u8 = undefined,
    counter_buf: [16]u8 = undefined,

    // Profiling (raw — updated every frame)
    frame_time_ms: f32 = 0,
    layout_time_ms: f32 = 0,
    fps: f32 = 0,
    frame_history: [60]f32 = [_]f32{0} ** 60,
    frame_history_idx: u32 = 0,
    // Display snapshots — updated every ~200 ms so text is readable
    display_fps: f32 = 0,
    display_frame_time_ms: f32 = 0,
    display_layout_time_ms: f32 = 0,
    display_mem_bytes: usize = 0,
    display_mem_peak_bytes: usize = 0,
    fps_buf: [20]u8 = undefined,
    frame_time_buf: [20]u8 = undefined,
    layout_time_buf: [20]u8 = undefined,
    avg_buf: [20]u8 = undefined,
    min_buf: [20]u8 = undefined,
    max_buf: [20]u8 = undefined,
    mem_buf: [24]u8 = undefined,
    mem_sub_buf: [32]u8 = undefined,
    mem_peak_buf: [24]u8 = undefined,
    hw: zcw.HardwareInfo = .{},
};

// ── Helpers ───────────────────────────────────────────────────────────────────
fn hovered(id: clay.ElementId) bool {
    return clay.pointerOver(id);
}

fn button(
    id_str: []const u8,
    label: []const u8,
    bg_color: clay.Color,
    bg_hover: clay.Color,
    font_id: u16,
    font_size: u16,
    clicked: bool,
) bool {
    const id = clay.ElementId.ID(id_str);
    const is_hovered = hovered(id);
    clay.UI()(.{
        .id = id,
        .layout = .{ .padding = .axes(8, 16), .child_alignment = .{ .x = .center, .y = .center } },
        .background_color = if (is_hovered) bg_hover else bg_color,
        .corner_radius = .all(6),
    })({
        clay.text(label, .{ .font_id = font_id, .font_size = font_size, .color = text });
    });
    return is_hovered and clicked;
}

fn statCard(
    id_str: []const u8,
    title: []const u8,
    value: []const u8,
    sub: []const u8,
    accent_color: clay.Color,
    font_id: u16,
) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id_str),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow, .h = .fixed(110) },
            .padding = .all(16),
            .child_gap = 6,
        },
        .background_color = card,
        .corner_radius = .all(10),
        .border = .{ .color = border, .width = .outside(1) },
    })({
        clay.text(title, .{ .font_id = font_id, .font_size = 12, .color = text_muted });
        clay.text(value, .{ .font_id = font_id, .font_size = 26, .color = text });
        clay.UI()(.{
            .id = clay.ElementId.localID(id_str),
            .layout = .{ .sizing = .{ .h = .fixed(4), .w = .fixed(40) } },
            .background_color = accent_color,
            .corner_radius = .all(2),
        })({});
        clay.text(sub, .{ .font_id = font_id, .font_size = 11, .color = text_muted });
    });
}

fn navItem(
    label: []const u8,
    tab: Tab,
    state: *State,
    font_id: u16,
    clicked: bool,
) void {
    const id = clay.ElementId.IDI("NavItem", @intFromEnum(tab));
    const selected = state.tab == tab;
    const is_hovered = hovered(id);
    clay.UI()(.{
        .id = id,
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(40) },
            .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
            .child_alignment = .{ .y = .center },
        },
        .background_color = if (selected) accent_dim else if (is_hovered) card_hover else transparent,
        .corner_radius = .all(6),
    })({
        clay.UI()(.{
            .id = clay.ElementId.localIDI("Indicator", @intFromEnum(tab)),
            .layout = .{ .sizing = .{ .w = .fixed(3), .h = .fixed(20) } },
            .background_color = if (selected) accent else transparent,
            .corner_radius = .all(2),
        })({});
        clay.UI()(.{
            .id = clay.ElementId.localIDI("NavSpacer", @intFromEnum(tab)),
            .layout = .{ .sizing = .{ .w = .fixed(10) } },
        })({});
        clay.text(label, .{
            .font_id = font_id,
            .font_size = 14,
            .color = if (selected) text else text_muted,
        });
    });
    if (is_hovered and clicked) state.tab = tab;
}

fn legendDot(id_str: []const u8, col: clay.Color, label: []const u8, font_id: u16) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id_str),
        .layout = .{ .child_gap = 6, .child_alignment = .{ .y = .center } },
    })({
        clay.UI()(.{
            .id = clay.ElementId.localID("Dot"),
            .layout = .{ .sizing = .{ .w = .fixed(8), .h = .fixed(8) } },
            .background_color = col,
            .corner_radius = .all(4),
        })({});
        clay.text(label, .{ .font_id = font_id, .font_size = 11, .color = text_muted });
    });
}

fn timingRow(id_str: []const u8, label: []const u8, value: []const u8, col: clay.Color, font_id: u16) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id_str),
        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(32) }, .child_alignment = .{ .y = .center } },
    })({
        clay.UI()(.{
            .id = clay.ElementId.localID("Pip"),
            .layout = .{ .sizing = .{ .w = .fixed(6), .h = .fixed(6) } },
            .background_color = col,
            .corner_radius = .all(3),
        })({});
        clay.UI()(.{ .id = clay.ElementId.localID("Sp"), .layout = .{ .sizing = .{ .w = .fixed(10) } } })({});
        clay.text(label, .{ .font_id = font_id, .font_size = 13, .color = text });
        clay.UI()(.{ .id = clay.ElementId.localID("Grow"), .layout = .{ .sizing = .{ .w = .grow } } })({});
        clay.text(value, .{ .font_id = font_id, .font_size = 13, .color = col });
    });
}

// ── Tab content ───────────────────────────────────────────────────────────────
fn overviewContent(state: *State, font_id: u16, clicked: bool) void {
    clay.UI()(.{
        .id = .ID("StatsRow"),
        .layout = .{ .sizing = .{ .w = .grow }, .child_gap = 12 },
    })({
        statCard("RevCard", "Revenue", "$42,893", "+12.5% this month", success, font_id);
        statCard("UserCard", "Active Users", "1,284", "+8.2% this month", accent, font_id);
        statCard("UptimeCard", "Uptime", "99.8%", "Last 30 days", warning, font_id);
        statCard("TickCard", "Open Tickets", "17", "-4 since yesterday", danger, font_id);
    });

    clay.UI()(.{
        .id = .ID("ActionsSection"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow }, .child_gap = 10 },
    })({
        clay.text("Quick Actions", .{ .font_id = font_id, .font_size = 13, .color = text_muted });
        clay.UI()(.{
            .id = .ID("ActionsRow"),
            .layout = .{ .sizing = .{ .w = .grow }, .child_gap = 10 },
        })({
            if (button("BtnDeploy", "Deploy", accent, accent_hover, font_id, 13, clicked)) {
                state.last_action = "Deploy";
                state.log_count += 1;
            }
            if (button("BtnRestart", "Restart", card, card_hover, font_id, 13, clicked)) {
                state.last_action = "Restart";
                state.log_count += 1;
            }
            if (button("BtnAddUser", "+ Add User", card, card_hover, font_id, 13, clicked)) {
                state.last_action = "Add User";
                state.log_count += 1;
            }
            if (button("BtnLogs", "View Logs", card, card_hover, font_id, 13, clicked)) {
                state.last_action = "View Logs";
                state.log_count += 1;
            }
            if (button("BtnAlert", "Send Alert", danger, danger_hover, font_id, 13, clicked)) {
                state.last_action = "Alert sent!";
                state.log_count += 1;
            }
        });
    });

    clay.UI()(.{
        .id = .ID("CounterCard"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow },
            .padding = .all(16),
            .child_gap = 12,
        },
        .background_color = card,
        .corner_radius = .all(10),
        .border = .{ .color = border, .width = .outside(1) },
    })({
        clay.text("Counter", .{ .font_id = font_id, .font_size = 13, .color = text_muted });
        clay.UI()(.{
            .id = .ID("CounterRow"),
            .layout = .{ .child_gap = 12, .child_alignment = .{ .y = .center } },
        })({
            if (button("BtnDec", " - ", card, card_hover, font_id, 16, clicked))
                state.counter -= 1;

            const val_str = std.fmt.bufPrint(&state.counter_buf, "{d}", .{state.counter}) catch "?";
            clay.UI()(.{
                .id = .ID("CounterVal"),
                .layout = .{ .sizing = .{ .w = .fixed(70) }, .padding = .axes(8, 0), .child_alignment = .{ .x = .center } },
                .background_color = surface,
                .corner_radius = .all(6),
            })({
                clay.text(val_str, .{ .font_id = font_id, .font_size = 20, .color = text });
            });

            if (button("BtnInc", " + ", accent, accent_hover, font_id, 16, clicked))
                state.counter += 1;
        });

        const log_str = std.fmt.bufPrint(&state.log_buf, "Actions: {d}  |  Last: {s}", .{ state.log_count, state.last_action }) catch "?";
        clay.text(log_str, .{ .font_id = font_id, .font_size = 12, .color = text_muted });
    });
}

fn analyticsContent(font_id: u16) void {
    clay.UI()(.{
        .id = .ID("AnalyticsCard"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow },
            .padding = .all(16),
            .child_gap = 10,
        },
        .background_color = card,
        .corner_radius = .all(10),
        .border = .{ .color = border, .width = .outside(1) },
    })({
        clay.text("Weekly Traffic", .{ .font_id = font_id, .font_size = 14, .color = text_muted });
        clay.UI()(.{
            .id = .ID("BarChart"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(120) },
                .child_gap = 8,
                .child_alignment = .{ .y = .bottom },
            },
        })({
            const days = [_]struct { label: []const u8, h: f32, col: clay.Color }{
                .{ .label = "Mon", .h = 60, .col = accent },
                .{ .label = "Tue", .h = 90, .col = accent },
                .{ .label = "Wed", .h = 75, .col = accent },
                .{ .label = "Thu", .h = 110, .col = success },
                .{ .label = "Fri", .h = 95, .col = accent },
                .{ .label = "Sat", .h = 40, .col = warning },
                .{ .label = "Sun", .h = 30, .col = warning },
            };
            for (days, 0..) |day, i| {
                clay.UI()(.{
                    .id = clay.ElementId.IDI("BarCol", @intCast(i)),
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow }, .child_gap = 4, .child_alignment = .{ .x = .center, .y = .bottom } },
                })({
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("Bar", @intCast(i)),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(day.h) } },
                        .background_color = day.col,
                        .corner_radius = .{ .top_left = 4, .top_right = 4 },
                    })({});
                    clay.text(day.label, .{ .font_id = font_id, .font_size = 11, .color = text_muted });
                });
            }
        });
    });

    const metrics = [_]struct { name: []const u8, val: []const u8, col: clay.Color }{
        .{ .name = "Page Views", .val = "24,891", .col = accent },
        .{ .name = "Bounce Rate", .val = "38.4%", .col = warning },
        .{ .name = "Avg. Session", .val = "4m 12s", .col = success },
        .{ .name = "Conversions", .val = "3.7%", .col = danger },
    };
    for (metrics, 0..) |m, i| {
        clay.UI()(.{
            .id = clay.ElementId.IDI("MetricRow", @intCast(i)),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(44) }, .padding = .axes(0, 12), .child_alignment = .{ .y = .center } },
            .background_color = card,
            .corner_radius = .all(8),
        })({
            clay.UI()(.{
                .id = clay.ElementId.IDI("Dot", @intCast(i)),
                .layout = .{ .sizing = .{ .w = .fixed(8), .h = .fixed(8) } },
                .background_color = m.col,
                .corner_radius = .all(4),
            })({});
            clay.UI()(.{ .id = clay.ElementId.IDI("MetricSpacer", @intCast(i)), .layout = .{ .sizing = .{ .w = .fixed(10) } } })({});
            clay.text(m.name, .{ .font_id = font_id, .font_size = 13, .color = text });
            clay.UI()(.{ .id = clay.ElementId.IDI("MetricGrow", @intCast(i)), .layout = .{ .sizing = .{ .w = .grow } } })({});
            clay.text(m.val, .{ .font_id = font_id, .font_size = 13, .color = m.col });
        });
    }
}

fn usersContent(font_id: u16) void {
    const users = [_]struct { name: []const u8, role: []const u8, status: []const u8, col: clay.Color }{
        .{ .name = "Alice Johnson", .role = "Admin", .status = "Online", .col = success },
        .{ .name = "Bob Martinez", .role = "Developer", .status = "Online", .col = success },
        .{ .name = "Carol Chen", .role = "Designer", .status = "Away", .col = warning },
        .{ .name = "David Park", .role = "Developer", .status = "Offline", .col = text_muted },
        .{ .name = "Eva Williams", .role = "Manager", .status = "Online", .col = success },
        .{ .name = "Frank Okafor", .role = "DevOps", .status = "Online", .col = success },
    };

    for (users, 0..) |u, i| {
        const row_id = clay.ElementId.IDI("UserRow", @intCast(i));
        const is_hovered = hovered(row_id);
        clay.UI()(.{
            .id = row_id,
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(56) },
                .padding = .axes(0, 14),
                .child_gap = 12,
                .child_alignment = .{ .y = .center },
            },
            .background_color = if (is_hovered) card_hover else card,
            .corner_radius = .all(8),
        })({
            clay.UI()(.{
                .id = clay.ElementId.IDI("Avatar", @intCast(i)),
                .layout = .{ .sizing = .{ .w = .fixed(36), .h = .fixed(36) }, .child_alignment = .{ .x = .center, .y = .center } },
                .background_color = u.col,
                .corner_radius = .all(18),
            })({
                clay.text(u.name[0..1], .{ .font_id = font_id, .font_size = 16, .color = .{ 10, 12, 20, 255 } });
            });

            clay.UI()(.{
                .id = clay.ElementId.IDI("UserInfo", @intCast(i)),
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow }, .child_gap = 2 },
            })({
                clay.text(u.name, .{ .font_id = font_id, .font_size = 14, .color = text });
                clay.text(u.role, .{ .font_id = font_id, .font_size = 12, .color = text_muted });
            });

            clay.UI()(.{
                .id = clay.ElementId.IDI("StatusPill", @intCast(i)),
                .layout = .{ .padding = .axes(4, 10) },
                .background_color = .{ u.col[0], u.col[1], u.col[2], 40 },
                .corner_radius = .all(12),
            })({
                clay.text(u.status, .{ .font_id = font_id, .font_size = 11, .color = u.col });
            });
        });
    }
}

fn settingsContent(state: *State, font_id: u16, clicked: bool) void {
    const items = [_]struct { id: []const u8, label: []const u8, desc: []const u8, on: bool }{
        .{ .id = "SetAutoScale", .label = "Auto-scaling", .desc = "Automatically scale resources", .on = true },
        .{ .id = "SetNotify", .label = "Notifications", .desc = "Email alerts for critical events", .on = true },
        .{ .id = "SetMetrics", .label = "Metrics Collection", .desc = "Send anonymous usage data", .on = false },
        .{ .id = "SetBackup", .label = "Daily Backups", .desc = "Automated daily snapshots", .on = true },
        .{ .id = "SetMaintain", .label = "Maintenance Mode", .desc = "Pause incoming traffic", .on = false },
    };
    for (items, 0..) |item, i| {
        clay.UI()(.{
            .id = clay.ElementId.IDI("SettingRow", @intCast(i)),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(60) },
                .padding = .axes(0, 14),
                .child_alignment = .{ .y = .center },
                .child_gap = 12,
            },
            .background_color = card,
            .corner_radius = .all(8),
        })({
            clay.UI()(.{
                .id = clay.ElementId.IDI("SettingText", @intCast(i)),
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow }, .child_gap = 3 },
            })({
                clay.text(item.label, .{ .font_id = font_id, .font_size = 14, .color = text });
                clay.text(item.desc, .{ .font_id = font_id, .font_size = 12, .color = text_muted });
            });

            const toggle_id = clay.ElementId.ID(item.id);
            const tog_hov = hovered(toggle_id);
            clay.UI()(.{
                .id = toggle_id,
                .layout = .{ .sizing = .{ .w = .fixed(44), .h = .fixed(24) }, .padding = .axes(3, 3), .child_alignment = .{ .y = .center } },
                .background_color = if (item.on) accent else if (tog_hov) card_hover else border,
                .corner_radius = .all(12),
            })({
                clay.UI()(.{
                    .id = clay.ElementId.IDI("Knob", @intCast(i)),
                    .layout = .{ .sizing = .{ .w = .fixed(18), .h = .fixed(18) } },
                    .background_color = text,
                    .corner_radius = .all(9),
                })({});
            });
            _ = clicked;
            _ = state;
        });
    }
}

fn profilingContent(state: *State, font_id: u16) void {
    // Compute history stats
    var max_ft: f32 = 16.7;
    var min_ft: f32 = std.math.floatMax(f32);
    var sum_ft: f32 = 0;
    var count: u32 = 0;
    for (state.frame_history) |ft| {
        if (ft == 0) continue;
        if (ft > max_ft) max_ft = ft;
        if (ft < min_ft) min_ft = ft;
        sum_ft += ft;
        count += 1;
    }
    const avg_ft = if (count > 0) sum_ft / @as(f32, @floatFromInt(count)) else 0;
    if (count == 0) min_ft = 0;

    const fps_str = std.fmt.bufPrint(&state.fps_buf, "{d:.1} fps", .{state.display_fps}) catch "?";
    const ft_str = std.fmt.bufPrint(&state.frame_time_buf, "{d:.2} ms", .{state.display_frame_time_ms}) catch "?";
    const lt_str = std.fmt.bufPrint(&state.layout_time_buf, "{d:.3} ms", .{state.display_layout_time_ms}) catch "?";
    const avg_str = std.fmt.bufPrint(&state.avg_buf, "{d:.2} ms", .{avg_ft}) catch "?";
    const min_str = std.fmt.bufPrint(&state.min_buf, "{d:.2} ms", .{min_ft}) catch "?";
    const max_str = std.fmt.bufPrint(&state.max_buf, "{d:.2} ms", .{max_ft}) catch "?";
    const mem_str = fmtBytes(&state.mem_buf, state.display_mem_bytes);
    const mem_peak_str = fmtBytes(&state.mem_peak_buf, state.display_mem_peak_bytes);
    const mem_sub = std.fmt.bufPrint(&state.mem_sub_buf, "peak {s}", .{mem_peak_str}) catch "?";

    // ── Stat cards ────────────────────────────────────────────────────────────
    clay.UI()(.{
        .id = .ID("ProfStatsRow"),
        .layout = .{ .sizing = .{ .w = .grow }, .child_gap = 12 },
    })({
        statCard("ProfFPS", "Render FPS", fps_str, "excl. vsync sleep", success, font_id);
        statCard("ProfFT", "Frame Time", ft_str, "render work, excl. sleep", accent, font_id);
        statCard("ProfLT", "Layout Time", lt_str, "clay compute time", warning, font_id);
        statCard("ProfMem", "Heap", mem_str, mem_sub, text_muted, font_id);
    });

    // ── Frame time history chart ──────────────────────────────────────────────
    clay.UI()(.{
        .id = .ID("ProfChartCard"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow },
            .padding = .all(16),
            .child_gap = 10,
        },
        .background_color = card,
        .corner_radius = .all(10),
        .border = .{ .color = border, .width = .outside(1) },
    })({
        // Header row: title + avg readout
        clay.UI()(.{
            .id = .ID("ProfChartHdr"),
            .layout = .{ .sizing = .{ .w = .grow }, .child_alignment = .{ .y = .center } },
        })({
            clay.text("Frame Time History  (last 60 frames)", .{ .font_id = font_id, .font_size = 13, .color = text_muted });
            clay.UI()(.{ .id = .ID("ProfChartHdrGrow"), .layout = .{ .sizing = .{ .w = .grow } } })({});
            clay.text("avg ", .{ .font_id = font_id, .font_size = 12, .color = text_muted });
            clay.text(avg_str, .{ .font_id = font_id, .font_size = 12, .color = text });
        });

        // Bar chart — 60 bars, bottom-aligned, colored by frame-time budget
        clay.UI()(.{
            .id = .ID("ProfChart"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(80) },
                .child_gap = 1,
                .child_alignment = .{ .y = .bottom },
            },
            .background_color = .{ 15, 18, 30, 255 },
            .corner_radius = .all(6),
        })({
            for (0..60) |i| {
                const idx = (state.frame_history_idx + i) % 60;
                const ft = state.frame_history[idx];
                const h: f32 = if (ft > 0) @max(2, ft / max_ft * 76) else 0;
                const col: clay.Color =
                    if (ft == 0) .{ 25, 30, 48, 255 } else if (ft <= 16.7) success else if (ft <= 33.3) warning else danger;
                clay.UI()(.{
                    .id = clay.ElementId.IDI("ProfBar", @intCast(i)),
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(h) } },
                    .background_color = col,
                    .corner_radius = .{ .top_left = 2, .top_right = 2 },
                })({});
            }
        });

        // Legend
        clay.UI()(.{
            .id = .ID("ProfLegend"),
            .layout = .{ .child_gap = 20, .child_alignment = .{ .y = .center } },
        })({
            legendDot("LegGreen", success, "<=16.7ms (60 fps)", font_id);
            legendDot("LegYellow", warning, "<=33.3ms (30 fps)", font_id);
            legendDot("LegRed", danger, ">33.3ms", font_id);
        });
    });

    // ── Stats + memory detail row ─────────────────────────────────────────────
    clay.UI()(.{
        .id = .ID("ProfBottomRow"),
        .layout = .{ .sizing = .{ .w = .grow }, .child_gap = 12 },
    })({
        // Timing statistics
        clay.UI()(.{
            .id = .ID("ProfTimingCard"),
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .grow },
                .padding = .all(16),
                .child_gap = 4,
            },
            .background_color = card,
            .corner_radius = .all(10),
            .border = .{ .color = border, .width = .outside(1) },
        })({
            clay.text("Frame Statistics", .{ .font_id = font_id, .font_size = 13, .color = text_muted });
            clay.UI()(.{ .id = .ID("ProfTSep"), .layout = .{ .sizing = .{ .h = .fixed(6) } } })({});
            timingRow("StatMin", "Minimum", min_str, success, font_id);
            timingRow("StatAvg", "Average", avg_str, accent, font_id);
            timingRow("StatMax", "Maximum", max_str, danger, font_id);
        });

        // Hardware info
        clay.UI()(.{
            .id = .ID("ProfSysCard"),
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .grow },
                .padding = .all(16),
                .child_gap = 4,
            },
            .background_color = card,
            .corner_radius = .all(10),
            .border = .{ .color = border, .width = .outside(1) },
        })({
            clay.text("System", .{ .font_id = font_id, .font_size = 13, .color = text_muted });
            clay.UI()(.{ .id = .ID("ProfSSep"), .layout = .{ .sizing = .{ .h = .fixed(6) } } })({});
            timingRow("HwGPU", "GPU", state.hw.gpu[0..state.hw.gpu_len], accent, font_id);
            timingRow("HwBackend", "API", state.hw.backend[0..state.hw.backend_len], warning, font_id);
            timingRow("HwType", "Type", state.hw.adapter_type[0..state.hw.adapter_type_len], text_muted, font_id);
            timingRow("HwDisplay", "Display", state.hw.display[0..state.hw.display_len], success, font_id);
            timingRow("HwCPU", "CPU", state.hw.cpu_arch, text_muted, font_id);
            timingRow("HwOS", "OS", state.hw.os_name, text_muted, font_id);
        });
    });
}

// ── Root layout ───────────────────────────────────────────────────────────────
fn createLayout(state: *State, font_id: u16, clicked: bool) void {
    clay.UI()(.{
        .id = .ID("Root"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow },
        .background_color = bg,
    })({
        // ── Header ────────────────────────────────────────────────────────
        clay.UI()(.{
            .id = .ID("Header"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(52) },
                .padding = .axes(0, 20),
                .child_alignment = .{ .y = .center },
                .child_gap = 12,
            },
            .background_color = surface,
            .border = .{ .color = border, .width = .{ .bottom = 1 } },
        })({
            clay.text("Dashboard", .{ .font_id = font_id, .font_size = 16, .color = text });
            clay.UI()(.{ .id = .ID("HeaderGrow"), .layout = .{ .sizing = .{ .w = .grow } } })({});

            if (button("BtnDebug", if (state.debug_mode) "Debug: ON" else "Debug: OFF", if (state.debug_mode) accent else card, if (state.debug_mode) accent_hover else card_hover, font_id, 12, clicked)) {
                state.debug_mode = !state.debug_mode;
                clay.setDebugModeEnabled(state.debug_mode);
            }

            clay.UI()(.{
                .id = .ID("StatusPill"),
                .layout = .{ .padding = .axes(5, 10), .child_gap = 6, .child_alignment = .{ .y = .center } },
                .background_color = .{ success[0], success[1], success[2], 30 },
                .corner_radius = .all(12),
            })({
                clay.UI()(.{
                    .id = .ID("StatusDot"),
                    .layout = .{ .sizing = .{ .w = .fixed(7), .h = .fixed(7) } },
                    .background_color = success,
                    .corner_radius = .all(4),
                })({});
                clay.text("Online", .{ .font_id = font_id, .font_size = 12, .color = success });
            });
        });

        // ── Body ──────────────────────────────────────────────────────────
        clay.UI()(.{
            .id = .ID("Body"),
            .layout = .{ .sizing = .grow, .child_gap = 0 },
        })({
            // ── Sidebar ───────────────────────────────────────────────────
            clay.UI()(.{
                .id = .ID("Sidebar"),
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .w = .fixed(200), .h = .grow },
                    .padding = .all(12),
                    .child_gap = 4,
                },
                .background_color = surface,
                .border = .{ .color = border, .width = .{ .right = 1 } },
            })({
                clay.text("NAVIGATION", .{ .font_id = font_id, .font_size = 10, .color = text_muted });
                clay.UI()(.{ .id = .ID("NavSep"), .layout = .{ .sizing = .{ .h = .fixed(8) } } })({});
                navItem("Overview", .overview, state, font_id, clicked);
                navItem("Analytics", .analytics, state, font_id, clicked);
                navItem("Users", .users, state, font_id, clicked);
                navItem("Settings", .settings, state, font_id, clicked);
                navItem("Profiling", .profiling, state, font_id, clicked);

                clay.UI()(.{ .id = .ID("SidebarGrow"), .layout = .{ .sizing = .{ .h = .grow } } })({});
                clay.text("F1 - debug overlay", .{ .font_id = font_id, .font_size = 10, .color = text_muted });
            });

            // ── Main content ──────────────────────────────────────────────
            clay.UI()(.{
                .id = .ID("Main"),
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow, .padding = .all(20), .child_gap = 16 },
            })({
                const tab_titles = [_][]const u8{ "Overview", "Analytics", "Users", "Settings", "Profiling" };
                clay.text(tab_titles[@intFromEnum(state.tab)], .{ .font_id = font_id, .font_size = 20, .color = text });

                clay.UI()(.{
                    .id = .ID("ContentScroll"),
                    .layout = .{ .sizing = .grow },
                    .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
                })({
                    clay.UI()(.{
                        .id = .ID("ContentInner"),
                        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow }, .child_gap = 16 },
                    })({
                        switch (state.tab) {
                            .overview => overviewContent(state, font_id, clicked),
                            .analytics => analyticsContent(font_id),
                            .users => usersContent(font_id),
                            .settings => settingsContent(state, font_id, clicked),
                            .profiling => profilingContent(state, font_id),
                        }
                    });
                });
            });
        });
    });
}

fn overflowLayout(font_id: u16) void {
    clay.UI()(.{
        .id = .ID("OverflowRoot"),
        .layout = .{ .sizing = .grow, .child_alignment = .{ .x = .center, .y = .center }, .direction = .top_to_bottom, .child_gap = 12 },
        .background_color = bg,
    })({
        clay.UI()(.{
            .id = .ID("OverflowCard"),
            .layout = .{ .direction = .top_to_bottom, .padding = .all(24), .child_gap = 10, .child_alignment = .{ .x = .center } },
            .background_color = card,
            .corner_radius = .all(12),
            .border = .{ .color = danger, .width = .outside(1) },
        })({
            clay.text("UI scale too large", .{ .font_id = font_id, .font_size = 18, .color = danger });
            clay.text("Scroll down to reduce scale", .{ .font_id = font_id, .font_size = 13, .color = text_muted });
        });
    });
}

// ── Entry point ───────────────────────────────────────────────────────────────
const space_mono = @embedFile("resources/SpaceMono-Regular.ttf");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var w = try zcw.Window.init("Dashboard", 1600, 900, io);
    w.setFpsTarget(60);
    defer w.deinit();

    var counting_alloc = CountingAllocator{ .child = init.gpa };
    var r = try zcw.Renderer.init(counting_alloc.allocator(), w, true);
    var last_display_update = std.Io.Clock.awake.now(io);
    defer r.deinit();

    const font_id = try r.loadFont(space_mono);
    var state = State{};
    state.hw = r.getHardwareInfo();
    var prev_mouse = false;
    var prev_f1 = false;

    r.setUiScale(1.8);

    while (!w.shouldClose()) {
        if (w.keyPressed(.equal)) r.setUiScale(r.font_atlas.ui_scale + 0.1);
        if (w.keyPressed(.minus)) r.setUiScale(r.font_atlas.ui_scale - 0.1);

        const frame_start = std.Io.Clock.awake.now(io);
        w.beginFrame(io);

        const mouse_now = w.mouseDown();
        const clicked = mouse_now and !prev_mouse;
        prev_mouse = mouse_now;

        const f1_now = w.keyPressed(.F1);
        if (f1_now and !prev_f1) {
            state.debug_mode = !state.debug_mode;
            clay.setDebugModeEnabled(state.debug_mode);
        }
        prev_f1 = f1_now;

        const back_buffer = r.beginFrame();

        // ── Layout (timed for the profiling page) ─────────────────────────
        const layout_start = std.Io.Clock.awake.now(io);
        if (r.ui_fits) {
            createLayout(&state, font_id, clicked);
        } else {
            overflowLayout(font_id);
        }
        state.layout_time_ms = @as(f32, @floatFromInt(layout_start.untilNow(io, .awake).toNanoseconds())) / 1_000_000.0;

        r.endFrame(back_buffer);

        // ── Frame timing — measured after render, before the fps sleep ────
        const frame_ns = frame_start.untilNow(io, .awake).toNanoseconds();
        state.frame_time_ms = @as(f32, @floatFromInt(frame_ns)) / 1_000_000.0;
        state.fps = if (state.frame_time_ms > 0.001) 1000.0 / state.frame_time_ms else 9999.0;
        state.frame_history[state.frame_history_idx % 60] = state.frame_time_ms;
        state.frame_history_idx +%= 1;

        if (last_display_update.untilNow(io, .awake).toNanoseconds() >= 200_000_000) {
            state.display_fps = state.fps;
            state.display_frame_time_ms = state.frame_time_ms;
            state.display_layout_time_ms = state.layout_time_ms;
            state.display_mem_bytes = counting_alloc.current;
            state.display_mem_peak_bytes = counting_alloc.peak;
            last_display_update = std.Io.Clock.awake.now(io);
        }

        w.endFrame(io);
    }
}
