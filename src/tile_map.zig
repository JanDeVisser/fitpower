const std = @import("std");
const builtin = @import("builtin");
const rl = @import("c.zig").rl;
const curl_c = @cImport(@cInclude("curl/curl.h"));
const fit_parser = @import("fit_parser.zig");
const zwift_worlds = @import("zwift_worlds.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const TILE_SIZE = 256;
pub const MAX_CACHED_TILES = 64;
pub const MIN_ZOOM = 1;
pub const MAX_ZOOM = 18;

const OSM_TILE_URL = "https://tile.openstreetmap.org/{d}/{d}/{d}.png";
const USER_AGENT = "sweattrails/1.0";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const MapSource = enum { osm, zwift };

pub const CachedTile = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    texture: rl.Texture2D = std.mem.zeroes(rl.Texture2D),
    loaded: bool = false,
    loading: bool = false,
    last_used: i64 = 0,
};

pub const TileCache = struct {
    tiles: [MAX_CACHED_TILES]CachedTile = std.mem.zeroes([MAX_CACHED_TILES]CachedTile),
    tile_count: usize = 0,
    cache_dir: [512]u8 = std.mem.zeroes([512]u8),
    initialized: bool = false,

    pub fn init(self: *TileCache) void {
        self.* = .{};

        const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";

        const dir = if (builtin.os.tag == .macos)
            std.fmt.bufPrintZ(&self.cache_dir, "{s}/Library/Application Support/sweattrails/tiles", .{home}) catch return
        else
            std.fmt.bufPrintZ(&self.cache_dir, "{s}/.local/share/sweattrails/tiles", .{home}) catch return;

        _ = dir; // bufPrintZ wrote into self.cache_dir; sentinel is already set

        createDirectoryRecursive(std.mem.sliceTo(&self.cache_dir, 0));
        self.initialized = true;
    }

    pub fn deinit(self: *TileCache) void {
        for (self.tiles[0..self.tile_count]) |*tile| {
            if (tile.loaded) {
                rl.UnloadTexture(tile.texture);
            }
        }
        self.tile_count = 0;
        self.initialized = false;
    }

    /// Return a pointer to the texture for tile (x, y, z), downloading and
    /// caching it as needed.  Returns null when the tile is unavailable.
    pub fn getTile(self: *TileCache, x: i32, y: i32, z: i32) ?*rl.Texture2D {
        if (!self.initialized) return null;

        const max_tile: i32 = (@as(i32, 1) << @intCast(z)) - 1;
        if (x < 0 or x > max_tile or y < 0 or y > max_tile) return null;

        const tile = self.findOrEvict(x, y, z);

        if (tile.loaded) return &tile.texture;

        // Try to load from disk (downloading first if necessary).
        var path_buf: [512]u8 = undefined;
        const cache_dir = std.mem.sliceTo(&self.cache_dir, 0);
        if (downloadTile(cache_dir, x, y, z, &path_buf)) {
            const path_z = std.mem.sliceTo(&path_buf, 0);
            const img = rl.LoadImage(path_z.ptr);
            if (img.data != null) {
                tile.texture = rl.LoadTextureFromImage(img);
                rl.UnloadImage(img);
                tile.loaded = true;
                return &tile.texture;
            }
        }

        return null;
    }

    // ------------------------------------------------------------------
    // Private helpers
    // ------------------------------------------------------------------

    fn findOrEvict(self: *TileCache, x: i32, y: i32, z: i32) *CachedTile {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const now = ts.sec;

        // Check if the tile already exists in the cache.
        for (self.tiles[0..self.tile_count]) |*tile| {
            if (tile.x == x and tile.y == y and tile.z == z) {
                tile.last_used = now;
                return tile;
            }
        }

        // Use a fresh slot if available.
        if (self.tile_count < MAX_CACHED_TILES) {
            const tile = &self.tiles[self.tile_count];
            self.tile_count += 1;
            tile.* = .{ .x = x, .y = y, .z = z, .last_used = now };
            return tile;
        }

        // Evict the least recently used slot.
        var lru_idx: usize = 0;
        var lru_time: i64 = self.tiles[0].last_used;
        for (self.tiles[1..], 1..) |*tile, i| {
            if (tile.last_used < lru_time) {
                lru_time = tile.last_used;
                lru_idx = i;
            }
        }

        const evicted = &self.tiles[lru_idx];
        if (evicted.loaded) rl.UnloadTexture(evicted.texture);
        evicted.* = .{ .x = x, .y = y, .z = z, .last_used = now };
        return evicted;
    }
};

pub const MapView = struct {
    center_lat: f64 = 0,
    center_lon: f64 = 0,
    zoom: i32 = 0,
    view_width: i32 = 0,
    view_height: i32 = 0,
    source: MapSource = .osm,
    zwift_world: ?*const zwift_worlds.ZwiftWorld = null,
    zwift_map_texture: rl.Texture2D = std.mem.zeroes(rl.Texture2D),
    zwift_map_loaded: bool = false,
};

// ---------------------------------------------------------------------------
// Coordinate conversion
// ---------------------------------------------------------------------------

pub fn latLonToTile(lat: f64, lon: f64, zoom: i32, tile_x: *i32, tile_y: *i32) void {
    const n = std.math.pow(f64, 2.0, @floatFromInt(zoom));
    tile_x.* = @intFromFloat((lon + 180.0) / 360.0 * n);

    const lat_rad = lat * std.math.pi / 180.0;
    tile_y.* = @intFromFloat((1.0 - std.math.asinh(std.math.tan(lat_rad)) / std.math.pi) / 2.0 * n);

    const max_tile: i32 = (@as(i32, 1) << @intCast(zoom)) - 1;
    tile_x.* = std.math.clamp(tile_x.*, 0, max_tile);
    tile_y.* = std.math.clamp(tile_y.*, 0, max_tile);
}

pub fn latLonToPixel(lat: f64, lon: f64, zoom: i32, pixel_x: *f64, pixel_y: *f64) void {
    const n = std.math.pow(f64, 2.0, @floatFromInt(zoom));
    pixel_x.* = ((lon + 180.0) / 360.0 * n) * TILE_SIZE;

    const lat_rad = lat * std.math.pi / 180.0;
    pixel_y.* = ((1.0 - std.math.asinh(std.math.tan(lat_rad)) / std.math.pi) / 2.0 * n) * TILE_SIZE;
}

pub fn tileToLatLon(tile_x: i32, tile_y: i32, zoom: i32, lat: *f64, lon: *f64) void {
    const n = std.math.pow(f64, 2.0, @floatFromInt(zoom));
    const tx: f64 = @floatFromInt(tile_x);
    const ty: f64 = @floatFromInt(tile_y);
    lon.* = tx / n * 360.0 - 180.0;
    const lat_rad = std.math.atan(std.math.sinh(std.math.pi * (1.0 - 2.0 * ty / n)));
    lat.* = lat_rad * 180.0 / std.math.pi;
}

// ---------------------------------------------------------------------------
// Map view helpers
// ---------------------------------------------------------------------------

pub fn mapViewFitBounds(
    view: *MapView,
    min_lat: f64,
    max_lat: f64,
    min_lon: f64,
    max_lon: f64,
    view_width: i32,
    view_height: i32,
) void {
    view.view_width = view_width;
    view.view_height = view_height;
    view.center_lat = (min_lat + max_lat) / 2.0;
    view.center_lon = (min_lon + max_lon) / 2.0;

    view.zwift_world = zwift_worlds.detectWorld(min_lat, max_lat, min_lon, max_lon);
    if (view.zwift_world != null) {
        view.source = .zwift;
        view.zoom = 15; // nominal value — Zwift uses its own scaling
        return;
    }

    view.source = .osm;

    const w_f: f64 = @floatFromInt(view_width);
    const h_f: f64 = @floatFromInt(view_height);

    var best_zoom: i32 = MAX_ZOOM;
    var z: i32 = MAX_ZOOM;
    while (z >= MIN_ZOOM) : (z -= 1) {
        var px1: f64 = undefined;
        var py1: f64 = undefined;
        var px2: f64 = undefined;
        var py2: f64 = undefined;
        latLonToPixel(min_lat, min_lon, z, &px1, &py1);
        latLonToPixel(max_lat, max_lon, z, &px2, &py2);

        const width_needed = @abs(px2 - px1);
        const height_needed = @abs(py2 - py1);

        if (width_needed <= w_f and height_needed <= h_f) {
            best_zoom = z;
            break;
        }
    }

    view.zoom = best_zoom;
}

// ---------------------------------------------------------------------------
// OSM tile-map rendering
// ---------------------------------------------------------------------------

pub fn drawTileMap(cache: *TileCache, view: *const MapView, screen_x: i32, screen_y: i32) void {
    var center_px: f64 = undefined;
    var center_py: f64 = undefined;
    latLonToPixel(view.center_lat, view.center_lon, view.zoom, &center_px, &center_py);

    const hw: f64 = @as(f64, @floatFromInt(view.view_width)) / 2.0;
    const hh: f64 = @as(f64, @floatFromInt(view.view_height)) / 2.0;

    const left_px = center_px - hw;
    const top_py = center_py - hh;
    const right_px = center_px + hw;
    const bottom_py = center_py + hh;

    const tile_x_start: i32 = @intFromFloat(left_px / TILE_SIZE);
    const tile_y_start: i32 = @intFromFloat(top_py / TILE_SIZE);
    const tile_x_end: i32 = @intFromFloat(right_px / TILE_SIZE);
    const tile_y_end: i32 = @intFromFloat(bottom_py / TILE_SIZE);

    rl.BeginScissorMode(screen_x, screen_y, view.view_width, view.view_height);

    rl.DrawRectangle(screen_x, screen_y, view.view_width, view.view_height,
        rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });

    var ty = tile_y_start;
    while (ty <= tile_y_end) : (ty += 1) {
        var tx = tile_x_start;
        while (tx <= tile_x_end) : (tx += 1) {
            const tile_px: f64 = @as(f64, @floatFromInt(tx)) * TILE_SIZE;
            const tile_py: f64 = @as(f64, @floatFromInt(ty)) * TILE_SIZE;
            const draw_x: i32 = screen_x + @as(i32, @intFromFloat(tile_px - left_px));
            const draw_y: i32 = screen_y + @as(i32, @intFromFloat(tile_py - top_py));

            if (cache.getTile(tx, ty, view.zoom)) |tex| {
                rl.DrawTexture(tex.*, draw_x, draw_y, rl.WHITE);
            } else {
                rl.DrawRectangle(draw_x, draw_y, TILE_SIZE, TILE_SIZE,
                    rl.Color{ .r = 180, .g = 180, .b = 180, .a = 255 });
                rl.DrawRectangleLines(draw_x, draw_y, TILE_SIZE, TILE_SIZE,
                    rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });
            }
        }
    }

    rl.EndScissorMode();
}

// ---------------------------------------------------------------------------
// Path drawing (OSM)
// ---------------------------------------------------------------------------

pub fn drawPath(
    view: *const MapView,
    screen_x: i32,
    screen_y: i32,
    samples: []const fit_parser.FitPowerSample,
) void {
    if (samples.len < 2) return;

    var center_px: f64 = undefined;
    var center_py: f64 = undefined;
    latLonToPixel(view.center_lat, view.center_lon, view.zoom, &center_px, &center_py);
    const left_px = center_px - @as(f64, @floatFromInt(view.view_width)) / 2.0;
    const top_py = center_py - @as(f64, @floatFromInt(view.view_height)) / 2.0;

    rl.BeginScissorMode(screen_x, screen_y, view.view_width, view.view_height);

    var prev_point: rl.Vector2 = undefined;
    var have_prev = false;

    // Track first and last GPS points for start/end markers.
    var first_point: rl.Vector2 = undefined;
    var last_point: rl.Vector2 = undefined;
    var have_first = false;

    for (samples) |*sample| {
        if (!sample.has_gps) continue;

        const lat = @as(f64, @floatFromInt(sample.latitude)) * fit_parser.FIT_SEMICIRCLE_TO_DEGREES;
        const lon = @as(f64, @floatFromInt(sample.longitude)) * fit_parser.FIT_SEMICIRCLE_TO_DEGREES;

        var px: f64 = undefined;
        var py: f64 = undefined;
        latLonToPixel(lat, lon, view.zoom, &px, &py);

        const point = rl.Vector2{
            .x = @as(f32, @floatFromInt(screen_x)) + @as(f32, @floatCast(px - left_px)),
            .y = @as(f32, @floatFromInt(screen_y)) + @as(f32, @floatCast(py - top_py)),
        };

        if (have_prev) {
            const line_color = powerColor(if (sample.has_power) sample.power else null);
            rl.DrawLineEx(prev_point, point, 3.0, line_color);
        }

        if (!have_first) {
            first_point = point;
            have_first = true;
        }
        last_point = point;
        prev_point = point;
        have_prev = true;
    }

    if (have_first) {
        rl.DrawCircle(
            @intFromFloat(first_point.x),
            @intFromFloat(first_point.y),
            6,
            rl.GREEN,
        );
        rl.DrawCircle(
            @intFromFloat(last_point.x),
            @intFromFloat(last_point.y),
            6,
            rl.RED,
        );
    }

    rl.EndScissorMode();
}

// ---------------------------------------------------------------------------
// Attribution
// ---------------------------------------------------------------------------

pub fn drawAttribution(view: *const MapView, x: i32, y: i32, font_size: i32) void {
    const attribution: [*:0]const u8 =
        if (view.source == .zwift and view.zwift_world != null)
            "Map: Zwift"
        else
            "\xC2\xA9 OpenStreetMap contributors"; // UTF-8 copyright symbol

    const text_width = rl.MeasureText(attribution, font_size);
    rl.DrawRectangle(x, y, text_width + 10, font_size + 4,
        rl.Color{ .r = 255, .g = 255, .b = 255, .a = 200 });
    rl.DrawText(attribution, x + 5, y + 2, font_size, rl.DARKGRAY);
}

// ---------------------------------------------------------------------------
// Zwift map loading / freeing
// ---------------------------------------------------------------------------

pub fn loadZwiftMap(view: *MapView, cache_dir: []const u8) !void {
    if (view.zwift_world == null or view.zwift_map_loaded) return;

    const world = view.zwift_world.?;

    // Build zwift subdirectory path and ensure it exists.
    var zwift_dir_buf: [512]u8 = undefined;
    const zwift_dir = try std.fmt.bufPrintZ(&zwift_dir_buf, "{s}/zwift", .{cache_dir});
    createDirectoryRecursive(zwift_dir);

    // Build the cache file path: <cache_dir>/zwift/<slug>.png
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = try std.fmt.bufPrintZ(&cache_path_buf, "{s}/zwift/{s}.png", .{ cache_dir, world.slug });

    // Download only if not already cached.
    const downloaded = downloadZwiftMap(world.map_url, cache_path);
    if (!downloaded) {
        std.debug.print("Failed to download Zwift map for {s}\n", .{world.name});
        return error.DownloadFailed;
    }

    const img = rl.LoadImage(cache_path.ptr);
    if (img.data == null) {
        std.debug.print("Failed to load Zwift map image: {s}\n", .{cache_path});
        return error.ImageLoadFailed;
    }

    view.zwift_map_texture = rl.LoadTextureFromImage(img);
    rl.UnloadImage(img);
    view.zwift_map_loaded = true;
}

pub fn freeZwiftMap(view: *MapView) void {
    if (view.zwift_map_loaded) {
        rl.UnloadTexture(view.zwift_map_texture);
        view.zwift_map_loaded = false;
    }
    view.zwift_world = null;
    view.source = .osm;
}

// ---------------------------------------------------------------------------
// Zwift map rendering
// ---------------------------------------------------------------------------

pub fn drawZwiftMap(view: *MapView, screen_x: i32, screen_y: i32) void {
    if (!view.zwift_map_loaded or view.zwift_world == null) return;

    rl.BeginScissorMode(screen_x, screen_y, view.view_width, view.view_height);

    rl.DrawRectangle(screen_x, screen_y, view.view_width, view.view_height,
        rl.Color{ .r = 30, .g = 40, .b = 50, .a = 255 });

    const map_w: f32 = @floatFromInt(view.zwift_map_texture.width);
    const map_h: f32 = @floatFromInt(view.zwift_map_texture.height);
    const view_w: f32 = @floatFromInt(view.view_width);
    const view_h: f32 = @floatFromInt(view.view_height);

    const scale = @min(view_w / map_w, view_h / map_h);
    const scaled_w = map_w * scale;
    const scaled_h = map_h * scale;

    const draw_x: f32 = @as(f32, @floatFromInt(screen_x)) + (view_w - scaled_w) / 2.0;
    const draw_y: f32 = @as(f32, @floatFromInt(screen_y)) + (view_h - scaled_h) / 2.0;

    rl.DrawTextureEx(view.zwift_map_texture, rl.Vector2{ .x = draw_x, .y = draw_y }, 0.0, scale, rl.WHITE);

    rl.EndScissorMode();
}

// ---------------------------------------------------------------------------
// Zwift path rendering
// ---------------------------------------------------------------------------

pub fn drawZwiftPath(
    view: *MapView,
    screen_x: i32,
    screen_y: i32,
    samples: []const fit_parser.FitPowerSample,
) void {
    if (samples.len < 2 or !view.zwift_map_loaded or view.zwift_world == null) return;

    // Compute the same map-fitting scale as drawZwiftMap.
    const map_w: f32 = @floatFromInt(view.zwift_map_texture.width);
    const map_h: f32 = @floatFromInt(view.zwift_map_texture.height);
    const view_w: f32 = @floatFromInt(view.view_width);
    const view_h: f32 = @floatFromInt(view.view_height);

    const scale = @min(view_w / map_w, view_h / map_h);
    const scaled_w = map_w * scale;
    const scaled_h = map_h * scale;

    const draw_x: f32 = @as(f32, @floatFromInt(screen_x)) + (view_w - scaled_w) / 2.0;
    const draw_y: f32 = @as(f32, @floatFromInt(screen_y)) + (view_h - scaled_h) / 2.0;

    // Calibration constants: GPS -> image pixel linear transform.
    const lon_scale: f64 = 52849.0;
    const lon_offset: f64 = -8819285.0;
    const lat_scale: f64 = -53432.0;
    const lat_offset: f64 = -621180.0;

    rl.BeginScissorMode(screen_x, screen_y, view.view_width, view.view_height);

    var prev_point: rl.Vector2 = undefined;
    var have_prev = false;

    // Track first/last GPS coordinates for start/end markers.
    var first_lon: f64 = 0;
    var first_lat: f64 = 0;
    var last_lon: f64 = 0;
    var last_lat: f64 = 0;
    var have_first = false;

    for (samples) |*sample| {
        if (!sample.has_gps) continue;

        const lat = @as(f64, @floatFromInt(sample.latitude)) * fit_parser.FIT_SEMICIRCLE_TO_DEGREES;
        const lon = @as(f64, @floatFromInt(sample.longitude)) * fit_parser.FIT_SEMICIRCLE_TO_DEGREES;

        const img_x = lon_scale * lon + lon_offset;
        const img_y = lat_scale * lat + lat_offset;

        const px = draw_x + @as(f32, @floatCast(img_x / map_w)) * scaled_w;
        const py = draw_y + @as(f32, @floatCast(img_y / map_h)) * scaled_h;

        const point = rl.Vector2{ .x = px, .y = py };

        if (have_prev) {
            const line_color = powerColor(if (sample.has_power) sample.power else null);
            rl.DrawLineEx(prev_point, point, 3.0, line_color);
        }

        if (!have_first) {
            first_lon = lon;
            first_lat = lat;
            have_first = true;
        }
        last_lon = lon;
        last_lat = lat;
        prev_point = point;
        have_prev = true;
    }

    // Draw start (green) and end (red) markers.
    if (have_first) {
        {
            const img_x = lon_scale * first_lon + lon_offset;
            const img_y = lat_scale * first_lat + lat_offset;
            const mx: i32 = @intFromFloat(draw_x + @as(f32, @floatCast(img_x / map_w)) * scaled_w);
            const my: i32 = @intFromFloat(draw_y + @as(f32, @floatCast(img_y / map_h)) * scaled_h);
            rl.DrawCircle(mx, my, 6, rl.GREEN);
        }
        {
            const img_x = lon_scale * last_lon + lon_offset;
            const img_y = lat_scale * last_lat + lat_offset;
            const mx: i32 = @intFromFloat(draw_x + @as(f32, @floatCast(img_x / map_w)) * scaled_w);
            const my: i32 = @intFromFloat(draw_y + @as(f32, @floatCast(img_y / map_h)) * scaled_h);
            rl.DrawCircle(mx, my, 6, rl.RED);
        }
    }

    rl.EndScissorMode();
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Return a line color from a wattage value (or a default red when absent).
fn powerColor(power: ?u16) rl.Color {
    const w = power orelse return rl.Color{ .r = 255, .g = 80, .b = 80, .a = 255 };
    return if (w < 150)
        rl.Color{ .r = 80, .g = 180, .b = 255, .a = 255 } // blue  — easy
    else if (w < 250)
        rl.Color{ .r = 80, .g = 255, .b = 120, .a = 255 } // green — moderate
    else
        rl.Color{ .r = 255, .g = 100, .b = 80, .a = 255 }; // red   — hard
}

/// Create all intermediate directories in `path` (POSIX only).
fn createDirectoryRecursive(path: []const u8) void {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return;

    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or buf[i] == '/') {
            buf[i] = 0;
            _ = std.c.mkdir(@as([*:0]const u8, @ptrCast(&buf)), 0o755);
            buf[i] = if (i < path.len) '/' else 0;
        }
    }
}

/// curl write callback: writes received bytes to the FILE* passed as userdata.
fn writeFileCallback(
    contents: ?*anyopaque,
    size: usize,
    nmemb: usize,
    userp: ?*anyopaque,
) callconv(.c) usize {
    const file: *std.c.FILE = @ptrCast(@alignCast(userp orelse return 0));
    const bytes: [*]const u8 = @ptrCast(contents orelse return 0);
    return std.c.fwrite(bytes, size, nmemb, file);
}

/// Download `url` into `cache_path` using libcurl.  Returns true when the
/// file is available (either already cached or just downloaded).
fn downloadWithCurl(url: []const u8, cache_path: [:0]const u8, timeout_secs: c_long) bool {
    // Already cached?
    {
        const cfd = std.posix.openatZ(std.posix.AT.FDCWD, cache_path.ptr, .{ .ACCMODE = .RDONLY }, 0) catch 0;
        if (cfd > 0) {
            var cst: std.c.Stat = undefined;
            const cached = (std.c.fstat(cfd, &cst) == 0 and cst.size > 0);
            _ = std.c.close(cfd);
            if (cached) return true;
        }
    }

    const curl = curl_c.curl_easy_init() orelse return false;
    defer curl_c.curl_easy_cleanup(curl);

    const file = std.c.fopen(cache_path.ptr, "wb") orelse return false;
    defer _ = std.c.fclose(file);

    var url_z_buf: [512]u8 = undefined;
    const url_z = std.fmt.bufPrintZ(&url_z_buf, "{s}", .{url}) catch return false;

    var headers: ?*curl_c.curl_slist = null;
    headers = curl_c.curl_slist_append(headers, "User-Agent: " ++ USER_AGENT);
    defer curl_c.curl_slist_free_all(headers);

    _ = curl_c.curl_easy_setopt(curl, curl_c.CURLOPT_URL, url_z.ptr);
    _ = curl_c.curl_easy_setopt(curl, curl_c.CURLOPT_HTTPHEADER, headers);
    _ = curl_c.curl_easy_setopt(curl, curl_c.CURLOPT_WRITEFUNCTION, &writeFileCallback);
    _ = curl_c.curl_easy_setopt(curl, curl_c.CURLOPT_WRITEDATA, file);
    _ = curl_c.curl_easy_setopt(curl, curl_c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = curl_c.curl_easy_setopt(curl, curl_c.CURLOPT_TIMEOUT, timeout_secs);

    const res = curl_c.curl_easy_perform(curl);
    if (res != curl_c.CURLE_OK) {
        _ = std.c.unlink(cache_path.ptr);
        return false;
    }
    return true;
}

/// Download an OSM tile to `<cache_dir>/<z>/<x>/<y>.png`.
/// Writes the resulting path (null-terminated) into `out_path_buf`.
/// Returns true when the file is available.
fn downloadTile(cache_dir: []const u8, x: i32, y: i32, z: i32, out_path_buf: *[512]u8) bool {
    // Ensure the z/x directory exists.
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/{d}/{d}", .{ cache_dir, z, x }) catch return false;
    createDirectoryRecursive(dir_path);

    const out_path = std.fmt.bufPrintZ(out_path_buf, "{s}/{d}/{d}/{d}.png", .{ cache_dir, z, x, y }) catch return false;

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://tile.openstreetmap.org/{d}/{d}/{d}.png", .{ z, x, y }) catch return false;

    return downloadWithCurl(url, out_path, 10);
}

/// Download a Zwift mini-map image.
fn downloadZwiftMap(url: []const u8, cache_path: [:0]const u8) bool {
    return downloadWithCurl(url, cache_path, 30);
}
