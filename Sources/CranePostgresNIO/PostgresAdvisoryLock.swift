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

import Crypto
import Foundation
import Logging
package import PostgresNIO

package struct PostgresAdvisoryLock {
    private let id: (class: Int32, object: Int32)
    private let logger: Logger

    package init(qualifiedHistoryTable: String, logger: Logger) {
        // ASCII "CRNE" packed big-endian — Crane's classid for the two-int `pg_advisory_lock` namespace.
        let classID: Int32 = 0x4352_4E45

        // SHA-256 of the qualified history table truncated to 32 bits, scoping the lock per schema.
        //
        // Same schema → same object ID → same lock (mutual exclusion).
        // Different schemas → different object IDs → independent locks (parallel acquisition).
        let objectID: Int32 = {
            let digest = SHA256.hash(data: Data(qualifiedHistoryTable.utf8))
            let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Int32(bitPattern: value)
        }()

        self.id = (classID, objectID)
        var logger = logger
        logger[metadataKey: "pg_advisory_lock.class_id"] = "\(classID)"
        logger[metadataKey: "pg_advisory_lock.object_id"] = "\(objectID)"
        self.logger = logger
    }

    package func withLock(
        on connection: PostgresConnection,
        maxLockAcquisitionAttempts: Int = 50,
        lockAcquisitionRetryDelay: Duration = .seconds(1),
        body: @Sendable () async throws -> Void
    ) async throws {
        try await acquire(
            on: connection,
            maxAttempts: maxLockAcquisitionAttempts,
            retryDelay: lockAcquisitionRetryDelay
        )

        do {
            try await body()

            do {
                try await release(on: connection)
            } catch {
                logger.warning(
                    """
                    The operation succeeded but the advisory lock couldn't be released. \
                    It will be automatically released once the connection closes.
                    """,
                    error: error
                )
            }
        } catch let bodyError {
            do {
                try await release(on: connection)
            } catch {
                logger.warning(
                    """
                    Failed to release the advisory lock manually. \
                    It will be automatically released once the connection closes.
                    """,
                    error: error
                )
            }

            throw bodyError
        }
    }

    package func acquire(
        on connection: PostgresConnection,
        maxAttempts: Int = 50,
        retryDelay: Duration = .seconds(1)
    ) async throws {
        let maxAttempts = max(maxAttempts, 1)
        let query: PostgresQuery = "SELECT pg_try_advisory_lock(\(id.class), \(id.object))"

        for attempt in 1...maxAttempts {
            var logger = logger
            logger[metadataKey: "pg_advisory_lock.attempt"] = "\(attempt)"

            let rows = try await connection.query(query, logger: logger)

            var acquired = false
            for try await result in rows.decode(Bool.self) {
                acquired = result
                break
            }

            if acquired {
                logger.debug("Acquired advisory lock.")
                return
            }

            if attempt == maxAttempts {
                logger.error("Another instance of Crane is still holding the advisory lock. Giving up.")
                throw AcquisitionFailed()
            } else if attempt == 1 {
                // Notify the user on the first attempt only to reduce noise.
                logger.info(
                    "Another instance of Crane is already running. Waiting for it to release the advisory lock.",
                    metadata: [
                        "pg_advisory_lock.max_attempts": "\(maxAttempts)",
                        "pg_advisory_lock.retry_delay_ms": "\(retryDelay.milliseconds)",
                    ]
                )
            } else {
                logger.debug(
                    "Retrying advisory lock acquisition after delay.",
                    metadata: [
                        "pg_advisory_lock.max_attempts": "\(maxAttempts)",
                        "pg_advisory_lock.retry_delay_ms": "\(retryDelay.milliseconds)",
                    ]
                )
            }

            try await Task.sleep(for: retryDelay)
        }
    }

    package func release(on connection: PostgresConnection) async throws {
        try await connection.query("SELECT pg_advisory_unlock(\(id.class), \(id.object))", logger: logger)
        logger.debug("Released advisory lock.")
    }

    package struct AcquisitionFailed: Error {}
}
