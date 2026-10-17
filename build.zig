const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// Die build.zig zeigt seit 0.61.8 nur noch auf module.R4MF, statt Name,
/// Typ beziehungsweise Rolle und Metadaten ein zweites Mal hinzuschreiben.
/// Damit gibt es hier nichts mehr, was vom Manifest abweichen koennte.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const guard_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/rx_guard.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_guard_tests = b.addRunArtifact(guard_tests);
    const irq_policy_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/irq_policy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_irq_policy_tests = b.addRunArtifact(irq_policy_tests);
    const test_step = b.step("test", "Run RTL8139 RX recovery tests");
    test_step.dependOn(&run_guard_tests.step);
    test_step.dependOn(&run_irq_policy_tests.step);
}
