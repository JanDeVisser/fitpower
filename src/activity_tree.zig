const std = @import("std");
const activity_meta = @import("activity_meta.zig");
const file_organizer = @import("file_organizer.zig");

pub const OVERLAP_THRESHOLD: i64 = 600;

const month_names = [_][]const u8{
    "", "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
};

pub fn getMonthName(month: i32) []const u8 {
    if (month < 1 or month > 12) return "";
    return month_names[@intCast(month)];
}

pub const NodeType = enum { year, month, group, file };

pub const TreeNode = struct {
    type: NodeType,
    name: [64]u8 = std.mem.zeroes([64]u8),
    display_title: [128]u8 = std.mem.zeroes([128]u8),
    full_path: [512]u8 = std.mem.zeroes([512]u8),
    meta_path: [512]u8 = std.mem.zeroes([512]u8),
    activity_time: i64 = 0,
    expanded: bool = false,
    children: std.ArrayList(TreeNode),

    pub fn init(_: std.mem.Allocator) TreeNode {
        return .{
            .type = .file,
            .children = .empty,
        };
    }

    pub fn deinit(self: *TreeNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit(allocator);
    }
};

pub const ActivityTree = struct {
    years: std.ArrayList(TreeNode),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ActivityTree {
        return .{
            .years = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ActivityTree) void {
        for (self.years.items) |*year| {
            year.deinit(self.allocator);
        }
        self.years.deinit(self.allocator);
    }

    pub fn scan(self: *ActivityTree, data_dir: []const u8) !void {
        for (self.years.items) |*year| {
            year.deinit(self.allocator);
        }
        self.years.clearRetainingCapacity();

        var activity_dir_buf: [512]u8 = undefined;
        const activity_dir = try std.fmt.bufPrint(&activity_dir_buf, "{s}/activity", .{data_dir});

        file_organizer.createDirectoryPath(activity_dir) catch {};

        var activity_z_buf: [512]u8 = undefined;
        const activity_z = try std.fmt.bufPrintZ(&activity_z_buf, "{s}", .{activity_dir});

        const year_dir = std.c.opendir(activity_z) orelse return;
        defer _ = std.c.closedir(year_dir);

        while (std.c.readdir(year_dir)) |year_entry| {
            const year_name = std.mem.sliceTo(&year_entry.name, 0);
            if (year_name.len == 0 or year_name[0] == '.') continue;
            if (year_entry.type != std.c.DT.DIR) continue;
            if (year_name.len != 4) continue;
            var all_digits = true;
            for (year_name) |c| {
                if (c < '0' or c > '9') { all_digits = false; break; }
            }
            if (!all_digits) continue;

            var year_node = TreeNode.init(self.allocator);
            year_node.type = .year;
            const year_name_len = @min(year_name.len, year_node.name.len - 1);
            @memcpy(year_node.name[0..year_name_len], year_name[0..year_name_len]);
            year_node.expanded = false;

            var year_path_buf: [512]u8 = undefined;
            const year_path = try std.fmt.bufPrint(&year_path_buf, "{s}/{s}", .{ activity_dir, year_name });

            try scanMonths(self.allocator, &year_node, year_path);

            std.sort.block(TreeNode, year_node.children.items, {}, monthDescLessThan);

            try self.years.append(self.allocator, year_node);
        }

        std.sort.block(TreeNode, self.years.items, {}, yearDescLessThan);

        if (self.years.items.len > 0) {
            self.years.items[0].expanded = true;
            if (self.years.items[0].children.items.len > 0) {
                self.years.items[0].children.items[0].expanded = true;
            }
        }
    }

    pub fn visibleCount(self: *const ActivityTree) usize {
        var count: usize = 0;
        for (self.years.items) |*year| {
            count += 1;
            if (year.expanded) {
                for (year.children.items) |*month| {
                    count += 1;
                    if (month.expanded) {
                        for (month.children.items) |*child| {
                            count += 1;
                            if (child.type == .group and child.expanded) {
                                count += child.children.items.len;
                            }
                        }
                    }
                }
            }
        }
        return count;
    }

    pub fn getVisible(self: *ActivityTree, visible_index: usize) ?*TreeNode {
        var current: usize = 0;
        for (self.years.items) |*year| {
            if (current == visible_index) return year;
            current += 1;
            if (year.expanded) {
                for (year.children.items) |*month| {
                    if (current == visible_index) return month;
                    current += 1;
                    if (month.expanded) {
                        for (month.children.items) |*child| {
                            if (current == visible_index) return child;
                            current += 1;
                            if (child.type == .group and child.expanded) {
                                for (child.children.items) |*file| {
                                    if (current == visible_index) return file;
                                    current += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    pub fn toggle(self: *ActivityTree, visible_index: usize) ?*TreeNode {
        const node = self.getVisible(visible_index) orelse return null;
        switch (node.type) {
            .year, .month, .group => node.expanded = !node.expanded,
            .file => {},
        }
        return node;
    }
};

fn yearDescLessThan(_: void, a: TreeNode, b: TreeNode) bool {
    return std.mem.order(u8, std.mem.sliceTo(&b.name, 0), std.mem.sliceTo(&a.name, 0)) == .lt;
}

fn monthDescLessThan(_: void, a: TreeNode, b: TreeNode) bool {
    return b.activity_time < a.activity_time;
}

fn fileDescLessThan(_: void, a: TreeNode, b: TreeNode) bool {
    return b.activity_time < a.activity_time;
}

fn jsonExtractField(buf: []const u8, field: []const u8, out: []u8) ?[]u8 {
    var search_buf: [72]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;

    const key_pos = std.mem.indexOf(u8, buf, search) orelse return null;
    var pos = buf[key_pos + search.len ..];

    const colon = std.mem.indexOfScalar(u8, pos, ':') orelse return null;
    pos = pos[colon..];

    var skip: usize = 0;
    while (skip < pos.len and (pos[skip] == ':' or pos[skip] == ' ' or pos[skip] == '\t' or pos[skip] == '\n')) {
        skip += 1;
    }
    pos = pos[skip..];

    if (pos.len == 0 or pos[0] != '"') return null;
    pos = pos[1..];

    var i: usize = 0;
    var pi: usize = 0;
    while (pi < pos.len and pos[pi] != '"' and i < out.len - 1) {
        if (pos[pi] == '\\' and pi + 1 < pos.len) {
            pi += 1;
            out[i] = switch (pos[pi]) {
                'n' => ' ',
                '"' => '"',
                '\\' => '\\',
                else => pos[pi],
            };
            i += 1;
        } else {
            out[i] = pos[pi];
            i += 1;
        }
        pi += 1;
    }
    if (i == 0) return null;
    out[i] = 0;
    return out[0..i];
}

fn parseIsoTimestamp(iso: []const u8) i64 {
    if (iso.len < 19) return 0;

    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(u8, iso[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(u8, iso[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(u8, iso[17..19], 10) catch return 0;

    if (month < 1 or month > 12) return 0;
    if (day < 1 or day > 31) return 0;

    const days = daysFromCivil(year, month, day);
    const secs: i64 = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
    return secs;
}

fn daysFromCivil(y_in: i32, m_in: u8, d: u8) i64 {
    var y: i64 = y_in;
    const m: i64 = m_in;
    const da: i64 = d;
    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + da - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn readFileHead(filepath: []const u8, buf: []u8) usize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{filepath}) catch return 0;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = std.c.close(fd);
    return std.posix.read(fd, buf) catch 0;
}

fn jsonGetActivityTimestamp(allocator: std.mem.Allocator, filepath: []const u8) i64 {
    _ = allocator;
    var buf: [2048]u8 = undefined;
    const n = readFileHead(filepath, &buf);
    if (n == 0) return 0;
    const data = buf[0..n];

    const patterns = [_][]const u8{ "\"start_date_local\"", "\"start_date\"", "\"starts\"" };
    for (patterns) |pat| {
        const key_pos = std.mem.indexOf(u8, data, pat) orelse continue;
        var pos = data[key_pos + pat.len ..];

        const colon = std.mem.indexOfScalar(u8, pos, ':') orelse continue;
        pos = pos[colon..];

        var skip: usize = 0;
        while (skip < pos.len and (pos[skip] == ':' or pos[skip] == ' ' or pos[skip] == '\t' or pos[skip] == '\n')) {
            skip += 1;
        }
        pos = pos[skip..];

        if (pos.len == 0 or pos[0] != '"') continue;
        pos = pos[1..];

        var ts_buf: [64]u8 = undefined;
        var ti: usize = 0;
        while (ti < pos.len and pos[ti] != '"' and ti < ts_buf.len - 1) {
            ts_buf[ti] = pos[ti];
            ti += 1;
        }
        const ts = parseIsoTimestamp(ts_buf[0..ti]);
        if (ts > 0) return ts;
    }
    return 0;
}

fn formatRideTitle(timestamp: i64, out: []u8) []u8 {
    if (timestamp <= 0) return out[0..0];

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const dow = @mod(epoch_day.day + 4, 7);
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const secs_of_day = @mod(timestamp, 86400);
    const hour: u64 = @intCast(@divFloor(secs_of_day, 3600));
    const minute: u64 = @intCast(@divFloor(@mod(secs_of_day, 3600), 60));

    const month_idx: usize = @intCast(@as(u8, month_day.month.numeric()) - 1);

    return std.fmt.bufPrint(out, "Ride - {s} {d:0>2}, {d:0>2}:{d:0>2}", .{
        day_names[dow],
        month_day.day_index + 1,
        hour,
        minute,
    }) catch blk: {
        _ = mon_names[month_idx];
        break :blk out[0..0];
    };
}

fn loadActivityTitle(allocator: std.mem.Allocator, node: *TreeNode) void {
    const name = std.mem.sliceTo(&node.name, 0);
    const full_path = std.mem.sliceTo(&node.full_path, 0);

    var title_buf: [128]u8 = std.mem.zeroes([128]u8);
    const base_len = @min(name.len, title_buf.len - 1);
    @memcpy(title_buf[0..base_len], name[0..base_len]);
    var title_end: usize = base_len;
    if (base_len >= 4 and std.ascii.eqlIgnoreCase(title_buf[base_len - 4 .. base_len], ".fit")) {
        title_end = base_len - 4;
    } else if (base_len >= 5 and std.ascii.eqlIgnoreCase(title_buf[base_len - 5 .. base_len], ".json")) {
        title_end = base_len - 5;
    }

    const is_json = name.len > 5 and std.ascii.eqlIgnoreCase(name[name.len - 5 ..], ".json");

    var json_buf: [4096]u8 = std.mem.zeroes([4096]u8);
    var json_len: usize = 0;
    if (is_json) {
        json_len = readFileHead(full_path, &json_buf);
    }
    const json_data = json_buf[0..json_len];

    var used_meta = false;
    if (activity_meta.loadMeta(allocator, full_path)) |meta| {
        if (meta.title_edited) {
            const t = std.mem.sliceTo(&meta.title, 0);
            if (t.len > 0) {
                const copy_len = @min(t.len, title_buf.len - 1);
                @memcpy(title_buf[0..copy_len], t[0..copy_len]);
                title_end = copy_len;
                used_meta = true;
            }
        }
    } else |_| {}

    if (!used_meta and is_json and json_len > 0) {
        var name_buf: [128]u8 = undefined;
        if (jsonExtractField(json_data, "name", &name_buf)) |extracted| {
            if (extracted.len > 0) {
                const copy_len = @min(extracted.len, title_buf.len - 1);
                @memcpy(title_buf[0..copy_len], extracted[0..copy_len]);
                title_end = copy_len;
                used_meta = true;
            }
        }
    }

    if (!used_meta and !is_json) {
        const is_wahoo = std.mem.startsWith(u8, name, "wahoo_");
        const is_zwift = std.mem.startsWith(u8, name, "zwift_");

        if (is_wahoo or is_zwift) {
            var timestamp: i64 = 0;
            if (is_zwift) {
                const stem = name[6 .. name.len - 4];
                timestamp = std.fmt.parseInt(i64, stem, 10) catch 0;
            } else {
                timestamp = file_organizer.getFitActivityTimestamp(full_path);
            }
            if (timestamp > 0) {
                var ride_buf: [128]u8 = undefined;
                const ride_title = formatRideTitle(timestamp, &ride_buf);
                if (ride_title.len > 0) {
                    const copy_len = @min(ride_title.len, title_buf.len - 1);
                    @memcpy(title_buf[0..copy_len], ride_title[0..copy_len]);
                    title_end = copy_len;
                }
            }
        }
    }

    const final = title_buf[0..title_end];
    const dt_len = @min(final.len, node.display_title.len - 1);
    @memcpy(node.display_title[0..dt_len], final[0..dt_len]);
    node.display_title[dt_len] = 0;
}

fn scanMonths(allocator: std.mem.Allocator, year_node: *TreeNode, year_path: []const u8) !void {
    var year_z_buf: [512]u8 = undefined;
    const year_z = try std.fmt.bufPrintZ(&year_z_buf, "{s}", .{year_path});

    const year_dir = std.c.opendir(year_z) orelse return;
    defer _ = std.c.closedir(year_dir);

    while (std.c.readdir(year_dir)) |month_entry| {
        const month_name_z = std.mem.sliceTo(&month_entry.name, 0);
        if (month_name_z.len == 0 or month_name_z[0] == '.') continue;
        if (month_entry.type != std.c.DT.DIR) continue;
        if (month_name_z.len != 2) continue;

        const month_num = std.fmt.parseInt(i32, month_name_z, 10) catch continue;
        if (month_num < 1 or month_num > 12) continue;

        var month_node = TreeNode.init(allocator);
        month_node.type = .month;
        const month_name = getMonthName(month_num);
        const mn_len = @min(month_name.len, month_node.name.len - 1);
        @memcpy(month_node.name[0..mn_len], month_name[0..mn_len]);
        month_node.activity_time = month_num;
        month_node.expanded = false;

        var month_path_buf: [512]u8 = undefined;
        const month_path = try std.fmt.bufPrint(&month_path_buf, "{s}/{s}", .{ year_path, month_name_z });

        try scanFiles(allocator, &month_node, month_path);

        try year_node.children.append(allocator, month_node);
    }
}

fn getFileMtime(filepath: []const u8) i64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{filepath}) catch return 0;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return 0;
    return st.mtime().sec;
}

fn scanFiles(allocator: std.mem.Allocator, month_node: *TreeNode, month_path: []const u8) !void {
    var month_z_buf: [512]u8 = undefined;
    const month_z = try std.fmt.bufPrintZ(&month_z_buf, "{s}", .{month_path});

    const month_dir = std.c.opendir(month_z) orelse return;
    defer _ = std.c.closedir(month_dir);

    var temp: std.ArrayList(TreeNode) = .empty;
    defer {
        for (temp.items) |*n| {
            n.deinit(allocator);
        }
        temp.deinit(allocator);
    }

    while (std.c.readdir(month_dir)) |file_entry| {
        if (file_entry.type != std.c.DT.REG) continue;
        const fname = std.mem.sliceTo(&file_entry.name, 0);
        const flen = fname.len;

        const is_meta = flen > 10 and std.ascii.eqlIgnoreCase(fname[flen - 10 ..], ".meta.json");
        if (is_meta) continue;

        const is_fit = flen > 4 and std.ascii.eqlIgnoreCase(fname[flen - 4 ..], ".fit");
        const is_json = flen > 5 and std.ascii.eqlIgnoreCase(fname[flen - 5 ..], ".json");
        if (!is_fit and !is_json) continue;

        var file_node = TreeNode.init(allocator);
        file_node.type = .file;

        const name_len = @min(flen, file_node.name.len - 1);
        @memcpy(file_node.name[0..name_len], fname[0..name_len]);

        const fp = std.fmt.bufPrint(&file_node.full_path, "{s}/{s}", .{ month_path, fname }) catch continue;
        _ = fp;

        loadActivityTitle(allocator, &file_node);

        if (is_json) {
            file_node.activity_time = jsonGetActivityTimestamp(allocator, std.mem.sliceTo(&file_node.full_path, 0));
        } else {
            file_node.activity_time = file_organizer.getFitActivityTimestamp(std.mem.sliceTo(&file_node.full_path, 0));
        }

        if (file_node.activity_time == 0) {
            file_node.activity_time = getFileMtime(std.mem.sliceTo(&file_node.full_path, 0));
        }

        try temp.append(allocator, file_node);
    }

    if (temp.items.len == 0) return;

    std.sort.block(TreeNode, temp.items, {}, fileDescLessThan);

    var grouped = try allocator.alloc(bool, temp.items.len);
    defer allocator.free(grouped);
    @memset(grouped, false);

    for (0..temp.items.len) |i| {
        if (grouped[i]) continue;

        var group_indices: [32]usize = undefined;
        var group_size: usize = 0;
        group_indices[group_size] = i;
        group_size += 1;
        grouped[i] = true;

        const t_anchor = temp.items[i].activity_time;

        var j: usize = i + 1;
        while (j < temp.items.len and group_size < 32) : (j += 1) {
            if (grouped[j]) continue;
            const t2 = temp.items[j].activity_time;
            const diff = if (t_anchor > t2) t_anchor - t2 else t2 - t_anchor;
            if (diff <= OVERLAP_THRESHOLD) {
                group_indices[group_size] = j;
                group_size += 1;
                grouped[j] = true;
            }
        }

        if (group_size == 1) {
            const node = temp.items[i];
            temp.items[i] = TreeNode.init(allocator);
            try month_node.children.append(allocator, node);
        } else {
            var group_node = TreeNode.init(allocator);
            group_node.type = .group;
            group_node.expanded = false;
            group_node.activity_time = temp.items[group_indices[0]].activity_time;

            const mp = activity_meta.groupMetaPath(month_path, group_node.activity_time, &group_node.meta_path);
            _ = mp;

            var group_title: []const u8 = std.mem.sliceTo(&temp.items[group_indices[0]].display_title, 0);
            var gmeta_title_buf: [256]u8 = std.mem.zeroes([256]u8);
            const meta_path_str = std.mem.sliceTo(&group_node.meta_path, 0);
            if (activity_meta.loadGroupMeta(allocator, meta_path_str)) |gmeta| {
                if (gmeta.title_edited) {
                    const t = std.mem.sliceTo(&gmeta.title, 0);
                    if (t.len > 0) {
                        const copy_len = @min(t.len, gmeta_title_buf.len - 1);
                        @memcpy(gmeta_title_buf[0..copy_len], t[0..copy_len]);
                        group_title = gmeta_title_buf[0..copy_len];
                    }
                }
            } else |_| {}

            const name_slice = std.fmt.bufPrint(&group_node.name, "{s} ({d})", .{ group_title, group_size }) catch blk: {
                break :blk group_node.name[0..0];
            };
            _ = name_slice;
            const dn = std.mem.sliceTo(&group_node.name, 0);
            const dt_len = @min(dn.len, group_node.display_title.len - 1);
            @memcpy(group_node.display_title[0..dt_len], dn[0..dt_len]);
            group_node.display_title[dt_len] = 0;

            for (group_indices[0..group_size]) |gi| {
                const node = temp.items[gi];
                temp.items[gi] = TreeNode.init(allocator);
                try group_node.children.append(allocator, node);
            }

            try month_node.children.append(allocator, group_node);
        }
    }
}
