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

#if Configuration
import Configuration
#endif

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
                    paths: ["migrations"],
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
                    #expect(row1.description == "create_users")
                    #expect(row1.type == "APPLY")
                    #expect(row1.user == db.configuration.username)
                    #expect(row1.succeeded)

                    let row2 = historyRows[1]
                    #expect(row2.rank == 2)
                    #expect(row2.version == nil)
                    #expect(row2.description == "active_users_view")
                    #expect(row2.type == "REPEATABLE")
                    #expect(row2.user == db.configuration.username)
                    #expect(row2.succeeded)
                }
            }

            @Test func `Applying twice does not re-execute migrations`() async throws {
                let migrator = try Migrator(
                    rootPath: fixturesPath,
                    paths: ["migrations"],
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

        @Suite struct User {
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

            @Test func `Queries the current database user`() async throws {
                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    let user = try await target.currentUser()
                    #expect(user == db.configuration.username)
                    group.cancelAll()
                }
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
                            description: "create_users",
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
                                description: "create_users",
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
                    description: "create_users",
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

        @Suite struct Schema {
            let db: TemporaryDatabase

            init() throws {
                db = try #require(TemporaryDatabase.current)
            }

            private func makeTarget(schema: String? = nil) -> PostgresMigrationTarget {
                PostgresMigrationTarget(
                    host: db.configuration.host,
                    port: db.configuration.port,
                    username: db.configuration.username,
                    password: db.configuration.password,
                    database: db.name,
                    schema: schema
                )
            }

            @Test func `Defaults to unqualified history table when no schema is configured`() async throws {
                let target = makeTarget()

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tablesInPublic = try await client.tableNames(in: "public")
                    #expect(tablesInPublic.contains("crane_schema_history"))
                }
            }

            @Test func `Creates history table in the configured schema`() async throws {
                try await db.withClient { try await $0.query("CREATE SCHEMA custom_schema") }
                let target = makeTarget(schema: "custom_schema")

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tablesInCustomSchema = try await client.tableNames(in: "custom_schema")
                    let tablesInPublic = try await client.tableNames(in: "public")
                    #expect(tablesInCustomSchema.contains("crane_schema_history"))
                    #expect(!tablesInPublic.contains("crane_schema_history"))
                }
            }

            @Test func `Migration tables land in the configured schema`() async throws {
                try await db.withClient { try await $0.query("CREATE SCHEMA custom_schema") }
                let target = makeTarget(schema: "custom_schema")

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    try await target.withTransaction {
                        try await target.execute("CREATE TABLE users (id INTEGER)")
                    }
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tablesInCustomSchema = try await client.tableNames(in: "custom_schema")
                    let tablesInPublic = try await client.tableNames(in: "public")
                    #expect(tablesInCustomSchema.contains("users"))
                    #expect(!tablesInPublic.contains("users"))
                }
            }

            @Test func `search_path is scoped to the migration transaction`() async throws {
                try await db.withClient { try await $0.query("CREATE SCHEMA custom_schema") }
                let target = makeTarget(schema: "custom_schema")

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    try await target.withTransaction {
                        try await target.execute("CREATE TABLE inside_tx (id INTEGER)")
                    }
                    // Outside withTransaction → no SET LOCAL → default search_path → public.
                    try await target.execute("CREATE TABLE outside_tx (id INTEGER)")
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tablesInCustomSchema = try await client.tableNames(in: "custom_schema")
                    let tablesInPublic = try await client.tableNames(in: "public")
                    #expect(tablesInCustomSchema.contains("inside_tx"))
                    #expect(!tablesInCustomSchema.contains("outside_tx"))
                    #expect(tablesInPublic.contains("outside_tx"))
                }
            }

            @Test func `Different schemas isolate their history`() async throws {
                try await db.withClient { client in
                    try await client.query("CREATE SCHEMA tenant_a")
                    try await client.query("CREATE SCHEMA tenant_b")
                }
                let targetA = makeTarget(schema: "tenant_a")
                let targetB = makeTarget(schema: "tenant_b")

                try await withThrowingTaskGroup { group in
                    group.addTask { await targetA.run() }
                    group.addTask { await targetB.run() }

                    try await targetA.setUpHistory()
                    try await targetA.record(
                        SchemaHistoryRow(
                            rank: 1,
                            version: 1,
                            description: "tenant_a_migration",
                            type: .apply,
                            checksum: "x",
                            user: "u",
                            executionDate: Date(timeIntervalSince1970: 0),
                            duration: .milliseconds(1),
                            succeeded: true
                        )
                    )

                    try await targetB.setUpHistory()
                    try await targetB.record(
                        SchemaHistoryRow(
                            rank: 1,
                            version: 1,
                            description: "tenant_b_migration",
                            type: .apply,
                            checksum: "x",
                            user: "u",
                            executionDate: Date(timeIntervalSince1970: 0),
                            duration: .milliseconds(1),
                            succeeded: true
                        )
                    )

                    let descriptionsA = try await targetA.history().map(\.description)
                    let descriptionsB = try await targetB.history().map(\.description)
                    #expect(descriptionsA == ["tenant_a_migration"])
                    #expect(descriptionsB == ["tenant_b_migration"])

                    group.cancelAll()
                }
            }

            @Test func `Handles schema names containing double-quote characters`() async throws {
                try await db.withClient { try await $0.query(#"CREATE SCHEMA "weird""name""#) }
                let target = makeTarget(schema: #"weird"name"#)

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }

                    try await target.setUpHistory()
                    try await target.record(
                        SchemaHistoryRow(
                            rank: 1,
                            version: 1,
                            description: "with_quotes",
                            type: .apply,
                            checksum: "x",
                            user: "u",
                            executionDate: Date(timeIntervalSince1970: 0),
                            duration: .milliseconds(1),
                            succeeded: true
                        )
                    )
                    #expect(try await target.history().map(\.description) == ["with_quotes"])

                    try await target.withTransaction {
                        try await target.execute("CREATE TABLE inside (id INTEGER)")
                    }

                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tables = try await client.tableNames(in: #"weird"name"#)
                    #expect(tables.contains("crane_schema_history"))
                    #expect(tables.contains("inside"))
                }
            }

            @Test func `Throws when configured schema does not exist`() async throws {
                let target = makeTarget(schema: "does_not_exist")

                await withTaskGroup { group in
                    group.addTask { await target.run() }

                    await #expect(throws: PSQLError.self) {
                        try await target.setUpHistory()
                    }

                    group.cancelAll()
                }
            }
        }

        #if Configuration
        @Suite struct `Config Reader` {
            let db: TemporaryDatabase

            init() throws {
                db = try #require(TemporaryDatabase.current)
            }

            @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
            @Test func `Reads connection config from config reader`() async throws {
                let reader = ConfigReader(
                    provider: InMemoryProvider(
                        values: [
                            "host": ConfigValue(.string(db.configuration.host), isSecret: false),
                            "port": ConfigValue(.int(db.configuration.port), isSecret: false),
                            "username": ConfigValue(.string(db.configuration.username), isSecret: false),
                            "password": ConfigValue(.string(db.configuration.password), isSecret: true),
                            "database": ConfigValue(.string(db.name), isSecret: false),
                        ]
                    )
                )
                let target = try PostgresMigrationTarget(reader: reader)

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tables = try await client.tableNames()
                    #expect(tables.contains("crane_schema_history"))
                }
            }

            @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
            @Test func `Reads schema from config reader`() async throws {
                try await db.withClient { try await $0.query("CREATE SCHEMA custom_schema") }

                let reader = ConfigReader(
                    provider: InMemoryProvider(
                        values: [
                            "host": ConfigValue(.string(db.configuration.host), isSecret: false),
                            "port": ConfigValue(.int(db.configuration.port), isSecret: false),
                            "username": ConfigValue(.string(db.configuration.username), isSecret: false),
                            "password": ConfigValue(.string(db.configuration.password), isSecret: true),
                            "database": ConfigValue(.string(db.name), isSecret: false),
                            "schema": ConfigValue(.string("custom_schema"), isSecret: false),
                        ]
                    )
                )
                let target = try PostgresMigrationTarget(reader: reader)

                try await withThrowingTaskGroup { group in
                    group.addTask { await target.run() }
                    try await target.setUpHistory()
                    group.cancelAll()
                }

                try await db.withClient { client in
                    let tablesInCustomSchema = try await client.tableNames(in: "custom_schema")
                    #expect(tablesInCustomSchema.contains("crane_schema_history"))
                }
            }
        }
        #endif
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

    fileprivate func tableNames(in schema: String) async throws -> Set<String> {
        var names = Set<String>()

        let q: PostgresQuery = """
            SELECT table_name FROM information_schema.tables WHERE table_schema = \(schema)
            """
        for try await name in try await query(q).decode(String.self) {
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
