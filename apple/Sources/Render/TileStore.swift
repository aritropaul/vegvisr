//  TileStore.swift
//  Tiles that survive the process.
//
//  A tile is a pure function of seed:gen:mode:palette:z/x/y — the generator is
//  deterministic, so a tile computed once is correct forever. Until now they
//  lived only in TextureCache, which meant every launch regenerated terrain
//  this machine had already produced. Arriving at a level for the first time
//  costs ~65 rasterisations at 15-50 ms each; from disk it costs ~65 reads and
//  an inflate that runs at memcpy speed.
//
//  The web build has had this since store.ts, backed by the Cache API. Same
//  idea here with the image codec removed: PNG would mean a CoreGraphics
//  round-trip on both sides, whereas LZFSE runs near a gigabyte a second and
//  leaves the payload as exactly the pixel block the texture upload wants. The
//  renderer's flat biome regions are also unusually compressible, so the cost
//  of not using PNG is smaller than it sounds.
//
//  Everything fails soft. The caches directory is purgeable at the OS's
//  discretion, a file can be half-written if the app was killed mid-save, and
//  a format change orphans the lot. Any miss or bad read just generates the
//  tile the way it always did.

import Foundation

final class TileStore: @unchecked Sendable {
    /// Bumped when the on-disk layout or the pixel format changes, which
    /// orphans the old directory rather than trying to migrate it.
    private static let version = "v1"
    private static let magic: UInt32 = 0x5647_5431   // "VGT1"

    private let dir: URL?
    private let budget: Int
    private let lock = NSLock()

    /// What the last scan (plus every save since) says is on disk. This exists
    /// so the render path can ask *synchronously* whether a tile is worth
    /// reading — awaiting storage per tile, per frame, would be worse than
    /// regenerating.
    private var present: Set<TileKey> = []
    private var loading: Set<TileKey> = []
    private var saving: Set<TileKey> = []
    private var bytes = 0
    /// Whether the index is usable yet. Until it is, a caller cannot tell a
    /// tile it owns from one it has never generated.
    private var ready = false

    /// Reads beat writes: a read is blocking something on screen, a write is
    /// housekeeping. Both are serial — a 256 KB read plus inflate is a few
    /// tenths of a millisecond, so even a whole level arrives inside a frame,
    /// and serial queues cannot explode GCD's thread pool the way a semaphore
    /// over a concurrent queue can.
    private let readQ = DispatchQueue(label: "tilestore.read", qos: .userInitiated)
    private let writeQ = DispatchQueue(label: "tilestore.write", qos: .utility)

    var indexReady: Bool { lock.withLock { ready } }

    init(budgetMB: Int = 512) {
        budget = budgetMB * 1024 * 1024
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        // On macOS the caches URL is the shared ~/Library/Caches, so the
        // bundle id is ours to add; on iOS it is already inside the container
        // and the extra component is harmless.
        let owner = Bundle.main.bundleIdentifier ?? "dev.aritropaul.vegvisr"
        let d = base?
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("tiles-\(TileStore.version)", isDirectory: true)
        if let d {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        dir = (d.map { fm.fileExists(atPath: $0.path) } == true) ? d : nil
        guard dir != nil else { ready = true; return }
        // On readQ, not writeQ: the first frame genuinely waits on this, and
        // `afterScan` chains behind it on the same queue.
        readQ.async { [weak self] in self?.scanKeys() }
    }

    // MARK: - Naming

    /// Every key component, flattened. `-` appears in negative seeds and is
    /// fine in a filename; nothing else here can produce a separator.
    private func name(_ k: TileKey) -> String {
        "\(k.seed)_\(k.gen)_\(k.mode)_\(k.palette)_\(k.z)_\(k.x)_\(k.y).t"
    }

    private func key(fromName n: String) -> TileKey? {
        guard n.hasSuffix(".t") else { return nil }
        let f = n.dropLast(2).split(separator: "_")
        guard f.count == 7,
              let seed = Int32(f[0]), let gen = Int32(f[1]),
              let mode = Int32(f[2]), let pal = Int32(f[3]),
              let z = Int(f[4]), let x = Int(f[5]), let y = Int(f[6]) else { return nil }
        return TileKey(seed: seed, gen: gen, mode: mode, palette: pal, z: z, x: x, y: y)
    }

    // MARK: - Index

    /// Names only — one readdir, no per-file stat. Statting a few thousand
    /// tiles costs tens of milliseconds, and measured on a 2 069-tile cache
    /// that was long enough for the renderer to start generating sixteen tiles
    /// it already had on disk. Everything the render path needs is in the
    /// filename.
    private func scanKeys() {
        guard let dir else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            lock.withLock { ready = true }
            return
        }
        var found = Set<TileKey>()
        for n in names {
            if let k = key(fromName: n) { found.insert(k) }
        }
        lock.withLock {
            present.formUnion(found)
            ready = true
        }
        // Sizes are only needed to seed the budget, so they go to the write
        // queue where nothing on screen is waiting for them.
        writeQ.async { [weak self] in self?.scanSizes(names) }
    }

    private func scanSizes(_ names: [String]) {
        guard let dir else { return }
        let fm = FileManager.default
        var total = 0
        for n in names {
            let p = dir.appendingPathComponent(n).path
            if let a = try? fm.attributesOfItem(atPath: p), let sz = a[.size] as? Int {
                total += sz
            }
        }
        lock.withLock { bytes += total }
        trimIfNeeded()
    }

    /// Whether reading is worth trying. True while a read is already in flight,
    /// so the render path keeps waiting on disk instead of also queueing a
    /// worker for the same tile — firing both would generate a tile we are
    /// milliseconds from having.
    func has(_ k: TileKey) -> Bool {
        lock.withLock { present.contains(k) || loading.contains(k) }
    }

    // MARK: - Read

    /// Hand back a stored tile, or nothing. De-duplicated, so calling this
    /// every frame for the same key costs one read.
    func load(_ k: TileKey, _ done: @escaping @Sendable (TileResult) -> Void) {
        guard let dir else { return }
        let go = lock.withLock { () -> Bool in
            guard !loading.contains(k) else { return false }
            loading.insert(k)
            return true
        }
        guard go else { return }

        readQ.async { [weak self] in
            guard let self else { return }
            let url = dir.appendingPathComponent(self.name(k))
            var result: TileResult?
            if let raw = try? Data(contentsOf: url, options: .mappedIfSafe),
               raw.count > 8 {
                let header = raw.withUnsafeBytes { p -> (UInt32, UInt32) in
                    (p.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                     p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                }
                if header.0 == TileStore.magic {
                    let size = Int(header.1)
                    let body = raw.subdata(in: 8..<raw.count) as NSData
                    if let flat = try? body.decompressed(using: .lzfse) as Data,
                       flat.count == size * size * 4 {
                        result = TileResult(key: k, pixels: [UInt8](flat), size: size)
                    }
                }
            }
            self.lock.withLock {
                self.loading.remove(k)
                // A file that will not read is not on disk as far as anyone
                // here is concerned, so the next frame asks a worker.
                if result == nil { self.present.remove(k) }
            }
            if result == nil { try? FileManager.default.removeItem(at: url) }
            if let result { done(result) }
        }
    }

    // MARK: - Write

    /// Persist a freshly generated tile. Off the render path deliberately:
    /// compressing 256 KB costs a fraction of a millisecond but the write
    /// itself is I/O, and a tile that never lands only costs a regeneration
    /// some other day.
    func save(_ r: TileResult) {
        guard let dir else { return }
        let go = lock.withLock { () -> Bool in
            guard !present.contains(r.key), !saving.contains(r.key) else { return false }
            saving.insert(r.key)
            return true
        }
        guard go else { return }

        writeQ.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.saving.remove(r.key) } }
            let src = Data(r.pixels) as NSData
            guard let packed = try? src.compressed(using: .lzfse) as Data else { return }
            var blob = Data(capacity: packed.count + 8)
            withUnsafeBytes(of: TileStore.magic.littleEndian) { blob.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(r.size).littleEndian) { blob.append(contentsOf: $0) }
            blob.append(packed)
            let url = dir.appendingPathComponent(self.name(r.key))
            // Atomic, so a kill mid-write leaves the old file or none, never a
            // truncated one that reads as a corrupt tile.
            guard (try? blob.write(to: url, options: .atomic)) != nil else { return }
            self.lock.withLock {
                self.present.insert(r.key)
                self.bytes += blob.count
            }
            self.trimIfNeeded()
        }
    }

    // MARK: - Budget

    /// Evict oldest-written first, not least-recently-used: tracking access
    /// would mean touching a file's mtime on every read, which turns each
    /// cache hit into a write. Write order is a fair proxy for a cache whose
    /// contents only ever grow as you explore.
    private func trimIfNeeded() {
        let over = lock.withLock { bytes > budget }
        guard over, let dir else { return }
        writeQ.async { [weak self] in
            guard let self else { return }
            let props: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: props, options: [.skipsHiddenFiles])
            else { return }
            let aged = items.compactMap { u -> (URL, Int, Date)? in
                guard let v = try? u.resourceValues(forKeys: Set(props)),
                      let s = v.fileSize, let d = v.contentModificationDate else { return nil }
                return (u, s, d)
            }.sorted { $0.2 < $1.2 }

            var total = aged.reduce(0) { $0 + $1.1 }
            // Trim to 85% so this runs in batches rather than on every save
            // once the cache is full.
            let target = Int(Double(self.budget) * 0.85)
            var dropped: [TileKey] = []
            var freed = 0
            for (u, size, _) in aged where total > target {
                guard (try? FileManager.default.removeItem(at: u)) != nil else { continue }
                if let k = self.key(fromName: u.lastPathComponent) { dropped.append(k) }
                total -= size
                freed += size
            }
            self.lock.withLock {
                for k in dropped { self.present.remove(k) }
                self.bytes = max(0, self.bytes - freed)
            }
        }
    }

    /// Everything stored for one world, coarsest level first, capped. Coarse
    /// tiles earn their place twice over: they are what the opening view shows
    /// and what stands in for every finer tile that has not arrived.
    func storedKeys(seed: Int32, gen: Int32, mode: Int32, palette: Int32,
                    maxZ: Int, limit: Int) -> [TileKey] {
        lock.withLock {
            present
                .filter {
                    $0.seed == seed && $0.gen == gen
                        && $0.mode == mode && $0.palette == palette && $0.z <= maxZ
                }
                // Coarse first, then centre-out. Both halves matter once the
                // cap bites: the coarse levels are the ancestors everything
                // finer falls back to, and the map opens centred on the world
                // origin, so the middle of a level is what gets looked at.
                .sorted { a, b in
                    if a.z != b.z { return a.z < b.z }
                    func r2(_ k: TileKey) -> Int {
                        let c = (1 << k.z) / 2
                        let dx = k.x - c, dy = k.y - c
                        return dx * dx + dy * dy
                    }
                    let (ra, rb) = (r2(a), r2(b))
                    if ra != rb { return ra < rb }
                    return a.y != b.y ? a.y < b.y : a.x < b.x
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// Run something once the index exists. The index is built on `writeQ`, so
    /// queueing behind it is the whole mechanism — no flag, no polling, and no
    /// way for a caller to look at an empty index and conclude nothing is
    /// stored.
    func afterScan(_ body: @escaping @Sendable () -> Void) {
        readQ.async(execute: body)
    }

    /// Diagnostics for the tile trace.
    var stats: (tiles: Int, mb: Double) {
        lock.withLock { (present.count, Double(bytes) / 1_048_576.0) }
    }
}
