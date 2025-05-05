import Foundation
@testable import NIOCore
import Atomics
import _Concurrency // for @TaskLocal

// =============================================================================
// MARK: - Common helpers & errors

/// Mirror of NIOPosix’s thread‑pool shutdown error so callers compile unchanged.
public enum NIOThreadPoolError: Error { case shutdown }

/// Task‑local key that stores the UUID of the `AsyncEventLoop` currently
/// executing.  Lets us answer `inEventLoop` without private APIs.
@available(macOS 10.15, *)
private enum _CurrentEventLoopKey { @TaskLocal static var id: UUID? }

// =============================================================================
// MARK: - AsyncEventLoop

/// A single‑threaded `EventLoop` implemented solely with Swift Concurrency.
@available(macOS 10.15, *)
public final class AsyncEventLoop: EventLoop, @unchecked Sendable {
    // ---------------------------------------------------------------------
    // Internals
    private actor _SerialExecutor {
        let loopID: UUID
        init(loopID: UUID) { self.loopID = loopID }
        nonisolated func enqueue(_ job: @escaping () -> Void) {
            _CurrentEventLoopKey.$id.withValue(loopID) { Task { job() } }
        }
    }

    private let _id = UUID()                    // unique identifier
    private let executor: _SerialExecutor

    public init() { self.executor = _SerialExecutor(loopID: _id) }

    // ---------------------------------------------------------------------
    // EventLoop basics
    public var inEventLoop: Bool { _CurrentEventLoopKey.id == _id }

    public func execute(_ task: @escaping () -> Void) { executor.enqueue(task) }

    // Promises / Futures ----------------------------------------------------
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

    // Submitting work -------------------------------------------------------
    public func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        let promise = makePromise(of: T.self)
        executor.enqueue {
            do { promise.succeed(try task()) }
            catch { promise.fail(error) }
        }
        return promise.futureResult
    }

    public func flatSubmit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        submit(task)
    }

    // Scheduling ------------------------------------------------------------
    public func scheduleTask<T>(deadline: NIODeadline,
                                _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise = makePromise(of: T.self)
        let nanos = deadline.uptimeNanoseconds - NIODeadline.now().uptimeNanoseconds
        let handle = Task {
            try await Task.sleep(nanoseconds: nanos)
            do { promise.succeed(try task()) }
            catch { promise.fail(error) }
        }
        return Scheduled(promise: promise) { handle.cancel() }
    }

    public func scheduleTask<T>(in delay: TimeAmount,
                                _ task: @escaping () throws -> T) -> Scheduled<T> {
        scheduleTask(deadline: .now() + delay, task)
    }

    // Shutdown --------------------------------------------------------------
    public func closeGracefully() async {}

    // EventLoopGroup single‑loop compatibility ------------------------------
    public func next() -> EventLoop { self }
    public func any()  -> EventLoop { self }

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

@available(macOS 10.15, *)
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

    /// Handle returned to the caller representing the submitted work.
    public final class WorkItem: @unchecked Sendable {
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

/// Drop‑in stand‑in for `NIOThreadPool`, powered by detached Tasks.
@available(macOS 10.15, *)
public final class NIOThreadPool: @unchecked Sendable {
    private let shutdownFlag         = ManagedAtomic<Bool>(false)
    private let nextID               = ManagedAtomic<UInt64>(0)

    public init(numberOfThreads _: Int? = nil) {}
    public func start() {}

    // MARK: ‑ Private helpers -------------------------------------------------
    private func makeWorkItem() -> NIOThreadPool.WorkItem {
        let id = nextID.loadThenWrappingIncrement(ordering: .sequentiallyConsistent)
        return .init(id: id)
    }

    // MARK: ‑ Public API ------------------------------------------------------

    /// Original NIO API: returns only the future.
    public func submit<T>(on eventLoop: EventLoop, _ fn: @escaping () throws -> T) -> EventLoopFuture<T> {
        submit(on: eventLoop, fn).future
    }

    /// Overload that also returns a `WorkItem` handle (used by sqlite‑nio).
    private func submit<T>(on eventLoop: EventLoop, _ fn: @escaping () throws -> T) -> (future: EventLoopFuture<T>, work: WorkItem) {
        // print("SM: 🎃🔵")
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return (eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown), makeWorkItem())
        }

        let item = makeWorkItem()
        item.transition(to: .queued)

        let future = eventLoop.submit {
            // print("SM: 🍊🔵")
            item.transition(to: .running)
            do {
                let value = try fn()
                item.transition(to: .completed)
                return value
            } catch {
                item.transition(to: .failed(error))
                throw error
            }
            // print("SM: 🍊🔵")
        }
        // print("SM: 🎃🟢")
        return (future, item)
    }

    /// Async helper mirroring `runIfActive` without an EventLoop context.
    public func runIfActive<T>(_ body: @escaping () throws -> T) async throws -> T {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else { throw NIOThreadPoolError.shutdown }
        return try await Task.detached { try body() }.value
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
        // print("SM: SHUTDOWN START")
        shutdownFlag.store(true, ordering: .sequentiallyConsistent)
        cb(nil)

        // print("SM: SHUTDOWN STOP")
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

// TODO: SM: Lot's of cleanup here, split to files, re-implement, etc. Squash everything to first commit in nio, feat: Add new async IO
// module to…


/*

 SM: A
 SM: 🔵
 SM: 🟢
 SM: D
 SM: B
 SM: B.1
 SM: B.2
 SM: B.3
 SM: B.4
 SM: B.5.loop
 SM: C
 SM: B.6.1
 SM: B.6.2
 // ERROR: await finishes before all promises filled

 SM: A
 SM: 🔵
 SM: 🟢
 SM: D
 SM: B
 SM: B.1
 SM: B.2
 SM: B.3
 SM: B.4
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: B.6.2
 SM: B.5.loop
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: C
 SM: B.6.1
 SM: B.6.2

 */


/*
 SM: =============================== ❤️
 SM: =============================== 🧡
 SM: 🦄🔵
 SM: A
 SM: 🎃🔵
 SM: 🎃🟢
 SM: D
 SM: 🍊🔵
 SM: B
 SM: B.1
 SM: B.2
 SM: B.3
 SM: B.4
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: C
 SM: 🦄🟢
 SM: B.6.2
 SM: 🟣🟢
 SM: =============================== 💛
 SM: =============================== 💙
 SM: 🦄🔵
 SM: A
 SM: 🎃🔵
 SM: 🎃🟢
 SM: D
 SM: 🍊🔵
 SM: B
 SM: B.1
 SM: B.2
 SM: B.3
 SM: B.4
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: 🟣🟢
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: B.6.2
 SM: 🟣🔵
 SM: 🟣🟢
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: B.6.1
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🟢
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🔵
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: B.6.1
 SM: 🟣🔵
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🟢
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.2
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.6.1
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: 🟣🔵
 SM: B.6.2
 SM: 🟣🟢
 SM: B.5.loop
 SM: 🟣🔵
 SM: B.6.1
 SM: B.5.loop
 SM: 🟣🔵
 SM: C
 SM: 🦄🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.1
 SM: B.6.2
 SM: 🟣🟢
 SM: B.6.2
 SM: 🟣🟢
 */
