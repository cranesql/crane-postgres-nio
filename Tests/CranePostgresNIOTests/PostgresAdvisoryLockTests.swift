//===----------------------------------------------------------------------===//
//
// This source file is part of the Crane open source project
//
// Copyright (c) 2026 the Crane project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CranePostgresNIO
import InMemoryLogging
import Logging
import PostgresNIO
import Testing

struct `Postgres Advisory Lock` {
    @Suite(.disabledWithoutPostgresConfiguration, .temporaryDatabase, .timeLimit(.minutes(1)))
    struct Integration {
        let logHandler = InMemoryLogHandler()
        let logger: Logger
        let db: TemporaryDatabase

        init() throws {
            var logger = Logger(label: "Postgres Advisory Lock Tests")
            logger.handler = logHandler
            logger.logLevel = .trace
            self.logger = logger

            db = try #require(TemporaryDatabase.current)
        }

        @Test func `withLock runs the body and releases the lock afterwards`() async throws {
            let qualifiedHistoryTable = "public.crane_schema_history"
            let lock = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)
            let events = EventLog()

            try await db.withClient { client in
                try await client.withConnection { connection in
                    try await lock.withLock(on: connection) {
                        await events.append("body ran")
                        let grantedAdvisoryLocks = try await client.grantedAdvisoryLocks()
                        #expect(grantedAdvisoryLocks.count == 1)
                    }

                    #expect(try await client.grantedAdvisoryLocks().isEmpty)
                }
            }

            #expect(await events.entries == ["body ran"])
        }

        @Test func `withLock releases the lock and propagates the body's error when the body throws`() async throws {
            let qualifiedHistoryTable = "public.crane_schema_history"
            let lock = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)

            struct BodyFailure: Error {}

            try await db.withClient { client in
                try await client.withConnection { connection in
                    _ = await #expect(throws: BodyFailure.self) {
                        try await lock.withLock(on: connection) {
                            throw BodyFailure()
                        }
                    }

                    let grantedAdvisoryLocks = try await client.grantedAdvisoryLocks()
                    #expect(grantedAdvisoryLocks.isEmpty)
                }
            }
        }

        @Test func `Acquires lock on initial attempt when the lock isn't held yet`() async throws {
            let qualifiedHistoryTable = "public.crane_schema_history"
            let lock = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)

            try await db.withClient { client in
                try await client.withConnection { connection in
                    try await lock.acquire(on: connection, maxAttempts: 1, retryDelay: .zero)
                    #expect(
                        try await client.grantedAdvisoryLocks() == [
                            AdvisoryLockKey(classID: 0x4352_4E45, objectID: 956_008_311)
                        ]
                    )
                }
            }

            let acquisitionLogEntry = InMemoryLogHandler.Entry(
                level: .debug,
                message: "Acquired advisory lock.",
                metadata: [
                    "pg_advisory_lock.class_id": "1129467461",
                    "pg_advisory_lock.object_id": "956008311",
                    "pg_advisory_lock.attempt": "1",
                ]
            )

            #expect(logHandler.entries.contains(acquisitionLogEntry))
        }

        @Test func `Releases an acquired lock`() async throws {
            let qualifiedHistoryTable = "public.crane_schema_history"
            let lock = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)

            try await db.withClient { client in
                try await client.withConnection { connection in
                    try await lock.acquire(on: connection, maxAttempts: 1, retryDelay: .zero)
                    try await lock.release(on: connection)

                    #expect(try await client.grantedAdvisoryLocks().isEmpty)
                }
            }

            let releaseLogEntry = InMemoryLogHandler.Entry(
                level: .debug,
                message: "Released advisory lock.",
                metadata: [
                    "pg_advisory_lock.class_id": "1129467461",
                    "pg_advisory_lock.object_id": "956008311",
                ]
            )

            #expect(logHandler.entries.contains(releaseLogEntry))
        }

        @Test func `Retries until another holder releases the lock`() async throws {
            let qualifiedHistoryTable = "public.crane_schema_history"
            let firstHolder = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)
            let secondHolder = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)
            let events = EventLog()
            let firstAcquired = AsyncStream<Void>.makeStream()

            try await db.withClient { client in
                try await withThrowingTaskGroup { group in
                    group.addTask {
                        try await client.withConnection { connection in
                            try await firstHolder.acquire(on: connection, maxAttempts: 1, retryDelay: .zero)
                            await events.append("first acquired")
                            firstAcquired.continuation.yield()
                            firstAcquired.continuation.finish()
                            try await Task.sleep(for: .milliseconds(150))
                            try await firstHolder.release(on: connection)
                            await events.append("first released")
                        }
                    }

                    for await _ in firstAcquired.stream { break }

                    try await client.withConnection { connection in
                        try await secondHolder.acquire(on: connection, maxAttempts: 5, retryDelay: .milliseconds(100))
                        await events.append("second acquired")
                        try await secondHolder.release(on: connection)
                    }

                    try await group.waitForAll()
                }
            }

            let recorded = await events.entries
            #expect(recorded == ["first acquired", "first released", "second acquired"])

            let waitingLogEntry = InMemoryLogHandler.Entry(
                level: .info,
                message: "Another instance of Crane is already running. Waiting for it to release the advisory lock.",
                metadata: [
                    "pg_advisory_lock.class_id": "1129467461",
                    "pg_advisory_lock.object_id": "956008311",
                    "pg_advisory_lock.attempt": "1",
                    "pg_advisory_lock.max_attempts": "5",
                    "pg_advisory_lock.retry_delay_ms": "100",
                ]
            )
            #expect(logHandler.entries.contains(waitingLogEntry))

            let retryLogEntry = InMemoryLogHandler.Entry(
                level: .debug,
                message: "Retrying advisory lock acquisition after delay.",
                metadata: [
                    "pg_advisory_lock.class_id": "1129467461",
                    "pg_advisory_lock.object_id": "956008311",
                    "pg_advisory_lock.attempt": "2",
                    "pg_advisory_lock.max_attempts": "5",
                    "pg_advisory_lock.retry_delay_ms": "100",
                ]
            )
            #expect(logHandler.entries.contains(retryLogEntry))

            #expect(logHandler.entries.count(where: { $0.message == "Acquired advisory lock." }) == 2)
        }

        @Test func `Throws after exhausting retry attempts`() async throws {
            let qualifiedHistoryTable = "public.crane_schema_history"
            let firstHolder = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)
            let secondHolder = PostgresAdvisoryLock(qualifiedHistoryTable: qualifiedHistoryTable, logger: logger)

            try await db.withClient { client in
                try await client.withConnection { connectionA in
                    try await firstHolder.acquire(on: connectionA, maxAttempts: 1, retryDelay: .zero)

                    try await client.withConnection { connectionB in
                        _ = await #expect(throws: PostgresAdvisoryLock.AcquisitionFailed.self) {
                            try await secondHolder.acquire(
                                on: connectionB,
                                maxAttempts: 2,
                                retryDelay: .milliseconds(50)
                            )
                        }
                    }

                    try await firstHolder.release(on: connectionA)
                }
            }

            let failureLogEntry = InMemoryLogHandler.Entry(
                level: .error,
                message: "Another instance of Crane is still holding the advisory lock. Giving up.",
                metadata: [
                    "pg_advisory_lock.class_id": "1129467461",
                    "pg_advisory_lock.object_id": "956008311",
                    "pg_advisory_lock.attempt": "2",
                ]
            )
            #expect(logHandler.entries.contains(failureLogEntry))
        }

        @Test func `Locks scoped to different qualified tables don't block each other`() async throws {
            let lockA = PostgresAdvisoryLock(
                qualifiedHistoryTable: "tenant_a.crane_schema_history",
                logger: logger
            )
            let lockB = PostgresAdvisoryLock(
                qualifiedHistoryTable: "tenant_b.crane_schema_history",
                logger: logger
            )

            try await db.withClient { client in
                try await client.withConnection { connectionA in
                    try await lockA.acquire(on: connectionA, maxAttempts: 1, retryDelay: .zero)

                    try await client.withConnection { connectionB in
                        try await lockB.acquire(on: connectionB, maxAttempts: 1, retryDelay: .zero)

                        #expect(try await client.grantedAdvisoryLocks().count == 2)
                    }
                }
            }
        }
    }
}

private struct AdvisoryLockKey: Hashable, Sendable {
    let classID: Int32
    let objectID: Int32
}

extension PostgresClient {
    fileprivate func grantedAdvisoryLocks() async throws -> [AdvisoryLockKey] {
        var keys: [AdvisoryLockKey] = []
        // Filter by current database so parallel test runs in other temporary databases don't
        // pollute the result — `pg_locks` is cluster-wide. Cast to int4 because `pg_locks`
        // exposes classid/objid as `oid` (unsigned), but the advisory-lock API uses signed int4.
        let q: PostgresQuery = """
            SELECT classid::int4, objid::int4 FROM pg_locks
            WHERE locktype = 'advisory'
              AND granted
              AND objsubid = 2
              AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
            ORDER BY classid, objid
            """
        for try await (classID, objectID) in try await query(q).decode((Int32, Int32).self) {
            keys.append(AdvisoryLockKey(classID: classID, objectID: objectID))
        }
        return keys
    }
}

private actor EventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}
