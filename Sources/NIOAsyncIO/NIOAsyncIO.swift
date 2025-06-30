import Foundation
@testable import NIOCore // FIXME: SM: NOW: Can't build release build until this @testible is remove
import Atomics
import _Concurrency // for @TaskLocal

// MARK: - Common helpers & errors -

/// Mirror of NIOPosix’s thread‑pool shutdown error so callers compile unchanged.
public enum NIOThreadPoolError: Error { case shutdown }

/// Task‑local key that stores the UUID of the `AsyncEventLoop` currently
/// executing.  Lets us answer `inEventLoop` without private APIs.
@available(macOS 13, *)
private enum _CurrentEventLoopKey { @TaskLocal static var id: UUID? }

// MARK: - AsyncEventLoop -

/// A single‑threaded `EventLoop` implemented solely with Swift Concurrency.
@available(macOS 13, *)
public final class AsyncEventLoop: EventLoop, @unchecked Sendable {
    private actor _SerialExecutor {
        /// We use this actor to make serialized FIFO entry
        /// into the event loop. This is a shared instance between all
        /// event loops, so it is important that we ONLY use it to enqueue
        /// jobs that come from a non-isolated context.
        @globalActor
        private struct _IsolatingSerialEntryActor { // FIXME: SM: Try out the pattern here instead: https://swiftwithmajid.com/2024/03/12/global-actors-in-swift/
            actor ActorType {}
            static let shared = ActorType()
        }

        fileprivate typealias OrderIntegerType = UInt64

        private struct ScheduledJob {
            let deadline: NIODeadline
            let order: OrderIntegerType
            let job: () -> Void
        }
        private var scheduledQueue: [ScheduledJob] = []
        private var nextScheduledItemOrder: OrderIntegerType = 0

        private var currentlyRunningExecutorTask: Task<Void, Never>?
        private var taskQueue: [() -> Void] = [] // TODO: SM: Rename to jobQueue

        let loopID: UUID
        init(loopID: UUID) {
            self.loopID = loopID
        }

        // Insert and sort by (deadline, order)
        fileprivate nonisolated func schedule(at deadline: NIODeadline, job: @escaping () -> Void) {
            Task { @_IsolatingSerialEntryActor [job] in
                // ^----- Ensures FIFO entry from nonisolated contexts
                await _schedule(at: deadline, job: job)
            }
        }

        private func _schedule(at deadline: NIODeadline, job: @escaping () -> Void) {
            let order = nextScheduledItemOrder
            nextScheduledItemOrder += 1
            scheduledQueue.append(ScheduledJob(deadline: deadline, order: order, job: job))
            scheduledQueue.sort {
                if $0.deadline != $1.deadline {
                    return $0.deadline < $1.deadline
                }
                return $0.order < $1.order
            }

            runNextJobIfNeeded()
        }

        nonisolated func enqueue(_ job: @escaping () -> Void) {
            Task { @_IsolatingSerialEntryActor [job] in
                // ^----- Ensures FIFO entry from nonisolated contexts
                await _enqueue(job)
            }
        }

        private func _enqueue(_ job: @escaping () -> Void) {
            taskQueue.append(job)
            runNextJobIfNeeded()
        }

        private func runNextJobIfNeeded() {
            // Stop if both queues are empty.
            if taskQueue.isEmpty && scheduledQueue.isEmpty { return }

            // No need to start if a task is already running
            guard currentlyRunningExecutorTask == nil else { return }

            currentlyRunningExecutorTask = Task {
                // When we're done running the next job,
                // we'll run a task for the next job if needed.
                defer {
                    // When we're done, clear the reference to the task
                    currentlyRunningExecutorTask = nil
                    // And make sure to run the next job
                    runNextJobIfNeeded()
                }

                await _CurrentEventLoopKey.$id.withValue(loopID) {
                    // 1. Run all jobs currently in taskQueue
                    for job in taskQueue {
                        // Run the job
                        job()

                        // Remove the job from the queue
                        taskQueue.removeFirst()

                        await Task.yield()
                    }

                    // 2. Run all jobs in scheduledQueue past the due date
                    //
                    // FIFO is more important than the precision of the scheduled time
                    // The queue is pre-sorted in the desired order
                    let now = NIODeadline.now()
                    for scheduled in scheduledQueue {
                        guard now >= scheduled.deadline else {
                            // The queue is sorted by deadline, so as we reach items past now,
                            // we can stop iterating for efficiency
                            break
                        }

                        // Run the job
                        scheduled.job()

                        // Remove the job from the queue
                        scheduledQueue.removeFirst()

                        await Task.yield()
                    }

                    // 3. Run next scheduled job near the expected due date time

                    // TODO: SM: Write unit test for following line, deadlines in the past should execute immediately,
                    // (and not crash because of subtraction past 0 on an unsigned int).
                    if let nextScheduledTask = scheduledQueue.first {
                        let nanoseconds: UInt64 = Self.flooringSubtraction(
                            nextScheduledTask.deadline.uptimeNanoseconds,
                            now.uptimeNanoseconds
                        )
                        let handle = Task {
                            try? await Task.sleep(for: .nanoseconds(nanoseconds), tolerance: .nanoseconds(0))
                            runNextJobIfNeeded()
                        }
                    }
                }
            }
        }

        private static func flooringSubtraction(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (partial, overflow) = lhs.subtractingReportingOverflow(rhs)
            guard !overflow else { return UInt64.min }
            return partial
        }
    }

    private let _id = UUID() // unique identifier
    private let executor: _SerialExecutor

    public init() {
        self.executor = _SerialExecutor(loopID: _id)
    }

    // MARK: - EventLoop basics -

    public var inEventLoop: Bool {
        return _CurrentEventLoopKey.id == _id
    }

    @_disfavoredOverload
    public func execute(_ task: @escaping () -> Void) {
        executor.enqueue(task)
    }

    // MARK: - Promises / Futures -

    public func makePromise<T>(of type: T.Type = T.self,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> EventLoopPromise<T> {
        .init(eventLoop: self, file: file, line: line)
    }

    public func makeSucceededFuture<T>(_ value: T) -> EventLoopFuture<T> {
        let p = makePromise(of: T.self); p.succeed(value); return p.futureResult
    }

    public func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        let p = makePromise(of: T.self); p.fail(error); return p.futureResult
    }

    // MARK: - Submitting work -

    public func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        let promise = makePromise(of: T.self)
        executor.enqueue {
            do {
                let value = try task()
                promise.succeed(value)
            }
            catch { promise.fail(error) }
        }
        return promise.futureResult
    }

    public func flatSubmit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        submit(task)
    }

    // MARK: - Scheduling -

    /// NOTE:
    ///
    /// Timing for execute vs submit vs schedule:
    ///
    /// Tasks scheduled via `execute` or `submit` are appended to the back of the event loop's task queue
    /// and are executed serially in FIFO order. Scheduled tasks (e.g., via `schedule(deadline:)`) are
    /// placed in a timing wheel and, when their deadline arrives, are enqueued at the back of the main
    /// queue after any already-pending work. This means that if the event loop is backed up, a scheduled
    /// task may execute slightly after its scheduled time, as it must wait for previously enqueued tasks
    /// to finish. Scheduled tasks never preempt or jump ahead of already-queued immediate work.
    public func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        let promise = makePromise(of: T.self)

        executor.schedule(at: deadline) {
            do {
                promise.succeed(try task())
            } catch {
                promise.fail(error)
            }
        }

        return Scheduled(promise: promise) {
            // TODO: SM: Figure out how to properly cancel tasks.
            // Tricky because this code section is non-isolated.
            // Might have to track scheduled task id's separate, and
            // feed them into schedule call. Then use that same id
            // to cancel here

            // TODO: SM: Add unit test for cancelling scheduled task via promise.
        }
    }

    public func scheduleTask<T>(in delay: TimeAmount,
                                _ task: @escaping () throws -> T) -> Scheduled<T> {
        scheduleTask(deadline: .now() + delay, task)
    }

    public func closeGracefully() async {}

    public func next() -> EventLoop {
        self
    }
    public func any()  -> EventLoop {
        self
    }

    #if canImport(Dispatch)
    public func shutdownGracefully(queue _: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        Task { callback(nil) } // TODO: SM: Probably need blocking call mechanism here.
    }
    #endif

    public func syncShutdownGracefully() throws {}

    #if !canImport(Dispatch)
    /// Must crash if it's not safe to call `syncShutdownGracefully` in the current context.
    ///
    /// This method is a debug hook that can be used to override the behaviour of `syncShutdownGracefully`
    /// when called. By default it does nothing.
    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        // TODO: SM: Implement me
    }
    #endif
}

// =============================================================================
// MARK: - MultiThreadedEventLoopGroup

@available(macOS 13, *)
public final class MultiThreadedEventLoopGroup: EventLoopGroup, @unchecked Sendable {
    private let loops: [AsyncEventLoop]
    private let counter = ManagedAtomic<Int>(0)

    public init(numberOfThreads: Int = System.coreCount) {
        precondition(numberOfThreads > 0, "thread count must be positive")
        self.loops = (0..<numberOfThreads).map { _ in AsyncEventLoop() }
    }

    // EventLoopGroup --------------------------------------------------------
    public func next() -> EventLoop {
        loops[counter.loadThenWrappingIncrement(ordering: .sequentiallyConsistent) % loops.count]
    }

    public func any() -> EventLoop { loops[0] }

    public func makeIterator() -> NIOCore.EventLoopIterator {
        .init(self.loops.map { $0 as EventLoop })
    }

    #if canImport(Dispatch)
    // NOTE: SM: We compile this out of the protocol for wasm, so we probably don't need to support this
    public func shutdownGracefully(queue _: DispatchQueue, _ cb: @escaping (Error?) -> Void) {
        Task {
            for loop in loops { await loop.closeGracefully() }
            cb(nil)
        }
    }
    #endif // canImport(Dispatch)

    public func syncShutdownGracefully() throws { // SM: This is WRONG. Not a sync API
        Task {
            await loops.concurrentForEach { loop in await loop.closeGracefully() }
        }
    }

    public static let singleton = MultiThreadedEventLoopGroup()

    #if !canImport(Dispatch)
    /// Must crash if it's not safe to call `syncShutdownGracefully` in the current context.
    ///
    /// This method is a debug hook that can be used to override the behaviour of `syncShutdownGracefully`
    /// when called. By default it does nothing.
    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        // TODO: SM: Implement me
    }
    #endif
}

// =============================================================================
// MARK: - NIOAsyncThreadPool

@available(macOS 10.15, *)
extension NIOThreadPool {
    /// Discrete life‑cycle states of a submitted work‑item.
    public enum WorkItemState: Sendable {
        case queued, running, completed, cancelled, failed(Error)
    }

    // TODO: SM: Should this WorkItem be moved to _SerialExecutor

    /// Handle returned to the caller representing the submitted work.
    public final class WorkItem: @unchecked Sendable { // TODO: SM: Should/can this be a struct?
        public let id: UInt64
        private let stateBits = ManagedAtomic<Int>(0) // 0‑queued 1‑running 2‑completed 3‑cancelled 4‑failed


        init(id: UInt64) { self.id = id }

        /// Current state (computed from atomic storage)
        public var state: WorkItemState {
            switch stateBits.load(ordering: .sequentiallyConsistent) {
            case 0: return .queued
            case 1: return .running
            case 2: return .completed
            case 3: return .cancelled
            default: return .failed(NIOThreadPoolError.shutdown)
            }
        }

        fileprivate func transition(to new: WorkItemState) {
            switch new {
            case .queued:    _ = stateBits.store(0, ordering: .sequentiallyConsistent)
            case .running:   _ = stateBits.store(1, ordering: .sequentiallyConsistent)
            case .completed: _ = stateBits.store(2, ordering: .sequentiallyConsistent)
            case .cancelled: _ = stateBits.store(3, ordering: .sequentiallyConsistent)
            case .failed(_):
                _ = stateBits.store(4, ordering: .sequentiallyConsistent)
            }
        }

        /// Best‑effort cancellation.  Only flips state; does not pre‑empt the Task.
        public func cancel() { transition(to: .cancelled) }
    }
}

/// Drop‑in stand‑in for `NIOThreadPool`, powered by Swift Concurrency.
@available(macOS 10.15, *)
public final class NIOThreadPool: @unchecked Sendable {
    private let shutdownFlag         = ManagedAtomic<Bool>(false)
    private let nextID               = ManagedAtomic<UInt64>(0)

    public init(numberOfThreads _: Int? = nil) {}
    public func start() {}

    // MARK: ‑ Private helpers -
    private func makeWorkItem() -> NIOThreadPool.WorkItem {
        let id = nextID.loadThenWrappingIncrement(ordering: .sequentiallyConsistent)
        return .init(id: id)
    }

    // MARK: ‑ Public API -

    /// Original NIO API: returns only the future.
    public func submit<T>(on eventLoop: EventLoop, _ fn: @escaping () throws -> T) -> EventLoopFuture<T> {
        submit(on: eventLoop, fn).future
    }

    /// Overload that also returns a `WorkItem` handle (used by sqlite‑nio).
    private func submit<T>(on eventLoop: EventLoop, _ fn: @escaping () throws -> T) -> (future: EventLoopFuture<T>, work: WorkItem) {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return (eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown), makeWorkItem())
        }

        let item = makeWorkItem()
        item.transition(to: .queued)

        let future = eventLoop.submit {
            item.transition(to: .running)
            do {
                let value = try fn()
                item.transition(to: .completed)
                return value
            } catch {
                item.transition(to: .failed(error))
                throw error
            }
        }
        return (future, item)
    }

    /// Async helper mirroring `runIfActive` without an EventLoop context.
    public func runIfActive<T>(_ body: @escaping () throws -> T) async throws -> T {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else { throw NIOThreadPoolError.shutdown }
        return try await Task { try body() }.value
    }

    /// Event‑loop variant returning only the future.
    public func runIfActive<T>(eventLoop: EventLoop, _ body: @escaping () throws -> T) -> EventLoopFuture<T> {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown)
        }
        return eventLoop.submit { try body() }
    }

    /// Variant returning both future and WorkItem.
    public func runIfActive<T>(eventLoop: EventLoop, _ body: @escaping () throws -> T) -> (future: EventLoopFuture<T>, work: WorkItem) {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return (eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown), makeWorkItem())
        }
        let item = makeWorkItem(); item.transition(to: .queued)
        let fut = eventLoop.submit {
            item.transition(to: .running)
            do {
                let v = try body(); item.transition(to: .completed); return v
            } catch {
                item.transition(to: .failed(error)); throw error
            }
        }
        return (fut, item)
    }

    // Cancellation -----------------------------------------------------------
    public func cancel(_ work: WorkItem) {
        work.cancel()
    }

    // Lifecycle --------------------------------------------------------------
    public func shutdownGracefully(_ cb: @escaping (Error?) -> Void = { _ in } ) {
        shutdownFlag.store(true, ordering: .sequentiallyConsistent)
        cb(nil)
    }

    public static let singleton: NIOThreadPool = {
        let pool = NIOThreadPool(); pool.start(); return pool
    }()
}

// =============================================================================
// MARK: - Utilities

@available(macOS 10.15, *)
@_spi(NIOAsyncInternal) extension Array {
    /// Concurrent `forEach` helper powered by Swift Concurrency (non‑throwing).
    func concurrentForEach(_ body: @escaping (Element) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for element in self {
                group.addTask { await body(element) }
            }
            await group.waitForAll()
        }
    }
}

// TODO: SM: NOW: Lot's of cleanup here, split to files, re-implement "tests" as real Swift Tests, etc.
// Squash everything to first commit in nio, feat: Add new async IO module to…
