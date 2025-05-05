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

import class Atomics.ManagedAtomic
import protocol NIOCore.EventLoop
import class NIOCore.EventLoopFuture

/// Mirror of NIOPosix’s thread‑pool shutdown error so callers compile unchanged.
public enum NIOThreadPoolError: Error { case shutdown }

/// Drop‑in stand‑in for `NIOThreadPool`, powered by Swift Concurrency.
@available(macOS 10.15, *)
public final class NIOThreadPool: @unchecked Sendable {
    /// Handle returned to the caller representing the submitted work.
    public struct WorkItem: Sendable {
        public let id: UInt64
        init(id: UInt64) { self.id = id }
    }

    private let shutdownFlag = ManagedAtomic<Bool>(false)
    private let nextID = ManagedAtomic<UInt64>(0)

    public init(numberOfThreads _: Int? = nil) {}
    public func start() {}

    // MARK: ‑ Private helpers -
    private func makeWorkItem() -> NIOThreadPool.WorkItem {
        let id = nextID.loadThenWrappingIncrement(ordering: .sequentiallyConsistent)
        return .init(id: id)
    }

    // MARK: ‑ Public API -

    /// Original NIO API: returns only the future.
    public func submit<T>(on eventLoop: EventLoop, _ fn: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        submit(on: eventLoop, fn).future
    }

    /// Overload that also returns a `WorkItem` handle (used by sqlite‑nio).
    private func submit<T>(on eventLoop: EventLoop, _ work: @escaping @Sendable () throws -> T) -> (future: EventLoopFuture<T>, work: WorkItem) {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return (eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown), makeWorkItem())
        }

        let item = makeWorkItem()

        let future = eventLoop.submit {
            let value = try work()
            // Work item completed
            return value
        }

        return (future, item)
    }

    /// Async helper mirroring `runIfActive` without an EventLoop context.
    public func runIfActive<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else { throw NIOThreadPoolError.shutdown }
        return try await Task { try body() }.value
    }

    /// Event‑loop variant returning only the future.
    public func runIfActive<T>(eventLoop: EventLoop, _ body: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown)
        }
        return eventLoop.submit { try body() }
    }

    /// Variant returning both future and WorkItem.
    public func runIfActive<T>(eventLoop: EventLoop, _ body: @escaping @Sendable () throws -> T) -> (future: EventLoopFuture<T>, work: WorkItem) {
        guard !shutdownFlag.load(ordering: .sequentiallyConsistent) else {
            return (eventLoop.makeFailedFuture(NIOThreadPoolError.shutdown), makeWorkItem())
        }
        let item = makeWorkItem()
        let fut = eventLoop.submit {
            let v = try body()
            return v
        }
        return (fut, item)
    }

    // Lifecycle --------------------------------------------------------------
    public func shutdownGracefully(_ callback: @escaping (Error?) -> Void = { _ in } ) {
        shutdownFlag.store(true, ordering: .sequentiallyConsistent)
        callback(nil)
    }

    public static let singleton: NIOThreadPool = {
        let pool = NIOThreadPool()
        pool.start()
        return pool
    }()
}

// TODO: SM: Find any tests, in nioposix, and in my own test code, etc, and implement as real swift tests
