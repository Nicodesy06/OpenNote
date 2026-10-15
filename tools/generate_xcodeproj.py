#!/usr/bin/env python3
"""Genera QuadernoAI.xcodeproj (formato Xcode 16+, cartelle sincronizzate).

Uso: python3 tools/generate_xcodeproj.py
Il progetto include:
  - target app "QuadernoAI" (cartella App/, Info.plist in Config/)
  - target test "QuadernoAITests" (cartella AppTests/)
  - pacchetto locale Packages/QuadernoCore (prodotto QuadernoCore)
  - schema condiviso con i test dell'app e del pacchetto.
In alternativa è disponibile project.yml per XcodeGen.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "QuadernoAI.xcodeproj")

BUNDLE_ID = "it.quadernoai.app"
DEPLOYMENT = "17.0"


def oid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


IDS = {k: oid(k) for k in [
    "project", "mainGroup", "productsGroup", "appGroup", "testsGroup", "configGroup", "packagesGroup",
    "appProduct", "testsProduct", "infoPlistRef", "packageFolderRef",
    "appTarget", "testsTarget",
    "appSources", "appFrameworks", "appResources", "testsSources", "testsFrameworks", "testsResources",
    "coreBuildFile", "coreProductDependency", "localPackageRef",
    "testsDependency", "testsProxy",
    "projectConfigList", "projectDebug", "projectRelease",
    "appConfigList", "appDebug", "appRelease",
    "testsConfigList", "testsDebug", "testsRelease",
]}


def settings_block(items: dict, indent: str = "\t\t\t\t") -> str:
    lines = []
    for key in sorted(items):
        value = items[key]
        if isinstance(value, list):
            inner = "".join(f"{indent}\t{quote(v)},\n" for v in value)
            lines.append(f"{indent}{key} = (\n{inner}{indent});\n")
        else:
            lines.append(f"{indent}{key} = {quote(value)};\n")
    return "".join(lines)


def quote(value) -> str:
    text = str(value)
    safe = text.replace("_", "").replace(".", "").replace("/", "")
    if text and safe.isalnum():
        return text
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"') + '"'


common_project = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
}
project_debug = dict(common_project, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
})
project_release = dict(common_project, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
})

app_common = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": "",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Config/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": "0.1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_STRICT_CONCURRENCY": "minimal",
    "TARGETED_DEVICE_FAMILY": "2",
}
tests_common = {
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_TEAM": "",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "0.1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
    "SWIFT_STRICT_CONCURRENCY": "minimal",
    "TARGETED_DEVICE_FAMILY": "2",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/QuadernoAI.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/QuadernoAI",
}

I = IDS


def config(id_key, name, items):
    return f"""\t\t{I[id_key]} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings_block(items)}\t\t\t}};
\t\t\tname = {name};
\t\t}};
"""


pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
\t\t{I['coreBuildFile']} /* QuadernoCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['coreProductDependency']} /* QuadernoCore */; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t{I['testsProxy']} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {I['project']} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {I['appTarget']};
\t\t\tremoteInfo = QuadernoAI;
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
\t\t{I['appProduct']} /* QuadernoAI.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuadernoAI.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{I['testsProduct']} /* QuadernoAITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuadernoAITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{I['infoPlistRef']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{I['packageFolderRef']} /* QuadernoCore */ = {{isa = PBXFileReference; lastKnownFileType = wrapper; path = QuadernoCore; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
\t\t{I['appGroup']} /* App */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; }};
\t\t{I['testsGroup']} /* AppTests */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = AppTests; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{I['appFrameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{I['coreBuildFile']} /* QuadernoCore in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{I['testsFrameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{I['mainGroup']} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I['appGroup']} /* App */,
\t\t\t\t{I['testsGroup']} /* AppTests */,
\t\t\t\t{I['configGroup']} /* Config */,
\t\t\t\t{I['packagesGroup']} /* Packages */,
\t\t\t\t{I['productsGroup']} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{I['configGroup']} /* Config */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I['infoPlistRef']} /* Info.plist */,
\t\t\t);
\t\t\tpath = Config;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{I['packagesGroup']} /* Packages */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I['packageFolderRef']} /* QuadernoCore */,
\t\t\t);
\t\t\tpath = Packages;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{I['productsGroup']} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I['appProduct']} /* QuadernoAI.app */,
\t\t\t\t{I['testsProduct']} /* QuadernoAITests.xctest */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{I['appTarget']} /* QuadernoAI */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {I['appConfigList']} /* Build configuration list for PBXNativeTarget "QuadernoAI" */;
\t\t\tbuildPhases = (
\t\t\t\t{I['appSources']} /* Sources */,
\t\t\t\t{I['appFrameworks']} /* Frameworks */,
\t\t\t\t{I['appResources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{I['appGroup']} /* App */,
\t\t\t);
\t\t\tname = QuadernoAI;
\t\t\tpackageProductDependencies = (
\t\t\t\t{I['coreProductDependency']} /* QuadernoCore */,
\t\t\t);
\t\t\tproductName = QuadernoAI;
\t\t\tproductReference = {I['appProduct']} /* QuadernoAI.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t{I['testsTarget']} /* QuadernoAITests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {I['testsConfigList']} /* Build configuration list for PBXNativeTarget "QuadernoAITests" */;
\t\t\tbuildPhases = (
\t\t\t\t{I['testsSources']} /* Sources */,
\t\t\t\t{I['testsFrameworks']} /* Frameworks */,
\t\t\t\t{I['testsResources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{I['testsDependency']} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{I['testsGroup']} /* AppTests */,
\t\t\t);
\t\t\tname = QuadernoAITests;
\t\t\tproductName = QuadernoAITests;
\t\t\tproductReference = {I['testsProduct']} /* QuadernoAITests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{I['project']} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{I['appTarget']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t\t{I['testsTarget']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t\tTestTargetID = {I['appTarget']};
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {I['projectConfigList']} /* Build configuration list for PBXProject "QuadernoAI" */;
\t\t\tdevelopmentRegion = it;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\tit,
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {I['mainGroup']};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpackageReferences = (
\t\t\t\t{I['localPackageRef']} /* XCLocalSwiftPackageReference "Packages/QuadernoCore" */,
\t\t\t);
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {I['productsGroup']} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{I['appTarget']} /* QuadernoAI */,
\t\t\t\t{I['testsTarget']} /* QuadernoAITests */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{I['appResources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{I['testsResources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{I['appSources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{I['testsSources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{I['testsDependency']} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {I['appTarget']} /* QuadernoAI */;
\t\t\ttargetProxy = {I['testsProxy']} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{config('projectDebug', 'Debug', project_debug)}{config('projectRelease', 'Release', project_release)}{config('appDebug', 'Debug', app_common)}{config('appRelease', 'Release', app_common)}{config('testsDebug', 'Debug', tests_common)}{config('testsRelease', 'Release', tests_common)}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{I['projectConfigList']} /* Build configuration list for PBXProject "QuadernoAI" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{I['projectDebug']} /* Debug */,
\t\t\t\t{I['projectRelease']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{I['appConfigList']} /* Build configuration list for PBXNativeTarget "QuadernoAI" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{I['appDebug']} /* Debug */,
\t\t\t\t{I['appRelease']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{I['testsConfigList']} /* Build configuration list for PBXNativeTarget "QuadernoAITests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{I['testsDebug']} /* Debug */,
\t\t\t\t{I['testsRelease']} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
\t\t{I['localPackageRef']} /* XCLocalSwiftPackageReference "Packages/QuadernoCore" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = Packages/QuadernoCore;
\t\t}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
\t\t{I['coreProductDependency']} /* QuadernoCore */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tproductName = QuadernoCore;
\t\t}};
/* End XCSwiftPackageProductDependency section */
\t}};
\trootObject = {I['project']} /* Project object */;
}}
"""

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{I['appTarget']}"
               BuildableName = "QuadernoAI.app"
               BlueprintName = "QuadernoAI"
               ReferencedContainer = "container:QuadernoAI.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{I['testsTarget']}"
               BuildableName = "QuadernoAITests.xctest"
               BlueprintName = "QuadernoAITests"
               ReferencedContainer = "container:QuadernoAI.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "QuadernoCoreTests"
               BuildableName = "QuadernoCoreTests"
               BlueprintName = "QuadernoCoreTests"
               ReferencedContainer = "container:Packages/QuadernoCore">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{I['appTarget']}"
            BuildableName = "QuadernoAI.app"
            BlueprintName = "QuadernoAI"
            ReferencedContainer = "container:QuadernoAI.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{I['appTarget']}"
            BuildableName = "QuadernoAI.app"
            BlueprintName = "QuadernoAI"
            ReferencedContainer = "container:QuadernoAI.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

workspace = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""

os.makedirs(os.path.join(PROJECT, "xcshareddata", "xcschemes"), exist_ok=True)
os.makedirs(os.path.join(PROJECT, "project.xcworkspace"), exist_ok=True)
with open(os.path.join(PROJECT, "project.pbxproj"), "w") as f:
    f.write(pbxproj)
with open(os.path.join(PROJECT, "xcshareddata", "xcschemes", "QuadernoAI.xcscheme"), "w") as f:
    f.write(scheme)
with open(os.path.join(PROJECT, "project.xcworkspace", "contents.xcworkspacedata"), "w") as f:
    f.write(workspace)
print("Generato", PROJECT)
