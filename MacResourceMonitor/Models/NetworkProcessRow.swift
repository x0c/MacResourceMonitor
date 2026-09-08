import Foundation

nonisolated struct ProcessNetworkRate: Sendable, Equatable {
    var receivedBytesPerSecond: Double
    var sentBytesPerSecond: Double
}

nonisolated struct NetworkProcessRow: Identifiable, Sendable, Hashable {
    let process: ProcessRow
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double

    var id: String { process.id }
    var displayName: String { process.displayName }
    var totalBytesPerSecond: Double { uploadBytesPerSecond + downloadBytesPerSecond }
}
