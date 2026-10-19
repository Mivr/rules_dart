"""Extensions for bzlmod.

Installs a Dart toolchain.
Every module can define a toolchain version under the default name, "dart".
The root module's request wins when present, even if it is older than a
dependency's request (rules_dart's included); otherwise the highest requested
version is selected. A root pin older than a dependency's request prints a
NOTE naming both versions.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.
"""

load("//dart/private:toolchain_selection.bzl", "select_toolchain_version")
load(":repositories.bzl", "dart_register_toolchains")

_DEFAULT_NAME = "dart"

dart_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one Dart toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "dart_version": attr.string(doc = """\
Explicit version of the Dart SDK. A version requested by the root module takes
precedence over versions requested by dependencies (rules_dart's included), even
when the root's version is older; without a root request, the highest requested
version is selected.""", mandatory = True),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the Dart toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(struct(
                version = toolchain.dart_version,
                is_root = mod.is_root,
            ))
    for name, requests in registrations.items():
        selection = select_toolchain_version(name, requests)
        if selection.note:
            # buildifier: disable=print
            print("NOTE: " + selection.note)

        dart_register_toolchains(
            name = name,
            dart_version = selection.version,
        )
    return module_ctx.extension_metadata(
        reproducible = True,
    )

dart = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {"toolchain": dart_toolchain},
    os_dependent = False,
    arch_dependent = False,
    doc = """Installs a Dart SDK toolchain. Multiple modules may request different versions. The root module's request wins when present (even if older than a dependency's); otherwise the highest requested version is selected.""",
)
