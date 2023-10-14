const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe
    });
    const root_source_file = .{ .path = "src/main.zig" };
    const exe = b.addExecutable(.{
        .name = "habu",
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    b.installArtifact(exe);

    const cross_step = b.step("cross", "Install cross-compiled executables");

    inline for (triples) |triple| {
        const cross = b.addExecutable(.{
            .name = "habu-" ++ triple,
            .root_source_file = root_source_file,
            .optimize = optimize,
            .target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = triple }),
            .link_libc = true,
        });
        cross.strip = true;
        const cross_install = b.addInstallArtifact(cross, .{});
        cross_step.dependOn(&cross_install.step);
    }

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

const triples = .{
    "x86_64-linux-gnu",
    "aarch64-macos-none",
    "x86_64-macos-none",
};
