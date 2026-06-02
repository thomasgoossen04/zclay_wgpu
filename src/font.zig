const std = @import("std");
const TrueType = @import("TrueType");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const clay = @import("zclay");

pub const atlas_size: u32 = 1024;
const glyph_padding: u32 = 1;

pub const GlyphInfo = struct {
    u0: f32, v0: f32, u1: f32, v1: f32,
    off_x: f32, off_y: f32,
    width: f32, height: f32,
    advance: f32,
};

const GlyphKey = struct {
    font_id: u16,
    font_size: u16,
    codepoint: u21,
};

const FontEntry = struct {
    data: []u8,
    tt: TrueType,
};

pub const FontAtlas = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    dpi_scale: f32,
    ui_scale: f32,
    fonts: std.ArrayListUnmanaged(FontEntry),
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, GlyphInfo),
    pixels: []u8,
    cursor_x: u32,
    cursor_y: u32,
    row_height: u32,
    texture: zgpu.TextureHandle,
    texture_view: zgpu.TextureViewHandle,
    sampler: zgpu.SamplerHandle,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, dpi_scale: f32) !FontAtlas {
        const pixels = try allocator.alloc(u8, atlas_size * atlas_size);
        @memset(pixels, 0);

        const texture = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = atlas_size, .height = atlas_size, .depth_or_array_layers = 1 },
            .format = .r8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const texture_view = gctx.createTextureView(texture, .{});
        const sampler = gctx.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .dpi_scale = @max(1.0, dpi_scale),
            .ui_scale = 1.0,
            .fonts = .empty,
            .glyphs = .empty,
            .pixels = pixels,
            .cursor_x = glyph_padding,
            .cursor_y = glyph_padding,
            .row_height = 0,
            .texture = texture,
            .texture_view = texture_view,
            .sampler = sampler,
            .dirty = true, // upload zeros on first frame
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        for (self.fonts.items) |entry| self.allocator.free(entry.data);
        self.fonts.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.allocator.free(self.pixels);
    }

    pub fn addFont(self: *FontAtlas, data: []const u8) !u16 {
        const owned = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(owned);
        const tt = try TrueType.load(owned);
        const id: u16 = @intCast(self.fonts.items.len);
        try self.fonts.append(self.allocator, .{ .data = owned, .tt = tt });
        return id;
    }

    pub fn getGlyph(self: *FontAtlas, font_id: u16, font_size: u16, codepoint: u21) !GlyphInfo {
        const key = GlyphKey{ .font_id = font_id, .font_size = font_size, .codepoint = codepoint };
        if (self.glyphs.get(key)) |info| return info;
        return self.rasterizeGlyph(key);
    }

    fn rasterizeGlyph(self: *FontAtlas, key: GlyphKey) !GlyphInfo {
        const entry = &self.fonts.items[key.font_id];
        // font_size is in clay units. Clay's coordinate space is already divided by
        // ui_scale, so 1 clay unit = ui_scale * dpi_scale physical pixels.
        // Metrics (advance, offsets) stay in clay units — no ui_scale multiplier.
        // The bitmap is rasterized at full physical resolution for sharpness.
        const font_size_f: f32 = @floatFromInt(key.font_size);
        const log_scale   = entry.tt.scaleForPixelHeight(font_size_f);
        const phys_scale  = entry.tt.scaleForPixelHeight(font_size_f * self.ui_scale * self.dpi_scale);
        const glyph = entry.tt.codepointGlyphIndex(key.codepoint);
        const hm = entry.tt.glyphHMetrics(glyph);
        const advance: f32 = @as(f32, @floatFromInt(hm.advance_width)) * log_scale;

        var bitmap_pixels: std.ArrayListUnmanaged(u8) = .empty;
        defer bitmap_pixels.deinit(self.allocator);

        const bm = try entry.tt.glyphBitmap(self.allocator, &bitmap_pixels, glyph, phys_scale, phys_scale);
        const w: u32 = bm.width;
        const h: u32 = bm.height;

        // Empty glyph (space, etc.)
        if (w == 0 or h == 0) {
            const info = GlyphInfo{ .u0=0,.v0=0,.u1=0,.v1=0,.off_x=0,.off_y=0,.width=0,.height=0,.advance=advance };
            try self.glyphs.put(self.allocator, key, info);
            return info;
        }

        // Advance to next row if needed
        if (self.cursor_x + w + glyph_padding > atlas_size) {
            self.cursor_y += self.row_height + glyph_padding;
            self.cursor_x = glyph_padding;
            self.row_height = 0;
        }

        // Atlas full: skip rendering but record advance
        if (self.cursor_y + h + glyph_padding > atlas_size) {
            std.log.warn("[font] atlas full, glyph U+{X} skipped", .{@as(u32, key.codepoint)});
            const info = GlyphInfo{ .u0=0,.v0=0,.u1=0,.v1=0,.off_x=0,.off_y=0,.width=0,.height=0,.advance=advance };
            try self.glyphs.put(self.allocator, key, info);
            return info;
        }

        // Copy bitmap rows into atlas
        for (0..h) |row| {
            const dst_start = (self.cursor_y + row) * atlas_size + self.cursor_x;
            const src_start = row * w;
            @memcpy(self.pixels[dst_start..][0..w], bitmap_pixels.items[src_start..][0..w]);
        }

        const inv = 1.0 / @as(f32, atlas_size);
        const info = GlyphInfo{
            .u0 = @as(f32, @floatFromInt(self.cursor_x)) * inv,
            .v0 = @as(f32, @floatFromInt(self.cursor_y)) * inv,
            .u1 = @as(f32, @floatFromInt(self.cursor_x + w)) * inv,
            .v1 = @as(f32, @floatFromInt(self.cursor_y + h)) * inv,
            // off/size in logical pixels so clay positions are correct
            // Convert physical pixels → clay units (physical = clay * ui_scale * dpi_scale)
            .off_x  = @as(f32, @floatFromInt(bm.off_x)) / (self.ui_scale * self.dpi_scale),
            .off_y  = @as(f32, @floatFromInt(bm.off_y)) / (self.ui_scale * self.dpi_scale),
            .width  = @as(f32, @floatFromInt(w))         / (self.ui_scale * self.dpi_scale),
            .height = @as(f32, @floatFromInt(h))         / (self.ui_scale * self.dpi_scale),
            .advance = advance,
        };

        self.cursor_x += w + glyph_padding;
        if (h > self.row_height) self.row_height = h;
        self.dirty = true;

        try self.glyphs.put(self.allocator, key, info);
        return info;
    }

    fn invalidateCache(self: *FontAtlas) void {
        self.glyphs.clearRetainingCapacity();
        self.cursor_x = glyph_padding;
        self.cursor_y = glyph_padding;
        self.row_height = 0;
        @memset(self.pixels, 0);
        self.dirty = true;
    }

    /// Call each frame with the current monitor's DPI scale.
    pub fn updateDpiScale(self: *FontAtlas, new_scale: f32) bool {
        const clamped = @max(1.0, new_scale);
        if (@abs(clamped - self.dpi_scale) < 0.01) return false;
        self.dpi_scale = clamped;
        self.invalidateCache();
        return true;
    }

    /// Set a global UI scale multiplier applied on top of font_size values.
    /// 1.0 = no scaling, 1.5 = 50% larger, 2.0 = double, etc.
    pub fn setUiScale(self: *FontAtlas, scale: f32) void {
        const clamped = @max(0.25, scale);
        if (@abs(clamped - self.ui_scale) < 0.001) return;
        self.ui_scale = clamped;
        self.invalidateCache();
    }

    pub fn flush(self: *FontAtlas) void {
        if (!self.dirty) return;
        const tex = self.gctx.lookupResource(self.texture).?;
        self.gctx.queue.writeTexture(
            .{ .texture = tex },
            .{ .bytes_per_row = atlas_size, .rows_per_image = atlas_size },
            .{ .width = atlas_size, .height = atlas_size, .depth_or_array_layers = 1 },
            u8,
            self.pixels,
        );
        self.dirty = false;
    }
};

pub fn measureTextFn(text: []const u8, config: *clay.TextElementConfig, atlas: *FontAtlas) clay.Dimensions {
    if (atlas.fonts.items.len == 0 or config.font_id >= atlas.fonts.items.len) {
        return .{
            .w = @as(f32, @floatFromInt(text.len)) * @as(f32, @floatFromInt(config.font_size)) * 0.6,
            .h = @floatFromInt(config.font_size),
        };
    }
    const entry = &atlas.fonts.items[config.font_id];
    const scale = entry.tt.scaleForPixelHeight(@floatFromInt(config.font_size));
    const vm = entry.tt.verticalMetrics();
    const line_h: f32 = @as(f32, @floatFromInt(vm.ascent - vm.descent + vm.line_gap)) * scale;

    var width: f32 = 0;
    var prev: ?TrueType.GlyphIndex = null;
    var i: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch { i += 1; continue; };
        if (i + seq > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq]) catch 0xFFFD;
        i += seq;
        const g = entry.tt.codepointGlyphIndex(cp);
        if (prev) |pg| width += @as(f32, @floatFromInt(entry.tt.glyphKernAdvance(pg, g))) * scale;
        width += @as(f32, @floatFromInt(entry.tt.glyphHMetrics(g).advance_width)) * scale;
        prev = g;
    }
    return .{ .w = width, .h = line_h };
}
