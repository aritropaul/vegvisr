//  Perlin.swift
//  Bit-accurate port of `UnityEngine.Mathf.PerlinNoise(x, y)`.
//
//  Ken Perlin's 2002 "Improving Noise" 3D noise evaluated at z=0 with Perlin's
//  original 256-entry permutation table, plus two Unity-specific quirks:
//    1. x and y pass through abs() first, so the field is mirrored across both
//       axes (NOT classic Perlin behaviour).
//    2. The result is rescaled by (raw + 0.69) / 1.483 — affine, not clamped,
//       so it can slip slightly outside 0..1.
//
//  Validated against 176 values dumped from real Unity; max error 5.96e-8.

import Foundation

/// Ken Perlin's original 2002 permutation table, verbatim.
private let PERM: [UInt8] = [
    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,
    8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,
    117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,
    71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,
    41,55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,
    89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,
    226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,
    17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,
    167,43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,
    246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,
    239,107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,
    254,138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180,
]

/// Indexing with a mask is equivalent to Perlin's doubled 512-entry table,
/// since p512[i] == PERM[i % 256] for all i < 512.
@inline(__always)
private func p(_ i: Int32) -> Int32 {
    Int32(PERM[Int(i & 255)])
}

/// Quintic ease curve: 6t^5 - 15t^4 + 10t^3.
@inline(__always)
private func fade(_ t: Float) -> Float {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

@inline(__always)
private func lerpP(_ t: Float, _ a: Float, _ b: Float) -> Float {
    a + t * (b - a)
}

/// Perlin's 12-direction gradient, with the z-terms collapsed out at z=0.
@inline(__always)
private func grad(_ hash: Int32, _ x: Float, _ y: Float) -> Float {
    let h = hash & 15
    let u = h < 8 ? x : y
    let v: Float
    if h < 4 { v = y } else if h == 12 || h == 14 { v = x } else { v = 0.0 }
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
}

/// Reimplementation of `UnityEngine.Mathf.PerlinNoise(x, y)`.
@inline(__always)
public func perlin(_ x0: Float, _ y0: Float) -> Float {
    var x = abs(x0)
    var y = abs(y0)

    let xi = x.rounded(.down)
    let yi = y.rounded(.down)
    // Safe because x,y >= 0 after abs(); mirrors C's `(int)x`.
    let xw = Int32(xi)
    let yw = Int32(yi)

    x -= xi
    y -= yi

    let a = p(xw) &+ yw
    let b = p(xw &+ 1) &+ yw

    let aa = p(p(a))
    let ba = p(p(b))
    let ab = p(p(a &+ 1))
    let bb = p(p(b &+ 1))

    let u = fade(x)
    let v = fade(y)

    let res = lerpP(
        v,
        lerpP(u, grad(aa, x, y), grad(ba, x - 1.0, y)),
        lerpP(u, grad(ab, x, y - 1.0), grad(bb, x - 1.0, y - 1.0))
    )

    return (res + 0.69) / 1.483
}

/// `DUtils.PerlinNoise(double,double)` — narrows to Float at the call boundary
/// only, because Mathf.PerlinNoise is float-only in Unity.
@inline(__always)
public func pn(_ x: Double, _ y: Double) -> Double {
    Double(perlin(Float(x), Float(y)))
}

// MARK: - Mathf trig
//
// Unity's Mathf wraps the double-precision libm: `Mathf.Sin(float f)` is
// literally `(float)Math.Sin(f)`. Calling `sinf` instead computes in single
// precision and lands 1 ULP away on roughly 11% of inputs, so every sin/cos on
// the generation path goes through these rather than the f32 libm entry points.
// `Mathf.Atan2` is the same shape; atan2f happens to agree bit-for-bit with the
// widened form on every value tested, but it is routed through here anyway so
// the rule is uniform.

@inline(__always)
public func mathfSin(_ x: Float) -> Float { Float(sin(Double(x))) }

@inline(__always)
public func mathfCos(_ x: Float) -> Float { Float(cos(Double(x))) }

@inline(__always)
public func mathfAtan2(_ y: Float, _ x: Float) -> Float { Float(atan2(Double(y), Double(x))) }
