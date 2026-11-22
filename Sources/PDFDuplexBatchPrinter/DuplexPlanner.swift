import Foundation

struct PlannedPage: Equatable {
    /// One-based page number in the source PDF. Nil is reserved for an explicit blank page.
    let sourcePage: Int?
}

struct DuplexPlan: Equatable {
    let oddPass: [PlannedPage]
    let evenPass: [PlannedPage]
}

enum DuplexPlanner {
    static func plan(pageCount: Int, profile: PrinterProfile) -> DuplexPlan {
        plan(pageCounts: [pageCount], profile: profile)
    }

    /// Plans several documents that were merged back to back into one source PDF.
    /// Each document is padded to an even length first, so every document starts
    /// on the front of a new sheet and the printed stack separates into sets.
    static func plan(pageCounts: [Int], profile: PrinterProfile) -> DuplexPlan {
        var sequence: [Int?] = []
        var offset = 0
        for count in pageCounts where count > 0 {
            sequence += (1...count).map { offset + $0 }
            if !count.isMultiple(of: 2) { sequence.append(nil) }
            offset += count
        }

        var odd = stride(from: 0, to: sequence.count, by: 2).map { PlannedPage(sourcePage: sequence[$0]) }
        var even = stride(from: 1, to: sequence.count, by: 2).map { PlannedPage(sourcePage: sequence[$0]) }

        if profile.oddOrder == .reversed { odd.reverse() }
        if profile.evenOrder == .reversed { even.reverse() }

        return DuplexPlan(oddPass: odd, evenPass: even)
    }
}
