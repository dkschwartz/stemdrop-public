import XCTest
@testable import StemDrop

final class CleanupSettingsTests: XCTestCase {
    func testEngineArgumentsForDefaults() {
        let settings = CleanupSettings()
        XCTAssertEqual(
            settings.engineArguments,
            ["--reseparate", "1", "--gate", "1", "--gate-threshold", "0.50", "--denoise", "0.50"]
        )
    }

    func testEngineArgumentsWithAllThreeOff() {
        var settings = CleanupSettings()
        settings.reseparate = false
        settings.gate = false
        settings.denoise = false
        XCTAssertEqual(
            settings.engineArguments,
            ["--reseparate", "0", "--gate", "0", "--gate-threshold", "0.50", "--denoise", "0"]
        )
    }
}
