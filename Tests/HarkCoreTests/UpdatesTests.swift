import XCTest
@testable import HarkCore

final class UpdatesTests: XCTestCase {
    func testComparesVersionsNumberByNumber() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.9.0")), try XCTUnwrap(AppVersion("0.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.1.0")), try XCTUnwrap(AppVersion("v0.2.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.2")), try XCTUnwrap(AppVersion("1.2.1")))
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertEqual(AppVersion("v2.0.1-beta.1"), AppVersion("2.0.1"))
        XCTAssertFalse(try XCTUnwrap(AppVersion("1.0.0")) < XCTUnwrap(AppVersion("1.0")))
    }

    func testRejectsTagsThatAreNotVersions() {
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion(""))
    }

    func testReadsAGitHubRelease() throws {
        let json = """
        {"tag_name": "v0.3.0", "html_url": "https://github.com/piyush-hack/Hark/releases/tag/v0.3.0",
         "body": "## What's new\\r\\n- Faster wake-up\\r\\n\\r\\n---\\r\\n**Install:** drag Hark to Applications.",
         "assets": [
           {"name": "Hark-0.3.0.dmg", "browser_download_url": "https://example.com/Hark-0.3.0.dmg", "size": 9000000},
           {"name": "Hark-0.3.0.zip", "browser_download_url": "https://example.com/Hark-0.3.0.zip", "size": 7900000}
         ]}
        """
        let release = try Release(githubJSON: Data(json.utf8))
        XCTAssertEqual(release.version, AppVersion("0.3.0"))
        XCTAssertEqual(release.notes, "## What's new\n- Faster wake-up")
        XCTAssertEqual(release.archive, URL(string: "https://example.com/Hark-0.3.0.zip"))
        XCTAssertEqual(release.archiveSize, 7_900_000)
        XCTAssertEqual(release.page.absoluteString, "https://github.com/piyush-hack/Hark/releases/tag/v0.3.0")
    }

    func testAReleaseWithoutAnAppHasNoArchive() throws {
        let json = #"{"tag_name": "0.4.0", "html_url": "https://github.com/x/y/releases/tag/0.4.0", "body": null, "assets": []}"#
        let release = try Release(githubJSON: Data(json.utf8))
        XCTAssertNil(release.archive)
        XCTAssertEqual(release.notes, "")
    }

    func testOnlyAnAppBundleCanUpdateItself() {
        // Tests run from an .xctest bundle, which must never be replaced.
        guard case .failure = UpdateInstaller.destination(for: Bundle(for: Self.self)) else {
            return XCTFail("a test bundle is not an installable app")
        }
    }
}
