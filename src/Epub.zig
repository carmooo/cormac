const Epub = @This();

const std = @import("std");

reader: *std.Io.File.Reader,
foo: u1 = 1,

// TODO remove
pub fn tmp(e: Epub) u1 {
    return e.foo;
}

const container_filename = "META-INF/container.xml";
const mime_filename = "mimetype";
const mime_type = "application/epub+zip";

pub const EpubError = error{
    EpubHasNoFiles,
    EpubFirstFileIsNotMimetype,
    EpubDoesNotHaveContainerXMLFile,
    EpubWrongFormat,
    EpubFileNotFound,
};

pub fn open(reader: *std.Io.File.Reader, allocator: std.mem.Allocator) !Epub {
    var iter = try std.zip.Iterator.init(reader);
    const first = try iter.next() orelse return EpubError.EpubHasNoFiles;

    // first file must be mimetype
    const first_filename = try getFilenameFromEntry(reader, first, allocator);
    if (!std.mem.eql(u8, first_filename, mime_filename)) return EpubError.EpubFirstFileIsNotMimetype;

    // mime type must be application/epub+zip
    const first_content = try decompressEntryToMemory(reader, first, allocator);
    if (!std.mem.eql(u8, first_content, mime_type)) return EpubError.EpubWrongFormat;

    // next we are finding the container file
    const container_entry = try getEntryByFilename(reader, container_filename, allocator);

    // get the content of the container file
    const container_content = try decompressEntryToMemory(reader, container_entry, allocator);

    // get opf filename. no need to parse xml. this is faster
    const needle = "full-path=\"";
    var opf_path: []u8 = undefined;
    if (std.mem.indexOf(u8, container_content, needle)) |start| {
        const path_start = start + needle.len;
        if (std.mem.indexOfScalar(u8, container_content[path_start..], '"')) |end| {
            opf_path = container_content[path_start .. path_start + end];
            // opf_path is e.g. "OEBPS/content.opf"
        }
    }

    // Open .../content.opf file and parse
    const content_entry = try getEntryByFilename(reader, opf_path, allocator);
    const content_content = try decompressEntryToMemory(reader, content_entry, allocator);

    std.debug.print("{s}", .{content_content});

    return Epub{ .reader = reader };
}

fn getFilenameFromEntry(reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, entry.filename_len);
    try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try reader.interface.readSliceAll(buffer);
    return buffer;
}

fn decompressEntryToMemory(reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, allocator: std.mem.Allocator) ![]u8 {
    try reader.seekTo(entry.file_offset);
    const local_header = try reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
    try reader.seekBy(local_header.filename_len + local_header.extra_len);

    const buffer = try allocator.alloc(u8, entry.uncompressed_size);
    switch (entry.compression_method) {
        .store => {
            try reader.interface.readSliceAll(buffer);
        },
        .deflate => {
            _ = try reader.interface.peek(1);
            var decompress = std.compress.flate.Decompress.init(&reader.interface, .raw, &.{});
            var writer = std.Io.Writer.fixed(buffer);
            _ = try decompress.reader.streamRemaining(&writer);
        },
        else => {},
    }
    return buffer;
}

fn getEntryByFilename(reader: *std.Io.File.Reader, filename: []const u8, allocator: std.mem.Allocator) !std.zip.Iterator.Entry {
    var iterator = try std.zip.Iterator.init(reader);
    while (try iterator.next()) |entry| {
        const entry_name = try getFilenameFromEntry(reader, entry, allocator);
        if (std.mem.eql(u8, filename, entry_name)) return entry;
    }
    return EpubError.EpubFileNotFound;
}
