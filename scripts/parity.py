#!/usr/bin/env python3
"""Cross-language parity gate: the Rust generator against the Swift port.

The two are not byte-identical and cannot be made so cheaply. Rust and Swift
reach different libm implementations for sin/cos/pow; each is correctly rounded
to within an ULP of the true result, but not to the *same* ULP. That difference
is real, bounded and measured, so this asserts the bound instead of pretending
it is zero. A gate that demanded byte equality would have to be switched off,
and a switched-off gate catches nothing.

Exact, no tolerance:
  RNG state and output vectors, seed hashing, the seed -> offset draw order,
  the Perlin checksum and its mirror quirk, which biome each probe lands in,
  every biome's share of world area, and every boss / trader / start-temple
  position. Those are what a seed report states and what a player judges a
  seed by.

Bounded, with the observed value printed either way:
  raw height in metres, tile byte sums, and the total location count — where a
  single rejection-sample outcome in ~12 000 can flip and cascade, because
  placement shares one occupancy map.

Ignored:
  timings, and hashes of byte blocks (a one-byte tile difference changes an FNV
  digest completely, so the digest can only say "differs", which the sum
  already says quantitatively).
"""

import re
import sys

# key prefix -> (kind, tolerance)
BOUNDED = {
    "sample.": ("height", 1e-3),   # metres; observed max 5.4e-5
    "tile.":   ("sum", 8),         # bytes out of ~26 M; observed max 2
    "bits.":   ("ulp", 512),       # float32 steps; observed max 92
    "loc.count": ("count", 4),     # placements out of 12 163; observed 1
    "loc.kinds": ("kinds", 4),     # per category, except spawn/boss/trader
}
IGNORED = (".ms", ".fnv", "loc.checksum")

# Indices into loc.kinds that must match exactly: Spawn, Boss, Trader.
EXACT_KINDS = (0, 1, 2)


def load(path):
    rows = []
    with open(path) as f:
        for raw in f:
            if not raw.strip():
                continue
            parts = raw.rstrip("\n").split("\t")
            rows.append((parts[0], parts[1:]))
    return rows


def norm_key(k):
    # Rust prints -125f32 as "-125", Swift as "-125.0". Only the bits.* probe
    # keys embed raw floats, so the fixup stays scoped to them.
    return re.sub(r"\.0(?=,|$)", "", k) if k.startswith("bits.") else k


def main(rust_path, swift_path):
    rust, swift = load(rust_path), load(swift_path)
    fails, notes = [], []

    if len(rust) != len(swift):
        print(f"FAIL  line count {len(rust)} vs {len(swift)} — harnesses disagree")
        return 1

    for i, ((rk, rv), (sk, sv)) in enumerate(zip(rust, swift), 1):
        if norm_key(rk) != norm_key(sk):
            fails.append(f"line {i}: key {rk!r} vs {sk!r}")
            continue
        if any(rk.endswith(s) or rk == s for s in IGNORED):
            continue

        kind = tol = None
        for prefix, (k, t) in BOUNDED.items():
            if rk.startswith(prefix):
                kind, tol = k, t
                break

        if kind is None:
            if rv != sv:
                fails.append(f"{rk}: {rv} vs {sv} (must be exact)")
            continue

        if kind == "height":
            # "<biome bitmask>\t<height>": the biome is a classification and
            # must be identical; the height is the analogue value.
            if rv[0] != sv[0]:
                fails.append(f"{rk}: biome {rv[0]} vs {sv[0]} (must be exact)")
                continue
            d = abs(float(rv[1]) - float(sv[1]))
            notes.append((rk, f"{d:.2e} m", d <= tol))
            if d > tol:
                fails.append(f"{rk}: height differs by {d:.3e} m > {tol}")

        elif kind == "sum":
            d = abs(int(rv[0]) - int(sv[0]))
            notes.append((rk, f"{d} bytes", d <= tol))
            if d > tol:
                fails.append(f"{rk}: byte sum differs by {d} > {tol}")

        elif kind == "ulp":
            d = abs(int(rv[1], 16) - int(sv[1], 16))
            notes.append((rk, f"{d} ulp", d <= tol))
            if d > tol:
                fails.append(f"{rk}: {d} float32 steps apart > {tol}")

        elif kind == "count":
            d = abs(int(rv[0]) - int(sv[0]))
            notes.append((rk, f"{d} sites", d <= tol))
            if d > tol:
                fails.append(f"{rk}: {rv[0]} vs {sv[0]}, differs by {d} > {tol}")

        elif kind == "kinds":
            a = [int(x) for x in rv[0].split(",")]
            b = [int(x) for x in sv[0].split(",")]
            if len(a) != len(b):
                fails.append(f"{rk}: {len(a)} categories vs {len(b)}")
                continue
            for j, (x, y) in enumerate(zip(a, b)):
                if j in EXACT_KINDS:
                    if x != y:
                        fails.append(f"{rk}[{j}]: {x} vs {y} — spawn/boss/trader must be exact")
                elif abs(x - y) > tol:
                    fails.append(f"{rk}[{j}]: {x} vs {y}, differs by {abs(x - y)} > {tol}")
            worst = max(abs(x - y) for x, y in zip(a, b))
            notes.append((rk, f"worst category {worst}", worst <= tol))

    width = max(len(k) for k, _, _ in notes) if notes else 0
    for k, v, ok in notes:
        print(f"{'ok  ' if ok else 'FAIL'}  {k:<{width}}  {v}")

    exact = sum(
        1 for (rk, _), _ in zip(rust, swift)
        if not any(rk.startswith(p) for p in BOUNDED)
        and not any(rk.endswith(s) or rk == s for s in IGNORED)
    )
    print(f"\n{exact} vectors compared exactly, {len(notes)} within bounds")

    if fails:
        print(f"\n{len(fails)} failure(s):")
        for f in fails:
            print(f"  {f}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: parity.py <rust-output> <swift-output>")
    sys.exit(main(sys.argv[1], sys.argv[2]))
