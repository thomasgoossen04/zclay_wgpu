pub const Window = @import("window.zig").Window;
pub const Renderer = @import("renderer.zig").Renderer;
pub const clay = @import("zclay");
pub const Key = @import("zglfw").Key;

const std = @import("std");

pub const ClayManager = struct {
    alloc: std.mem.Allocator,
    memory: []u8,

    pub fn init(alloc: std.mem.Allocator, window: Window, renderer: Renderer) !ClayManager {
        const min_mem_size: u32 = clay.minMemorySize();
        const n_memory = try alloc.alloc(u8, min_mem_size);
        const arena: clay.Arena = .init(n_memory);
        _ = clay.initialize(arena, .{
            .w = window.init_w,
            .h = window.init_h,
        }, .{});
        clay.setMeasureTextFunction({}, renderer.measureText);
        return .{
            .alloc = alloc,
            .memory = n_memory,
        };
    }

    pub fn deinit(self: ClayManager) void {
        self.alloc.free(self.memory);
    }
};
