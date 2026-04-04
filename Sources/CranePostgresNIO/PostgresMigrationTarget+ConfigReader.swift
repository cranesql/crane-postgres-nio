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

#if Configuration
public import Configuration

extension PostgresMigrationTarget {
    /// Create a migration target configured from a ``ConfigReader``.
    ///
    /// Scopes the reader to `crane.postgres` and reads the following configuration keys:
    /// - `host` — Database host. Defaults to `"localhost"`.
    /// - `port` — Database port. Defaults to `5432`.
    /// - `username` — Database username. Required.
    /// - `password` — Database password. Required.
    /// - `database` — Database name. Optional.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    public init(reader: ConfigReader) throws {
        let postgres = reader.scoped(to: ["crane", "postgres"])
        let host = postgres.string(forKey: "host", default: "localhost")
        let port = postgres.int(forKey: "port", default: 5432)
        let username = try postgres.requiredString(forKey: "username")
        let password = try postgres.requiredString(forKey: "password", isSecret: true)
        let database = postgres.string(forKey: "database")

        self.init(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database
        )
    }
}
#endif
