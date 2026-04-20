#!/usr/bin/env python
"""
Build script for the VibezCraft native extension.

Usage:
    scons                                       # macOS debug by default
    scons platform=macos target=template_release
    scons platform=linux target=template_debug
    scons -c                                    # clean

Prereqs: godot-cpp submodule populated and built once:
    cd godot-cpp && scons platform=macos target=template_debug
"""

env = SConscript("godot-cpp/SConstruct")
env.Append(CPPPATH=["src/"])

sources = Glob("src/*.cpp")

# Output under bin/ so the .gdextension manifest can reference it with
# relative paths. env["suffix"] adds ".{platform}.{target}[.arch]" to the
# base name; env["SHLIBSUFFIX"] is ".dylib"/".so"/".dll".
library = env.SharedLibrary(
    "bin/libmesher_native{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
