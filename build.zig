const std = @import("std");

const ThisBuild = @This();

pub const Options = struct {
    /// The target architecture for which the module will be built.
    target: ?std.Build.ResolvedTarget = null,
    /// The optimization mode used to compile the module.
    optimize: ?std.lang.Optimize = null,
    dependency_bit_word: ?*std.Build.Module = null,
    pub fn initFromOptions(b: *std.Build) Options {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        };
    }

    /// Create the `bit_structs` module in the caller's build graph.
    ///
    /// Intended for parent packages that want a single shared instance:
    /// ```zig
    /// const bit_structs_mod = (@import("bit_structs").Options{
    ///     .target = target,
    ///     .optimize = optimize,
    /// }).getModule(b);
    /// ```
    /// Uses `dependencyFromBuildZig` so source paths stay correct when
    /// called from a parent build via `@import("bit_structs")`.
    pub fn getModule(self: Options, b: *std.Build) *std.Build.Module {
        const target = self.target orelse b.standardTargetOptions(.{});
        const optimize = self.optimize orelse b.standardOptimizeOption(.{});
        const self_dep = b.dependencyFromBuildZig(ThisBuild, .{
            .target = target,
            .optimize = optimize,
        });
        const bit_word_mod = self.dependency_bit_word orelse self_dep.builder.dependency("bit_word", .{
            .target = target,
            .optimize = optimize,
        }).module("bit_word");
        const mod = b.createModule(.{
            .root_source_file = self_dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("bit_word", bit_word_mod);
        return mod;
    }
};

/// Create the `bit_structs` module in the *own* package graph (standalone `zig build`).
/// Same wiring as `Options.getModule` but uses `b.path` (valid only for own build).
fn createModuleOwn(b: *std.Build, options: Options) *std.Build.Module {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    const bit_word_mod = options.dependency_bit_word orelse b.dependency("bit_word", .{
        .target = target,
        .optimize = optimize,
    }).module("bit_word");
    const mod = b.addModule("bit_structs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("bit_word", bit_word_mod);
    return mod;
}

/// Configures library modules, unit tests and the tree benchmark.
/// - `b` - build graph that receives all steps and artifacts.
pub fn build(b: *std.Build) void {
    const options = Options.initFromOptions(b);
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});

    const mod = createModuleOwn(b, options);
    const bit_word_mod = mod.import_table.get("bit_word").?;

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const bench_bit_tree_exe = b.addExecutable(.{
        .name = "bench_bit_tree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_bit_tree.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bit_word", .module = bit_word_mod },
            },
        }),
    });

    const run_bench_bit_tree = b.addRunArtifact(bench_bit_tree_exe);
    run_bench_bit_tree.addPassthruArgs();

    const bench_bit_tree_step = b.step("bench_bit_tree", "Run tree benchmarks with history");
    bench_bit_tree_step.dependOn(&run_bench_bit_tree.step);
}
