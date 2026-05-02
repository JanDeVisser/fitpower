const std = @import("std");
const builtin = @import("builtin");

const garmin_config_path = "/.config/sweattrails/garmin_config";
const garmin_tokens_dir = "/.config/sweattrails/garmin_tokens";

// ── libc shims not exposed by std.c ──────────────────────────────────────────
const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: *anyopaque, size: usize, count: usize, stream: *FILE) usize;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// ── Public types ─────────────────────────────────────────────────────────────

pub const GarminConfig = struct {
    email: [256]u8 = std.mem.zeroes([256]u8),
    password: [256]u8 = std.mem.zeroes([256]u8),
};

pub const GarminActivity = struct {
    id: i64 = 0,
    name: [256]u8 = std.mem.zeroes([256]u8),
    type: [64]u8 = std.mem.zeroes([64]u8),
    start_time: [32]u8 = std.mem.zeroes([32]u8),
    duration: f32 = 0,
    distance: f32 = 0,
};

pub const GarminActivityList = struct {
    allocator: std.mem.Allocator,
    activities: std.ArrayList(GarminActivity),

    pub fn init(allocator: std.mem.Allocator) GarminActivityList {
        return .{ .allocator = allocator, .activities = .empty };
    }

    pub fn deinit(self: *GarminActivityList) void {
        self.activities.deinit(self.allocator);
    }
};

// ── Errors ───────────────────────────────────────────────────────────────────

pub const GarminError = error{
    HelperNotFound,
    HelperFailed,
    AuthFailed,
    ParseError,
    HomeNotSet,
    DownloadFailed,
};

// ── Minimal JSON helpers ──────────────────────────────────────────────────────

fn jsonFindKey(json: []const u8, key: []const u8) ?usize {
    var search_buf: [258]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, json, start, search)) |pos| {
        var depth: i32 = 0;
        for (json[0..pos]) |ch| {
            if (ch == '{') depth += 1 else if (ch == '}') depth -= 1;
        }
        if (depth <= 1) return pos;
        start = pos + 1;
    }
    return null;
}

fn jsonGetString(json: []const u8, key: []const u8, out: []u8) ?[]u8 {
    const key_pos = jsonFindKey(json, key) orelse return null;

    const after_key = key_pos + key.len + 2;
    const colon_rel = std.mem.indexOfScalar(u8, json[after_key..], ':') orelse return null;
    var pos = after_key + colon_rel + 1;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;

    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;

    var i: usize = 0;
    while (pos < json.len and json[pos] != '"' and i < out.len - 1) {
        if (json[pos] == '\\' and pos + 1 < json.len) {
            pos += 1;
        }
        out[i] = json[pos];
        i += 1;
        pos += 1;
    }
    out[i] = 0;
    return out[0..i];
}

fn jsonGetInt64(json: []const u8, key: []const u8) ?i64 {
    const key_pos = jsonFindKey(json, key) orelse return null;
    const after_key = key_pos + key.len + 2;
    const colon_rel = std.mem.indexOfScalar(u8, json[after_key..], ':') orelse return null;
    var pos = after_key + colon_rel + 1;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;

    var end = pos;
    if (end < json.len and (json[end] == '-' or json[end] == '+')) end += 1;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;

    if (end == pos) return null;
    return std.fmt.parseInt(i64, json[pos..end], 10) catch null;
}

fn jsonGetFloat(json: []const u8, key: []const u8) ?f32 {
    const key_pos = jsonFindKey(json, key) orelse return null;
    const after_key = key_pos + key.len + 2;
    const colon_rel = std.mem.indexOfScalar(u8, json[after_key..], ':') orelse return null;
    var pos = after_key + colon_rel + 1;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;

    var end = pos;
    if (end < json.len and (json[end] == '-' or json[end] == '+')) end += 1;
    while (end < json.len) {
        const ch = json[end];
        if ((ch >= '0' and ch <= '9') or ch == '.' or ch == 'e' or ch == 'E' or
            ((ch == '+' or ch == '-') and end > pos))
        {
            end += 1;
        } else break;
    }

    if (end == pos) return null;
    return std.fmt.parseFloat(f32, json[pos..end]) catch null;
}

fn responseOk(json: []const u8) bool {
    var buf: [32]u8 = undefined;
    const val = jsonGetString(json, "status", &buf) orelse return false;
    return std.mem.eql(u8, val, "ok");
}

// ── Helper utilities ──────────────────────────────────────────────────────────

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

fn createDirectoryPath(path: []const u8) !void {
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

// ── Helper discovery ──────────────────────────────────────────────────────────

pub fn findHelper(buf: []u8) ![]u8 {
    const helper_name = "garmin_helper.py";

    if (builtin.os.tag == .linux) {
        var exe_buf: [512]u8 = undefined;
        var link_z: [16:0]u8 = undefined;
        @memcpy(link_z[0..14], "/proc/self/exe");
        link_z[14] = 0;
        const n = std.posix.readlinkZ(&link_z, &exe_buf) catch 0;
        if (n > 0) {
            const ep = exe_buf[0..n];
            if (std.mem.lastIndexOfScalar(u8, ep, '/')) |slash| {
                const candidate = std.fmt.bufPrint(buf, "{s}/{s}", .{ ep[0..slash], helper_name }) catch return GarminError.HelperNotFound;
                if (fileExists(candidate)) return candidate;
            }
        }
    } else if (builtin.os.tag == .macos) {
        var exe_buf: [512]u8 = undefined;
        var exe_len: u32 = @intCast(exe_buf.len);
        const rc = _NSGetExecutablePath(&exe_buf, &exe_len);
        if (rc == 0) {
            const ep = std.mem.sliceTo(&exe_buf, 0);
            if (std.mem.lastIndexOfScalar(u8, ep, '/')) |slash| {
                const candidate = std.fmt.bufPrint(buf, "{s}/{s}", .{ ep[0..slash], helper_name }) catch return GarminError.HelperNotFound;
                if (fileExists(candidate)) return candidate;
            }
        }
    }

    var cwd_buf: [512]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return GarminError.HelperNotFound;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);
    const candidate = std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd, helper_name }) catch return GarminError.HelperNotFound;
    if (fileExists(candidate)) return candidate;

    return GarminError.HelperNotFound;
}

extern fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

// ── Helper runner ─────────────────────────────────────────────────────────────

fn runHelper(
    allocator: std.mem.Allocator,
    config: ?*const GarminConfig,
    args: []const []const u8,
) ![]u8 {
    var helper_buf: [512]u8 = undefined;
    const helper_path = try findHelper(&helper_buf);

    if (config) |cfg| {
        const email = std.mem.sliceTo(&cfg.email, 0);
        const password = std.mem.sliceTo(&cfg.password, 0);
        if (email.len > 0 and password.len > 0) {
            var email_z: [257]u8 = std.mem.zeroes([257]u8);
            var pass_z: [257]u8 = std.mem.zeroes([257]u8);
            @memcpy(email_z[0..email.len], email);
            @memcpy(pass_z[0..password.len], password);
            _ = setenv("GARMIN_EMAIL", @ptrCast(&email_z), 1);
            _ = setenv("GARMIN_PASSWORD", @ptrCast(&pass_z), 1);
        }
    }

    var cmd_buf: [4096]u8 = undefined;
    var cmd_pos: usize = 0;

    const p1 = std.fmt.bufPrint(cmd_buf[cmd_pos..], "python3 {s}", .{helper_path}) catch return GarminError.HelperFailed;
    cmd_pos += p1.len;

    for (args) |a| {
        const p = std.fmt.bufPrint(cmd_buf[cmd_pos..], " {s}", .{a}) catch return GarminError.HelperFailed;
        cmd_pos += p.len;
    }

    if (cmd_pos >= cmd_buf.len) return GarminError.HelperFailed;
    cmd_buf[cmd_pos] = 0;

    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);
    const pipe = popen(cmd_z, "r") orelse return GarminError.HelperFailed;
    defer _ = pclose(pipe);

    var chunks: std.ArrayList([]u8) = .empty;
    defer {
        for (chunks.items) |chunk| allocator.free(chunk);
        chunks.deinit(allocator);
    }

    var total: usize = 0;
    while (true) {
        const chunk = try allocator.alloc(u8, 4096);
        const n = fread(chunk.ptr, 1, 4096, pipe);
        if (n == 0) {
            allocator.free(chunk);
            break;
        }
        try chunks.append(allocator, chunk[0..n]);
        total += n;
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

// ── Public API ────────────────────────────────────────────────────────────────

pub fn loadConfig(allocator: std.mem.Allocator) !GarminConfig {
    const home_ptr = std.c.getenv("HOME") orelse return GarminError.HomeNotSet;
    const home = std.mem.span(home_ptr);

    const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, garmin_config_path });
    defer allocator.free(path);

    const json = readFileFull(allocator, path) catch return error.FileNotFound;
    defer allocator.free(json);

    var cfg = GarminConfig{};
    _ = jsonGetString(json, "email", &cfg.email);
    _ = jsonGetString(json, "password", &cfg.password);

    return cfg;
}

pub fn saveConfig(config: *const GarminConfig) !void {
    const home_ptr = std.c.getenv("HOME") orelse return GarminError.HomeNotSet;
    const home = std.mem.span(home_ptr);

    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/sweattrails", .{home}) catch return error.NameTooLong;
    try createDirectoryPath(dir_path);

    var file_path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}{s}", .{ home, garmin_config_path }) catch return error.NameTooLong;

    var fp_z_buf: [512]u8 = undefined;
    const fp_z = std.fmt.bufPrintZ(&fp_z_buf, "{s}", .{file_path}) catch return error.NameTooLong;
    const fd = try std.posix.openatZ(std.posix.AT.FDCWD, fp_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    defer _ = std.c.close(fd);

    const email = std.mem.sliceTo(&config.email, 0);
    const password = std.mem.sliceTo(&config.password, 0);

    var out_buf: [1024]u8 = undefined;
    const content = try std.fmt.bufPrint(&out_buf,
        "{{\n  \"email\": \"{s}\",\n  \"password\": \"{s}\"\n}}\n",
        .{ email, password },
    );
    var written: usize = 0;
    while (written < content.len) {
        const n = std.c.write(fd, content[written..].ptr, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn isAuthenticated(allocator: std.mem.Allocator) bool {
    const output = runHelper(allocator, null, &.{"check"}) catch return false;
    defer allocator.free(output);
    return responseOk(output);
}

pub fn authenticate(allocator: std.mem.Allocator, config: *const GarminConfig) !void {
    const email = std.mem.sliceTo(&config.email, 0);
    const password = std.mem.sliceTo(&config.password, 0);
    if (email.len == 0 or password.len == 0) return GarminError.AuthFailed;

    const output = try runHelper(allocator, config, &.{"login_env"});
    defer allocator.free(output);

    if (!responseOk(output)) return GarminError.AuthFailed;
}

pub fn fetchActivities(allocator: std.mem.Allocator, list: *GarminActivityList, limit: i32) !void {
    var limit_buf: [32]u8 = undefined;
    const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});

    const output = try runHelper(allocator, null, &.{ "list", limit_str });
    defer allocator.free(output);

    if (!responseOk(output)) return GarminError.HelperFailed;

    const arr_key = "\"activities\"";
    const arr_key_pos = std.mem.indexOf(u8, output, arr_key) orelse return GarminError.ParseError;
    const after_key = arr_key_pos + arr_key.len;
    const bracket_rel = std.mem.indexOfScalar(u8, output[after_key..], '[') orelse return GarminError.ParseError;
    var pos = after_key + bracket_rel + 1;

    while (pos < output.len) {
        const obj_start_rel = std.mem.indexOfScalar(u8, output[pos..], '{') orelse break;
        const obj_start = pos + obj_start_rel;

        var depth: usize = 1;
        var obj_end = obj_start + 1;
        while (obj_end < output.len and depth > 0) {
            if (output[obj_end] == '{') depth += 1 else if (output[obj_end] == '}') depth -= 1;
            obj_end += 1;
        }

        const obj = output[obj_start..obj_end];

        var act = GarminActivity{};
        if (jsonGetInt64(obj, "id")) |id| act.id = id;
        _ = jsonGetString(obj, "name", &act.name);
        _ = jsonGetString(obj, "type", &act.type);
        _ = jsonGetString(obj, "start_time", &act.start_time);
        if (jsonGetFloat(obj, "duration")) |d| act.duration = d;
        if (jsonGetFloat(obj, "distance")) |d| act.distance = d;

        try list.activities.append(list.allocator, act);
        pos = obj_end;
    }
}

pub fn downloadFit(allocator: std.mem.Allocator, activity_id: i64, output_path: []const u8) !void {
    var id_buf: [32]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{activity_id});

    const output = try runHelper(allocator, null, &.{ "download", id_str, output_path });
    defer allocator.free(output);

    if (!responseOk(output)) return GarminError.DownloadFailed;
}

pub fn disconnect() !void {
    const home_ptr = std.c.getenv("HOME") orelse return GarminError.HomeNotSet;
    const home = std.mem.span(home_ptr);

    var session_buf: [512]u8 = undefined;
    const session_z = std.fmt.bufPrintZ(&session_buf, "{s}{s}/session.pkl", .{ home, garmin_tokens_dir }) catch return error.NameTooLong;
    const rc_unlink = std.c.unlink(session_z);
    if (rc_unlink != 0) {
        const err = std.c.errno(rc_unlink);
        if (err != .NOENT) return error.UnlinkFailed;
    }

    var tokens_buf: [512]u8 = undefined;
    const tokens_z = std.fmt.bufPrintZ(&tokens_buf, "{s}{s}", .{ home, garmin_tokens_dir }) catch return error.NameTooLong;
    const rc_rmdir = std.c.rmdir(tokens_z);
    if (rc_rmdir != 0) {
        const err = std.c.errno(rc_rmdir);
        if (err != .NOENT and err != .NOTEMPTY) return error.RmdirFailed;
    }
}
