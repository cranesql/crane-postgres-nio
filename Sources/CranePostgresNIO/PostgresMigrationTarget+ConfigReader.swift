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
    /// Reads the following keys directly from the reader. The caller is responsible for any
    /// namespace scoping (e.g. `reader.scoped(to: "postgres")`).
    /// - `host` — Database host. Defaults to `"localhost"`.
    /// - `port` — Database port. Defaults to `5432`.
    /// - `username` — Database username. Required.
    /// - `password` — Database password. Required.
    /// - `database` — Database name. Optional.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    public init(reader: ConfigReader) throws {
        let host = reader.string(forKey: "host", default: "localhost")
        let port = reader.int(forKey: "port", default: 5432)
        let username = try reader.requiredString(forKey: "username")
        let password = try reader.requiredString(forKey: "password", isSecret: true)
        let database = reader.string(forKey: "database")

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
