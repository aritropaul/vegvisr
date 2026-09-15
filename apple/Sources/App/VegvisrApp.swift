//  VegvisrApp.swift
//  App shell. One scene, one model; the chrome adapts per platform while the
//  map and every panel body are shared.

import SwiftUI
import Worldgen

@main
struct VegvisrApp: App {
    @StateObject private var model = AppModel()

    init() {
        // `Vegvisr --snapshot <path>` renders the chrome offscreen and exits.
        // Used to check type scale and layout without a screen-capture grant;
        // note Liquid Glass is a compositor material and will not appear here.
        #if os(macOS)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            PanelSnapshot.run(to: args[i + 1])
        }
        if let i = args.firstIndex(of: "--markers"), i + 1 < args.count {
            MarkerProbe.run(to: args[i + 1])
        }
        if args.contains("--curve") { CurveProbe.run() }
        if let i = args.firstIndex(of: "--sharelink"), i + 1 < args.count {
            MainActor.assumeIsolated { ShareProbe.run(args[i + 1]) }
        }
        if let i = args.firstIndex(of: "--lodshot"), i + 2 < args.count {
            LodProbe.run(to: args[i + 1], seed: args[i + 2])
        }
        if let i = args.firstIndex(of: "--mapshot"), i + 2 < args.count {
            MapShot.run(to: args[i + 1], span: Float(args[i + 2]) ?? 6000, seed: "j3QV2ftr3y")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                // Both the vegvisr:// scheme and, once the app is signed for
                // associated domains, https links to the site itself.
                .onOpenURL { model.open($0) }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var seedText = "j3QV2ftr3y"
    @Published var activeSeed = "j3QV2ftr3y"
    @Published var seedInt: Int32 = 0
    @Published var genVersion: Int32 = 2
    @Published var mode: Mode = .biome
    @Published var palette: Palette = .classic
    @Published var booting = true
    @Published var bootProgress: Double = 0.12
    @Published var bootText = "BUILDING WORLD"
    @Published var hover: SIMD2<Float>?
    @Published var hoverBiome: Biome = .none
    @Published var hoverHeight: Float = 0
    @Published var visibleTiles = 0
    @Published var queueDepth = 0
    @Published var composition: [(Biome, Double)] = []
    @Published var workers = CoreTopology.workerCount()
    @Published var enabledKinds: Set<UInt8> = Set(POI_KINDS.filter(\.defaultOn).map(\.id))
    @Published var sites: [Site] = []
    @Published var siteCounts: [UInt8: Int] = [:]
    @Published var placementProgress: Double = 0
    @Published var placing = false
    @Published var report: SeedReport?
    @Published var hoveredSite: Site?
    @Published var selectedSite: Site?
    /// World metres per screen point, published so hit radius stays constant
    /// on screen as the camera zooms.
    @Published var metresPerPoint: Float = 1
    @Published var tooltipPoint: CGPoint?
    private var cam = MapCamera()
    private var viewPts = SIMD2<Float>(1, 1)

    private weak var renderer: MapRenderer?
    private var probe: WorldGenerator?
    private var hoverTask: Task<Void, Never>?
    private var placementTask: Task<Void, Never>?
    /// Bumped on every generate() so a slow placement pass from a previous
    /// seed cannot publish its sites over the current one.
    private var generation = 0
    private var markerIndex = MarkerIndex()
    private var lastMarkerZoom: Float = .nan
    private var didFit = false

    /// What the app reopens on. Mode and palette are part of a tile's identity,
    /// so restoring the seed without them would preload a set of tiles the
    /// first frame then ignores.
    private enum Remembered {
        static let seed = "session.seed"
        static let mode = "session.mode"
        static let palette = "session.palette"
    }

    init() {
        let d = UserDefaults.standard
        if let last = d.string(forKey: Remembered.seed)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            seedText = last
            activeSeed = last
        }
        // Absent keys read as 0, which is .biome and .classic — the defaults
        // these properties already carry.
        if let m = Mode(rawValue: Int32(d.integer(forKey: Remembered.mode))) { mode = m }
        if let p = Palette(rawValue: Int32(d.integer(forKey: Remembered.palette))) { palette = p }
        seedInt = seedFromName(activeSeed)
    }

    private func remember() {
        let d = UserDefaults.standard
        d.set(activeSeed, forKey: Remembered.seed)
        d.set(Int(mode.rawValue), forKey: Remembered.mode)
        d.set(Int(palette.rawValue), forKey: Remembered.palette)
    }

    func attach(renderer r: MapRenderer) {
        guard renderer !== r else { return }
        renderer = r
        r.onStats = { [weak self] visible, depth in
            Task { @MainActor in self?.visibleTiles = visible; self?.queueDepth = depth }
        }
        // Start pulling last session's tiles off disk now, so the reads happen
        // while the generator builds rather than after it.
        r.setMode(mode)
        r.setPalette(palette)
        r.preload(seed: seedInt, gen: genVersion, mode: mode, palette: palette)
        generate()
    }

    func generate() {
        let name = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSeed = name
        seedInt = seedFromName(name)
        remember()
        booting = true
        bootProgress = 0.12
        bootText = "BUILDING WORLD · \(workers) WORKERS"
        renderer?.clearForNewSeed(seed: seedInt, gen: genVersion)

        // Markers from the previous seed must not survive into this one, even
        // for the seconds before placement finishes.
        placementTask?.cancel()
        generation += 1
        sites = []
        siteCounts = [:]
        report = nil
        placementProgress = 0
        renderer?.setMarkers([])
        didFit = false

        let gen = genVersion
        Task.detached(priority: .userInitiated) {
            // A probe generator for point queries and the composition chart —
            // separate from the render pool so hovering never waits on a tile.
            let wg = WorldGenerator(seedName: name, worldGenVersion: gen)
            await MainActor.run { [weak self] in
                self?.bootProgress = 0.46
                // Hand the finished generator to the render pool; all workers
                // share this one instance.
                self?.renderer?.setWorld(wg, name: name, gen: gen)
            }
            let comp = Self.composition(of: wg)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.probe = wg
                self.composition = comp
                self.bootProgress = 1.0
                self.bootText = "READY"
                withAnimation(DS.bootFade) { self.booting = false }
                self.startPlacement(wg)
            }
        }
    }

    /// Location placement is ~7 s of rejection sampling across 183 types and
    /// cannot be parallelised — one shared occupancy map, prioritised types
    /// first. So it runs incrementally and publishes what is final so far:
    /// once a type has been processed its placements cannot change.
    private func startPlacement(_ wg: WorldGenerator) {
        let mine = generation
        placing = true
        placementTask = Task.detached(priority: .utility) {
            let st = beginLocations()
            var landmass: Landmass?
            while !Task.isCancelled {
                let done = stepLocations(wg, st, 8)
                let snapshot = st.placed
                let progress = Double(st.progress)
                if done && landmass == nil { landmass = buildLandmass(wg) }
                let lm = landmass
                let sites = snapshot.map { p -> Site in
                    let c = LOCATIONS[p.cfg]
                    let reach = lm.map { $0.nearestLand(p.x, p.y, 6) == $0.spawn } ?? false
                    return Site(kind: c.kind, label: c.label, x: p.x, y: p.y, reachable: reach)
                }
                let rep = done ? Self.buildReport(sites: sites, lm: lm) : nil
                await MainActor.run { [weak self] in
                    guard let self, self.generation == mine else { return }
                    self.sites = sites
                    self.placementProgress = progress
                    var counts: [UInt8: Int] = [:]
                    for s in sites { counts[s.kind.rawValue, default: 0] += 1 }
                    self.siteCounts = counts
                    if let rep { withAnimation(DS.swapIn) { self.report = rep } }
                    self.placing = !done
                    self.pushMarkers()
                }
                if done { break }
            }
        }
    }

    nonisolated static func buildReport(sites: [Site], lm: Landmass?) -> SeedReport {
        var r = SeedReport()
        guard let lm else { return r }
        r.spawnAreaKm2 = lm.areaKm2(lm.spawn)
        r.largestKm2 = (lm.sizes.indices.map { lm.areaKm2(Int32($0)) }.max()) ?? 0
        r.landmasses = lm.sizes.count
        r.spawnIsLargest = abs(r.spawnAreaKm2 - r.largestKm2) < 0.01
        // One row per distinct boss/trader name: prefer an instance on the
        // spawn landmass, then the nearest.
        var best: [String: Site] = [:]
        for s in sites where s.kind == .boss || s.kind == .trader {
            if let cur = best[s.label] {
                let better = (s.reachable && !cur.reachable)
                    || (s.reachable == cur.reachable && s.dist < cur.dist)
                if better { best[s.label] = s }
            } else {
                best[s.label] = s
            }
        }
        r.sites = best.values.sorted { $0.dist < $1.dist }
        r.total = r.sites.count
        r.reachable = r.sites.filter(\.reachable).count
        return r
    }

    func toggleKind(_ id: UInt8) {
        if enabledKinds.contains(id) { enabledKinds.remove(id) } else { enabledKinds.insert(id) }
        pushMarkers()
    }

    private func pushMarkers() {
        let visibleSites = sites.filter { enabledKinds.contains($0.kind.rawValue) }
        markerIndex = MarkerIndex(visibleSites)
        if let h = hoveredSite, !visibleSites.contains(h) { hoveredSite = nil }
        if let s = selectedSite, !visibleSites.contains(s) { selectedSite = nil }

        let hot = hoveredSite
        let sel = selectedSite
        var byKind: [UInt8: [MarkerInstance]] = [:]
        for s in visibleSites {
            let emphasised = s == hot || s == sel
            let side = markerSide(s.kind) * (emphasised ? 1.4 : 1.0)
            byKind[s.kind.rawValue, default: []]
                .append(MarkerInstance(world: SIMD2(s.x, s.y), sizePx: side))
        }
        renderer?.setMarkers(POI_KINDS.compactMap { cat in
            guard let inst = byKind[cat.id], !inst.isEmpty else { return nil }
            return MarkerBatch(glyph: cat.glyph, colour: cat.rgba, instances: inst)
        })
    }

    /// Symbol size in points, scaled with zoom and clamped to 6...16 so markers
    /// stay legible close in without swallowing the islands at world view.
    private func markerSide(_ k: Kind) -> Float {
        let t = min(max((cam.zoom + 1) / 6.0, 0), 1)          // zoom -1...5
        var d = 6 + t * 10                                     // 6...16 px across
        switch k {
        case .spawn, .boss: d *= 1.15
        case .trader: d *= 1.05
        default: break
        }
        // The glyph texture reserves room for the spawn crosshair, so the quad
        // is wider than the symbol it contains.
        return min(max(d, 6), 16) * 1.6
    }

    /// The camera as the share/link code sees it. `cam` is private to the
    /// model; this keeps it that way rather than widening it for one feature.
    var shareCamera: MapCamera { cam }

    /// Jump to a camera and suppress the automatic opening fit, which would
    /// otherwise replace a shared position with the whole world.
    func pinCamera(_ c: MapCamera) {
        didFit = true
        renderer?.camera = c
    }

    func updateCamera(_ c: MapCamera, _ v: SIMD2<Float>) {
        cam = c
        viewPts = v
        metresPerPoint = 1 / c.scale
        refreshTooltipPoint()
        if abs(c.zoom - lastMarkerZoom) > 0.12 {
            lastMarkerZoom = c.zoom
            pushMarkers()
        }
        if !didFit { didFit = true; fit(animated: false) }
    }

    private func refreshTooltipPoint() {
        guard let s = hoveredSite else { tooltipPoint = nil; return }
        let p = cam.worldToView(s.x, s.y, viewSize: viewPts)
        // Drop the tooltip if the marker has left the viewport.
        guard p.x > -40, p.y > -40, p.x < viewPts.x + 40, p.y < viewPts.y + 40 else {
            tooltipPoint = nil
            return
        }
        tooltipPoint = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    /// A click on the map: select a marker if one is under the pointer.
    func tap(at w: SIMD2<Float>) {
        let hit = markerIndex.hit(w.x, w.y, radius: 13 * metresPerPoint)
        selectedSite = hit
        pushMarkers()
        if let hit { centreOn(hit.x, hit.y) }
    }

    func centreOn(_ x: Float, _ y: Float) {
        guard let r = renderer else { return }
        var target = r.camera
        target.cx = x; target.cy = y
        target.zoom = max(target.zoom, 3.0)
        target.clampCentre()
        r.flyTo(target)
    }

    /// Biome share over the playable disc, sampled on a 96x96 lattice.
    nonisolated static func composition(of wg: WorldGenerator) -> [(Biome, Double)] {
        var counts = [Int](repeating: 0, count: 10)
        let n = 96
        var total = 0
        for j in 0..<n {
            for i in 0..<n {
                let fx: Double = -10000.0 + (Double(i) + 0.5) * 20000.0 / Double(n)
                let fy: Double = 10000.0 - (Double(j) + 0.5) * 20000.0 / Double(n)
                let x = Float(fx)
                let y = Float(fy)
                if length(x, y) > 10000.0 { continue }
                counts[Int(ordOfBiome(wg.biome(x, y)))] += 1
                total += 1
            }
        }
        let denom = Double(max(total, 1))
        var out: [(Biome, Double)] = []
        for b in BIOME_ORDER {
            let c = counts[Int(ordOfBiome(b))]
            out.append((b, Double(c) / denom))
        }
        return out
    }

    /// Point query, debounced onto a background task so pointer movement never
    /// blocks the main thread on a height sample.
    func updateHoverReadout() {
        hoverTask?.cancel()
        guard let w = hover, let wg = probe else {
            if hoveredSite != nil { hoveredSite = nil; pushMarkers() }
            return
        }
        // 11 screen points, converted to world metres so the grab area stays
        // the same size on screen at every zoom.
        let hit = markerIndex.hit(w.x, w.y, radius: 11 * metresPerPoint)
        if hit != hoveredSite {
            hoveredSite = hit
            refreshTooltipPoint()
            pushMarkers()
        }
        hoverTask = Task.detached(priority: .utility) {
            let (b, h) = wg.sample(w.x, w.y)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.hoverBiome = b
                self?.hoverHeight = h
            }
        }
    }

    /// Zoom 0 renders the world at exactly one tile across — 256 pt — which
    /// left it as a postage stamp in the middle of the window. Solve for the
    /// zoom that actually fills the shorter viewport axis instead.
    /// `animated` is false for the one-time fit on first layout — animating the
    /// opening frame is a slow reveal, not a bridge from anywhere.
    func fit(animated: Bool = true) {
        guard let r = renderer else { return }
        let side = min(viewPts.x, viewPts.y)
        guard side > 1 else { return }
        var target = r.camera
        target.cx = 0; target.cy = 0
        target.zoom = log2(side * 0.94 / Float(TILE_PX))
        if animated { r.flyTo(target) } else { r.camera = target }
    }

    func setMode(_ m: Mode) { mode = m; renderer?.setMode(m); remember() }
    func setPalette(_ p: Palette) { palette = p; renderer?.setPalette(p); remember() }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()
            MetalMapView(model: model).ignoresSafeArea()
            Vignette().allowsHitTesting(false)
            CornerWash()

            #if os(macOS)
            MacChrome()
            #else
            PhoneChrome()
            #endif

            // Tooltip sits above the map but below the panels and boot screen.
            if let s = model.hoveredSite, let p = model.tooltipPoint {
                GeometryReader { geo in
                    MarkerTooltip(site: s, at: p, bounds: geo.size)
                }
                .allowsHitTesting(false)
            }

            if model.booting { BootOverlay() }
        }
        .background(DS.bg)
        .onChange(of: model.hover) { _, _ in model.updateHoverReadout() }
    }
}

/// Radial darkening at the screen edges, matching the web build's .vignette.
struct Vignette: View {
    var body: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.42)],
                center: .center,
                startRadius: min(geo.size.width, geo.size.height) * 0.35,
                endRadius: max(geo.size.width, geo.size.height) * 0.75
            )
        }
        .ignoresSafeArea()
    }
}

#if os(macOS)
/// Fixed corner panels, as on the web.
struct MacChrome: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Wordmark()
                    SeedPanel()
                    ReportPanel()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) { RenderPanel(); MarkersPanel() }
            }
            .padding(DS.panelInset)
            VStack { Spacer(); HStack(alignment: .bottom) {
                CompositionPanel(); Spacer(); TelemetryPanel()
            } }
            .padding(DS.panelInset)
        }
    }
}
#else
/// iPhone has no room for corner panels; the same content stacks into a sheet
/// over the map rather than being cut down.
struct PhoneChrome: View {
    @EnvironmentObject var model: AppModel
    @State private var showControls = false

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) { Wordmark(); SeedPanel() }
                Spacer()
                Button { showControls.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.ink)
                        .frame(width: 34, height: 34)
                        .panelChrome()
                }.buttonStyle(.plain)
            }
            Spacer()
            TelemetryPanel()
        }
        .padding(DS.panelInset)
        .sheet(isPresented: $showControls) {
            ScrollView {
                VStack(spacing: 12) {
                    RenderPanel(); MarkersPanel(); ReportPanel(); CompositionPanel()
                }
                    .padding(DS.panelInset)
            }
            .background(DS.bg)
            .presentationDetents([.medium, .large])
            .presentationBackground(DS.bg)
        }
    }
}
#endif

// MARK: - Sharing

/// Where a shared link points, and the domain the app claims for Universal
/// Links. One constant so the two can never disagree.
let SHARE_HOST = "vegvisr.vercel.app"

extension AppModel {
    /// The default marker set as the bitmask the link format uses.
    static var defaultMarkerMask: UInt32 {
        POI_KINDS.filter(\.defaultOn).reduce(UInt32(0)) { $0 | (1 << UInt32($1.id)) }
    }

    /// The current view as a link.
    ///
    /// Deliberately an https link to the web build rather than a `vegvisr://`
    /// one. A share has to work for whoever receives it, and most recipients
    /// will not have the app — the site shows the same map, and opens the app
    /// for the people who do have it. A custom scheme in a message is a dead
    /// link for everyone else.
    ///
    /// Parameter names are the web's own permalink format, verbatim, so a
    /// single link is read by both front ends and by links already in the
    /// wild. Defaults are omitted for the same reason the web omits them: a
    /// link someone pastes into a forum post should not wrap.
    var shareURL: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = SHARE_HOST
        c.path = "/"
        var q = [URLQueryItem(name: "seed", value: activeSeed)]
        let cam = shareCamera
        if cam.cx != 0 || cam.cy != 0 {
            q.append(.init(name: "at",
                           value: "\(Int(cam.cx.rounded())),\(Int(cam.cy.rounded()))"))
        }
        if cam.zoom != 0 {
            q.append(.init(name: "z", value: String(format: "%.2f", cam.zoom)))
        }
        if mode != .biome { q.append(.init(name: "m", value: "\(mode.rawValue)")) }
        if palette != .classic { q.append(.init(name: "p", value: "\(palette.rawValue)")) }
        let mask = enabledKinds.reduce(UInt32(0)) { $0 | (1 << UInt32($1)) }
        if mask != Self.defaultMarkerMask {
            q.append(.init(name: "k", value: String(mask, radix: 36)))
        }
        if genVersion != 2 { q.append(.init(name: "wgv", value: "\(genVersion)")) }
        c.queryItems = q
        return c.url!
    }

    /// Open a shared link.
    ///
    /// Accepts the https form and the `vegvisr://` scheme alike. The scheme
    /// exists because Universal Links need a signed app with an
    /// associated-domains entitlement; until then it is the only thing that
    /// can hand a link to the app, and afterwards it costs nothing to keep.
    /// Unknown and malformed parameters are ignored rather than rejected, so
    /// a link written by a newer build still opens something sensible.
    func open(_ url: URL) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let g = value("wgv"), let v = Int32(g), v > 0 { genVersion = v }

        // Markers and render settings before generate(), so the first frame
        // after the world lands is already the shared view.
        if let k = value("k"), let mask = UInt32(k, radix: 36) {
            enabledKinds = Set(POI_KINDS.map(\.id).filter { mask & (1 << UInt32($0)) != 0 })
        }
        if let m = value("m"), let v = Int32(m), let parsed = Mode(rawValue: v) { setMode(parsed) }
        if let p = value("p"), let v = Int32(p), let parsed = Palette(rawValue: v) {
            setPalette(parsed)
        }

        let seed = value("seed")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seed, !seed.isEmpty, seed != activeSeed {
            seedText = seed
            generate()
        }

        // Camera last. generate() clears the did-fit flag, and the first frame
        // would otherwise fit the whole world over the position in the link.
        var target = shareCamera
        var moved = false
        if let at = value("at") {
            let parts = at.split(separator: ",").compactMap { Float($0) }
            if parts.count == 2 { target.cx = parts[0]; target.cy = parts[1]; moved = true }
        }
        if let z = value("z"), let v = Float(z) { target.zoom = v; moved = true }
        if moved {
            target.clampCentre()
            pinCamera(target)
        }
    }
}
