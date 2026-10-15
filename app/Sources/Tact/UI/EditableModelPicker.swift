import AppKit
import SwiftUI

/// A native editable dropdown: endpoint discovery never prevents a manual ID.
struct EditableModelPicker: NSViewRepresentable {
    @Binding var model: String
    let models: [RemoteModel]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.isEditable = true
        field.completes = true
        field.numberOfVisibleItems = 12
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = L10n.tr("选择或输入模型 ID", "Choose or enter a model ID")
        field.setAccessibilityLabel(L10n.tr("模型", "Model"))
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSComboBox, context: Context) {
        context.coordinator.parent = self
        let ids = models.map(\.id)
        if context.coordinator.ids != ids {
            field.removeAllItems()
            field.addItems(withObjectValues: ids)
            context.coordinator.ids = ids
        }
        if field.stringValue != model { field.stringValue = model }
        field.placeholderString = L10n.tr("选择或输入模型 ID", "Choose or enter a model ID")
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: EditableModelPicker
        var ids: [String] = []

        init(_ parent: EditableModelPicker) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox else { return }
            parent.model = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox, ids.indices.contains(field.indexOfSelectedItem) else { return }
            parent.model = ids[field.indexOfSelectedItem]
        }
    }
}
