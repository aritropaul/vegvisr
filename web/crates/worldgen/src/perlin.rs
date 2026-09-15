//! Bit-accurate port of `UnityEngine.Mathf.PerlinNoise(x, y)`.
//!
//! Unity's implementation is closed-source native C++; this is Ken Perlin's
//! 2002 "Improving Noise" 3D noise evaluated at z=0 with Perlin's original
//! 256-entry permutation table, plus two Unity-specific quirks:
//!   1. `x` and `y` are passed through `abs()` first, so the field is mirrored
//!      across both axes (NOT classic Perlin behaviour).
//!   2. The result is rescaled by `(raw + 0.69) / 1.483`, which is why Unity
//!      documents the range as "approximately" 0..1 — it is affine, not clamped,
//!      so it can slip slightly outside.
//!
//! Validated against 176 values dumped from real Unity; see tests/perlin.rs.

/// Ken Perlin's original 2002 permutation table, verbatim.
#[rustfmt::skip]
const PERM: [u8; 256] = [
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
];

/// Indexing with a mask is equivalent to Perlin's doubled 512-entry table,
/// since p512[i] == PERM[i % 256] for all i < 512.
#[inline(always)]
fn p(i: i32) -> i32 {
    PERM[(i & 255) as usize] as i32
}

/// Quintic ease curve: 6t^5 - 15t^4 + 10t^3.
#[inline(always)]
fn fade(t: f32) -> f32 {
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

#[inline(always)]
fn lerp(t: f32, a: f32, b: f32) -> f32 {
    a + t * (b - a)
}

/// Perlin's 12-direction gradient, with the z-terms collapsed out at z=0.
#[inline(always)]
fn grad(hash: i32, x: f32, y: f32) -> f32 {
    let h = hash & 15;
    let u = if h < 8 { x } else { y };
    let v = if h < 4 {
        y
    } else if h == 12 || h == 14 {
        x
    } else {
        0.0
    };
    (if h & 1 == 0 { u } else { -u }) + (if h & 2 == 0 { v } else { -v })
}

/// Reimplementation of `UnityEngine.Mathf.PerlinNoise(x, y)`.
#[inline]
pub fn perlin(x: f32, y: f32) -> f32 {
    let mut x = x.abs();
    let mut y = y.abs();

    let xi = x.floor();
    let yi = y.floor();
    // Safe because x,y >= 0 after abs(); mirrors C's `(int)x`.
    let xw = xi as i32;
    let yw = yi as i32;

    x -= xi;
    y -= yi;

    let a = p(xw) + yw;
    let b = p(xw + 1) + yw;

    let aa = p(p(a));
    let ba = p(p(b));
    let ab = p(p(a + 1));
    let bb = p(p(b + 1));

    let u = fade(x);
    let v = fade(y);

    let res = lerp(
        v,
        lerp(u, grad(aa, x, y), grad(ba, x - 1.0, y)),
        lerp(u, grad(ab, x, y - 1.0), grad(bb, x - 1.0, y - 1.0)),
    );

    (res + 0.69) / 1.483
}
