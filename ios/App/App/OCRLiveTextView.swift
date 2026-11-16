import SwiftUI
import VisionKit
import ImageIO

// Live Text 图片选字叠层（对齐主流 OCR 做法）：UIImageView + ImageAnalysisInteraction。
// 文字直接叠在图上：双击选词、拖两端手柄扩选；选区变化经 delegate 回吐给面板「填入所选」。
// 仅 ImageAnalyzer.isSupported（A12 及以后芯片）可用，调用方负责兜底字符网格。
@MainActor
struct OCRLiveTextView: UIViewRepresentable {
    let image: UIImage
    var onSelectionChange: (String) -> Void
    var onAnalyzed: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .black
        view.clipsToBounds = true
        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .textSelection
        interaction.delegate = context.coordinator
        context.coordinator.interaction = interaction
        view.addInteraction(interaction)
        context.coordinator.analyze()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, ImageAnalysisInteractionDelegate {
        var parent: OCRLiveTextView
        weak var interaction: ImageAnalysisInteraction?

        init(parent: OCRLiveTextView) {
            self.parent = parent
        }

        // 图片已在 OCRViewModel 里烘焙成直立方向，orientation 固定 .up
        func analyze() {
            guard ImageAnalyzer.isSupported, let interaction else {
                parent.onAnalyzed(false)
                return
            }
            let image = parent.image
            Task { @MainActor in
                let analyzer = ImageAnalyzer()
                let config = ImageAnalyzer.Configuration(.text)
                do {
                    let analysis = try await analyzer.analyze(image, orientation: .up, configuration: config)
                    interaction.analysis = analysis
                    parent.onAnalyzed(!analysis.transcript.isEmpty)
                } catch {
                    parent.onAnalyzed(false)
                }
            }
        }

        func textSelectionDidChange(_ interaction: ImageAnalysisInteraction) {
            parent.onSelectionChange(interaction.selectedText)
        }
    }
}
