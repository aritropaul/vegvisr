//! Validates the Perlin port against values dumped from real UnityEngine.

use worldgen::perlin::perlin;

#[test]
fn matches_unity_ground_truth() {
    let raw = include_str!("fixtures/unity_perlin_values.txt");
    let expected: Vec<f32> = raw
        .split_whitespace()
        .map(|s| s.parse::<f32>().expect("parse"))
        .collect();
    assert_eq!(expected.len(), 176, "fixture should hold 176 samples");

    // Reproduce Avledet's original sweep exactly, including the f32
    // accumulation drift from repeatedly adding 0.1/0.3.
    let mut got = Vec::with_capacity(176);
    let mut y: f32 = -1.1;
    while y < 1.1 {
        let mut x: f32 = -1.1;
        while x < 1.1 {
            got.push(perlin(x, y));
            x += 0.1;
        }
        y += 0.3;
    }

    assert_eq!(got.len(), expected.len(), "sweep length mismatch");

    let mut max_err = 0.0f32;
    for (i, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
        let err = (g - e).abs();
        if err > max_err {
            max_err = err;
        }
        assert!(err < 1e-4, "index {i}: got {g}, expected {e}, err {err}");
    }
    println!("max error vs real Unity across 176 samples: {max_err:e}");
}

#[test]
fn is_mirrored_across_both_axes() {
    // Unity's abs() means the field mirrors; a classic Perlin port would fail.
    let a = perlin(0.4, 0.5);
    assert_eq!(perlin(-0.4, 0.5), a);
    assert_eq!(perlin(0.4, -0.5), a);
    assert_eq!(perlin(-0.4, -0.5), a);
}
