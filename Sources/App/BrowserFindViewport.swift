import Foundation

/// WebKit's native find scroller subtracts the docked input panel's full height
/// from its own bounds. A SwiftUI host may already have removed that space.
/// Reserve only the portion not already overlapping the visible container.
enum BrowserFindViewport {
    static func reservedHeight(viewport: CGRect, keyboard: CGRect, window: CGRect,
                               finding: Bool) -> CGFloat {
        guard finding, valid(viewport), valid(keyboard), valid(window) else { return 0 }
        let input = keyboard.intersection(window)
        guard valid(input), input.minX <= window.minX + 1,
              input.maxX >= window.maxX - 1, input.maxY >= window.maxY - 1 else { return 0 }
        let overlap = viewport.intersection(input)
        let overlappingHeight = valid(overlap) ? overlap.height : 0
        // WebKit subtracts the full screen-clipped input panel, including any
        // part beyond a smaller window. Only the visible overlap is deducted.
        return max(0, keyboard.height - overlappingHeight)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }
}

#if os(iOS)
import UIKit
import WebKit

@MainActor
final class BrowserWebContainer: UIView {
    private let webView: WKWebView
    private let onDetach: () -> Void
    private var keyboardFrameInScreen = CGRect.zero
    private var bottom: NSLayoutConstraint!

    init(webView: WKWebView, onDetach: @escaping () -> Void) {
        self.webView = webView
        self.onDetach = onDetach
        super.init(frame: .zero)
        isAccessibilityElement = false
        accessibilityIdentifier = "browser.viewport"
        // The extended WebKit canvas must never cover browser chrome, receive
        // touches outside this viewport, or expose text drawn outside it.
        clipsToBounds = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        bottom = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor), bottom
        ])
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { return nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func keyboardChanged(_ notification: Notification) {
        // Keyboard notifications identify their screen on iOS 16.1 and later.
        // A keyboard on another display must not resize this browser window.
        if let screen = notification.object as? UIScreen, let window, screen !== window.screen { return }
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        keyboardFrameInScreen = frame.cgRectValue
        setNeedsLayout()
    }

    override func layoutSubviews() {
        if webView.superview === self, let window {
            let viewport = convert(bounds, to: window)
            let screenFrame = keyboardFrameInScreen.intersection(window.screen.bounds)
            let keyboard = screenFrame.isNull || screenFrame.isEmpty ? CGRect.zero
                : window.convert(screenFrame, from: window.screen.coordinateSpace)
            let reserved = BrowserFindViewport.reservedHeight(viewport: viewport, keyboard: keyboard,
                window: window.bounds, finding: webView.findInteraction?.isFindNavigatorVisible == true)
            if bottom.constant != reserved { bottom.constant = reserved }
        } else if bottom.constant != 0 {
            bottom.constant = 0
        }
        super.layoutSubviews()
    }

    func setCoveredByResearch(_ covered: Bool) {
        guard webView.superview === self else { return }
        // Preserve the existing modal accessibility boundary and mounted view.
        accessibilityElementsHidden = covered
        accessibilityElements = covered ? [] : [webView]
        automationElements = covered ? [] : [webView]
        webView.accessibilityElementsHidden = covered
        setNeedsLayout()
    }

    func detachWebView() {
        // A replacement wrapper may already own the cached WKWebView.
        guard webView.superview === self else { return }
        accessibilityElementsHidden = false
        accessibilityElements = nil
        automationElements = nil
        webView.accessibilityElementsHidden = false
        onDetach()
        webView.removeFromSuperview()
    }
}
#endif
