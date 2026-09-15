//  CurveProbe.swift
//  Sanity-checks the hand-rolled timing curve against the shape SwiftUI would
//  produce for the same control points. Debug utility.

#if os(macOS)
import Foundation
import CoreText

enum CurveProbe {
    static func run() {
        let b = UnitBezier(0.22, 1, 0.36, 1)
        var prev = -1.0
        var monotonic = true
        var line = ""
        for i in 0...10 {
            let x = Double(i) / 10
            let y = b.value(x)
            if y < prev - 1e-9 { monotonic = false }
            prev = y
            line += String(format: "%.3f ", y)
        }
        print("curve(0.22,1,0.36,1): \(line)")
        print("  starts at 0:      \(abs(b.value(0)) < 1e-6)")
        print("  ends at 1:        \(abs(b.value(1) - 1) < 1e-6)")
        print("  monotonic:        \(monotonic)")
        // Ease-out means most of the distance is covered early.
        print("  half-way at t=.3: \(String(format: "%.3f", b.value(0.3))) (ease-out if > 0.5)")

        // Duration schedule, mirroring MapRenderer.flyTo.
        func dur(pts: Double, dz: Double) -> Double {
            var d = 0.32 + min(pts / 1200.0, 1.0) * 0.20
            d += min(abs(dz) * 0.04, 0.12)
            return min(max(d, 0.32), 0.52)
        }
        print("duration schedule (ms):")
        for (pts, dz) in [(40.0, 0.0), (300.0, 0.5), (900.0, 1.5), (4000.0, 3.0)] {
            print(String(format: "  travel %5.0f pt, dzoom %.1f -> %3.0f ms", pts, dz, dur(pts: pts, dz: dz) * 1000))
        }
        // Confirm the bundled faces resolve by PostScript name. The wordmark
        // font also sits in the user's own Library, which would mask a failed
        // bundle copy on this machine but not on anyone else's.
        print("bundled fonts:")
        let bundled = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for u in bundled { print("  \(u.lastPathComponent)") }
        for name in ["RunyTunesRevisitedNF", "MartianMono-Regular", "IBMPlexMono-Regular"] {
            let f = CTFontCreateWithName(name as CFString, 20, nil)
            let resolved = CTFontCopyPostScriptName(f) as String
            print("  \(name) -> \(resolved)\(resolved == name ? "" : "   *** NOT RESOLVED ***")")
        }
        exit(0)
    }
}
#endif
