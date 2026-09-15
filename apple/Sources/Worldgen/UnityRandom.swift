//  UnityRandom.swift
//  Bit-exact port of `UnityEngine.Random` (xorshift128) and Valheim's
//  `string.GetStableHashCode()`.
//
//  PORTING CONTRACT — every file in Worldgen/ follows these rules. Breaking one
//  silently produces a different world, so they are not negotiable:
//
//    Rust f32  -> Swift Float      Rust f64 -> Swift Double
//    wrapping_mul / wrapping_add   -> &* and &+   (Swift traps on overflow)
//    `seed as u32`                 -> UInt32(bitPattern:)
//    `x as i32` (truncating)       -> Int32(truncatingIfNeeded:)
//    Narrowing f64 -> f32          -> Float(x), at exactly the same point
//
//  Verified against Unity-captured vectors: seed 1234 produces state
//  [1234, 3159640283, 3392860520, 3460949513] and raw outputs
//  [3463400838, 3496203776, 3452947669, 1278673611, 4169168310].

import Foundation

/// MT19937 / Borosh-Niederreiter seeding constant (0x6C078965).
private let BOROSH: UInt32 = 1_812_433_253
/// 2^23 - 1. Unity derives floats from the low 23 mantissa bits.
private let MANTISSA_MAX: UInt32 = 0x7F_FFFF

public struct UnityRandom {
    public internal(set) var s0: UInt32
    public internal(set) var s1: UInt32
    public internal(set) var s2: UInt32
    public internal(set) var s3: UInt32

    public init(seed: Int32) {
        let a = UInt32(bitPattern: seed)
        let b = BOROSH &* a &+ 1
        let c = BOROSH &* b &+ 1
        let d = BOROSH &* c &+ 1
        s0 = a; s1 = b; s2 = c; s3 = d
    }

    @inline(__always)
    public mutating func nextU32() -> UInt32 {
        let t = s0 ^ (s0 << 11)
        s0 = s1
        s1 = s2
        s2 = s3
        s3 = s3 ^ (s3 >> 19) ^ t ^ (t >> 8)
        return s3
    }

    /// `Random.value` — low 23 bits over 2^23-1.
    @inline(__always)
    public mutating func value() -> Float {
        Float(nextU32() & MANTISSA_MAX) / Float(MANTISSA_MAX)
    }

    /// `Random.Range(float, float)`. Unity's formula is `t*(min-max) + max`,
    /// NOT the conventional `min + t*(max-min)`. The two differ in the last bits.
    @inline(__always)
    public mutating func range(_ min: Float, _ max: Float) -> Float {
        let t = value()
        return t * (min - max) + max
    }

    /// `Random.Range(int, int)`, max-exclusive. Widened to 64-bit, plain modulo
    /// with NO rejection sampling — this reproduces Unity's modulo bias, which
    /// is required for bit-exact parity. "Fixing" it would make it wrong.
    @inline(__always)
    public mutating func range(_ min: Int32, _ max: Int32) -> Int32 {
        let r = Int64(nextU32())
        let lo = Int64(min), hi = Int64(max)
        // Zero-width range: Unity returns min. We still consume a draw, matching
        // the fact that every other path here draws exactly once.
        if hi == lo { return min }
        let res = hi < lo ? lo - r % (hi - lo) : lo + r % (hi - lo)
        return Int32(truncatingIfNeeded: res)
    }

    /// `Random.insideUnitCircle` — closed-form polar method, exactly 2 draws.
    /// Uses Range(0,1) semantics, which equal `1 - value`.
    @inline(__always)
    public mutating func insideUnitCircle() -> (Float, Float) {
        let theta = (1.0 - value()) * Float.pi * 2.0
        let radius = (1.0 - value()).squareRoot()
        return (radius * mathfCos(theta), radius * mathfSin(theta))
    }
}

/// Valheim's `string.GetStableHashCode()` — djb2 variant consuming two chars
/// per iteration, over UTF-16 code units to match C# `string`.
public func stableHashCode(_ s: String) -> Int32 {
    let u = Array(s.utf16)
    var num: Int32 = 5381
    var num2: Int32 = 5381
    var i = 0
    while i < u.count && u[i] != 0 {
        num = ((num << 5) &+ num) ^ Int32(u[i])
        if i == u.count - 1 || u[i + 1] == 0 { break }
        num2 = ((num2 << 5) &+ num2) ^ Int32(u[i + 1])
        i += 2
    }
    return num &+ (num2 &* 1_566_083_941)
}

/// Valheim hard-codes the empty seed name to 0 rather than hashing it.
public func seedFromName(_ name: String) -> Int32 {
    name.isEmpty ? 0 : stableHashCode(name)
}
