use std::time::Instant;
use worldgen::geo::{Biome, WorldGenerator};
use worldgen::locations::{self, Kind, LOCATIONS};
use worldgen::render::{Mode, Palette, TileRenderer};

fn main() {
    let seed_name = std::env::args().nth(1).unwrap_or_else(|| "Dedbtjdcv".into());

    let t0 = Instant::now();
    let wg = WorldGenerator::from_seed_name(&seed_name, 2);
    let pregen = t0.elapsed();
    println!("seed {:?} -> m_seed {}", seed_name, wg.seed);
    println!("  offsets: {} {} {} {} {}", wg.offset0, wg.offset1, wg.offset2, wg.offset3, wg.offset4);
    println!("  pregenerate(): {:?}", pregen);

    // One 512x512 tile covering the whole world (z=0, ~39 m/px).
    const N: usize = 512;
    let t1 = Instant::now();
    let mut counts = [0usize; 10];
    let span = 20000.0f32;
    for py in 0..N {
        for px in 0..N {
            let wx = (px as f32 / N as f32) * span - 10000.0;
            let wy = (py as f32 / N as f32) * span - 10000.0;
            if (wx * wx + wy * wy).sqrt() > 10000.0 { continue; }
            let b = wg.biome(wx, wy);
            let i = match b {
                Biome::None => 0, Biome::Meadows => 1, Biome::Swamp => 2,
                Biome::Mountain => 3, Biome::BlackForest => 4, Biome::Plains => 5,
                Biome::AshLands => 6, Biome::DeepNorth => 7, Biome::Ocean => 8,
                Biome::Mistlands => 9,
            };
            counts[i] += 1;
        }
    }
    let biome_tile = t1.elapsed();
    println!("  512x512 biome-only tile: {:?}", biome_tile);

    let t2 = Instant::now();
    let mut acc = 0.0f32;
    for py in 0..N {
        for px in 0..N {
            let wx = (px as f32 / N as f32) * span - 10000.0;
            let wy = (py as f32 / N as f32) * span - 10000.0;
            acc += wg.height(wx, wy);
        }
    }
    let height_tile = t2.elapsed();
    println!("  512x512 biome+height tile: {:?} (checksum {:.1})", height_tile, acc);

    // Real tile-render cost, per mode, at the tile size the app actually uses.
    {
        let mut tr = TileRenderer::new(WorldGenerator::from_seed_name(&seed_name, 2));
        for (name, mode) in [("Biome  ", Mode::Biome), ("Terrain", Mode::Terrain)] {
            tr.render(-2000.0, 2000.0, 4000.0, 256, mode, Palette::Classic);
            let t = Instant::now();
            for _ in 0..5 {
                tr.render(-2000.0, 2000.0, 4000.0, 256, mode, Palette::Classic);
            }
            println!("  render 256^2 {}: {:?}/tile", name, t.elapsed() / 5);
        }
    }

    {
        let mut tr = TileRenderer::new(WorldGenerator::from_seed_name(&seed_name, 2));
        let t = Instant::now();
        tr.render(-2500.0, 2500.0, 5000.0, 2048, Mode::Terrain, Palette::Classic);
        println!("  render 2048^2 patch texture: {:?}", t.elapsed());
    }

    let t3 = Instant::now();
    let pois = locations::generate(&wg);
    println!("  locations::generate(): {:?} -> {} placed", t3.elapsed(), pois.len());
    let mut by_kind: std::collections::BTreeMap<String, usize> = Default::default();
    for p in &pois {
        *by_kind.entry(format!("{:?}", LOCATIONS[p.cfg].kind)).or_default() += 1;
    }
    for (k, v) in &by_kind {
        println!("    {:<10} {}", k, v);
    }
    for p in &pois {
        let c = &LOCATIONS[p.cfg];
        if c.kind == Kind::Boss || c.kind == Kind::Trader || c.kind == Kind::Spawn {
            println!(
                "    {:<20} {:>7.0},{:>7.0}  dist {:>6.0}m  {:?}",
                c.label, p.x, p.y, (p.x * p.x + p.y * p.y).sqrt(), wg.biome(p.x, p.y)
            );
        }
    }

    let total: usize = counts.iter().sum();
    let names = ["None","Meadows","Swamp","Mountain","BlackForest","Plains","AshLands","DeepNorth","Ocean","Mistlands"];
    println!("  biome distribution inside the 10km world disc:");
    for (i, n) in names.iter().enumerate() {
        if counts[i] > 0 {
            println!("    {:<12} {:>6.2}%", n, counts[i] as f32 / total as f32 * 100.0);
        }
    }
}
