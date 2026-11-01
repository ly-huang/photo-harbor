import Foundation

@main struct AssessmentTests {
    static func main() async throws {
        let first = URL(fileURLWithPath: CommandLine.arguments[1])
        let second = URL(fileURLWithPath: CommandLine.arguments[2])
        let identical = try await AssessmentService.shared.compare(first, first)
        guard let zero = identical.distance, zero < 0.0001 else { throw LibraryError.message("Feature print model unavailable or identical image mismatch: \(identical.similarityNote)") }
        print("PASS identical image distance", zero)
        let pair = try await AssessmentService.shared.compare(first, second)
        guard let distance = pair.distance, distance >= 0 else { throw LibraryError.message("Similarity model unavailable") }
        for stats in [pair.left, pair.right] {
            precondition(abs(stats.histogram.reduce(0, +) - 1) < 0.00001)
            precondition(stats.detailEnergy.isFinite && stats.detailEnergy >= 0)
            precondition((0...100).contains(stats.darkPercent) && (0...100).contains(stats.brightPercent))
            if let score = stats.aesthetics { precondition((0...100).contains(score)); print("PASS native aesthetics score", score) }
            else { print("AESTHETICS unavailable:", stats.aestheticsNote) }
        }
        print("PASS real image pair: distance", distance, "detail energy", pair.left.detailEnergy, pair.right.detailEnergy)
        let group = await AssessmentService.shared.compareMany([first, second, first, second])
        precondition(group.stats.count == 4 && group.stats.allSatisfy { $0 != nil })
        precondition(group.distances.count == 6)
        precondition(group.distances.first { $0.first == 0 && $0.second == 2 }!.value < 0.0001)
        let single = try await AssessmentService.shared.assess(first)
        precondition(single.aesthetics == pair.left.aesthetics)
        let partial = await AssessmentService.shared.compareMany([first, first.deletingLastPathComponent().appendingPathComponent("missing-fixture.jpg"), second])
        precondition(partial.stats[0] != nil && partial.stats[1] == nil && partial.stats[2] != nil)
        precondition(partial.errors[1] != nil && partial.distances.count == 1)
        print("PASS four-photo six-pair analysis, single assessment cache and partial failure isolation")
    }
}
