const std = @import("std");
const clay = @import("zclay");
const font = @import("font.zig");
const image_mod = @import("image.zig");
const math = std.math;

const num_circle_segments: u32 = 16;

pub const Vertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
    uv: [2]f32,
    /// (local_u, local_v, r/width, r/height) — used by image pipeline for
    /// rounded-corner masking. Zero for all other draw types.
    round: [4]f32,
};

pub const Pipeline = enum { geom, text, image };

pub const DrawCall = struct {
    index_start: u32,
    index_count: u32,
    scissor: ?[4]u32,
    pipeline: Pipeline,
};

pub const BuildResult = struct {
    vertex_count: u32,
    index_count: u32,
    draw_call_count: u32,
    overflowed: bool,
};

pub fn build(
    cmds: []const clay.RenderCommand,
    verts: []Vertex,
    idxs: []u32,
    draw_calls: []DrawCall,
    font_atlas: *font.FontAtlas,
    image_atlas: *image_mod.ImageAtlas,
) BuildResult {
    var b = Builder{ .verts = verts, .idxs = idxs, .dcs = draw_calls };
    b.beginBatch(null, .geom);

    for (cmds) |cmd| {
        const bb = cmd.bounding_box;
        switch (cmd.command_type) {
            .rectangle => {
                b.ensureMode(.geom);
                const rd = cmd.render_data.rectangle;
                const col = clayColor(rd.background_color);
                if (rd.corner_radius.top_left > 0) {
                    b.roundedRect(bb.x, bb.y, bb.width, bb.height, rd.corner_radius.top_left, col);
                } else {
                    b.rect(bb.x, bb.y, bb.width, bb.height, col);
                }
            },
            .border => {
                b.ensureMode(.geom);
                b.border(bb.x, bb.y, bb.width, bb.height, cmd.render_data.border);
            },
            .text => {
                b.ensureMode(.text);
                b.text(bb.x, bb.y, cmd.render_data.text, font_atlas);
            },
            .image => {
                b.ensureMode(.image);
                const rd = cmd.render_data.image;
                const id: u32 = @as(u32, @intCast(@intFromPtr(rd.image_data))) - 1;
                if (id < image_atlas.images.items.len) {
                    const info = image_atlas.images.items[id];
                    const tint: [4]f32 = if (rd.background_color[3] == 0)
                        .{ 1, 1, 1, 1 }
                    else
                        clayColor(rd.background_color);
                    b.imageQuad(bb.x, bb.y, bb.width, bb.height, info, tint, rd.corner_radius.top_left);
                }
            },
            .scissor_start => {
                b.flush();
                b.beginBatch(.{
                    @intFromFloat(@max(0, bb.x)),
                    @intFromFloat(@max(0, bb.y)),
                    @intFromFloat(@max(0, bb.width)),
                    @intFromFloat(@max(0, bb.height)),
                }, b.pipeline);
            },
            .scissor_end => {
                b.flush();
                b.beginBatch(null, .geom);
            },
            else => {},
        }
    }

    b.flush();
    return .{ .vertex_count = b.vc, .index_count = b.ic, .draw_call_count = b.dc, .overflowed = b.overflowed };
}

fn clayColor(c: clay.Color) [4]f32 {
    return .{ c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, c[3] / 255.0 };
}

const Builder = struct {
    verts: []Vertex,
    idxs: []u32,
    dcs: []DrawCall,
    vc: u32 = 0,
    ic: u32 = 0,
    dc: u32 = 0,
    batch_start: u32 = 0,
    scissor: ?[4]u32 = null,
    pipeline: Pipeline = .geom,
    overflowed: bool = false,

    fn beginBatch(b: *Builder, scissor: ?[4]u32, pipeline: Pipeline) void {
        b.batch_start = b.ic;
        b.scissor = scissor;
        b.pipeline = pipeline;
    }

    fn ensureMode(b: *Builder, want: Pipeline) void {
        if (b.pipeline == want) return;
        b.flush();
        b.pipeline = want;
        b.batch_start = b.ic;
    }

    fn flush(b: *Builder) void {
        const count = b.ic - b.batch_start;
        if (count == 0) return;
        b.dcs[b.dc] = .{
            .index_start = b.batch_start,
            .index_count = count,
            .scissor = b.scissor,
            .pipeline = b.pipeline,
        };
        b.dc += 1;
        b.batch_start = b.ic;
    }

    fn v(b: *Builder, x: f32, y: f32, col: [4]f32) u32 {
        return b.v_uv(x, y, 0, 0, col);
    }

    fn v_uv(b: *Builder, x: f32, y: f32, u: f32, vv: f32, col: [4]f32) u32 {
        if (b.vc >= b.verts.len) { b.overflowed = true; return 0; }
        const i = b.vc;
        b.verts[i] = .{ .pos = .{ x, y }, .color = col, .uv = .{ u, vv }, .round = .{ 0, 0, 0, 0 } };
        b.vc += 1;
        return i;
    }

    fn v_round(b: *Builder, x: f32, y: f32, atlas_u: f32, atlas_v: f32, local_u: f32, local_v: f32, rx: f32, ry: f32, col: [4]f32) u32 {
        if (b.vc >= b.verts.len) { b.overflowed = true; return 0; }
        const i = b.vc;
        b.verts[i] = .{ .pos = .{ x, y }, .color = col, .uv = .{ atlas_u, atlas_v }, .round = .{ local_u, local_v, rx, ry } };
        b.vc += 1;
        return i;
    }

    fn tri(b: *Builder, a: u32, c0: u32, c1: u32) void {
        if (b.ic + 3 > b.idxs.len) { b.overflowed = true; return; }
        b.idxs[b.ic] = a;
        b.idxs[b.ic + 1] = c0;
        b.idxs[b.ic + 2] = c1;
        b.ic += 3;
    }

    fn quad(b: *Builder, tl: u32, tr: u32, br: u32, bl: u32) void {
        b.tri(tl, tr, br);
        b.tri(tl, br, bl);
    }

    fn rect(b: *Builder, x: f32, y: f32, w: f32, h: f32, col: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const tl = b.v(x,     y,     col);
        const tr = b.v(x + w, y,     col);
        const br = b.v(x + w, y + h, col);
        const bl = b.v(x,     y + h, col);
        b.quad(tl, tr, br, bl);
    }

    fn roundedRect(b: *Builder, x: f32, y: f32, w: f32, h: f32, corner_radius: f32, col: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const r = @min(corner_radius, @min(w, h) / 2.0);
        const n: u32 = @max(num_circle_segments, @as(u32, @intFromFloat(r * 0.5)));

        const c_tl = b.v(x + r,     y + r,     col);
        const c_tr = b.v(x + w - r, y + r,     col);
        const c_br = b.v(x + w - r, y + h - r, col);
        const c_bl = b.v(x + r,     y + h - r, col);
        b.quad(c_tl, c_tr, c_br, c_bl);

        b.quad(b.v(x + r,     y,     col), b.v(x + w - r, y,     col), c_tr, c_tl);
        b.quad(c_bl, c_br, b.v(x + w - r, y + h, col), b.v(x + r, y + h, col));
        b.quad(b.v(x,     y + r,     col), c_tl, c_bl, b.v(x,     y + h - r, col));
        b.quad(c_tr, b.v(x + w, y + r, col), b.v(x + w, y + h - r, col), c_br);

        const corners = [4]struct { cx: f32, cy: f32, center: u32, a0: f32, a1: f32 }{
            .{ .cx = x + r,     .cy = y + r,     .center = c_tl, .a0 = math.pi,       .a1 = 1.5 * math.pi },
            .{ .cx = x + w - r, .cy = y + r,     .center = c_tr, .a0 = 1.5 * math.pi, .a1 = 2.0 * math.pi },
            .{ .cx = x + w - r, .cy = y + h - r, .center = c_br, .a0 = 0.0,           .a1 = 0.5 * math.pi },
            .{ .cx = x + r,     .cy = y + h - r, .center = c_bl, .a0 = 0.5 * math.pi, .a1 = math.pi },
        };

        for (corners) |c| {
            const step = (c.a1 - c.a0) / @as(f32, @floatFromInt(n));
            var prev = b.v(c.cx + math.cos(c.a0) * r, c.cy + math.sin(c.a0) * r, col);
            for (1..n + 1) |si| {
                const angle = c.a0 + @as(f32, @floatFromInt(si)) * step;
                const cur = b.v(c.cx + math.cos(angle) * r, c.cy + math.sin(angle) * r, col);
                b.tri(c.center, prev, cur);
                prev = cur;
            }
        }
    }

    fn border(b: *Builder, x: f32, y: f32, w: f32, h: f32, bd: clay.BorderRenderData) void {
        const col = clayColor(bd.color);
        const min_r = @min(w, h) / 2.0;
        const tl_r = @min(bd.corner_radius.top_left, min_r);
        const tr_r = @min(bd.corner_radius.top_right, min_r);
        const bl_r = @min(bd.corner_radius.bottom_left, min_r);
        const br_r = @min(bd.corner_radius.bottom_right, min_r);

        if (bd.width.top > 0) {
            const tw: f32 = @floatFromInt(bd.width.top);
            b.rect(x + tl_r, y, w - tl_r - tr_r, tw, col);
        }
        if (bd.width.bottom > 0) {
            const bw: f32 = @floatFromInt(bd.width.bottom);
            b.rect(x + bl_r, y + h - bw, w - bl_r - br_r, bw, col);
        }
        if (bd.width.left > 0) {
            const lw: f32 = @floatFromInt(bd.width.left);
            b.rect(x, y + tl_r, lw, h - tl_r - bl_r, col);
        }
        if (bd.width.right > 0) {
            const rw: f32 = @floatFromInt(bd.width.right);
            b.rect(x + w - rw, y + tr_r, rw, h - tr_r - br_r, col);
        }

        if (tl_r > 0 and bd.width.top > 0)
            b.arcRing(x + tl_r, y + tl_r, tl_r - @as(f32, @floatFromInt(bd.width.top)), tl_r, math.pi, 1.5 * math.pi, col);
        if (tr_r > 0 and bd.width.top > 0)
            b.arcRing(x + w - tr_r, y + tr_r, tr_r - @as(f32, @floatFromInt(bd.width.top)), tr_r, 1.5 * math.pi, 2.0 * math.pi, col);
        if (br_r > 0 and bd.width.bottom > 0)
            b.arcRing(x + w - br_r, y + h - br_r, br_r - @as(f32, @floatFromInt(bd.width.bottom)), br_r, 0.0, 0.5 * math.pi, col);
        if (bl_r > 0 and bd.width.bottom > 0)
            b.arcRing(x + bl_r, y + h - bl_r, bl_r - @as(f32, @floatFromInt(bd.width.bottom)), bl_r, 0.5 * math.pi, math.pi, col);
    }

    fn arcRing(b: *Builder, cx: f32, cy: f32, inner_r: f32, outer_r: f32, a0: f32, a1: f32, col: [4]f32) void {
        if (outer_r <= 0) return;
        const n: u32 = @max(num_circle_segments, @as(u32, @intFromFloat(outer_r * 1.5)));
        const step = (a1 - a0) / @as(f32, @floatFromInt(n));
        const ri = @max(inner_r, 0.0);

        for (0..n) |si| {
            const ang1 = a0 + @as(f32, @floatFromInt(si)) * step;
            const ang2 = a0 + @as(f32, @floatFromInt(si + 1)) * step;
            const in1  = b.v(cx + math.cos(ang1) * ri,     cy + math.sin(ang1) * ri,     col);
            const out1 = b.v(cx + math.cos(ang1) * outer_r, cy + math.sin(ang1) * outer_r, col);
            const out2 = b.v(cx + math.cos(ang2) * outer_r, cy + math.sin(ang2) * outer_r, col);
            const in2  = b.v(cx + math.cos(ang2) * ri,     cy + math.sin(ang2) * ri,     col);
            b.quad(in1, out1, out2, in2);
        }
    }

    fn imageQuad(b: *Builder, x: f32, y: f32, w: f32, h: f32, info: image_mod.ImageInfo, tint: [4]f32, corner_r: f32) void {
        if (w <= 0 or h <= 0) return;
        const rx = if (w > 0) corner_r / w else 0;
        const ry = if (h > 0) corner_r / h else 0;
        const tl = b.v_round(x,     y,     info.u0, info.v0, 0, 0, rx, ry, tint);
        const tr = b.v_round(x + w, y,     info.u1, info.v0, 1, 0, rx, ry, tint);
        const br = b.v_round(x + w, y + h, info.u1, info.v1, 1, 1, rx, ry, tint);
        const bl = b.v_round(x,     y + h, info.u0, info.v1, 0, 1, rx, ry, tint);
        b.quad(tl, tr, br, bl);
    }

    fn text(b: *Builder, x: f32, y: f32, td: clay.TextRenderData, atlas: *font.FontAtlas) void {
        if (td.font_id >= atlas.fonts.items.len) return;

        const entry = &atlas.fonts.items[td.font_id];
        const scale = entry.tt.scaleForPixelHeight(@floatFromInt(td.font_size));
        const vm = entry.tt.verticalMetrics();
        const baseline_y = y + @as(f32, @floatFromInt(vm.ascent)) * scale;
        const col = clayColor(td.text_color);

        // Round baseline once so all glyphs in this run share the same integer row.
        // Rounding per-glyph causes adjacent letters to land on different pixel rows
        // Snap to the nearest PHYSICAL pixel boundary (not just clay units).
        // A clay unit at non-integer physical pixels (e.g. 101 * 1.5dpi = 151.5px) makes
        // each glyph round to a different physical row → letters appear at different heights.
        const total_scale = atlas.ui_scale * atlas.dpi_scale;
        const baseline_y_px = @round(baseline_y * total_scale) / total_scale;

        var pen_x = x;
        var prev_glyph: ?@import("TrueType").GlyphIndex = null;
        const chars = td.string_contents.chars[0..@intCast(td.string_contents.length)];
        var i: usize = 0;

        while (i < chars.len) {
            const seq = std.unicode.utf8ByteSequenceLength(chars[i]) catch { i += 1; continue; };
            if (i + seq > chars.len) break;
            const cp = std.unicode.utf8Decode(chars[i .. i + seq]) catch 0xFFFD;
            i += seq;

            const g = entry.tt.codepointGlyphIndex(cp);
            if (prev_glyph) |pg|
                pen_x += @as(f32, @floatFromInt(entry.tt.glyphKernAdvance(pg, g))) * scale;

            const info = atlas.getGlyph(td.font_id, td.font_size, cp) catch {
                pen_x += @as(f32, @floatFromInt(entry.tt.glyphHMetrics(g).advance_width)) * scale;
                prev_glyph = g;
                continue;
            };

            if (info.width > 0 and info.height > 0) {
                const gx = @round((pen_x + info.off_x) * total_scale) / total_scale;
                const gy = baseline_y_px + info.off_y;
                const gw = info.width;
                const gh = info.height;
                const tl = b.v_uv(gx,      gy,      info.u0, info.v0, col);
                const tr = b.v_uv(gx + gw, gy,      info.u1, info.v0, col);
                const br = b.v_uv(gx + gw, gy + gh, info.u1, info.v1, col);
                const bl = b.v_uv(gx,      gy + gh, info.u0, info.v1, col);
                b.quad(tl, tr, br, bl);
            }

            pen_x += info.advance;
            prev_glyph = g;
        }
    }
};
