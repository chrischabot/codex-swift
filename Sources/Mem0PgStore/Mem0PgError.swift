import Foundation
import Mem0Core
import PostgresNIO

/// Maps PostgresNIO / PSQL errors onto the engine's `Mem0Error` surface, keeping
/// SQLSTATE diagnostics where useful.
enum Mem0PgErrorMap {
    static func wrap(_ error: any Error, _ context: String) -> Mem0Error {
        if let psql = error as? PSQLError {
            // Surface the server SQLSTATE + message when present.
            let code = psql.serverInfo?[.sqlState]
            let message = psql.serverInfo?[.message] ?? String(describing: psql.code)
            if let code {
                // 23505 unique_violation, 23503 fk_violation, etc. — all "database".
                return Mem0Error.database("\(context): [\(code)] \(message)")
            }
            return Mem0Error.database("\(context): \(message)")
        }
        return Mem0Error.database("\(context): \(error)")
    }
}
