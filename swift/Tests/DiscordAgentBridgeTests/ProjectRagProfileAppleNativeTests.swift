import Foundation
import Testing
@testable import DiscordAgentBridge

// Fixture-based — ports the former ObjcXcodeProfileTests + SwiftSpmXcodeProfileTests fixtures
// onto the merged `AppleNativeProfile` (objc-xcode + swift-spm-xcode profiles combined so ObjC and
// Swift no longer compete as separate primary profiles), plus new coverage for the merge's actual
// point (ObjC + Swift symbols coexisting in one discovery) and the new C/C++ class/struct + #include
// extraction.

@Suite("AppleNativeProfile")
struct AppleNativeProfileTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-applenative-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ root: URL, _ relativePath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func record(_ path: String) -> ProjectFileRecord {
        ProjectFileRecord(path: path, sha256: "", size: 0, mtimeNs: 0)
    }

    private static let pbxproj = """
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	objectVersion = 56;
    	objects = {

    /* Begin PBXNativeTarget section */
    		AAAA0000AAAA0000AAAA0001 /* SampleApp */ = {
    			isa = PBXNativeTarget;
    			buildConfigurationList = AAAA0000AAAA0000AAAA0002 /* Build configuration list for PBXNativeTarget "SampleApp" */;
    			buildPhases = (
    			);
    			dependencies = (
    				AAAA0000AAAA0000AAAA0003 /* PBXTargetDependency */,
    			);
    			name = SampleApp;
    			productName = SampleApp;
    		};
    		AAAA0000AAAA0000AAAA0004 /* SampleKit */ = {
    			isa = PBXNativeTarget;
    			buildConfigurationList = AAAA0000AAAA0000AAAA0005 /* Build configuration list for PBXNativeTarget "SampleKit" */;
    			buildPhases = (
    			);
    			dependencies = (
    			);
    			name = SampleKit;
    			productName = SampleKit;
    		};
    /* End PBXNativeTarget section */

    /* Begin PBXTargetDependency section */
    		AAAA0000AAAA0000AAAA0003 /* PBXTargetDependency */ = {
    			isa = PBXTargetDependency;
    			target = AAAA0000AAAA0000AAAA0004 /* SampleKit */;
    			targetProxy = AAAA0000AAAA0000AAAA0006 /* PBXContainerItemProxy */;
    		};
    /* End PBXTargetDependency section */

    	};
    	rootObject = AAAA0000AAAA0000AAAA0007 /* Project object */;
    }
    """

    private static let sampleKitPublicHeader = """
    #import <Foundation/Foundation.h>

    @protocol SampleKitDelegate <NSObject>
    - (void)kitDidFinish;
    @end

    @interface SampleKit : NSObject
    + (instancetype)sharedKit;
    - (void)runWithCompletion:(void (^)(BOOL success))completion;
    @end
    """

    private static let appDelegateHeader = """
    #import <UIKit/UIKit.h>

    @interface AppDelegate : UIResponder
    - (BOOL)applicationDidFinishLaunching;
    @end
    """

    private static let appDelegateSource = """
    #import "AppDelegate.h"
    #import <SampleKit/SampleKit.h>

    @implementation AppDelegate
    - (BOOL)applicationDidFinishLaunching {
        return YES;
    }
    @end
    """

    private static let bridgeHeader = "void bridge_call(void);\n"

    private static let bridgeSource = """
    #include "Bridge.h"
    #import <Foundation/Foundation.h>

    void bridge_call(void) {}
    """

    // MARK: - matches

    @Test func matches_pbxprojAndObjcSourcesPresent_scoresHigh() throws {
        let profile = AppleNativeProfile()
        let files = [record("Sample.xcodeproj/project.pbxproj"), record("SampleApp/AppDelegate.h")]
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: files) == 90)
    }

    // Merging objc-xcode + swift-spm-xcode loosened this: a bare `.pbxproj` alone (condition a)
    // now scores 90 even without a recognized ObjC/Swift source alongside it, since the merged
    // profile no longer needs a language-specific score to out-rank `GenericFileGraphProfile`.
    @Test func matches_pbxprojAlonePresent_scoresHigh() throws {
        let profile = AppleNativeProfile()
        let files = [record("Sample.xcodeproj/project.pbxproj"), record("README.md")]
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: files) == 90)
    }

    @Test func matches_noPbxprojNoPackageSwift_scoresZero() throws {
        let profile = AppleNativeProfile()
        let files = [record("SampleApp/AppDelegate.h"), record("SampleApp/AppDelegate.m")]
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: files) == 0)
    }

    @Test func matches_packageSwiftPresent_scoresHigh() throws {
        let profile = AppleNativeProfile()
        let score = profile.matches(root: URL(fileURLWithPath: "/tmp"), files: [record("Package.swift")])
        #expect(score == 90)
    }

    // Both former profiles' xcodeproj+swift condition scored differently (80 vs the pbxproj-only
    // 90); now unified to a single profile, every match branch scores 90.
    @Test func matches_xcodeprojPlusSwift_scoresHigh() throws {
        let profile = AppleNativeProfile()
        let files = [record("App.xcodeproj/project.pbxproj"), record("App/Main.swift")]
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: files) == 90)
    }

    @Test func matches_neitherPresent_scoresZero() throws {
        let profile = AppleNativeProfile()
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: [record("README.md")]) == 0)
    }

    // MARK: - ObjC discovery (ported from ObjcXcodeProfileTests)

    @Test func discover_extractsTargetsHeadersSelectorsAndImportEdges() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(root, "Sample.xcodeproj/project.pbxproj", Self.pbxproj)
        try writeFile(root, "Public/SampleKit.h", Self.sampleKitPublicHeader)
        try writeFile(root, "SampleApp/AppDelegate.h", Self.appDelegateHeader)
        try writeFile(root, "SampleApp/AppDelegate.m", Self.appDelegateSource)
        try writeFile(root, "SampleApp/Bridge.h", Self.bridgeHeader)
        try writeFile(root, "SampleApp/Bridge.mm", Self.bridgeSource)

        let files = [
            record("Sample.xcodeproj/project.pbxproj"),
            record("Public/SampleKit.h"),
            record("SampleApp/AppDelegate.h"),
            record("SampleApp/AppDelegate.m"),
            record("SampleApp/Bridge.h"),
            record("SampleApp/Bridge.mm"),
        ]
        let profile = AppleNativeProfile()
        let discovery = try await profile.discover(root: root, files: files)

        // target graph
        let moduleIds = Set(discovery.modules.map(\.id))
        #expect(moduleIds == ["SampleApp", "SampleKit"])
        #expect(discovery.edges.contains {
            $0.kind == "target-dependency" && $0.fromModuleId == "SampleApp" && $0.toModuleId == "SampleKit"
        })

        // public header
        #expect(discovery.symbols.contains {
            $0.kind == "public-header" && $0.path == "Public/SampleKit.h"
        })
        #expect(!discovery.symbols.contains { $0.kind == "public-header" && $0.path == "SampleApp/AppDelegate.h" })

        // @interface / @protocol
        let interfaceNames = Set(discovery.symbols.filter { $0.kind == "interface" }.map(\.name))
        #expect(interfaceNames == ["SampleKit", "AppDelegate"])
        #expect(discovery.symbols.contains { $0.kind == "protocol" && $0.name == "SampleKitDelegate" })

        // selectors
        let selectorNames = Set(discovery.symbols.filter { $0.kind == "selector" }.map(\.name))
        #expect(selectorNames == ["sharedKit", "kitDidFinish", "runWithCompletion:", "applicationDidFinishLaunching"])

        // #import edges: quoted resolves to the sibling header; angle-bracket framework-style
        // import falls back to a basename match against the public header living elsewhere.
        #expect(discovery.edges.contains {
            $0.kind == "import" && $0.fromModuleId == "SampleApp/AppDelegate.m" && $0.toModuleId == "SampleApp/AppDelegate.h"
        })
        #expect(discovery.edges.contains {
            $0.kind == "import" && $0.fromModuleId == "SampleApp/AppDelegate.m" && $0.toModuleId == "Public/SampleKit.h"
        })

        // #include edge + unresolved system header falls back to the raw import spec
        #expect(discovery.edges.contains {
            $0.kind == "include" && $0.fromModuleId == "SampleApp/Bridge.mm" && $0.toModuleId == "SampleApp/Bridge.h"
        })
        #expect(discovery.edges.contains {
            $0.kind == "import" && $0.fromModuleId == "SampleApp/Bridge.mm" && $0.toModuleId == "Foundation/Foundation.h"
        })
    }

    @Test func discover_unreadableFiles_recordDiagnosticsInsteadOfThrowing() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // No files actually written to disk — every listed record is unreadable.
        let files = [record("Sample.xcodeproj/project.pbxproj"), record("SampleApp/AppDelegate.h")]
        let profile = AppleNativeProfile()
        let discovery = try await profile.discover(root: root, files: files)

        #expect(discovery.modules.isEmpty)
        #expect(discovery.symbols.isEmpty)
        #expect(discovery.diagnostics.contains { $0.code == "unreadablePbxproj" })
        #expect(discovery.diagnostics.contains { $0.code == "unreadableSource" })
    }

    // MARK: - Swift discovery (ported from SwiftSpmXcodeProfileTests)

    @Test func discover_extractsTargetsImportsAndSymbolsFromPackageSwift() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(
            root, "Package.swift",
            """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(
                name: "Sample",
                targets: [
                    .target(
                        name: "SampleLib",
                        dependencies: []
                    ),
                    .executableTarget(name: "sample-cli", dependencies: ["SampleLib"]),
                    .testTarget(name: "SampleLibTests", dependencies: ["SampleLib"]),
                ]
            )
            """
        )
        try writeFile(
            root, "Sources/SampleLib/Widget.swift",
            """
            import Foundation

            public protocol Widget: Sendable {
                var id: String { get }
            }

            public struct DefaultWidget: Widget {
                public let id: String
            }

            public final class WidgetFactory {
                func make() -> DefaultWidget { DefaultWidget(id: "x") }
            }
            """
        )

        let files = [record("Package.swift"), record("Sources/SampleLib/Widget.swift")]
        let profile = AppleNativeProfile()
        let discovery = try await profile.discover(root: root, files: files)

        let moduleIds = Set(discovery.modules.map(\.id))
        #expect(moduleIds == ["SampleLib", "sample-cli"], "testTarget must not be picked up as a module")

        let importEdges = discovery.edges.filter { $0.kind == "import" }
        #expect(importEdges.contains { $0.fromModuleId == "SampleLib" && $0.toModuleId == "Foundation" })

        let symbolNames = Set(discovery.symbols.map(\.name))
        #expect(symbolNames.isSuperset(of: ["Widget", "DefaultWidget", "WidgetFactory", "make"]))
        #expect(discovery.symbols.first { $0.name == "Widget" }?.kind == "protocol")
        #expect(discovery.symbols.first { $0.name == "DefaultWidget" }?.kind == "struct")
        #expect(discovery.symbols.first { $0.name == "WidgetFactory" }?.kind == "class")
        #expect(discovery.symbols.first { $0.name == "make" }?.kind == "func")
        #expect(discovery.symbols.allSatisfy { $0.moduleId == "SampleLib" })
    }

    @Test func discover_withoutPackageSwift_stillScansSwiftFilesAndFallsBackToDirectoryModule() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(
            root, "App/Main.swift",
            """
            import UIKit

            struct Root {}
            """
        )

        let files = [record("App/Main.swift")]
        let profile = AppleNativeProfile()
        let discovery = try await profile.discover(root: root, files: files)

        #expect(discovery.modules.isEmpty)
        #expect(discovery.symbols.contains { $0.name == "Root" && $0.kind == "struct" && $0.moduleId == "App" })
        #expect(discovery.edges.contains { $0.kind == "import" && $0.toModuleId == "UIKit" && $0.fromModuleId == "App" })
    }

    // MARK: - merge regression: ObjC + Swift coexist in one project

    // This is the actual point of merging objc-xcode + swift-spm-xcode: before the merge,
    // `ProjectRagBuilder.build()` picked exactly one highest-scoring profile as primary, so a
    // project with both ObjC and Swift sources (e.g. NEWSDK) lost one language's symbols entirely.
    // A single profile scanning both means both show up in the same discovery.
    @Test func discover_objcAndSwiftCoexist_bothLanguagesSymbolsPresent() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(root, "Sample.xcodeproj/project.pbxproj", Self.pbxproj)
        try writeFile(root, "SampleApp/AppDelegate.h", Self.appDelegateHeader)
        try writeFile(root, "SampleApp/AppDelegate.m", Self.appDelegateSource)
        try writeFile(
            root, "SampleApp/SwiftHelper.swift",
            """
            import Foundation

            class SwiftHelper {
                func run() {}
            }

            struct SwiftModel {
                let id: String
            }
            """
        )

        let files = [
            record("Sample.xcodeproj/project.pbxproj"),
            record("SampleApp/AppDelegate.h"),
            record("SampleApp/AppDelegate.m"),
            record("SampleApp/SwiftHelper.swift"),
        ]
        let profile = AppleNativeProfile()
        let discovery = try await profile.discover(root: root, files: files)

        // ObjC symbols present
        #expect(discovery.symbols.contains { $0.kind == "interface" && $0.name == "AppDelegate" })
        #expect(discovery.symbols.contains { $0.kind == "selector" && $0.name == "applicationDidFinishLaunching" })

        // Swift symbols present in the same discovery — neither language crowded the other out
        #expect(discovery.symbols.contains { $0.kind == "class" && $0.name == "SwiftHelper" })
        #expect(discovery.symbols.contains { $0.kind == "func" && $0.name == "run" })
        #expect(discovery.symbols.contains { $0.kind == "struct" && $0.name == "SwiftModel" })
    }

    // MARK: - C/C++ discovery (new)

    @Test func discover_cxxFiles_extractsClassStructSymbolsAndIncludeEdges() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(
            root, "Lib/Foo.hpp",
            """
            #pragma once

            class FooBase {
            public:
                virtual ~FooBase() = default;
            };

            struct FooConfig {
                int value;
            };
            """
        )
        try writeFile(
            root, "Lib/Foo.cpp",
            """
            #include "Foo.hpp"
            #include <string>

            class FooImpl : public FooBase {
            };
            """
        )

        let files = [record("Lib/Foo.hpp"), record("Lib/Foo.cpp")]
        let profile = AppleNativeProfile()
        let discovery = try await profile.discover(root: root, files: files)

        let classNames = Set(discovery.symbols.filter { $0.kind == "class" }.map(\.name))
        #expect(classNames == ["FooBase", "FooImpl"])
        let structNames = Set(discovery.symbols.filter { $0.kind == "struct" }.map(\.name))
        #expect(structNames == ["FooConfig"])

        #expect(discovery.edges.contains {
            $0.kind == "include" && $0.fromModuleId == "Lib/Foo.cpp" && $0.toModuleId == "Lib/Foo.hpp"
        })
        #expect(discovery.edges.contains {
            $0.kind == "include" && $0.fromModuleId == "Lib/Foo.cpp" && $0.toModuleId == "string"
        })
    }
}
