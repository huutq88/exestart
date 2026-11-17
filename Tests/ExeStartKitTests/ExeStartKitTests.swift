@testable import ExeStartKit
import XCTest

final class ExeStartKitTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParseAssetName() {
        XCTAssertEqual(RuntimeManager.parseAssetName("wine-stable-11.0_1-osx64.tar.xz")?.channel, "stable")
        XCTAssertEqual(RuntimeManager.parseAssetName("wine-stable-11.0_1-osx64.tar.xz")?.version, "11.0_1")
        XCTAssertEqual(RuntimeManager.parseAssetName("wine-staging-11.21-osx64.tar.xz")?.channel, "staging")
        XCTAssertNil(RuntimeManager.parseAssetName("wine-foo-1.0-osx64.tar.xz"))
        XCTAssertNil(RuntimeManager.parseAssetName("README.md"))
    }

    func testParseReleases() throws {
        let json = """
        [{"published_at":"2026-04-16T14:05:00Z","assets":[
          {"name":"wine-stable-11.0_1-osx64.tar.xz","size":185303032,
           "browser_download_url":"https://example.com/wine-stable-11.0_1-osx64.tar.xz"},
          {"name":"checksums.txt","size":10,"browser_download_url":"https://example.com/c.txt"}]}]
        """
        let list = try RuntimeManager.parseReleases(Data(json.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "wine-stable-11.0_1")
        XCTAssertNotNil(list[0].publishedAt)
    }

    func testFindWineBinaryPrefersWine() throws {
        let bin = tmp.appendingPathComponent("Wine Stable.app/Contents/Resources/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["wine64", "wine", "wineserver"] {
            let f = bin.appendingPathComponent(name)
            FileManager.default.createFile(atPath: f.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        XCTAssertEqual(RuntimeManager.findWineBinary(in: tmp)?.lastPathComponent, "wine")
    }

    func testInstallArchiveFromFakeTarball() throws {
        // Dựng một gói giống của Gcenx với `wine` giả, nén .tar.xz rồi cài.
        let src = tmp.appendingPathComponent("src")
        let bin = src.appendingPathComponent("Wine Stable.app/Contents/Resources/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine").path,
                                       contents: Data("#!/bin/sh\necho wine-11.0\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let archive = tmp.appendingPathComponent("wine.tar.xz")
        try Shell.run("/usr/bin/tar", ["-cJf", archive.path, "-C", src.path, "Wine Stable.app"])

        let mgr = RuntimeManager(paths: Paths(root: tmp.appendingPathComponent("home")))
        try mgr.paths.ensureExists()
        let rt = try mgr.installArchive(archive, id: "wine-stable-11.0_1", channel: "stable", version: "11.0_1")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: rt.wineBinary.path))
        XCTAssertEqual(mgr.installed().map(\.id), ["wine-stable-11.0_1"])
        XCTAssertEqual(try mgr.runtime(id: nil).id, "wine-stable-11.0_1")
    }

    func testWineArguments() {
        XCTAssertEqual(Wine.arguments(for: URL(fileURLWithPath: "/a/Setup.MSI"), extra: []),
                       ["msiexec", "/i", "/a/Setup.MSI"])
        XCTAssertEqual(Wine.arguments(for: URL(fileURLWithPath: "/a/x.bat"), extra: ["1"]),
                       ["cmd", "/c", "/a/x.bat", "1"])
        XCTAssertEqual(Wine.arguments(for: URL(fileURLWithPath: "/a/app.exe"), extra: ["-v"]),
                       ["/a/app.exe", "-v"])
        XCTAssertEqual(Wine.arguments(for: URL(fileURLWithPath: "/a/App.lnk"), extra: []),
                       ["start", "/unix", "/a/App.lnk"])
    }

    func testValidateName() {
        XCTAssertNoThrow(try validateName("Văn phòng 2"))
        XCTAssertNoThrow(try validateName("my-bottle_1.0"))
        XCTAssertThrowsError(try validateName(""))
        XCTAssertThrowsError(try validateName("../etc"))
        XCTAssertThrowsError(try validateName(".hidden"))
        XCTAssertThrowsError(try validateName("a/b"))
    }

    func testBottleConfigDecodesOldFiles() throws {
        let cfg = try JSONDecoder().decode(BottleConfig.self, from: Data(#"{"runtimeID":"x"}"#.utf8))
        XCTAssertEqual(cfg.runtimeID, "x")
        XCTAssertEqual(cfg.windowsVersion, .win10)
        XCTAssertEqual(cfg.dpi, 96)
    }

    func testProgramDiscovery() throws {
        let paths = Paths(root: tmp)
        try paths.ensureExists()
        let dir = paths.bottles.appendingPathComponent("Test")
        let bottle = Bottle(name: "Test", directory: dir, config: BottleConfig())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bottle.save()
        let pf = bottle.driveC.appendingPathComponent("Program Files/Acme")
        let menu = bottle.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs/Acme")
        for d in [pf, menu, bottle.driveC.appendingPathComponent("Program Files/Internet Explorer")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        for f in [pf.appendingPathComponent("Acme.exe"), pf.appendingPathComponent("unins000.exe"),
                  pf.appendingPathComponent("Tool.exe"), menu.appendingPathComponent("Acme.lnk"),
                  bottle.driveC.appendingPathComponent("Program Files/Internet Explorer/iexplore.exe")] {
            FileManager.default.createFile(atPath: f.path, contents: Data())
        }
        let programs = BottleManager(paths: paths).programs(in: try BottleManager(paths: paths).bottle(named: "Test"))
        XCTAssertEqual(programs.map(\.name), ["Acme", "Tool"])
        XCTAssertEqual(programs.first?.kind, .startMenu)   // ưu tiên shortcut Start Menu, bỏ trùng tên
    }

    func testShortcutScriptQuotes() throws {
        XCTAssertEqual(Shortcut.shellQuote("it's"), #"'it'\''s'"#)
    }
}
