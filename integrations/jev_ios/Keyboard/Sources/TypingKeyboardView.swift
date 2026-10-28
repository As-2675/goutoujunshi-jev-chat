import UIKit

/// Typing stays entirely on-device, including when keyboard Full Access is disabled.
@MainActor
final class TypingKeyboardView: UIView {
    private enum Layout { case letters, nine, numbers, symbols }
    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onKeyboardButtonCreated: ((UIButton) -> Void)? { didSet { renderKeys() } }
    private var chinese = true
    private var uppercase = false
    private var layout: Layout = .letters
    private var composition = PinyinComposition()
    /// 九宫格输入态（数字串）；与 composition（字母串）互斥，切布局时清空对应一侧。
    private var nineInput = ""
    private var engine: PinyinEngine?
    private var candidates = [PinyinCandidate]()
    private var lookupRevision = 0
    private let lookupQueue = DispatchQueue(label: "ai.goutoujunshi.pinyin", qos: .userInitiated)
    private let stack = UIStackView()
    private let preedit = KB.label("", size: 13)
    private let candidateScroll = UIScrollView()
    private let candidateRow = UIStackView()
    private let keys = UIStackView()
    private var deleteTimer: Timer?
    private var compact = false
    private var preeditHeight: NSLayoutConstraint!
    private var candidatesHeight: NSLayoutConstraint!
    /// 九宫格多一行键位，单键压到 40 才能在 326pt 的面板里放下。
    private var keyHeight: CGFloat { compact ? 32 : (layout == .nine ? 40 : 44) }

    var hasComposition: Bool { layout == .nine ? !nineInput.isEmpty : !composition.raw.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical; stack.spacing = 5
        keys.axis = .vertical; keys.spacing = 7
        candidateRow.axis = .horizontal; candidateRow.spacing = 6
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.delaysContentTouches = false
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateRow); candidateRow.translatesAutoresizingMaskIntoConstraints = false
        preedit.numberOfLines = 1
        preeditHeight = preedit.heightAnchor.constraint(equalToConstant: 18)
        candidatesHeight = candidateScroll.heightAnchor.constraint(equalToConstant: 44)
        preeditHeight.isActive = true; candidatesHeight.isActive = true
        [preedit, candidateScroll, keys].forEach { stack.addArrangedSubview($0) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            candidateRow.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor),
            candidateRow.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor),
            candidateRow.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateRow.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateRow.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor)
        ])
        renderKeys(); renderCandidates()
        let resource = Bundle.main.url(forResource: "pinyin", withExtension: "tsv")
        lookupQueue.async { [weak self] in
            let engine = resource.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(PinyinEngine.init(tsv:))
            DispatchQueue.main.async { [weak self] in self?.engine = engine; self?.refreshCandidates() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { deleteTimer?.invalidate() }

    func clearComposition() {
        composition.clear(); nineInput = ""; lookupRevision += 1; candidates = []; renderCandidates()
        deleteTimer?.invalidate(); deleteTimer = nil
    }
    func setCompactLayout(_ value: Bool) {
        guard compact != value else { return }
        compact = value
        preeditHeight.constant = value ? 14 : 18
        preedit.font = .systemFont(ofSize: value ? 11 : 13)
        candidatesHeight.constant = value ? 32 : 44
        keys.spacing = value ? 5 : 7
        renderKeys(); renderCandidates()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { deleteTimer?.invalidate(); deleteTimer = nil }
    }
    private func key(_ title: String, identifier: String? = nil, utility: Bool = false, fixedHeight: Bool = true, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title; config.cornerStyle = .fixed
        config.background.cornerRadius = 9
        config.baseBackgroundColor = utility ? KB.highlight : KB.surface
        config.baseForegroundColor = KB.ink
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming; result.font = .systemFont(ofSize: title.count > 1 ? 16 : 20); return result
        }
        button.configuration = config
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.12; button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.accessibilityIdentifier = identifier
        if fixedHeight { button.heightAnchor.constraint(equalToConstant: keyHeight).isActive = true }
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    private func letterRow(_ text: String, insetRatio: CGFloat = 0) -> UIView {
        let row = keyRow(text.map { character in
            let raw = String(character)
            return key(uppercase && !chinese ? raw.uppercased() : raw, identifier: "typingKey_" + raw) { [weak self] in self?.type(raw) }
        })
        guard insetRatio > 0 else { return row }
        let wrapper = UIView(); wrapper.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: wrapper.topAnchor), row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                                     row.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
                                     row.widthAnchor.constraint(equalTo: wrapper.widthAnchor, multiplier: 1 - insetRatio * 2)])
        return wrapper
    }
    private func keyRow(_ views: [UIView]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal; row.spacing = compact ? 4 : 5; row.distribution = .fillEqually
        return row
    }
    private func deleteKey(fixedHeight: Bool = true) -> UIButton {
        let button = key("⌫", identifier: "typingBackspace", utility: true, fixedHeight: fixedHeight) { [weak self] in self?.backspace() }
        button.accessibilityLabel = "删除"
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdDelete(_:)))
        hold.minimumPressDuration = 0.4
        button.addGestureRecognizer(hold)
        return button
    }
    @objc private func holdDelete(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            backspace()
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.backspace() }
            }
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            deleteTimer?.invalidate(); deleteTimer = nil
        }
    }
    private func renderKeys() {
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch layout {
        case .letters:
            keys.addArrangedSubview(letterRow("qwertyuiop"))
            keys.addArrangedSubview(letterRow("asdfghjkl", insetRatio: 0.05))
            let shift = key(chinese ? "分词" : "⇧", identifier: "typingShift", utility: true) { [weak self] in
                guard let self = self else { return }
                if self.chinese { self.composition.append("'"); self.refreshCandidates() }
                else { self.uppercase.toggle(); self.renderKeys() }
            }
            if !chinese && uppercase { shift.configuration?.baseBackgroundColor = KB.primary; shift.configuration?.baseForegroundColor = KB.onPrimary }
            shift.accessibilityLabel = chinese ? "拼音分隔符" : "切换大小写"
            let letters = keyRow("zxcvbnm".map { character in
                let raw = String(character)
                return key(uppercase && !chinese ? raw.uppercased() : raw, identifier: "typingKey_" + raw) { [weak self] in self?.type(raw) }
            })
            let third = UIStackView(arrangedSubviews: [shift, letters, deleteKey()])
            third.axis = .horizontal; third.spacing = 12; third.distribution = .fill
            shift.widthAnchor.constraint(equalTo: third.widthAnchor, multiplier: 0.11).isActive = true
            third.arrangedSubviews.last!.widthAnchor.constraint(equalTo: shift.widthAnchor).isActive = true
            keys.addArrangedSubview(third)
        case .nine:
            // 参考 iOS 自带九宫格：左侧一列标点、中间 3×3 数字键、右侧 ⌫/换行，
            // 底部一条「符号 / 123 / 空格 / 中英 / 地球」。数字键走 T9，小字是字母组。
            let punctKeys = ["@", "?", "。", "…"].map { value -> UIButton in
                let button = key(value, identifier: "typingNinePunct", utility: false, fixedHeight: false) { [weak self] in
                    self?.insertPunctuation(value)
                }
                button.accessibilityLabel = value
                return button
            }
            let leftColumn = UIStackView(arrangedSubviews: punctKeys)
            leftColumn.axis = .vertical; leftColumn.spacing = 3; leftColumn.distribution = .fillEqually

            let grid = [("1", "，"), ("2", "abc"), ("3", "def"),
                        ("4", "ghi"), ("5", "jkl"), ("6", "mno"),
                        ("7", "pqrs"), ("8", "tuv"), ("9", "wxyz")]
            let gridStack = UIStackView()
            gridStack.axis = .vertical; gridStack.spacing = 7
            for base in stride(from: 0, to: 9, by: 3) {
                gridStack.addArrangedSubview(keyRow((base..<base + 3).map { digitKey(grid[$0].0, letters: grid[$0].1) }))
            }

            let returnKey = key("换行", identifier: "typingNineReturn", utility: true, fixedHeight: false) { [weak self] in
                guard let self = self else { return }
                self.commitComposition(); self.onInsert?("\n")
            }
            let rightColumn = UIStackView(arrangedSubviews: [deleteKey(fixedHeight: false), returnKey])
            rightColumn.axis = .vertical; rightColumn.spacing = 3; rightColumn.distribution = .fillEqually

            let mainRow = UIStackView(arrangedSubviews: [leftColumn, gridStack, rightColumn])
            mainRow.axis = .horizontal; mainRow.spacing = 6; mainRow.alignment = .fill
            leftColumn.widthAnchor.constraint(equalTo: keys.widthAnchor, multiplier: 0.14).isActive = true
            rightColumn.widthAnchor.constraint(equalTo: keys.widthAnchor, multiplier: 0.17).isActive = true
            keys.addArrangedSubview(mainRow)

            let symbolKey = key("符号", identifier: "typingNineSymbols", utility: true) { [weak self] in
                guard let self = self else { return }
                self.commitComposition(); self.layout = .symbols; self.renderKeys()
            }
            let numbersKey = key("123", identifier: "typingNineNumbers", utility: true) { [weak self] in
                guard let self = self else { return }
                self.commitComposition(); self.layout = .numbers; self.renderKeys()
            }
            let spaceKey = key("空格", identifier: "typingNineSpace") { [weak self] in
                guard let self = self else { return }
                if self.hasComposition { self.commitComposition() } else { self.onInsert?(" ") }
            }
            spaceKey.accessibilityLabel = "空格"
            let languageKey = key(chinese ? "中" : "英", identifier: "typingNineLanguage", utility: true) { [weak self] in
                guard let self = self else { return }
                self.commitComposition(); self.chinese.toggle(); self.renderKeys(); self.renderCandidates()
            }
            languageKey.accessibilityLabel = chinese ? "中文输入，点击切换英文" : "英文输入，点击切换中文"
            let globeKey = key("", identifier: "typingNineGlobe", utility: true) {}
            globeKey.configuration?.image = UIImage(systemName: "globe")
            globeKey.accessibilityLabel = "切换到其他键盘"
            onKeyboardButtonCreated?(globeKey)
            let bottom = UIStackView(arrangedSubviews: [symbolKey, numbersKey, spaceKey, languageKey, globeKey])
            bottom.axis = .horizontal; bottom.spacing = 5; bottom.distribution = .fill
            symbolKey.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.14).isActive = true
            numbersKey.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.14).isActive = true
            languageKey.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.16).isActive = true
            globeKey.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.14).isActive = true
            keys.addArrangedSubview(bottom)
            return
        case .numbers, .symbols:
            let rows = layout == .numbers ? ["1234567890", "-/:;()¥&@\""] : ["[]{}#%^*+=", "_\\|~<>€£•$"]
            rows.forEach { keys.addArrangedSubview(letterRow($0)) }
            let page = key(layout == .numbers ? "#+=" : "123", identifier: "typingSymbolPage", utility: true) { [weak self] in
                guard let self = self else { return }; self.layout = self.layout == .numbers ? .symbols : .numbers; self.renderKeys()
            }
            let punctuation = chinese ? ["，", "。", "？", "！", "、", "…", "'" ] : [",", ".", "?", "!", ":", ";", "'"]
            keys.addArrangedSubview(keyRow([page] + punctuation.map { value in key(value) { [weak self] in self?.insertPunctuation(value) } } + [deleteKey()]))
        }
        let alphabetTitle: String
        switch layout {
        case .letters: alphabetTitle = "123"
        case .numbers: alphabetTitle = "九宫"
        case .nine: alphabetTitle = "ABC"
        case .symbols: alphabetTitle = "123"
        }
        let alphabet = key(alphabetTitle, identifier: "typingLayout", utility: true) { [weak self] in
            guard let self = self else { return }
            self.commitComposition()
            switch self.layout {
            case .letters: self.layout = .numbers
            case .numbers: self.layout = .nine
            case .nine: self.layout = .letters
            case .symbols: self.layout = .numbers
            }
            self.renderKeys(); self.renderCandidates()
        }
        let language = key(chinese ? "中" : "英", identifier: "typingLanguage", utility: true) { [weak self] in
            guard let self = self else { return }; self.commitComposition(); self.chinese.toggle(); self.renderKeys(); self.renderCandidates()
        }
        language.accessibilityLabel = chinese ? "中文输入，点击切换英文" : "英文输入，点击切换中文"
        let globe = key("", identifier: "typingNextKeyboard", utility: true) {}
        globe.configuration?.image = UIImage(systemName: "globe")
        globe.accessibilityLabel = "切换到其他键盘"
        onKeyboardButtonCreated?(globe)
        let punctuation = key(chinese ? "，" : ",", identifier: "typingComma") { [weak self] in self?.insertPunctuation(self?.chinese == true ? "，" : ",") }
        let space = key("空格", identifier: "typingSpace") { [weak self] in
            guard let self = self else { return }
            if self.hasComposition { self.commitComposition() } else { self.onInsert?(" ") }
        }
        let enter = key("换行", identifier: "typingReturn", utility: true) { [weak self] in self?.commitComposition(); self?.onInsert?("\n") }
        enter.accessibilityLabel = "插入换行，不发送消息"
        let row = UIStackView(arrangedSubviews: [alphabet, globe, language, punctuation, space, enter])
        row.axis = .horizontal; row.spacing = 5; row.distribution = .fill
        alphabet.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.105).isActive = true
        globe.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.095).isActive = true
        language.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.095).isActive = true
        punctuation.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.075).isActive = true
        enter.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.16).isActive = true
        space.accessibilityLabel = "空格，拼音输入时选第一个完整候选"
        keys.addArrangedSubview(row)
    }
    private func type(_ character: String) {
        if chinese && layout == .letters {
            composition.append(character); refreshCandidates()
        } else { onInsert?(uppercase && layout == .letters ? character.uppercased() : character) }
    }
    private func typeDigit(_ digit: String) {
        guard layout == .nine else { onInsert?(digit); return }
        guard nineInput.count < 24 else { return }
        nineInput += digit
        refreshCandidates()
    }

    /// 九宫格键：大字是数字，小字是该键的字母组（abc / def …）。
    private func digitKey(_ digit: String, letters: String) -> UIButton {
        let button = key(digit, identifier: "typingDigit_" + digit) { [weak self] in self?.typeDigit(digit) }
        if var config = button.configuration {
            config.subtitle = letters
            config.titleAlignment = .center
            config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var result = incoming
                result.font = .systemFont(ofSize: 10, weight: .medium)
                return result
            }
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var result = incoming
                result.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
                return result
            }
            button.configuration = config
        }
        button.accessibilityLabel = "\(digit) \(letters)"
        return button
    }
    private func insertPunctuation(_ value: String) { commitComposition(); onInsert?(value) }
    private func backspace() {
        if layout == .nine {
            if !nineInput.isEmpty { nineInput.removeLast(); refreshCandidates(); return }
            onDelete?(); return
        }
        if composition.backspace() { refreshCandidates() } else { onDelete?() }
    }
    private func commitComposition() {
        guard hasComposition else { return }
        if layout == .nine {
            if let first = candidates.first { onInsert?(first.text) }
            nineInput = ""
            refreshCandidates()
            return
        }
        // Never insert an incomplete leading-word candidate while dropping the remaining syllables.
        let available = candidates.isEmpty ? (engine?.candidates(for: composition.raw) ?? []) : candidates
        if let candidate = available.first, candidate.consumed == composition.raw.count,
           let text = composition.select(candidate) { onInsert?(text) }
        else { let text = composition.raw; composition.clear(); onInsert?(text) }
        refreshCandidates()
    }
    private func refreshCandidates() {
        lookupRevision += 1
        let revision = lookupRevision
        let nine = layout == .nine
        let raw = nine ? nineInput : composition.raw
        candidates = []; renderCandidates()
        guard !raw.isEmpty, let engine = engine else { return }
        lookupQueue.async { [weak self] in
            let result = nine ? engine.candidates(forDigits: raw) : engine.candidates(for: raw)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.lookupRevision == revision else { return }
                let current = self.layout == .nine ? self.nineInput : self.composition.raw
                guard current == raw else { return }
                self.candidates = result; self.renderCandidates()
            }
        }
    }
    private func renderCandidates() {
        let raw = layout == .nine ? nineInput : composition.raw
        preedit.text = raw.isEmpty ? (chinese ? "中文拼音 · 本地输入" : "英文 · 本地输入") : raw
        preedit.textColor = KB.secondary
        candidateRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        candidateScroll.contentOffset = .zero
        if raw.isEmpty {
            for value in (chinese ? ["。", "？", "！", "😊", "👍", "❤️"] : [".", "?", "!", "😊", "👍", "❤️"]) {
                candidateRow.addArrangedSubview(key(value) { [weak self] in self?.insertPunctuation(value) })
            }
            candidateRow.addArrangedSubview(key("←", identifier: "typingCursorLeft") { [weak self] in self?.onMove?(-1) })
            candidateRow.addArrangedSubview(key("→", identifier: "typingCursorRight") { [weak self] in self?.onMove?(1) })
        } else {
            for (index, candidate) in candidates.enumerated() {
                let button = key(candidate.text, identifier: "pinyinCandidate_\(index)") { [weak self] in
                    guard let self = self else { return }
                    if self.layout == .nine {
                        self.nineInput = ""
                        self.onInsert?(candidate.text)
                        self.refreshCandidates()
                        return
                    }
                    guard let text = self.composition.select(candidate) else { return }
                    self.onInsert?(text); self.refreshCandidates()
                }
                button.accessibilityLabel = "拼音候选：" + candidate.text
                candidateRow.addArrangedSubview(button)
            }
            if layout != .nine {
                candidateRow.addArrangedSubview(key(raw, identifier: "pinyinRaw") { [weak self] in
                    guard let self = self, self.composition.raw == raw else { return }
                    self.composition.clear(); self.onInsert?(raw); self.refreshCandidates()
                })
            }
        }
        for case let button as UIButton in candidateRow.arrangedSubviews {
            let title = button.configuration?.title ?? ""
            let width = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 20)]).width + 24
            button.widthAnchor.constraint(equalToConstant: max(44, width)).isActive = true
            if var config = button.configuration {
                config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var result = incoming; result.font = .systemFont(ofSize: 20); return result
                }
                config.titleLineBreakMode = .byClipping
                button.configuration = config
            }
        }
    }
}
