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
import PostgresNIO

public struct PostgresMigrationTarget: MigrationTarget, Sendable {
    private let client: PostgresClient
    private let logger = Logger(label: "PostgresMigrationTarget")

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

    public func history() async throws -> [SchemaHistoryRow] {
        []
    }

    public func run() async {
        await client.run()
    }

    public func execute(_ sqlScript: String) async throws {
        try await client.withConnection { connection in
            _ = try await connection.query(PostgresQuery(unsafeSQL: sqlScript), logger: logger)
        }
    }
}
