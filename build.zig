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

    const build_opts = b.addOptions();
    exe.addOptions("build_options", build_opts);

    const version = "20240109";
    build_opts.addOption([]const u8, "version", version);

    const git_commit_hash = b.exec(&.{"git", "rev-parse", "HEAD"});
    build_opts.addOption([]const u8, "git_commit_hash", git_commit_hash[0..git_commit_hash.len - 1]); // Skip ending newline

    const cross_step = b.step("cross", "Install cross-compiled executables");

    inline for (triples) |triple| {
        const cross = b.addExecutable(.{
            .name = "habu-" ++ triple,
            .root_source_file = root_source_file,
            .optimize = optimize,
            .target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = triple }),
            .link_libc = true,
        });
        cross.addOptions("build_options", build_opts);
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
    "x86_64-windows-gnu",
};
