const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const atlas_size: u32 = 2048;
const img_padding: u32 = 1;

pub const ImageInfo = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const ImageAtlas = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    images: std.ArrayListUnmanaged(ImageInfo),
    pixels: []u8,
    cursor_x: u32,
    cursor_y: u32,
    row_height: u32,
    texture: zgpu.TextureHandle,
    texture_view: zgpu.TextureViewHandle,
    sampler: zgpu.SamplerHandle,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) !ImageAtlas {
        const pixels = try allocator.alloc(u8, atlas_size * atlas_size * 4);
        @memset(pixels, 0);

        const texture = gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_2d,
            .size = .{ .width = atlas_size, .height = atlas_size, .depth_or_array_layers = 1 },
            .format = .rgba8_unorm,
            .mip_level_count = 1,
            .sample_count = 1,
        });
        const texture_view = gctx.createTextureView(texture, .{});
        const sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .images = .empty,
            .pixels = pixels,
            .cursor_x = img_padding,
            .cursor_y = img_padding,
            .row_height = 0,
            .texture = texture,
            .texture_view = texture_view,
            .sampler = sampler,
            .dirty = true,
        };
    }

    pub fn deinit(self: *ImageAtlas) void {
        self.images.deinit(self.allocator);
        self.allocator.free(self.pixels);
    }

    pub fn addImage(self: *ImageAtlas, png_data: []const u8) !u32 {
        var decoded = try decodePng(self.allocator, png_data);
        defer decoded.pixels.deinit(self.allocator);

        const w = decoded.width;
        const h = decoded.height;

        if (self.cursor_x + w + img_padding > atlas_size) {
            self.cursor_y += self.row_height + img_padding;
            self.cursor_x = img_padding;
            self.row_height = 0;
        }

        if (self.cursor_y + h + img_padding > atlas_size) return error.ImageAtlasFull;

        for (0..h) |row| {
            const dst_start = ((self.cursor_y + @as(u32, @intCast(row))) * atlas_size + self.cursor_x) * 4;
            const src_start = row * w * 4;
            @memcpy(self.pixels[dst_start..][0 .. w * 4], decoded.pixels.items[src_start..][0 .. w * 4]);
        }

        const inv = 1.0 / @as(f32, @floatFromInt(atlas_size));
        const info = ImageInfo{
            .u0 = @as(f32, @floatFromInt(self.cursor_x)) * inv,
            .v0 = @as(f32, @floatFromInt(self.cursor_y)) * inv,
            .u1 = @as(f32, @floatFromInt(self.cursor_x + w)) * inv,
            .v1 = @as(f32, @floatFromInt(self.cursor_y + h)) * inv,
        };

        self.cursor_x += w + img_padding;
        if (h > self.row_height) self.row_height = h;
        self.dirty = true;

        const id: u32 = @intCast(self.images.items.len);
        try self.images.append(self.allocator, info);
        return id;
    }

    pub fn flush(self: *ImageAtlas) void {
        if (!self.dirty) return;
        const tex = self.gctx.lookupResource(self.texture).?;
        self.gctx.queue.writeTexture(
            .{ .texture = tex },
            .{ .bytes_per_row = atlas_size * 4, .rows_per_image = atlas_size },
            .{ .width = atlas_size, .height = atlas_size, .depth_or_array_layers = 1 },
            u8,
            self.pixels,
        );
        self.dirty = false;
    }
};

const DecodedPng = struct {
    pixels: std.ArrayListUnmanaged(u8),
    width: u32,
    height: u32,
};

fn decodePng(allocator: std.mem.Allocator, data: []const u8) !DecodedPng {
    const png_sig = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &png_sig)) return error.InvalidPng;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    while (pos + 12 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 .. pos + 8];
        if (pos + 12 + chunk_len > data.len) return error.InvalidPng;
        const chunk_data = data[pos + 8 ..][0..chunk_len];
        pos += 12 + chunk_len;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len < 13) return error.InvalidPng;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
            if (chunk_data[12] != 0) return error.PngInterlaceNotSupported;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    if (width == 0 or height == 0) return error.InvalidPng;
    if (bit_depth != 8) return error.PngUnsupportedBitDepth;

    const bpp: u32 = switch (color_type) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return error.PngUnsupportedColorType,
    };

    const stride = 1 + width * bpp;
    const raw_size = height * stride;
    const raw = try allocator.alloc(u8, raw_size);
    defer allocator.free(raw);

    {
        var reader = std.Io.Reader.fixed(idat.items);
        var decomp: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
        var writer = std.Io.Writer.fixed(raw);
        _ = decomp.reader.streamRemaining(&writer) catch return error.PngDecompressError;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.resize(allocator, width * height * 4);

    const prev_buf = try allocator.alloc(u8, width * bpp);
    defer allocator.free(prev_buf);
    @memset(prev_buf, 0);
    const curr_buf = try allocator.alloc(u8, width * bpp);
    defer allocator.free(curr_buf);

    for (0..height) |row| {
        const src = raw[row * stride ..][0..stride];
        const filter = src[0];
        const filtered = src[1..];
        const dst = out.items[row * width * 4 ..][0 .. width * 4];

        for (0..width * bpp) |i| {
            const x = filtered[i];
            const a: u8 = if (i >= bpp) curr_buf[i - bpp] else 0;
            const b: u8 = prev_buf[i];
            const c: u8 = if (i >= bpp) prev_buf[i - bpp] else 0;
            curr_buf[i] = switch (filter) {
                0 => x,
                1 => x +% a,
                2 => x +% b,
                3 => x +% @as(u8, @truncate((@as(u16, a) + @as(u16, b)) >> 1)),
                4 => x +% paethPredictor(a, b, c),
                else => return error.PngInvalidFilter,
            };
        }

        for (0..width) |px| {
            const rgba: [4]u8 = switch (color_type) {
                0 => .{ curr_buf[px], curr_buf[px], curr_buf[px], 255 },
                2 => .{ curr_buf[px * 3], curr_buf[px * 3 + 1], curr_buf[px * 3 + 2], 255 },
                4 => .{ curr_buf[px * 2], curr_buf[px * 2], curr_buf[px * 2], curr_buf[px * 2 + 1] },
                6 => .{ curr_buf[px * 4], curr_buf[px * 4 + 1], curr_buf[px * 4 + 2], curr_buf[px * 4 + 3] },
                else => unreachable,
            };
            dst[px * 4 ..][0..4].* = rgba;
        }

        @memcpy(prev_buf, curr_buf);
    }

    return .{ .pixels = out, .width = width, .height = height };
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const A: i32 = a;
    const B: i32 = b;
    const C: i32 = c;
    const p = A + B - C;
    const pa: i32 = @intCast(@abs(p - A));
    const pb: i32 = @intCast(@abs(p - B));
    const pc: i32 = @intCast(@abs(p - C));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}
