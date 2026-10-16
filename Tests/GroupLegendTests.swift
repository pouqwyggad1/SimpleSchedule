import Foundation

/// Pure layout tests. No application, windows, user defaults, or stored user data.
@main
struct GroupLegendTests {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class Suite {
        var assertions = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw Failure(message: message) }
        }

        func layout(
            _ widths: [Double], at width: Double, visible: Int, hidden: Int,
            spacing: Double = 8, overflow: Double = 44, _ message: String
        ) throws {
            let result = GroupLegendLayout(
                itemWidths: widths, availableWidth: width,
                spacing: spacing, overflowWidth: overflow
            )
            try expect(result.visibleCount == visible, "\(message): видимые группы")
            try expect(result.hiddenCount == hidden, "\(message): счетчик остальных групп")
        }

        func run() throws {
            try boundaries()
            try prefixAndChanges()
            try widthSweep()
            try invalidGeometry()
        }

        private func boundaries() throws {
            try layout([], at: 0, visible: 0, hidden: 0, "Пустая легенда")
            try layout([80], at: 80, visible: 1, hidden: 0, "Одна группа помещается точно")
            try layout([80], at: 79, visible: 0, hidden: 1, "Одна группа не помещается")
            try layout([20, 20], at: 48, visible: 2, hidden: 0, "При полном размещении место под меню не резервируется")
            try layout([20, 20], at: 47, visible: 0, hidden: 2, "Меню и зазор резервируются при первом переполнении")
            try layout([50, 50, 50], at: 166, visible: 3, hidden: 0, "Все три группы помещаются точно")
            try layout([50, 50, 50], at: 165, visible: 2, hidden: 1, "Уменьшение ширины на один пункт открывает меню")
            try layout([50, 50, 50], at: 160, visible: 2, hidden: 1, "Две группы и меню помещаются точно")
            try layout([50, 50, 50], at: 159, visible: 1, hidden: 2, "Переход к одной видимой группе")
            try layout([50, 50, 50], at: 102, visible: 1, hidden: 2, "Одна группа и меню помещаются точно")
            try layout([50, 50, 50], at: 101, visible: 0, hidden: 3, "Все группы переходят в меню")
            try layout([50, 50, 50], at: 44, visible: 0, hidden: 3, "Только меню без лишнего ведущего зазора")
            try layout([50, 50, 50], at: 0, visible: 0, hidden: 3, "Нулевая ширина")
            try layout([50, 50, 50], at: -1, visible: 0, hidden: 3, "Отрицательная доступная ширина")
            try layout([30, 30, 30], at: 90, visible: 3, hidden: 0, spacing: 0, "Нулевой зазор")
            try layout([30, 30, 30], at: 89, visible: 1, hidden: 2, spacing: 0, "Нулевой зазор с переполнением")
            try layout([30, 30, 30], at: 105, visible: 1, hidden: 2, overflow: 60, "Увеличенная ширина счетчика")
            try layout(Array(repeating: 30, count: 120), at: 150, visible: 2, hidden: 118, overflow: 60, "Трехзначное число скрытых групп")
        }

        private func prefixAndChanges() throws {
            try layout([500, 20, 20], at: 200, visible: 0, hidden: 3, "Длинное первое название не переставляет последующие группы")
            try layout([30, 500, 20], at: 200, visible: 1, hidden: 2, "После длинного названия группы остаются в исходном порядке")
            try layout([38, 38, 38], at: 140, visible: 3, hidden: 0, "Короткие названия до переименования")
            try layout([38, 200, 38], at: 140, visible: 1, hidden: 2, "Удлиненное название пересчитывает переполнение")
            try layout([38, 38, 38], at: 140, visible: 3, hidden: 0, "Возврат короткого названия возвращает группы из меню")
            try layout([38], at: 140, visible: 1, hidden: 0, "Удаление групп убирает устаревший счетчик")
        }

        private func widthSweep() throws {
            // Independent feasibility/maximality invariants over realistic narrow/wide rows.
            let fixtures: [[Double]] = [
                [], [65], [65, 93], [70, 120, 45, 98, 62],
                [400, 20, 20], Array(repeating: 54, count: 130)
            ]
            for widths in fixtures {
                var previousVisible = 0
                let totalWidth = widths.reduce(0, +) + Double(max(0, widths.count - 1)) * 8
                for available in stride(from: 0.0, through: 800.0, by: 1.0) {
                    let result = GroupLegendLayout(itemWidths: widths, availableWidth: available, spacing: 8, overflowWidth: 60)
                    try expect((0...widths.count).contains(result.visibleCount), "Число видимых групп в допустимом диапазоне")
                    try expect(result.hiddenCount == widths.count - result.visibleCount, "Ни одна группа не потеряна и не посчитана дважды")
                    try expect(result.visibleCount >= previousVisible, "При расширении панели число видимых групп не уменьшается")
                    previousVisible = result.visibleCount

                    if totalWidth <= available {
                        try expect(result.visibleCount == widths.count && result.hiddenCount == 0, "Полное размещение имеет приоритет перед меню")
                    } else if available >= 60 {
                        let prefixWidth = widths.prefix(result.visibleCount).reduce(0, +)
                        let occupied = prefixWidth + Double(result.visibleCount) * 8 + 60
                        try expect(occupied <= available, "Видимый префикс вместе с меню помещается в строку")
                        if result.visibleCount < widths.count {
                            let nextCount = result.visibleCount + 1
                            let nextWidth = widths.prefix(nextCount).reduce(0, +) + Double(nextCount) * 8 + 60
                            try expect(nextWidth > available, "Выбран самый длинный помещающийся префикс")
                        }
                    } else {
                        try expect(result.visibleCount == 0, "При нехватке места для меню группы остаются скрытыми")
                    }
                }
            }
        }

        private func invalidGeometry() throws {
            // Invalid geometry must return bounded counts, never trap or publish nonsense.
            let fixtures: [([Double], Double, Double, Double)] = [
                ([40, 60], .nan, 8, 44), ([40, 60], .infinity, 8, 44),
                ([40, 60], -.infinity, 8, 44), ([.nan, 40], 200, 8, 44),
                ([.infinity, 40], 200, 8, 44), ([-1, 40], 200, 8, 44),
                ([40, 60], 200, .nan, 44), ([40, 60], 200, 8, .infinity),
                ([1e100, 1e100], 500, 8, 44)
            ]
            for (widths, available, spacing, overflow) in fixtures {
                let result = GroupLegendLayout(itemWidths: widths, availableWidth: available, spacing: spacing, overflowWidth: overflow)
                try expect((0...widths.count).contains(result.visibleCount), "Некорректная геометрия не выводит число видимых групп за границы")
                try expect(result.hiddenCount == widths.count - result.visibleCount, "Некорректная геометрия сохраняет общий счетчик")
            }
        }
    }

    static func main() throws {
        let suite = Suite()
        try suite.run()
        print("GroupLegendTests: \(suite.assertions) проверок пройдено. Приложение и пользовательские данные не открывались.")
    }
}
