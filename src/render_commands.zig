const std = @import("std");
const clay = @import("zclay");
const font = @import("font.zig");
const image_mod = @import("image.zig");
const c_elem = @import("custom_element.zig");
const zvec = @import("zvec");
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

pub const Pipeline = enum { geom, text, image, vec };

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
    alloc: std.mem.Allocator,
    cmds: []const clay.RenderCommand,
    verts: []Vertex,
    idxs: []u32,
    draw_calls: []DrawCall,
    font_atlas: *font.FontAtlas,
    image_atlas: *image_mod.ImageAtlas,
) BuildResult {
    var b = Builder{ .verts = verts, .idxs = idxs, .dcs = draw_calls, .alloc = alloc };
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
            .custom => {
                const raw = cmd.render_data.custom.custom_data orelse continue;
                const elem: *c_elem.CustomElementData = @ptrCast(@alignCast(raw));
                switch (elem.*) {
                    .vector_graphic => |*vg| {
                        b.ensureMode(.vec);
                        b.vectorGraphic(bb.x, bb.y, bb.width, bb.height, vg);
                    },
                }
            },
            else => {},
        }
    }

    b.flush();
    return .{ .vertex_count = b.vc, .index_count = b.ic, .draw_call_count = b.dc, .overflowed = b.overflowed };
}

// Compose two affine transforms: result = outer ∘ inner (inner applied first).
// Each transform is [a, b, c, d, e, f] where x' = a*x + c*y + e, y' = b*x + d*y + f.
fn composeTransforms(outer: [6]f32, inner: [6]f32) [6]f32 {
    return .{
        outer[0] * inner[0] + outer[2] * inner[1],
        outer[1] * inner[0] + outer[3] * inner[1],
        outer[0] * inner[2] + outer[2] * inner[3],
        outer[1] * inner[2] + outer[3] * inner[3],
        outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
        outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    };
}

fn pointInTri(p: zvec.Point, a: zvec.Point, pb: zvec.Point, c: zvec.Point) bool {
    const d1 = (p.x - pb.x) * (a.y - pb.y) - (a.x - pb.x) * (p.y - pb.y);
    const d2 = (p.x - c.x) * (pb.y - c.y) - (pb.x - c.x) * (p.y - c.y);
    const d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y);
    const has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0);
    const has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0);
    return !(has_neg and has_pos);
}

fn clayColor(c: clay.Color) [4]f32 {
    return .{ c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, c[3] / 255.0 };
}

const Builder = struct {
    verts: []Vertex,
    idxs: []u32,
    dcs: []DrawCall,
    alloc: std.mem.Allocator,
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
        if (b.vc >= b.verts.len) {
            b.overflowed = true;
            return 0;
        }
        const i = b.vc;
        b.verts[i] = .{ .pos = .{ x, y }, .color = col, .uv = .{ u, vv }, .round = .{ 0, 0, 0, 0 } };
        b.vc += 1;
        return i;
    }

    fn v_round(b: *Builder, x: f32, y: f32, atlas_u: f32, atlas_v: f32, local_u: f32, local_v: f32, rx: f32, ry: f32, col: [4]f32) u32 {
        if (b.vc >= b.verts.len) {
            b.overflowed = true;
            return 0;
        }
        const i = b.vc;
        b.verts[i] = .{ .pos = .{ x, y }, .color = col, .uv = .{ atlas_u, atlas_v }, .round = .{ local_u, local_v, rx, ry } };
        b.vc += 1;
        return i;
    }

    fn tri(b: *Builder, a: u32, c0: u32, c1: u32) void {
        if (b.ic + 3 > b.idxs.len) {
            b.overflowed = true;
            return;
        }
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
        const tl = b.v(x, y, col);
        const tr = b.v(x + w, y, col);
        const br = b.v(x + w, y + h, col);
        const bl = b.v(x, y + h, col);
        b.quad(tl, tr, br, bl);
    }

    fn roundedRect(b: *Builder, x: f32, y: f32, w: f32, h: f32, corner_radius: f32, col: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const r = @min(corner_radius, @min(w, h) / 2.0);
        const n: u32 = @max(num_circle_segments, @as(u32, @intFromFloat(r * 0.5)));

        const c_tl = b.v(x + r, y + r, col);
        const c_tr = b.v(x + w - r, y + r, col);
        const c_br = b.v(x + w - r, y + h - r, col);
        const c_bl = b.v(x + r, y + h - r, col);
        b.quad(c_tl, c_tr, c_br, c_bl);

        b.quad(b.v(x + r, y, col), b.v(x + w - r, y, col), c_tr, c_tl);
        b.quad(c_bl, c_br, b.v(x + w - r, y + h, col), b.v(x + r, y + h, col));
        b.quad(b.v(x, y + r, col), c_tl, c_bl, b.v(x, y + h - r, col));
        b.quad(c_tr, b.v(x + w, y + r, col), b.v(x + w, y + h - r, col), c_br);

        const corners = [4]struct { cx: f32, cy: f32, center: u32, a0: f32, a1: f32 }{
            .{ .cx = x + r, .cy = y + r, .center = c_tl, .a0 = math.pi, .a1 = 1.5 * math.pi },
            .{ .cx = x + w - r, .cy = y + r, .center = c_tr, .a0 = 1.5 * math.pi, .a1 = 2.0 * math.pi },
            .{ .cx = x + w - r, .cy = y + h - r, .center = c_br, .a0 = 0.0, .a1 = 0.5 * math.pi },
            .{ .cx = x + r, .cy = y + h - r, .center = c_bl, .a0 = 0.5 * math.pi, .a1 = math.pi },
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
            const in1 = b.v(cx + math.cos(ang1) * ri, cy + math.sin(ang1) * ri, col);
            const out1 = b.v(cx + math.cos(ang1) * outer_r, cy + math.sin(ang1) * outer_r, col);
            const out2 = b.v(cx + math.cos(ang2) * outer_r, cy + math.sin(ang2) * outer_r, col);
            const in2 = b.v(cx + math.cos(ang2) * ri, cy + math.sin(ang2) * ri, col);
            b.quad(in1, out1, out2, in2);
        }
    }

    fn imageQuad(b: *Builder, x: f32, y: f32, w: f32, h: f32, info: image_mod.ImageInfo, tint: [4]f32, corner_r: f32) void {
        if (w <= 0 or h <= 0) return;
        const rx = if (w > 0) corner_r / w else 0;
        const ry = if (h > 0) corner_r / h else 0;
        const tl = b.v_round(x, y, info.u0, info.v0, 0, 0, rx, ry, tint);
        const tr = b.v_round(x + w, y, info.u1, info.v0, 1, 0, rx, ry, tint);
        const br = b.v_round(x + w, y + h, info.u1, info.v1, 1, 1, rx, ry, tint);
        const bl = b.v_round(x, y + h, info.u0, info.v1, 0, 1, rx, ry, tint);
        b.quad(tl, tr, br, bl);
    }

    fn vectorGraphic(b: *Builder, bx: f32, by: f32, bw: f32, bh: f32, vg: *const zvec.VecGraphic) void {
        if (vg.width <= 0 or vg.height <= 0) return;
        const sx = bw / vg.width;
        const sy = bh / vg.height;
        const base_xform = [6]f32{ sx, 0, 0, sy, bx, by };

        // Reuse across commands to avoid repeated alloc/free.
        // We use flattenPath (not flattenAlloc) because flattenAlloc calls
        // toOwnedSlice() which can reallocate the points buffer, leaving the
        // Contour.points sub-slices dangling.
        var pts: std.ArrayList(zvec.Point) = .empty;
        defer pts.deinit(b.alloc);
        var ctrs: std.ArrayList(zvec.Flatten.Contour) = .empty;
        defer ctrs.deinit(b.alloc);

        for (vg.commands) |cmd| {
            pts.clearRetainingCapacity();
            ctrs.clearRetainingCapacity();

            const xform = if (cmd.transform) |t| composeTransforms(base_xform, t) else base_xform;
            zvec.Flatten.flattenPath(b.alloc, cmd.path, .{ .transform = xform }, &pts, &ctrs) catch continue;

            if (cmd.fill) |fill| {
                const col = [4]f32{
                    fill.paint.solid[0],
                    fill.paint.solid[1],
                    fill.paint.solid[2],
                    fill.paint.solid[3] * fill.opacity,
                };
                for (ctrs.items) |contour| {
                    if (contour.points.len < 3) continue;
                    b.fillContour(contour.points, col);
                }
            }

            if (cmd.stroke) |stroke| {
                const col = [4]f32{
                    stroke.paint.solid[0],
                    stroke.paint.solid[1],
                    stroke.paint.solid[2],
                    stroke.paint.solid[3] * stroke.opacity,
                };
                const hw = stroke.width * @sqrt(sx * sy) * 0.5;
                for (ctrs.items) |contour| {
                    b.strokeContour(contour.points, contour.closed, hw, col);
                }
            }
        }
    }

    fn fillContour(b: *Builder, pts: []const zvec.Point, col: [4]f32) void {
        const n = pts.len;
        if (n < 3) return;

        const base = b.vc;
        for (pts) |p| _ = b.v(p.x, p.y, col);

        if (n == 3) {
            b.tri(base, base + 1, base + 2);
            return;
        }

        // Shoelace area; CCW = positive (Y-down screen space → CCW = negative area, but
        // we just track the sign consistently and use it for the winding-aware ear test).
        var area: f32 = 0;
        for (0..n) |i| {
            const j = (i + 1) % n;
            area += pts[i].x * pts[j].y - pts[j].x * pts[i].y;
        }
        const ccw = area >= 0;

        const active = b.alloc.alloc(u32, n) catch return;
        defer b.alloc.free(active);
        for (0..n) |i| active[i] = @intCast(i);
        var m = n;

        var iter: usize = 0;
        var fails: usize = 0;
        while (m > 3 and fails < m) {
            const pi = (iter + m - 1) % m;
            const ci = iter % m;
            const ni = (iter + 1) % m;

            const pv = pts[active[pi]];
            const cv = pts[active[ci]];
            const nv = pts[active[ni]];

            // Convexity check: cross product of (pv→cv) × (cv→nv)
            const cross = (cv.x - pv.x) * (nv.y - cv.y) - (cv.y - pv.y) * (nv.x - cv.x);
            const convex = if (ccw) cross >= 0 else cross <= 0;

            if (convex) {
                var ear = true;
                for (0..m) |k| {
                    if (k == pi or k == ci or k == ni) continue;
                    if (pointInTri(pts[active[k]], pv, cv, nv)) {
                        ear = false;
                        break;
                    }
                }

                if (ear) {
                    if (ccw) {
                        b.tri(base + active[pi], base + active[ci], base + active[ni]);
                    } else {
                        b.tri(base + active[pi], base + active[ni], base + active[ci]);
                    }
                    var k = ci;
                    while (k < m - 1) : (k += 1) active[k] = active[k + 1];
                    m -= 1;
                    iter = if (ci >= m) 0 else ci;
                    fails = 0;
                    continue;
                }
            }

            iter = (iter + 1) % m;
            fails += 1;
        }

        if (m == 3) {
            if (ccw) {
                b.tri(base + active[0], base + active[1], base + active[2]);
            } else {
                b.tri(base + active[0], base + active[2], base + active[1]);
            }
        }
    }

    fn strokeContour(b: *Builder, pts: []const zvec.Point, closed: bool, hw: f32, col: [4]f32) void {
        if (pts.len < 2 or hw <= 0) return;
        const n = pts.len;
        const seg_count = if (closed) n else n - 1;
        const max_miter = hw * 4.0;

        const segNorm = struct {
            fn f(p0: zvec.Point, p1: zvec.Point) [2]f32 {
                const dx = p1.x - p0.x;
                const dy = p1.y - p0.y;
                const d = @sqrt(dx * dx + dy * dy);
                if (d < 1e-6) return .{ 0.0, 0.0 };
                return .{ -dy / d, dx / d };
            }
        }.f;

        // Compute miter offset at a vertex shared between two segments whose
        // unit normals are `na` (incoming) and `nb` (outgoing).
        // m = (na + nb) * hw / (1 + dot(na, nb)), capped at max_miter.
        const miterOff = struct {
            fn f(na: [2]f32, nb: [2]f32, hw_: f32, max_: f32) [2]f32 {
                const dot = na[0] * nb[0] + na[1] * nb[1];
                const denom = @max(1.0 + dot, 0.05);
                const mx = (na[0] + nb[0]) * hw_ / denom;
                const my = (na[1] + nb[1]) * hw_ / denom;
                const ml = @sqrt(mx * mx + my * my);
                if (ml > max_) {
                    const s = max_ / ml;
                    return .{ mx * s, my * s };
                }
                return .{ mx, my };
            }
        }.f;

        for (0..seg_count) |si| {
            const vi0 = si;
            const vi1 = (si + 1) % n;
            const cur_n = segNorm(pts[vi0], pts[vi1]);
            if (cur_n[0] == 0.0 and cur_n[1] == 0.0) continue;

            const off0: [2]f32 = if (!closed and si == 0) .{ cur_n[0] * hw, cur_n[1] * hw } else blk: {
                const prev_n = segNorm(pts[if (si == 0) n - 1 else si - 1], pts[vi0]);
                if (prev_n[0] == 0.0 and prev_n[1] == 0.0) break :blk .{ cur_n[0] * hw, cur_n[1] * hw };
                break :blk miterOff(prev_n, cur_n, hw, max_miter);
            };

            const off1: [2]f32 = if (!closed and si == seg_count - 1) .{ cur_n[0] * hw, cur_n[1] * hw } else blk: {
                const next_n = segNorm(pts[vi1], pts[(vi1 + 1) % n]);
                if (next_n[0] == 0.0 and next_n[1] == 0.0) break :blk .{ cur_n[0] * hw, cur_n[1] * hw };
                break :blk miterOff(cur_n, next_n, hw, max_miter);
            };

            const tl = b.v(pts[vi0].x + off0[0], pts[vi0].y + off0[1], col);
            const bl = b.v(pts[vi0].x - off0[0], pts[vi0].y - off0[1], col);
            const tr = b.v(pts[vi1].x + off1[0], pts[vi1].y + off1[1], col);
            const br = b.v(pts[vi1].x - off1[0], pts[vi1].y - off1[1], col);
            b.quad(tl, tr, br, bl);
        }
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
            const seq = std.unicode.utf8ByteSequenceLength(chars[i]) catch {
                i += 1;
                continue;
            };
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
                const tl = b.v_uv(gx, gy, info.u0, info.v0, col);
                const tr = b.v_uv(gx + gw, gy, info.u1, info.v0, col);
                const br = b.v_uv(gx + gw, gy + gh, info.u1, info.v1, col);
                const bl = b.v_uv(gx, gy + gh, info.u0, info.v1, col);
                b.quad(tl, tr, br, bl);
            }

            pen_x += info.advance;
            prev_glyph = g;
        }
    }
};
