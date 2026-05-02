const std = @import("std");
const math = std.math;

fn readFd(fd: std.posix.fd_t, buf: []u8) usize {
    return std.posix.read(fd, buf) catch 0;
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

// GPS coordinate conversion: FIT uses semicircles (2^31 = 180 degrees)
pub const FIT_SEMICIRCLE_TO_DEGREES: f64 = 180.0 / 2147483648.0;
pub const FIT_MAX_FIELDS = 256;
pub const FIT_MAX_POWER_SAMPLES = 100000;

// FIT Global Message Numbers
const FIT_MESG_RECORD = 20;

// FIT Record Field Definition Numbers
const FIT_FIELD_POSITION_LAT: u8 = 0;
const FIT_FIELD_POSITION_LONG: u8 = 1;
const FIT_FIELD_HEART_RATE: u8 = 3;
const FIT_FIELD_CADENCE: u8 = 4;
const FIT_FIELD_POWER: u8 = 7;
const FIT_FIELD_TIMESTAMP: u8 = 253;

// FIT base types
const FIT_BASE_TYPE_ENUM: u8 = 0x00;
const FIT_BASE_TYPE_SINT8: u8 = 0x01;
const FIT_BASE_TYPE_UINT8: u8 = 0x02;
const FIT_BASE_TYPE_SINT16: u8 = 0x83;
const FIT_BASE_TYPE_UINT16: u8 = 0x84;
const FIT_BASE_TYPE_SINT32: u8 = 0x85;
const FIT_BASE_TYPE_UINT32: u8 = 0x86;
const FIT_BASE_TYPE_STRING: u8 = 0x07;
const FIT_BASE_TYPE_FLOAT32: u8 = 0x88;
const FIT_BASE_TYPE_FLOAT64: u8 = 0x89;
const FIT_BASE_TYPE_UINT8Z: u8 = 0x0A;
const FIT_BASE_TYPE_UINT16Z: u8 = 0x8B;
const FIT_BASE_TYPE_UINT32Z: u8 = 0x8C;
const FIT_BASE_TYPE_BYTE: u8 = 0x0D;
const FIT_BASE_TYPE_SINT64: u8 = 0x8E;
const FIT_BASE_TYPE_UINT64: u8 = 0x8F;
const FIT_BASE_TYPE_UINT64Z: u8 = 0x90;

pub const FitFieldDef = struct {
    field_def_num: u8,
    size: u8,
    base_type: u8,
};

pub const FitDefinition = struct {
    defined: bool = false,
    reserved: u8 = 0,
    arch: u8 = 0, // 0=little endian, 1=big endian
    global_msg_num: u16 = 0,
    num_fields: u8 = 0,
    fields: [FIT_MAX_FIELDS]FitFieldDef = undefined,
    record_size: usize = 0,
};

pub const FitPowerSample = struct {
    timestamp: u32,
    power: u16,
    has_power: bool,
    latitude: i32, // semicircles (raw FIT format)
    longitude: i32, // semicircles (raw FIT format)
    has_gps: bool,
    heart_rate: u8, // bpm (0 = invalid)
    has_heart_rate: bool,
    cadence: u8, // rpm (0 = invalid)
    has_cadence: bool,
};

pub const FitPowerData = struct {
    allocator: std.mem.Allocator = undefined,
    samples: std.ArrayList(FitPowerSample),
    max_power: u16 = 0,
    min_power: u16 = std.math.maxInt(u16),
    avg_power: f64 = 0,
    has_gps_data: bool = false,
    gps_sample_count: usize = 0,
    min_lat: f64 = 90.0,
    max_lat: f64 = -90.0,
    min_lon: f64 = 180.0,
    max_lon: f64 = -180.0,
    title: [256]u8 = std.mem.zeroes([256]u8),
    description: [2048]u8 = std.mem.zeroes([2048]u8),
    activity_type: [64]u8 = std.mem.zeroes([64]u8),
    start_time: i64 = 0,
    elapsed_time: i32 = 0,
    moving_time: i32 = 0,
    total_distance: f32 = 0,
    max_heart_rate: u8 = 0,
    avg_heart_rate: u8 = 0,
    has_heart_rate_data: bool = false,
    max_cadence: u8 = 0,
    avg_cadence: u8 = 0,
    has_cadence_data: bool = false,
    source_file: [512]u8 = std.mem.zeroes([512]u8),

    pub fn init(allocator: std.mem.Allocator) FitPowerData {
        return .{ .allocator = allocator, .samples = .empty };
    }

    pub fn deinit(self: *FitPowerData) void {
        self.samples.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Binary helpers
// ---------------------------------------------------------------------------

fn readUint16(data: []const u8, big_endian: bool) u16 {
    if (big_endian) {
        return @as(u16, data[0]) << 8 | data[1];
    }
    return @as(u16, data[1]) << 8 | data[0];
}

fn readUint32(data: []const u8, big_endian: bool) u32 {
    if (big_endian) {
        return @as(u32, data[0]) << 24 | @as(u32, data[1]) << 16 |
            @as(u32, data[2]) << 8 | data[3];
    }
    return @as(u32, data[3]) << 24 | @as(u32, data[2]) << 16 |
        @as(u32, data[1]) << 8 | data[0];
}

fn readSint32(data: []const u8, big_endian: bool) i32 {
    return @bitCast(readUint32(data, big_endian));
}

fn readFieldValue(data: []const u8, size: u8, big_endian: bool) u64 {
    return switch (size) {
        1 => data[0],
        2 => readUint16(data, big_endian),
        4 => readUint32(data, big_endian),
        8 => if (big_endian)
            (@as(u64, readUint32(data[0..4], big_endian)) << 32) | readUint32(data[4..8], big_endian)
        else
            (@as(u64, readUint32(data[4..8], big_endian)) << 32) | readUint32(data[0..4], big_endian),
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Haversine distance (meters)
// ---------------------------------------------------------------------------

fn haversineDistance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const R: f64 = 6371000.0;
    const dlat = (lat2 - lat1) * math.pi / 180.0;
    const dlon = (lon2 - lon1) * math.pi / 180.0;
    const a = math.sin(dlat / 2) * math.sin(dlat / 2) +
        math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) *
        math.sin(dlon / 2) * math.sin(dlon / 2);
    const c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a));
    return R * c;
}

// ---------------------------------------------------------------------------
// Process a single FIT record message (shared between compressed-ts and data paths)
// ---------------------------------------------------------------------------

fn processRecordMessage(
    data: *FitPowerData,
    def: *const FitDefinition,
    record_data: []const u8,
    timestamp: *u32,
) !void {
    var power: u16 = 0;
    var has_power = false;
    var latitude: i32 = 0x7FFFFFFF;
    var longitude: i32 = 0x7FFFFFFF;
    var has_gps = false;
    var heart_rate: u8 = 0;
    var has_heart_rate = false;
    var cadence: u8 = 0;
    var has_cadence = false;
    var offset: usize = 0;
    const big_endian = (def.arch == 1);

    for (def.fields[0..def.num_fields]) |field| {
        const field_data = record_data[offset .. offset + field.size];

        if (field.field_def_num == FIT_FIELD_POWER and field.size >= 2) {
            power = @truncate(readFieldValue(field_data, field.size, big_endian));
            if (power != 0xFFFF) has_power = true;
        } else if (field.field_def_num == FIT_FIELD_TIMESTAMP and field.size >= 4) {
            timestamp.* = @truncate(readFieldValue(field_data, field.size, big_endian));
        } else if (field.field_def_num == FIT_FIELD_POSITION_LAT and field.size >= 4) {
            latitude = readSint32(field_data, big_endian);
            if (latitude != 0x7FFFFFFF) has_gps = true;
        } else if (field.field_def_num == FIT_FIELD_POSITION_LONG and field.size >= 4) {
            longitude = readSint32(field_data, big_endian);
        } else if (field.field_def_num == FIT_FIELD_HEART_RATE and field.size >= 1) {
            heart_rate = @truncate(readFieldValue(field_data, field.size, big_endian));
            if (heart_rate != 0xFF and heart_rate > 0) has_heart_rate = true;
        } else if (field.field_def_num == FIT_FIELD_CADENCE and field.size >= 1) {
            cadence = @truncate(readFieldValue(field_data, field.size, big_endian));
            if (cadence != 0xFF and cadence > 0) has_cadence = true;
        }

        offset += field.size;
    }

    // Only add sample if it has at least one data stream
    if (!has_power and !has_gps and !has_heart_rate and !has_cadence) return;

    try data.samples.append(data.allocator, .{
        .timestamp = timestamp.*,
        .power = power,
        .has_power = has_power,
        .latitude = latitude,
        .longitude = longitude,
        .has_gps = has_gps,
        .heart_rate = heart_rate,
        .has_heart_rate = has_heart_rate,
        .cadence = cadence,
        .has_cadence = has_cadence,
    });

    if (has_power) {
        if (power > data.max_power) data.max_power = power;
        if (power < data.min_power) data.min_power = power;
    }
}

// ---------------------------------------------------------------------------
// Post-parse statistics for FIT files
// ---------------------------------------------------------------------------

fn calcFitStats(data: *FitPowerData) void {
    const count = data.samples.items.len;
    if (count == 0) {
        data.min_power = 0;
        return;
    }

    var total_power: u64 = 0;
    var total_hr: u64 = 0;
    var total_cadence: u64 = 0;
    var power_count: usize = 0;
    var hr_count: usize = 0;
    var cadence_count: usize = 0;

    data.min_lat = 90.0;
    data.max_lat = -90.0;
    data.min_lon = 180.0;
    data.max_lon = -180.0;
    data.max_heart_rate = 0;

    var prev_lat: f64 = 0;
    var prev_lon: f64 = 0;
    var has_prev_gps = false;

    for (data.samples.items) |sample| {
        if (sample.has_power) {
            total_power += sample.power;
            power_count += 1;
        }
        if (sample.has_gps) {
            const lat = @as(f64, @floatFromInt(sample.latitude)) * FIT_SEMICIRCLE_TO_DEGREES;
            const lon = @as(f64, @floatFromInt(sample.longitude)) * FIT_SEMICIRCLE_TO_DEGREES;
            if (lat < data.min_lat) data.min_lat = lat;
            if (lat > data.max_lat) data.max_lat = lat;
            if (lon < data.min_lon) data.min_lon = lon;
            if (lon > data.max_lon) data.max_lon = lon;
            data.gps_sample_count += 1;
            data.has_gps_data = true;

            if (has_prev_gps) {
                data.total_distance += @floatCast(haversineDistance(prev_lat, prev_lon, lat, lon));
            }
            prev_lat = lat;
            prev_lon = lon;
            has_prev_gps = true;
        }
        if (sample.has_heart_rate) {
            total_hr += sample.heart_rate;
            hr_count += 1;
            if (sample.heart_rate > data.max_heart_rate) data.max_heart_rate = sample.heart_rate;
            data.has_heart_rate_data = true;
        }
        if (sample.has_cadence) {
            if (sample.cadence > data.max_cadence) data.max_cadence = sample.cadence;
            data.has_cadence_data = true;
            if (sample.cadence > 0) {
                total_cadence += sample.cadence;
                cadence_count += 1;
            }
        }
    }

    if (power_count > 0) data.avg_power = @as(f64, @floatFromInt(total_power)) / @as(f64, @floatFromInt(power_count));
    if (hr_count > 0) data.avg_heart_rate = @truncate(total_hr / hr_count);
    if (cadence_count > 0) data.avg_cadence = @truncate(total_cadence / cadence_count);

    // Elapsed time from first/last timestamp
    // FIT timestamps are seconds since 1989-12-31 00:00:00 UTC
    const first_ts = data.samples.items[0].timestamp;
    const last_ts = data.samples.items[count - 1].timestamp;
    data.elapsed_time = @intCast(last_ts - first_ts);

    // Convert FIT timestamp to Unix timestamp (FIT epoch is 631065600 s after Unix epoch)
    data.start_time = @as(i64, first_ts) + 631065600;

    // Default activity type
    const atype = "Ride";
    @memcpy(data.activity_type[0..atype.len], atype);

    // Generate default title: "YYYY-MM-DD HH:MM Ride"
    const unix_secs: i64 = data.start_time;
    const title_str = formatTimestampTitle(unix_secs, atype);
    const tlen = std.mem.indexOfScalar(u8, &title_str, 0) orelse title_str.len;
    @memcpy(data.title[0..tlen], title_str[0..tlen]);
}

/// Format "YYYY-MM-DD HH:MM <suffix>" from a Unix timestamp (UTC).
/// Returns a fixed 256-byte buffer.
fn formatTimestampTitle(unix_secs: i64, suffix: []const u8) [256]u8 {
    var buf: [256]u8 = std.mem.zeroes([256]u8);
    // Decompose unix timestamp to calendar (UTC)
    const epoch = std.time.epoch;
    const secs_per_day = 86400;
    const days_since_epoch: i64 = @divFloor(unix_secs, secs_per_day);
    const secs_in_day: i64 = @mod(unix_secs, secs_per_day);
    const hour: i64 = @divFloor(secs_in_day, 3600);
    const minute: i64 = @divFloor(@mod(secs_in_day, 3600), 60);

    // Use std epoch helpers for date decomposition
    const epoch_day = epoch.EpochDay{ .day = @intCast(days_since_epoch) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year: u32 = year_day.year;
    const month: u32 = month_day.month.numeric();
    const day: u32 = month_day.day_index + 1;

    const written = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} {s}", .{
        year, month, day, hour, minute, suffix,
    }) catch "";
    _ = written;
    return buf;
}

// ---------------------------------------------------------------------------
// parseFitFile
// ---------------------------------------------------------------------------

pub fn parseFitFile(allocator: std.mem.Allocator, filename: []const u8) !FitPowerData {
    var fn_z_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fn_z = try std.fmt.bufPrintZ(&fn_z_buf, "{s}", .{filename});
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, fn_z, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);

    var data = FitPowerData.init(allocator);
    errdefer data.deinit();

    // Read first byte (header size)
    var first_byte: [1]u8 = undefined;
    const n1 = readFd(fd, &first_byte);
    if (n1 != 1) return error.UnexpectedEof;

    const header_size = first_byte[0];
    if (header_size != 12 and header_size != 14) {
        std.debug.print("Error: Invalid FIT header size: {d}\n", .{header_size});
        return error.InvalidFitHeader;
    }

    // Read the rest of the header into a 14-byte buffer
    var header: [14]u8 = undefined;
    header[0] = header_size;
    const n2 = readFd(fd, header[1..header_size]);
    if (n2 != header_size - 1) return error.UnexpectedEof;

    // Verify .FIT signature at bytes 8-11
    if (header[8] != '.' or header[9] != 'F' or header[10] != 'I' or header[11] != 'T') {
        std.debug.print("Error: Invalid FIT signature\n", .{});
        return error.InvalidFitSignature;
    }

    const data_size = readUint32(header[4..8], false);

    // Local message definitions (0-15)
    var definitions: [16]FitDefinition = [_]FitDefinition{.{}} ** 16;

    // Timestamp accumulator (for compressed timestamps)
    var timestamp: u32 = 0;

    var bytes_read: usize = 0;

    while (bytes_read < data_size) {
        var hdr_byte: [1]u8 = undefined;
        const hn = readFd(fd, &hdr_byte);
        if (hn != 1) break;
        bytes_read += 1;
        const record_header = hdr_byte[0];

        if (record_header & 0x80 != 0) {
            // --- Compressed timestamp header ---
            const local_msg: u8 = (record_header >> 5) & 0x03;
            const time_offset: u32 = record_header & 0x1F;

            // Update timestamp accumulator
            timestamp = (timestamp & 0xFFFFFFE0) | time_offset;
            if (time_offset < (timestamp & 0x1F)) {
                timestamp +%= 0x20;
            }

            const def = &definitions[local_msg];
            if (!def.defined) continue;

            const rec_buf = try allocator.alloc(u8, def.record_size);
            defer allocator.free(rec_buf);

            const rn = readFd(fd, rec_buf);
            if (rn != def.record_size) break;
            bytes_read += def.record_size;

            if (def.global_msg_num == FIT_MESG_RECORD) {
                try processRecordMessage(&data, def, rec_buf, &timestamp);
            }
        } else if (record_header & 0x40 != 0) {
            // --- Definition message ---
            const local_msg: u8 = record_header & 0x0F;
            const has_dev_data = (record_header & 0x20) != 0;

            var def_hdr: [5]u8 = undefined;
            const dhn = readFd(fd, &def_hdr);
            if (dhn != 5) break;
            bytes_read += 5;

            const def = &definitions[local_msg];
            def.defined = true;
            def.reserved = def_hdr[0];
            def.arch = def_hdr[1];
            def.global_msg_num = readUint16(def_hdr[2..4], def.arch == 1);
            def.num_fields = def_hdr[4];
            def.record_size = 0;

            var fi: u8 = 0;
            while (fi < def.num_fields) : (fi += 1) {
                var field_def: [3]u8 = undefined;
                const fdn = readFd(fd, &field_def);
                if (fdn != 3) break;
                bytes_read += 3;

                if (fi < FIT_MAX_FIELDS) {
                    def.fields[fi].field_def_num = field_def[0];
                    def.fields[fi].size = field_def[1];
                    def.fields[fi].base_type = field_def[2];
                }
                def.record_size += field_def[1];
            }

            // Skip developer field definitions if present
            if (has_dev_data) {
                var num_dev: [1]u8 = undefined;
                const ndn = readFd(fd, &num_dev);
                if (ndn != 1) break;
                bytes_read += 1;

                var di: u8 = 0;
                while (di < num_dev[0]) : (di += 1) {
                    var dev_field: [3]u8 = undefined;
                    const dfn = readFd(fd, &dev_field);
                    if (dfn != 3) break;
                    bytes_read += 3;
                    def.record_size += dev_field[1];
                }
            }
        } else {
            // --- Data message ---
            const local_msg: u8 = record_header & 0x0F;
            const def = &definitions[local_msg];

            if (!def.defined) {
                std.debug.print("Warning: Undefined local message {d}\n", .{local_msg});
                break;
            }

            const rec_buf = try allocator.alloc(u8, def.record_size);
            defer allocator.free(rec_buf);

            const rn = readFd(fd, rec_buf);
            if (rn != def.record_size) break;
            bytes_read += def.record_size;

            if (def.global_msg_num == FIT_MESG_RECORD) {
                try processRecordMessage(&data, def, rec_buf, &timestamp);
            }
        }
    }

    // Store source file path
    const src = filename[0..@min(filename.len, data.source_file.len - 1)];
    @memcpy(data.source_file[0..src.len], src);

    // Calculate statistics
    calcFitStats(&data);

    const count = data.samples.items.len;
    std.debug.print("Parsed {d} samples ({d} with GPS)\n", .{ count, data.gps_sample_count });
    if (data.has_gps_data) {
        std.debug.print("GPS bounds: lat [{d:.5}, {d:.5}], lon [{d:.5}, {d:.5}]\n", .{
            data.min_lat, data.max_lat, data.min_lon, data.max_lon,
        });
    }
    std.debug.print("Power range: {d} - {d} watts, average: {d:.1} watts\n", .{
        data.min_power, data.max_power, data.avg_power,
    });
    if (data.has_heart_rate_data) {
        std.debug.print("Heart rate: avg {d} bpm, max {d} bpm\n", .{
            data.avg_heart_rate, data.max_heart_rate,
        });
    }

    return data;
}

// ---------------------------------------------------------------------------
// JSON helpers (private)
// ---------------------------------------------------------------------------

/// Search for `"key"` in `json`, skip past `:`, skip whitespace, expect `"`,
/// copy the string value into `out`. Returns the slice written, or null.
fn jsonGetString(json: []const u8, key: []const u8, out: []u8) ?[]u8 {
    // Build search pattern: "key"
    var search_buf: [258]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    // Find ':'
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var p = after_key[colon + 1 ..];

    // Skip whitespace
    while (p.len > 0 and (p[0] == ' ' or p[0] == '\t' or p[0] == '\n' or p[0] == '\r')) {
        p = p[1..];
    }
    if (p.len == 0 or p[0] != '"') return null;
    p = p[1..]; // skip opening quote

    var i: usize = 0;
    while (p.len > 0 and p[0] != '"' and i < out.len - 1) {
        if (p[0] == '\\' and p.len > 1) {
            p = p[1..]; // skip backslash, copy next char raw
        }
        out[i] = p[0];
        i += 1;
        p = p[1..];
    }
    out[i] = 0;
    return out[0..i];
}

/// Search for `"key"` in `json`, skip past `:`, parse a number. Returns null if not found.
fn jsonGetNumber(json: []const u8, key: []const u8) ?f64 {
    var search_buf: [258]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var p = after_key[colon + 1 ..];

    // Skip whitespace
    while (p.len > 0 and (p[0] == ' ' or p[0] == '\t' or p[0] == '\n' or p[0] == '\r')) {
        p = p[1..];
    }
    if (p.len == 0) return null;

    return jsonParseNumberSlice(p);
}

/// Find `"key": [` in `json`, return slice starting at the `[`.
fn jsonFindArray(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [258]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var p = after_key[colon + 1 ..];

    // Skip whitespace
    while (p.len > 0 and (p[0] == ' ' or p[0] == '\t' or p[0] == '\n' or p[0] == '\r')) {
        p = p[1..];
    }
    if (p.len == 0 or p[0] != '[') return null;
    return p;
}

/// Count elements in a JSON array starting at `arr_start` (must begin with `[`).
fn jsonCountArrayElements(arr_start: []const u8) usize {
    if (arr_start.len == 0 or arr_start[0] != '[') return 0;

    const p = arr_start[1..];
    var count: usize = 0;
    var depth: usize = 1;
    var in_element = false;
    var i: usize = 0;
    while (i < p.len and depth > 0) : (i += 1) {
        const ch = p[i];
        if (ch == '[') {
            depth += 1;
            in_element = true;
        } else if (ch == ']') {
            depth -= 1;
            if (depth == 0 and in_element) count += 1;
        } else if (ch == ',' and depth == 1) {
            if (in_element) count += 1;
            in_element = false;
        } else if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') {
            in_element = true;
        }
    }
    return count;
}

/// Parse a number at the start of `p` (after skipping whitespace).
/// Returns the value and advances `p` past the number.
fn jsonParseNumber(p: *[]const u8) f64 {
    // Skip whitespace
    while (p.len > 0 and (p.*[0] == ' ' or p.*[0] == '\t' or p.*[0] == '\n' or p.*[0] == '\r')) {
        p.* = p.*[1..];
    }
    return jsonParseNumberSlice(p.*) orelse blk: {
        // Advance past any non-numeric content so we don't loop forever
        if (p.len > 0) p.* = p.*[1..];
        break :blk 0.0;
    };
}

/// Parse a floating-point number from the beginning of `s`, returning it and
/// setting `*p` to the remainder.  Returns null if no number is found.
fn jsonParseNumberSlice(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var end: usize = 0;
    // Optional leading minus
    if (s[end] == '-') end += 1;
    if (end >= s.len or (s[end] < '0' or s[end] > '9')) return null;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    if (end < s.len and s[end] == '.') {
        end += 1;
        while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    }
    if (end < s.len and (s[end] == 'e' or s[end] == 'E')) {
        end += 1;
        if (end < s.len and (s[end] == '+' or s[end] == '-')) end += 1;
        while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    }
    return std.fmt.parseFloat(f64, s[0..end]) catch null;
}

/// Parse a floating-point number at `*p`, advancing `*p` past it.
fn jsonParseNumberAdvance(p: *[]const u8) f64 {
    // Skip whitespace
    while (p.len > 0 and (p.*[0] == ' ' or p.*[0] == '\t' or p.*[0] == '\n' or p.*[0] == '\r')) {
        p.* = p.*[1..];
    }
    if (p.len == 0) return 0;
    var end: usize = 0;
    const s = p.*;
    if (s[end] == '-') end += 1;
    if (end >= s.len) return 0;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    if (end < s.len and s[end] == '.') {
        end += 1;
        while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    }
    if (end < s.len and (s[end] == 'e' or s[end] == 'E')) {
        end += 1;
        if (end < s.len and (s[end] == '+' or s[end] == '-')) end += 1;
        while (end < s.len and s[end] >= '0' and s[end] <= '9') end += 1;
    }
    const val = std.fmt.parseFloat(f64, s[0..end]) catch 0.0;
    p.* = s[end..];
    return val;
}

/// Skip to the next element in an array (past a `,` at depth 0, or stop at `]`).
fn jsonSkipToNext(p: *[]const u8) void {
    var depth: usize = 0;
    while (p.len > 0) {
        const ch = p.*[0];
        p.* = p.*[1..];
        if (ch == '[') {
            depth += 1;
        } else if (ch == ']') {
            if (depth == 0) return;
            depth -= 1;
        } else if (ch == ',' and depth == 0) {
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Parse ISO 8601 date string to Unix timestamp (UTC)
// ---------------------------------------------------------------------------

fn parseIso8601(date_str: []const u8) i64 {
    // Expected format: YYYY-MM-DDTHH:MM:SS (first 19 chars)
    if (date_str.len < 19) return 0;

    const year = std.fmt.parseInt(i32, date_str[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u32, date_str[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u32, date_str[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, date_str[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, date_str[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, date_str[17..19], 10) catch return 0;

    if (month < 1 or month > 12 or day < 1 or day > 31) return 0;

    // Days since Unix epoch (1970-01-01) using proleptic Gregorian calendar
    const y: i64 = year;
    const m: i64 = month;
    const d: i64 = day;

    // Algorithm: compute Julian Day Number then subtract Unix epoch JDN
    const a = @divFloor(14 - m, 12);
    const yy = y + 4800 - a;
    const mm = m + 12 * a - 3;
    const jdn = d + @divFloor(153 * mm + 2, 5) + 365 * yy + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400) - 32045;
    // Unix epoch JDN = 2440588 (1970-01-01)
    const days_since_epoch = jdn - 2440588;

    return days_since_epoch * 86400 + hour * 3600 + minute * 60 + second;
}

// ---------------------------------------------------------------------------
// Statistics for JSON-parsed activities
// ---------------------------------------------------------------------------

fn calcJsonStats(data: *FitPowerData) void {
    const count = data.samples.items.len;
    if (count == 0) {
        if (data.min_power == std.math.maxInt(u16)) data.min_power = 0;
        return;
    }

    var total_power: u64 = 0;
    var total_hr: u64 = 0;
    var total_cadence: u64 = 0;
    var power_count: usize = 0;
    var hr_count: usize = 0;
    var cadence_count: usize = 0;

    data.min_lat = 90.0;
    data.max_lat = -90.0;
    data.min_lon = 180.0;
    data.max_lon = -180.0;
    data.max_heart_rate = 0;
    data.max_cadence = 0;

    for (data.samples.items) |sample| {
        if (sample.has_power) {
            total_power += sample.power;
            power_count += 1;
            if (sample.power > data.max_power) data.max_power = sample.power;
            if (sample.power < data.min_power) data.min_power = sample.power;
        }
        if (sample.has_gps) {
            const lat = @as(f64, @floatFromInt(sample.latitude)) * FIT_SEMICIRCLE_TO_DEGREES;
            const lon = @as(f64, @floatFromInt(sample.longitude)) * FIT_SEMICIRCLE_TO_DEGREES;
            if (lat < data.min_lat) data.min_lat = lat;
            if (lat > data.max_lat) data.max_lat = lat;
            if (lon < data.min_lon) data.min_lon = lon;
            if (lon > data.max_lon) data.max_lon = lon;
            data.gps_sample_count += 1;
            data.has_gps_data = true;
        }
        if (sample.has_heart_rate) {
            total_hr += sample.heart_rate;
            hr_count += 1;
            if (sample.heart_rate > data.max_heart_rate) data.max_heart_rate = sample.heart_rate;
            data.has_heart_rate_data = true;
        }
        if (sample.has_cadence) {
            if (sample.cadence > data.max_cadence) data.max_cadence = sample.cadence;
            data.has_cadence_data = true;
            if (sample.cadence > 0) {
                total_cadence += sample.cadence;
                cadence_count += 1;
            }
        }
    }

    if (power_count > 0) data.avg_power = @as(f64, @floatFromInt(total_power)) / @as(f64, @floatFromInt(power_count));
    if (hr_count > 0) data.avg_heart_rate = @truncate(total_hr / hr_count);
    if (cadence_count > 0) data.avg_cadence = @truncate(total_cadence / cadence_count);

    if (data.min_power == std.math.maxInt(u16)) data.min_power = 0;
}

// ---------------------------------------------------------------------------
// parseJsonActivity
// ---------------------------------------------------------------------------

pub fn parseJsonActivity(allocator: std.mem.Allocator, filename: []const u8) !FitPowerData {
    const json_buf = try readFileFull(allocator, filename);
    defer allocator.free(json_buf);
    const json = json_buf;

    var data = FitPowerData.init(allocator);
    errdefer data.deinit();

    // Store source file path
    const src = filename[0..@min(filename.len, data.source_file.len - 1)];
    @memcpy(data.source_file[0..src.len], src);

    // Activity metadata
    _ = jsonGetString(json, "name", &data.title);
    _ = jsonGetString(json, "type", &data.activity_type);

    var start_date_buf: [64]u8 = std.mem.zeroes([64]u8);
    _ = jsonGetString(json, "start_date", &start_date_buf);
    const start_date_str = std.mem.sliceTo(&start_date_buf, 0);
    const base_timestamp = parseIso8601(start_date_str);
    data.start_time = base_timestamp;

    if (jsonGetNumber(json, "moving_time")) |v| data.moving_time = @intFromFloat(v);
    if (jsonGetNumber(json, "elapsed_time")) |v| data.elapsed_time = @intFromFloat(v);
    if (jsonGetNumber(json, "distance")) |v| data.total_distance = @floatCast(v);

    // Find streams section
    const streams_pos = std.mem.indexOf(u8, json, "\"streams\"") orelse {
        std.debug.print("Error: No streams section found in JSON\n", .{});
        return error.NoStreamsSection;
    };
    const streams = json[streams_pos..];

    // Find time array to determine sample count
    const time_arr = jsonFindArray(streams, "time") orelse {
        std.debug.print("Error: No time stream found in JSON\n", .{});
        return error.NoTimeStream;
    };

    const sample_count = jsonCountArrayElements(time_arr);
    if (sample_count == 0) {
        std.debug.print("Error: Empty time stream in JSON\n", .{});
        return error.EmptyTimeStream;
    }

    // Pre-allocate samples
    try data.samples.ensureTotalCapacity(data.allocator, sample_count);

    // Fill with zero-initialised samples
    var si: usize = 0;
    while (si < sample_count) : (si += 1) {
        try data.samples.append(data.allocator, std.mem.zeroes(FitPowerSample));
    }

    // Parse time array
    {
        var p = time_arr[1..]; // skip opening '['
        for (data.samples.items) |*sample| {
            const time_offset: i64 = @intFromFloat(jsonParseNumberAdvance(&p));
            sample.timestamp = @intCast(base_timestamp + time_offset);
            jsonSkipToNext(&p);
        }
    }

    // Parse watts array
    if (jsonFindArray(streams, "watts")) |watts_arr| {
        var p = watts_arr[1..];
        for (data.samples.items) |*sample| {
            const watts: i32 = @intFromFloat(jsonParseNumberAdvance(&p));
            if (watts > 0) {
                sample.power = @intCast(watts);
                sample.has_power = true;
            }
            jsonSkipToNext(&p);
        }
    }

    // Parse latlng array (array of [lat, lon] pairs)
    if (jsonFindArray(streams, "latlng")) |latlng_arr| {
        var p = latlng_arr[1..];
        for (data.samples.items) |*sample| {
            // Advance to opening '[' of the pair
            while (p.len > 0 and p[0] != '[') p = p[1..];
            if (p.len == 0) break;
            p = p[1..]; // skip '['

            const lat = jsonParseNumberAdvance(&p);
            // Skip to ','
            while (p.len > 0 and p[0] != ',') p = p[1..];
            if (p.len > 0) p = p[1..]; // skip ','

            const lon = jsonParseNumberAdvance(&p);

            // Skip to ']'
            while (p.len > 0 and p[0] != ']') p = p[1..];
            if (p.len > 0) p = p[1..]; // skip ']'

            // Convert decimal degrees to FIT semicircles
            sample.latitude = @intFromFloat(lat / FIT_SEMICIRCLE_TO_DEGREES);
            sample.longitude = @intFromFloat(lon / FIT_SEMICIRCLE_TO_DEGREES);
            sample.has_gps = true;

            jsonSkipToNext(&p);
        }
    }

    // Parse heartrate array
    if (jsonFindArray(streams, "heartrate")) |hr_arr| {
        var p = hr_arr[1..];
        for (data.samples.items) |*sample| {
            const hr: i32 = @intFromFloat(jsonParseNumberAdvance(&p));
            if (hr > 0 and hr < 255) {
                sample.heart_rate = @intCast(hr);
                sample.has_heart_rate = true;
            }
            jsonSkipToNext(&p);
        }
    }

    // Parse cadence array
    if (jsonFindArray(streams, "cadence")) |cad_arr| {
        var p = cad_arr[1..];
        for (data.samples.items) |*sample| {
            const cad: i32 = @intFromFloat(jsonParseNumberAdvance(&p));
            if (cad > 0 and cad < 255) {
                sample.cadence = @intCast(cad);
                sample.has_cadence = true;
            }
            jsonSkipToNext(&p);
        }
    }

    // Calculate elapsed_time from time stream if not already set
    if (data.elapsed_time == 0 and sample_count > 1) {
        var p_time = time_arr[1..];
        var last_time: i32 = 0;
        for (0..sample_count) |_| {
            last_time = @intFromFloat(jsonParseNumberAdvance(&p_time));
            jsonSkipToNext(&p_time);
        }
        data.elapsed_time = last_time;
    }

    // Use moving_time as fallback
    if (data.elapsed_time == 0 and data.moving_time > 0) {
        data.elapsed_time = data.moving_time;
    }

    // Calculate statistics
    calcJsonStats(&data);

    const count = data.samples.items.len;
    std.debug.print("Parsed {d} samples from JSON ({d} with GPS)\n", .{ count, data.gps_sample_count });
    if (data.has_gps_data) {
        std.debug.print("GPS bounds: lat [{d:.5}, {d:.5}], lon [{d:.5}, {d:.5}]\n", .{
            data.min_lat, data.max_lat, data.min_lon, data.max_lon,
        });
    }
    std.debug.print("Power range: {d} - {d} watts, average: {d:.1} watts\n", .{
        data.min_power, data.max_power, data.avg_power,
    });
    if (data.has_heart_rate_data) {
        std.debug.print("Heart rate: avg {d} bpm, max {d} bpm\n", .{
            data.avg_heart_rate, data.max_heart_rate,
        });
    }

    return data;
}
