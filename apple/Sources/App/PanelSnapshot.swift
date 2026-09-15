//  PanelSnapshot.swift
//  Offscreen render of the panel chrome, for checking type scale and layout
//  without a screen-recording permission. Debug utility, macOS only.

#if os(macOS)
import SwiftUI
import AppKit

enum PanelSnapshot {
    @MainActor
    static func run(to path: String) {
        DS.snapshotMode = true
        let model = AppModel()
        model.seedInt = -647823732
        model.hover = SIMD2<Float>(988, -1053)
        model.hoverBiome = .blackForest
        model.hoverHeight = 45.8
        model.visibleTiles = 35
        model.queueDepth = 0
        model.composition = [
            (.meadows, 0.0336), (.blackForest, 0.1442), (.swamp, 0.0297),
            (.mountain, 0.0361), (.plains, 0.1489), (.mistlands, 0.1884),
            (.ashLands, 0.0950), (.deepNorth, 0.0629), (.ocean, 0.2613),
        ]

        model.enabledKinds = [0, 1, 2]
        model.siteCounts = [0: 1, 1: 27, 2: 30, 3: 710, 4: 543, 5: 551, 6: 368,
                            7: 568, 8: 789, 9: 1767, 10: 1325, 11: 540,
                            12: 2680, 13: 2201, 14: 63]
        model.sites = Array(repeating: Site(kind: .boss, label: "x", x: 0, y: 0, reachable: true),
                            count: 12163)
        var rep = SeedReport()
        rep.spawnAreaKm2 = 41.2; rep.largestKm2 = 41.2; rep.landmasses = 212
        rep.spawnIsLargest = true; rep.reachable = 3; rep.total = 8
        rep.sites = [
            Site(kind: .spawn, label: "Eikthyr", x: 2161, y: 1583, reachable: true),
            Site(kind: .boss, label: "The Elder", x: -1440, y: 2496, reachable: true),
            Site(kind: .trader, label: "Haldor", x: 3832, y: 3205, reachable: false),
            Site(kind: .boss, label: "Bonemass", x: -2366, y: 3904, reachable: true),
            Site(kind: .boss, label: "Moder", x: 5460, y: -1210, reachable: false),
            Site(kind: .boss, label: "Yagluth", x: -128, y: -3200, reachable: false),
        ]
        model.report = rep

        let mapPath = ProcessInfo.processInfo.environment["SNAPSHOT_MAP"] ?? ""
        let backdrop = NSImage(contentsOfFile: mapPath)

        let sheet = ZStack(alignment: .topLeading) {
            if let backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 760, height: 480)
                    .clipped()
            } else {
                Color(hex: 0x0B1A2A)
            }
            CornerWash()
            VStack(alignment: .leading, spacing: 10) {
                Wordmark()
                SeedPanel()
            }
            .padding(DS.panelInset)
        }
        .environmentObject(model)
        .preferredColorScheme(.dark)

        // ImageRenderer cannot host TextFields, Buttons or GeometryReader, so
        // the sheet goes into a real (offscreen) window and is captured from
        // its layer once AppKit has laid it out.
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))   // offscreen
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
            exit(0)
        }
    }
}
#endif
