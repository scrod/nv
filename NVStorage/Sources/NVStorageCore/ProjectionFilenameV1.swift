import Foundation

/// A name-preparation failure that leaves the captured inventory available for review.
public enum ProjectionFilenameError: Error, Equatable, Sendable {
    case invalidTitle, invalidExtension, ambiguousInventory, lengthLimit
}

/// Captured filename inputs for NV's title sanitizing, extension and collision policy.
/// Rooted callers revalidate physical occupancy before installing the selected leaf.
public struct ProjectionFilenameV1: Sendable {
    private let extensions: FileExtensionGroupV1
    private let current: ProjectionLeafNameV1?
    private let noteBases: CollisionNames
    private let occupied: CollisionNames

    public init(extensions: FileExtensionGroupV1, current: ProjectionLeafNameV1?,
                otherNotes: [ProjectionLeafNameV1], occupied: [ExactUTF8]) throws {
        for ext in extensions.extensions {
            let value = ext.string
            guard !ext.bytes.contains(0), !ext.bytes.contains(47),
                  value == value.trimmingCharacters(in: CharacterSet(charactersIn: "./*: \t\n\r")) else {
                throw ProjectionFilenameError.invalidExtension
            }
        }
        let all = CollisionNames(occupied.map(\.string))
        guard !all.hasAliases else { throw ProjectionFilenameError.ambiguousInventory }
        self.extensions = extensions; self.current = current
        self.noteBases = CollisionNames(otherNotes.map { ($0.spelling.string as NSString).deletingPathExtension })
        self.occupied = CollisionNames(occupied.filter { $0 != current?.spelling }.map(\.string)
            + ["NV Data", "Notes & Settings", "Interim Note-Changes"])
    }

    /// Selects a candidate from the captured names using the legacy numeric suffix convention.
    public func filename(for title: ExactUTF8) throws -> ProjectionLeafNameV1 {
        guard !title.bytes.isEmpty, !title.bytes.contains(0) else { throw ProjectionFilenameError.invalidTitle }
        var stem = title.string.replacingOccurrences(of: "/", with: ":")
        if stem.hasPrefix(".") { stem.replaceSubrange(stem.startIndex...stem.startIndex, with: "_") }
        var ext = extensions.extensions[Int(extensions.chosen)].string
        if let current {
            let old = (current.spelling.string as NSString).pathExtension
            if extensions.extensions.contains(where: { $0.string.compare(old, options: .caseInsensitive) == .orderedSame }) { ext = old }
        }
        let reserve = 5 + ext.utf16.count
        guard reserve < 255 else { throw ProjectionFilenameError.lengthLimit }
        let text = stem as NSString
        if text.length > 255 - reserve {
            var count = 255 - reserve
            if (0xD800...0xDBFF).contains(text.character(at: count - 1)) { count -= 1 }
            stem = text.substring(to: count)
        }
        guard !stem.isEmpty else { throw ProjectionFilenameError.lengthLimit }
        let suffixBase = (stem as NSString).deletingPathExtension
        // Each occupied candidate consumes a distinct name in the captured sets.
        for iteration in 0...(noteBases.count + occupied.count) {
            let base = iteration == 0 ? stem : suffixBase + "." + String(iteration)
            let name = ext.isEmpty ? base : base + "." + ext
            guard name.utf16.count <= 255 else { throw ProjectionFilenameError.lengthLimit }
            if !noteBases.contains(base), !occupied.contains(name) {
                return try ProjectionLeafNameV1(ExactUTF8(bytes: Array(name.utf8)))
            }
        }
        throw ProjectionFilenameError.lengthLimit
    }
}

/// Sorted case-insensitive names support repeated candidate checks by binary search.
private struct CollisionNames: Sendable {
    let names: [String]
    var count: Int { names.count }
    init(_ names: [String]) { self.names = names.sorted { $0.compare($1, options: .caseInsensitive) == .orderedAscending } }
    var hasAliases: Bool {
        names.indices.dropFirst().contains { names[$0 - 1].compare(names[$0], options: .caseInsensitive) == .orderedSame }
    }
    func contains(_ name: String) -> Bool {
        var lower = 0, upper = names.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            switch names[middle].compare(name, options: .caseInsensitive) {
            case .orderedSame: return true
            case .orderedAscending: lower = middle + 1
            case .orderedDescending: upper = middle
            }
        }
        return false
    }
}
