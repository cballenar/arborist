const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Embed templates at compile time via anonymous imports
    root_mod.addAnonymousImport("template_mutagen_yml", .{
        .root_source_file = b.path("templates/mutagen.yml"),
    });
    root_mod.addAnonymousImport("template_settings_workspace_php", .{
        .root_source_file = b.path("templates/settings.workspace.php"),
    });
    root_mod.addAnonymousImport("template_workspace_nginx_conf", .{
        .root_source_file = b.path("templates/workspace-nginx.conf"),
    });
    root_mod.addAnonymousImport("template_ddev_drush", .{
        .root_source_file = b.path("templates/ddev-commands/drush"),
    });
    root_mod.addAnonymousImport("template_ddev_npm", .{
        .root_source_file = b.path("templates/ddev-commands/npm"),
    });
    root_mod.addAnonymousImport("template_ddev_twig_debug", .{
        .root_source_file = b.path("templates/ddev-commands/twig-debug"),
    });

    const exe = b.addExecutable(.{
        .name = "arborist",
        .root_module = root_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run arborist");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const exe_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
