const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mcpsync",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Ad-hoc codesign for native macOS builds so the binary runs without quarantine.
    // Skip when cross-compiling (e.g. building x86_64 on arm64) — the notarize script
    // handles signing for distribution builds with the real Developer ID.
    const native_macos = target.result.os.tag == .macos and builtin.os.tag == .macos;
    const cross_compiling = target.result.cpu.arch != builtin.cpu.arch;
    if (native_macos and !cross_compiling) {
        const codesign = b.addSystemCommand(&.{ "codesign", "-f", "-s", "-" });
        codesign.addArtifactArg(exe);
        b.getInstallStep().dependOn(&codesign.step);
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run mcpsync");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
