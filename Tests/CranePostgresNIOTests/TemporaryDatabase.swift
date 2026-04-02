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

import Foundation
import PostgresNIO
import Testing

struct TemporaryDatabase: Sendable {
    let name: String
    let configuration: Configuration

    @TaskLocal static var current: TemporaryDatabase?

    func withClient<T>(
        _ body: (PostgresClient) async throws -> T
    ) async throws -> T {
        let client = PostgresClient(
            configuration: PostgresClient.Configuration(
                host: configuration.host,
                port: configuration.port,
                username: configuration.username,
                password: configuration.password,
                database: name,
                tls: .disable
            )
        )
        return try await withThrowingTaskGroup(returning: T.self) { group in
            group.addTask { await client.run() }
            let result = try await body(client)
            group.cancelAll()
            return result
        }
    }

    struct Configuration: Sendable {
        let host: String
        let port: Int
        let username: String
        let password: String

        static let resolved: Configuration? = {
            guard let host = ProcessInfo.processInfo.environment["POSTGRES_HOST"],
                let portString = ProcessInfo.processInfo.environment["POSTGRES_PORT"],
                let port = Int(portString),
                let user = ProcessInfo.processInfo.environment["POSTGRES_USER"],
                let password = ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"]
            else { return nil }
            return Configuration(host: host, port: port, username: user, password: password)
        }()
    }
}

struct TemporaryDatabaseTrait: TestTrait, SuiteTrait, TestScoping {
    let isRecursive = true

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard let configuration = TemporaryDatabase.Configuration.resolved else {
            return
        }

        let name = "crane_test_\(UUID().uuidString.lowercased().replacing("-", with: "_"))"

        let adminConfiguration = PostgresClient.Configuration(
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            password: configuration.password,
            database: nil,
            tls: .disable
        )

        try await runAdminQuery("CREATE DATABASE \(name)", configuration: adminConfiguration)

        let db = TemporaryDatabase(name: name, configuration: configuration)

        do {
            try await TemporaryDatabase.$current.withValue(db) {
                try await function()
            }
        } catch {
            try? await runAdminQuery("DROP DATABASE \(name) WITH (FORCE)", configuration: adminConfiguration)
            throw error
        }

        try await runAdminQuery("DROP DATABASE \(name) WITH (FORCE)", configuration: adminConfiguration)
    }
}

extension Trait where Self == TemporaryDatabaseTrait {
    static var temporaryDatabase: Self { TemporaryDatabaseTrait() }
}

extension Trait where Self == ConditionTrait {
    static var disabledWithoutPostgresConfiguration: Self {
        .disabled(if: TemporaryDatabase.Configuration.resolved == nil, "No Postgres connection configured")
    }
}

private func runAdminQuery(_ sql: String, configuration: PostgresClient.Configuration) async throws {
    let client = PostgresClient(configuration: configuration)
    try await withThrowingTaskGroup { group in
        group.addTask { await client.run() }
        try await client.query(PostgresQuery(unsafeSQL: sql))
        group.cancelAll()
    }
}
