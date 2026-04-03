import Foundation

struct RemoteSessionStatus: Equatable, Sendable, Identifiable {
    let target: String
    let state: String
    let name: String
    let cwd: String

    var id: String { target }
}
