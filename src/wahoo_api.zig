const std = @import("std");

const curl = @cImport(@cInclude("curl/curl.h"));
const ssl = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/evp.h");
});

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const WAHOO_CONFIG_PATH = "/.config/sweattrails/wahoo_config";
const WAHOO_AUTH_URL = "https://api.wahooligan.com/oauth/authorize";
const WAHOO_TOKEN_URL = "https://api.wahooligan.com/oauth/token";
const WAHOO_API_URL = "https://api.wahooligan.com/v1";
const CALLBACK_PORT: u16 = 8090;
const REDIRECT_URI = "https://localhost:8090/callback";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const WahooError = error{
    NoHome,
    ConfigReadFailed,
    ConfigWriteFailed,
    NotAuthenticated,
    SslContextFailed,
    CertLoadFailed,
    KeyLoadFailed,
    SocketFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    SslHandshakeFailed,
    NoAuthCode,
    CurlFailed,
    TokenParseFailed,
    FileOpenFailed,
    NoFitUrl,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Exported types
// ---------------------------------------------------------------------------

pub const WahooConfig = struct {
    client_id: [64]u8 = std.mem.zeroes([64]u8),
    client_secret: [128]u8 = std.mem.zeroes([128]u8),
    access_token: [256]u8 = std.mem.zeroes([256]u8),
    refresh_token: [256]u8 = std.mem.zeroes([256]u8),
    token_expires_at: i64 = 0,
};

pub const WahooWorkout = struct {
    id: i64 = 0,
    name: [256]u8 = std.mem.zeroes([256]u8),
    starts: [32]u8 = std.mem.zeroes([32]u8),
    minutes: i32 = 0,
    distance_meters: f32 = 0,
    ascent_meters: f32 = 0,
    avg_heart_rate: i32 = 0,
    avg_power: i32 = 0,
    fit_file_url: [512]u8 = std.mem.zeroes([512]u8),
};

pub const WahooWorkoutList = struct {
    workouts: std.ArrayList(WahooWorkout),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WahooWorkoutList {
        return .{ .workouts = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *WahooWorkoutList) void {
        self.workouts.deinit(self.allocator);
    }
};

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

// ---------------------------------------------------------------------------
// JSON parsing helpers
// ---------------------------------------------------------------------------

/// Returns the index of the first occurrence of `"key"` at nesting depth <= 1.
fn jsonFindKey(json: []const u8, key: []const u8) ?usize {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    var pos: usize = 0;
    while (pos < json.len) {
        const found = std.mem.indexOf(u8, json[pos..], search) orelse return null;
        const abs = pos + found;

        // Count braces before this position to determine depth
        var depth: i32 = 0;
        for (json[0..abs]) |c| {
            if (c == '{') depth += 1 else if (c == '}') depth -= 1;
        }
        if (depth <= 1) return abs;

        pos = abs + 1;
    }
    return null;
}

/// Extract the string value for `key` from `json` into `out`. Returns the
/// written slice on success, or null on failure.
fn jsonGetString(json: []const u8, key: []const u8, out: []u8) ?[]u8 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = jsonFindKey(json, key) orelse return null;
    const after_key = json[key_pos + search.len ..];

    const colon_off = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var rest = after_key[colon_off..];

    // Skip ':' and whitespace
    var skip: usize = 0;
    while (skip < rest.len and (rest[skip] == ':' or rest[skip] == ' ' or rest[skip] == '\t')) {
        skip += 1;
    }
    rest = rest[skip..];

    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];

    var i: usize = 0;
    var pi: usize = 0;
    while (pi < rest.len and rest[pi] != '"' and i < out.len - 1) {
        if (rest[pi] == '\\' and pi + 1 < rest.len) {
            pi += 1;
        }
        out[i] = rest[pi];
        i += 1;
        pi += 1;
    }
    out[i] = 0;
    return out[0..i];
}

fn jsonGetInt64(json: []const u8, key: []const u8) ?i64 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = jsonFindKey(json, key) orelse return null;
    const after_key = json[key_pos + search.len ..];

    const colon_off = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var rest = after_key[colon_off..];

    var skip: usize = 0;
    while (skip < rest.len and (rest[skip] == ':' or rest[skip] == ' ' or rest[skip] == '\t')) {
        skip += 1;
    }
    rest = rest[skip..];

    // Find end of number
    var end: usize = 0;
    if (end < rest.len and (rest[end] == '-' or rest[end] == '+')) end += 1;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;

    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
}

fn jsonGetInt(json: []const u8, key: []const u8) ?i32 {
    const v = jsonGetInt64(json, key) orelse return null;
    return @intCast(v);
}

fn jsonGetFloat(json: []const u8, key: []const u8) ?f32 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = jsonFindKey(json, key) orelse return null;
    const after_key = json[key_pos + search.len ..];

    const colon_off = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var rest = after_key[colon_off..];

    var skip: usize = 0;
    while (skip < rest.len and (rest[skip] == ':' or rest[skip] == ' ' or rest[skip] == '\t')) {
        skip += 1;
    }
    rest = rest[skip..];

    // Find end of float token
    var end: usize = 0;
    if (end < rest.len and (rest[end] == '-' or rest[end] == '+')) end += 1;
    while (end < rest.len and ((rest[end] >= '0' and rest[end] <= '9') or rest[end] == '.' or rest[end] == 'e' or rest[end] == 'E' or rest[end] == '-' or rest[end] == '+')) {
        end += 1;
    }
    if (end == 0) return null;

    return std.fmt.parseFloat(f32, rest[0..end]) catch null;
}

// ---------------------------------------------------------------------------
// Nested JSON helpers (for workout_summary / file objects)
// ---------------------------------------------------------------------------

/// Find the nested object under `obj_key` and return the slice starting at its
/// opening brace. The caller can then call the flat helpers on that slice.
fn jsonFindNestedObject(json: []const u8, obj_key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{obj_key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];
    const brace_off = std.mem.indexOfScalar(u8, after_key, '{') orelse return null;
    return after_key[brace_off..];
}

pub fn jsonGetNestedString(json: []const u8, obj_key: []const u8, field_key: []const u8, out: []u8) ?[]u8 {
    const obj = jsonFindNestedObject(json, obj_key) orelse return null;
    return jsonGetString(obj, field_key, out);
}

pub fn jsonGetNestedFloat(json: []const u8, obj_key: []const u8, field_key: []const u8) ?f32 {
    const obj = jsonFindNestedObject(json, obj_key) orelse return null;
    return jsonGetFloat(obj, field_key);
}

pub fn jsonGetNestedInt(json: []const u8, obj_key: []const u8, field_key: []const u8) ?i32 {
    const obj = jsonFindNestedObject(json, obj_key) orelse return null;
    return jsonGetInt(obj, field_key);
}

// ---------------------------------------------------------------------------
// curl write-callback and buffer
// ---------------------------------------------------------------------------

const CurlBuffer = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CurlBuffer {
        return .{ .data = .empty, .allocator = allocator };
    }

    fn deinit(self: *CurlBuffer) void {
        self.data.deinit(self.allocator);
    }

    fn slice(self: *const CurlBuffer) [:0]const u8 {
        if (self.data.items.len == 0) return ""[0..0 :0];
        return self.data.items[0 .. self.data.items.len - 1 :0];
    }
};

extern fn system(command: [*:0]const u8) c_int;

fn curlWriteCallback(contents: ?*anyopaque, size: usize, nmemb: usize, userp: ?*anyopaque) callconv(.c) usize {
    const realsize = size * nmemb;
    const buf: *CurlBuffer = @ptrCast(@alignCast(userp orelse return 0));
    const src: [*]const u8 = @ptrCast(contents orelse return 0);

    if (buf.data.items.len > 0 and buf.data.items[buf.data.items.len - 1] == 0) {
        buf.data.items.len -= 1;
    }
    buf.data.appendSlice(buf.allocator, src[0..realsize]) catch return 0;
    buf.data.append(buf.allocator, 0) catch return 0;

    return realsize;
}

// ---------------------------------------------------------------------------
// Token response parsing
// ---------------------------------------------------------------------------

fn parseTokenResponse(json: []const u8, config: *WahooConfig) bool {
    if (jsonGetString(json, "access_token", &config.access_token) == null) return false;
    if (jsonGetString(json, "refresh_token", &config.refresh_token) == null) return false;

    if (jsonGetInt(json, "expires_in")) |expires_in| {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        config.token_expires_at = ts.sec + @as(i64, expires_in);
    }

    return true;
}

// ---------------------------------------------------------------------------
// SSL context helpers
// ---------------------------------------------------------------------------

fn createSslContextWithCert() WahooError!*ssl.SSL_CTX {
    const ctx = ssl.SSL_CTX_new(ssl.TLS_server_method()) orelse {
        std.debug.print("Failed to create SSL context\n", .{});
        return WahooError.SslContextFailed;
    };
    errdefer ssl.SSL_CTX_free(ctx);

    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else {
        std.debug.print("HOME not set\n", .{});
        return WahooError.NoHome;
    };

    var cert_buf: [512]u8 = undefined;
    var key_buf: [512]u8 = undefined;
    const cert_path = std.fmt.bufPrintZ(&cert_buf, "{s}/.config/sweattrails/certs/localhost+1.pem", .{home}) catch return WahooError.SslContextFailed;
    const key_path = std.fmt.bufPrintZ(&key_buf, "{s}/.config/sweattrails/certs/localhost+1-key.pem", .{home}) catch return WahooError.SslContextFailed;

    if (ssl.SSL_CTX_use_certificate_file(ctx, cert_path.ptr, ssl.SSL_FILETYPE_PEM) <= 0) {
        std.debug.print("Failed to load certificate from {s}\n", .{cert_path});
        std.debug.print("Run: mkcert -install && mkdir -p ~/.config/sweattrails/certs && " ++
            "cd ~/.config/sweattrails/certs && mkcert localhost 127.0.0.1\n", .{});
        return WahooError.CertLoadFailed;
    }

    if (ssl.SSL_CTX_use_PrivateKey_file(ctx, key_path.ptr, ssl.SSL_FILETYPE_PEM) <= 0) {
        std.debug.print("Failed to load private key from {s}\n", .{key_path});
        return WahooError.KeyLoadFailed;
    }

    return ctx;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn loadConfig(allocator: std.mem.Allocator) !WahooConfig {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return WahooError.NoHome;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, WAHOO_CONFIG_PATH }) catch return WahooError.ConfigReadFailed;

    const json = readFileFull(allocator, path) catch return WahooError.ConfigReadFailed;
    defer allocator.free(json);

    var config = WahooConfig{};
    _ = jsonGetString(json, "client_id", &config.client_id);
    _ = jsonGetString(json, "client_secret", &config.client_secret);
    _ = jsonGetString(json, "access_token", &config.access_token);
    _ = jsonGetString(json, "refresh_token", &config.refresh_token);

    if (jsonGetInt64(json, "token_expires_at")) |exp| {
        config.token_expires_at = exp;
    }

    if (config.client_id[0] == 0 or config.client_secret[0] == 0) {
        return WahooError.ConfigReadFailed;
    }

    return config;
}

pub fn saveConfig(config: *const WahooConfig) !void {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return WahooError.NoHome;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, WAHOO_CONFIG_PATH }) catch return WahooError.ConfigWriteFailed;

    var path_z_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch return WahooError.ConfigWriteFailed;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{
        .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true,
    }, 0o644) catch return WahooError.ConfigWriteFailed;
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
        }) catch return WahooError.ConfigWriteFailed;
    var written: usize = 0;
    while (written < content.len) {
        const n = std.c.write(fd, content[written..].ptr, content.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

pub fn isAuthenticated(config: *const WahooConfig) bool {
    return config.access_token[0] != 0 and config.refresh_token[0] != 0;
}

pub fn authenticate(allocator: std.mem.Allocator, config: *WahooConfig) !void {
    var auth_url_buf: [1024]u8 = undefined;
    const auth_url = std.fmt.bufPrintZ(
        &auth_url_buf,
        "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope=user_read%20workouts_read",
        .{ WAHOO_AUTH_URL, std.mem.sliceTo(&config.client_id, 0), REDIRECT_URI },
    ) catch return WahooError.SslContextFailed;

    std.debug.print("Opening browser for Wahoo authorization...\n", .{});
    std.debug.print("If browser doesn't open, visit:\n{s}\n\n", .{auth_url});

    // Initialise OpenSSL (1.1+ auto-initialises; explicit call for 1.0 compat)
    _ = ssl.OPENSSL_init_ssl(0, null);

    const ssl_ctx = try createSslContextWithCert();
    defer ssl.SSL_CTX_free(ssl_ctx);

    // Open browser
    var cmd_buf: [1200]u8 = undefined;
    const open_cmd = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "{s} '{s}'", .{ open_cmd, auth_url }) catch return WahooError.SslContextFailed;
    _ = system(cmd.ptr);

    // Create listening socket
    const server_fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (server_fd < 0) return WahooError.SocketFailed;
    defer _ = std.c.close(server_fd);

    var opt: c_int = 1;
    _ = std.c.setsockopt(server_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &opt, @sizeOf(c_int));

    const addr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, CALLBACK_PORT),
        .addr = 0,
        .zero = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    if (std.c.bind(server_fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return WahooError.BindFailed;
    if (std.c.listen(server_fd, 1) != 0) return WahooError.ListenFailed;

    std.debug.print("Waiting for authorization callback on port {d} (HTTPS)...\n", .{CALLBACK_PORT});

    const client_fd = std.c.accept(server_fd, null, null);
    if (client_fd < 0) return WahooError.AcceptFailed;
    defer _ = std.c.close(client_fd);

    // Wrap the accepted connection with SSL
    const ssl_conn = ssl.SSL_new(ssl_ctx) orelse return WahooError.SslContextFailed;
    defer ssl.SSL_free(ssl_conn);

    _ = ssl.SSL_set_fd(ssl_conn, client_fd);

    if (ssl.SSL_accept(ssl_conn) <= 0) {
        std.debug.print("SSL handshake failed\n", .{});
        return WahooError.SslHandshakeFailed;
    }

    // Read the HTTP request
    var request: [4096]u8 = std.mem.zeroes([4096]u8);
    _ = ssl.SSL_read(ssl_conn, &request, request.len - 1);

    // Extract authorization code from the request line
    var code: [256]u8 = std.mem.zeroes([256]u8);
    if (std.mem.indexOf(u8, &request, "code=")) |code_start_off| {
        const code_start = code_start_off + 5;
        const request_slice = request[code_start..];
        var code_end: usize = 0;
        while (code_end < request_slice.len) {
            const c = request_slice[code_end];
            if (c == '&' or c == ' ' or c == '\r' or c == '\n') break;
            code_end += 1;
        }
        const code_len = @min(code_end, code.len - 1);
        @memcpy(code[0..code_len], request_slice[0..code_len]);
        code[code_len] = 0;
    }

    // Send success response to the browser
    const http_response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "<html><body><h1>Wahoo Authorization successful!</h1>" ++
        "<p>You can close this window and return to Sweattrails.</p></body></html>";
    _ = ssl.SSL_write(ssl_conn, http_response, http_response.len);
    _ = ssl.SSL_shutdown(ssl_conn);

    if (code[0] == 0) {
        std.debug.print("No authorization code received\n", .{});
        return WahooError.NoAuthCode;
    }

    std.debug.print("Got authorization code, exchanging for tokens...\n", .{});

    // Exchange the authorization code for tokens
    const handle = curl.curl_easy_init() orelse return WahooError.CurlFailed;
    defer curl.curl_easy_cleanup(handle);

    var post_buf: [1024]u8 = undefined;
    const post_data = std.fmt.bufPrintZ(
        &post_buf,
        "client_id={s}&client_secret={s}&code={s}&grant_type=authorization_code&redirect_uri={s}",
        .{
            std.mem.sliceTo(&config.client_id, 0),
            std.mem.sliceTo(&config.client_secret, 0),
            std.mem.sliceTo(&code, 0),
            REDIRECT_URI,
        },
    ) catch return WahooError.CurlFailed;

    var buf = CurlBuffer.init(allocator);
    defer buf.deinit();
    // Prime with a null terminator so slice() is always valid
    try buf.data.append(buf.allocator, 0);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, WAHOO_TOKEN_URL.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, post_data.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &buf);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) {
        std.debug.print("Token exchange failed: {s}\n", .{curl.curl_easy_strerror(res)});
        return WahooError.CurlFailed;
    }

    if (!parseTokenResponse(buf.slice(), config)) {
        return WahooError.TokenParseFailed;
    }

    try saveConfig(config);
    std.debug.print("Wahoo authentication successful!\n", .{});
}

pub fn refreshToken(allocator: std.mem.Allocator, config: *WahooConfig) !void {
    if (config.refresh_token[0] == 0) return WahooError.NotAuthenticated;

    // Skip refresh if token is still valid (with 5-minute buffer)
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now: i64 = ts.sec;
    if (config.token_expires_at > now + 300) return;

    std.debug.print("Refreshing Wahoo access token...\n", .{});

    const handle = curl.curl_easy_init() orelse return WahooError.CurlFailed;
    defer curl.curl_easy_cleanup(handle);

    var post_buf: [1024]u8 = undefined;
    const post_data = std.fmt.bufPrintZ(
        &post_buf,
        "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
        .{
            std.mem.sliceTo(&config.client_id, 0),
            std.mem.sliceTo(&config.client_secret, 0),
            std.mem.sliceTo(&config.refresh_token, 0),
        },
    ) catch return WahooError.CurlFailed;

    var buf = CurlBuffer.init(allocator);
    defer buf.deinit();
    try buf.data.append(buf.allocator, 0);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, WAHOO_TOKEN_URL.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_POSTFIELDS, post_data.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &buf);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) return WahooError.CurlFailed;

    if (!parseTokenResponse(buf.slice(), config)) return WahooError.TokenParseFailed;

    try saveConfig(config);
}

pub fn fetchWorkouts(
    allocator: std.mem.Allocator,
    config: *WahooConfig,
    list: *WahooWorkoutList,
    page: i32,
    per_page: i32,
) !void {
    try refreshToken(allocator, config);

    const handle = curl.curl_easy_init() orelse return WahooError.CurlFailed;
    defer curl.curl_easy_cleanup(handle);

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "{s}/workouts?page={d}&per_page={d}", .{
        WAHOO_API_URL, page, per_page,
    }) catch return WahooError.CurlFailed;

    var auth_buf: [512]u8 = undefined;
    const auth_header = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{
        std.mem.sliceTo(&config.access_token, 0),
    }) catch return WahooError.CurlFailed;

    var headers: ?*curl.curl_slist = null;
    headers = curl.curl_slist_append(headers, auth_header.ptr);
    headers = curl.curl_slist_append(headers, "Accept: application/json");
    defer curl.curl_slist_free_all(headers);

    var buf = CurlBuffer.init(allocator);
    defer buf.deinit();
    try buf.data.append(buf.allocator, 0);

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_HTTPHEADER, headers);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &buf);

    const res = curl.curl_easy_perform(handle);
    if (res != curl.CURLE_OK) return WahooError.CurlFailed;

    const json = buf.slice();
    if (json.len == 0) return;

    // Wahoo returns {"workouts": [...]}
    const workouts_key = std.mem.indexOf(u8, json, "\"workouts\"") orelse return;
    const array_off = std.mem.indexOfScalar(u8, json[workouts_key..], '[') orelse return;
    var pos: usize = workouts_key + array_off + 1; // skip '['

    // Iterate over top-level objects in the array
    while (pos < json.len) {
        // Find the next opening brace
        const brace_off = std.mem.indexOfScalar(u8, json[pos..], '{') orelse break;
        const obj_start = pos + brace_off;

        // Find the matching closing brace, respecting nesting
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

        // Parse the individual workout object
        if (jsonGetInt64(obj, "id")) |id| {
            var workout = WahooWorkout{};
            workout.id = id;

            _ = jsonGetString(obj, "name", &workout.name);
            _ = jsonGetString(obj, "starts", &workout.starts);
            if (jsonGetInt(obj, "minutes")) |v| workout.minutes = v;

            // Nested fields from workout_summary
            if (jsonGetNestedFloat(obj, "workout_summary", "distance_accum")) |v| workout.distance_meters = v;
            if (jsonGetNestedFloat(obj, "workout_summary", "ascent_accum")) |v| workout.ascent_meters = v;
            if (jsonGetNestedInt(obj, "workout_summary", "heart_rate_avg")) |v| workout.avg_heart_rate = v;
            if (jsonGetNestedInt(obj, "workout_summary", "power_avg")) |v| workout.avg_power = v;

            // FIT file URL from the nested file object
            _ = jsonGetNestedString(obj, "file", "url", &workout.fit_file_url);

            try list.workouts.append(list.allocator, workout);
        }

        pos = i;
    }
}

pub fn downloadFit(config: *WahooConfig, fit_url: []const u8, output_path: []const u8) !void {
    _ = config; // CDN downloads require no auth

    if (fit_url.len == 0) return WahooError.NoFitUrl;

    const handle = curl.curl_easy_init() orelse return WahooError.CurlFailed;
    defer curl.curl_easy_cleanup(handle);

    // Need null-terminated versions for C APIs
    var url_buf: [1024]u8 = undefined;
    const url_z = std.fmt.bufPrintZ(&url_buf, "{s}", .{fit_url}) catch return WahooError.CurlFailed;

    var path_buf: [1024]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{output_path}) catch return WahooError.CurlFailed;

    const f = std.c.fopen(path_z.ptr, "wb") orelse return WahooError.FileOpenFailed;
    errdefer {
        _ = std.c.fclose(f);
        _ = std.c.unlink(path_z.ptr);
    }

    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url_z.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, f);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));

    const res = curl.curl_easy_perform(handle);
    _ = std.c.fclose(f);

    if (res != curl.CURLE_OK) {
        _ = std.c.unlink(path_z.ptr);
        return WahooError.CurlFailed;
    }

    std.debug.print("Downloaded Wahoo workout to: {s}\n", .{output_path});
}
