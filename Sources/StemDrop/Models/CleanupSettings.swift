import Foundation

/// Options for the Vocal Cleanup tab, mapped straight onto
/// `stemdrop_engine.cleanup`'s CLI arguments.
struct CleanupSettings: Equatable, Sendable {
    var reseparate: Bool = true
    var reseparatePasses: Int = 1        // 1 or 2
    var gate: Bool = true
    var gateThreshold: Double = 0.5      // 0.1…0.9
    var denoise: Bool = true
    var denoiseAmount: Double = 0.5      // 0.1…1.0

    var engineArguments: [String] {
        [
            "--reseparate", reseparate ? "\(reseparatePasses)" : "0",
            "--gate", gate ? "1" : "0",
            "--gate-threshold", String(format: "%.2f", gateThreshold),
            "--denoise", denoise ? String(format: "%.2f", denoiseAmount) : "0"
        ]
    }
}
