//  Panels.swift
//  The instrument-panel chrome: Liquid Glass plates with hairline borders,
//  corner registration ticks, and a collapsible body.

import SwiftUI
import Worldgen

// MARK: - Chrome

/// The `.panel::before/::after` decoration: a 5pt bracket at two opposite
/// corners, stroked on two sides each. No SwiftUI pseudo-element exists, so it
/// is drawn as a Shape. Inset slightly so the arms sit on the straight part of
/// the plate's edge rather than fighting the corner curve.
struct CornerTicks: Shape {
    var inset: CGFloat = 0
    func path(in r: CGRect) -> Path {
        var p = Path()
        let s = DS.tickSize
        let x0 = r.minX + inset, y0 = r.minY + inset
        let x1 = r.maxX - inset, y1 = r.maxY - inset
        p.move(to: CGPoint(x: x0, y: y0 + s));  p.addLine(to: CGPoint(x: x0, y: y0))
        p.addLine(to: CGPoint(x: x0 + s, y: y0))
        p.move(to: CGPoint(x: x1, y: y1 - s));  p.addLine(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x1 - s, y: y1))
        return p
    }
}

/// Liquid Glass where the OS has it, the old blurred plate where it doesn't.
/// The dark tint is kept in both paths: an untinted glass plate over a
/// near-black map washes the panel out and loses the instrument look.
struct PanelChrome: ViewModifier {
    var radius: CGFloat = DS.panelRadius

    func body(content: Content) -> some View {
        // Square corners: this is an instrument panel, not a card.
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(macOS 26.0, iOS 26.0, *), !DS.snapshotMode {
                content
                    .glassEffect(.regular.tint(DS.panelTint).interactive(), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .background(DS.panel, in: shape)
            }
        }
        .overlay(shape.stroke(DS.line, lineWidth: DS.hairline))
        .overlay(CornerTicks().stroke(DS.tick, lineWidth: 1))
    }
}

extension View {
    func panelChrome(radius: CGFloat = DS.panelRadius) -> some View {
        modifier(PanelChrome(radius: radius))
    }
}

/// Collapsible instrument plate. Open state persists per panel.
struct Panel<Content: View>: View {
    let id: String
    let title: String
    var trailing: String = ""
    @ViewBuilder var content: Content

    @AppStorage private var open: Bool

    init(id: String, title: String, trailing: String = "",
         @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.trailing = trailing
        self.content = content()
        _open = AppStorage(wrappedValue: true, "panel.\(id).open")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DS.inkDim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title)
                        .font(DS.phead.font).tracking(DS.phead.tracking)
                        .foregroundStyle(DS.inkDim)
                    Spacer(minLength: 12)
                    if !trailing.isEmpty {
                        Text(trailing)
                            .font(DS.phead.font).tracking(DS.phead.tracking)
                            .foregroundStyle(DS.noteInk)
                    }
                }
                .padding(.bottom, 6)
                // Without this the header only responds where a glyph is drawn.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            #endif

            if open {
                Rectangle().fill(DS.line).frame(height: 1)
                content.padding(.top, 7)
            }
        }
        .padding(DS.panelPad)
        .frame(width: DS.panelWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panelChrome()
    }
}

// MARK: - Controls

/// Segmented control. Every cell is hit-testable across its whole rectangle —
/// an inactive cell's fill is `.clear`, and SwiftUI will not hit-test a clear
/// background without an explicit content shape.
struct Seg<T: Equatable>: View {
    let options: [(String, T)]
    let current: T
    var onPick: (T) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = current == opt.1
                Button { onPick(opt.1) } label: {
                    Text(opt.0)
                        .font(DS.seg.font).tracking(DS.seg.tracking)
                        .lineLimit(1)
                        .padding(.vertical, 6).padding(.horizontal, 7)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(active ? DS.bg : DS.inkDim)
                        .background(active ? DS.ink : Color.white.opacity(0.001))
                        .contentShape(Rectangle())
                }
                .pressable()
                .overlay(Rectangle().stroke(active ? DS.ink : DS.line, lineWidth: 1))
                .animation(DS.quick, value: active)
                #if os(macOS)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                #endif
            }
        }
    }
}

/// Flat action button with a full-rectangle hit area.
struct FlatButton: View {
    let title: String
    var tint: Color = DS.inkDim
    var border: Color = DS.line
    var fill: Color = Color.white.opacity(0.001)
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.seg.font).tracking(DS.seg.tracking)
                .foregroundStyle(tint)
                .padding(.vertical, 6).padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .background(fill)
                .contentShape(Rectangle())
        }
        .pressable()
        .overlay(Rectangle().stroke(border, lineWidth: 1))
        #if os(macOS)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}

/// Shares the current view as a link.
///
/// Styled by hand rather than wrapped around FlatButton because ShareLink
/// brings its own Button, and nesting one inside another swallows the tap on
/// macOS.
struct ShareButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ShareLink(item: model.shareURL) {
            Text("SHARE")
                .font(DS.seg.font).tracking(DS.seg.tracking)
                .foregroundStyle(DS.inkDim)
                .padding(.vertical, 6).padding(.horizontal, 11)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().stroke(DS.line, lineWidth: 1))
        #if os(macOS)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}

struct KV: View {
    let k: String
    let v: String
    var big = false
    var dim = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(k).font(DS.kvKey.font).tracking(DS.kvKey.tracking)
                .foregroundStyle(DS.inkDim)
            Spacer(minLength: 0)
            Text(v)
                .font(big ? DS.kvBig.font : (dim ? DS.kvDim.font : DS.kvVal.font))
                .tracking(big ? DS.kvBig.tracking : (dim ? DS.kvDim.tracking : DS.kvVal.tracking))
                .monospacedDigit()
                .foregroundStyle(dim ? DS.inkDim : DS.ink)
        }
        .padding(.vertical, 0.5)
    }
}

// MARK: - Panels

struct SeedPanel: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        Panel(id: "seed", title: "TERRAIN SCOPE", trailing: "v\(model.genVersion)") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    TextField("", text: $model.seedText)
                        .textFieldStyle(.plain)
                        .font(DS.seedInput.font).tracking(DS.seedInput.tracking)
                        .foregroundStyle(DS.ink)
                        .focused($focused)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).padding(.horizontal, 7)
                        .background(DS.seedField)
                        .overlay(Rectangle().stroke(focused ? DS.amber : DS.line, lineWidth: 1))
                        .onSubmit { model.generate() }
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif

                    FlatButton(title: "RUN", tint: DS.amber, border: DS.amber,
                               fill: DS.amber.opacity(0.13)) { model.generate() }
                        .fixedSize()
                }
                KV(k: "HASH", v: "\(model.seedInt)", dim: true)
            }
        }
    }
}

struct RenderPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(id: "render", title: "RENDER") {
            VStack(spacing: 5) {
                Seg(options: [("BIOME", Mode.biome), ("TERRAIN", Mode.terrain)],
                    current: model.mode) { model.setMode($0) }
                Seg(options: [("STD", Palette.classic), ("A11Y", Palette.accessible)],
                    current: model.palette) { model.setPalette($0) }
                HStack(spacing: 5) {
                    FlatButton(title: "FIT") { model.fit() }
                    ShareButton()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TelemetryPanel: View {
    @EnvironmentObject var model: AppModel

    private var pos: String {
        guard let h = model.hover else { return "—" }
        return "\(Int(h.x)), \(Int(h.y))"
    }
    private var dist: String {
        guard let h = model.hover else { return "—" }
        return "\(Int(length(h.x, h.y))) m"
    }

    var body: some View {
        Panel(id: "telemetry", title: "TELEMETRY") {
            VStack(spacing: 1) {
                KV(k: "POS", v: pos, big: true)
                KV(k: "BIOME", v: model.hover == nil ? "—" : model.hoverBiome.label, big: true)
                KV(k: "ALT", v: model.hover == nil ? "—" : String(format: "%.1f m", model.hoverHeight), big: true)
                KV(k: "DIST", v: dist, big: true)

                if let s = model.hoveredSite ?? model.selectedSite {
                    HStack(spacing: 6) {
                        Text(s.label)
                            .font(DS.site.font).tracking(DS.site.tracking)
                            .foregroundStyle(DS.amber)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(Int(s.dist)) m")
                            .font(DS.site.font).monospacedDigit()
                            .foregroundStyle(DS.amber.opacity(0.75))
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.amber.opacity(0.09))
                    .overlay(Rectangle().stroke(DS.amber.opacity(0.4), lineWidth: 1))
                    .padding(.top, 5)
                }

                Rectangle().fill(DS.line).frame(height: 1).padding(.vertical, 5)
                KV(k: "TILES", v: "\(model.visibleTiles)", dim: true)
                KV(k: "QUEUE", v: "\(model.queueDepth)", dim: true)
                KV(k: "WORKERS", v: "\(model.workers)", dim: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CompositionPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(id: "composition", title: "SURFACE COMPOSITION", trailing: "WORLD") {
            VStack(spacing: 3) {
                ForEach(BIOME_ORDER, id: \.rawValue) { b in
                    let pct = model.composition.first { $0.0 == b }?.1 ?? 0
                    HStack(spacing: 7) {
                        Text(b.label)
                            .font(DS.barName.font).tracking(DS.barName.tracking)
                            .foregroundStyle(DS.inkDim)
                            .frame(width: 74, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(DS.trackBg)
                                Rectangle().fill(Swatch.of(b, model.palette))
                                    .frame(width: geo.size.width * pct)
                                    .animation(DS.barFill, value: pct)
                            }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.1f%%", pct * 100))
                            .font(DS.barVal.font).tracking(DS.barVal.tracking)
                            .monospacedDigit()
                            .foregroundStyle(DS.ink)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BootOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            DS.bg.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(DS.bootBar)
                    Rectangle().fill(DS.amber)
                        .frame(width: 190 * model.bootProgress)
                        .shadow(color: DS.amber, radius: 4.5)
                }
                .frame(width: 190, height: 2)
                .animation(.easeInOut(duration: 0.26), value: model.bootProgress)

                Text(model.bootText)
                    .font(DS.bootText.font).tracking(DS.bootText.tracking)
                    .foregroundStyle(DS.inkDim)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Markers

struct MarkersPanel: View {
    @EnvironmentObject var model: AppModel

    private var total: Int { model.sites.count }

    var body: some View {
        Panel(id: "markers", title: "MARKERS",
              trailing: model.placing
                  ? "\(Int(model.placementProgress * 100))%"
                  : (total > 0 ? "\(total)" : "")) {
            VStack(spacing: 0) {
                ForEach(POI_KINDS) { cat in
                    let on = model.enabledKinds.contains(cat.id)
                    Button { model.toggleKind(cat.id) } label: {
                        HStack(spacing: 7) {
                            // Unfilled swatch that lights up and glows when on,
                            // mirroring the web build's .mk element.
                            Rectangle()
                                .stroke(cat.color, lineWidth: 1)
                                .frame(width: 11, height: 11)
                                .opacity(on ? 1 : 0.35)
                                .shadow(color: on ? cat.color : .clear, radius: 3.5)
                            Text(cat.name)
                                .font(DS.poiLabel.font).tracking(DS.poiLabel.tracking)
                                .foregroundStyle(on ? DS.ink : DS.inkDim)
                            Spacer(minLength: 6)
                            Text("\(model.siteCounts[cat.id] ?? 0)")
                                .font(DS.poiCount.font).tracking(DS.poiCount.tracking)
                                .monospacedDigit()
                                .foregroundStyle(on ? DS.ink : DS.inkDim)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 2)
                        .contentShape(Rectangle())
                    }
                    .pressable()
                    .animation(DS.quick, value: on)
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    #endif
                }

                Text("Placement runs all 183 types; they compete for the same 64 m zones.")
                    .font(DS.note.font).tracking(DS.note.tracking)
                    .foregroundStyle(DS.noteInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                    .overlay(alignment: .top) { Rectangle().fill(DS.line).frame(height: 1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Seed report

struct ReportPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(id: "report", title: "SEED REPORT",
              trailing: model.report.map { "\($0.reachable)/\($0.total)" } ?? "") {
            if let r = model.report {
                VStack(alignment: .leading, spacing: 1) {
                    KV(k: "HOME LANDMASS", v: String(format: "%.1f km²", r.spawnAreaKm2))
                    KV(k: "LARGEST", v: String(format: "%.1f km²", r.largestKm2), dim: true)
                    KV(k: "LANDMASSES", v: "\(r.landmasses)", dim: true)

                    Rectangle().fill(DS.line).frame(height: 1).padding(.vertical, 6)

                    ForEach(Array(r.sites.enumerated()), id: \.offset) { _, s in
                        Button { model.centreOn(s.x, s.y) } label: {
                            HStack(spacing: 6) {
                                Text(s.reachable ? "✓" : "~")
                                    .font(DS.siteText.font)
                                    .foregroundStyle(s.reachable ? DS.ok : DS.lbl)
                                    .frame(width: 9, alignment: .leading)
                                Text(s.label)
                                    .font(DS.siteText.font).tracking(DS.siteText.tracking)
                                    .foregroundStyle(s.reachable ? DS.fg : DS.lbl)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(Int(s.dist)) m")
                                    .font(DS.siteText.font).tracking(DS.siteText.tracking)
                                    .monospacedDigit()
                                    .foregroundStyle(DS.fg2)
                            }
                            .padding(.vertical, 2).padding(.horizontal, 3)
                            .contentShape(Rectangle())
                        }
                        .pressable()
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(s.reachable ? DS.ok : .clear)
                                .frame(width: 1)
                        }
                        #if os(macOS)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        #endif
                    }

                    Text("✓ = reachable on foot from spawn")
                        .font(DS.note.font).tracking(DS.note.tracking)
                        .foregroundStyle(DS.noteInk)
                        .padding(.top, 7)
                        .overlay(alignment: .top) { Rectangle().fill(DS.line).frame(height: 1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(DS.reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: 3)))
            } else {
                HStack(spacing: 7) {
                    Text(model.placing ? "PLACING LOCATIONS" : "WAITING")
                        .font(DS.seg.font).tracking(DS.seg.tracking)
                        .foregroundStyle(DS.amber)
                    Spacer()
                    Text("\(Int(model.placementProgress * 100))%")
                        .font(DS.kvDim.font).monospacedDigit()
                        .foregroundStyle(DS.inkDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Marker tooltip

/// Floating label pinned to the hovered marker. Positioned in the map's own
/// coordinate space, and nudged so it never hangs off the viewport edge.
struct MarkerTooltip: View {
    let site: Site
    let at: CGPoint
    let bounds: CGSize

    private var category: POICategory? {
        POI_KINDS.first { $0.kind == site.kind }
    }

    var body: some View {
        let w: CGFloat = 176
        let flipX = at.x + w + 22 > bounds.width
        let flipY = at.y < 54

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(category?.color ?? DS.ink)
                    .frame(width: 7, height: 7)
                Text(site.label)
                    .font(DS.site.font).tracking(DS.site.tracking)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(category?.name ?? "")
                    .font(DS.note.font).tracking(DS.note.tracking)
                    .foregroundStyle(DS.inkDim)
                Spacer(minLength: 4)
                Text("\(Int(site.x)), \(Int(site.y))")
                    .font(DS.note.font).monospacedDigit()
                    .foregroundStyle(DS.inkDim)
            }
            HStack(spacing: 8) {
                Text(site.reachable ? "✓ ON FOOT" : "~ NEEDS A BOAT")
                    .font(DS.note.font).tracking(DS.note.tracking)
                    .foregroundStyle(site.reachable ? DS.ok : DS.lbl)
                Spacer(minLength: 4)
                Text("\(Int(site.dist)) m")
                    .font(DS.note.font).monospacedDigit()
                    .foregroundStyle(DS.fg2)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .frame(width: w, alignment: .leading)
        .panelChrome(radius: 0)
        .allowsHitTesting(false)
        .offset(x: flipX ? -(w + 16) : 16, y: flipY ? 14 : -58)
        .position(at)
    }
}

// MARK: - Press feedback

/// The app had no press state anywhere — hover was styled, press was not. This
/// is the only motion added to the controls; the scale is kept at the subtle
/// end because the segmented controls are hit tens of times a day.
///
/// Not applied to the panel headers: collapsing is meant to feel instant, and
/// any motion on that control risks reintroducing the lag that was removed.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? DS.pressScale : 1.0)
            .animation(DS.press, value: configuration.isPressed)
    }
}

extension View {
    func pressable() -> some View { buttonStyle(PressableButtonStyle()) }
}

// MARK: - Wordmark

/// The app name in the top-left corner, over a blur that fades out rather than
/// a plate. A panel here would read as another instrument; this is signage.
struct CornerWash: View {
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.46, 520)
            let h = min(geo.size.height * 0.40, 340)

            ZStack(alignment: .topLeading) {
                // Two masked passes rather than one: a single blur that stops
                // dead has a visible edge, and stacking a wider, gentler pass
                // under a tighter one reads as the blur falling off.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(width: w, height: h)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.55), location: 0.0),
                                .init(color: .black.opacity(0.22), location: 0.45),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(width: w * 0.62, height: h * 0.62)
                    .mask(
                        RadialGradient(
                            stops: [
                                .init(color: .black.opacity(0.85), location: 0.0),
                                .init(color: .black.opacity(0.35), location: 0.55),
                                .init(color: .clear, location: 1.0),
                            ],
                            center: .topLeading, startRadius: 0,
                            endRadius: max(w, h) * 0.62)
                    )

                // A little ink so the wordmark holds over bright meadow.
                Rectangle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: DS.bg.opacity(0.78), location: 0.0),
                                .init(color: DS.bg.opacity(0.30), location: 0.5),
                                .init(color: .clear, location: 1.0),
                            ],
                            center: .topLeading, startRadius: 0, endRadius: max(w, h) * 0.8)
                    )
                    .frame(width: w, height: h)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("VEGVISR")
                .font(DS.rune(34))
                .tracking(1.5)
                .foregroundStyle(DS.ink)
                .shadow(color: DS.bg.opacity(0.9), radius: 6, x: 0, y: 1)
            Text("SEED MAP")
                .font(DS.note.font)
                .tracking(DS.note.tracking)
                .foregroundStyle(DS.noteInk)
                .padding(.bottom, 2)
        }
        .padding(.bottom, 2)
        .allowsHitTesting(false)
    }
}
