import XCTest
@testable import Claude_Usage

/// Tests for the stale-cache handling in the installed statusline script.
///
/// The script is bash, so each case extracts the relevant function from the real
/// `bashScript` and runs it. Testing a copy of the helpers instead would let them
/// drift from what actually ships.
final class StatuslineServiceStaleCacheTests: XCTestCase {

    private var service: StatuslineService { .shared }

    // MARK: - Helpers

    /// Writes `script` to a temp file and returns its path.
    private func writeScript(_ script: String, named name: String = "script.sh") throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("statusline-\(UUID().uuidString)-\(name)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// Runs `bash -n` so a malformed script fails the test rather than the user's statusline.
    private func assertScriptParses() throws {
        let path = try writeScript(service.bashScript, named: "parse.sh")
        let result = try run("/bin/bash", ["-n", path])
        XCTAssertEqual(
            result.status, 0,
            "installed statusline must be valid bash:\n\(result.stderr)"
        )
    }

    /// Pulls a single `name() { ... }` function out of the script.
    private func function(_ name: String) throws -> String {
        let lines = service.bashScript.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(name)() {") }) else {
            XCTFail("statusline script no longer defines \(name)()")
            throw XCTSkip("\(name)() not found")
        }
        guard let end = lines[start...].firstIndex(where: { $0 == "}" }) else {
            XCTFail("\(name)() is unterminated")
            throw XCTSkip("\(name)() unterminated")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// The threshold constant plus both helpers, in dependency order. Sourcing a
    /// helper on its own would leave it calling something undefined, so every
    /// evaluation gets all three.
    private func stalePreamble() throws -> String {
        try function("format_cache_age") + "\n\n" + function("cache_stale_marker")
    }

    @discardableResult
    private func run(_ launch: String, _ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            // Only newlines: the stale marker deliberately starts with a space,
            // so trimming whitespace would delete the thing under test.
            String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .newlines),
            String(decoding: errData, as: UTF8.self)
        )
    }

    /// Sources the threshold and both helpers, then evaluates `body`,
    /// returning trimmed stdout.
    private func eval(function functionName: String, _ body: String) throws -> String {
        let source = "cache_stale_after=300\n\n" + (try stalePreamble()) + "\n" + body
        let path = try writeScript(source, named: "\(functionName).sh")
        let result = try run("/bin/bash", [path])
        XCTAssertEqual(
            result.status, 0,
            "evaluating \(functionName) failed:\n\(result.stderr)"
        )
        XCTAssertEqual(
            result.stderr, "",
            "evaluating \(functionName) wrote to stderr:\n\(result.stderr)"
        )
        return result.stdout
    }

    // MARK: - Script integrity

    func testInstalledScriptIsValidBash() throws {
        try assertScriptParses()
    }

    /// Every gate must go through the shared helpers, so the threshold lives in
    /// one place instead of being repeated per block.
    func testNoBlockHardcodesTheFreshnessThreshold() {
        XCTAssertFalse(
            service.bashScript.contains("-lt 300"),
            "a block still gates on a literal 300s; use cache_stale_after"
        )
        XCTAssertTrue(service.bashScript.contains("cache_stale_after=300"))
    }

    // MARK: - format_cache_age

    func testFormatCacheAgeSeconds() throws {
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 0"), "0s")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 47"), "47s")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 59"), "59s")
    }

    func testFormatCacheAgeMinutes() throws {
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 60"), "1m")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 780"), "13m")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 3599"), "59m")
    }

    func testFormatCacheAgeHours() throws {
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 3600"), "1h")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 3660"), "1h1m")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 7500"), "2h5m")
        XCTAssertEqual(try eval(function: "format_cache_age", "format_cache_age 90000"), "25h")
    }

    // MARK: - cache_stale_marker

    /// Under the threshold nothing is appended, so a fresh reading is unchanged.
    func testFreshCacheAddsNoMarker() throws {
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=colored; GRAY=''; RESET=''; cache_stale_marker 120 ''"
            ),
            ""
        )
    }

    func testCacheWithNoTimestampAddsNoMarker() throws {
        // The cache exists but carries no TIMESTAMP, so there is no age to show.
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=colored; GRAY=''; RESET=''; cache_stale_marker '' ''"
            ),
            ""
        )
    }

    func testStaleCacheMarksAgeInColourMode() throws {
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=colored; GRAY='<g>'; RESET='<r>'; cache_stale_marker 780 '<c>'"
            ),
            " <g>⋯ 13m<r><c>"
        )
    }

    func testStaleCacheMarksAgeInMonochromeMode() throws {
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=monochrome; GRAY=''; RESET=''; cache_stale_marker 780 ''"
            ),
            " (stale 13m)"
        )
    }

    /// The original gate was `-lt 300`: a cache younger than 300s was served, and
    /// 300s itself was already discarded. This pins that same boundary, so the
    /// change is only about *what* happens at 300s (labelled, not dropped).
    func testThresholdMatchesTheOriginalBoundary() throws {
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=monochrome; GRAY=''; RESET=''; cache_stale_marker 299 ''"
            ),
            "",
            "a cache younger than the threshold is fresh and unmarked"
        )
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=monochrome; GRAY=''; RESET=''; cache_stale_marker 300 ''"
            ),
            " (stale 5m)",
            "at the threshold the reading is labelled rather than dropped"
        )
        XCTAssertEqual(
            try eval(
                function: "cache_stale_marker",
                "color_mode=monochrome; GRAY=''; RESET=''; cache_stale_marker 301 ''"
            ),
            " (stale 5m)",
            "one second past the threshold should be marked"
        )
    }

    // MARK: - Cache reads are no longer withheld

    /// The bug: a stale reading was discarded, so the segment rendered empty.
    /// Each block must read its values regardless of age.
    func testStaleCacheValuesAreStillRead() {
        for key in ["UTILIZATION=", "WEEKLY_UTILIZATION=", "COST_USED="] {
            XCTAssertTrue(
                service.bashScript.contains("grep \"^\(key)\""),
                "\(key) is no longer read from the cache"
            )
        }
    }
}
