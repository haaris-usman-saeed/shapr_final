import Foundation
import ShaprCore

// swift run ShaprCoreChecks          behaviour checks for Shapr Flow's core
// swift run ShaprCoreChecks --demo   the TechniGala story, run through the real engine
let args = CommandLine.arguments
if args.contains("--demo") {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shapr-flow-demo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    // A fixed afternoon so the output is the same every run.
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = 14; c.minute = 0
    print(FlowDemo.narrate(directory: dir, start: Calendar.current.date(from: c)!))
    exit(0)
}
var failures = 0
var passes = 0
FlowCoreChecks.run { ok, what in
    print(ok ? "  PASS" : "  FAIL", what)
    if ok { passes += 1 } else { failures += 1 }
}
print(failures == 0 ? "\nAll \(passes) Flow core checks passed." : "\n\(failures) of \(passes + failures) Flow core check(s) failed.")
exit(failures == 0 ? 0 : 1)
