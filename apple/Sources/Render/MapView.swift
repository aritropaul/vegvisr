//  MapView.swift
//  One MTKView subclass driven by native input on both platforms, wrapped once
//  for SwiftUI. Camera-driving gestures stay on AppKit/UIKit rather than
//  SwiftUI's gesture pipeline: a map needs the event to reach the render loop
//  without a view-graph round trip.

import SwiftUI
import MetalKit
import simd
import Worldgen

#if canImport(UIKit)
import UIKit
typealias PlatformViewRep = UIViewRepresentable
#else
import AppKit
typealias PlatformViewRep = NSViewRepresentable
#endif

/// Time-based inertia. Decay is evaluated as a closed-form function of elapsed
/// wall-clock time, not multiplied once per frame — a per-frame constant makes
/// the glide run twice as fast on a 120 Hz display as on a 60 Hz one.
@MainActor
final class Momentum {
    private var link: CADisplayLink?
    private var v0 = SIMD2<Double>(0, 0)
    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private let decay = 0.998            // UIScrollView .normal, per millisecond
    var onTick: ((SIMD2<Double>) -> Void)?
    #if os(macOS)
    weak var host: NSView?
    #endif

    func begin(velocity: SIMD2<Double>) {
        guard (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot() > 40 else { return }
        v0 = velocity
        start = CACurrentMediaTime()
        last = start
        stop()
        #if os(macOS)
        guard let host else { return }
        let l = host.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        #else
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        #endif
    }

    func stop() { link?.invalidate(); link = nil }

    private func delta(_ t1: CFTimeInterval, _ t2: CFTimeInterval) -> SIMD2<Double> {
        let k = 1000 * log(decay)
        let p1 = v0 * (pow(decay, 1000 * t1) - 1) / k
        let p2 = v0 * (pow(decay, 1000 * t2) - 1) / k
        return p2 - p1
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let d = delta(last - start, now - start)
        last = now
        onTick?(d)
        let speed = v0 * pow(decay, 1000 * (now - start))
        if (speed.x * speed.x + speed.y * speed.y).squareRoot() < 2 { stop() }
    }
}

final class MapMTKView: MTKView {
    var renderer: MapRenderer?
    var onHover: ((SIMD2<Float>?) -> Void)?
    var onTap: ((SIMD2<Float>) -> Void)?
    let momentum = Momentum()
    let transit = CameraTransit()
    private var zoomSettle: DispatchWorkItem?

    /// Tell the renderer a zoom is in flight, and schedule the release. The
    /// level is held for the whole gesture plus a short settle, so a flurry of
    /// wheel ticks re-tiles once at the end rather than at every step.
    private func markZooming() {
        renderer?.setZooming(true)
        zoomSettle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.renderer?.setZooming(false) }
        zoomSettle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
    }

    private var viewSizePts: SIMD2<Float> {
        SIMD2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1)))
    }

    private func pan(dx: Double, dy: Double) {
        guard var cam = renderer?.camera else { return }
        cam.cx -= Float(dx) / cam.scale
        cam.cy += Float(dy) / cam.scale
        cam.clampCentre()
        renderer?.camera = cam
    }

    private func setUpMomentum() {
        momentum.onTick = { [weak self] d in self?.pan(dx: d.x, dy: d.y) }
        transit.onTick = { [weak self] c in self?.renderer?.camera = c }
        transit.onFinish = { [weak self] in self?.renderer?.setZooming(false) }
        #if os(macOS)
        momentum.host = self
        transit.host = self
        #endif
    }

    /// Direct manipulation always wins over an in-flight transit.
    private func interrupt() {
        momentum.stop()
        transit.stop()
    }

    #if os(macOS)
    // AppKit's default is a bottom-left origin; flipping makes the view agree
    // with UIKit and with Metal texture space, so the shared camera math needs
    // no per-platform branch.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var tracking: NSTrackingArea?
    private var lastDrag: NSPoint?
    private var downAt: NSPoint?
    private var lastMoveTime: TimeInterval = 0
    private var velocity = SIMD2<Double>(0, 0)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        setUpMomentum()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let cam = renderer?.camera else { return }
        onHover?(cam.viewToWorld(Float(p.x), Float(p.y), viewSize: viewSizePts))
    }
    override func mouseExited(with e: NSEvent) { onHover?(nil) }

    override func mouseDown(with e: NSEvent) {
        interrupt()
        if e.clickCount == 2 {
            markZooming()
            let p = convert(e.locationInWindow, from: nil)
            var cam = renderer?.camera ?? MapCamera()
            cam.zoomBy(1.0, at: SIMD2(Float(p.x), Float(p.y)), viewSize: viewSizePts)
            renderer?.camera = cam
            return
        }
        lastDrag = convert(e.locationInWindow, from: nil)
        downAt = lastDrag
        velocity = .zero
        lastMoveTime = e.timestamp
    }

    override func mouseDragged(with e: NSEvent) {
        guard let last = lastDrag else { return }
        let cur = convert(e.locationInWindow, from: nil)
        let dx = Double(cur.x - last.x), dy = Double(cur.y - last.y)
        pan(dx: dx, dy: dy)
        let dt = max(e.timestamp - lastMoveTime, 1e-4)
        velocity = SIMD2(dx / dt, dy / dt)
        lastMoveTime = e.timestamp
        lastDrag = cur
    }

    override func mouseUp(with e: NSEvent) {
        let up = convert(e.locationInWindow, from: nil)
        // A click is a press that did not travel; anything further is a drag.
        if let d = downAt, hypot(up.x - d.x, up.y - d.y) < 4, e.clickCount == 1,
           let cam = renderer?.camera {
            onTap?(cam.viewToWorld(Float(up.x), Float(up.y), viewSize: viewSizePts))
        }
        lastDrag = nil
        downAt = nil
        if e.timestamp - lastMoveTime < 0.08 { momentum.begin(velocity: velocity) }
    }

    override func scrollWheel(with e: NSEvent) {
        interrupt()
        let p = convert(e.locationInWindow, from: nil)
        // macOS delivers trackpad pinch as scroll + ctrl.
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.control) {
            markZooming()
            var cam = renderer?.camera ?? MapCamera()
            cam.zoomBy(Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08),
                       at: SIMD2(Float(p.x), Float(p.y)), viewSize: viewSizePts)
            renderer?.camera = cam
            return
        }
        let k = e.hasPreciseScrollingDeltas ? 1.0 : 8.0
        pan(dx: Double(e.scrollingDeltaX) * k, dy: Double(e.scrollingDeltaY) * k)
    }

    override func magnify(with e: NSEvent) {
        interrupt()
        markZooming()
        let p = convert(e.locationInWindow, from: nil)
        var cam = renderer?.camera ?? MapCamera()
        cam.zoomBy(Float(e.magnification) * 2.2, at: SIMD2(Float(p.x), Float(p.y)),
                   viewSize: viewSizePts)
        renderer?.camera = cam
    }

    #else
    private var pinchAnchor = SIMD2<Float>(0, 0)
    private var zoomAtPinchStart: Float = 0

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        installGestures()
    }
    required init(coder: NSCoder) { super.init(coder: coder); installGestures() }

    private func installGestures() {
        setUpMomentum()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        pan.allowedScrollTypesMask = [.continuous]   // iPad trackpad two-finger scroll
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch))
        let dbl = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        dbl.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(onSingleTap))
        single.numberOfTapsRequired = 1
        single.require(toFail: dbl)
        single.delegate = self
        addGestureRecognizer(single)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHoverGesture))
        for g in [pan, pinch, dbl, hover] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        isMultipleTouchEnabled = true
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: interrupt()
        case .changed:
            let t = g.translation(in: self)
            pan(dx: Double(t.x), dy: Double(t.y))
            g.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            let v = g.velocity(in: self)
            momentum.begin(velocity: SIMD2(Double(v.x), Double(v.y)))
        default: break
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let p = g.location(in: self)
        if g.state == .began {
            pinchAnchor = SIMD2(Float(p.x), Float(p.y))
            zoomAtPinchStart = renderer?.camera.zoom ?? 0
            interrupt()
        }
        guard g.state == .changed || g.state == .began else { return }
        markZooming()
        var cam = renderer?.camera ?? MapCamera()
        let target = zoomAtPinchStart + log2(Float(max(g.scale, 0.01)))
        cam.zoomBy(target - cam.zoom, at: pinchAnchor, viewSize: viewSizePts)
        renderer?.camera = cam
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        markZooming()
        let p = g.location(in: self)
        var cam = renderer?.camera ?? MapCamera()
        cam.zoomBy(1.0, at: SIMD2(Float(p.x), Float(p.y)), viewSize: viewSizePts)
        renderer?.camera = cam
    }

    @objc private func onSingleTap(_ g: UITapGestureRecognizer) {
        guard let cam = renderer?.camera else { return }
        let p = g.location(in: self)
        onTap?(cam.viewToWorld(Float(p.x), Float(p.y), viewSize: viewSizePts))
    }

    @objc private func onHoverGesture(_ g: UIHoverGestureRecognizer) {
        guard let cam = renderer?.camera else { return }
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            onHover?(cam.viewToWorld(Float(p.x), Float(p.y), viewSize: viewSizePts))
        default: onHover?(nil)
        }
    }
    #endif
}

#if os(iOS)
extension MapMTKView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ a: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
}
#endif

/// SwiftUI bridge. One implementation, both platforms.
struct MetalMapView: PlatformViewRep {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MapRenderer?
    }

    private func build(context: Context) -> MapMTKView {
        let v = MapMTKView(frame: .zero, device: nil)
        guard let r = MapRenderer(view: v) else { return v }
        v.renderer = r
        v.delegate = r
        context.coordinator.renderer = r
        model.attach(renderer: r)
        v.onHover = { [weak model] w in
            Task { @MainActor in model?.hover = w }
        }
        v.onTap = { [weak model] w in
            Task { @MainActor in model?.tap(at: w) }
        }
        r.flyHandler = { [weak v, weak r] from, to, d in
            guard let v else { return }
            // A transit sweeps the zoom continuously; hold the level for its
            // duration so it does not re-tile on the way.
            if abs(to.zoom - from.zoom) > 0.05 { r?.setZooming(true) }
            v.transit.begin(from: from, to: to, duration: d)
        }
        r.onCamera = { [weak model] cam, viewPts in
            Task { @MainActor in model?.updateCamera(cam, viewPts) }
        }
        return v
    }

    private func sync(_ v: MapMTKView) {
        guard let r = v.renderer else { return }
        r.setMode(model.mode)
        r.setPalette(model.palette)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> MapMTKView { build(context: context) }
    func updateNSView(_ v: MapMTKView, context: Context) { sync(v) }
    #else
    func makeUIView(context: Context) -> MapMTKView { build(context: context) }
    func updateUIView(_ v: MapMTKView, context: Context) { sync(v) }
    #endif
}
