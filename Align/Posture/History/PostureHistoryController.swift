import Combine
import Foundation

@MainActor
final class PostureHistoryController: ObservableObject {
    static let persistenceInterval: TimeInterval = 3_600

    @Published private(set) var loadResult: PostureHistoryLoadResult = .loading
    @Published private(set) var database = PostureHistoryDatabase(buckets: [])

    let store: PostureHistoryStore
    private var accumulator = PostureHistoryAccumulator()
    private var loadTask: Task<PostureHistoryLoadResult, Never>?
    private var persistTail: Task<Bool, Never>?
    private var operationTail: Task<Void, Never>?
    private var scheduledPersistence: Task<Void, Never>?
    private var hasUnpersistedChanges = false
    /// Monotone tombstone for persistence.  A completion from a generation
    /// older than an erase may finish its I/O, but it must not republish stale
    /// state into the actor after the erase has completed.
    private var persistenceGeneration: UInt64 = 0

    init(store: PostureHistoryStore = PostureHistoryStore()) {
        self.store = store
    }

    func loadIfNeeded() async {
        if loadResult != .loading || !database.buckets.isEmpty || !database.coverage.isEmpty { return }
        let generation = persistenceGeneration
        let task: Task<PostureHistoryLoadResult, Never>
        if let current = loadTask { task = current }
        else { task = Task { await store.load() }; loadTask = task }
        let result = await task.value
        loadTask = nil
        guard generation == persistenceGeneration else { return }
        loadResult = result
        database = result.database
        accumulator.restore(database, now: Date())
    }

    func record(_ observation: PostureHistoryObservation, now: Date = Date()) async {
        let generation = persistenceGeneration
        await loadIfNeeded()
        guard generation == persistenceGeneration else { return }
        accumulator.ingest(observation, now: now)
        schedulePersistence()
    }

    func recordCoverage(
        channel: PostureCoverageChannel,
        interval: DateInterval,
        now: Date = Date()
    ) async {
        let generation = persistenceGeneration
        await loadIfNeeded()
        guard generation == persistenceGeneration else { return }
        accumulator.ingestCoverage(channel: channel, interval: interval, now: now)
        schedulePersistence()
    }

    func recordControlEvent(_ event: PostureHistoryControlEvent, now: Date = Date()) async {
        let generation = persistenceGeneration
        await loadIfNeeded()
        guard generation == persistenceGeneration else { return }
        accumulator.recordControlEvent(event, now: now)
        schedulePersistence()
    }

    func recordScreenBreakEvent(_ event: ScreenBreakEvent, now: Date = Date()) async {
        let generation = persistenceGeneration
        await loadIfNeeded()
        guard generation == persistenceGeneration else { return }
        accumulator.recordScreenBreakEvent(event, now: now)
        schedulePersistence()
    }

    func enqueueScreenBreakEvent(_ event: ScreenBreakEvent, now: Date = Date()) {
        let previous = operationTail
        let generation = persistenceGeneration
        operationTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, generation == self.persistenceGeneration else { return }
            await self.recordScreenBreakEvent(event, now: now)
        }
    }

    /// File explicitement les écritures lancées depuis le runtime synchrone.
    /// `flushPending` peut alors garantir qu'une fermeture ne coupe pas la
    /// dernière durée, couverture ou transition en attente.
    func enqueue(_ observation: PostureHistoryObservation, now: Date = Date()) {
        let previous = operationTail
        let generation = persistenceGeneration
        operationTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, generation == self.persistenceGeneration else { return }
            await self.record(observation, now: now)
        }
    }

    func enqueueCoverage(
        channel: PostureCoverageChannel,
        interval: DateInterval,
        now: Date = Date()
    ) {
        let previous = operationTail
        let generation = persistenceGeneration
        operationTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, generation == self.persistenceGeneration else { return }
            await self.recordCoverage(channel: channel, interval: interval, now: now)
        }
    }

    func enqueueControlEvent(_ event: PostureHistoryControlEvent, now: Date = Date()) {
        let previous = operationTail
        let generation = persistenceGeneration
        operationTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, generation == self.persistenceGeneration else { return }
            await self.recordControlEvent(event, now: now)
        }
    }

    func flushPending() async {
        if let operationTail { await operationTail.value }
        scheduledPersistence?.cancel()
        scheduledPersistence = nil
        if hasUnpersistedChanges { await persist() }
        if let persistTail { _ = await persistTail.value }
    }

    func erase() async {
        persistenceGeneration &+= 1
        let eraseGeneration = persistenceGeneration
        let queuedOperation = operationTail
        operationTail = nil
        scheduledPersistence?.cancel()
        scheduledPersistence = nil
        hasUnpersistedChanges = false
        queuedOperation?.cancel()
        if let queuedOperation { await queuedOperation.value }
        if let loadTask {
            loadTask.cancel()
            _ = await loadTask.value
            self.loadTask = nil
        }
        let previous = persistTail
        previous?.cancel()
        let task = Task { [store] () -> Bool in
            if let previous { _ = await previous.value }
            do {
                try await store.erase()
                return true
            } catch {
                return false
            }
        }
        persistTail = task
        guard await task.value else {
            loadResult = .unavailable
            return
        }
        guard eraseGeneration == persistenceGeneration else { return }
        accumulator = .init()
        database = .init(buckets: [])
        loadResult = .empty
    }


    private func persist() async {
        guard hasUnpersistedChanges else { return }
        hasUnpersistedChanges = false
        database = accumulator.database
        let snapshot = database
        let generation = persistenceGeneration
        let previous = persistTail
        let task = Task { [store] () -> Bool in
            if let previous { _ = await previous.value }
            do {
                try await store.save(snapshot)
                return true
            } catch {
                return false
            }
        }
        persistTail = task
        let success = await task.value
        guard generation == persistenceGeneration else { return }
        if success {
            loadResult = .loaded(database)
        } else {
            hasUnpersistedChanges = true
            loadResult = .unavailable
        }
    }

    private func schedulePersistence() {
        hasUnpersistedChanges = true
        guard scheduledPersistence == nil else { return }
        let generation = persistenceGeneration
        scheduledPersistence = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.persistenceInterval * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, generation == self.persistenceGeneration else { return }
            self.scheduledPersistence = nil
            await self.persist()
        }
    }
}
