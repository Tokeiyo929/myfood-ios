import SwiftUI
import UIKit

// 可选中文本块：非编辑 UITextView，长按选词、拖两端手柄扩选，系统编辑菜单（复制/查询）。
// 选区变化回吐给 OCR 面板「填入所选」；空选区回调空串。
@MainActor
struct SelectableTextView: UIViewRepresentable {
    let text: String
    var onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView

        init(parent: SelectableTextView) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, let full = textView.text else {
                parent.onSelectionChange("")
                return
            }
            parent.onSelectionChange((full as NSString).substring(with: range))
        }
    }
}
