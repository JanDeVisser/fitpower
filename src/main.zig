const std = @import("std");
const builtin = @import("builtin");
const rl = @import("c.zig").rl;
const libc = @cImport({
    @cInclude("time.h");
});
const fit_parser = @import("fit_parser.zig");
const activity_tree_mod = @import("activity_tree.zig");
const strava_api = @import("strava_api.zig");
const wahoo_api = @import("wahoo_api.zig");
const zwift_sync = @import("zwift_sync.zig");
const garmin_sync = @import("garmin_sync.zig");
const tile_map = @import("tile_map.zig");
const activity_meta_mod = @import("activity_meta.zig");
const file_organizer = @import("file_organizer.zig");

const WINDOW_WIDTH = 1200;
const WINDOW_HEIGHT = 700;
const STRAVA_SYNC_PER_PAGE: i32 = 50;
const STRAVA_SYNC_MAX_PAGES: i32 = 10;
const WAHOO_SYNC_PER_PAGE: i32 = 30;
const WAHOO_SYNC_MAX_PAGES: i32 = 10;
const GARMIN_SYNC_LIMIT: i32 = 200;
const GRAPH_MARGIN_LEFT = 80;
const GRAPH_MARGIN_RIGHT = 40;
const GRAPH_MARGIN_TOP = 80;
const GRAPH_MARGIN_BOTTOM = 60;
const MAX_GRAPH_DATASETS = 8;

const TabMode = enum { local, settings };
const GraphViewMode = enum { summary, power, map };
const EditField = enum { none, title, description };

const SmoothingOption = struct { seconds: i32, label: [:0]const u8 };
const smoothing_options = [_]SmoothingOption{
    .{ .seconds = 0, .label = "Off" },
    .{ .seconds = 5, .label = "5s" },
    .{ .seconds = 15, .label = "15s" },
    .{ .seconds = 30, .label = "30s" },
    .{ .seconds = 60, .label = "1m" },
    .{ .seconds = 120, .label = "2m" },
    .{ .seconds = 300, .label = "5m" },
};

const graph_colors = [MAX_GRAPH_DATASETS]rl.Color{
    .{ .r = 50, .g = 150, .b = 255, .a = 255 },
    .{ .r = 255, .g = 100, .b = 100, .a = 255 },
    .{ .r = 100, .g = 200, .b = 100, .a = 255 },
    .{ .r = 255, .g = 200, .b = 50, .a = 255 },
    .{ .r = 200, .g = 100, .b = 255, .a = 255 },
    .{ .r = 100, .g = 255, .b = 255, .a = 255 },
    .{ .r = 255, .g = 150, .b = 100, .a = 255 },
    .{ .r = 200, .g = 200, .b = 200, .a = 255 },
};

var g_font: rl.Font = undefined;
var g_font_loaded: bool = false;

fn drawTextF(text: [*:0]const u8, x: i32, y: i32, size: i32, color: rl.Color) void {
    if (g_font_loaded) {
        rl.DrawTextEx(g_font, text, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, @floatFromInt(size), 1.0, color);
    } else {
        rl.DrawText(text, x, y, size, color);
    }
}

fn measureTextF(text: [*:0]const u8, size: i32) i32 {
    if (g_font_loaded) {
        return @intFromFloat(rl.MeasureTextEx(g_font, text, @floatFromInt(size), 1.0).x);
    }
    return rl.MeasureText(text, size);
}

fn bufLen(buf: []const u8) usize {
    return std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
}

fn drawButton(x: i32, y: i32, w: i32, h: i32, text: [*:0]const u8, enabled: bool) bool {
    const mouse = rl.GetMousePosition();
    const hover = enabled and mouse.x >= @as(f32, @floatFromInt(x)) and mouse.x < @as(f32, @floatFromInt(x + w)) and mouse.y >= @as(f32, @floatFromInt(y)) and mouse.y < @as(f32, @floatFromInt(y + h));
    const clicked = hover and rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON);

    const bg: rl.Color = if (!enabled) .{ .r = 40, .g = 40, .b = 50, .a = 255 } else if (hover) .{ .r = 80, .g = 100, .b = 140, .a = 255 } else .{ .r = 60, .g = 80, .b = 120, .a = 255 };
    const fg: rl.Color = if (enabled) rl.WHITE else rl.GRAY;

    rl.DrawRectangle(x, y, w, h, bg);
    rl.DrawRectangleLines(x, y, w, h, .{ .r = 100, .g = 120, .b = 160, .a = 255 });

    const tw = measureTextF(text, 14);
    drawTextF(text, x + @divTrunc(w - tw, 2), y + @divTrunc(h - 16, 2), 16, fg);
    return clicked;
}

fn drawBusyModal(title: [*:0]const u8, message: [*:0]const u8, accent: rl.Color) void {
    const sw = rl.GetScreenWidth();
    const sh = rl.GetScreenHeight();
    const mw = 450;
    const mh = 100;
    const mx = @divTrunc(sw - mw, 2);
    const my = @divTrunc(sh - mh, 2);

    rl.BeginDrawing();
    rl.ClearBackground(.{ .r = 25, .g = 25, .b = 35, .a = 255 });
    rl.DrawRectangle(mx - 2, my - 2, mw + 4, mh + 4, .{ .r = 80, .g = 80, .b = 100, .a = 255 });
    rl.DrawRectangle(mx, my, mw, mh, .{ .r = 40, .g = 40, .b = 50, .a = 255 });
    drawTextF(title, mx + 20, my + 15, 20, accent);
    drawTextF(message, mx + 20, my + 50, 15, rl.WHITE);
    rl.EndDrawing();
}

fn formatDuration(seconds: i32, buf: []u8) [:0]u8 {
    const h = @divTrunc(seconds, 3600);
    const m = @divTrunc(@rem(seconds, 3600), 60);
    const s = @rem(seconds, 60);
    if (h > 0) {
        return std.fmt.bufPrintZ(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch buf[0..0 :0];
    }
    return std.fmt.bufPrintZ(buf, "{d}:{d:0>2}", .{ m, s }) catch buf[0..0 :0];
}

fn drawTextField(x: i32, y: i32, w: i32, h: i32, text: []const u8, is_editing: bool, cursor_pos: i32, blink_time: f64) bool {
    const mouse = rl.GetMousePosition();
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const hover = mouse.x >= fx and mouse.x < fx + fw and mouse.y >= fy and mouse.y < fy + fh;
    const clicked = hover and rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON);

    const bg: rl.Color = if (is_editing) .{ .r = 50, .g = 50, .b = 60, .a = 255 } else if (hover) .{ .r = 40, .g = 40, .b = 50, .a = 255 } else .{ .r = 35, .g = 35, .b = 45, .a = 255 };
    rl.DrawRectangle(x, y, w, h, bg);
    rl.DrawRectangleLines(x, y, w, h, if (is_editing) rl.Color{ .r = 100, .g = 150, .b = 255, .a = 255 } else rl.Color{ .r = 60, .g = 60, .b = 70, .a = 255 });

    const text_x = x + 8;
    const text_y = y + @divTrunc(h - 16, 2);
    const max_width = w - 16;

    const text_slice = std.mem.sliceTo(text, 0);
    var disp_buf: [512]u8 = undefined;
    const dlen = @min(text_slice.len, 511);
    @memcpy(disp_buf[0..dlen], text_slice[0..dlen]);
    disp_buf[dlen] = 0;

    var display = disp_buf[0..dlen :0];
    while (display.len > 0 and measureTextF(display.ptr, 15) > max_width) {
        display = disp_buf[0 .. display.len - 1 :0];
        disp_buf[display.len] = 0;
    }
    drawTextF(display.ptr, text_x, text_y, 15, rl.WHITE);

    if (is_editing) {
        const cp: usize = @intCast(@min(cursor_pos, @as(i32, @intCast(text_slice.len))));
        var tmp_buf: [512]u8 = undefined;
        const tmp_len = @min(cp, 511);
        @memcpy(tmp_buf[0..tmp_len], text_slice[0..tmp_len]);
        tmp_buf[tmp_len] = 0;
        const tmp: [:0]const u8 = tmp_buf[0..tmp_len :0];
        const cx = text_x + measureTextF(tmp.ptr, 15);
        if (@rem(@as(i32, @intFromFloat(blink_time * 2)), 2) == 0) {
            rl.DrawRectangle(cx, text_y, 2, 16, rl.WHITE);
        }
    }
    return clicked;
}

fn drawTextArea(x: i32, y: i32, w: i32, h: i32, text: []const u8, is_editing: bool, cursor_pos: i32, blink_time: f64) bool {
    const mouse = rl.GetMousePosition();
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const hover = mouse.x >= fx and mouse.x < fx + fw and mouse.y >= fy and mouse.y < fy + fh;
    const clicked = hover and rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON);

    const bg: rl.Color = if (is_editing) .{ .r = 50, .g = 50, .b = 60, .a = 255 } else if (hover) .{ .r = 40, .g = 40, .b = 50, .a = 255 } else .{ .r = 35, .g = 35, .b = 45, .a = 255 };
    rl.DrawRectangle(x, y, w, h, bg);
    rl.DrawRectangleLines(x, y, w, h, if (is_editing) rl.Color{ .r = 100, .g = 150, .b = 255, .a = 255 } else rl.Color{ .r = 60, .g = 60, .b = 70, .a = 255 });

    const text_x = x + 8;
    const text_y = y + 8;
    const line_height = 18;
    const max_width = w - 16;
    const max_lines = @divTrunc(h - 16, line_height);

    const text_slice = std.mem.sliceTo(text, 0);
    var line: i32 = 0;
    var char_index: i32 = 0;
    var cursor_draw_x: i32 = text_x;
    var cursor_draw_y: i32 = text_y;
    var p: usize = 0;

    while (p < text_slice.len and line < max_lines) {
        const line_start = p;
        var line_end = p;
        var word_end = p;

        while (line_end < text_slice.len and text_slice[line_end] != '\n') {
            while (word_end < text_slice.len and text_slice[word_end] != ' ' and text_slice[word_end] != '\n') {
                word_end += 1;
            }
            var tmp_buf: [512]u8 = undefined;
            const seg_len = @min(word_end - line_start, 511);
            @memcpy(tmp_buf[0..seg_len], text_slice[line_start..line_start + seg_len]);
            tmp_buf[seg_len] = 0;
            const seg: [:0]const u8 = tmp_buf[0..seg_len :0];
            if (measureTextF(seg.ptr, 15) > max_width and line_end > line_start) break;
            line_end = word_end;
            if (word_end < text_slice.len and text_slice[word_end] == ' ') word_end += 1;
        }

        if (line_end == line_start and line_end < text_slice.len and text_slice[line_end] != '\n') {
            while (line_end < text_slice.len and text_slice[line_end] != '\n') {
                var tmp_buf2: [512]u8 = undefined;
                const seg_len = @min(line_end - line_start + 1, 511);
                @memcpy(tmp_buf2[0..seg_len], text_slice[line_start..line_start + seg_len]);
                tmp_buf2[seg_len] = 0;
                const seg2: [:0]const u8 = tmp_buf2[0..seg_len :0];
                if (measureTextF(seg2.ptr, 15) > max_width) break;
                line_end += 1;
            }
        }

        var line_buf: [512]u8 = undefined;
        const line_len = @min(line_end - line_start, 511);
        @memcpy(line_buf[0..line_len], text_slice[line_start..line_start + line_len]);
        line_buf[line_len] = 0;
        const line_text: [:0]const u8 = line_buf[0..line_len :0];
        drawTextF(line_text.ptr, text_x, text_y + line * line_height, 15, rl.WHITE);

        const line_start_idx = char_index;
        const line_end_idx = char_index + @as(i32, @intCast(line_len));
        if (is_editing and cursor_pos >= line_start_idx and cursor_pos <= line_end_idx) {
            const pos_in_line: usize = @intCast(cursor_pos - line_start_idx);
            var tmp3: [512]u8 = undefined;
            const tlen = @min(pos_in_line, 511);
            @memcpy(tmp3[0..tlen], text_slice[line_start..line_start + tlen]);
            tmp3[tlen] = 0;
            const tmp3s: [:0]const u8 = tmp3[0..tlen :0];
            cursor_draw_x = text_x + measureTextF(tmp3s.ptr, 15);
            cursor_draw_y = text_y + line * line_height;
        }

        char_index += @as(i32, @intCast(line_len));
        p = line_end;
        if (p < text_slice.len and text_slice[p] == '\n') {
            p += 1;
            char_index += 1;
        }
        line += 1;
    }

    if (is_editing and @rem(@as(i32, @intFromFloat(blink_time * 2)), 2) == 0) {
        rl.DrawRectangle(cursor_draw_x, cursor_draw_y, 2, 16, rl.WHITE);
    }
    return clicked;
}

fn drawPowerGraphMulti(
    datasets: []const *const fit_parser.FitPowerData,
    graph_x: i32,
    graph_y: i32,
    graph_w: i32,
    graph_h: i32,
    smoothing_seconds: i32,
    allocator: std.mem.Allocator,
) void {
    if (datasets.len == 0 or datasets[0].samples.items.len < 2) return;

    rl.DrawRectangle(graph_x, graph_y, graph_w, graph_h, .{ .r = 30, .g = 30, .b = 40, .a = 255 });

    var global_min: u16 = datasets[0].min_power;
    var global_max: u16 = datasets[0].max_power;
    var global_duration: u32 = 0;

    for (datasets) |data| {
        if (data.samples.items.len < 2) continue;
        if (data.min_power < global_min) global_min = data.min_power;
        if (data.max_power > global_max) global_max = data.max_power;
        const items = data.samples.items;
        const dur = items[items.len - 1].timestamp -% items[0].timestamp;
        if (dur > global_duration) global_duration = dur;
    }
    if (global_duration == 0) return;

    const min_display: f32 = if (global_min > 20) @as(f32, @floatFromInt(global_min)) - 20.0 else 0.0;
    const max_display: f32 = @as(f32, @floatFromInt(global_max)) + 20.0;
    const display_range = max_display - min_display;
    if (display_range <= 0) return;

    const num_grid = 5;
    var gi: i32 = 0;
    while (gi <= num_grid) : (gi += 1) {
        const y_ratio: f32 = @as(f32, @floatFromInt(gi)) / num_grid;
        const gy = graph_y + @as(i32, @intFromFloat(y_ratio * @as(f32, @floatFromInt(graph_h))));
        const power_val = max_display - (y_ratio * display_range);
        rl.DrawLine(graph_x, gy, graph_x + graph_w, gy, .{ .r = 60, .g = 60, .b = 70, .a = 255 });
        var lbuf: [32]u8 = undefined;
        const label = std.fmt.bufPrintZ(&lbuf, "{d}W", .{@as(i32, @intFromFloat(power_val))}) catch continue;
        drawTextF(label.ptr, graph_x - 55, gy - 8, 16, rl.LIGHTGRAY);
    }

    const num_time = 10;
    var ti: i32 = 0;
    while (ti <= num_time) : (ti += 1) {
        const x_ratio: f32 = @as(f32, @floatFromInt(ti)) / num_time;
        const gx = graph_x + @as(i32, @intFromFloat(x_ratio * @as(f32, @floatFromInt(graph_w))));
        rl.DrawLine(gx, graph_y, gx, graph_y + graph_h, .{ .r = 60, .g = 60, .b = 70, .a = 255 });
        const time_off: u32 = @intFromFloat(x_ratio * @as(f32, @floatFromInt(global_duration)));
        const mins = time_off / 60;
        const secs = time_off % 60;
        var tbuf: [32]u8 = undefined;
        const tlabel = std.fmt.bufPrintZ(&tbuf, "{d}:{d:0>2}", .{ mins, secs }) catch continue;
        drawTextF(tlabel.ptr, gx - 20, graph_y + graph_h + 10, 14, rl.LIGHTGRAY);
    }

    for (datasets, 0..) |data, d| {
        if (data.samples.items.len < 2) continue;
        const items = data.samples.items;

        var smoothed: ?[]f32 = null;
        defer if (smoothed) |s| allocator.free(s);
        if (smoothing_seconds > 0) {
            smoothed = allocator.alloc(f32, items.len) catch null;
            if (smoothed) |s| {
                const half: usize = @intCast(@divTrunc(smoothing_seconds, 2));
                for (items, 0..) |_, i| {
                    const start = if (i > half) i - half else 0;
                    const end = if (i + half < items.len) i + half else items.len - 1;
                    var sum: f32 = 0;
                    for (items[start .. end + 1]) |smp| sum += @floatFromInt(smp.power);
                    s[i] = sum / @as(f32, @floatFromInt(end - start + 1));
                }
            }
        }

        const data_start = items[0].timestamp;
        const line_color = graph_colors[d % MAX_GRAPH_DATASETS];

        for (items[0 .. items.len - 1], 0..) |_, i| {
            const t1 = items[i].timestamp -% data_start;
            const t2 = items[i + 1].timestamp -% data_start;
            const x1: f32 = @as(f32, @floatFromInt(graph_x)) + (@as(f32, @floatFromInt(t1)) / @as(f32, @floatFromInt(global_duration))) * @as(f32, @floatFromInt(graph_w));
            const x2: f32 = @as(f32, @floatFromInt(graph_x)) + (@as(f32, @floatFromInt(t2)) / @as(f32, @floatFromInt(global_duration))) * @as(f32, @floatFromInt(graph_w));
            const p1: f32 = if (smoothed) |s| s[i] else @floatFromInt(items[i].power);
            const p2: f32 = if (smoothed) |s| s[i + 1] else @floatFromInt(items[i + 1].power);
            const y1: f32 = @as(f32, @floatFromInt(graph_y)) + ((max_display - p1) / display_range) * @as(f32, @floatFromInt(graph_h));
            const y2: f32 = @as(f32, @floatFromInt(graph_y)) + ((max_display - p2) / display_range) * @as(f32, @floatFromInt(graph_h));
            rl.DrawLineEx(.{ .x = x1, .y = y1 }, .{ .x = x2, .y = y2 }, 2.0, line_color);
        }
    }

    if (datasets.len > 1) {
        for (datasets, 0..) |data, d| {
            const c = graph_colors[d % MAX_GRAPH_DATASETS];
            const ly = graph_y + 10 + @as(i32, @intCast(d)) * 18;
            rl.DrawRectangle(graph_x + 10, ly, 12, 12, c);
            var lbuf: [128]u8 = undefined;
            const title = std.mem.sliceTo(&data.title, 0);
            const label = std.fmt.bufPrintZ(&lbuf, "{s} ({d:.0}W avg)", .{ title, data.avg_power }) catch continue;
            drawTextF(label.ptr, graph_x + 28, ly - 1, 14, rl.LIGHTGRAY);
        }
    } else {
        const data = datasets[0];
        const avg_y_ratio = (max_display - @as(f32, @floatCast(data.avg_power))) / display_range;
        const avg_y = graph_y + @as(i32, @intFromFloat(avg_y_ratio * @as(f32, @floatFromInt(graph_h))));
        rl.DrawLine(graph_x, avg_y, graph_x + graph_w, avg_y, .{ .r = 255, .g = 200, .b = 50, .a = 200 });
        var abuf: [64]u8 = undefined;
        const alabel = std.fmt.bufPrintZ(&abuf, "Avg: {d:.0}W", .{data.avg_power}) catch return;
        drawTextF(alabel.ptr, graph_x + graph_w - 100, avg_y - 20, 16, .{ .r = 255, .g = 200, .b = 50, .a = 255 });
    }
}

fn drawSummaryTab(
    data: *const fit_parser.FitPowerData,
    edit_field: *EditField,
    edit_title: []u8,
    edit_desc: []u8,
    cursor_pos: *i32,
    blink_time: f64,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    is_group: bool,
    group_datasets: []const *const fit_parser.FitPowerData,
) i32 {
    const label_x = x + 20;
    const value_x = x + 150;
    const row_h = 28;
    var cy = y + 15;
    var clicked_activity: i32 = -1;
    const mouse = rl.GetMousePosition();

    drawTextF("Title:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    const title_clicked = drawTextField(value_x, cy, w - 170, 24, edit_title, edit_field.* == .title, cursor_pos.*, blink_time);
    if (title_clicked and edit_field.* != .title) {
        edit_field.* = .title;
        cursor_pos.* = @intCast(bufLen(edit_title));
    }
    cy += row_h;

    if (is_group and group_datasets.len > 0) {
        drawTextF("Activities:", label_x, cy + 4, 15, rl.LIGHTGRAY);
        cy += row_h;

        for (group_datasets, 0..) |gdata, i| {
            const iy = cy;
            const iw = w - 40;
            const ih = 24;
            const hover = mouse.x >= @as(f32, @floatFromInt(label_x)) and mouse.x < @as(f32, @floatFromInt(label_x + iw)) and mouse.y >= @as(f32, @floatFromInt(iy)) and mouse.y < @as(f32, @floatFromInt(iy + ih));
            if (hover) {
                rl.DrawRectangle(label_x, iy, iw, ih, .{ .r = 50, .g = 60, .b = 80, .a = 255 });
                if (rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON)) {
                    clicked_activity = @intCast(i);
                }
            }
            const c = graph_colors[i % MAX_GRAPH_DATASETS];
            rl.DrawRectangle(label_x + 5, iy + 6, 12, 12, c);
            var ibuf: [256]u8 = undefined;
            const title_s = std.mem.sliceTo(&gdata.title, 0);
            const itext = std.fmt.bufPrintZ(&ibuf, "{s} ({d:.0} W avg)", .{ title_s, gdata.avg_power }) catch continue;
            drawTextF(itext.ptr, label_x + 25, iy + 4, 15, if (hover) rl.WHITE else rl.LIGHTGRAY);
            cy += row_h;
        }
        cy += 10;

        drawTextF("Notes:", label_x, cy + 4, 15, rl.LIGHTGRAY);
        cy += 22;
        const dh = @max(h - (cy - y) - 20, 60);
        const desc_clicked = drawTextArea(label_x, cy, w - 40, dh, edit_desc, edit_field.* == .description, cursor_pos.*, blink_time);
        if (desc_clicked and edit_field.* != .description) {
            edit_field.* = .description;
            cursor_pos.* = @intCast(bufLen(edit_desc));
        }
        if (rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON) and !title_clicked and !desc_clicked and clicked_activity < 0) {
            edit_field.* = .none;
        }
        return clicked_activity;
    }

    // Single activity stats
    drawTextF("Type:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    const atype = std.mem.sliceTo(&data.activity_type, 0);
    if (atype.len > 0) {
        var abuf: [65]u8 = undefined;
        @memcpy(abuf[0..atype.len], atype);
        abuf[atype.len] = 0;
        drawTextF(abuf[0..atype.len :0].ptr, value_x, cy + 4, 15, rl.WHITE);
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Source
    {
        const src = std.mem.sliceTo(&data.source_file, 0);
        const basename = if (std.mem.lastIndexOfScalar(u8, src, '/')) |idx| src[idx + 1 ..] else src;
        const source_label: [*:0]const u8, const source_color: rl.Color = blk: {
            if (std.mem.endsWith(u8, basename, ".json")) break :blk .{ "Strava", .{ .r = 252, .g = 82, .b = 0, .a = 255 } };
            if (std.mem.startsWith(u8, basename, "wahoo_")) break :blk .{ "Wahoo", .{ .r = 255, .g = 193, .b = 7, .a = 255 } };
            if (std.mem.startsWith(u8, basename, "zwift_")) break :blk .{ "Zwift", .{ .r = 252, .g = 102, .b = 0, .a = 255 } };
            if (std.mem.startsWith(u8, basename, "garmin_")) break :blk .{ "Garmin", .{ .r = 0, .g = 148, .b = 218, .a = 255 } };
            break :blk .{ "Local", rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 } };
        };
        drawTextF("Source:", label_x, cy + 4, 15, rl.LIGHTGRAY);
        rl.DrawRectangle(value_x, cy + 7, 6, 6, source_color);
        drawTextF(source_label, value_x + 12, cy + 4, 15, source_color);
        cy += row_h;
    }

    // Date
    drawTextF("Date:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    if (data.start_time > 0) {
        const t: libc.time_t = @intCast(data.start_time);
        const tm = libc.localtime(&t);
        if (tm != null) {
            var dbuf: [64]u8 = undefined;
            _ = libc.strftime(&dbuf, dbuf.len, "%Y-%m-%d %H:%M", tm);
            const ds = std.mem.sliceTo(&dbuf, 0);
            var dzbuf: [64]u8 = undefined;
            @memcpy(dzbuf[0..ds.len], ds);
            dzbuf[ds.len] = 0;
            drawTextF(dzbuf[0..ds.len :0].ptr, value_x, cy + 4, 15, rl.WHITE);
        }
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Duration
    drawTextF("Duration:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    if (data.elapsed_time > 0) {
        var dur_buf: [32]u8 = undefined;
        const dur_str = formatDuration(data.elapsed_time, &dur_buf);
        if (data.moving_time > 0 and data.moving_time != data.elapsed_time) {
            var mov_buf: [32]u8 = undefined;
            const mov_str = formatDuration(data.moving_time, &mov_buf);
            var cbuf: [80]u8 = undefined;
            const combined = std.fmt.bufPrintZ(&cbuf, "{s} (moving: {s})", .{ dur_str, mov_str }) catch dur_str;
            drawTextF(combined.ptr, value_x, cy + 4, 15, rl.WHITE);
        } else {
            drawTextF(dur_str.ptr, value_x, cy + 4, 15, rl.WHITE);
        }
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Distance
    drawTextF("Distance:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    if (data.total_distance > 0) {
        var dbuf2: [32]u8 = undefined;
        const ds2 = std.fmt.bufPrintZ(&dbuf2, "{d:.2} km", .{data.total_distance / 1000.0}) catch "-";
        drawTextF(ds2.ptr, value_x, cy + 4, 15, rl.WHITE);
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Avg Speed
    drawTextF("Avg Speed:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    const time_for_speed: i32 = if (data.moving_time > 0) data.moving_time else data.elapsed_time;
    if (data.total_distance > 0 and time_for_speed > 0) {
        const speed = (data.total_distance / 1000.0) / (@as(f32, @floatFromInt(time_for_speed)) / 3600.0);
        var sbuf: [32]u8 = undefined;
        const ss = std.fmt.bufPrintZ(&sbuf, "{d:.1} km/h", .{speed}) catch "-";
        drawTextF(ss.ptr, value_x, cy + 4, 15, rl.WHITE);
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Power
    drawTextF("Power:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    if (data.avg_power > 0) {
        var pbuf: [64]u8 = undefined;
        const ps = std.fmt.bufPrintZ(&pbuf, "{d:.0} W avg / {d} W max", .{ data.avg_power, data.max_power }) catch "-";
        drawTextF(ps.ptr, value_x, cy + 4, 15, rl.WHITE);
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Heart rate
    drawTextF("Heart Rate:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    if (data.has_heart_rate_data) {
        var hbuf: [64]u8 = undefined;
        const hs = std.fmt.bufPrintZ(&hbuf, "{d} bpm avg / {d} bpm max", .{ data.avg_heart_rate, data.max_heart_rate }) catch "-";
        drawTextF(hs.ptr, value_x, cy + 4, 15, rl.WHITE);
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h;

    // Cadence
    drawTextF("Cadence:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    if (data.has_cadence_data) {
        var cbuf2: [64]u8 = undefined;
        const cs = std.fmt.bufPrintZ(&cbuf2, "{d} rpm avg / {d} rpm max", .{ data.avg_cadence, data.max_cadence }) catch "-";
        drawTextF(cs.ptr, value_x, cy + 4, 15, rl.WHITE);
    } else {
        drawTextF("-", value_x, cy + 4, 15, rl.WHITE);
    }
    cy += row_h + 10;

    drawTextF("Notes:", label_x, cy + 4, 15, rl.LIGHTGRAY);
    cy += 22;
    const dh2 = @max(h - (cy - y) - 20, 60);
    const desc_clicked2 = drawTextArea(label_x, cy, w - 40, dh2, edit_desc, edit_field.* == .description, cursor_pos.*, blink_time);
    if (desc_clicked2 and edit_field.* != .description) {
        edit_field.* = .description;
        cursor_pos.* = @intCast(bufLen(edit_desc));
    }
    if (rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON) and !title_clicked and !desc_clicked2) {
        edit_field.* = .none;
    }
    return -1;
}

fn activityFileExists(data_dir: []const u8, prefix: []const u8, id: i64, ext: []const u8) bool {
    return activityFileExistsInner(data_dir, prefix, id, ext) catch false;
}

fn activityFileExistsInner(data_dir: []const u8, prefix: []const u8, id: i64, ext: []const u8) !bool {
    var id_buf: [48]u8 = undefined;
    const id_str = if (prefix.len > 0)
        try std.fmt.bufPrint(&id_buf, "{s}{d}{s}", .{ prefix, id, ext })
    else
        try std.fmt.bufPrint(&id_buf, "{d}{s}", .{ id, ext });

    var act_dir_buf: [512]u8 = undefined;
    const act_dir = try std.fmt.bufPrint(&act_dir_buf, "{s}/activity", .{data_dir});

    var act_dir_z_buf: [512]u8 = undefined;
    const act_dir_z = try std.fmt.bufPrintZ(&act_dir_z_buf, "{s}", .{act_dir});
    const year_dir = std.c.opendir(act_dir_z) orelse return false;
    defer _ = std.c.closedir(year_dir);

    while (std.c.readdir(year_dir)) |ye| {
        const ye_name = std.mem.sliceTo(&ye.name, 0);
        if (ye_name[0] == '.') continue;
        if (ye.type != std.c.DT.DIR) continue;

        var yp_buf: [512]u8 = undefined;
        var yp_z_buf: [512]u8 = undefined;
        const yp = std.fmt.bufPrint(&yp_buf, "{s}/{s}", .{ act_dir, ye_name }) catch continue;
        const yp_z = std.fmt.bufPrintZ(&yp_z_buf, "{s}", .{yp}) catch continue;

        const month_dir = std.c.opendir(yp_z) orelse continue;
        var found = false;
        while (std.c.readdir(month_dir)) |me| {
            const me_name = std.mem.sliceTo(&me.name, 0);
            if (me_name[0] == '.') continue;
            if (me.type != std.c.DT.DIR) continue;

            var fp_z_buf: [512]u8 = undefined;
            const fp_z = std.fmt.bufPrintZ(&fp_z_buf, "{s}/{s}/{s}", .{ yp, me_name, id_str }) catch continue;
            if (std.c.access(fp_z, 0) == 0) {
                found = true;
                break;
            }
        }
        _ = std.c.closedir(month_dir);
        if (found) return true;
    }
    return false;
}

fn loadActivityFile(allocator: std.mem.Allocator, path: []const u8) ?fit_parser.FitPowerData {
    const is_json = std.ascii.endsWithIgnoreCase(path, ".json");
    if (is_json) {
        return fit_parser.parseJsonActivity(allocator, path) catch null;
    }
    return fit_parser.parseFitFile(allocator, path) catch null;
}

fn initPaths(data_dir: *[512]u8) void {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
    if (builtin.os.tag == .macos) {
        _ = std.fmt.bufPrintZ(data_dir, "{s}/Library/Application Support/fitpower", .{home}) catch {};
    } else {
        _ = std.fmt.bufPrintZ(data_dir, "{s}/.local/share/fitpower", .{home}) catch {};
    }
}

fn freeGroupDatasets(allocator: std.mem.Allocator, datasets: []*fit_parser.FitPowerData, count: usize) void {
    for (datasets[0..count]) |ds| {
        ds.deinit();
        allocator.destroy(ds);
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var data_dir: [512]u8 = std.mem.zeroes([512]u8);
    initPaths(&data_dir);
    const data_dir_s = std.mem.sliceTo(&data_dir, 0);

    var inbox_buf: [512]u8 = undefined;
    const inbox_path = try std.fmt.bufPrint(&inbox_buf, "{s}/inbox", .{data_dir_s});
    file_organizer.createDirectoryPath(inbox_path) catch {};
    const inbox_processed = file_organizer.processInbox(allocator, data_dir_s) catch 0;
    if (inbox_processed > 0) {
        std.debug.print("Processed {d} files from inbox\n", .{inbox_processed});
    }

    var tree = activity_tree_mod.ActivityTree.init(allocator);
    defer tree.deinit();
    tree.scan(data_dir_s) catch {};
    std.debug.print("Scanned activity tree: {d} years\n", .{tree.years.items.len});

    // Load configs
    var strava_config_loaded: bool = false;
    var strava_config: strava_api.StravaConfig = blk: {
        const cfg = strava_api.loadConfig(allocator) catch break :blk strava_api.StravaConfig{};
        strava_config_loaded = true;
        break :blk cfg;
    };

    var wahoo_config_loaded: bool = false;
    var wahoo_config: wahoo_api.WahooConfig = blk: {
        const cfg = wahoo_api.loadConfig(allocator) catch break :blk wahoo_api.WahooConfig{};
        wahoo_config_loaded = true;
        break :blk cfg;
    };

    var garmin_config_loaded: bool = false;
    _ = blk: {
        _ = garmin_sync.loadConfig(allocator) catch break :blk {};
        garmin_config_loaded = true;
        break :blk {};
    };
    var garmin_authenticated: bool = false;
    if (garmin_config_loaded) {
        garmin_authenticated = garmin_sync.isAuthenticated(allocator);
    }

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_MSAA_4X_HINT);
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Sweattrails");
    rl.MaximizeWindow();
    rl.SetTargetFPS(60);

    // Load font
    const home_for_font = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
    const font_paths = [_][]const u8{
        "/.local/share/fonts/JetBrainsMono-Regular.ttf",
        "/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
        "/Library/Fonts/JetBrainsMono-VariableFont_wght.ttf",
    };
    for (font_paths) |fp| {
        var font_buf: [512]u8 = undefined;
        const font_path = std.fmt.bufPrintZ(&font_buf, "{s}{s}", .{ home_for_font, fp }) catch continue;
        if (rl.FileExists(font_path.ptr)) {
            g_font = rl.LoadFontEx(font_path.ptr, 32, null, 0);
            rl.SetTextureFilter(g_font.texture, rl.TEXTURE_FILTER_BILINEAR);
            g_font_loaded = true;
            break;
        }
    }
    if (!g_font_loaded) g_font = rl.GetFontDefault();

    // Strava auto-sync
    if (strava_config_loaded and strava_api.isAuthenticated(&strava_config)) {
        var warm: i32 = 0;
        while (warm < 10 and !rl.WindowShouldClose()) : (warm += 1) {
            rl.BeginDrawing();
            rl.ClearBackground(.{ .r = 25, .g = 25, .b = 35, .a = 255 });
            rl.EndDrawing();
        }
        const strava_orange = rl.Color{ .r = 252, .g = 82, .b = 0, .a = 255 };
        const sw = rl.GetScreenWidth();
        const sh = rl.GetScreenHeight();
        const mw: i32 = 450;
        const mh: i32 = 150;
        const mx = @divTrunc(sw - mw, 2);
        const my = @divTrunc(sh - mh, 2);

        var sync_page: i32 = 1;
        var sync_total: i32 = 0;
        var sync_dl: i32 = 0;
        var sync_skip: i32 = 0;
        var sync_done = false;
        var sync_status_buf: [256]u8 = std.mem.zeroes([256]u8);
        _ = std.fmt.bufPrintZ(&sync_status_buf, "Checking Strava activities...", .{}) catch {};

        while (!sync_done and !rl.WindowShouldClose()) {
            rl.BeginDrawing();
            rl.ClearBackground(.{ .r = 25, .g = 25, .b = 35, .a = 255 });
            rl.DrawRectangle(mx - 2, my - 2, mw + 4, mh + 4, .{ .r = 80, .g = 80, .b = 100, .a = 255 });
            rl.DrawRectangle(mx, my, mw, mh, .{ .r = 40, .g = 40, .b = 50, .a = 255 });
            drawTextF("Strava Sync", mx + 20, my + 15, 20, strava_orange);
            drawTextF(@ptrCast(&sync_status_buf), mx + 20, my + 50, 15, rl.WHITE);
            var prog_buf: [128]u8 = undefined;
            const prog = std.fmt.bufPrintZ(&prog_buf, "Downloaded: {d}  |  Skipped: {d}  |  Total: {d}", .{ sync_dl, sync_skip, sync_total }) catch continue;
            drawTextF(prog.ptr, mx + 20, my + 75, 14, rl.LIGHTGRAY);
            const bar_w = mw - 40;
            rl.DrawRectangle(mx + 20, my + 105, bar_w, 20, .{ .r = 30, .g = 30, .b = 40, .a = 255 });
            if (sync_total > 0) {
                const fill: i32 = @intFromFloat(@as(f32, @floatFromInt(sync_dl + sync_skip)) / @as(f32, @floatFromInt(sync_total)) * @as(f32, @floatFromInt(bar_w)));
                rl.DrawRectangle(mx + 20, my + 105, fill, 20, strava_orange);
            }
            rl.EndDrawing();

            var sbuf2: [256]u8 = undefined;
            _ = std.fmt.bufPrintZ(&sbuf2, "Fetching page {d}...", .{sync_page}) catch {};
            @memcpy(&sync_status_buf, &sbuf2);

            var page_list = strava_api.StravaActivityList.init(allocator);
            defer page_list.deinit();
            strava_api.fetchActivities(allocator, &strava_config, &page_list, sync_page, STRAVA_SYNC_PER_PAGE) catch {
                sync_done = true;
                continue;
            };

            if (page_list.activities.items.len == 0) {
                sync_done = true;
                continue;
            }

            for (page_list.activities.items) |act| {
                sync_total += 1;
                if (activityFileExists(data_dir_s, "", act.id, ".json")) {
                    sync_skip += 1;
                    continue;
                }
                var status3: [256]u8 = undefined;
                _ = std.fmt.bufPrintZ(&status3, "Downloading: {s}...", .{std.mem.sliceTo(&act.name, 0)}) catch {};
                @memcpy(&sync_status_buf, &status3);

                const start_date = std.mem.sliceTo(&act.start_date, 0);
                if (start_date.len >= 10) {
                    var out_dir_buf: [512]u8 = undefined;
                    const out_dir = std.fmt.bufPrint(&out_dir_buf, "{s}/activity/{s}/{s}", .{ data_dir_s, start_date[0..4], start_date[5..7] }) catch continue;
                    file_organizer.createDirectoryPath(out_dir) catch {};
                    var out_path_buf: [512]u8 = undefined;
                    const out_path = std.fmt.bufPrint(&out_path_buf, "{s}/{d}.json", .{ out_dir, act.id }) catch continue;
                    if (strava_api.downloadActivity(allocator, &strava_config, act.id, out_path)) {
                        sync_dl += 1;
                    } else |_| {}
                }
            }

            const batch = page_list.activities.items.len;
            if (batch == @as(usize, @intCast(STRAVA_SYNC_PER_PAGE)) and sync_page < STRAVA_SYNC_MAX_PAGES) {
                sync_page += 1;
            } else {
                sync_done = true;
            }
        }

        if (sync_dl > 0) {
            tree.deinit();
            tree = activity_tree_mod.ActivityTree.init(allocator);
            tree.scan(data_dir_s) catch {};
        }
        std.debug.print("Strava sync: {d} dl, {d} skip\n", .{ sync_dl, sync_skip });
    }

    // Wahoo auto-sync
    if (wahoo_config_loaded and wahoo_api.isAuthenticated(&wahoo_config)) {
        const wahoo_yellow = rl.Color{ .r = 255, .g = 193, .b = 7, .a = 255 };
        const sw2 = rl.GetScreenWidth();
        const sh2 = rl.GetScreenHeight();
        const mw2: i32 = 450;
        const mh2: i32 = 150;
        const mx2 = @divTrunc(sw2 - mw2, 2);
        const my2 = @divTrunc(sh2 - mh2, 2);

        var sync_page2: i32 = 1;
        var sync_total2: i32 = 0;
        var sync_dl2: i32 = 0;
        var sync_skip2: i32 = 0;
        var sync_done2 = false;

        while (!sync_done2 and !rl.WindowShouldClose()) {
            rl.BeginDrawing();
            rl.ClearBackground(.{ .r = 25, .g = 25, .b = 35, .a = 255 });
            rl.DrawRectangle(mx2 - 2, my2 - 2, mw2 + 4, mh2 + 4, .{ .r = 80, .g = 80, .b = 100, .a = 255 });
            rl.DrawRectangle(mx2, my2, mw2, mh2, .{ .r = 40, .g = 40, .b = 50, .a = 255 });
            drawTextF("Wahoo Sync", mx2 + 20, my2 + 15, 20, wahoo_yellow);
            var wp: [128]u8 = undefined;
            const wpl = std.fmt.bufPrintZ(&wp, "Downloaded: {d}  |  Skipped: {d}  |  Total: {d}", .{ sync_dl2, sync_skip2, sync_total2 }) catch continue;
            drawTextF(wpl.ptr, mx2 + 20, my2 + 75, 14, rl.LIGHTGRAY);
            rl.EndDrawing();

            var wpage_list = wahoo_api.WahooWorkoutList.init(allocator);
            defer wpage_list.deinit();
            wahoo_api.fetchWorkouts(allocator, &wahoo_config, &wpage_list, sync_page2, WAHOO_SYNC_PER_PAGE) catch {
                sync_done2 = true;
                continue;
            };

            if (wpage_list.workouts.items.len == 0) {
                sync_done2 = true;
                continue;
            }

            for (wpage_list.workouts.items) |workout| {
                sync_total2 += 1;
                if (activityFileExists(data_dir_s, "wahoo_", workout.id, ".fit")) {
                    sync_skip2 += 1;
                    continue;
                }
                const url = std.mem.sliceTo(&workout.fit_file_url, 0);
                if (url.len == 0) { sync_skip2 += 1; continue; }

                const starts = std.mem.sliceTo(&workout.starts, 0);
                if (starts.len >= 10) {
                    var odir_buf: [512]u8 = undefined;
                    const odir = std.fmt.bufPrint(&odir_buf, "{s}/activity/{s}/{s}", .{ data_dir_s, starts[0..4], starts[5..7] }) catch continue;
                    file_organizer.createDirectoryPath(odir) catch {};
                    var opath_buf: [512]u8 = undefined;
                    const opath = std.fmt.bufPrint(&opath_buf, "{s}/wahoo_{d}.fit", .{ odir, workout.id }) catch continue;
                    if (wahoo_api.downloadFit(&wahoo_config, url, opath)) {
                        sync_dl2 += 1;
                    } else |_| {}
                }
            }

            const wbatch = wpage_list.workouts.items.len;
            if (wbatch == @as(usize, @intCast(WAHOO_SYNC_PER_PAGE)) and sync_page2 < WAHOO_SYNC_MAX_PAGES) {
                sync_page2 += 1;
            } else {
                sync_done2 = true;
            }
        }

        if (sync_dl2 > 0) {
            tree.deinit();
            tree = activity_tree_mod.ActivityTree.init(allocator);
            tree.scan(data_dir_s) catch {};
        }
        std.debug.print("Wahoo sync: {d} dl, {d} skip\n", .{ sync_dl2, sync_skip2 });
    }

    // Zwift auto-sync
    if (zwift_sync.loadConfig(allocator)) |zwift_config| {
        if (zwift_config.auto_sync) {
            const remote = std.mem.sliceTo(&zwift_config.remote_host, 0);
            const src = std.mem.sliceTo(&zwift_config.source_folder, 0);
            const should_sync = remote.len > 0 or blk: {
                var src_z_buf: [512]u8 = undefined;
                const src_z = std.fmt.bufPrintZ(&src_z_buf, "{s}", .{src}) catch break :blk false;
                break :blk std.c.access(src_z, 0) == 0;
            };
            if (should_sync) {
                var zprog = zwift_sync.ZwiftSyncProgress{};
                const zimported = zwift_sync.syncActivities(allocator, &zwift_config, data_dir_s, &zprog) catch 0;
                if (zimported > 0) {
                    tree.deinit();
                    tree = activity_tree_mod.ActivityTree.init(allocator);
                    tree.scan(data_dir_s) catch {};
                }
                std.debug.print("Zwift sync: {d} imported\n", .{zimported});
            }
        }
    } else |_| {}

    // Garmin auto-sync
    if (garmin_authenticated) {
        var garmin_list = garmin_sync.GarminActivityList.init(allocator);
        defer garmin_list.deinit();
        garmin_sync.fetchActivities(allocator, &garmin_list, GARMIN_SYNC_LIMIT) catch {};

        var gsynced: i32 = 0;
        for (garmin_list.activities.items) |act| {
            if (activityFileExists(data_dir_s, "garmin_", act.id, ".fit")) continue;
            const st = std.mem.sliceTo(&act.start_time, 0);
            if (st.len >= 10) {
                var odir_buf: [512]u8 = undefined;
                const odir = std.fmt.bufPrint(&odir_buf, "{s}/activity/{s}/{s}", .{ data_dir_s, st[0..4], st[5..7] }) catch continue;
                file_organizer.createDirectoryPath(odir) catch {};
                var opath_buf: [512]u8 = undefined;
                const opath = std.fmt.bufPrint(&opath_buf, "{s}/garmin_{d}.fit", .{ odir, act.id }) catch continue;
                if (garmin_sync.downloadFit(allocator, act.id, opath)) {
                    gsynced += 1;
                } else |_| {}
            }
        }
        if (gsynced > 0) {
            tree.deinit();
            tree = activity_tree_mod.ActivityTree.init(allocator);
            tree.scan(data_dir_s) catch {};
        }
        std.debug.print("Garmin sync: {d} downloaded\n", .{gsynced});
    }

    // --- Main UI state ---
    var current_tab: TabMode = .local;
    var graph_view: GraphViewMode = .summary;
    var selected_tree: usize = 0;
    var tree_scroll: i32 = 0;
    var visible_files: i32 = 15;
    var power_data: ?fit_parser.FitPowerData = null;
    var file_loaded = false;
    var group_datasets_storage: [MAX_GRAPH_DATASETS]*fit_parser.FitPowerData = undefined;
    var group_dataset_count: usize = 0;
    var group_selected = false;
    var smoothing_index: usize = 0;
    var tile_cache: tile_map.TileCache = .{};
    tile_cache.init();
    defer tile_cache.deinit();
    var map_view: tile_map.MapView = .{};
    var act_meta: activity_meta_mod.ActivityMeta = .{};
    var group_meta: activity_meta_mod.GroupMeta = .{};
    var current_group_meta_path: [512]u8 = std.mem.zeroes([512]u8);
    var edit_field: EditField = .none;
    var cursor_pos: i32 = 0;
    var blink_time: f64 = 0;
    var original_title: [256]u8 = std.mem.zeroes([256]u8);
    var original_desc: [2048]u8 = std.mem.zeroes([2048]u8);
    var status_msg: [256]u8 = std.mem.zeroes([256]u8);
    _ = std.fmt.bufPrintZ(&status_msg, "Select a file to view power data", .{}) catch {};
    var current_title: [256]u8 = std.mem.zeroes([256]u8);
    // editing buffers (same backing as power_data fields when loaded)
    var edit_title_buf: [256]u8 = std.mem.zeroes([256]u8);
    var edit_desc_buf: [2048]u8 = std.mem.zeroes([2048]u8);

    // Load first file
    {
        const tv = tree.visibleCount();
        var i: usize = 0;
        while (i < tv) : (i += 1) {
            const node = tree.getVisible(i) orelse continue;
            if (node.type != .file) continue;
            selected_tree = i;
            const path = std.mem.sliceTo(&node.full_path, 0);
            if (loadActivityFile(allocator, path)) |pd| {
                power_data = pd;
                file_loaded = true;
                graph_view = .summary;
                map_view = .{};
                const title = std.mem.sliceTo(&pd.title, 0);
                @memcpy(current_title[0..title.len], title);
                current_title[title.len] = 0;
                @memcpy(edit_title_buf[0..title.len], title);
                edit_title_buf[title.len] = 0;
                const desc = std.mem.sliceTo(&pd.description, 0);
                @memcpy(edit_desc_buf[0..desc.len], desc);
                edit_desc_buf[desc.len] = 0;
                if (activity_meta_mod.loadMeta(allocator, path)) |m| {
                    act_meta = m;
                    if (m.title_edited) {
                        const mt = std.mem.sliceTo(&m.title, 0);
                        @memcpy(edit_title_buf[0..mt.len], mt);
                        edit_title_buf[mt.len] = 0;
                    }
                    if (m.description_edited) {
                        const md = std.mem.sliceTo(&m.description, 0);
                        @memcpy(edit_desc_buf[0..md.len], md);
                        edit_desc_buf[md.len] = 0;
                    }
                } else |_| {}
                @memcpy(&original_title, &edit_title_buf);
                @memcpy(&original_desc, &edit_desc_buf);
            }
            break;
        }
    }

    var prev_edit_field: EditField = .none;

    while (!rl.WindowShouldClose()) {
        const key = rl.GetKeyPressed();
        const mouse = rl.GetMousePosition();

        if (key == rl.KEY_ONE) current_tab = .local;
        if (key == rl.KEY_TWO) current_tab = .settings;
        if (edit_field == .none) {
            if (key == rl.KEY_S) graph_view = .summary;
            if (key == rl.KEY_G) graph_view = .power;
            if (key == rl.KEY_M) {
                if (power_data) |*pd| {
                    if (pd.has_gps_data) graph_view = .map;
                }
            }
        }

        blink_time += rl.GetFrameTime();
        const tree_visible = tree.visibleCount();
        const list_count: i32 = @intCast(tree_visible);

        // Navigation
        if (key == rl.KEY_DOWN or key == rl.KEY_J) {
            if (selected_tree + 1 < tree_visible) {
                selected_tree += 1;
                if (@as(i32, @intCast(selected_tree)) >= tree_scroll + visible_files) {
                    tree_scroll = @as(i32, @intCast(selected_tree)) - visible_files + 1;
                }
            }
        } else if (key == rl.KEY_UP or key == rl.KEY_K) {
            if (selected_tree > 0) {
                selected_tree -= 1;
                if (@as(i32, @intCast(selected_tree)) < tree_scroll) {
                    tree_scroll = @as(i32, @intCast(selected_tree));
                }
            }
        } else if (key == rl.KEY_PAGE_DOWN) {
            selected_tree = @min(selected_tree + @as(usize, @intCast(visible_files)), tree_visible -| 1);
            tree_scroll = @max(0, @as(i32, @intCast(selected_tree)) - visible_files + 1);
        } else if (key == rl.KEY_PAGE_UP) {
            selected_tree -|= @intCast(visible_files);
            tree_scroll = @as(i32, @intCast(selected_tree));
        }

        if (current_tab == .local and tree_visible > 0) {
            if (tree.getVisible(selected_tree)) |sel_node| {
                if (sel_node.type == .year or sel_node.type == .month or sel_node.type == .group) {
                    if (key == rl.KEY_LEFT) sel_node.expanded = false;
                    if (key == rl.KEY_RIGHT) sel_node.expanded = true;
                }
            }
        }

        // Load on Enter/Space
        if ((key == rl.KEY_ENTER or key == rl.KEY_SPACE) and current_tab == .local and tree_visible > 0 and edit_field == .none) {
            if (tree.getVisible(selected_tree)) |node| {
                if (node.type == .file) {
                    if (power_data) |*pd| pd.deinit();
                    freeGroupDatasets(allocator, &group_datasets_storage, group_dataset_count);
                    group_dataset_count = 0;
                    group_selected = false;
                    file_loaded = false;
                    graph_view = .summary;
                    tile_map.freeZwiftMap(&map_view);
                    map_view = .{};
                    power_data = null;

                    const path = std.mem.sliceTo(&node.full_path, 0);
                    if (loadActivityFile(allocator, path)) |pd| {
                        power_data = pd;
                        file_loaded = true;
                        const title = std.mem.sliceTo(&pd.title, 0);
                        @memcpy(edit_title_buf[0..title.len], title);
                        edit_title_buf[title.len] = 0;
                        const desc = std.mem.sliceTo(&pd.description, 0);
                        @memcpy(edit_desc_buf[0..desc.len], desc);
                        edit_desc_buf[desc.len] = 0;
                        act_meta = .{};
                        if (activity_meta_mod.loadMeta(allocator, path)) |m| {
                            act_meta = m;
                            if (m.title_edited) {
                                const mt = std.mem.sliceTo(&m.title, 0);
                                @memcpy(edit_title_buf[0..mt.len], mt);
                                edit_title_buf[mt.len] = 0;
                            }
                            if (m.description_edited) {
                                const md = std.mem.sliceTo(&m.description, 0);
                                @memcpy(edit_desc_buf[0..md.len], md);
                                edit_desc_buf[md.len] = 0;
                            }
                        } else |_| {}
                        @memcpy(&original_title, &edit_title_buf);
                        @memcpy(&original_desc, &edit_desc_buf);
                    }
                } else if (node.type == .group) {
                    if (power_data) |*pd| pd.deinit();
                    freeGroupDatasets(allocator, &group_datasets_storage, group_dataset_count);
                    group_dataset_count = 0;
                    group_selected = true;
                    file_loaded = false;
                    graph_view = .summary;
                    tile_map.freeZwiftMap(&map_view);
                    map_view = .{};
                    power_data = null;

                    const gmp = std.mem.sliceTo(&node.meta_path, 0);
                    @memset(&current_group_meta_path, 0);
                    @memcpy(current_group_meta_path[0..gmp.len], gmp);
                    group_meta = .{};
                    const has_gm = if (activity_meta_mod.loadGroupMeta(allocator, gmp)) |m| blk: {
                        group_meta = m;
                        break :blk true;
                    } else |_| false;

                    var loaded: usize = 0;
                    for (node.children.items) |*child| {
                        if (loaded >= MAX_GRAPH_DATASETS) break;
                        if (child.type != .file) continue;
                        const cpath = std.mem.sliceTo(&child.full_path, 0);
                        const ds = allocator.create(fit_parser.FitPowerData) catch continue;
                        if (loadActivityFile(allocator, cpath)) |pd| {
                            ds.* = pd;
                            var cmeta: activity_meta_mod.ActivityMeta = .{};
                            if (activity_meta_mod.loadMeta(allocator, cpath)) |m| cmeta = m else |_| {}
                            if (cmeta.title_edited) {
                                const mt = std.mem.sliceTo(&cmeta.title, 0);
                                @memcpy(ds.title[0..mt.len], mt);
                                ds.title[mt.len] = 0;
                            }
                            group_datasets_storage[loaded] = ds;
                            loaded += 1;
                        } else {
                            allocator.destroy(ds);
                        }
                    }
                    group_dataset_count = loaded;

                    if (loaded > 0) {
                        file_loaded = true;
                        var dummy = fit_parser.FitPowerData.init(allocator);
                        const first = group_datasets_storage[0];
                        @memcpy(&dummy.title, &first.title);
                        @memcpy(&dummy.description, &first.description);
                        dummy.avg_power = first.avg_power;
                        dummy.max_power = first.max_power;
                        dummy.min_power = first.min_power;
                        if (has_gm and group_meta.title_edited) @memcpy(&dummy.title, &group_meta.title);
                        if (has_gm and group_meta.description_edited) @memcpy(&dummy.description, &group_meta.description);
                        power_data = dummy;
                        const title = std.mem.sliceTo(&dummy.title, 0);
                        @memcpy(edit_title_buf[0..title.len], title);
                        edit_title_buf[title.len] = 0;
                        const desc = std.mem.sliceTo(&dummy.description, 0);
                        @memcpy(edit_desc_buf[0..desc.len], desc);
                        edit_desc_buf[desc.len] = 0;
                        @memcpy(&original_title, &edit_title_buf);
                        @memcpy(&original_desc, &edit_desc_buf);
                    }
                } else {
                    node.expanded = !node.expanded;
                }
            }
        }

        // Mouse wheel
        const wheel = rl.GetMouseWheelMove();
        if (wheel != 0 and mouse.x < 375) {
            tree_scroll -= @as(i32, @intFromFloat(wheel)) * 3;
            if (tree_scroll < 0) tree_scroll = 0;
            const max_scroll = list_count - visible_files;
            if (tree_scroll > max_scroll) tree_scroll = @max(0, max_scroll);
        }

        // Text editing
        if (edit_field != .none) {
            const is_title = edit_field == .title;
            const text_buf: []u8 = if (is_title) &edit_title_buf else &edit_desc_buf;
            const max_len: usize = if (is_title) edit_title_buf.len - 1 else edit_desc_buf.len - 1;
            const text_len = bufLen(text_buf);

            var ch: i32 = rl.GetCharPressed();
            while (ch != 0) {
                if (ch >= 32 and ch < 127 and text_len < max_len) {
                    const cp: usize = @intCast(cursor_pos);
                    std.mem.copyBackwards(u8, text_buf[cp + 1 .. text_len + 1], text_buf[cp..text_len]);
                    text_buf[cp] = @intCast(ch);
                    cursor_pos += 1;
                }
                ch = rl.GetCharPressed();
            }

            if (rl.IsKeyPressed(rl.KEY_BACKSPACE) and cursor_pos > 0) {
                const cp: usize = @intCast(cursor_pos);
                std.mem.copyForwards(u8, text_buf[cp - 1 .. text_len], text_buf[cp..text_len]);
                text_buf[text_len - 1] = 0;
                cursor_pos -= 1;
            }
            if (rl.IsKeyPressed(rl.KEY_DELETE) and cursor_pos < @as(i32, @intCast(text_len))) {
                const cp: usize = @intCast(cursor_pos);
                std.mem.copyForwards(u8, text_buf[cp..text_len], text_buf[cp + 1 .. text_len + 1]);
                text_buf[text_len] = 0;
            }
            if (rl.IsKeyPressed(rl.KEY_LEFT) and cursor_pos > 0) cursor_pos -= 1;
            if (rl.IsKeyPressed(rl.KEY_RIGHT) and cursor_pos < @as(i32, @intCast(text_len))) cursor_pos += 1;
            if (rl.IsKeyPressed(rl.KEY_HOME)) cursor_pos = 0;
            if (rl.IsKeyPressed(rl.KEY_END)) cursor_pos = @intCast(text_len);

            if (rl.IsKeyPressed(rl.KEY_ENTER)) {
                if (edit_field == .title) {
                    edit_field = .none;
                } else if (text_len < max_len) {
                    const cp: usize = @intCast(cursor_pos);
                    std.mem.copyBackwards(u8, text_buf[cp + 1 .. text_len + 1], text_buf[cp..text_len]);
                    text_buf[cp] = '\n';
                    cursor_pos += 1;
                }
            }
            if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
                if (edit_field == .title) {
                    @memcpy(&edit_title_buf, &original_title);
                } else {
                    @memcpy(&edit_desc_buf, &original_desc);
                }
                edit_field = .none;
            }
        }

        // ---- Drawing ----
        rl.BeginDrawing();
        rl.ClearBackground(.{ .r = 20, .g = 20, .b = 25, .a = 255 });

        visible_files = @divTrunc(rl.GetScreenHeight() - 110, 25);
        if (visible_files < 5) visible_files = 5;

        drawTextF("Sweattrails", 10, 10, 26, rl.WHITE);

        const tab_y = 45;
        if (drawButton(10, tab_y, 90, 25, "1: Local", true)) current_tab = .local;
        if (current_tab == .local) rl.DrawRectangle(10, tab_y + 23, 90, 2, .{ .r = 100, .g = 150, .b = 255, .a = 255 });
        if (drawButton(105, tab_y, 110, 25, "2: Settings", true)) current_tab = .settings;
        if (current_tab == .settings) rl.DrawRectangle(105, tab_y + 23, 110, 2, .{ .r = 100, .g = 150, .b = 255, .a = 255 });

        const list_y = tab_y + 35;
        rl.DrawRectangle(5, list_y, 365, visible_files * 25 + 10, .{ .r = 35, .g = 35, .b = 45, .a = 255 });

        if (current_tab == .local) {
            drawTextF("Activities:", 10, list_y + 5, 15, rl.LIGHTGRAY);

            var vi: i32 = 0;
            while (vi < visible_files and vi + tree_scroll < list_count) : (vi += 1) {
                const node_idx: usize = @intCast(vi + tree_scroll);
                const vy = list_y + 25 + vi * 25;
                const node = tree.getVisible(node_idx) orelse continue;

                const hover = mouse.x >= 8 and mouse.x < 367 and mouse.y >= @as(f32, @floatFromInt(vy - 2)) and mouse.y < @as(f32, @floatFromInt(vy + 20));

                if (node_idx == selected_tree) {
                    rl.DrawRectangle(8, vy - 2, 359, 22, .{ .r = 60, .g = 80, .b = 120, .a = 255 });
                } else if (hover) {
                    rl.DrawRectangle(8, vy - 2, 359, 22, .{ .r = 45, .g = 45, .b = 55, .a = 255 });
                }

                if (hover and rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON)) {
                    // Save pending edits
                    if (edit_field != .none and file_loaded) {
                        savePendingEdits(allocator, &edit_field, &edit_title_buf, &edit_desc_buf, &original_title, &original_desc, &power_data, &act_meta, &group_meta, &current_group_meta_path, &tree, selected_tree, group_selected);
                    }
                    selected_tree = node_idx;
                    if (node.type == .file) {
                        if (power_data) |*pd| pd.deinit();
                        freeGroupDatasets(allocator, &group_datasets_storage, group_dataset_count);
                        group_dataset_count = 0;
                        group_selected = false;
                        file_loaded = false;
                        graph_view = .summary;
                        tile_map.freeZwiftMap(&map_view);
                        map_view = .{};
                        power_data = null;
                        const path = std.mem.sliceTo(&node.full_path, 0);
                        if (loadActivityFile(allocator, path)) |pd| {
                            power_data = pd;
                            file_loaded = true;
                            const title = std.mem.sliceTo(&pd.title, 0);
                            @memcpy(edit_title_buf[0..title.len], title);
                            edit_title_buf[title.len] = 0;
                            const desc = std.mem.sliceTo(&pd.description, 0);
                            @memcpy(edit_desc_buf[0..desc.len], desc);
                            edit_desc_buf[desc.len] = 0;
                            act_meta = .{};
                            if (activity_meta_mod.loadMeta(allocator, path)) |m| {
                                act_meta = m;
                                if (m.title_edited) { const mt = std.mem.sliceTo(&m.title, 0); @memcpy(edit_title_buf[0..mt.len], mt); edit_title_buf[mt.len] = 0; }
                                if (m.description_edited) { const md = std.mem.sliceTo(&m.description, 0); @memcpy(edit_desc_buf[0..md.len], md); edit_desc_buf[md.len] = 0; }
                            } else |_| {}
                            @memcpy(&original_title, &edit_title_buf);
                            @memcpy(&original_desc, &edit_desc_buf);
                        }
                    } else if (node.type == .group) {
                        if (power_data) |*pd| pd.deinit();
                        freeGroupDatasets(allocator, &group_datasets_storage, group_dataset_count);
                        group_dataset_count = 0;
                        group_selected = true;
                        file_loaded = false;
                        graph_view = .summary;
                        tile_map.freeZwiftMap(&map_view);
                        map_view = .{};
                        power_data = null;
                        const gmp = std.mem.sliceTo(&node.meta_path, 0);
                        @memset(&current_group_meta_path, 0);
                        @memcpy(current_group_meta_path[0..gmp.len], gmp);
                        group_meta = .{};
                        const has_gm = if (activity_meta_mod.loadGroupMeta(allocator, gmp)) |m| blk: { group_meta = m; break :blk true; } else |_| false;
                        var loaded: usize = 0;
                        for (node.children.items) |*child| {
                            if (loaded >= MAX_GRAPH_DATASETS) break;
                            if (child.type != .file) continue;
                            const cpath = std.mem.sliceTo(&child.full_path, 0);
                            const ds = allocator.create(fit_parser.FitPowerData) catch continue;
                            if (loadActivityFile(allocator, cpath)) |pd| {
                                ds.* = pd;
                                var cmeta: activity_meta_mod.ActivityMeta = .{};
                                if (activity_meta_mod.loadMeta(allocator, cpath)) |m| cmeta = m else |_| {}
                                if (cmeta.title_edited) { const mt = std.mem.sliceTo(&cmeta.title, 0); @memcpy(ds.title[0..mt.len], mt); ds.title[mt.len] = 0; }
                                group_datasets_storage[loaded] = ds;
                                loaded += 1;
                            } else { allocator.destroy(ds); }
                        }
                        group_dataset_count = loaded;
                        if (loaded > 0) {
                            file_loaded = true;
                            var dummy = fit_parser.FitPowerData.init(allocator);
                            const first = group_datasets_storage[0];
                            @memcpy(&dummy.title, &first.title);
                            @memcpy(&dummy.description, &first.description);
                            if (has_gm and group_meta.title_edited) @memcpy(&dummy.title, &group_meta.title);
                            if (has_gm and group_meta.description_edited) @memcpy(&dummy.description, &group_meta.description);
                            power_data = dummy;
                            const title = std.mem.sliceTo(&dummy.title, 0);
                            @memcpy(edit_title_buf[0..title.len], title);
                            edit_title_buf[title.len] = 0;
                            const desc = std.mem.sliceTo(&dummy.description, 0);
                            @memcpy(edit_desc_buf[0..desc.len], desc);
                            edit_desc_buf[desc.len] = 0;
                            @memcpy(&original_title, &edit_title_buf);
                            @memcpy(&original_desc, &edit_desc_buf);
                        }
                    } else {
                        node.expanded = !node.expanded;
                    }
                }

                var indent: i32 = 0;
                var prefix_buf: [8]u8 = std.mem.zeroes([8]u8);
                var text_color: rl.Color = if (node_idx == selected_tree) rl.WHITE else rl.LIGHTGRAY;

                switch (node.type) {
                    .year => {
                        _ = std.fmt.bufPrintZ(&prefix_buf, "{s} ", .{if (node.expanded) "[-]" else "[+]"}) catch {};
                        text_color = if (node_idx == selected_tree) rl.WHITE else rl.Color{ .r = 150, .g = 180, .b = 255, .a = 255 };
                    },
                    .month => {
                        indent = 16;
                        _ = std.fmt.bufPrintZ(&prefix_buf, "{s} ", .{if (node.expanded) "[-]" else "[+]"}) catch {};
                        text_color = if (node_idx == selected_tree) rl.WHITE else rl.Color{ .r = 180, .g = 200, .b = 150, .a = 255 };
                    },
                    .group => {
                        indent = 32;
                        _ = std.fmt.bufPrintZ(&prefix_buf, "{s} ", .{if (node.expanded) "[-]" else "[+]"}) catch {};
                        text_color = if (node_idx == selected_tree) rl.WHITE else rl.Color{ .r = 255, .g = 200, .b = 150, .a = 255 };
                    },
                    .file => {
                        indent = 32;
                        // Check if under a group
                        var li: i32 = @as(i32, @intCast(node_idx)) - 1;
                        while (li >= 0) : (li -= 1) {
                            const parent = tree.getVisible(@intCast(li)) orelse break;
                            if (parent.type == .group and parent.expanded) { indent = 48; break; }
                            if (parent.type == .month or parent.type == .year) break;
                        }
                    },
                }

                const display_text = if (node.type == .file or node.type == .group) std.mem.sliceTo(&node.display_title, 0) else std.mem.sliceTo(&node.name, 0);
                const prefix = std.mem.sliceTo(&prefix_buf, 0);
                const max_chars: usize = @intCast(@max(1, 40 - @divTrunc(indent, 8)));
                const truncated = if (display_text.len > max_chars) display_text[0..max_chars] else display_text;
                var disp_buf2: [64]u8 = undefined;
                const disp = std.fmt.bufPrintZ(&disp_buf2, "{s}{s}{s}", .{ prefix, truncated, if (display_text.len > max_chars) "..." else "" }) catch continue;
                drawTextF(disp.ptr, 12 + indent, vy, 15, text_color);
            }

            if (tree_scroll > 0) drawTextF("^", 145, list_y + 8, 15, rl.GRAY);
            if (tree_scroll + visible_files < list_count) drawTextF("v", 145, list_y + visible_files * 25 + 5, 15, rl.GRAY);

            if (tree_visible == 0) {
                drawTextF("No activities found.", 12, list_y + 30, 14, rl.GRAY);
                drawTextF("Drop .fit files in:", 12, list_y + 50, 14, rl.GRAY);
                if (builtin.os.tag == .macos) {
                    drawTextF("~/Library/Application Support/", 12, list_y + 70, 13, .{ .r = 100, .g = 150, .b = 200, .a = 255 });
                    drawTextF("fitpower/inbox/", 12, list_y + 88, 13, .{ .r = 100, .g = 150, .b = 200, .a = 255 });
                } else {
                    drawTextF("~/.local/share/fitpower/inbox/", 12, list_y + 70, 13, .{ .r = 100, .g = 150, .b = 200, .a = 255 });
                }
            }
        } else { // Settings tab
            var sec_y: i32 = list_y + 10;
            const strava_orange2 = rl.Color{ .r = 252, .g = 82, .b = 0, .a = 255 };
            const wahoo_yellow2 = rl.Color{ .r = 255, .g = 193, .b = 7, .a = 255 };
            const garmin_blue = rl.Color{ .r = 0, .g = 148, .b = 218, .a = 255 };

            if (!strava_api.isAuthenticated(&strava_config)) {
                drawTextF("Strava: Not connected", 10, sec_y, 15, strava_orange2);
                if (drawButton(10, sec_y + 25, 355, 30, "Connect to Strava", strava_config_loaded)) {
                    rl.EndDrawing();
                    drawBusyModal("Strava", "Waiting for browser authentication...", strava_orange2);
                    if (strava_api.authenticate(&strava_config)) {
                        _ = std.fmt.bufPrintZ(&status_msg, "Connected to Strava!", .{}) catch {};
                    } else |_| {
                        _ = std.fmt.bufPrintZ(&status_msg, "Strava authentication failed", .{}) catch {};
                    }
                    rl.BeginDrawing();
                }
                sec_y += 65;
            } else {
                drawTextF("Strava: Connected", 10, sec_y, 15, strava_orange2);
                if (drawButton(220, sec_y - 3, 100, 22, "Disconnect", true)) {
                    rl.EndDrawing();
                    drawBusyModal("Strava", "Disconnecting...", strava_orange2);
                    @memset(&strava_config.access_token, 0);
                    @memset(&strava_config.refresh_token, 0);
                    strava_config.token_expires_at = 0;
                    strava_api.saveConfig(&strava_config) catch {};
                    _ = std.fmt.bufPrintZ(&status_msg, "Disconnected from Strava", .{}) catch {};
                    rl.BeginDrawing();
                }
                sec_y += 25;
            }

            rl.DrawLine(10, sec_y + 5, 365, sec_y + 5, .{ .r = 60, .g = 60, .b = 70, .a = 255 });
            sec_y += 15;

            if (!wahoo_api.isAuthenticated(&wahoo_config)) {
                drawTextF("Wahoo: Not connected", 10, sec_y, 15, wahoo_yellow2);
                if (drawButton(10, sec_y + 25, 355, 30, "Connect to Wahoo", wahoo_config_loaded)) {
                    rl.EndDrawing();
                    drawBusyModal("Wahoo", "Waiting for browser authentication...", wahoo_yellow2);
                    if (wahoo_api.authenticate(allocator, &wahoo_config)) {
                        _ = std.fmt.bufPrintZ(&status_msg, "Connected to Wahoo!", .{}) catch {};
                    } else |_| {
                        _ = std.fmt.bufPrintZ(&status_msg, "Wahoo authentication failed", .{}) catch {};
                    }
                    rl.BeginDrawing();
                }
                sec_y += 65;
            } else {
                drawTextF("Wahoo: Connected", 10, sec_y, 15, wahoo_yellow2);
                if (drawButton(220, sec_y - 3, 100, 22, "Disconnect", true)) {
                    rl.EndDrawing();
                    drawBusyModal("Wahoo", "Disconnecting...", wahoo_yellow2);
                    @memset(&wahoo_config.access_token, 0);
                    @memset(&wahoo_config.refresh_token, 0);
                    wahoo_config.token_expires_at = 0;
                    wahoo_api.saveConfig(&wahoo_config) catch {};
                    _ = std.fmt.bufPrintZ(&status_msg, "Disconnected from Wahoo", .{}) catch {};
                    rl.BeginDrawing();
                }
                sec_y += 25;
            }

            rl.DrawLine(10, sec_y + 5, 365, sec_y + 5, .{ .r = 60, .g = 60, .b = 70, .a = 255 });
            sec_y += 15;

            if (!garmin_authenticated) {
                drawTextF("Garmin: Not connected", 10, sec_y, 15, garmin_blue);
                if (drawButton(10, sec_y + 25, 355, 30, "Connect to Garmin", garmin_config_loaded)) {
                    var gcfg = garmin_sync.loadConfig(allocator) catch garmin_sync.GarminConfig{};
                    rl.EndDrawing();
                    drawBusyModal("Garmin", "Authenticating...", garmin_blue);
                    if (garmin_sync.authenticate(allocator, &gcfg)) {
                        garmin_authenticated = true;
                        _ = std.fmt.bufPrintZ(&status_msg, "Connected to Garmin!", .{}) catch {};
                    } else |_| {
                        _ = std.fmt.bufPrintZ(&status_msg, "Garmin authentication failed", .{}) catch {};
                    }
                    rl.BeginDrawing();
                }
                sec_y += 65;
            } else {
                drawTextF("Garmin: Connected", 10, sec_y, 15, garmin_blue);
                if (drawButton(220, sec_y - 3, 100, 22, "Disconnect", true)) {
                    rl.EndDrawing();
                    drawBusyModal("Garmin", "Disconnecting...", garmin_blue);
                    garmin_sync.disconnect() catch {};
                    garmin_authenticated = false;
                    _ = std.fmt.bufPrintZ(&status_msg, "Disconnected from Garmin", .{}) catch {};
                    rl.BeginDrawing();
                }
                sec_y += 25;
            }

            rl.DrawLine(10, sec_y + 5, 365, sec_y + 5, .{ .r = 60, .g = 60, .b = 70, .a = 255 });
            sec_y += 15;
            drawTextF("Tools", 10, sec_y, 15, rl.LIGHTGRAY);
            sec_y += 25;
            if (drawButton(10, sec_y, 355, 30, "Match Activities", true)) {
                tree.scan(data_dir_s) catch {};
                _ = std.fmt.bufPrintZ(&status_msg, "Activity matching complete", .{}) catch {};
            }
        }

        // Graph area
        const graph_x = 400 + GRAPH_MARGIN_LEFT;
        const graph_y = GRAPH_MARGIN_TOP;
        const graph_w = rl.GetScreenWidth() - 400 - GRAPH_MARGIN_LEFT - GRAPH_MARGIN_RIGHT;
        const graph_h = rl.GetScreenHeight() - GRAPH_MARGIN_TOP - GRAPH_MARGIN_BOTTOM - 40;

        if (file_loaded and power_data != null) {
            const pd = &power_data.?;
            const has_samples = (group_selected and group_dataset_count > 0) or (!group_selected and pd.samples.items.len > 0);
            if (has_samples) {
                const view_name: [*:0]const u8 = switch (graph_view) {
                    .summary => "Summary",
                    .power => "Power Graph",
                    .map => "Map",
                };
                var title_buf2: [300]u8 = undefined;
                const title_disp = std.fmt.bufPrintZ(&title_buf2, "{s} - {s}", .{ view_name, std.mem.sliceTo(&edit_title_buf, 0) }) catch "Activity";
                drawTextF(title_disp.ptr, 400, 15, 18, rl.WHITE);

                const display_pd: *const fit_parser.FitPowerData = if (group_selected and group_dataset_count > 0) group_datasets_storage[0] else pd;
                var stats_buf: [256]u8 = undefined;
                const stats = std.fmt.bufPrintZ(&stats_buf, "Min: {d}W | Max: {d}W | Avg: {d:.0}W | Samples: {d}", .{ display_pd.min_power, display_pd.max_power, display_pd.avg_power, display_pd.samples.items.len }) catch "";
                drawTextF(stats.ptr, 400, 40, 15, rl.LIGHTGRAY);

                const tab_btn_y = 58;
                var btn_x: i32 = 400;
                if (drawButton(btn_x, tab_btn_y, 85, 20, "S: Summary", true)) graph_view = .summary;
                if (graph_view == .summary) rl.DrawRectangle(btn_x, tab_btn_y + 18, 85, 2, .{ .r = 200, .g = 150, .b = 100, .a = 255 });
                btn_x += 90;
                if (drawButton(btn_x, tab_btn_y, 70, 20, "G: Graph", true)) graph_view = .power;
                if (graph_view == .power) rl.DrawRectangle(btn_x, tab_btn_y + 18, 70, 2, .{ .r = 100, .g = 150, .b = 255, .a = 255 });
                btn_x += 75;
                const has_gps = pd.has_gps_data;
                if (drawButton(btn_x, tab_btn_y, 60, 20, "M: Map", has_gps)) {
                    if (has_gps) graph_view = .map;
                }
                if (graph_view == .map) rl.DrawRectangle(btn_x, tab_btn_y + 18, 60, 2, .{ .r = 100, .g = 200, .b = 100, .a = 255 });

                const content_y = tab_btn_y + 25;
                const content_h = graph_h - (content_y - graph_y);

                if (graph_view == .summary) {
                    var group_ptrs: [MAX_GRAPH_DATASETS]*const fit_parser.FitPowerData = undefined;
                    var gcount: usize = 0;
                    if (group_selected) {
                        for (group_datasets_storage[0..group_dataset_count]) |ds| {
                            group_ptrs[gcount] = ds;
                            gcount += 1;
                        }
                    }
                    const clicked_idx = drawSummaryTab(display_pd, &edit_field, &edit_title_buf, &edit_desc_buf, &cursor_pos, blink_time, 400, content_y, graph_w + GRAPH_MARGIN_LEFT, content_h, group_selected, group_ptrs[0..gcount]);

                    if (clicked_idx >= 0 and group_selected) {
                        const ci: usize = @intCast(clicked_idx);
                        if (ci < group_dataset_count) {
                            const child_ds = group_datasets_storage[ci];
                            if (power_data) |*opd| opd.deinit();
                            var new_pd = fit_parser.FitPowerData.init(allocator);
                            new_pd = child_ds.*;
                            new_pd.allocator = allocator;
                            new_pd.samples = .empty;
                            for (child_ds.samples.items) |s| new_pd.samples.append(allocator, s) catch {};
                            freeGroupDatasets(allocator, &group_datasets_storage, group_dataset_count);
                            group_dataset_count = 0;
                            group_selected = false;
                            power_data = new_pd;
                            const t2 = std.mem.sliceTo(&new_pd.title, 0);
                            @memcpy(edit_title_buf[0..t2.len], t2);
                            edit_title_buf[t2.len] = 0;
                            const d2 = std.mem.sliceTo(&new_pd.description, 0);
                            @memcpy(edit_desc_buf[0..d2.len], d2);
                            edit_desc_buf[d2.len] = 0;
                            @memcpy(&original_title, &edit_title_buf);
                            @memcpy(&original_desc, &edit_desc_buf);
                        }
                    }
                } else if (graph_view == .map and has_gps) {
                    if (map_view.zoom == 0) {
                        tile_map.mapViewFitBounds(&map_view, pd.min_lat, pd.max_lat, pd.min_lon, pd.max_lon, graph_w, content_h);
                        if (map_view.source == .zwift and map_view.zwift_world != null) {
                            const cd = std.mem.sliceTo(&tile_cache.cache_dir, 0);
                            tile_map.loadZwiftMap(&map_view, cd) catch {};
                        }
                    }
                    map_view.view_width = graph_w;
                    map_view.view_height = content_h;

                    if (map_view.source == .zwift and map_view.zwift_map_loaded) {
                        tile_map.drawZwiftMap(&map_view, graph_x, content_y);
                        tile_map.drawZwiftPath(&map_view, graph_x, content_y, pd.samples.items);
                    } else {
                        tile_map.drawTileMap(&tile_cache, &map_view, graph_x, content_y);
                        tile_map.drawPath(&map_view, graph_x, content_y, pd.samples.items);
                    }
                    tile_map.drawAttribution(&map_view, graph_x + graph_w - 200, content_y + content_h - 18, 12);
                } else {
                    // Power graph with smoothing slider
                    const slider_x = graph_x;
                    const slider_y = content_y;
                    const slider_w = graph_w;
                    drawTextF("Smoothing:", slider_x - 75, slider_y + 5, 14, rl.LIGHTGRAY);
                    const track_y = slider_y + 10;
                    rl.DrawRectangle(slider_x, track_y, slider_w, 4, .{ .r = 60, .g = 60, .b = 70, .a = 255 });

                    for (smoothing_options, 0..) |opt, si| {
                        const stop_ratio: f32 = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(smoothing_options.len - 1));
                        const stop_x = slider_x + @as(i32, @intFromFloat(stop_ratio * @as(f32, @floatFromInt(slider_w))));
                        rl.DrawRectangle(stop_x - 2, track_y - 2, 4, 8, .{ .r = 80, .g = 80, .b = 90, .a = 255 });
                        const lw = measureTextF(opt.label, 12);
                        drawTextF(opt.label, stop_x - @divTrunc(lw, 2), slider_y + 18, 12, if (si == smoothing_index) rl.WHITE else rl.GRAY);
                    }
                    const handle_ratio: f32 = @as(f32, @floatFromInt(smoothing_index)) / @as(f32, @floatFromInt(smoothing_options.len - 1));
                    const handle_x = slider_x + @as(i32, @intFromFloat(handle_ratio * @as(f32, @floatFromInt(slider_w))));
                    rl.DrawCircle(handle_x, track_y + 2, 8, .{ .r = 100, .g = 150, .b = 255, .a = 255 });
                    rl.DrawCircle(handle_x, track_y + 2, 5, rl.WHITE);

                    if (rl.IsMouseButtonDown(rl.MOUSE_LEFT_BUTTON)) {
                        if (mouse.y >= @as(f32, @floatFromInt(slider_y)) and mouse.y <= @as(f32, @floatFromInt(slider_y + 35)) and mouse.x >= @as(f32, @floatFromInt(slider_x - 10)) and mouse.x <= @as(f32, @floatFromInt(slider_x + slider_w + 10))) {
                            var cr = (mouse.x - @as(f32, @floatFromInt(slider_x))) / @as(f32, @floatFromInt(slider_w));
                            if (cr < 0) cr = 0;
                            if (cr > 1) cr = 1;
                            smoothing_index = @intFromFloat(cr * @as(f32, @floatFromInt(smoothing_options.len - 1)) + 0.5);
                        }
                    }

                    const gcontent_y = content_y + 35;
                    const gcontent_h = content_h - 35;
                    const smooth_s = smoothing_options[smoothing_index].seconds;

                    if (group_selected and group_dataset_count > 0) {
                        var gptrs: [MAX_GRAPH_DATASETS]*const fit_parser.FitPowerData = undefined;
                        for (group_datasets_storage[0..group_dataset_count], 0..) |ds, gi| gptrs[gi] = ds;
                        drawPowerGraphMulti(gptrs[0..group_dataset_count], graph_x, gcontent_y, graph_w, gcontent_h, smooth_s, allocator);
                    } else {
                        const single = [_]*const fit_parser.FitPowerData{pd};
                        drawPowerGraphMulti(&single, graph_x, gcontent_y, graph_w, gcontent_h, smooth_s, allocator);
                    }
                }
            }
        } else {
            rl.DrawRectangle(graph_x, graph_y, graph_w, graph_h, .{ .r = 30, .g = 30, .b = 40, .a = 255 });
            const msg: [*:0]const u8 = if (current_tab == .settings)
                "Settings"
            else if (tree_visible > 0)
                "Select an activity"
            else if (builtin.os.tag == .macos)
                "Drop .fit files in ~/Library/Application Support/fitpower/inbox/"
            else
                "Drop .fit files in ~/.local/share/fitpower/inbox/";
            const tw2 = measureTextF(msg, 18);
            drawTextF(msg, graph_x + @divTrunc(graph_w - tw2, 2), graph_y + @divTrunc(graph_h, 2), 20, rl.GRAY);
        }

        drawTextF("Up/Down: Navigate | Left/Right: Collapse/Expand | S/G/M: Summary/Graph/Map | ESC: Quit", 10, rl.GetScreenHeight() - 25, 14, rl.GRAY);
        rl.EndDrawing();

        // Save when editing stops
        if (prev_edit_field != .none and edit_field == .none and file_loaded) {
            const title_changed = !std.mem.eql(u8, std.mem.sliceTo(&edit_title_buf, 0), std.mem.sliceTo(&original_title, 0));
            const desc_changed = !std.mem.eql(u8, std.mem.sliceTo(&edit_desc_buf, 0), std.mem.sliceTo(&original_desc, 0));

            if (title_changed or desc_changed) {
                if (group_selected) {
                    if (title_changed) { @memcpy(&group_meta.title, &edit_title_buf); group_meta.title_edited = true; }
                    if (desc_changed) { @memcpy(&group_meta.description, &edit_desc_buf); group_meta.description_edited = true; }
                    const gmp = std.mem.sliceTo(&current_group_meta_path, 0);
                    if (gmp.len > 0) activity_meta_mod.saveGroupMeta(gmp, &group_meta) catch {};
                    if (title_changed) {
                        if (tree.getVisible(selected_tree)) |gn| {
                            if (gn.type == .group) {
                                const new_title = std.mem.sliceTo(&edit_title_buf, 0);
                                _ = std.fmt.bufPrintZ(&gn.display_title, "{s} ({d})", .{ new_title, gn.children.items.len }) catch {};
                                const dt_s = std.mem.sliceTo(&gn.display_title, 0);
                                const dt_n = @min(dt_s.len, gn.name.len - 1);
                                @memcpy(gn.name[0..dt_n], dt_s[0..dt_n]);
                                gn.name[dt_n] = 0;
                            }
                        }
                    }
                } else {
                    if (title_changed) { @memcpy(&act_meta.title, &edit_title_buf); act_meta.title_edited = true; }
                    if (desc_changed) { @memcpy(&act_meta.description, &edit_desc_buf); act_meta.description_edited = true; }
                    if (power_data) |*pd| {
                        activity_meta_mod.saveMeta(std.mem.sliceTo(&pd.source_file, 0), &act_meta) catch {};
                        if (title_changed) {
                            if (tree.getVisible(selected_tree)) |fn2| {
                                if (fn2.type == .file) {
                                    const et_s = std.mem.sliceTo(&edit_title_buf, 0);
                                    const et_n = @min(et_s.len, fn2.display_title.len - 1);
                                    @memcpy(fn2.display_title[0..et_n], et_s[0..et_n]);
                                    fn2.display_title[et_n] = 0;
                                }
                            }
                        }
                    }
                }
                @memcpy(&original_title, &edit_title_buf);
                @memcpy(&original_desc, &edit_desc_buf);
            }
        }
        prev_edit_field = edit_field;
    }

    // Cleanup
    tile_map.freeZwiftMap(&map_view);
    if (power_data) |*pd| pd.deinit();
    freeGroupDatasets(allocator, &group_datasets_storage, group_dataset_count);
    if (g_font_loaded) rl.UnloadFont(g_font);
    rl.CloseWindow();
}

fn savePendingEdits(
    allocator: std.mem.Allocator,
    edit_field: *EditField,
    edit_title: []const u8,
    edit_desc: []const u8,
    original_title: []const u8,
    original_desc: []const u8,
    power_data: *?fit_parser.FitPowerData,
    act_meta: *activity_meta_mod.ActivityMeta,
    group_meta: *activity_meta_mod.GroupMeta,
    group_meta_path: *[512]u8,
    tree: *activity_tree_mod.ActivityTree,
    selected: usize,
    group_selected: bool,
) void {
    _ = allocator;
    const title_changed = !std.mem.eql(u8, std.mem.sliceTo(edit_title, 0), std.mem.sliceTo(original_title, 0));
    const desc_changed = !std.mem.eql(u8, std.mem.sliceTo(edit_desc, 0), std.mem.sliceTo(original_desc, 0));
    if (title_changed or desc_changed) {
        if (group_selected) {
            if (title_changed) { @memcpy(&group_meta.title, edit_title[0..@min(edit_title.len, group_meta.title.len)]); group_meta.title_edited = true; }
            if (desc_changed) { @memcpy(&group_meta.description, edit_desc[0..@min(edit_desc.len, group_meta.description.len)]); group_meta.description_edited = true; }
            const gmp = std.mem.sliceTo(group_meta_path, 0);
            if (gmp.len > 0) activity_meta_mod.saveGroupMeta(gmp, group_meta) catch {};
        } else {
            if (title_changed) { @memcpy(&act_meta.title, edit_title[0..@min(edit_title.len, act_meta.title.len)]); act_meta.title_edited = true; }
            if (desc_changed) { @memcpy(&act_meta.description, edit_desc[0..@min(edit_desc.len, act_meta.description.len)]); act_meta.description_edited = true; }
            if (power_data.*) |*pd| {
                activity_meta_mod.saveMeta(std.mem.sliceTo(&pd.source_file, 0), act_meta) catch {};
                if (title_changed) {
                    if (tree.getVisible(selected)) |fn2| {
                        if (fn2.type == .file) @memcpy(fn2.display_title[0..@min(edit_title.len, fn2.display_title.len)], edit_title[0..@min(edit_title.len, fn2.display_title.len)]);
                    }
                }
            }
        }
    }
    edit_field.* = .none;
}
