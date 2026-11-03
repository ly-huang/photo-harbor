// Standalone runner for Command Line Tools installations without XCTest.
// Executes the same test methods as the SwiftPM XCTest target.
import Foundation
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { if try !value() { fatalError("Expected true", file: file, line: line) } }
    catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { let a = try lhs(); let b = try rhs(); if a != b { fatalError("\(a) != \(b)", file: file, line: line) } }
    catch { fatalError("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value() } catch { return }
    fatalError("Expected error", file: file, line: line)
}
@main struct CoreTestRunner {
    static func main() throws {
        let suite = LibraryServiceTests()
        let tests: [(String, () throws -> Void)] = [
            ("filtered export conflicts and safety", suite.testFilteredExport),
            ("relative pairing", suite.testRelativePairsStayWithinAlbumDespiteRepeatedNames),
            ("unique fallback and ambiguity", suite.testUniqueFallbackAndAmbiguousDuplicates),
            ("nested and offline roots", suite.testNestedAndDisconnectedRootsRejected),
            ("deletion revalidation", suite.testNewCounterpartAndChangedFileBlockDeletion),
            ("symlinks", suite.testSymlinksAreSkipped),
            ("date alignment and verified copy", suite.testPlanAlignsPairDateAndRefusesCollision),
            ("overwrite prevention", suite.testCopyNeverOverwritesAndRejectsSymlinkParent),
            ("restore collision", suite.testRestoreRefusesOverwrite),
            ("duplicate import plan", suite.testDuplicateImportDestinationsRejectedBeforeCopy),
            ("EXIF original capture date", suite.testEXIFDateOverridesModificationDate),
            ("optional location and new destination roots", suite.testOptionalPlaceAndNewRootsPreviewDoesNotWrite),
            ("embedded location, GPS and manual precedence", suite.testEmbeddedPlaceAndGPSFallbackPriority),
            ("single format and shared import parent", suite.testSingleFormatAlbumsAndSharedImportDestination),
            ("legacy state and history expiry", suite.testLegacyStateAndHistoryExpiry),
            ("reused filename keeps fresh review state", suite.testReusedPathDoesNotInheritRejection)
        ]
        for (name, test) in tests {
            try suite.setUpWithError()
            do { try test() } catch { try? suite.tearDownWithError(); throw error }
            try suite.tearDownWithError()
            print("PASS \(name)")
        }
        print("\(tests.count) core tests passed")
    }
}
