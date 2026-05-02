const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    root_module.linkSystemLibrary("raylib", .{});
    root_module.linkSystemLibrary("curl", .{});
    root_module.linkSystemLibrary("ssl", .{});
    root_module.linkSystemLibrary("crypto", .{});

    switch (target.result.os.tag) {
        .macos => {
            root_module.linkFramework("IOKit", .{});
            root_module.linkFramework("Cocoa", .{});
            root_module.linkFramework("OpenGL", .{});
        },
        else => {
            root_module.linkSystemLibrary("m", .{});
        },
    }

    const exe = b.addExecutable(.{
        .name = "sweattrails",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run sweattrails");
    run_step.dependOn(&run_cmd.step);
}
