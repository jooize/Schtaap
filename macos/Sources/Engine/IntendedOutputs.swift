import Foundation

/// The speakers the user asked for, kept apart from the ones the engine has
/// selected right now.
///
/// The two drift: Siri, an Apple TV or another AirPlay sender can take a
/// speaker away, and the engine reports that as the output simply flipping to
/// unselected. There is no "borrowed by someone else" field to read. So the
/// app remembers what was asked for, treats an intended speaker that is not
/// playing as one to win back, and retries selecting it -- the refusal is the
/// probe, and the speaker coming free is what makes the retry succeed.
///
/// Only the user rewrites this: selecting a speaker adds it, switching it off
/// removes it. The engine's own changes never do, which is the whole point.
struct IntendedOutputs: Codable, Equatable {
    /// Output id to the name it had when chosen. Ids are the engine's and
    /// survive its restarts, but a rebuilt database hands out new ones, so
    /// the name is kept as a second key.
    private(set) var members: [String: String] = [:]

    var isEmpty: Bool { members.isEmpty }

    func contains(_ output: Output) -> Bool {
        members[output.id] != nil || members.values.contains(output.name)
    }

    mutating func insert(_ output: Output) {
        members[output.id] = output.name
    }

    mutating func remove(_ output: Output) {
        members[output.id] = nil
        // A stale id under the same name would keep the speaker intended.
        members = members.filter { $0.value != output.name }
    }

    // MARK: - Persistence

    static func load(from url: URL) -> IntendedOutputs? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IntendedOutputs.self, from: data)
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Losing this costs one rejoin; it is not worth failing anything over.
        try? data.write(to: url, options: .atomic)
    }
}
