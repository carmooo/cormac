const Epub = @This();

const std = @import("std");
const xml = @import("xml");

reader: *std.Io.File.Reader,
metadata: Metadata,

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

pub const Metadata = struct {
    title: []const u8,
    language: []const u8,
    identifier: []const u8,
    creator: ?[]const u8 = null,
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
    var content_xml: xml = .{ .buffer = content_content };

    // get metadata
    var title: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var identifier: ?[]const u8 = null;
    var creator: ?[]const u8 = null;
    while (true) {
        const token = content_xml.next() catch |err| switch (err) {
            error.BufferUnderrun => break,
            else => return err,
        };
        switch (token) {
            .tag_open => |tag_open_name| {
                // std.debug.print("{s}\n", .{tag_name});
                if (std.mem.eql(u8, "metadata", tag_open_name)) {
                    while (true) {
                        const metadata_token = try content_xml.next();
                        switch (metadata_token) {
                            .tag_close => |tag_close_name| {
                                if (std.mem.eql(u8, "metadata", tag_close_name)) {
                                    break;
                                }
                            },
                            .tag_open => |metadata_tag_name| {
                                if (std.mem.eql(u8, "dc:title", metadata_tag_name)) {
                                    const title_token = try content_xml.nextContent();
                                    switch (title_token) {
                                        .content => |title_content| title = title_content,
                                        else => unreachable,
                                    }
                                } else if (std.mem.eql(u8, "dc:language", metadata_tag_name)) {
                                    const language_token = try content_xml.nextContent();
                                    switch (language_token) {
                                        .content => |language_content| language = language_content,
                                        else => unreachable,
                                    }
                                } else if (std.mem.eql(u8, "dc:identifier", metadata_tag_name)) {
                                    const identifier_token = try content_xml.nextContent();
                                    switch (identifier_token) {
                                        .content => |identifier_content| identifier = identifier_content,
                                        else => unreachable,
                                    }
                                } else if (std.mem.eql(u8, "dc:creator", metadata_tag_name)) {
                                    const creator_token = try content_xml.nextContent();
                                    switch (creator_token) {
                                        .content => |creator_content| creator = creator_content,
                                        else => unreachable,
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }

    return Epub{ .reader = reader, .metadata = .{
        .title = title orelse return error.TitleMissing,
        .language = language orelse return error.LanguageMissing,
        .identifier = identifier orelse return error.IdentifierMissing,
        .creator = creator,
    } };
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
