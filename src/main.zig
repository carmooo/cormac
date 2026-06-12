const std = @import("std");
const Epub = @import("Epub.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const file = try std.Io.Dir.cwd().openFile(io, "testdata/pg215-images-3.epub", .{});
    defer file.close(io);
    // TODO review buffer size
    var reader_buffer: [512]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var epub = try Epub.init(&reader, allocator);
    defer epub.deinit(allocator);
    std.debug.print("{any}", .{epub.metadata});
    std.debug.print("{any}", .{epub.manifest.items.len});
    std.debug.print("{any}", .{epub.spine.items.len});
}
