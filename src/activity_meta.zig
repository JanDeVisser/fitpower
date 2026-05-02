const std = @import("std");

pub const MAX_GROUP_FILES = 32;

pub const ActivityMeta = struct {
    title: [256]u8 = std.mem.zeroes([256]u8),
    description: [2048]u8 = std.mem.zeroes([2048]u8),
    title_edited: bool = false,
    description_edited: bool = false,
};

pub const GroupMeta = struct {
    title: [256]u8 = std.mem.zeroes([256]u8),
    description: [2048]u8 = std.mem.zeroes([2048]u8),
    title_edited: bool = false,
    description_edited: bool = false,
    files: [MAX_GROUP_FILES][64]u8 = std.mem.zeroes([MAX_GROUP_FILES][64]u8),
    file_count: i32 = 0,
};

fn jsonEscapeString(src: []const u8, dest: []u8) []u8 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < src.len and j < dest.len - 2) : (i += 1) {
        const c = src[i];
        switch (c) {
            '"', '\\' => {
                if (j < dest.len - 3) {
                    dest[j] = '\\';
                    j += 1;
                    dest[j] = c;
                    j += 1;
                }
            },
            '\n' => {
                if (j < dest.len - 3) {
                    dest[j] = '\\';
                    j += 1;
                    dest[j] = 'n';
                    j += 1;
                }
            },
            '\r' => {
                if (j < dest.len - 3) {
                    dest[j] = '\\';
                    j += 1;
                    dest[j] = 'r';
                    j += 1;
                }
            },
            '\t' => {
                if (j < dest.len - 3) {
                    dest[j] = '\\';
                    j += 1;
                    dest[j] = 't';
                    j += 1;
                }
            },
            else => {
                dest[j] = c;
                j += 1;
            },
        }
    }
    return dest[0..j];
}

fn jsonUnescapeString(src: []const u8, dest: []u8) []u8 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < src.len and j < dest.len - 1) {
        if (src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            dest[j] = switch (src[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => src[i],
            };
            j += 1;
            i += 1;
        } else {
            dest[j] = src[i];
            j += 1;
            i += 1;
        }
    }
    return dest[0..j];
}

fn jsonGetStringValue(json: []const u8, key: []const u8, out: []u8) bool {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return false;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return false;
    const after_key = json[key_pos + search.len ..];

    const colon_offset = std.mem.indexOfScalar(u8, after_key, ':') orelse return false;
    var pos = after_key[colon_offset..];

    var skip: usize = 0;
    while (skip < pos.len and (pos[skip] == ':' or pos[skip] == ' ' or pos[skip] == '\t' or pos[skip] == '\n')) {
        skip += 1;
    }
    pos = pos[skip..];

    if (pos.len == 0 or pos[0] != '"') return false;
    pos = pos[1..];

    var escaped_buf: [4096]u8 = undefined;
    var ei: usize = 0;
    var pi: usize = 0;
    while (pi < pos.len and pos[pi] != '"' and ei < escaped_buf.len - 1) {
        if (pos[pi] == '\\' and pi + 1 < pos.len) {
            escaped_buf[ei] = pos[pi];
            ei += 1;
            pi += 1;
        }
        escaped_buf[ei] = pos[pi];
        ei += 1;
        pi += 1;
    }
    const escaped = escaped_buf[0..ei];

    const unescaped = jsonUnescapeString(escaped, out);
    if (unescaped.len < out.len) {
        out[unescaped.len] = 0;
    }
    return true;
}

fn jsonGetBoolValue(json: []const u8, key: []const u8) bool {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return false;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return false;
    const after_key = json[key_pos + search.len ..];

    const colon_offset = std.mem.indexOfScalar(u8, after_key, ':') orelse return false;
    var pos = after_key[colon_offset..];

    var skip: usize = 0;
    while (skip < pos.len and (pos[skip] == ':' or pos[skip] == ' ' or pos[skip] == '\t' or pos[skip] == '\n')) {
        skip += 1;
    }
    pos = pos[skip..];

    return std.mem.startsWith(u8, pos, "true");
}

fn readFileFull(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);

    var chunks: std.ArrayList([]u8) = .empty;
    defer {
        for (chunks.items) |chunk| allocator.free(chunk);
        chunks.deinit(allocator);
    }

    var total: usize = 0;
    while (true) {
        const chunk = try allocator.alloc(u8, 4096);
        const n = std.posix.read(fd, chunk) catch {
            allocator.free(chunk);
            break;
        };
        if (n == 0) {
            allocator.free(chunk);
            break;
        }
        try chunks.append(allocator, chunk[0..n]);
        total += n;
        if (n < 4096) break;
    }

    const buf = try allocator.alloc(u8, total + 1);
    var offset: usize = 0;
    for (chunks.items) |chunk| {
        @memcpy(buf[offset .. offset + chunk.len], chunk);
        offset += chunk.len;
    }
    buf[total] = 0;
    return buf[0..total];
}

fn writeFileFull(path: []const u8, data: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    defer _ = std.c.close(fd);

    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data[written..].ptr, data.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn loadMeta(allocator: std.mem.Allocator, activity_path: []const u8) !ActivityMeta {
    var path_buf: [520]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&path_buf, "{s}.meta.json", .{activity_path});

    const json = try readFileFull(allocator, meta_path);
    defer allocator.free(json);

    var meta = ActivityMeta{};
    _ = jsonGetStringValue(json, "title", &meta.title);
    _ = jsonGetStringValue(json, "description", &meta.description);
    meta.title_edited = jsonGetBoolValue(json, "title_edited");
    meta.description_edited = jsonGetBoolValue(json, "description_edited");
    return meta;
}

pub fn saveMeta(activity_path: []const u8, meta: *const ActivityMeta) !void {
    var path_buf: [520]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&path_buf, "{s}.meta.json", .{activity_path});

    var escaped_title_buf: [512]u8 = undefined;
    var escaped_desc_buf: [4096]u8 = undefined;
    const title_src = std.mem.sliceTo(&meta.title, 0);
    const desc_src = std.mem.sliceTo(&meta.description, 0);
    const escaped_title = jsonEscapeString(title_src, &escaped_title_buf);
    const escaped_desc = jsonEscapeString(desc_src, &escaped_desc_buf);

    var out_buf: [8192]u8 = undefined;
    const content = try std.fmt.bufPrint(&out_buf,
        "{{\n  \"title\": \"{s}\",\n  \"description\": \"{s}\",\n  \"title_edited\": {s},\n  \"description_edited\": {s}\n}}\n",
        .{
            escaped_title,
            escaped_desc,
            if (meta.title_edited) "true" else "false",
            if (meta.description_edited) "true" else "false",
        });

    try writeFileFull(meta_path, content);
}

pub fn groupMetaPath(month_path: []const u8, timestamp: i64, buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "{s}/group_{d}.meta.json", .{ month_path, timestamp }) catch buf[0..0];
}

pub fn loadGroupMeta(allocator: std.mem.Allocator, meta_path: []const u8) !GroupMeta {
    const json = try readFileFull(allocator, meta_path);
    defer allocator.free(json);

    var meta = GroupMeta{};
    _ = jsonGetStringValue(json, "title", &meta.title);
    _ = jsonGetStringValue(json, "description", &meta.description);
    meta.title_edited = jsonGetBoolValue(json, "title_edited");
    meta.description_edited = jsonGetBoolValue(json, "description_edited");

    const files_key = std.mem.indexOf(u8, json, "\"files\"") orelse return meta;
    const bracket_offset = std.mem.indexOfScalar(u8, json[files_key..], '[') orelse return meta;
    var pos = json[files_key + bracket_offset + 1 ..];

    while (pos.len > 0 and meta.file_count < MAX_GROUP_FILES) {
        var skip: usize = 0;
        while (skip < pos.len and (pos[skip] == ' ' or pos[skip] == '\n' or pos[skip] == ',')) {
            skip += 1;
        }
        pos = pos[skip..];

        if (pos.len == 0 or pos[0] == ']') break;

        if (pos[0] != '"') break;
        pos = pos[1..];

        const dest = &meta.files[@intCast(meta.file_count)];
        var di: usize = 0;
        while (pos.len > 0 and pos[0] != '"' and di < 63) {
            dest[di] = pos[0];
            di += 1;
            pos = pos[1..];
        }
        dest[di] = 0;
        if (pos.len > 0 and pos[0] == '"') pos = pos[1..];
        meta.file_count += 1;
    }

    return meta;
}

pub fn saveGroupMeta(meta_path: []const u8, meta: *const GroupMeta) !void {
    var escaped_title_buf: [512]u8 = undefined;
    var escaped_desc_buf: [4096]u8 = undefined;
    const title_src = std.mem.sliceTo(&meta.title, 0);
    const desc_src = std.mem.sliceTo(&meta.description, 0);
    const escaped_title = jsonEscapeString(title_src, &escaped_title_buf);
    const escaped_desc = jsonEscapeString(desc_src, &escaped_desc_buf);

    // Build files array string
    var files_buf: [4096]u8 = undefined;
    var fi: usize = 0;
    var i: i32 = 0;
    while (i < meta.file_count) : (i += 1) {
        const fname = std.mem.sliceTo(&meta.files[@intCast(i)], 0);
        const sep: []const u8 = if (i > 0) ", " else "";
        const s = std.fmt.bufPrint(files_buf[fi..], "{s}\"{s}\"", .{ sep, fname }) catch break;
        fi += s.len;
    }

    var out_buf: [16384]u8 = undefined;
    const content = try std.fmt.bufPrint(&out_buf,
        "{{\n  \"title\": \"{s}\",\n  \"description\": \"{s}\",\n  \"title_edited\": {s},\n  \"description_edited\": {s},\n  \"files\": [{s}]\n}}\n",
        .{
            escaped_title,
            escaped_desc,
            if (meta.title_edited) "true" else "false",
            if (meta.description_edited) "true" else "false",
            files_buf[0..fi],
        });

    try writeFileFull(meta_path, content);
}
