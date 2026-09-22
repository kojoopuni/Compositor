#!/usr/bin/env python3
"""Writes CLI/CompositorCLI.xcodeproj, the command-line build of Compositor's engine.

The tool target compiles the app's own sources from ../Compositor, minus everything that needs a window, plus
CLI/Sources. It is a separate project so upstream's Compositor.xcodeproj is never edited. The exclusion list is
read from disk, so run this again after merging upstream: a new file under UI/ is picked up without hand edits.

    python3 CLI/make_project.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "Compositor")
PROJECT = os.path.join(ROOT, "CLI", "CompositorCLI.xcodeproj")

# Files outside UI/ that build views, windows, panels or the app itself.
WINDOWED = [
    "ContentView.swift",
    "CompositorApp.swift",
    "Assets.xcassets",
    "IO/ProjectController.swift",
    "IO/ProjectController+Formats.swift",
    "IO/CompositorApplicationDelegate.swift",
    "IO/ImageFileDrop.swift",
    "Document/ProjectWorkspace.swift",
    "Rendering/EditorCanvas.swift",
    "Rendering/TransformOverlay.swift",
    "Rendering/BrushCursorOverlay.swift",
    "Rendering/SampleRingOverlay.swift",
    "Rendering/InlineTextEditor.swift",
]

# Files under UI/ the engine itself refers to (plain value types beside their views), so they stay in.
ENGINE_UI = ["UI/PSDConversionSheet.swift"]


def identifier(name):
    """A stable 24-digit object id, so regenerating the project produces no diff."""
    return hashlib.sha1(("compositor-cli:" + name).encode()).hexdigest()[:24].upper()


def excluded():
    paths = [path for path in WINDOWED if os.path.exists(os.path.join(ENGINE, path))]
    # Whole folders of interface code: the panels and views, and the server that drives the running app.
    for name in ["UI", "Control"]:
        for folder, _, files in os.walk(os.path.join(ENGINE, name)):
            for file in files:
                relative = os.path.relpath(os.path.join(folder, file), ENGINE)
                if not file.startswith(".") and relative not in ENGINE_UI:
                    paths.append(relative)
    return sorted(paths)


def settings(configuration):
    debug = configuration == "Debug"
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "MACOSX_DEPLOYMENT_TARGET": "26.5",
        "SDKROOT": "macosx",
        "ONLY_ACTIVE_ARCH": "YES" if debug else "NO",
        "SWIFT_COMPILATION_MODE": "singlefile" if debug else "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"' if debug else '"-O"',
        "DEBUG_INFORMATION_FORMAT": "dwarf" if debug else '"dwarf-with-dsym"',
    }
    if debug:
        common["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = '"DEBUG $(inherited)"'
        common["ENABLE_TESTABILITY"] = "YES"
    return common


def target_settings():
    # Copied from the app target: without MainActor default isolation EditorSession and its extensions do not
    # compile, and without -O3 the C pixel kernels crawl in Debug.
    return {
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_IDENTITY": '"-"',
        "ENABLE_APP_SANDBOX": "NO",
        "ENABLE_HARDENED_RUNTIME": "NO",
        "GCC_OPTIMIZATION_LEVEL": "3",
        "PRODUCT_NAME": '"compositor-cli"',
        "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        "SWIFT_OBJC_BRIDGING_HEADER": '"$(SRCROOT)/../Compositor/Compositor-Bridging-Header.h"',
        "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
        "SWIFT_VERSION": "5.0",
    }


def block(values, indent):
    pad = "\t" * indent
    return "".join(f"{pad}{key} = {value};\n" for key, value in sorted(values.items()))


def main():
    ids = {name: identifier(name) for name in [
        "project", "mainGroup", "products", "product", "engine", "sources", "exceptions", "target",
        "sourcesPhase", "frameworksPhase", "projectConfigurations", "targetConfigurations",
        "projectDebug", "projectRelease", "targetDebug", "targetRelease"]}
    exceptions = "".join(f"\t\t\t\t{quote(path)},\n" for path in excluded())
    text = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXFileReference section */
		{ids['product']} /* compositor-cli */ = {{isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = "compositor-cli"; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		{ids['exceptions']} /* Exceptions for "Compositor" folder in "compositor-cli" target */ = {{
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
{exceptions}			);
			target = {ids['target']} /* compositor-cli */;
		}};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{ids['engine']} /* Compositor */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				{ids['exceptions']} /* Exceptions for "Compositor" folder in "compositor-cli" target */,
			);
			name = Compositor;
			path = ../Compositor;
			sourceTree = "<group>";
		}};
		{ids['sources']} /* Sources */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Sources;
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{ids['frameworksPhase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ids['mainGroup']} = {{
			isa = PBXGroup;
			children = (
				{ids['sources']} /* Sources */,
				{ids['engine']} /* Compositor */,
				{ids['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['product']} /* compositor-cli */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids['target']} /* compositor-cli */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['targetConfigurations']} /* Build configuration list for PBXNativeTarget "compositor-cli" */;
			buildPhases = (
				{ids['sourcesPhase']} /* Sources */,
				{ids['frameworksPhase']} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{ids['engine']} /* Compositor */,
				{ids['sources']} /* Sources */,
			);
			name = "compositor-cli";
			productName = "compositor-cli";
			productReference = {ids['product']} /* compositor-cli */;
			productType = "com.apple.product-type.tool";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
			}};
			buildConfigurationList = {ids['projectConfigurations']} /* Build configuration list for PBXProject "CompositorCLI" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {ids['mainGroup']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {ids['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* compositor-cli */,
			);
		}};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		{ids['sourcesPhase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids['projectDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{block(settings('Debug'), 4)}			}};
			name = Debug;
		}};
		{ids['projectRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{block(settings('Release'), 4)}			}};
			name = Release;
		}};
		{ids['targetDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{block(target_settings(), 4)}			}};
			name = Debug;
		}};
		{ids['targetRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{block(target_settings(), 4)}			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids['projectConfigurations']} /* Build configuration list for PBXProject "CompositorCLI" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['projectDebug']} /* Debug */,
				{ids['projectRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['targetConfigurations']} /* Build configuration list for PBXNativeTarget "compositor-cli" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['targetDebug']} /* Debug */,
				{ids['targetRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ids['project']} /* Project object */;
}}
"""
    os.makedirs(PROJECT, exist_ok=True)
    with open(os.path.join(PROJECT, "project.pbxproj"), "w") as file:
        file.write(text)
    print(f"Wrote {os.path.relpath(PROJECT, ROOT)} with {len(excluded())} excluded files")


def quote(path):
    return path if path.replace("/", "").replace(".", "").replace("_", "").isalnum() else f'"{path}"'


if __name__ == "__main__":
    main()
