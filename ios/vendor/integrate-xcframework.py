#!/usr/bin/env python3
"""
Link `ios/vendor/dcap_qvl.xcframework` into the FeedlingTest target of
testapp/FeedlingTest.xcodeproj.

Idempotent — re-running does nothing if the framework is already linked.
Uses the `pbxproj` library (pip install pbxproj) to do the editing so we
don't hand-roll the OpenStep plist surgery.
"""
from pbxproj import XcodeProject
from pbxproj.pbxextensions.ProjectFiles import FileOptions

PROJ = "/Users/sxysun/Desktop/suapp/feedling-mcp-v1/testapp/FeedlingTest.xcodeproj/project.pbxproj"
XCFRAMEWORK = "../ios/vendor/dcap_qvl.xcframework"
TARGET = "FeedlingTest"


def main() -> int:
    p = XcodeProject.load(PROJ)

    # Skip if already linked
    for f in p.objects.get_objects_in_section("PBXFileReference"):
        if "dcap_qvl.xcframework" in (getattr(f, "path", None) or ""):
            print(f"already linked: {f.path}")
            return 0

    options = FileOptions(
        create_build_files=True,
        embed_framework=False,  # static lib inside xcframework — no embed
        code_sign_on_copy=False,
    )
    added = p.add_file(
        XCFRAMEWORK,
        parent=None,
        target_name=TARGET,
        force=True,
        file_options=options,
    )
    if not added:
        print("add_file returned empty — xcframework not linked")
        return 1

    # Do NOT add HEADER_SEARCH_PATHS to ios/vendor/include. The
    # xcframework carries its own copy of dcap_qvl.h + module.modulemap
    # under ios-arm64/Headers/ and ios-arm64-simulator/Headers/; adding
    # the source-tree include/ to the search path makes clang see the
    # modulemap twice and fails with "Redefinition of module 'dcap_qvl'".

    p.save()
    print(f"linked {XCFRAMEWORK} into target {TARGET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
