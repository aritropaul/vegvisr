// Mirror of apple/Tests/parity — prints the identical format so the Swift port
// can be diffed against the Rust reference mechanically.
use worldgen::geo::{length, Biome, WorldGenerator};
use worldgen::perlin::perlin;
use worldgen::random::{seed_from_name, UnityRandom};
use worldgen::render::{Mode, Palette, TileRenderer};
use worldgen::locations::{generate, Kind, LOCATIONS};

fn line(k: &str, v: String) { println!("{}\t{}", k, v); }

fn main() {
    let mut r = UnityRandom::new(1234);
    let st = r.state();
    line("rng.state", format!("{},{},{},{}", st.0, st.1, st.2, st.3));
    let outs: Vec<String> = (0..5).map(|_| r.next_u32().to_string()).collect();
    line("rng.next5", outs.join(","));

    let mut r2 = UnityRandom::new(1234);
    let ri: Vec<String> = (0..5).map(|_| r2.range_i32(0, i32::MAX).to_string()).collect();
    line("rng.range5", ri.join(","));

    for s in ["Dedbtjdcv", "Valheim", "test", "a", ""] {
        let k = if s.is_empty() { "<empty>".to_string() } else { s.to_string() };
        line(&format!("hash.{}", k), format!("{}", seed_from_name(s)));
    }
    line("hash.Kh0zDpuPnw", format!("{}", seed_from_name("Kh0zDpuPnw")));
    line("hash.q6GhJN6FwT", format!("{}", seed_from_name("q6GhJN6FwT")));

    let wga = WorldGenerator::biome_only(seed_from_name("Dedbtjdcv"), 2);
    line("offsets.Dedbtjdcv", format!("{},{},{},{},{}",
        wga.offset0 as i32, wga.offset1 as i32, wga.offset2 as i32, wga.offset3 as i32, wga.offset4 as i32));
    line("seeds.Dedbtjdcv", format!("{},{}", wga.river_seed, wga.stream_seed));

    let mut checksum = 0.0f64;
    let mut yy = -1.1f32;
    while yy <= 1.1 {
        let mut xx = -1.1f32;
        while xx <= 1.1 {
            checksum += perlin(xx, yy) as f64;
            xx += 0.1;
        }
        yy += 0.3;
    }
    line("perlin.checksum", format!("{:.9}", checksum));
    line("perlin.mirror", format!("{}",
        perlin(0.4,0.5) == perlin(-0.4,0.5) && perlin(0.4,0.5) == perlin(0.4,-0.5)
        && perlin(0.4,0.5) == perlin(-0.4,-0.5)));

    const TEST: &str = "j3QV2ftr3y";
    line(&format!("seed.{}", TEST), format!("{}", seed_from_name(TEST)));
    let t0 = std::time::Instant::now();
    let wg = WorldGenerator::from_seed_name(TEST, 2);
    line("pregenerate.ms", format!("{:.1}", t0.elapsed().as_secs_f64() * 1000.0));

    for (x, y) in [(0,0), (500,500), (-1200,300), (3000,-2500), (0,-9800), (0,9800), (11000,0), (6000,6000)] {
        let (b, h) = wg.sample(x as f32, y as f32);
        line(&format!("sample.{},{}", x, y), format!("{}\t{:.6}", b as u16, h));
    }

    let ord = |b: Biome| -> usize { match b {
        Biome::None=>0, Biome::Meadows=>1, Biome::Swamp=>2, Biome::Mountain=>3,
        Biome::BlackForest=>4, Biome::Plains=>5, Biome::AshLands=>6,
        Biome::DeepNorth=>7, Biome::Ocean=>8, Biome::Mistlands=>9 } };
    let names = ["None","Meadows","Swamp","Mountain","BlackForest","Plains","AshLands","DeepNorth","Ocean","Mistlands"];
    let mut counts = [0usize; 10];
    let n = 384usize;
    let mut total = 0usize;
    for j in 0..n {
        for i in 0..n {
            let x = (-10000.0 + (i as f64 + 0.5) * 20000.0 / n as f64) as f32;
            let y = (10000.0 - (j as f64 + 0.5) * 20000.0 / n as f64) as f32;
            if length(x, y) > 10000.0 { continue; }
            counts[ord(wg.biome(x, y))] += 1;
            total += 1;
        }
    }
    for k in 0..10 { if counts[k] > 0 {
        line(&format!("dist.{}", names[k]), format!("{:.2}%", 100.0 * counts[k] as f64 / total as f64));
    }}

    let mut tr = TileRenderer::new(WorldGenerator::from_seed_name(TEST, 2));
    for (mode, pal, tag) in [(Mode::Biome, Palette::Classic, "biome/std"),
                              (Mode::Terrain, Palette::Classic, "terrain/std"),
                              (Mode::Terrain, Palette::Accessible, "terrain/a11y")] {
        let t = std::time::Instant::now();
        tr.render(-2000.0, 2000.0, 4000.0, 256, mode, pal);
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        let mut sum: u64 = 0;
        let mut fnv: u64 = 0xcbf29ce484222325;
        for &b in tr.pixels() {
            sum = sum.wrapping_add(b as u64);
            fnv = (fnv ^ b as u64).wrapping_mul(0x100000001b3);
        }
        line(&format!("tile.{}.sum", tag), format!("{}", sum));
        line(&format!("tile.{}.fnv", tag), format!("{:016x}", fnv));
        line(&format!("tile.{}.ms", tag), format!("{:.1}", ms));
    }

    if std::env::var("DUMP").is_ok() {
        tr.render(-2000.0, 2000.0, 4000.0, 256, Mode::Biome, Palette::Classic);
        std::fs::write("/tmp/rust_tile.bin", tr.pixels()).unwrap();
    }

    for (wx, wy) in [(-1734.375f32, -125.0f32), (1906.25f32, 1250.0f32), (15.625f32, -921.875f32)] {
        let (b, h) = wg.sample(wx, wy);
        line(&format!("bits.{},{}", wx, wy), format!("{}\t{:08x}", b as u16, h.to_bits()));
    }

    let t_loc = std::time::Instant::now();
    let placed = generate(&wg);
    line("loc.ms", format!("{:.0}", t_loc.elapsed().as_secs_f64() * 1000.0));
    line("loc.count", format!("{}", placed.len()));
    let mut kind_counts = [0usize; 15];
    let mut chk: u64 = 0;
    for p in &placed {
        kind_counts[LOCATIONS[p.cfg].kind as usize] += 1;
        chk = chk.wrapping_add((p.x.to_bits() as u64).wrapping_mul(0x9E3779B1))
                 .wrapping_add((p.y.to_bits() as u64).wrapping_mul(0x85EBCA77))
                 .wrapping_add(p.cfg as u64);
    }
    line("loc.kinds", kind_counts.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(","));
    line("loc.checksum", format!("{:016x}", chk));
    for p in &placed {
        let k = LOCATIONS[p.cfg].kind;
        if k == Kind::Boss || k == Kind::Spawn {
            line(&format!("loc.site.{}", LOCATIONS[p.cfg].label), format!("{},{}", p.x as i32, p.y as i32));
        }
    }
}
