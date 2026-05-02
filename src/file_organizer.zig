const std = @import("std");

pub const FIT_TIMESTAMP_OFFSET: i64 = 631065600;

const FIT_MESG_RECORD: u16 = 20;
const FIT_MESG_FILE_ID: u16 = 0;
const FIT_FIELD_TIMESTAMP: u8 = 253;
const FIT_FIELD_TIME_CREATED: u8 = 4;

const LocalDef = struct {
    defined: bool = false,
    arch: u8 = 0,
    global_msg_num: u16 = 0,
    num_fields: u8 = 0,
    field_def_nums: [256]u8 = [_]u8{0} ** 256,
    field_sizes: [256]u8 = [_]u8{0} ** 256,
    record_size: usize = 0,
};

fn readU16(data: []const u8, big_endian: bool) u16 {
    if (big_endian) {
        return @as(u16, data[0]) << 8 | @as(u16, data[1]);
    }
    return @as(u16, data[1]) << 8 | @as(u16, data[0]);
}

fn readU32(data: []const u8, big_endian: bool) u32 {
    if (big_endian) {
        return @as(u32, data[0]) << 24 | @as(u32, data[1]) << 16 |
            @as(u32, data[2]) << 8 | @as(u32, data[3]);
    }
    return @as(u32, data[3]) << 24 | @as(u32, data[2]) << 16 |
        @as(u32, data[1]) << 8 | @as(u32, data[0]);
}

fn readFd(fd: std.posix.fd_t, buf: []u8) usize {
    return std.posix.read(fd, buf) catch 0;
}

pub fn createDirectoryPath(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const trimmed = if (path.len > 0 and path[path.len - 1] == '/')
        path[0 .. path.len - 1]
    else
        path;

    var i: usize = 1;
    while (i <= trimmed.len) : (i += 1) {
        if (i == trimmed.len or trimmed[i] == '/') {
            const component = trimmed[0..i];
            const z = try std.fmt.bufPrintZ(&buf, "{s}", .{component});
            const rc = std.c.mkdir(z, 0o755);
            const err = std.c.errno(rc);
            if (err != .SUCCESS and err != .EXIST) return error.MkdirFailed;
        }
    }
}

pub fn getFitActivityTimestamp(filepath: []const u8) i64 {
    return fitTimestampInner(filepath) catch 0;
}

fn fitTimestampInner(filepath: []const u8) !i64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{filepath});
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);

    var header: [14]u8 = undefined;
    if (readFd(fd, header[0..1]) != 1) return 0;

    const header_size = header[0];
    if (header_size != 12 and header_size != 14) return 0;

    if (readFd(fd, header[1..header_size]) != header_size - 1) return 0;

    if (header[8] != '.' or header[9] != 'F' or header[10] != 'I' or header[11] != 'T') return 0;

    const data_size = readU32(header[4..8], false);

    var definitions = [_]LocalDef{.{}} ** 16;
    const timestamp: u32 = 0;
    var bytes_read: u32 = 0;

    var record_buf: [4096]u8 = undefined;

    while (bytes_read < data_size) {
        var record_header_buf: [1]u8 = undefined;
        if (readFd(fd, &record_header_buf) != 1) break;
        const record_header = record_header_buf[0];
        bytes_read += 1;

        if (record_header & 0x80 != 0) {
            // Compressed timestamp header
            const local_msg = (record_header >> 5) & 0x03;
            const def = &definitions[local_msg];
            if (!def.defined) continue;

            const sz = def.record_size;
            if (sz > record_buf.len) break;
            if (readFd(fd, record_buf[0..sz]) != sz) break;
            bytes_read += @intCast(sz);

            if (def.global_msg_num == FIT_MESG_RECORD) {
                var offset: usize = 0;
                for (0..def.num_fields) |i| {
                    if (def.field_def_nums[i] == FIT_FIELD_TIMESTAMP and def.field_sizes[i] >= 4) {
                        const ts = readU32(record_buf[offset..], def.arch == 1);
                        return @as(i64, ts) + FIT_TIMESTAMP_OFFSET;
                    }
                    offset += def.field_sizes[i];
                }
            }
        } else if (record_header & 0x40 != 0) {
            // Definition message
            const local_msg = record_header & 0x0F;
            const has_dev_data = (record_header & 0x20) != 0;

            var def_header: [5]u8 = undefined;
            if (readFd(fd, &def_header) != 5) break;
            bytes_read += 5;

            const def = &definitions[local_msg];
            def.defined = true;
            def.arch = def_header[1];
            def.global_msg_num = readU16(def_header[2..4], def.arch == 1);
            def.num_fields = def_header[4];
            def.record_size = 0;

            var i: usize = 0;
            while (i < def.num_fields and i < 256) : (i += 1) {
                var field_def: [3]u8 = undefined;
                if (readFd(fd, &field_def) != 3) break;
                bytes_read += 3;
                def.field_def_nums[i] = field_def[0];
                def.field_sizes[i] = field_def[1];
                def.record_size += field_def[1];
            }

            if (has_dev_data) {
                var num_dev_buf: [1]u8 = undefined;
                if (readFd(fd, &num_dev_buf) != 1) break;
                bytes_read += 1;
                const num_dev_fields = num_dev_buf[0];

                var j: usize = 0;
                while (j < num_dev_fields) : (j += 1) {
                    var dev_field_def: [3]u8 = undefined;
                    if (readFd(fd, &dev_field_def) != 3) break;
                    bytes_read += 3;
                    def.record_size += dev_field_def[1];
                }
            }
        } else {
            // Data message
            const local_msg = record_header & 0x0F;
            const def = &definitions[local_msg];
            if (!def.defined) break;

            const sz = def.record_size;
            if (sz > record_buf.len) break;
            if (readFd(fd, record_buf[0..sz]) != sz) break;
            bytes_read += @intCast(sz);

            if (def.global_msg_num == FIT_MESG_FILE_ID or def.global_msg_num == FIT_MESG_RECORD) {
                var offset: usize = 0;
                for (0..def.num_fields) |i| {
                    const field_num = def.field_def_nums[i];
                    const is_timestamp = field_num == FIT_FIELD_TIMESTAMP or
                        (def.global_msg_num == FIT_MESG_FILE_ID and field_num == FIT_FIELD_TIME_CREATED);
                    if (is_timestamp and def.field_sizes[i] >= 4) {
                        const ts = readU32(record_buf[offset..], def.arch == 1);
                        if (ts != 0 and ts != 0xFFFFFFFF) {
                            return @as(i64, ts) + FIT_TIMESTAMP_OFFSET;
                        }
                    }
                    offset += def.field_sizes[i];
                }
            }
        }
    }

    return if (timestamp != 0) @as(i64, timestamp) + FIT_TIMESTAMP_OFFSET else 0;
}

pub fn organizeFitFile(data_dir: []const u8, filepath: []const u8) !void {
    var unix_ts = getFitActivityTimestamp(filepath);
    if (unix_ts == 0) {
        std.debug.print("Warning: Could not get timestamp from {s}, using current time\n", .{filepath});
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        unix_ts = ts.sec;
    }

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(unix_ts)) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var dest_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_dir = try std.fmt.bufPrint(&dest_dir_buf, "{s}/activity/{d:0>4}/{d:0>2}", .{
        data_dir,
        year_day.year,
        month_day.month.numeric(),
    });

    try createDirectoryPath(dest_dir);

    const filename = std.fs.path.basename(filepath);

    var dest_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path = try std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ dest_dir, filename });

    var dest_path_z: [std.fs.max_path_bytes]u8 = undefined;
    const dest_z = try std.fmt.bufPrintZ(&dest_path_z, "{s}", .{dest_path});

    if (std.c.access(dest_z, 0) != 0) {
        // File doesn't exist at destination, move it
        var src_z_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_z = try std.fmt.bufPrintZ(&src_z_buf, "{s}", .{filepath});
        const rc = std.c.rename(src_z, dest_z);
        if (rc != 0) return error.RenameFailed;
        std.debug.print("Organized: {s} -> {s}\n", .{ filename, dest_path });
    } else {
        std.debug.print("Warning: File already exists at {s}, skipping\n", .{dest_path});
    }
}

pub fn processInbox(allocator: std.mem.Allocator, data_dir: []const u8) !i32 {
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox_path = try std.fmt.bufPrint(&inbox_buf, "{s}/inbox", .{data_dir});

    try createDirectoryPath(inbox_path);

    var inbox_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox_z = try std.fmt.bufPrintZ(&inbox_z_buf, "{s}", .{inbox_path});

    const dir = std.c.opendir(inbox_z) orelse return error.OpenDirFailed;
    defer _ = std.c.closedir(dir);

    var processed: i32 = 0;
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (entry.type != std.c.DT.REG) continue;
        if (name.len <= 4) continue;

        const ext = name[name.len - 4 ..];
        if (!std.ascii.eqlIgnoreCase(ext, ".fit")) continue;

        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ inbox_path, name });
        defer allocator.free(filepath);

        organizeFitFile(data_dir, filepath) catch |err| {
            std.debug.print("Error organizing {s}: {}\n", .{ name, err });
            continue;
        };
        processed += 1;
    }

    return processed;
}
