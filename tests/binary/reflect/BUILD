load("@rules_scala_annex//rules:scala.bzl", "scala_binary", "scala_library")

scala_library(
    name = "bad",
    srcs = ["Reflect.scala"],
    scala = "//scala:2_12",
)

scala_binary(
    name = "good",
    srcs = ["Reflect.scala"],
    deps_used_whitelist = ["@org_scala_lang_scala_reflect"],
    scala = "//scala:2_12",
    deps = ["@org_scala_lang_scala_reflect"],
)
