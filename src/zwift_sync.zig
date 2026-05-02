const std = @import("std");
const file_organizer = @import("file_organizer.zig");

const zwift_config_path = "/.config/sweattrails/zwift_config";
const zwift_imported_path = "/.config/sweattrails/zwift_imported.json";

// ── libc shims ────────────────────────────────────────────────────────────────
const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: *anyopaque, size: usize, count: usize, stream: *FILE) usize;
extern fn system(command: [*:0]const u8) c_int;

// ── Public types ─────────────────────────────────────────────────────────────

pub const ZwiftConfig = struct {
    source_folder: [512]u8 = std.mem.zeroes([512]u8),
    remote_host: [256]u8 = std.mem.zeroes([256]u8),
    auto_sync: bool = true,
};

pub const ZwiftImportedEntry = struct {
    activity_timestamp: i64 = 0,
    file_size: usize = 0,
    source_filename: [256]u8 = std.mem.zeroes([256]u8),
};

pub const ZwiftImportedList = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ZwiftImportedEntry),

    pub fn init(allocator: std.mem.Allocator) ZwiftImportedList {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *ZwiftImportedList) void {
        self.entries.deinit(self.allocator);
    }
};

pub const ZwiftSyncProgress = struct {
    files_found: i32 = 0,
    files_imported: i32 = 0,
    files_skipped: i32 = 0,
    current_file: [256]u8 = std.mem.zeroes([256]u8),
};

// ── Utilities ─────────────────────────────────────────────────────────────────

pub fn getDefaultFolder(buf: []u8) []u8 {
    const home_ptr = std.c.getenv("HOME") orelse return buf[0..0];
    const home = std.mem.span(home_ptr);
    return std.fmt.bufPrint(buf, "{s}/Documents/Zwift/Activities", .{home}) catch buf[0..0];
}

fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    return std.c.access(path_z, 0) == 0;
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

    const result = try allocator.alloc(u8, total + 1);
    var offset: usize = 0;
    for (chunks.items) |chunk| {
        @memcpy(result[offset .. offset + chunk.len], chunk);
        offset += chunk.len;
    }
    result[total] = 0;
    return result[0..total];
}

fn writeFd(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data[written..].ptr, data.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn openFileWrite(path: []const u8) !std.posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    return std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
}

fn getFileSize(path: []const u8) usize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return 0;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return 0;
    return @intCast(st.size);
}

fn createDirectoryPath(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const trimmed = if (path.len > 0 and path[path.len - 1] == '/')
        path[0 .. path.len - 1]
    else
        path;
    var i: usize = 1;
    while (i <= trimmed.len) : (i += 1) {
        if (i == trimmed.len or trimmed[i] == '/') {
            const z = try std.fmt.bufPrintZ(&buf, "{s}", .{trimmed[0..i]});
            const rc = std.c.mkdir(z, 0o755);
            const err = std.c.errno(rc);
            if (err != .SUCCESS and err != .EXIST) return error.MkdirFailed;
        }
    }
}

fn copyFile(src_path: []const u8, dst_path: []const u8) !void {
    var src_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_z_buf, "{s}", .{src_path});
    const src_fd = try std.posix.openatZ(std.posix.AT.FDCWD, src_z, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(src_fd);

    const dst_fd = try openFileWrite(dst_path);
    defer _ = std.c.close(dst_fd);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(src_fd, &buf) catch break;
        if (n == 0) break;
        try writeFd(dst_fd, buf[0..n]);
    }
}

fn endsWithFit(name: []const u8) bool {
    if (name.len < 5) return false;
    return std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".fit");
}

fn copyFileName(dest: *[256]u8, src: []const u8) void {
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
    dest[n] = 0;
}

fn buildDestDir(allocator: std.mem.Allocator, data_dir: []const u8, timestamp: i64) ![]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        allocator,
        "{s}/activity/{d:0>4}/{d:0>2}",
        .{ data_dir, year_day.year, @intFromEnum(month_day.month) },
    );
}

// ── Config I/O ────────────────────────────────────────────────────────────────

pub fn loadConfig(allocator: std.mem.Allocator) !ZwiftConfig {
    var config = ZwiftConfig{};

    const home_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
    const home = std.mem.span(home_ptr);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, zwift_config_path });

    const json = readFileFull(allocator, path) catch {
        _ = getDefaultFolder(&config.source_folder);
        return config;
    };
    defer allocator.free(json);

    if (jsonGetString(json, "source_folder")) |v| {
        const n = @min(v.len, config.source_folder.len - 1);
        @memcpy(config.source_folder[0..n], v[0..n]);
        config.source_folder[n] = 0;
    }
    if (jsonGetString(json, "remote_host")) |v| {
        const n = @min(v.len, config.remote_host.len - 1);
        @memcpy(config.remote_host[0..n], v[0..n]);
        config.remote_host[n] = 0;
    }
    if (jsonGetBool(json, "auto_sync")) |v| {
        config.auto_sync = v;
    }

    if (config.source_folder[0] == 0) {
        _ = getDefaultFolder(&config.source_folder);
    }

    return config;
}

pub fn saveConfig(config: *const ZwiftConfig) !void {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
    const home = std.mem.span(home_ptr);

    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/sweattrails", .{home}) catch return error.NameTooLong;
    try createDirectoryPath(dir_path);

    var file_path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ home, zwift_config_path }) catch return error.NameTooLong;

    const fd = try openFileWrite(file_path);
    defer _ = std.c.close(fd);

    var out_buf: [2048]u8 = undefined;
    const content = try std.fmt.bufPrint(&out_buf,
        "{{\n  \"source_folder\": \"{s}\",\n  \"remote_host\": \"{s}\",\n  \"auto_sync\": {s}\n}}\n",
        .{
            std.mem.sliceTo(&config.source_folder, 0),
            std.mem.sliceTo(&config.remote_host, 0),
            if (config.auto_sync) "true" else "false",
        },
    );
    try writeFd(fd, content);
}

// ── Imported-list I/O ─────────────────────────────────────────────────────────

pub fn loadImported(allocator: std.mem.Allocator) !ZwiftImportedList {
    var list = ZwiftImportedList.init(allocator);

    const home_ptr = std.c.getenv("HOME") orelse return list;
    const home = std.mem.span(home_ptr);

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, zwift_imported_path });

    const json = readFileFull(allocator, path) catch return list;
    defer allocator.free(json);

    const array_start = std.mem.indexOf(u8, json, "\"imported\"") orelse return list;
    const bracket = std.mem.indexOfScalarPos(u8, json, array_start, '[') orelse return list;

    var pos: usize = bracket + 1;
    while (true) {
        const obj_start = std.mem.indexOfScalarPos(u8, json, pos, '{') orelse break;

        var depth: usize = 1;
        var in_str = false;
        var i: usize = obj_start + 1;
        while (i < json.len and depth > 0) : (i += 1) {
            const ch = json[i];
            if (in_str) {
                if (ch == '\\') {
                    i += 1;
                } else if (ch == '"') {
                    in_str = false;
                }
            } else {
                switch (ch) {
                    '"' => in_str = true,
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    else => {},
                }
            }
        }
        if (depth != 0) break;

        const obj = json[obj_start..i];
        pos = i;

        const ts = jsonGetInt64(obj, "timestamp") orelse continue;
        const sz = jsonGetInt64(obj, "file_size") orelse 0;
        const fname = jsonGetString(obj, "filename") orelse "";

        var entry = ZwiftImportedEntry{
            .activity_timestamp = ts,
            .file_size = @intCast(sz),
        };
        const n = @min(fname.len, entry.source_filename.len - 1);
        @memcpy(entry.source_filename[0..n], fname[0..n]);
        entry.source_filename[n] = 0;

        try list.entries.append(list.allocator, entry);
    }

    return list;
}

pub fn saveImported(list: *const ZwiftImportedList) !void {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
    const home = std.mem.span(home_ptr);

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, zwift_imported_path }) catch return error.NameTooLong;

    const fd = try openFileWrite(path);
    defer _ = std.c.close(fd);

    try writeFd(fd, "{\n  \"imported\": [\n");

    for (list.entries.items, 0..) |*entry, idx| {
        var line_buf: [1024]u8 = undefined;
        const sep = if (idx < list.entries.items.len - 1) "," else "";
        const line = std.fmt.bufPrint(&line_buf,
            "    {{\"timestamp\": {d}, \"file_size\": {d}, \"filename\": \"{s}\"}}{s}\n",
            .{
                entry.activity_timestamp,
                entry.file_size,
                std.mem.sliceTo(&entry.source_filename, 0),
                sep,
            },
        ) catch continue;
        try writeFd(fd, line);
    }

    try writeFd(fd, "  ]\n}\n");
}

pub fn isImported(list: *const ZwiftImportedList, timestamp: i64, file_size: usize) bool {
    for (list.entries.items) |*entry| {
        if (entry.activity_timestamp == timestamp and entry.file_size == file_size) return true;
    }
    return false;
}

fn isFilenameImported(list: *const ZwiftImportedList, filename: []const u8, file_size: usize) bool {
    for (list.entries.items) |*entry| {
        if (entry.file_size == file_size and
            std.mem.eql(u8, std.mem.sliceTo(&entry.source_filename, 0), filename))
        {
            return true;
        }
    }
    return false;
}

pub fn addImported(list: *ZwiftImportedList, timestamp: i64, file_size: usize, filename: []const u8) !void {
    var entry = ZwiftImportedEntry{
        .activity_timestamp = timestamp,
        .file_size = file_size,
    };
    const n = @min(filename.len, entry.source_filename.len - 1);
    @memcpy(entry.source_filename[0..n], filename[0..n]);
    entry.source_filename[n] = 0;
    try list.entries.append(list.allocator, entry);
}

// ── Main sync entry point ─────────────────────────────────────────────────────

pub fn syncActivities(
    allocator: std.mem.Allocator,
    config: *const ZwiftConfig,
    data_dir: []const u8,
    progress: *ZwiftSyncProgress,
) !i32 {
    progress.* = ZwiftSyncProgress{};

    var imported = try loadImported(allocator);
    defer imported.deinit();

    const remote_host = std.mem.sliceTo(&config.remote_host, 0);
    const imported_count: i32 = if (remote_host.len > 0)
        try syncRemote(allocator, config, data_dir, progress, &imported)
    else
        try syncLocal(allocator, config, data_dir, progress, &imported);

    try saveImported(&imported);
    return imported_count;
}

// ── Local sync ────────────────────────────────────────────────────────────────

fn syncLocal(
    allocator: std.mem.Allocator,
    config: *const ZwiftConfig,
    data_dir: []const u8,
    progress: *ZwiftSyncProgress,
    imported: *ZwiftImportedList,
) !i32 {
    const source_folder = std.mem.sliceTo(&config.source_folder, 0);

    var dir_z_buf: [512]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{source_folder}) catch return 0;
    const dir = std.c.opendir(dir_z) orelse return 0;
    defer _ = std.c.closedir(dir);

    var imported_count: i32 = 0;

    while (std.c.readdir(dir)) |entry| {
        if (entry.type != std.c.DT.REG) continue;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (!endsWithFit(name)) continue;

        progress.files_found += 1;
        copyFileName(&progress.current_file, name);

        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_folder, name }) catch {
            progress.files_skipped += 1;
            continue;
        };

        const file_size = getFileSize(src_path);
        if (file_size == 0) {
            progress.files_skipped += 1;
            continue;
        }

        const timestamp = file_organizer.getFitActivityTimestamp(src_path);
        if (timestamp == 0) {
            progress.files_skipped += 1;
            continue;
        }

        if (isImported(imported, timestamp, file_size)) {
            progress.files_skipped += 1;
            continue;
        }

        const dest_dir = buildDestDir(allocator, data_dir, timestamp) catch {
            progress.files_skipped += 1;
            continue;
        };
        defer allocator.free(dest_dir);

        createDirectoryPath(dest_dir) catch {
            progress.files_skipped += 1;
            continue;
        };

        var dest_buf: [512]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_buf, "{s}/zwift_{d}.fit", .{ dest_dir, timestamp }) catch {
            progress.files_skipped += 1;
            continue;
        };

        if (fileExists(dest_path)) {
            addImported(imported, timestamp, file_size, name) catch {};
            progress.files_skipped += 1;
            continue;
        }

        copyFile(src_path, dest_path) catch {
            progress.files_skipped += 1;
            continue;
        };
        addImported(imported, timestamp, file_size, name) catch {};
        imported_count += 1;
        progress.files_imported += 1;
        std.debug.print("Imported Zwift activity: {s} -> {s}\n", .{ name, dest_path });
    }

    return imported_count;
}

// ── Remote sync via SSH / SCP ─────────────────────────────────────────────────

const RemoteFileInfo = struct {
    filename: [256]u8,
    file_size: usize,
};

fn syncRemote(
    allocator: std.mem.Allocator,
    config: *const ZwiftConfig,
    data_dir: []const u8,
    progress: *ZwiftSyncProgress,
    imported: *ZwiftImportedList,
) !i32 {
    const remote_host = std.mem.sliceTo(&config.remote_host, 0);
    const source_folder = std.mem.sliceTo(&config.source_folder, 0);

    var files = try sshListFitFiles(allocator, remote_host, source_folder);
    defer files.deinit(allocator);

    if (files.items.len == 0) return 0;

    const home_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
    const home = std.mem.span(home_ptr);
    var tmp_dir_buf: [512]u8 = undefined;
    const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "{s}/.cache/sweattrails/zwift_tmp", .{home});
    createDirectoryPath(tmp_dir) catch {};

    var imported_count: i32 = 0;

    for (files.items) |*rfi| {
        const fname = std.mem.sliceTo(&rfi.filename, 0);
        progress.files_found += 1;
        copyFileName(&progress.current_file, fname);

        if (isFilenameImported(imported, fname, rfi.file_size)) {
            progress.files_skipped += 1;
            continue;
        }

        var remote_buf: [1024]u8 = undefined;
        const remote_path = std.fmt.bufPrint(&remote_buf, "{s}/{s}", .{ source_folder, fname }) catch {
            progress.files_skipped += 1;
            continue;
        };

        var tmp_buf: [1024]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/{s}", .{ tmp_dir, fname }) catch {
            progress.files_skipped += 1;
            continue;
        };

        scpCopyFile(allocator, remote_host, remote_path, tmp_path) catch {
            progress.files_skipped += 1;
            continue;
        };

        const file_size = getFileSize(tmp_path);
        const timestamp = file_organizer.getFitActivityTimestamp(tmp_path);

        if (timestamp == 0) {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        }

        if (isImported(imported, timestamp, file_size)) {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        }

        const dest_dir = buildDestDir(allocator, data_dir, timestamp) catch {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        };
        defer allocator.free(dest_dir);

        createDirectoryPath(dest_dir) catch {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        };

        var dest_buf: [512]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_buf, "{s}/zwift_{d}.fit", .{ dest_dir, timestamp }) catch {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        };

        if (fileExists(dest_path)) {
            addImported(imported, timestamp, file_size, fname) catch {};
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        }

        // Try rename first (fast path), fall back to copy.
        var tmp_z_buf: [1024]u8 = undefined;
        var dst_z_buf: [512]u8 = undefined;
        const tmp_z = std.fmt.bufPrintZ(&tmp_z_buf, "{s}", .{tmp_path}) catch {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        };
        const dst_z = std.fmt.bufPrintZ(&dst_z_buf, "{s}", .{dest_path}) catch {
            deleteFile(tmp_path);
            progress.files_skipped += 1;
            continue;
        };

        const moved = (std.c.rename(tmp_z, dst_z) == 0) or blk: {
            copyFile(tmp_path, dest_path) catch {
                deleteFile(tmp_path);
                break :blk false;
            };
            deleteFile(tmp_path);
            break :blk true;
        };

        if (moved) {
            addImported(imported, timestamp, file_size, fname) catch {};
            imported_count += 1;
            progress.files_imported += 1;
            std.debug.print("Imported Zwift activity from {s}: {s} -> {s}\n", .{ remote_host, fname, dest_path });
        } else {
            progress.files_skipped += 1;
        }
    }

    return imported_count;
}

fn deleteFile(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(path_z);
}

fn sshListFitFiles(allocator: std.mem.Allocator, host: []const u8, folder: []const u8) !std.ArrayList(RemoteFileInfo) {
    var files: std.ArrayList(RemoteFileInfo) = .empty;
    errdefer files.deinit(allocator);

    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf,
        "ssh -o BatchMode=yes -o ConnectTimeout=10 {s} \"cd \\\"{s}\\\" 2>/dev/null && (stat -f '%z %N' *.fit 2>/dev/null || stat -c '%s %n' *.fit 2>/dev/null)\"",
        .{ host, folder },
    ) catch return files;

    const pipe = popen(cmd.ptr, "r") orelse return files;
    defer _ = pclose(pipe);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    while (true) {
        const chunk = allocator.alloc(u8, 4096) catch break;
        const n = fread(chunk.ptr, 1, 4096, pipe);
        if (n == 0) {
            allocator.free(chunk);
            break;
        }
        out.appendSlice(allocator, chunk[0..n]) catch {
            allocator.free(chunk);
            break;
        };
        allocator.free(chunk);
    }

    var line_it = std.mem.splitScalar(u8, out.items, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;

        const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const size_str = trimmed[0..space];
        const full_name = trimmed[space + 1 ..];

        const file_size = std.fmt.parseInt(usize, size_str, 10) catch continue;

        const basename = if (std.mem.lastIndexOfScalar(u8, full_name, '/')) |idx|
            full_name[idx + 1 ..]
        else
            full_name;

        if (!endsWithFit(basename)) continue;

        var rfi = RemoteFileInfo{ .filename = std.mem.zeroes([256]u8), .file_size = file_size };
        const n = @min(basename.len, rfi.filename.len - 1);
        @memcpy(rfi.filename[0..n], basename[0..n]);
        rfi.filename[n] = 0;

        files.append(allocator, rfi) catch continue;
    }

    return files;
}

fn scpCopyFile(allocator: std.mem.Allocator, host: []const u8, remote_path: []const u8, local_path: []const u8) !void {
    var cmd_buf: [2048]u8 = undefined;
    _ = std.fmt.bufPrintZ(&cmd_buf,
        "scp -o BatchMode=yes -o ConnectTimeout=10 {s}:{s} {s}",
        .{ host, remote_path, local_path },
    ) catch return error.ScpFailed;
    _ = allocator;
    if (system(@ptrCast(&cmd_buf)) != 0) return error.ScpFailed;
}

// ── Minimal JSON helpers ──────────────────────────────────────────────────────

fn jsonFindKey(json: []const u8, key: []const u8) ?usize {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, search)) |found| {
        var depth: i32 = 0;
        for (json[0..found]) |ch| {
            if (ch == '{') depth += 1 else if (ch == '}') depth -= 1;
        }
        if (depth <= 1) return found;
        pos = found + 1;
    }
    return null;
}

fn jsonGetString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = jsonFindKey(json, key) orelse return null;

    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var pos = key_pos + search.len;
    pos = std.mem.indexOfScalarPos(u8, json, pos, ':') orelse return null;
    pos += 1;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;

    const start = pos;
    while (pos < json.len and json[pos] != '"') {
        if (json[pos] == '\\') pos += 1;
        pos += 1;
    }
    return json[start..pos];
}

fn jsonGetBool(json: []const u8, key: []const u8) ?bool {
    const key_pos = jsonFindKey(json, key) orelse return null;

    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var pos = key_pos + search.len;
    pos = std.mem.indexOfScalarPos(u8, json, pos, ':') orelse return null;
    pos += 1;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}

    if (std.mem.startsWith(u8, json[pos..], "true")) return true;
    if (std.mem.startsWith(u8, json[pos..], "false")) return false;
    return null;
}

fn jsonGetInt64(json: []const u8, key: []const u8) ?i64 {
    const key_pos = jsonFindKey(json, key) orelse return null;

    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var pos = key_pos + search.len;
    pos = std.mem.indexOfScalarPos(u8, json, pos, ':') orelse return null;
    pos += 1;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}

    const start = pos;
    if (pos < json.len and json[pos] == '-') pos += 1;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}
    if (pos == start) return null;

    return std.fmt.parseInt(i64, json[start..pos], 10) catch null;
}
