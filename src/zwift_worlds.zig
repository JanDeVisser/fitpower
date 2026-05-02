pub const ZwiftWorld = struct {
    id: i32,
    name: []const u8,
    slug: []const u8,
    min_lat: f64,
    max_lat: f64,
    min_lon: f64,
    max_lon: f64,
    img_min_lat: f64,
    img_max_lat: f64,
    img_min_lon: f64,
    img_max_lon: f64,
    map_url: []const u8,
    is_fictional: bool,
};

pub const worlds: []const ZwiftWorld = &[_]ZwiftWorld{
    .{
        .id = 1,
        .name = "Watopia",
        .slug = "Watopia",
        .min_lat = -11.76,
        .max_lat = -11.62,
        .min_lon = 166.78,
        .max_lon = 167.16,
        .img_min_lat = -11.752,
        .img_max_lat = -11.623,
        .img_min_lon = 167.156,
        .img_max_lon = 166.790,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Watopia_2.png",
        .is_fictional = true,
    },
    .{
        .id = 2,
        .name = "Crit City",
        .slug = "CritCity",
        .min_lat = -10.40,
        .max_lat = -10.37,
        .min_lon = 165.78,
        .max_lon = 165.82,
        .img_min_lat = -10.41,
        .img_max_lat = -10.36,
        .img_min_lon = 165.77,
        .img_max_lon = 165.83,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_CritCity.png",
        .is_fictional = true,
    },
    .{
        .id = 3,
        .name = "Makuri Islands",
        .slug = "MakuriIslands",
        .min_lat = -10.85,
        .max_lat = -10.74,
        .min_lon = 165.77,
        .max_lon = 165.88,
        .img_min_lat = -10.86,
        .img_max_lat = -10.73,
        .img_min_lon = 165.76,
        .img_max_lon = 165.89,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_MakuriIslands.png",
        .is_fictional = true,
    },
    .{
        .id = 4,
        .name = "France",
        .slug = "France",
        .min_lat = -21.76,
        .max_lat = -21.64,
        .min_lon = 166.14,
        .max_lon = 166.26,
        .img_min_lat = -21.77,
        .img_max_lat = -21.63,
        .img_min_lon = 166.13,
        .img_max_lon = 166.27,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_France.png",
        .is_fictional = true,
    },
    .{
        .id = 5,
        .name = "Richmond",
        .slug = "Richmond",
        .min_lat = 37.50,
        .max_lat = 37.58,
        .min_lon = -77.49,
        .max_lon = -77.39,
        .img_min_lat = 37.49,
        .img_max_lat = 37.59,
        .img_min_lon = -77.50,
        .img_max_lon = -77.38,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Richmond.png",
        .is_fictional = false,
    },
    .{
        .id = 6,
        .name = "London",
        .slug = "London",
        .min_lat = 51.46,
        .max_lat = 51.54,
        .min_lon = -0.18,
        .max_lon = -0.06,
        .img_min_lat = 51.45,
        .img_max_lat = 51.55,
        .img_min_lon = -0.19,
        .img_max_lon = -0.05,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_London.png",
        .is_fictional = false,
    },
    .{
        .id = 7,
        .name = "New York",
        .slug = "NewYork",
        .min_lat = 40.59,
        .max_lat = 40.82,
        .min_lon = -74.02,
        .max_lon = -73.92,
        .img_min_lat = 40.58,
        .img_max_lat = 40.83,
        .img_min_lon = -74.03,
        .img_max_lon = -73.91,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_NewYork.png",
        .is_fictional = false,
    },
    .{
        .id = 8,
        .name = "Innsbruck",
        .slug = "Innsbruck",
        .min_lat = 47.21,
        .max_lat = 47.29,
        .min_lon = 11.35,
        .max_lon = 11.48,
        .img_min_lat = 47.20,
        .img_max_lat = 47.30,
        .img_min_lon = 11.34,
        .img_max_lon = 11.49,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Innsbruck.png",
        .is_fictional = false,
    },
    .{
        .id = 9,
        .name = "Bologna",
        .slug = "Bologna",
        .min_lat = 44.45,
        .max_lat = 44.53,
        .min_lon = 11.26,
        .max_lon = 11.37,
        .img_min_lat = 44.44,
        .img_max_lat = 44.54,
        .img_min_lon = 11.25,
        .img_max_lon = 11.38,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Bologna.png",
        .is_fictional = false,
    },
    .{
        .id = 10,
        .name = "Yorkshire",
        .slug = "Yorkshire",
        .min_lat = 53.95,
        .max_lat = 54.03,
        .min_lon = -1.63,
        .max_lon = -1.50,
        .img_min_lat = 53.94,
        .img_max_lat = 54.04,
        .img_min_lon = -1.64,
        .img_max_lon = -1.49,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Yorkshire.png",
        .is_fictional = false,
    },
    .{
        .id = 11,
        .name = "Paris",
        .slug = "Paris",
        .min_lat = 48.83,
        .max_lat = 48.91,
        .min_lon = 2.26,
        .max_lon = 2.37,
        .img_min_lat = 48.82,
        .img_max_lat = 48.92,
        .img_min_lon = 2.25,
        .img_max_lon = 2.38,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Paris.png",
        .is_fictional = false,
    },
    .{
        .id = 12,
        .name = "Scotland",
        .slug = "Scotland",
        .min_lat = 55.62,
        .max_lat = 55.68,
        .min_lon = -5.28,
        .max_lon = -5.18,
        .img_min_lat = 55.61,
        .img_max_lat = 55.69,
        .img_min_lon = -5.29,
        .img_max_lon = -5.17,
        .map_url = "https://cdn.zwift.com/static/images/maps/MiniMap_Scotland.png",
        .is_fictional = false,
    },
};

pub fn worldCount() usize {
    return worlds.len;
}

pub fn getWorld(index: usize) ?*const ZwiftWorld {
    if (index >= worlds.len) return null;
    return &worlds[index];
}

pub fn detectWorld(min_lat: f64, max_lat: f64, min_lon: f64, max_lon: f64) ?*const ZwiftWorld {
    for (worlds) |*world| {
        if (!world.is_fictional) continue;
        if (min_lat >= world.min_lat - 0.01 and max_lat <= world.max_lat + 0.01 and
            min_lon >= world.min_lon - 0.01 and max_lon <= world.max_lon + 0.01)
        {
            return world;
        }
    }
    for (worlds) |*world| {
        if (world.is_fictional) continue;
        if (min_lat >= world.min_lat and max_lat <= world.max_lat and
            min_lon >= world.min_lon and max_lon <= world.max_lon)
        {
            return world;
        }
    }
    return null;
}
