//! Bit-exact port of `UnityEngine.Random` (xorshift128) and Valheim's
//! `string.GetStableHashCode()`.
//!
//! Verified against Unity-captured test vectors: seed 1234 produces state
//! [1234, 3159640283, 3392860520, 3460949513] and raw outputs
//! [3463400838, 3496203776, 3452947669, 1278673611, 4169168310].

/// MT19937 / Borosh-Niederreiter seeding constant (0x6C078965).
const BOROSH: u32 = 1812433253;
/// 2^23 - 1. Unity derives floats from the low 23 mantissa bits.
const MANTISSA_MAX: u32 = 0x7FFFFF;

#[derive(Clone, Copy, Debug)]
pub struct UnityRandom {
    s0: u32,
    s1: u32,
    s2: u32,
    s3: u32,
}

impl UnityRandom {
    pub fn new(seed: i32) -> Self {
        let s0 = seed as u32;
        let s1 = BOROSH.wrapping_mul(s0).wrapping_add(1);
        let s2 = BOROSH.wrapping_mul(s1).wrapping_add(1);
        let s3 = BOROSH.wrapping_mul(s2).wrapping_add(1);
        Self { s0, s1, s2, s3 }
    }

    /// Exposed for the cross-language parity harness.
    pub fn state(&self) -> (u32, u32, u32, u32) { (self.s0, self.s1, self.s2, self.s3) }

    #[inline]
    pub fn next_u32(&mut self) -> u32 {
        let t = self.s0 ^ (self.s0 << 11);
        self.s0 = self.s1;
        self.s1 = self.s2;
        self.s2 = self.s3;
        self.s3 = self.s3 ^ (self.s3 >> 19) ^ t ^ (t >> 8);
        self.s3
    }

    /// `Random.value` — low 23 bits over 2^23-1.
    #[inline]
    pub fn value(&mut self) -> f32 {
        (self.next_u32() & MANTISSA_MAX) as f32 / MANTISSA_MAX as f32
    }

    /// `Random.Range(float, float)`. Note Unity's formula is
    /// `t*(min-max) + max`, NOT the conventional `min + t*(max-min)`.
    #[inline]
    pub fn range_f32(&mut self, min: f32, max: f32) -> f32 {
        let t = self.value();
        t * (min - max) + max
    }

    /// `Random.Range(int, int)`, max-exclusive. Widened to 64-bit, plain
    /// modulo with NO rejection sampling — this reproduces Unity's modulo
    /// bias, which is required for bit-exact parity.
    #[inline]
    pub fn range_i32(&mut self, min: i32, max: i32) -> i32 {
        let r = self.next_u32() as i64;
        let (lo, hi) = (min as i64, max as i64);
        // Zero-width range: Unity returns min. Whether its native code still
        // advances the stream is unverified; we consume, matching the fact
        // that every other path here draws exactly once.
        if hi == lo {
            return min;
        }
        let res = if hi < lo { lo - r % (hi - lo) } else { lo + r % (hi - lo) };
        res as i32
    }

    /// `Random.insideUnitCircle` — closed-form polar method, exactly 2 draws.
    /// Uses Range(0,1) semantics, which equal `1 - value`.
    #[inline]
    pub fn inside_unit_circle(&mut self) -> (f32, f32) {
        let theta = (1.0 - self.value()) * std::f32::consts::TAU;
        let radius = (1.0 - self.value()).sqrt();
        (radius * theta.cos(), radius * theta.sin())
    }
}

/// Valheim's `string.GetStableHashCode()` — djb2 variant consuming two chars
/// per iteration. Operates on UTF-16 code units, matching C# `string`.
pub fn stable_hash_code(s: &str) -> i32 {
    let u: Vec<u16> = s.encode_utf16().collect();
    let mut num: i32 = 5381;
    let mut num2: i32 = 5381;
    let mut i = 0usize;
    while i < u.len() && u[i] != 0 {
        num = ((num << 5).wrapping_add(num)) ^ (u[i] as i32);
        if i == u.len() - 1 || u[i + 1] == 0 {
            break;
        }
        num2 = ((num2 << 5).wrapping_add(num2)) ^ (u[i + 1] as i32);
        i += 2;
    }
    num.wrapping_add(num2.wrapping_mul(1566083941))
}

/// Valheim hard-codes the empty seed name to 0 rather than hashing it.
pub fn seed_from_name(name: &str) -> i32 {
    if name.is_empty() { 0 } else { stable_hash_code(name) }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Seed phrase -> integer, checked against two real `.fwl` world files as
    /// parsed by Kakoen's `valheim-save-tools`. Those files store the phrase
    /// *and* the integer the game derived from it, so they are independent
    /// ground truth for `GetStableHashCode` — not another copy of our own
    /// assumption.
    #[test]
    fn seed_names_match_real_world_files() {
        assert_eq!(seed_from_name("Kh0zDpuPnw"), 810132289);
        assert_eq!(seed_from_name("q6GhJN6FwT"), 517038747);
    }

    #[test]
    fn hash_vectors() {
        assert_eq!(stable_hash_code("Dedbtjdcv"), 1218100378);
        assert_eq!(stable_hash_code("Valheim"), -827134064);
        assert_eq!(stable_hash_code("test"), -871206010);
        assert_eq!(stable_hash_code("a"), 372029373);
        assert_eq!(seed_from_name(""), 0);
    }

    #[test]
    fn rng_vectors() {
        let r = UnityRandom::new(1234);
        assert_eq!([r.s0, r.s1, r.s2, r.s3], [1234, 3159640283, 3392860520, 3460949513]);
        let mut r = UnityRandom::new(1234);
        let got: Vec<u32> = (0..5).map(|_| r.next_u32()).collect();
        assert_eq!(got, vec![3463400838, 3496203776, 3452947669, 1278673611, 4169168310]);
    }

    #[test]
    fn range_int_vectors() {
        let mut r = UnityRandom::new(1234);
        let got: Vec<i32> = (0..5).map(|_| r.range_i32(0, i32::MAX)).collect();
        assert_eq!(got, vec![1315917191, 1348720129, 1305464022, 1278673611, 2021684663]);
    }

    #[test]
    fn world_offsets_dedbtjdcv() {
        let mut r = UnityRandom::new(seed_from_name("Dedbtjdcv"));
        let o: Vec<i32> = (0..4).map(|_| r.range_i32(-10000, 10000)).collect();
        assert_eq!(o, vec![-8087, 9698, -4921, -8635]);
        let river = r.range_i32(i32::MIN, i32::MAX);
        let stream = r.range_i32(i32::MIN, i32::MAX);
        let o4 = r.range_i32(-10000, 10000);
        assert_eq!(river, 1741748534);
        assert_eq!(stream, -2141061776);
        assert_eq!(o4, -116);
    }
}
