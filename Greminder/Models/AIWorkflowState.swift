import Foundation

/// Identity and data used by a request travel with its result, never reconstructed at completion.
struct AIContext: Equatable, Sendable {
    var snapshot: TaskSnapshot
    var account: String?
}

struct AIRequest: Equatable, Sendable {
    var id: UUID
    var context: AIContext
}

struct AIProposalBatch: Equatable, Sendable {
    var context: AIContext
    var proposals: [TaskProposal]
    var isExample = false
}
