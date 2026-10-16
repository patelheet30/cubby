import os

private let logger = Logger(subsystem: "com.heetpatel.cubby", category: "app")

/// Public (unredacted) log line; read with `log show --predicate 'subsystem == "com.heetpatel.cubby"'`.
func log(_ message: String) { logger.notice("\(message, privacy: .public)") }
