import XCTest

final class WallpaperStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: WallpaperStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = WallpaperStore(paths: WallpaperPaths(root: tempDir.appendingPathComponent("Support")))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testImportCopiesVideoAndWritesConfig() async throws {
        let source = try await VideoFixture.makeMovie(in: tempDir)

        let config = try await store.importVideo(from: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: config.videoPath))
        XCTAssertEqual(config.videoURL.deletingLastPathComponent().standardizedFileURL,
                       store.paths.videos.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: config.videoURL), try Data(contentsOf: source))
        XCTAssertEqual(store.currentConfig, config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original must be left in place")
    }

    func testImportRejectsNonMovie() async throws {
        let text = tempDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        do {
            _ = try await store.importVideo(from: text)
            XCTFail("expected notAMovie")
        } catch {
            XCTAssertEqual(error as? ImportError, .notAMovie)
        }
        XCTAssertNil(store.currentConfig)
    }

    func testImportRejectsCorruptMovie() async throws {
        let fake = tempDir.appendingPathComponent("broken.mov")
        try Data(repeating: 0xAB, count: 1024).write(to: fake)

        do {
            _ = try await store.importVideo(from: fake)
            XCTFail("expected unplayable")
        } catch {
            XCTAssertEqual(error as? ImportError, .unplayable)
        }
        XCTAssertNil(store.currentConfig)
    }

    func testSecondImportReplacesFirst() async throws {
        let first = try await store.importVideo(from: try await VideoFixture.makeMovie(in: tempDir, name: "a.mov"))
        let second = try await store.importVideo(from: try await VideoFixture.makeMovie(in: tempDir, name: "b.mov"))

        XCTAssertNotEqual(first.videoPath, second.videoPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.videoPath), "old copy should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.videoPath))
        XCTAssertEqual(store.currentConfig, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.videos.path).count, 1)
    }
}
