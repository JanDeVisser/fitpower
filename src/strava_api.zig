const std = @import("std");
const curl = @cImport(@cInclude("curl/curl.h"));

const config_path = "/.config/sweattrails/strava_config";
const strava_auth_url = "https://www.strava.com/oauth/authorize";
const strava_token_url = "https://www.strava.com/oauth/token";
const strava_api_url = "https://www.strava.com/api/v3";
const callback_port: u16 = 8089;
const redirect_uri = "http://localhost:8089/callback";

pub const StravaConfig = struct {
    client_id: [32]u8 = std.mem.zeroes([32]u8),
    client_secret: [128]u8 = std.mem.zeroes([128]u8),
    access_token: [128]u8 = std.mem.zeroes([128]u8),
    refresh_token: [128]u8 = std.mem.zeroes([128]u8),
    token_expires_at: i64 = 0,
};

pub const StravaActivity = struct {
    id: i64 = 0,
    name: [256]u8 = std.mem.zeroes([256]u8),
    type: [64]u8 = std.mem.zeroes([64]u8),
    start_date: [32]u8 = std.mem.zeroes([32]u8),
    moving_time: i32 = 0,
    distance: f32 = 0,
    average_watts: f32 = 0,
    has_power: bool = false,
};

pub const StravaActivityList = struct {
    activities: std.ArrayList(StravaActivity),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StravaActivityList {
        return .{ .activities = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *StravaActivityList) void {
        self.activities.deinit(self.allocator);
    }
};

pub const StravaError = error{
    NoHomeDir,
    ConfigReadFailed,
    ConfigWriteFailed,
    MissingCredentials,
    CurlInitFailed,
    CurlRequestFailed,
    TokenParseFailed,
    NoAuthCode,
    ServerBindFailed,
    BrowserOpenFailed,
    DownloadFailed,
    OutOfMemory,
};

const CurlBuffer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CurlBuffer {
        return .{ .data = .empty, .allocator = allocator };
    }

    fn deinit(self: *CurlBuffer) void {
        self.data.deinit(self.allocator);
    }

    fn asSlice(self: *CurlBuffer) ![:0]const u8 {
        try self.data.append(self.allocator, 0);
        const full = self.data.items;
        self.data.items.len -= 1;
        return full[0..self.data.items.len :0];
    }
};

extern fn system(command: [*:0]const u8) c_int;

fn curlWriteCallback(
    contents: ?*anyopaque,
    size: usize,
    nmemb: usize,
    userp: ?*anyopaque,
) callconv(.c) usize {
    const real_size = size * nmemb;
    const buf: *CurlBuffer = @ptrCast(@alignCast(userp orelse return 0));
    const bytes: [*]const u8 = @ptrCast(contents orelse return 0);
    buf.data.appendSlice(buf.allocator, bytes[0..real_size]) catch return 0;
    return real_size;
}

fn jsonFindKey(json: []const u8, key: []const u8) ?usize {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var offset: usize = 0;
    while (std.mem.indexOf(u8, json[offset..], search)) |rel| {
        const pos = offset + rel;
        var depth: i32 = 0;
        for (json[0..pos]) |c| {
            if (c == '{') depth += 1 else if (c == '}') depth -= 1;
        }
        if (depth <= 1) return pos;
        offset = pos + 1;
    }
    return null;
}

fn jsonValueStart(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = jsonFindKey(json, key) orelse return null;

    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var rest = json[key_pos + search.len ..];
    const colon_off = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    rest = rest[colon_off..];

    var skip: usize = 0;
    while (skip < rest.len and (rest[skip] == ':' or rest[skip] == ' ' or rest[skip] == '\t')) {
        skip += 1;
    }
    return rest[skip..];
}

fn jsonGetString(json: []const u8, key: []const u8, out: []u8) bool {
    var rest = jsonValueStart(json, key) orelse return false;
    if (rest.len == 0 or rest[0] != '"') return false;
    rest = rest[1..];

    var i: usize = 0;
    var j: usize = 0;
    while (j < rest.len and rest[j] != '"' and i < out.len - 1) {
        if (rest[j] == '\\' and j + 1 < rest.len) {
            j += 1;
        }
        out[i] = rest[j];
        i += 1;
        j += 1;
    }
    out[i] = 0;
    return true;
}

fn jsonGetInt64(json: []const u8, key: []const u8) ?i64 {
    const rest = jsonValueStart(json, key) orelse return null;
    return std.fmt.parseInt(i64, trimNumber(rest), 10) catch null;
}

fn jsonGetInt(json: []const u8, key: []const u8) ?i32 {
    const v = jsonGetInt64(json, key) orelse return null;
    return @intCast(v);
}

fn jsonGetFloat(json: []const u8, key: []const u8) ?f32 {
    const rest = jsonValueStart(json, key) orelse return null;
    return std.fmt.parseFloat(f32, trimNumber(rest)) catch null;
}

fn jsonGetBool(json: []const u8, key: []const u8) ?bool {
    const rest = jsonValueStart(json, key) orelse return null;
    if (std.mem.startsWith(u8, rest, "true")) return true;
    if (std.mem.startsWith(u8, rest, "false")) return false;
    return null;
}

fn trimNumber(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len) {
        const c = s[end];
        if ((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E') {
            end += 1;
        } else break;
    }
    return s[0..end];
}

fn configFilePath(buf: []u8) ![]const u8 {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return StravaError.NoHomeDir;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, config_path });
}

fn readFileFull(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.ConfigReadFailed;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.ConfigReadFailed;
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

fn writeFd(fd: std.posix.fd_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data[written..].ptr, data.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

fn writeFdFmt(fd: std.posix.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFd(fd, s);
}

fn openFileWrite(path: []const u8) !std.posix.fd_t {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    return std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
}

pub fn loadConfig(allocator: std.mem.Allocator) !StravaConfig {
    var path_buf: [512]u8 = undefined;
    const path = try configFilePath(&path_buf);

    const json = readFileFull(allocator, path) catch return StravaError.ConfigReadFailed;
    defer allocator.free(json);

    var cfg = StravaConfig{};
    _ = jsonGetString(json, "client_id", &cfg.client_id);
    _ = jsonGetString(json, "client_secret", &cfg.client_secret);
    _ = jsonGetString(json, "access_token", &cfg.access_token);
    _ = jsonGetString(json, "refresh_token", &cfg.refresh_token);
    if (jsonGetInt64(json, "token_expires_at")) |exp| {
        cfg.token_expires_at = exp;
    }

    if (cfg.client_id[0] == 0 or cfg.client_secret[0] == 0) {
        return StravaError.MissingCredentials;
    }
    return cfg;
}

pub fn saveConfig(config: *const StravaConfig) !void {
    var path_buf: [512]u8 = undefined;
    const path = try configFilePath(&path_buf);

    const fd = openFileWrite(path) catch return StravaError.ConfigWriteFailed;
    defer _ = std.c.close(fd);

    var out_buf: [2048]u8 = undefined;
    const content = std.fmt.bufPrint(&out_buf,
        "{{\n  \"client_id\": \"{s}\",\n  \"client_secret\": \"{s}\",\n  \"access_token\": \"{s}\",\n  \"refresh_token\": \"{s}\",\n  \"token_expires_at\": {d}\n}}\n",
        .{
            std.mem.sliceTo(&config.client_id, 0),
            std.mem.sliceTo(&config.client_secret, 0),
            std.mem.sliceTo(&config.access_token, 0),
            std.mem.sliceTo(&config.refresh_token, 0),
            config.token_expires_at,
        }) catch return StravaError.ConfigWriteFailed;

    writeFd(fd, content);
}

pub fn isAuthenticated(config: *const StravaConfig) bool {
    return config.access_token[0] != 0 and config.refresh_token[0] != 0;
}

fn parseTokenResponse(json: []const u8, config: *StravaConfig) bool {
    if (!jsonGetString(json, "access_token", &config.access_token)) return false;
    if (!jsonGetString(json, "refresh_token", &config.refresh_token)) return false;
    if (jsonGetInt64(json, "expires_at")) |exp| {
        config.token_expires_at = exp;
    }
    return true;
}

fn openBrowser(url: []const u8) void {
    const builtin = @import("builtin");
    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "{s} {s}", .{
        if (builtin.os.tag == .macos) "open" else "xdg-open",
        url,
    }) catch return;
    _ = system(cmd.ptr);
}

fn oauthCallbackServer(port: u16, code_out: []u8) usize {
    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return 0;
    defer _ = std.c.close(sock);

    var one: c_int = 1;
    _ = std.c.setsockopt(sock, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    if (std.c.bind(sock, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return 0;
    if (std.c.listen(sock, 1) != 0) return 0;

    const conn = std.c.accept(sock, null, null);
    if (conn < 0) return 0;
    defer _ = std.c.close(conn);

    var req_buf: [4096]u8 = undefined;
    const n = std.c.recv(conn, &req_buf, req_buf.len, 0);
    if (n <= 0) return 0;
    const request = req_buf[0..@intCast(n)];

    var code_len: usize = 0;
    if (std.mem.indexOf(u8, request, "code=")) |code_start| {
        const after = request[code_start + 5 ..];
        var end: usize = 0;
        while (end < after.len and after[end] != '&' and after[end] != ' ' and
            after[end] != '\r' and after[end] != '\n')
        {
            end += 1;
        }
        code_len = @min(end, code_out.len - 1);
        @memcpy(code_out[0..code_len], after[0..code_len]);
        code_out[code_len] = 0;
    }

    const http_response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "<html><body><h1>Authorization successful!</h1>" ++
        "<p>You can close this window and return to sweattrails.</p></body></html>";
    _ = std.c.send(conn, http_response.ptr, http_response.len, 0);

    return code_len;
}

pub fn authenticate(config: *StravaConfig) !void {
    var auth_url_buf: [1024]u8 = undefined;
    const auth_url = try std.fmt.bufPrint(
        &auth_url_buf,
        "{s}?client_id={s}&response_type=code&redirect_uri={s}&approval_prompt=auto&scope=activity:read_all",
        .{ strava_auth_url, std.mem.sliceTo(&config.client_id, 0), redirect_uri },
    );

    std.debug.print("Opening browser for Strava authorization...\n", .{});
    std.debug.print("If the browser does not open, visit:\n{s}\n\n", .{auth_url});

    openBrowser(auth_url);

    std.debug.print("Waiting for authorization callback on port {d}...\n", .{callback_port});

    var code_buf: [256]u8 = std.mem.zeroes([256]u8);
    const code_len = oauthCallbackServer(callback_port, &code_buf);
    if (code_len == 0) return StravaError.NoAuthCode;

    std.debug.print("Got authorization code, exchanging for tokens...\n", .{});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const handle = curl.curl_easy_init() orelse return StravaError.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    var post_buf: [1024]u8 = undefined;
    const post_data = try std.fmt.bufPrint(
        &post_buf,
        "client_id={s}&client_secret={s}&code={s}&grant_type=authorization_code",
        .{
            std.mem.sliceTo(&config.client_id, 0),
            std.mem.sliceTo(&config.client_secret, 0),
            std.mem.sliceTo(&code_buf, 0),
        },
    );

    var buf = CurlBuffer.init(allocator);
    defer buf.deinit();

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, strava_token_url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, post_data.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &buf);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) return StravaError.CurlRequestFailed;

    const json = try buf.asSlice();
    if (!parseTokenResponse(json, config)) return StravaError.TokenParseFailed;

    try saveConfig(config);
    std.debug.print("Authentication successful!\n", .{});
}

pub fn refreshToken(config: *StravaConfig) !void {
    if (config.refresh_token[0] == 0) return StravaError.MissingCredentials;

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now: i64 = ts.sec;
    if (config.token_expires_at > now + 300) return;

    std.debug.print("Refreshing access token...\n", .{});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const handle = curl.curl_easy_init() orelse return StravaError.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    var post_buf: [1024]u8 = undefined;
    const post_data = try std.fmt.bufPrint(
        &post_buf,
        "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
        .{
            std.mem.sliceTo(&config.client_id, 0),
            std.mem.sliceTo(&config.client_secret, 0),
            std.mem.sliceTo(&config.refresh_token, 0),
        },
    );

    var buf = CurlBuffer.init(allocator);
    defer buf.deinit();

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, strava_token_url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, post_data.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &buf);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) return StravaError.CurlRequestFailed;

    const json = try buf.asSlice();
    if (!parseTokenResponse(json, config)) return StravaError.TokenParseFailed;

    try saveConfig(config);
}

pub fn fetchActivities(
    allocator: std.mem.Allocator,
    config: *StravaConfig,
    list: *StravaActivityList,
    page: i32,
    per_page: i32,
) !void {
    try refreshToken(config);

    const handle = curl.curl_easy_init() orelse return StravaError.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "{s}/athlete/activities?page={d}&per_page={d}",
        .{ strava_api_url, page, per_page },
    );

    var auth_buf: [256]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(
        &auth_buf,
        "Authorization: Bearer {s}",
        .{std.mem.sliceTo(&config.access_token, 0)},
    );

    var headers: ?*curl.struct_curl_slist = null;
    headers = curl.curl_slist_append(headers, auth_header.ptr);
    defer curl.curl_slist_free_all(headers);

    var buf = CurlBuffer.init(allocator);
    defer buf.deinit();

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &buf);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) return StravaError.CurlRequestFailed;

    const json = try buf.asSlice();
    try parseActivityArray(allocator, json, list);
}

fn parseActivityArray(allocator: std.mem.Allocator, json: []const u8, list: *StravaActivityList) !void {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, json, pos, '{')) |obj_start| {
        var depth: i32 = 1;
        var i = obj_start + 1;
        var in_string = false;
        while (i < json.len and depth > 0) {
            const c = json[i];
            if (c == '"' and (i == 0 or json[i - 1] != '\\')) {
                in_string = !in_string;
            } else if (!in_string) {
                if (c == '{') depth += 1 else if (c == '}') depth -= 1;
            }
            i += 1;
        }
        if (depth != 0) break;

        const obj = json[obj_start..i];

        if (jsonGetInt64(obj, "id")) |id| {
            var act = StravaActivity{ .id = id };
            _ = jsonGetString(obj, "name", &act.name);
            _ = jsonGetString(obj, "type", &act.type);
            _ = jsonGetString(obj, "start_date_local", &act.start_date);
            act.moving_time = jsonGetInt(obj, "moving_time") orelse 0;
            act.distance = jsonGetFloat(obj, "distance") orelse 0;
            act.average_watts = jsonGetFloat(obj, "average_watts") orelse 0;
            act.has_power = jsonGetBool(obj, "device_watts") orelse false;
            try list.activities.append(allocator, act);
        }

        pos = i;
    }
}

pub fn downloadActivity(
    allocator: std.mem.Allocator,
    config: *StravaConfig,
    activity_id: i64,
    output_path: []const u8,
) !void {
    try refreshToken(config);

    var auth_buf: [256]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(
        &auth_buf,
        "Authorization: Bearer {s}",
        .{std.mem.sliceTo(&config.access_token, 0)},
    );

    var activity_buf = CurlBuffer.init(allocator);
    defer activity_buf.deinit();

    {
        const handle = curl.curl_easy_init() orelse return StravaError.CurlInitFailed;
        defer curl.curl_easy_cleanup(handle);

        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "{s}/activities/{d}", .{ strava_api_url, activity_id });

        var headers: ?*curl.struct_curl_slist = null;
        headers = curl.curl_slist_append(headers, auth_header.ptr);
        defer curl.curl_slist_free_all(headers);

        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &activity_buf);

        const res = curl.curl_easy_perform(handle);
        if (res != curl.CURLE_OK) return StravaError.CurlRequestFailed;
    }

    const activity_json = try activity_buf.asSlice();

    var name_buf: [256]u8 = std.mem.zeroes([256]u8);
    var type_buf: [64]u8 = std.mem.zeroes([64]u8);
    var start_date_buf: [64]u8 = std.mem.zeroes([64]u8);
    _ = jsonGetString(activity_json, "name", &name_buf);
    _ = jsonGetString(activity_json, "type", &type_buf);
    _ = jsonGetString(activity_json, "start_date", &start_date_buf);
    const distance = jsonGetFloat(activity_json, "distance") orelse 0;
    const moving_time = jsonGetInt(activity_json, "moving_time") orelse 0;

    var streams_buf = CurlBuffer.init(allocator);
    defer streams_buf.deinit();

    {
        const handle = curl.curl_easy_init() orelse return StravaError.CurlInitFailed;
        defer curl.curl_easy_cleanup(handle);

        var url_buf: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/activities/{d}/streams?keys=time,watts,latlng,heartrate,cadence,altitude,distance&key_by_type=true",
            .{ strava_api_url, activity_id },
        );

        var headers: ?*curl.struct_curl_slist = null;
        headers = curl.curl_slist_append(headers, auth_header.ptr);
        defer curl.curl_slist_free_all(headers);

        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
        _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &streams_buf);

        const res = curl.curl_easy_perform(handle);
        if (res != curl.CURLE_OK) return StravaError.CurlRequestFailed;
    }

    const streams_json = try streams_buf.asSlice();

    const fd = openFileWrite(output_path) catch return StravaError.DownloadFailed;
    defer _ = std.c.close(fd);

    var escaped_name_buf: [512]u8 = undefined;
    const escaped_name = jsonEscapeString(std.mem.sliceTo(&name_buf, 0), &escaped_name_buf);

    writeFdFmt(fd, "{{\n", .{});
    writeFdFmt(fd, "  \"source\": \"strava\",\n", .{});
    writeFdFmt(fd, "  \"activity_id\": {d},\n", .{activity_id});
    writeFdFmt(fd, "  \"name\": \"{s}\",\n", .{escaped_name});
    writeFdFmt(fd, "  \"type\": \"{s}\",\n", .{std.mem.sliceTo(&type_buf, 0)});
    writeFdFmt(fd, "  \"start_date\": \"{s}\",\n", .{std.mem.sliceTo(&start_date_buf, 0)});
    writeFdFmt(fd, "  \"distance\": {d:.1},\n", .{distance});
    writeFdFmt(fd, "  \"moving_time\": {d},\n", .{moving_time});
    writeFdFmt(fd, "  \"streams\": {{\n", .{});

    const stream_keys = [_][]const u8{ "time", "watts", "latlng", "heartrate", "cadence", "altitude", "distance" };
    var first_stream = true;

    for (stream_keys) |key| {
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch continue;
        const stream_pos = std.mem.indexOf(u8, streams_json, search) orelse continue;

        const after_stream = streams_json[stream_pos..];
        const data_pos = std.mem.indexOf(u8, after_stream, "\"data\"") orelse continue;
        const after_data = after_stream[data_pos..];
        const arr_start_off = std.mem.indexOfScalar(u8, after_data, '[') orelse continue;
        const arr_start = arr_start_off + 1;

        var depth: i32 = 1;
        var j = arr_start;
        while (j < after_data.len and depth > 0) {
            if (after_data[j] == '[') depth += 1 else if (after_data[j] == ']') depth -= 1;
            j += 1;
        }
        if (depth != 0) continue;

        const arr_content = after_data[arr_start_off..j];

        if (!first_stream) writeFdFmt(fd, ",\n", .{});
        first_stream = false;
        writeFdFmt(fd, "    \"{s}\": {s}", .{ key, arr_content });
    }

    writeFdFmt(fd, "\n  }}\n", .{});
    writeFdFmt(fd, "}}\n", .{});

    std.debug.print("Downloaded activity to: {s}\n", .{output_path});
}

fn jsonEscapeString(src: []const u8, dest: []u8) []u8 {
    var j: usize = 0;
    for (src) |c| {
        if (j >= dest.len - 2) break;
        if (c == '"' or c == '\\') {
            dest[j] = '\\';
            j += 1;
        }
        dest[j] = c;
        j += 1;
    }
    return dest[0..j];
}
