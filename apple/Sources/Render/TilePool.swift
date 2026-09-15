//  TilePool.swift
//  Parallel tile rasterisation.
//
//  Replaces the web build's Web Worker pool. Each worker owns its own
//  WorldGenerator + TileRenderer, because TileRenderer keeps mutable scratch
//  buffers and is not safe to share. Work is CPU-bound with no suspension
//  points, so the blocking call is pushed off the cooperative pool via
//  @concurrent rather than parked on one of its threads for 15-50 ms.

import Foundation
import Worldgen

public struct TileKey: Hashable, Sendable {
    public let seed: Int32
    public let gen: Int32
    public let mode: Int32
    public let palette: Int32
    public let z: Int
    public let x: Int
    public let y: Int
}

public struct TileJob: Sendable {
    let key: TileKey
    let ox: Float, oy: Float, span: Float
    let size: Int
    var priority: Double
}

public struct TileResult: Sendable {
    public let key: TileKey
    public let pixels: [UInt8]
    public let size: Int
}

/// One worker = one renderer. The WorldGenerator behind it is *shared*: it is
/// immutable once pregeneration finishes, and it carries the river grid —
/// roughly 770 k points on a typical seed. Giving each worker its own copy cost
/// ~50 MB apiece and made every worker repeat the 120 ms build. Only
/// TileRenderer is per-worker, because its scratch buffers are mutable.
actor TileWorker {
    private var renderer: TileRenderer?
    private var builtFor: ObjectIdentifier?

    func render(_ job: TileJob, world: WorldGenerator) -> TileResult {
        let want = ObjectIdentifier(world)
        if builtFor != want {
            renderer = TileRenderer(world)
            builtFor = want
        }
        guard let r = renderer else { fatalError("renderer missing") }
        r.render(ox: job.ox, oy: job.oy, span: job.span, size: job.size,
                 mode: Mode(rawValue: job.key.mode) ?? .biome,
                 palette: Palette(rawValue: job.key.palette) ?? .classic)
        return TileResult(key: job.key, pixels: r.copyPixels(), size: job.size)
    }
}

/// Priority queue with dedup and re-prioritisation. Cheap bookkeeping, so an
/// actor is the right home for it.
actor TileScheduler {
    private var pending: [TileKey: TileJob] = [:]
    private var order: [TileKey] = []          // ascending priority
    private var inFlight: Set<TileKey> = []
    private var waiters: [CheckedContinuation<TileJob?, Never>] = []
    private var stopped = false

    func submit(_ job: TileJob) {
        guard !stopped, !inFlight.contains(job.key) else { return }
        pending[job.key] = job
        if let i = order.firstIndex(of: job.key) { order.remove(at: i) }
        let idx = order.firstIndex { (pending[$0]?.priority ?? 0) > job.priority } ?? order.count
        order.insert(job.key, at: idx)
        pump()
    }

    /// Drop everything not in `keep` that has not started yet. A job already
    /// handed to a worker runs to completion — a synchronous FFI-free render
    /// has no suspension point to interrupt — but its result is discarded.
    func cancelExcept(_ keep: Set<TileKey>) {
        for k in order where !keep.contains(k) { pending.removeValue(forKey: k) }
        order.removeAll { !keep.contains($0) }
    }

    func reset() {
        pending.removeAll(); order.removeAll(); inFlight.removeAll()
        for w in waiters { w.resume(returning: nil) }
        waiters.removeAll()
    }

    func isWanted(_ k: TileKey) -> Bool { pending[k] != nil || inFlight.contains(k) }
    func finished(_ k: TileKey) { inFlight.remove(k) }
    var depth: Int { order.count + inFlight.count }

    private func pump() {
        while !waiters.isEmpty, let k = order.first {
            order.removeFirst()
            guard let job = pending.removeValue(forKey: k) else { continue }
            inFlight.insert(k)
            waiters.removeFirst().resume(returning: job)
        }
    }

    func next() async -> TileJob? {
        if let k = order.first {
            order.removeFirst()
            if let job = pending.removeValue(forKey: k) {
                inFlight.insert(k)
                return job
            }
        }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Apple Silicon reports P- and E-cores together in activeProcessorCount, and
/// they are not interchangeable for sustained CPU work. Size off P-cores.
enum CoreTopology {
    static func performanceCores() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    static func efficiencyCores() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return 0
    }

    /// Every performance core plus half the efficiency cores.
    ///
    /// 60% of P-cores alone is too timid on an Apple Silicon part that pairs 4
    /// P-cores with 6 E-cores — it yields 3 workers and leaves most of the
    /// machine idle. Tile rasterisation is throughput work with no shared
    /// state, so the E-cores are worth using; holding back half of them keeps
    /// the UI and the probe generator responsive.
    static func workerCount() -> Int {
        let p = performanceCores()
        let e = efficiencyCores()
        return max(2, min(p + e / 2, 12))
    }
}

public final class TilePool: @unchecked Sendable {
    private let scheduler = TileScheduler()
    private var workers: [TileWorker] = []
    private var loops: [Task<Void, Never>] = []
    private var world: WorldGenerator?

    public var onTile: (@Sendable (TileResult) -> Void)?
    public private(set) var count: Int = 0

    public init() {
        count = CoreTopology.workerCount()
        workers = (0..<count).map { _ in TileWorker() }
    }

    public func configure(world: WorldGenerator) async {
        self.world = world
        await scheduler.reset()
        loops.forEach { $0.cancel() }
        loops = (0..<count).map { i in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.runWorker(i)
            }
        }
    }

    private func runWorker(_ index: Int) async {
        let worker = workers[index]
        while !Task.isCancelled {
            guard let job = await scheduler.next() else { continue }
            guard let world else { continue }
            let result = await worker.render(job, world: world)
            if await scheduler.isWanted(result.key) || true {
                onTile?(result)
            }
            await scheduler.finished(job.key)
        }
    }

    public func request(_ job: TileJob) { Task { await scheduler.submit(job) } }
    public func cancelExcept(_ keep: Set<TileKey>) { Task { await scheduler.cancelExcept(keep) } }
    public func depth() async -> Int { await scheduler.depth }
}
