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

import Crane
import CranePostgresNIO
import Foundation
import PostgresNIO
import Testing

@Suite struct `Postgres Migration Target` {
    @Suite(.disabledWithoutPostgresConfiguration, .temporaryDatabase)
    struct Integration {
        @Suite struct `End to End` {
            let db: TemporaryDatabase
            let fixturesPath: String
            let target: PostgresMigrationTarget

            init() throws {
                db = try #require(TemporaryDatabase.current)
                fixturesPath = try #require(Bundle.module.path(forResource: "Fixtures", ofType: nil))
                target = PostgresMigrationTarget(
                    host: db.configuration.host,
                    port: db.configuration.port,
                    username: db.configuration.username,
                    password: db.configuration.password,
                    database: db.name
                )
            }

            @Test func `Applies migrations`() async throws {
                try await db.withClient { client in
                    let tables = try await client.tableNames()
                    #expect(!tables.contains("users"))

                    let views = try await client.viewNames()
                    #expect(!views.contains("active_users"))

                    // crane_schema_history doesn't exist yet
                    await #expect(throws: PSQLError.self) {
                        try await client.historyRows()
                    }
                }

                let migrator = try Migrator(
                    rootPath: fixturesPath,
                    paths: ["migrations", "migrations/repeatable"],
                    target: target
                )

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await migrator.apply()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    // Verify the apply migration and repeatable migration were executed
                    #expect(try await client.tableNames().contains("users"))
                    #expect(try await client.viewNames().contains("active_users"))

                    // Verify history rows were recorded (apply + repeatable, not undo)
                    let historyRows = try await client.historyRows()
                    try #require(historyRows.count == 2)

                    let row1 = historyRows[0]
                    #expect(row1.rank == 1)
                    #expect(row1.version == 1)
                    #expect(row1.description == "migrations/v1.create_users.apply.sql")
                    #expect(row1.type == "APPLY")
                    #expect(row1.user == db.configuration.username)
                    #expect(row1.succeeded)

                    let row2 = historyRows[1]
                    #expect(row2.rank == 2)
                    #expect(row2.version == nil)
                    #expect(row2.description == "migrations/repeatable/repeat.active_users_view.sql")
                    #expect(row2.type == "REPEATABLE")
                    #expect(row2.user == db.configuration.username)
                    #expect(row2.succeeded)
                }
            }

            @Test func `Applying twice does not re-execute migrations`() async throws {
                let migrator = try Migrator(
                    rootPath: fixturesPath,
                    paths: ["migrations", "migrations/repeatable"],
                    target: target
                )

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await migrator.apply()
                    try await migrator.apply()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let historyRows = try await client.historyRows()
                    #expect(historyRows.count == 2)
                }
            }
        }

        @Suite struct Execute {
            let db: TemporaryDatabase
            let target: PostgresMigrationTarget

            init() throws {
                db = try #require(TemporaryDatabase.current)
                target = PostgresMigrationTarget(
                    host: db.configuration.host,
                    port: db.configuration.port,
                    username: db.configuration.username,
                    password: db.configuration.password,
                    database: db.name
                )
            }

            @Test func `Executes SQL script`() async throws {
                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.execute("CREATE TABLE execute_test (id INTEGER)")
                    group.cancelAll()
                }

                let tableNames = try await db.withClient { try await $0.tableNames() }
                #expect(tableNames.contains("execute_test"))
            }
        }

        @Suite struct History {
            let db: TemporaryDatabase
            let target: PostgresMigrationTarget

            init() throws {
                db = try #require(TemporaryDatabase.current)
                target = PostgresMigrationTarget(
                    host: db.configuration.host,
                    port: db.configuration.port,
                    username: db.configuration.username,
                    password: db.configuration.password,
                    database: db.name
                )
            }

            @Test func `Creates schema history table`() async throws {
                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let columns =
                        try await client
                        .query(
                            """
                            SELECT column_name
                            FROM information_schema.columns
                            WHERE table_name = 'crane_schema_history'
                            ORDER BY ordinal_position
                            """
                        )
                        .collect()
                        .map { try $0.decode(String.self) }

                    #expect(
                        columns == [
                            "rank",
                            "version",
                            "description",
                            "type",
                            "checksum",
                            "executed_by",
                            "executed_at",
                            "executed_in_ms",
                            "succeeded",
                        ]
                    )
                }
            }

            @Test func `Creates schema history table idempotently`() async throws {
                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    try await target.setUpHistory()
                    group.cancelAll()
                }
            }

            @Test func `Records migration in schema history table`() async throws {
                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    try await target.record(
                        SchemaHistoryRow(
                            rank: 1,
                            version: 1,
                            description: "migrations/v1.create_users.apply.sql",
                            type: .apply,
                            checksum: "abc123",
                            user: "integration",
                            executionDate: Date(timeIntervalSince1970: 42),
                            duration: .milliseconds(42),
                            succeeded: true
                        )
                    )
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let rows = try await client.historyRows()

                    #expect(
                        rows == [
                            PostgresHistoryRow(
                                rank: 1,
                                version: 1,
                                description: "migrations/v1.create_users.apply.sql",
                                type: "APPLY",
                                checksum: "abc123",
                                user: "integration",
                                executionDate: Date(timeIntervalSince1970: 42),
                                durationInMilliseconds: 42,
                                succeeded: true
                            )
                        ]
                    )
                }
            }

            @Test func `Retrieves recorded history`() async throws {
                let row = SchemaHistoryRow(
                    rank: 1,
                    version: 1,
                    description: "migrations/v1.create_users.apply.sql",
                    type: .apply,
                    checksum: "abc123",
                    user: "integration",
                    executionDate: Date(timeIntervalSince1970: 42),
                    duration: .milliseconds(42),
                    succeeded: true
                )

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    try await target.record(row)

                    #expect(try await target.history() == [row])

                    group.cancelAll()
                }
            }

            @Test func `Throws when retrieving migration from history with invalid type`() async throws {
                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()

                    _ = try await db.withClient { client in
                        try await client.query(
                            """
                            INSERT INTO crane_schema_history
                                (rank, version, description, type, checksum, executed_by, executed_at, executed_in_ms, succeeded)
                            VALUES
                                (1, 1, 'test', 'INVALID', 'abc123', 'integration', now(), 42, true)
                            """
                        )
                    }

                    await #expect(throws: PostgresMigrationTargetError.unknownMigrationType("INVALID")) {
                        try await target.history()
                    }

                    group.cancelAll()
                }
            }
        }

        @Suite struct Transaction {
            let db: TemporaryDatabase
            let target: PostgresMigrationTarget

            init() throws {
                db = try #require(TemporaryDatabase.current)
                target = PostgresMigrationTarget(
                    host: db.configuration.host,
                    port: db.configuration.port,
                    username: db.configuration.username,
                    password: db.configuration.password,
                    database: db.name
                )
            }

            @Test func `Rolls back on failure`() async throws {
                await withTaskGroup { group in
                    group.addTask { await target.run() }

                    struct Failure: Error {}
                    await #expect(throws: PostgresTransactionError.self) {
                        try await target.withTransaction {
                            try await target.execute("CREATE TABLE rollback_test (id INTEGER)")
                            throw Failure()
                        }
                    }

                    group.cancelAll()
                }

                let tableNames = try await db.withClient { try await $0.tableNames() }
                #expect(!tableNames.contains("rollback_test"))
            }
        }
    }
}

struct PostgresHistoryRow: Equatable {
    let rank: Int32
    let version: Int32?
    let description: String
    let type: String
    let checksum: String
    let user: String
    let executionDate: Date
    let durationInMilliseconds: Int32
    let succeeded: Bool
}

extension PostgresClient {
    fileprivate func tableNames() async throws -> Set<String> {
        var names = Set<String>()

        for try await name in try await query("SELECT table_name FROM information_schema.tables").decode(String.self) {
            names.insert(name)
        }

        return names
    }

    fileprivate func viewNames() async throws -> Set<String> {
        var names = Set<String>()

        for try await name in try await query("SELECT table_name FROM information_schema.views").decode(String.self) {
            names.insert(name)
        }

        return names
    }

    fileprivate func historyRows() async throws -> [PostgresHistoryRow] {
        var rows = [PostgresHistoryRow]()

        let query: PostgresQuery = """
            SELECT rank, version, description, type, checksum, executed_by, executed_at, executed_in_ms, succeeded
            FROM crane_schema_history
            ORDER BY rank
            """

        for try await (rank, version, description, type, checksum, user, executionDate, duration, succeeded)
            in try await self
            .query(query)
            .decode((Int32, Int32?, String, String, String, String, Date, Int32, Bool).self)
        {
            rows.append(
                PostgresHistoryRow(
                    rank: rank,
                    version: version,
                    description: description,
                    type: type,
                    checksum: checksum,
                    user: user,
                    executionDate: executionDate,
                    durationInMilliseconds: duration,
                    succeeded: succeeded
                )
            )
        }

        return rows
    }
}
