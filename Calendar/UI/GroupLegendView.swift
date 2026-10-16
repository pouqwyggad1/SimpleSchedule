import AppKit
import SwiftUI

/// A live legend of the user's groups. Its menu stays next to the date field.
struct GroupLegendView: View {
    let groups: [TaskGroup]
    let selectedGroupID: UUID?
    var onSelect: (TaskGroup) -> Void

    private let spacing: CGFloat = 8
    private let fontSize: CGFloat = 12
    private var labelFont: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    private var legendGroups: [TaskGroup] { groups + [.ungrouped] }

    private func chipWidth(_ group: TaskGroup) -> CGFloat {
        ceil((group.name as NSString).size(withAttributes: [.font: labelFont]).width) + 8 + 6 + 20
    }

    private var menuWidth: CGFloat {
        max(44, ceil(("+\(legendGroups.count)" as NSString).size(withAttributes: [.font: labelFont]).width) + 32)
    }

    var body: some View {
        GeometryReader { geometry in
            let items = legendGroups
            let layout = GroupLegendLayout(
                itemWidths: items.map { Double(chipWidth($0)) },
                availableWidth: Double(geometry.size.width),
                spacing: Double(spacing),
                overflowWidth: Double(menuWidth)
            )
            let hidden = Array(items.dropFirst(layout.visibleCount))
            let selectedHiddenGroup = hidden.first { $0.id == selectedGroupID }
            HStack(spacing: 0) {
                HStack(spacing: spacing) {
                    ForEach(items.prefix(layout.visibleCount)) { group in
                        groupButton(group)
                    }
                }
                Spacer(minLength: 0)
                if !hidden.isEmpty {
                    Menu {
                        Section("Остальные группы") {
                            ForEach(hidden) { group in
                                Toggle(isOn: Binding(
                                    get: { selectedGroupID == group.id },
                                    set: { _ in onSelect(group) }
                                )) {
                                    Label {
                                        Text(group.name)
                                    } icon: {
                                        Image(nsImage: swatch(hex: group.colorHex))
                                    }
                                }
                                .accessibilityLabel("Группа: \(group.name)")
                                .accessibilityIdentifier("groups.overflow.item.\(group.id.uuidString)")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("+\(hidden.count)").font(.system(size: fontSize, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .frame(width: menuWidth, height: 28)
                        .background(
                            selectedHiddenGroup != nil ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selectedHiddenGroup != nil ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 0.8)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: menuWidth, height: 28)
                    .padding(.leading, layout.visibleCount > 0 ? spacing : 0)
                    .help("Остальные группы: \(hidden.count)")
                    .accessibilityLabel("Еще групп: \(hidden.count)")
                    .accessibilityValue(selectedHiddenGroup.map { "Выбрана группа: \($0.name)" } ?? "")
                    .accessibilityAddTraits(selectedHiddenGroup != nil ? .isSelected : [])
                    .accessibilityIdentifier("groups.overflow")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(minWidth: menuWidth, maxWidth: .infinity)
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Группы")
    }

    private func groupButton(_ group: TaskGroup) -> some View {
        let selected = selectedGroupID == group.id
        return Button {
            onSelect(group)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: group.colorHex))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
                Text(group.name).font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: chipWidth(group), height: 28)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
            .overlay {
                Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Открыть группу «\(group.name)»")
        .accessibilityLabel("Группа: \(group.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("groups.legend.\(group.id.uuidString)")
    }

    // Native menu items preserve this non-template image's actual group color.
    private func swatch(hex: String) -> NSImage {
        let color = NSColor(Color(hex: hex))
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
