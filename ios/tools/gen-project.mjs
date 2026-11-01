#!/usr/bin/env node
/*
 * 生成 PornhubMobile.xcodeproj/project.pbxproj。
 *
 * 手写 pbxproj 很容易漏文件，所以这里用脚本按目录结构生成，
 * 新增源文件后重新运行即可：
 *
 *   node tools/gen-project.mjs
 */
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const iosDir = dirname(dirname(fileURLToPath(import.meta.url)));
const srcDir = join(iosDir, 'PornhubMobile');
const projectDir = join(iosDir, 'PornhubMobile.xcodeproj');
const outFile = join(projectDir, 'project.pbxproj');

const TARGET = 'PornhubMobile';
const BUNDLE_ID = 'local.ph.mobile';
const DEPLOYMENT = '16.0';
const SWIFT_SOUP_MIN = '2.7.0';

/* ------------------------------ 收集源文件 ------------------------------ */

const groupOrder = ['App', 'Core', 'UI'];
const sources = {};

for (const group of groupOrder) {
  const dir = join(srcDir, group);
  if (!existsSync(dir)) continue;
  sources[group] = readdirSync(dir)
    .filter((name) => name.endsWith('.swift'))
    .sort();
}

const allSwift = Object.values(sources).flatMap((files, index) =>
  files.map((name) => ({ group: groupOrder[index], name }))
);

/* ------------------------------ ID 生成 ------------------------------ */

const ids = new Map();
function id(key) {
  if (!ids.has(key)) {
    const value = 0xabcdef000000000000000000n + BigInt(ids.size);
    ids.set(key, value.toString(16).toUpperCase());
  }
  return ids.get(key);
}

function quote(value) {
  if (/^[A-Za-z0-9_./@-]+$/.test(value)) return value;
  return '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/* ------------------------------ 段落 ------------------------------ */

const buildFiles = [];
const fileRefs = [];
const groups = [];

for (const entry of allSwift) {
  const key = entry.group + '/' + entry.name;
  buildFiles.push(
    `\t\t${id('build:' + key)} /* ${entry.name} in Sources */ = {isa = PBXBuildFile; fileRef = ${id('file:' + key)} /* ${entry.name} */; };`
  );
  fileRefs.push(
    `\t\t${id('file:' + key)} /* ${entry.name} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${quote(entry.name)}; sourceTree = "<group>"; };`
  );
}

fileRefs.push(
  `\t\t${id('file:assets')} /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };`
);
fileRefs.push(
  `\t\t${id('file:plist')} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };`
);
fileRefs.push(
  `\t\t${id('file:product')} /* ${TARGET}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ${TARGET}.app; sourceTree = BUILT_PRODUCTS_DIR; };`
);

buildFiles.push(
  `\t\t${id('build:assets')} /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = ${id('file:assets')} /* Assets.xcassets */; };`
);
buildFiles.push(
  `\t\t${id('build:swiftsoup')} /* SwiftSoup in Frameworks */ = {isa = PBXBuildFile; productRef = ${id('pkg:product')} /* SwiftSoup */; };`
);

// 分组
for (const group of groupOrder) {
  const files = sources[group] || [];
  const children = files.map((name) => `\t\t\t\t${id('file:' + group + '/' + name)} /* ${name} */,`).join('\n');
  groups.push(
    `\t\t${id('group:' + group)} /* ${group} */ = {\n` +
      `\t\t\tisa = PBXGroup;\n` +
      `\t\t\tchildren = (\n${children}\n\t\t\t);\n` +
      `\t\t\tpath = ${quote(group)};\n` +
      `\t\t\tsourceTree = "<group>";\n` +
      `\t\t};`
  );
}

const sourceChildren = [
  ...groupOrder.map((group) => `\t\t\t\t${id('group:' + group)} /* ${group} */,`),
  `\t\t\t\t${id('file:assets')} /* Assets.xcassets */,`,
  `\t\t\t\t${id('file:plist')} /* Info.plist */,`
].join('\n');

groups.push(
  `\t\t${id('group:source')} /* ${TARGET} */ = {\n` +
    `\t\t\tisa = PBXGroup;\n` +
    `\t\t\tchildren = (\n${sourceChildren}\n\t\t\t);\n` +
    `\t\t\tpath = ${quote(TARGET)};\n` +
    `\t\t\tsourceTree = "<group>";\n` +
    `\t\t};`
);

groups.push(
  `\t\t${id('group:products')} /* Products */ = {\n` +
    `\t\t\tisa = PBXGroup;\n` +
    `\t\t\tchildren = (\n\t\t\t\t${id('file:product')} /* ${TARGET}.app */,\n\t\t\t);\n` +
    `\t\t\tname = Products;\n` +
    `\t\t\tsourceTree = "<group>";\n` +
    `\t\t};`
);

groups.push(
  `\t\t${id('group:root')} = {\n` +
    `\t\t\tisa = PBXGroup;\n` +
    `\t\t\tchildren = (\n\t\t\t\t${id('group:source')} /* ${TARGET} */,\n\t\t\t\t${id('group:products')} /* Products */,\n\t\t\t);\n` +
    `\t\t\tsourceTree = "<group>";\n` +
    `\t\t};`
);

const sourceBuildIds = allSwift
  .map((entry) => `\t\t\t\t${id('build:' + entry.group + '/' + entry.name)} /* ${entry.name} in Sources */,`)
  .join('\n');

const projectDebugSettings = {
  ALWAYS_SEARCH_USER_PATHS: 'NO',
  CLANG_ANALYZER_NONNULL: 'YES',
  CLANG_ENABLE_MODULES: 'YES',
  CLANG_ENABLE_OBJC_ARC: 'YES',
  CLANG_ENABLE_OBJC_WEAK: 'YES',
  CLANG_WARN_BOOL_CONVERSION: 'YES',
  CLANG_WARN_CONSTANT_CONVERSION: 'YES',
  CLANG_WARN_EMPTY_BODY: 'YES',
  CLANG_WARN_ENUM_CONVERSION: 'YES',
  CLANG_WARN_INT_CONVERSION: 'YES',
  CLANG_WARN_UNREACHABLE_CODE: 'YES',
  COPY_PHASE_STRIP: 'NO',
  DEBUG_INFORMATION_FORMAT: 'dwarf',
  ENABLE_STRICT_OBJC_MSGSEND: 'YES',
  ENABLE_TESTABILITY: 'YES',
  ENABLE_USER_SCRIPT_SANDBOXING: 'YES',
  GCC_C_LANGUAGE_STANDARD: 'gnu17',
  GCC_NO_COMMON_BLOCKS: 'YES',
  GCC_OPTIMIZATION_LEVEL: '0',
  IPHONEOS_DEPLOYMENT_TARGET: DEPLOYMENT,
  MTL_ENABLE_DEBUG_INFO: 'INCLUDE_SOURCE',
  MTL_FAST_MATH: 'YES',
  ONLY_ACTIVE_ARCH: 'YES',
  SDKROOT: 'iphoneos',
  SWIFT_ACTIVE_COMPILATION_CONDITIONS: '"DEBUG $(inherited)"',
  SWIFT_OPTIMIZATION_LEVEL: '"-Onone"',
  SWIFT_STRICT_CONCURRENCY: 'minimal',
  SWIFT_VERSION: '5.0'
};

const projectReleaseSettings = {
  ...projectDebugSettings,
  DEBUG_INFORMATION_FORMAT: '"dwarf-with-dsym"',
  ENABLE_NS_ASSERTIONS: 'NO',
  MTL_ENABLE_DEBUG_INFO: 'NO',
  SWIFT_COMPILATION_MODE: 'wholemodule',
  VALIDATE_PRODUCT: 'YES'
};
delete projectReleaseSettings.ENABLE_TESTABILITY;
delete projectReleaseSettings.GCC_OPTIMIZATION_LEVEL;
delete projectReleaseSettings.ONLY_ACTIVE_ARCH;
delete projectReleaseSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS;
delete projectReleaseSettings.SWIFT_OPTIMIZATION_LEVEL;

const targetSettings = {
  ASSETCATALOG_COMPILER_APPICON_NAME: 'AppIcon',
  ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: 'AccentColor',
  CODE_SIGN_STYLE: 'Automatic',
  CURRENT_PROJECT_VERSION: '1',
  GENERATE_INFOPLIST_FILE: 'NO',
  INFOPLIST_FILE: `${TARGET}/Info.plist`,
  IPHONEOS_DEPLOYMENT_TARGET: DEPLOYMENT,
  LD_RUNPATH_SEARCH_PATHS: '(\n\t\t\t\t"$(inherited)",\n\t\t\t\t"@executable_path/Frameworks",\n\t\t\t)',
  MARKETING_VERSION: '1.0.0',
  PRODUCT_BUNDLE_IDENTIFIER: BUNDLE_ID,
  PRODUCT_NAME: '"$(TARGET_NAME)"',
  SUPPORTED_PLATFORMS: '"iphoneos iphonesimulator"',
  SUPPORTS_MACCATALYST: 'NO',
  SWIFT_EMIT_LOC_STRINGS: 'YES',
  SWIFT_STRICT_CONCURRENCY: 'minimal',
  SWIFT_VERSION: '5.0',
  TARGETED_DEVICE_FAMILY: '"1,2"'
};

function settingsBlock(settings, indent = '\t\t\t\t') {
  return Object.entries(settings)
    .map(([key, value]) => `${indent}${key} = ${value};`)
    .join('\n');
}

const pbxproj = `// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
${buildFiles.join('\n')}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
${fileRefs.join('\n')}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		${id('phase:frameworks')} /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				${id('build:swiftsoup')} /* SwiftSoup in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
${groups.join('\n')}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		${id('target')} /* ${TARGET} */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = ${id('configlist:target')} /* Build configuration list for PBXNativeTarget "${TARGET}" */;
			buildPhases = (
				${id('phase:sources')} /* Sources */,
				${id('phase:frameworks')} /* Frameworks */,
				${id('phase:resources')} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = ${TARGET};
			packageProductDependencies = (
				${id('pkg:product')} /* SwiftSoup */,
			);
			productName = ${TARGET};
			productReference = ${id('file:product')} /* ${TARGET}.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		${id('project')} /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {
					${id('target')} = {
						CreatedOnToolsVersion = 16.0;
					};
				};
			};
			buildConfigurationList = ${id('configlist:project')} /* Build configuration list for PBXProject "${TARGET}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				"zh-Hans",
			);
			mainGroup = ${id('group:root')};
			packageReferences = (
				${id('pkg:ref')} /* XCRemoteSwiftPackageReference "SwiftSoup" */,
			);
			productRefGroup = ${id('group:products')} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				${id('target')} /* ${TARGET} */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		${id('phase:resources')} /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				${id('build:assets')} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		${id('phase:sources')} /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
${sourceBuildIds}
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		${id('config:project:debug')} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
${settingsBlock(projectDebugSettings)}
			};
			name = Debug;
		};
		${id('config:project:release')} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
${settingsBlock(projectReleaseSettings)}
			};
			name = Release;
		};
		${id('config:target:debug')} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
${settingsBlock(targetSettings)}
			};
			name = Debug;
		};
		${id('config:target:release')} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
${settingsBlock(targetSettings)}
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		${id('configlist:project')} /* Build configuration list for PBXProject "${TARGET}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				${id('config:project:debug')} /* Debug */,
				${id('config:project:release')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		${id('configlist:target')} /* Build configuration list for PBXNativeTarget "${TARGET}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				${id('config:target:debug')} /* Debug */,
				${id('config:target:release')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCRemoteSwiftPackageReference section */
		${id('pkg:ref')} /* XCRemoteSwiftPackageReference "SwiftSoup" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/scinfu/SwiftSoup.git";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = ${SWIFT_SOUP_MIN};
			};
		};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		${id('pkg:product')} /* SwiftSoup */ = {
			isa = XCSwiftPackageProductDependency;
			package = ${id('pkg:ref')} /* XCRemoteSwiftPackageReference "SwiftSoup" */;
			productName = SwiftSoup;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = ${id('project')} /* Project object */;
}
`;

mkdirSync(projectDir, { recursive: true });
writeFileSync(outFile, pbxproj, 'utf8');
console.log('wrote', outFile);
console.log('sources:', allSwift.length, 'files');
