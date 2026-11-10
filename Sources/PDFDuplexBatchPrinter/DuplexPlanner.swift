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
        guard pageCount > 0 else { return DuplexPlan(oddPass: [], evenPass: []) }

        // Pad an odd-length document to the next even page number first. This
        // makes the synthetic blank behave exactly like the final numbered
        // page (for example page 10 in a nine-page document).
        let paddedPageCount = pageCount.isMultiple(of: 2) ? pageCount : pageCount + 1

        var odd = stride(from: 1, through: paddedPageCount, by: 2).map {
            PlannedPage(sourcePage: $0 <= pageCount ? $0 : nil)
        }
        var even = stride(from: 2, through: paddedPageCount, by: 2).map {
            PlannedPage(sourcePage: $0 <= pageCount ? $0 : nil)
        }

        if profile.oddOrder == .reversed { odd.reverse() }
        if profile.evenOrder == .reversed { even.reverse() }

        return DuplexPlan(oddPass: odd, evenPass: even)
    }
}
