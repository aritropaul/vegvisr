//  CameraTransit.swift
//  Driven interpolation of the map camera.
//
//  Clicking a site in the seed report used to set `renderer.camera` outright,
//  which teleports up to 10 km and snaps the zoom — you arrive with no idea
//  where you came from. The camera lives in MapRenderer rather than SwiftUI, so
//  `withAnimation` cannot reach it; this rides the same CADisplayLink the pan
//  momentum already uses.

import QuartzCore
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Evaluates a CSS-style cubic-bezier timing curve. SwiftUI's
/// `Animation.timingCurve` cannot be sampled by hand, and the map already
/// speaks in that curve (`DS.barFill` is `0.22, 1, 0.36, 1`), so reproducing it
/// here keeps one easing vocabulary rather than introducing a second.
struct UnitBezier {
    private let ax, bx, cx: Double
    private let ay, by, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1;  bx = 3 * (x2 - x1) - cx;  ax = 1 - cx - bx
        cy = 3 * y1;  by = 3 * (y2 - y1) - cy;  ay = 1 - cy - by
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    /// Newton-Raphson, falling back to bisection where the derivative is flat.
    func value(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let dx = sampleX(t) - x
            if abs(dx) < 1e-6 { return sampleY(t) }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let v = sampleX(t)
            if abs(v - x) < 1e-6 { return sampleY(t) }
            if x > v { lo = t } else { hi = t }
            t = (hi - lo) * 0.5 + lo
        }
        return sampleY(t)
    }
}

@MainActor
final class CameraTransit {
    private var link: CADisplayLink?
    private var from = MapCamera()
    private var to = MapCamera()
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private let curve = UnitBezier(0.22, 1, 0.36, 1)   // matches DS.barFill

    var onTick: ((MapCamera) -> Void)?
    var onFinish: (() -> Void)?
    #if os(macOS)
    weak var host: NSView?
    #endif

    var isRunning: Bool { link != nil }

    func begin(from a: MapCamera, to b: MapCamera, duration d: CFTimeInterval) {
        stop()
        guard d > 0.01 else { onTick?(b); onFinish?(); return }
        from = a; to = b
        start = CACurrentMediaTime()
        duration = d
        #if os(macOS)
        guard let host else { onTick?(b); onFinish?(); return }
        let l = host.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        #else
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        #endif
    }

    /// Any direct manipulation wins — a transit must never fight the pointer.
    func stop() {
        let wasRunning = link != nil
        link?.invalidate()
        link = nil
        if wasRunning { onFinish?() }
    }

    @objc private func tick() {
        let raw = min(max((CACurrentMediaTime() - start) / duration, 0), 1)
        let e = Float(curve.value(raw))
        var c = MapCamera()
        c.cx = from.cx + (to.cx - from.cx) * e
        c.cy = from.cy + (to.cy - from.cy) * e
        // zoom is already logarithmic, so a linear blend here is geometric in
        // metres — which is what reads as a smooth dolly rather than a lurch.
        c.zoom = from.zoom + (to.zoom - from.zoom) * e
        c.clampCentre()
        onTick?(c)
        if raw >= 1 { stop() }
    }
}
