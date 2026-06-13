const Epub = @This();

const std = @import("std");
const xml = @import("xml");

reader: *std.Io.File.Reader,
opf_buffer: []const u8,
metadata: Metadata,
manifest: std.ArrayList(ManifestItem) = .empty,
spine: std.ArrayList(*const ManifestItem) = .empty,

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

pub const ManifestItem = struct {
    id: []const u8,
    href: []const u8,
    media_type: []const u8,
    properties: ?[]const u8 = null,
};

pub fn init(reader: *std.Io.File.Reader, allocator: std.mem.Allocator) !Epub {
    var iter = try std.zip.Iterator.init(reader);
    const first = try iter.next() orelse return EpubError.EpubHasNoFiles;

    // First file must be mimetype with application/epub+zip.
    if (!try entryHasFilename(reader, first, mime_filename)) return EpubError.EpubFirstFileIsNotMimetype;
    const first_content = try decompressEntryToMemory(reader, first, allocator);
    defer allocator.free(first_content);
    if (!std.mem.eql(u8, first_content, mime_type)) return EpubError.EpubWrongFormat;

    // No need to parse container file. Just finding full path is faster.
    const container_entry = try getEntryByFilename(reader, container_filename);
    const container_content = try decompressEntryToMemory(reader, container_entry, allocator);
    defer allocator.free(container_content);

    const needle = "full-path=\"";
    var opf_path: []u8 = undefined;
    if (std.mem.indexOf(u8, container_content, needle)) |start| {
        const path_start = start + needle.len;
        if (std.mem.indexOfScalar(u8, container_content[path_start..], '"')) |end| {
            opf_path = container_content[path_start .. path_start + end];
        }
    }

    const opf_entry = try getEntryByFilename(reader, opf_path);
    const opf_content = try decompressEntryToMemory(reader, opf_entry, allocator);
    var content_xml: xml = .{ .buffer = opf_content };

    var title: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var identifier: ?[]const u8 = null;
    var creator: ?[]const u8 = null;

    var manifest: std.ArrayList(ManifestItem) = .empty;

    var spine: std.ArrayList(*const ManifestItem) = .empty;

    while (true) {
        const token = content_xml.next() catch |err| switch (err) {
            error.BufferUnderrun => break,
            else => return err,
        };
        switch (token) {
            .tag_open => |tag_open_name| {
                // Parse metadata.
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
                    // Parse manifest.
                } else if (std.mem.eql(u8, "manifest", tag_open_name)) {
                    while (true) {
                        const manifest_token = try content_xml.next();
                        switch (manifest_token) {
                            .tag_close => |tag_close_name| {
                                if (std.mem.eql(u8, "manifest", tag_close_name)) {
                                    break;
                                }
                            },
                            .tag_open => |manifest_tag_name| {
                                if (std.mem.eql(u8, "item", manifest_tag_name)) {
                                    var id: ?[]const u8 = null;
                                    var href: ?[]const u8 = null;
                                    var media_type: ?[]const u8 = null;
                                    var properties: ?[]const u8 = null;
                                    while (true) {
                                        const item_token = try content_xml.next();
                                        switch (item_token) {
                                            .attr_key => |key| {
                                                const attr_value = try content_xml.next();
                                                switch (attr_value) {
                                                    .attr_value => |value| {
                                                        if (std.mem.eql(u8, "id", key)) {
                                                            id = value;
                                                        } else if (std.mem.eql(u8, "href", key)) {
                                                            href = value;
                                                        } else if (std.mem.eql(u8, "media-type", key)) {
                                                            media_type = value;
                                                        } else if (std.mem.eql(u8, "properties", key)) {
                                                            properties = value;
                                                        }
                                                    },
                                                    else => unreachable,
                                                }
                                            },
                                            .tag_close, .tag_close_empty => {
                                                try manifest.append(allocator, .{
                                                    .id = id orelse return error.ItemIdMissing,
                                                    .href = href orelse return error.ItemHrefMissing,
                                                    .media_type = media_type orelse return error.ItemMediaTypeMissing,
                                                    .properties = properties,
                                                });
                                                break;
                                            },
                                            else => {},
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    // Parse spine.
                } else if (std.mem.eql(u8, "spine", tag_open_name)) {
                    while (true) {
                        const spine_token = try content_xml.next();
                        switch (spine_token) {
                            .tag_close => |tag_close_name| {
                                if (std.mem.eql(u8, "spine", tag_close_name)) {
                                    break;
                                }
                            },
                            .attr_key => |key| {
                                if (std.mem.eql(u8, "idref", key)) {
                                    const value_token = try content_xml.next();
                                    switch (value_token) {
                                        .attr_value => |id| {
                                            for (manifest.items) |*item| {
                                                if (std.mem.eql(u8, item.id, id)) try spine.append(allocator, item);
                                            }
                                        },
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

    return .{
        .reader = reader,
        .opf_buffer = opf_content,
        .metadata = .{
            .title = title orelse return error.TitleMissing,
            .language = language orelse return error.LanguageMissing,
            .identifier = identifier orelse return error.IdentifierMissing,
            .creator = creator,
        },
        .manifest = manifest,
        .spine = spine,
    };
}

pub fn deinit(epub: *Epub, allocator: std.mem.Allocator) void {
    epub.manifest.deinit(allocator);
    epub.spine.deinit(allocator);
    allocator.free(epub.opf_buffer);
}

fn entryHasFilename(reader: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, filename: []const u8) !bool {
    // limits the name to 256 but this way we do not need an allocator
    var buffer: [256]u8 = undefined;
    if (entry.filename_len > buffer.len) return error.EpubUnsufficientBuffer;
    try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try reader.interface.readSliceAll(buffer[0..entry.filename_len]);
    return std.mem.eql(u8, buffer[0..entry.filename_len], filename);
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

fn getEntryByFilename(reader: *std.Io.File.Reader, filename: []const u8) !std.zip.Iterator.Entry {
    var iterator = try std.zip.Iterator.init(reader);
    while (try iterator.next()) |entry| {
        if (try entryHasFilename(reader, entry, filename)) return entry;
    }
    return EpubError.EpubFileNotFound;
}

test "test init deinit" {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, "testdata/pg215-images-3.epub", .{});
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var reader = file.reader(io, &buf);
    var epub = try Epub.init(&reader, std.testing.allocator);
    epub.deinit(std.testing.allocator);
}
