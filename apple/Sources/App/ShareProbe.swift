//  ShareProbe.swift
//  Prints AppModel.shareURL for a stated view, so the link the app hands out
//  can be checked against the web build's own permalink format rather than
//  assumed to match it. Debug utility, macOS only.

#if os(macOS)
import Foundation
import simd
import Worldgen

@MainActor
enum ShareProbe {
    static func run(_ spec: String) {
        // seed,cx,cy,zoom,mode,palette
        let f = spec.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let model = AppModel()
        model.seedText = f.count > 0 ? f[0] : "j3QV2ftr3y"
        model.activeSeed = model.seedText

        var cam = MapCamera()
        if f.count > 2, let x = Float(f[1]), let y = Float(f[2]) { cam.cx = x; cam.cy = y }
        if f.count > 3, let z = Float(f[3]) { cam.zoom = z }
        // The only route to the model's private camera, and the one the app
        // itself uses every frame.
        model.updateCamera(cam, SIMD2(1200, 800))

        if f.count > 4, let m = Int32(f[4]), let v = Mode(rawValue: m) { model.mode = v }
        if f.count > 5, let p = Int32(f[5]), let v = Palette(rawValue: p) { model.palette = v }

        print(model.shareURL.absoluteString)
        exit(0)
    }
}
#endif
