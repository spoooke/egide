import UIKit
import AVFoundation
import Combine

/// Full‑screen remote control surface.
///
/// Gestures
///   Mode Trackpad (default): 1 finger moves the cursor, tap = click, long press + move = drag.
///   Mode Tactile: tap = click where you touch, 1 finger drag = mouse drag, long press = right click.
///   Both: 2‑finger tap = right click, 2‑finger swipe = scroll, pinch = zoom (and move while pinching).
final class RemoteViewController: UIViewController, UIGestureRecognizerDelegate {
    enum Mode { case trackpad, touch }

    private let client: RemoteClient
    private let onClose: () -> Void

    private let videoView = VideoView()
    private let keyInput = KeyInputView()
    private let toolbar = UIStackView()
    private let statsLabel = UILabel()
    private let zoomResetButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private var hideToolbarWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private var mode: Mode = .trackpad {
        didSet { updateModeButton() }
    }
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var dragging = false
    private var pinchGesture: UIPinchGestureRecognizer!
    private var lastPointerSend: CFTimeInterval = 0

    init(client: RemoteClient, onClose: @escaping () -> Void) {
        self.client = client
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(videoView)
        client.videoView = videoView

        keyInput.onText = { [weak self] text in self?.typed(text) }
        keyInput.onBackspace = { [weak self] in self?.pressKey(51) }
        keyInput.onKey = { [weak self] code in self?.pressKey(code) }
        keyInput.onModifiersChanged = { _ in }
        view.addSubview(keyInput)

        setupGestures()
        setupToolbar()

        client.$videoSize.receive(on: RunLoop.main).sink { [weak self] _ in self?.view.setNeedsLayout() }.store(in: &cancellables)
        Publishers.CombineLatest(client.$fps, client.$latencyMs).receive(on: RunLoop.main).sink { [weak self] fps, ms in
            self?.statsLabel.text = "\(fps) i/s" + (ms.map { " · \($0) ms" } ?? "")
        }.store(in: &cancellables)

        UIApplication.shared.isIdleTimerDisabled = true
        client.requestKeyframe()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Layout & zoom

    private var fittedRect: CGRect {
        let size = client.videoSize
        let bounds = view.bounds
        guard size.width > 0, size.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: size, insideRect: bounds)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let rect = fittedRect
        videoView.bounds = CGRect(origin: .zero, size: rect.size)
        videoView.center = CGPoint(x: rect.midX, y: rect.midY)
        applyZoom()
    }

    private func applyZoom() {
        let size = videoView.bounds.size
        let maxX = max(0, (size.width * zoom - view.bounds.width) / 2)
        let maxY = max(0, (size.height * zoom - view.bounds.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
        if zoom <= 1.001 { pan = .zero }
        videoView.transform = CGAffineTransform(translationX: pan.x, y: pan.y).scaledBy(x: zoom, y: zoom)
        zoomResetButton.isHidden = zoom <= 1.001
    }

    /// Keeps the cursor visible when zoomed in trackpad mode.
    private func followCursor() {
        guard zoom > 1.001 else { return }
        let size = videoView.bounds.size
        let local = CGPoint(x: (cursor.x - 0.5) * size.width, y: (cursor.y - 0.5) * size.height)
        let onScreen = CGPoint(x: view.bounds.midX + pan.x + local.x * zoom, y: view.bounds.midY + pan.y + local.y * zoom)
        let margin: CGFloat = 60
        if onScreen.x < margin { pan.x += margin - onScreen.x }
        if onScreen.x > view.bounds.width - margin { pan.x -= onScreen.x - (view.bounds.width - margin) }
        if onScreen.y < margin { pan.y += margin - onScreen.y }
        if onScreen.y > view.bounds.height - margin { pan.y -= onScreen.y - (view.bounds.height - margin) }
        applyZoom()
    }

    // MARK: Gestures

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let pan1 = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan1.maximumNumberOfTouches = 1

        let pan2 = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        pan2.minimumNumberOfTouches = 2
        pan2.maximumNumberOfTouches = 2
        pan2.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        pinchGesture = pinch

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.35

        for g in [tap, twoFingerTap, pan1, pan2, pinch, long] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    /// Normalised (0…1) position on the Mac screen for a touch.
    private func normalized(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: videoView)
        let s = videoView.bounds.size
        return CGPoint(x: min(max(p.x / max(s.width, 1), 0), 1), y: min(max(p.y / max(s.height, 1), 0), 1))
    }

    private func sendPointer(_ p: CGPoint) {
        client.send(.pointer(x: Float(p.x), y: Float(p.y)))
    }

    private func click(_ button: Message.MouseButton, at p: CGPoint) {
        client.send(.pointer(x: Float(p.x), y: Float(p.y)))
        client.send(.button(button, down: true, x: Float(p.x), y: Float(p.y)))
        client.send(.button(button, down: false, x: Float(p.x), y: Float(p.y)))
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if mode == .touch { cursor = normalized(g) }
        click(.left, at: cursor)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        if mode == .touch { cursor = normalized(g) }
        click(.right, at: cursor)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch mode {
        case .touch:
            let p = normalized(g)
            cursor = p
            switch g.state {
            case .began:
                // Start the drag where the finger first touched.
                let start = g.location(in: videoView)
                let t = g.translation(in: videoView)
                let s = videoView.bounds.size
                let origin = CGPoint(x: min(max((start.x - t.x) / s.width, 0), 1), y: min(max((start.y - t.y) / s.height, 0), 1))
                sendPointer(origin)
                client.send(.button(.left, down: true, x: Float(origin.x), y: Float(origin.y)))
                sendPointer(p)
            case .changed:
                sendPointer(p)
            default:
                client.send(.button(.left, down: false, x: Float(p.x), y: Float(p.y)))
            }
        case .trackpad:
            moveCursor(by: g)
        }
    }

    /// Relative movement with acceleration, like a laptop trackpad.
    private func moveCursor(by g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        let v = g.velocity(in: view)
        let speed = hypot(v.x, v.y)
        let accel = min(max(speed / 800, 0.6), 2.5)
        let size = videoView.bounds.size
        let factor = 1.4 * accel / zoom
        cursor.x = min(max(cursor.x + t.x * factor / max(size.width, 1), 0), 1)
        cursor.y = min(max(cursor.y + t.y * factor / max(size.height, 1), 0), 1)
        sendPointer(cursor)
        followCursor()
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        switch mode {
        case .touch:
            if g.state == .began {
                cursor = normalized(g)
                click(.right, at: cursor)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case .trackpad:
            // Long press then move = drag (select text, move windows…).
            switch g.state {
            case .began:
                dragging = true
                lastLongPressPoint = g.location(in: view)
                client.send(.button(.left, down: true, x: Float(cursor.x), y: Float(cursor.y)))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .changed:
                let p = g.location(in: view)
                let size = videoView.bounds.size
                cursor.x = min(max(cursor.x + (p.x - lastLongPressPoint.x) * 1.4 / zoom / max(size.width, 1), 0), 1)
                cursor.y = min(max(cursor.y + (p.y - lastLongPressPoint.y) * 1.4 / zoom / max(size.height, 1), 0), 1)
                lastLongPressPoint = p
                sendPointer(cursor)
                followCursor()
            default:
                dragging = false
                client.send(.button(.left, down: false, x: Float(cursor.x), y: Float(cursor.y)))
            }
        }
    }
    private var lastLongPressPoint = CGPoint.zero

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        if pinchGesture.state == .began || pinchGesture.state == .changed {
            pan.x += t.x
            pan.y += t.y
            applyZoom()
        } else {
            client.send(.scroll(dx: Float(t.x * 2.5 / zoom), dy: Float(t.y * 2.5 / zoom)))
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let newZoom = min(max(zoom * g.scale, 1), 5)
        // Keep the point between the fingers fixed on screen.
        let p = g.location(in: view)
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let ratio = newZoom / zoom
        pan.x = (p.x - c.x) - ratio * (p.x - c.x - pan.x)
        pan.y = (p.y - c.y) - ratio * (p.y - c.y - pan.y)
        zoom = newZoom
        g.scale = 1
        applyZoom()
    }

    // MARK: Keyboard

    private func typed(_ text: String) {
        let mods = keyInput.modifiers
        if !mods.isEmpty, text.count == 1, text != "\n" {
            client.send(.keyChar(text, modifiers: mods))
            keyInput.clearModifiers()
        } else if text == "\n" {
            pressKey(36)
        } else {
            client.send(.text(text))
        }
    }

    private func pressKey(_ code: UInt16) {
        client.send(.key(code: code, modifiers: keyInput.modifiers))
        keyInput.clearModifiers()
    }

    @objc private func toggleKeyboard() {
        if keyInput.isFirstResponder { keyInput.resignFirstResponder() } else { keyInput.becomeFirstResponder() }
        showToolbar()
    }

    // MARK: Toolbar

    private func setupToolbar() {
        func button(_ symbol: String, _ action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.addTarget(self, action: action, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return b
        }
        let close = button("xmark", #selector(closeTapped))
        close.tintColor = .systemRed
        let keyboard = button("keyboard", #selector(toggleKeyboard))
        modeButton.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        modeButton.tintColor = .white
        modeButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        updateModeButton()
        zoomResetButton.setImage(UIImage(systemName: "arrow.down.right.and.arrow.up.left"), for: .normal)
        zoomResetButton.tintColor = .white
        zoomResetButton.addTarget(self, action: #selector(resetZoom), for: .touchUpInside)
        zoomResetButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        zoomResetButton.isHidden = true

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = UIColor.white.withAlphaComponent(0.8)

        [close, keyboard, modeButton, zoomResetButton, statsLabel].forEach { toolbar.addArrangedSubview($0) }
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 4
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 14)
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toolbar.layer.cornerRadius = 20
        toolbar.layer.cornerCurve = .continuous
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            toolbar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        showToolbar()
    }

    private func showToolbar() {
        hideToolbarWork?.cancel()
        UIView.animate(withDuration: 0.2) { self.toolbar.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.toolbar.alpha = 0.3 }
        }
        hideToolbarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func updateModeButton() {
        let symbol = mode == .trackpad ? "cursorarrow.motionlines" : "hand.point.up.left"
        modeButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
    }

    @objc private func toggleMode() {
        mode = mode == .trackpad ? .touch : .trackpad
        showToolbar()
        let banner = UILabel()
        banner.text = mode == .trackpad ? "Mode trackpad" : "Mode tactile"
        banner.textColor = .white
        banner.font = .systemFont(ofSize: 15, weight: .semibold)
        banner.textAlignment = .center
        banner.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        banner.layer.cornerRadius = 12
        banner.clipsToBounds = true
        banner.frame = CGRect(x: 0, y: 0, width: 180, height: 40)
        banner.center = view.center
        view.addSubview(banner)
        UIView.animate(withDuration: 0.4, delay: 0.8, options: []) { banner.alpha = 0 } completion: { _ in banner.removeFromSuperview() }
    }

    @objc private func resetZoom() {
        UIView.animate(withDuration: 0.25) {
            self.zoom = 1
            self.pan = .zero
            self.applyZoom()
        }
    }

    @objc private func closeTapped() {
        keyInput.resignFirstResponder()
        onClose()
    }
}

// MARK: - Keyboard input

/// Invisible view that receives the iOS keyboard, with a bar of Mac keys above it.
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((UInt16) -> Void)?
    var onModifiersChanged: ((Message.Modifiers) -> Void)?

    private(set) var modifiers: Message.Modifiers = [] {
        didSet { updateModifierButtons(); onModifiersChanged?(modifiers) }
    }
    private var modifierButtons: [(Message.Modifiers, UIButton)] = []
    private lazy var bar: UIInputView = makeBar()

    // UITextInputTraits: raw typing, no iOS "help".
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }
    var hasText: Bool { true }

    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    func clearModifiers() { if !modifiers.isEmpty { modifiers = [] } }

    private func makeBar() -> UIInputView {
        let input = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        input.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: input.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: input.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])

        func key(_ title: String, _ handler: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.gray()
            config.title = title
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in
                UIDevice.current.playInputClick()
                handler()
            })
            stack.addArrangedSubview(b)
            return b
        }
        for (label, mod) in [("⌘", Message.Modifiers.command), ("⌥", .option), ("⌃", .control), ("⇧", .shift)] {
            let b = key(label) { [weak self] in
                guard let self else { return }
                if self.modifiers.contains(mod) { self.modifiers.remove(mod) } else { self.modifiers.insert(mod) }
            }
            modifierButtons.append((mod, b))
        }
        let keys: [(String, UInt16)] = [("esc", 53), ("⇥", 48), ("←", 123), ("↑", 126), ("↓", 125), ("→", 124),
                                        ("⌦", 117), ("⇞", 116), ("⇟", 121), ("↖", 115), ("↘", 119)]
        for (label, code) in keys { _ = key(label) { [weak self] in self?.onKey?(code) } }
        _ = key("Spotlight") { [weak self] in
            self?.modifiers = [.command]
            self?.onKey?(49)
        }
        return input
    }

    private func updateModifierButtons() {
        for (mod, b) in modifierButtons {
            var config = modifiers.contains(mod) ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            config.title = b.configuration?.title
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            b.configuration = config
        }
    }
}

extension KeyInputView: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
