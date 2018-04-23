load(
    "@rules_scala_annex//rules:providers.bzl",
    "LabeledJars",
    "ScalaConfiguration",
    "ScalaInfo",
    "ZincConfiguration",
    "ZincInfo",
)
load(":private/import.bzl", "create_intellij_info")

def _filesArg(files):
    return ([str(len(files))] + [file.path for file in files])

runner_common_attributes = {
    "_check_deps": attr.label(
        cfg = "host",
        default = "@rules_scala_annex//rules/scala:deps",
        executable = True,
    ),
    "_java_toolchain": attr.label(
        default = Label("@bazel_tools//tools/jdk:current_java_toolchain"),
    ),
    "_host_javabase": attr.label(
        default = Label("@bazel_tools//tools/jdk:current_java_runtime"),
        cfg = "host",
    ),
}

def runner_common(ctx):
    runner = ctx.toolchains["@rules_scala_annex//rules/scala:runner_toolchain_type"].runner

    scala_configuration = ctx.attr.scala[ScalaConfiguration]
    scala_configuration_runtime_deps = _collect(JavaInfo, scala_configuration.runtime_classpath)

    zinc_configuration = ctx.attr.scala[ZincConfiguration]

    sdeps = java_common.merge(_collect(JavaInfo, ctx.attr.deps))
    sruntime_deps = java_common.merge(_collect(JavaInfo, ctx.attr.runtime_deps))
    sexports = java_common.merge(_collect(JavaInfo, ctx.attr.exports))
    splugins = java_common.merge(_collect(JavaInfo, ctx.attr.plugins))

    mains_file = ctx.actions.declare_file("{}.jar.mains.txt".format(ctx.label.name))
    analysis = ctx.actions.declare_file("{}/analysis.gz".format(ctx.label.name))
    apis = ctx.actions.declare_file("{}/apis.gz".format(ctx.label.name))

    if len(ctx.attr.srcs) == 0:
        java_info = java_common.merge([sdeps, sexports])
    else:
        java_info = JavaInfo(
            output_jar = ctx.outputs.jar,
            use_ijar = ctx.attr.use_ijar,
            sources = ctx.files.srcs,
            deps = [sdeps],
            runtime_deps = [sruntime_deps] + scala_configuration_runtime_deps,
            exports = [sexports],
            actions = ctx.actions,
            java_toolchain = ctx.attr._java_toolchain,
            host_javabase = ctx.attr._host_javabase,
        )

    analysis = ctx.actions.declare_file("{}/analysis.gz".format(ctx.label.name))
    apis = ctx.actions.declare_file("{}/apis.gz".format(ctx.label.name))
    used = ctx.actions.declare_file("{}/deps_used.txt".format(ctx.label.name))

    runner_inputs, _, input_manifests = ctx.resolve_command(tools = [runner])

    args = ctx.actions.args()
    if hasattr(args, "add_all"):  # Bazel 0.13.0+
        args.add("--compiler_bridge", zinc_configuration.compiler_bridge)
        args.add_all("--compiler_classpath", scala_configuration.compiler_classpath)
        args.add_all("--classpath", sdeps.transitive_deps)
        args.add("--label={}".format(ctx.label))
        args.add("--main_manifest", mains_file)
        args.add("--output_analysis", analysis)
        args.add("--output_apis", apis)
        args.add("--output_jar", ctx.outputs.jar)
        args.add("--output_used", used)
        args.add("--plugins", splugins.transitive_runtime_deps)
        args.add("--")
        args.add_all(ctx.files.srcs)
    else:
        args.add("--compiler_bridge")
        args.add(zinc_configuration.compiler_bridge)
        args.add("--compiler_classpath")
        args.add(scala_configuration.compiler_classpath)
        args.add("--classpath")
        args.add(sdeps.transitive_deps)
        args.add("--label={}".format(ctx.label))
        args.add("--main_manifest")
        args.add(mains_file)
        args.add("--output_analysis")
        args.add(analysis)
        args.add("--output_apis")
        args.add(apis)
        args.add("--output_jar")
        args.add(ctx.outputs.jar)
        args.add("--output_used")
        args.add(used)
        args.add("--plugin")
        args.add(splugins.transitive_runtime_deps)
        args.add("--")
        args.add(ctx.files.srcs)
    args.set_param_file_format("multiline")
    args.use_param_file("@%s", use_always = True)

    runner_inputs, _, input_manifests = ctx.resolve_command(tools = [runner])
    inputs = depset(
        [zinc_configuration.compiler_bridge] + scala_configuration.compiler_classpath + ctx.files.srcs + runner_inputs,
        transitive = [
            sdeps.transitive_deps,
            splugins.transitive_runtime_deps,
        ],
    )

    outputs = [ctx.outputs.jar, mains_file, analysis, apis, used]

    # todo: different execution path for nosrc jar?
    ctx.actions.run(
        mnemonic = "ScalaCompile",
        inputs = inputs,
        outputs = outputs,
        executable = runner.files_to_run.executable,
        input_manifests = input_manifests,
        execution_requirements = {"supports-workers": "1"},
        arguments = [args],
    )

    success = ctx.actions.declare_file("{}/deps.check".format(ctx.label.name))

    labeled_jars = depset(transitive = [dep[LabeledJars].values for dep in ctx.attr.deps])
    deps_args = ctx.actions.args()
    if hasattr(deps_args, "add_all"):  # Bazel 0.13.0+
        deps_args.add_all("--direct", [dep.label for dep in ctx.attr.deps], format_each = "_%s")
        deps_args.add_all(labeled_jars, before_each = "--group", map_each = _labeled_group)
        deps_args.add("--label", ctx.label, format = "_%s")
        deps_args.add_all(labeled_jars, before_each = "--group", map_each = _labeled_group)
        deps_args.add("--")
        deps_args.add(used)
        deps_args.add(success)
    else:
        deps_args.add("--direct")
        deps_args.add([dep.label for dep in ctx.attr.deps], format = "_%s")
        deps_args.add(labeled_jars, before_each = "--group", map_fn = _labeled_groups)
        deps_args.add("--label")
        deps_args.add(ctx.label, format = "_%s")
        deps_args.add("--")
        deps_args.add(used)
        deps_args.add(success)
    deps_args.set_param_file_format("multiline")
    deps_args.use_param_file("@%s", use_always = True)

    deps_inputs, _, deps_input_manifests = ctx.resolve_command(tools = [ctx.attr._check_deps])
    ctx.actions.run(
        mnemonic = "ScalaCheckDeps",
        inputs = [used] + deps_inputs,
        outputs = [success],
        executable = ctx.executable._check_deps,
        input_manifests = deps_input_manifests,
        execution_requirements = {"supports-workers": "1"},
        arguments = [deps_args],
    )

    return struct(
        analysis = analysis,
        apis = apis,
        java_info = java_info,
        scala_info = ScalaInfo(scala_configuration = scala_configuration),
        zinc_info = ZincInfo(analysis = analysis),
        intellij_info = create_intellij_info(ctx.label, ctx.attr.deps, java_info),
        files = depset([ctx.outputs.jar, success]),
        mains_files = depset([mains_file]),
    )

annex_scala_library_private_attributes = runner_common_attributes

def annex_scala_library_implementation(ctx):
    res = runner_common(ctx)
    return struct(
        providers = [
            res.java_info,
            res.scala_info,
            res.zinc_info,
            res.intellij_info,
            DefaultInfo(
                files = res.files,
            ),
            OutputGroupInfo(
                analysis = depset([res.analysis, res.apis]),
            ),
        ],
        java = res.intellij_info,
    )

def _collect(index, iterable):
    return [
        entry[index]
        for entry in iterable
        if index in entry
    ]

"""
Ew. Bazel 0.13.0's map_each will allow us to produce multiple args from each item.
"""

def _labeled_group(labeled_jars):
    return "|".join(["_{}".format(labeled_jars.label)] + [jar.path for jar in labeled_jars.jars])

def _labeled_groups(labeled_jars_list):
    return [_labeled_group(labeled_jars) for labeled_jars in labeled_jars_list]
