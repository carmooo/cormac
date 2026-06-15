const std = @import("std");
const Epub = @import("Epub.zig");
const xml = @import("xml");

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
    const open = try epub.open(3, allocator);
    std.debug.print("{s}\n", .{open[0..1000]});

    var chapter: xml = .{ .buffer = open };

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const c = try chapter.nextContent();
        switch (c) {
            .content => |text| {
                std.debug.print("{s}\n", .{text});
            },
            else => unreachable,
        }
    }
}
