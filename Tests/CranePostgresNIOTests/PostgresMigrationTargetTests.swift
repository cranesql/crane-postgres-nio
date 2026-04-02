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

        @Test func `Executes SQL when applying migrations`() async throws {
            let migrator = try Migrator(rootPath: fixturesPath, target: target)

            try await withThrowingTaskGroup { group in
                group.addTask {
                    await target.run()
                }

                try await migrator.apply()
                group.cancelAll()
            }

            try await db.withClient { client in
                let rows = try await client.query(
                    "SELECT table_name FROM information_schema.tables WHERE table_name = 'users'"
                )
                var tableNames = Set<String>()
                for try await tableName in rows.decode(String.self) {
                    tableNames.insert(tableName)
                }
                #expect(tableNames == ["users"])
            }
        }
    }
}
