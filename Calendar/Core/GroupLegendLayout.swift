import Foundation

/// Keeps the original group order and reserves the menu only when it is needed.
struct GroupLegendLayout {
    let visibleCount: Int
    let hiddenCount: Int

    init(itemWidths: [Double], availableWidth: Double, spacing: Double = 8, overflowWidth: Double) {
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        let gap = spacing.isFinite ? max(0, spacing) : 0
        let menu = overflowWidth.isFinite ? max(0, overflowWidth) : .infinity
        let widths = itemWidths.map { $0.isFinite ? max(0, $0) : Double.infinity }
        let completeWidth = widths.reduce(0, +) + Double(max(0, widths.count - 1)) * gap
        if completeWidth <= available {
            visibleCount = widths.count
        } else {
            var count = 0
            var used: Double = 0
            for width in widths {
                let next = used + (count == 0 ? 0 : gap) + width
                // At least one hidden item exists here; keep its menu reachable.
                guard next + gap + menu <= available else { break }
                used = next
                count += 1
            }
            visibleCount = count
        }
        hiddenCount = widths.count - visibleCount
    }
}
