//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Dispatch)
import Dispatch
#endif
import struct Foundation.UUID
import NIOCore

/// Task‑local key that stores the UUID of the `AsyncEventLoop` currently
/// executing.  Lets us answer `inEventLoop` without private APIs.
@available(macOS 13, *)
private enum _CurrentEventLoopKey { @TaskLocal static var id: UUID? }

// MARK: - AsyncEventLoop -

/// A single‑threaded `EventLoop` implemented solely with Swift Concurrency.
@available(macOS 13, *)
public final class AsyncEventLoop: EventLoop, @unchecked Sendable {
    public enum AsynceEventLoopError: Error {
        case cancellationFailure
    }

    private actor _SerialExecutor {
        /// We use this actor to make serialized FIFO entry
        /// into the event loop. This is a shared instance between all
        /// event loops, so it is important that we ONLY use it to enqueue
        /// jobs that come from a non-isolated context.
        @globalActor
        private struct _IsolatingSerialEntryActor {
            actor ActorType {}
            static let shared = ActorType()
        }

        fileprivate typealias OrderIntegerType = UInt64

        private struct ScheduledJob {
            let id: UUID
            let deadline: NIODeadline
            let order: OrderIntegerType
            let job: @Sendable () -> Void

            init(id: UUID = UUID(), deadline: NIODeadline, order: OrderIntegerType, job: @Sendable @escaping () -> Void) {
                self.id = id
                self.deadline = deadline
                self.order = order
                self.job = job
            }
        }
        private var scheduledQueue: [ScheduledJob] = []
        private var nextScheduledItemOrder: OrderIntegerType = 0

        private var currentlyRunningExecutorTask: Task<Void, Never>?
        private var jobQueue: [() -> Void] = []

        let loopID: UUID
        init(loopID: UUID) {
            self.loopID = loopID
        }


        /// Schedules a job and returns a UUID for the job that can be used to cancel the job if needed
        @discardableResult
        fileprivate nonisolated func schedule(at deadline: NIODeadline, job: @Sendable @escaping () -> Void) -> UUID {
            let id = UUID()
            Task { @_IsolatingSerialEntryActor [job] in
                // ^----- Ensures FIFO entry from nonisolated contexts
                await _schedule(at: deadline, id: id, job: job)
            }
            return id
        }

        private func _schedule(at deadline: NIODeadline, id: UUID, job: @Sendable @escaping () -> Void) {
            let order = nextScheduledItemOrder
            nextScheduledItemOrder += 1
            scheduledQueue.append(ScheduledJob(id: id, deadline: deadline, order: order, job: job))
            scheduledQueue.sort {
                if $0.deadline != $1.deadline {
                    return $0.deadline < $1.deadline
                }
                return $0.order < $1.order
            }

            runNextJobIfNeeded()
        }

        nonisolated func enqueue(_ job: @Sendable @escaping () -> Void) {
            Task { @_IsolatingSerialEntryActor [job] in
                // ^----- Ensures FIFO entry from nonisolated contexts
                await _enqueue(job)
            }
        }

        private func _enqueue(_ job: @escaping () -> Void) {
            jobQueue.append(job)
            runNextJobIfNeeded()
        }

        private func runNextJobIfNeeded() {
            // Stop if both queues are empty.
            if jobQueue.isEmpty && scheduledQueue.isEmpty { return }

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
                    for job in jobQueue {
                        // Run the job
                        job()

                        // Remove the job from the queue
                        jobQueue.removeFirst()

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

                    // 3. Schedule next run of jobs at or near the expected due date time for the next job.

                    // TODO: SM: Write unit test for following line, deadlines in the past should execute immediately,
                    // (and not crash because of subtraction past 0 on an unsigned int).
                    if let nextScheduledTask = scheduledQueue.first {
                        let nanoseconds: UInt64 = Self.flooringSubtraction(
                            nextScheduledTask.deadline.uptimeNanoseconds,
                            now.uptimeNanoseconds
                        )
                        Task {
                            try? await Task.sleep(for: .nanoseconds(nanoseconds), tolerance: .nanoseconds(0))
                            runNextJobIfNeeded()
                        }
                    }
                }
            }
        }

        fileprivate func cancelScheduledJob(withID id: UUID) throws {
            for (index, job) in scheduledQueue.enumerated() where job.id == id {
                scheduledQueue.remove(at: index)
                return
            }

            throw AsyncEventLoop.AsynceEventLoopError.cancellationFailure
        }

        fileprivate func clearQueue() {
            jobQueue.removeAll()
            scheduledQueue.removeAll()
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
    public func execute(_ task: @escaping @Sendable () -> Void) {
        executor.enqueue(task)
    }

    // MARK: - Promises / Futures -

    public func makePromise<T>(of type: T.Type = T.self,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> EventLoopPromise<T> {
        .init(eventLoop: self, file: file, line: line)
    }

    public func makeSucceededFuture<T: Sendable>(_ value: T) -> EventLoopFuture<T> {
        let p = makePromise(of: T.self); p.succeed(value); return p.futureResult
    }

    public func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        let p = makePromise(of: T.self); p.fail(error); return p.futureResult
    }

    // MARK: - Submitting work -
    @preconcurrency
    public func submit<T>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
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

    public func flatSubmit<T: Sendable>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
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
    @preconcurrency
    public func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        let promise = makePromise(of: T.self)

        let jobID = executor.schedule(at: deadline) {
            do {
                promise.succeed(try task())
            } catch {
                promise.fail(error)
            }
        }

        return Scheduled(promise: promise) { [weak self] in
            // NOTE: Documented cancellation procedure indicates
            // cancellation is not guaranteed. As such, and to match existing Promise API's,
            // using a Task here to avoid pushing async up the software stack.
            Task {
                try? await self?.executor.cancelScheduledJob(withID: jobID)
            }

            // NOTE: NIO Core already fails the promise before calling the cancellation closure,
            // so we do NOT try to fail the promise. Also cancellation is not guaranteed, so we
            // allow cancellation to silently fail rather than re-negotiating to a throwing API.

            // TODO: SM: Add unit test for cancelling scheduled task via promise.
        }
    }

    public func scheduleTask<T>(in delay: TimeAmount,
                                _ task: @escaping @Sendable () throws -> T) -> Scheduled<T> {
        scheduleTask(deadline: .now() + delay, task)
    }

    public func closeGracefully() async {
        await executor.clearQueue()
    }

    public func next() -> EventLoop {
        self
    }
    public func any()  -> EventLoop {
        self
    }

    #if canImport(Dispatch)
    public func shutdownGracefully(queue _: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        Task {
            await closeGracefully()
            callback(nil)
        }
    }
    #endif

    public func syncShutdownGracefully() throws {
        assertionFailure("Synchronous shutdown API's are not currently supported by AsyncEventLoop")
    }

    #if !canImport(Dispatch)
    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        assertionFailure("Synchronous shutdown API's are not currently supported by AsyncEventLoop")
    }
    #endif
}
