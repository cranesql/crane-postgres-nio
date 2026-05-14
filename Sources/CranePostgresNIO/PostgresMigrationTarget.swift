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

public import Crane
import Foundation
import PostgresNIO

public struct PostgresMigrationTarget: MigrationTarget, Sendable {
    private let client: PostgresClient
    private let logger = Logger(label: "PostgresMigrationTarget")

    @TaskLocal private static var transactionConnection: PostgresConnection?

    public init(
        host: String = "localhost",
        port: Int = 5432,
        username: String,
        password: String,
        database: String? = nil
    ) {
        client = PostgresClient(
            configuration: PostgresClient.Configuration(
                host: host,
                port: port,
                username: username,
                password: password,
                database: database,
                tls: .disable
            )
        )
    }

    // MARK: - Lifecycle

    public func run() async {
        await client.run()
    }

    // MARK: - User

    public func currentUser() async throws -> String? {
        try await withConnection { connection in
            let rows = try await connection.query("SELECT current_user::text", logger: logger)
            for try await user in rows.decode(String.self) {
                return user
            }
            throw PostgresMigrationTargetError.missingCurrentUser
        }
    }

    // MARK: - History

    public func setUpHistory() async throws {
        try await execute(
            """
            CREATE TABLE IF NOT EXISTS crane_schema_history (
                rank INTEGER NOT NULL PRIMARY KEY,
                version INTEGER,
                description TEXT NOT NULL,
                type TEXT NOT NULL,
                checksum TEXT NOT NULL,
                executed_by TEXT NOT NULL,
                executed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                executed_in_ms INTEGER NOT NULL,
                succeeded BOOLEAN NOT NULL
            )
            """
        )
    }

    public func history() async throws -> [SchemaHistoryRow] {
        let query: PostgresQuery = """
            SELECT rank, version, description, type, checksum, executed_by, executed_at, executed_in_ms, succeeded
            FROM crane_schema_history
            ORDER BY rank
            """

        var rows = [SchemaHistoryRow]()

        try await withConnection { connection in
            for try await row
                in try await connection
                .query(query, logger: logger)
                .decode((Int32, Int32?, String, String, String, String, Date, Int32, Bool).self)
            {
                rows.append(try SchemaHistoryRow(row: row))
            }
        }

        return rows
    }

    public func record(_ row: SchemaHistoryRow) async throws {
        let executionTimeMilliseconds = Int32(row.duration.milliseconds)
        let rank = Int32(row.rank)
        let version = row.version.map(Int32.init)
        let description = row.description
        let type = row.type.rawValue
        let checksum = row.checksum
        let user = row.user
        let executionDate = row.executionDate
        let succeeded = row.succeeded

        let query: PostgresQuery = """
            INSERT INTO crane_schema_history
                (rank, version, description, type, checksum, executed_by, executed_at, executed_in_ms, succeeded)
            VALUES
                (\(rank), \(version), \(description), \(type), \(checksum), \(user), \(executionDate), \(executionTimeMilliseconds), \(succeeded))
            """

        try await execute(query)
    }

    // MARK: - Execute

    public func execute(_ sqlScript: String) async throws {
        try await execute(PostgresQuery(unsafeSQL: sqlScript))
    }

    private func execute(_ query: PostgresQuery) async throws {
        try await withConnection { connection in
            try await connection.query(query, logger: logger)
        }
    }

    @discardableResult
    private func withConnection<T>(_ body: sending (PostgresConnection) async throws -> T) async throws -> T {
        if let connection = Self.transactionConnection {
            return try await body(connection)
        } else {
            return try await client.withConnection { connection in
                try await body(connection)
            }
        }
    }

    // MARK: - Transaction

    public func withTransaction(_ body: @Sendable () async throws -> Void) async throws {
        try await client.withTransaction(logger: logger) { connection in
            try await Self.$transactionConnection.withValue(connection) {
                try await body()
            }
        }
    }
}

package enum PostgresMigrationTargetError: Error, Equatable {
    case unknownMigrationType(String)
    case missingCurrentUser
}

extension SchemaHistoryRow {
    fileprivate init(row: (Int32, Int32?, String, String, String, String, Date, Int32, Bool)) throws {
        let (rank, version, description, type, checksum, user, executionDate, executionTimeMs, succeeded) = row

        guard let migrationType = SchemaHistoryRow.MigrationType(rawValue: type) else {
            throw PostgresMigrationTargetError.unknownMigrationType(type)
        }

        self = SchemaHistoryRow(
            rank: Int(rank),
            version: version.map(Int.init),
            description: description,
            type: migrationType,
            checksum: checksum,
            user: user,
            executionDate: executionDate,
            duration: .milliseconds(Int(executionTimeMs)),
            succeeded: succeeded
        )
    }
}
