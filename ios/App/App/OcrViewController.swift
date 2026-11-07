import UIKit
import Vision

// OCR 划选（对齐小程序 detail 页 ocrOverlay）：
// Vision 识别图片文字 → 字格面板 → 手指划选字符 → 填入 产品名/品牌/原料
final class OcrViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    enum Target { case name, brand, ingredient }
    private static let targetDefs: [(Target, String)] = [(.name, "产品名"), (.brand, "品牌"), (.ingredient, "原料")]

    var onName: ((String) -> Void)?
    var onBrand: ((String) -> Void)?
    var onIngredient: ((String) -> Void)?

    private let sourceImage: UIImage
    private var chars: [String] = []
    private var picked: Set<Int> = []
    private var target: Target = .name
    private var strokeMode = false
    private var lastHit: Int?
    private(set) var recognized = false // Vision 识别完成且有结果（冒烟截图信号）

    private let panel = UIView()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let collection: UICollectionView
    private var targetBtns: [UIButton] = []
    private let addBtn = UIButton(type: .system)
    private let clearBtn = UIButton(type: .system)

    init(image: UIImage) {
        sourceImage = image
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.6)

        panel.backgroundColor = .white
        panel.layer.cornerRadius = 12
        panel.layer.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let title = UILabel()
        title.text = "在图上点选文字"
        title.font = .boldSystemFont(ofSize: 16)
        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("完成", for: .normal)
        closeBtn.setTitleColor(Theme.primary, for: .normal)
        closeBtn.titleLabel?.font = .boldSystemFont(ofSize: 15)
        closeBtn.addTarget(self, action: #selector(closeOcr), for: .touchUpInside)
        let head = UIStackView(arrangedSubviews: [title, spacer(), closeBtn])
        head.axis = .horizontal

        let targetsRow = UIStackView(arrangedSubviews: OcrViewController.targetDefs.map { def -> UIButton in
            let b = UIButton(type: .system)
            b.setTitle(def.1, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13)
            b.layer.cornerRadius = 12
            b.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
            b.addAction(UIAction(handler: { [weak self] _ in self?.setTarget(def.0) }), for: .touchUpInside)
            targetBtns.append(b)
            return b
        })
        targetsRow.axis = .horizontal
        targetsRow.spacing = 8

        statusLabel.text = "识别中…"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel

        hintLabel.text = "已选：（空）"
        hintLabel.font = .systemFont(ofSize: 14)
        hintLabel.textColor = Theme.primary

        addBtn.setTitle("＋添加", for: .normal)
        addBtn.setTitleColor(.white, for: .normal)
        addBtn.titleLabel?.font = .boldSystemFont(ofSize: 13)
        addBtn.backgroundColor = Theme.primary
        addBtn.layer.cornerRadius = 12
        addBtn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        addBtn.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            self.applyBuilt()
            Toast.show("已填入", self.view)
        }), for: .touchUpInside)
        clearBtn.setTitle("清空", for: .normal)
        clearBtn.setTitleColor(.systemRed, for: .normal)
        clearBtn.titleLabel?.font = .systemFont(ofSize: 13)
        clearBtn.layer.cornerRadius = 12
        clearBtn.layer.borderWidth = 1
        clearBtn.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.5).cgColor
        clearBtn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        clearBtn.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            self.resetPicked()
            Toast.show("已清空", self.view)
        }), for: .touchUpInside)
        let actionsRow = UIStackView(arrangedSubviews: [spacer(), addBtn, clearBtn])
        actionsRow.axis = .horizontal
        actionsRow.spacing = 8

        collection.backgroundColor = UIColor(white: 0.96, alpha: 1)
        collection.layer.cornerRadius = 8
        collection.dataSource = self
        collection.delegate = self
        collection.register(OcrCharCell.self, forCellWithReuseIdentifier: "ocrchar")
        collection.alwaysBounceVertical = true
        let stroke = UILongPressGestureRecognizer(target: self, action: #selector(strokeGesture(_:)))
        stroke.minimumPressDuration = 0.05
        stroke.allowableMovement = CGFloat.greatestFiniteMagnitude
        collection.addGestureRecognizer(stroke)

        let sv = UIStackView(arrangedSubviews: [head, targetsRow, statusLabel, hintLabel, actionsRow, collection])
        sv.axis = .vertical
        sv.spacing = 10
        sv.setCustomSpacing(4, after: statusLabel)
        sv.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(sv)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            sv.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            sv.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            sv.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            sv.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            collection.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            collection.heightAnchor.constraint(lessThanOrEqualToConstant: 300), // 空灰区别拉满整屏（视觉测试暴露）
        ])
        updateTargetButtons()
        updateHint()
        recognize()
    }

    private func spacer() -> UIView { UIView() }

    // MARK: - Vision 识别

    private func recognize() {
        // 方向归一化（Vision 需要上朝向的 CGImage）
        let format = UIGraphicsImageRendererFormat.default()
        let renderer = UIGraphicsImageRenderer(size: sourceImage.size, format: format)
        let upright = renderer.image { _ in sourceImage.draw(in: CGRect(origin: .zero, size: sourceImage.size)) }
        guard let cg = upright.cgImage else {
            finishRecognition([])
            return
        }
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
            var texts: [String] = []
            for o in obs {
                if let t = o.topCandidates(1).first { texts.append(t.string) }
            }
            DispatchQueue.main.async { self?.finishRecognition(texts) }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = true
        DispatchQueue.global().async {
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
        }
    }

    private func finishRecognition(_ texts: [String]) {
        // 每段识别文本拆成单字（对齐小程序 items 平铺）
        var items: [String] = []
        for t in texts {
            for ch in t { items.append(String(ch)) }
        }
        guard !items.isEmpty else {
            statusLabel.text = "未识别到文字"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.dismiss(animated: false)
            }
            return
        }
        chars = items
        recognized = true
        statusLabel.text = "共\(items.count)个字，按住划选"
        collection.reloadData()
    }

    // MARK: - 划选

    @objc private func strokeGesture(_ g: UILongPressGestureRecognizer) {
        let loc = g.location(in: collection)
        switch g.state {
        case .began:
            guard let idx = hitIndex(at: loc) else { return }
            // 划选 = 选中范围：起点字总是点亮，整段滑动全选
            strokeMode = true
            lastHit = idx
            setChar(idx, on: true)
        case .changed:
            guard strokeMode, let idx = hitIndex(at: loc) else { return }
            // 连续性：从上一个命中到当前命中之间的字全部选中
            if let last = lastHit {
                let lo = min(last, idx), hi = max(last, idx)
                for i in lo...hi where !picked.contains(i) { setChar(i, on: true) }
            } else {
                setChar(idx, on: true)
            }
            lastHit = idx
        default:
            strokeMode = false
            lastHit = nil
        }
    }

    private func hitIndex(at loc: CGPoint) -> Int? {
        guard let p = collection.indexPathForItem(at: loc) else { return nil }
        let idx = p.item
        guard idx >= 0, idx < chars.count else { return nil }
        return idx
    }

    private func setChar(_ idx: Int, on: Bool) {
        if on { picked.insert(idx) } else { picked.remove(idx) }
        if let cell = collection.cellForItem(at: IndexPath(item: idx, section: 0)) as? OcrCharCell {
            cell.setPicked(on)
        }
        updateHint()
    }

    private func builtText() -> String {
        chars.enumerated().filter { picked.contains($0.offset) }.map { $0.element }.joined()
    }

    private func resetPicked() {
        picked = []
        collection.reloadData()
        updateHint()
    }

    private func updateHint() {
        let text = builtText()
        hintLabel.text = "已选：\(text.isEmpty ? "（空）" : text)"
        addBtn.isHidden = text.isEmpty
        clearBtn.isHidden = text.isEmpty
    }

    // MARK: - 目标 / 填入

    private func setTarget(_ t: Target) {
        guard t != target else { return }
        applyBuilt()   // 换目标前，把当前已选字填进当前字段（沿用小程序设计）
        target = t
        resetPicked()
        updateTargetButtons()
    }

    private func applyBuilt() {
        let text = builtText().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        switch target {
        case .name: onName?(text)
        case .brand: onBrand?(text)
        case .ingredient: onIngredient?(text)
        }
        resetPicked()
    }

    @objc private func closeOcr() {
        applyBuilt()
        dismiss(animated: false)
    }

    private func updateTargetButtons() {
        for (i, def) in OcrViewController.targetDefs.enumerated() {
            let active = def.0 == target
            let b = targetBtns[i]
            b.backgroundColor = active ? Theme.primary : UIColor(white: 0.94, alpha: 1)
            b.setTitleColor(active ? .white : Theme.primary, for: .normal)
        }
    }

    // MARK: - collection

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { chars.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ocrchar", for: indexPath) as! OcrCharCell
        cell.bind(chars[indexPath.item], picked: picked.contains(indexPath.item))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        // 8 列字格
        let w = floor((collectionView.bounds.width - 4 * 7) / 8)
        return CGSize(width: w, height: 34)
    }
}

private final class OcrCharCell: UICollectionViewCell {
    private let lb = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        lb.font = .systemFont(ofSize: 14)
        lb.textAlignment = .center
        lb.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lb)
        contentView.layer.cornerRadius = 4
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor(white: 0.85, alpha: 1).cgColor
        contentView.backgroundColor = .white
        NSLayoutConstraint.activate([
            lb.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            lb.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ ch: String, picked: Bool) {
        lb.text = ch
        setPicked(picked)
    }

    func setPicked(_ on: Bool) {
        contentView.backgroundColor = on ? Theme.primary : .white
        contentView.layer.borderColor = on ? Theme.primary.cgColor : UIColor(white: 0.85, alpha: 1).cgColor
        lb.textColor = on ? .white : .label
    }
}
