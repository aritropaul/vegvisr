//  DesignSystem.swift
//  Every colour, type style and metric transcribed from the web app's
//  src/ui/style.css so the two clients look like the same product.
//
//  Note on tracking: CSS letter-spacing is in `em` (relative to font size);
//  SwiftUI's .tracking() is in points. Every value here is pre-multiplied.

import SwiftUI
import Worldgen
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DS {
    /// Liquid Glass samples a live backdrop, so it renders as an opaque slab in
    /// an offscreen capture. The debug snapshot path turns it off to stay
    /// useful for checking layout.
    nonisolated(unsafe) static var snapshotMode = false

    // MARK: Colour — the :root custom properties
    static let bg        = Color(hex: 0x04070E)          // --bg
    static let ink       = Color(hex: 0x9FE8FF)          // --ink
    static let inkDim    = Color(hex: 0x5D7F93)          // --ink-dim
    static let amber     = Color(hex: 0xE8C07A)          // --amber
    static let red       = Color(hex: 0xFF7A52)          // --red
    static let line      = Color(hex: 0x96EBFF, a: 0.16) // --line
    static let panel     = Color(hex: 0x050911, a: 0.84) // --panel

    // Referenced in CSS only via var(--x, fallback) where --x is never
    // declared, so the fallback is what actually paints.
    static let fg        = Color(hex: 0xCFE3F5)
    static let fg2       = Color(hex: 0x8EA0B5)
    static let ok        = Color(hex: 0x8FD94A)

    static let tick      = Color(hex: 0x96EBFF, a: 0.50) // panel corner brackets
    static let hoverCyan = Color(hex: 0x96EBFF, a: 0.07)
    static let hoverBlue = Color(hex: 0x78B4FF, a: 0.09)
    static let lbl       = Color(hex: 0x6F7B89)
    static let noteInk   = Color(hex: 0x96EBFF, a: 0.32)
    static let hintInk   = Color(hex: 0x96EBFF, a: 0.40)
    static let gold      = Color(hex: 0xFFD77A)          // drop hint / slider tint
    static let trackBg   = Color(hex: 0x96EBFF, a: 0.07)
    static let bootBar   = Color(hex: 0x96EBFF, a: 0.14)
    static let seedField = Color(hex: 0x000000, a: 0.45)

    // MARK: Type — Martian Mono (display) + IBM Plex Mono (data)
    //
    // `fixedSize:` not `size:` — the latter scales with Dynamic Type, which on
    // a machine set above the default inflates an 8pt instrument label into
    // something that fights the rest of the chrome. These sizes are transcribed
    // from a stylesheet in px and are meant to stay put.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom("MartianMono-Regular", fixedSize: size).weight(weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("IBMPlexMono-Regular", fixedSize: size).weight(weight)
    }
    /// Wordmark only. A runic display face earns its keep once, at the top
    /// left; using it anywhere else would fight the instrument type.
    static func rune(_ size: CGFloat) -> Font {
        .custom("RunyTunesRevisitedNF", fixedSize: size)
    }

    // Named styles, matching the CSS selectors one-for-one.
    static let phead     = (font: display(8, .medium),  tracking: 0.8)   // .phead   .1em
    static let seg       = (font: display(8, .medium),  tracking: 0.32)  // .seg     .04em
    static let kvKey     = (font: display(8, .light),   tracking: 0.48)  // .kv dt   .06em
    static let kvVal     = (font: mono(11),             tracking: 0.33)  // .kv dd   .03em
    static let kvBig     = (font: mono(11),             tracking: 0.33)  // .kv.big dd
    static let kvDim     = (font: mono(9),              tracking: 0.27)  // .kv.dim
    static let poiLabel  = (font: display(8, .light),   tracking: 0.24)  // .poi     .03em
    static let poiCount  = (font: mono(9, .medium),     tracking: 0.27)  // .poi b
    static let barName   = (font: display(8, .light),   tracking: 0.16)  // .bar span .02em
    static let barVal    = (font: mono(10),             tracking: 0.30)  // .bar b
    static let note      = (font: display(7, .light),   tracking: 0.14)  // .note    .02em
    static let hint      = (font: display(7, .light),   tracking: 0.14)  // .hint
    static let bootText  = (font: display(8, .light),   tracking: 0.96)  // #bootText .12em
    static let seedInput = (font: mono(12),             tracking: 0.72)  // #seed    .06em
    static let goLabel   = (font: display(9, .bold),    tracking: 0.36)  // .go      .04em
    static let rowText   = (font: mono(10),             tracking: 0.60)  // .hit-row .06em
    static let siteText  = (font: mono(10),             tracking: 0.40)  // .site-row .04em
    static let site      = (font: mono(9, .medium),     tracking: 0.18)  // .site badge

    // MARK: Metrics
    static let panelPad     = EdgeInsets(top: 9, leading: 12, bottom: 11, trailing: 12)
    static let panelInset: CGFloat = 14      // fixed corner offset
    static let panelMinW: CGFloat = 168
    static let hairline: CGFloat = 1
    static let tickSize: CGFloat = 5         // .panel::before/::after 5x5px
    static let blurRadius: CGFloat = 10      // backdrop-filter: blur(10px)
    /// Liquid Glass reads as a material rather than a cutout with a little
    /// curvature; the plate stays close to the web's square corners.
    static let panelRadius: CGFloat = 0
    /// A whisper of tint under the glass — enough to keep the instrument cast
    /// without turning the plate into an opaque slab. The glass supplies the
    /// depth; a heavy fill here just hides it.
    static let panelTint = Color(hex: 0x0A1A2A, a: 0.18)
    /// Every plate is the same width so the corners line up as a set.
    static let panelWidth: CGFloat = 236

    // MARK: Motion
    static let quick  = Animation.easeInOut(duration: 0.12)   // 120ms ease
    static let barFill = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    static let bootFade = Animation.easeInOut(duration: 0.30)
    /// Collapsing is instant on purpose — a spring here reads as lag on a
    /// control you hit repeatedly while reading the map.
    static let collapse: Animation? = nil
    /// Press feedback. Deliberately at the subtle end: the segmented controls
    /// are hit tens of times a day and anything larger reads as sluggish.
    static let press = Animation.easeOut(duration: 0.12)
    static let pressScale: CGFloat = 0.97
    /// Content swapping in where there was a placeholder.
    static let swapIn = Animation.easeOut(duration: 0.20)

    /// Reduced motion is honoured by making motion gentler, not by removing it —
    /// the jarring change is usually the thing the motion exists to prevent.
    static var reduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }
}

extension Color {
    init(hex: UInt32, a: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: a)
    }
}

/// Biome swatches for the composition chart, per palette. Mirrors SWATCH in
/// the web app's main.ts.
enum Swatch {
    static let classic: [Biome: Color] = [
        .meadows: Color(hex: 0xA8E05F), .blackForest: Color(hex: 0x2F7D4F),
        .swamp: Color(hex: 0x9A7B45), .mountain: Color(hex: 0xDCE9F2),
        .plains: Color(hex: 0xD9B876), .mistlands: Color(hex: 0x8A7BC8),
        .ashLands: Color(hex: 0xE0552F), .deepNorth: Color(hex: 0x9FD8F0),
        .ocean: Color(hex: 0x2654C4),
    ]
    static let accessible: [Biome: Color] = [
        .meadows: Color(hex: 0xC6F060), .blackForest: Color(hex: 0x289EDC),
        .swamp: Color(hex: 0xF476CE), .mountain: Color(hex: 0xFFFFFF),
        .plains: Color(hex: 0xF6C43E), .mistlands: Color(hex: 0xB080FF),
        .ashLands: Color(hex: 0xFF8036), .deepNorth: Color(hex: 0x7EE2FF),
        .ocean: Color(hex: 0x3A68E2),
    ]
    static func of(_ b: Biome, _ p: Palette) -> Color {
        (p == .accessible ? accessible : classic)[b] ?? DS.inkDim
    }
}

/// Display order for the composition chart (matches BIOME_ORDER in protocol.ts).
let BIOME_ORDER: [Biome] = [
    .meadows, .blackForest, .swamp, .mountain, .plains,
    .mistlands, .ashLands, .deepNorth, .ocean,
]

extension Biome {
    var label: String {
        switch self {
        case .none: return "NONE"
        case .meadows: return "MEADOWS"
        case .swamp: return "SWAMP"
        case .mountain: return "MOUNTAIN"
        case .blackForest: return "BLACK FOREST"
        case .plains: return "PLAINS"
        case .ashLands: return "ASHLANDS"
        case .deepNorth: return "DEEP NORTH"
        case .ocean: return "OCEAN"
        case .mistlands: return "MISTLANDS"
        }
    }
}
