/// Reasons the exact version-1 value rules leave inputs available for review.
public enum MergeReviewReasonV1: Equatable, Sendable {
    case title, overlappingBodyEdits, lineLimit, resultLimit
    case headCount, ambiguousBase
}

public enum ConservativeMergeResultV1: Equatable, Sendable {
    case merged(PlaintextNoteValue)
    case review(MergeReviewReasonV1)
}

/// Genesis-pinned scalar, label-membership and exact LF bounding-edit rules.
public enum NVConservativeMergeV1 {
    public static let lineLimit = 10_000

    public static func merge(base: PlaintextNoteValue, left: PlaintextNoteValue,
                             right: PlaintextNoteValue, birthCreated: DisplayDate) throws -> ConservativeMergeResultV1 {
        guard let title = scalar(base.title, left.title, right.title) else { return .review(.title) }
        let body: ExactUTF8
        switch mergeBody(base.body, left.body, right.body) {
        case .success(let bytes): body = try ExactUTF8(bytes: bytes)
        case .failure(let reason): return .review(reason.reason)
        }
        let b = Set(base.labels.entries), l = Set(left.labels.entries), r = Set(right.labels.entries)
        let labels = b.union(l).union(r).filter { scalar(b.contains($0), l.contains($0), r.contains($0)) == true }
        do {
            return .merged(try PlaintextNoteValue(title: title, body: body, labels: CanonicalLabels(Array(labels)),
                created: birthCreated, modified: latest(left.modified, right.modified)))
        } catch CanonicalEncodingError.lengthLimit { return .review(.resultLimit) }
    }

    static func latest(_ a: DisplayDate, _ b: DisplayDate) -> DisplayDate {
        a.secondsSinceReferenceDate >= b.secondsSinceReferenceDate ? a : b
    }

    private static func scalar<T: Equatable>(_ base: T, _ left: T, _ right: T) -> T? {
        if left == right { return left }
        if left == base { return right }
        if right == base { return left }
        return nil
    }

    private struct Edit: Equatable {
        let range: Range<Int>
        let replacement: [ArraySlice<UInt8>]
    }

    /// Exact plaintext tokens whose three inputs satisfy the two-sided line bound.
    private struct TwoSidedPlainTextMergeInputs {
        let base: [ArraySlice<UInt8>]
        let left: [ArraySlice<UInt8>]
        let right: [ArraySlice<UInt8>]
        init?(_ b: ExactUTF8, _ l: ExactUTF8, _ r: ExactUTF8) {
            guard let b = Self.lines(b.bytes), let l = Self.lines(l.bytes), let r = Self.lines(r.bytes) else { return nil }
            base = b; left = l; right = r
        }
        /// LF stays with its preceding bytes; an empty trailing token is omitted.
        private static func lines(_ body: [UInt8]) -> [ArraySlice<UInt8>]? {
            var result: [ArraySlice<UInt8>] = [], start = 0
            for i in body.indices where body[i] == 10 {
                result.append(body[start...i]); start = i + 1
                if result.count > lineLimit { return nil }
            }
            if start < body.count { result.append(body[start...]) }
            return result.count <= lineLimit ? result : nil
        }
    }

    private static func edit(_ base: [ArraySlice<UInt8>], _ branch: [ArraySlice<UInt8>]) -> Edit {
        var prefix = 0, suffix = 0
        while prefix < min(base.count, branch.count), base[prefix] == branch[prefix] { prefix += 1 }
        while suffix < min(base.count, branch.count) - prefix,
              base[base.count - 1 - suffix] == branch[branch.count - 1 - suffix] { suffix += 1 }
        return Edit(range: prefix..<(base.count - suffix), replacement: Array(branch[prefix..<(branch.count - suffix)]))
    }

    private static func mergeBody(_ base: ExactUTF8, _ left: ExactUTF8, _ right: ExactUTF8) -> Result<[UInt8], BodyReview> {
        if let simple = scalar(base, left, right) { return .success(simple.bytes) }
        guard let inputs = TwoSidedPlainTextMergeInputs(base, left, right) else { return .failure(.lineLimit) }
        return mergeTwoSided(inputs)
    }

    private static func mergeTwoSided(_ inputs: TwoSidedPlainTextMergeInputs) -> Result<[UInt8], BodyReview> {
        let a = edit(inputs.base, inputs.left), z = edit(inputs.base, inputs.right)
        var result = inputs.base
        if a == z { result.replaceSubrange(a.range, with: a.replacement) }
        else {
            guard a.range.upperBound < z.range.lowerBound || z.range.upperBound < a.range.lowerBound else {
                return .failure(.overlappingBodyEdits)
            }
            for e in [a, z].sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                result.replaceSubrange(e.range, with: e.replacement)
            }
        }
        let count = result.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        guard count <= ObjectLimitsV1.decodedPayloadBytes else { return .failure(.resultLimit) }
        return .success(result.flatMap { $0 })
    }

    private enum BodyReview: Error {
        case overlappingBodyEdits, lineLimit, resultLimit
        var reason: MergeReviewReasonV1 {
            switch self { case .overlappingBodyEdits: .overlappingBodyEdits; case .lineLimit: .lineLimit; case .resultLimit: .resultLimit }
        }
    }
}
