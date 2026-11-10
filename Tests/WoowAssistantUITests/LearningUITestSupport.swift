import XCTest
import CoreGraphics

enum LearningElementVisibility {
    case fullyVisible
    /// Read a static text's full AX label when part of its frame is visible.
    /// This never authorizes tapping a partly obscured control.
    case readableText
}

/// SwiftUI may report a List descendant as hittable while its frame is covered by
/// the custom bottom navigation or keyboard. Scroll it fully into the content
/// viewport before tapping; never fall back to a blind screen coordinate.
func revealLearningElement(_ element: XCUIElement, in app: XCUIApplication,
                           visibility: LearningElementVisibility = .fullyVisible,
                           file: StaticString = #filePath, line: UInt = #line) {
    // Scrolling does not replace the containing Form/List. Resolve it once per
    // invocation, but refresh geometry after each swipe (keyboard/layout may
    // change). Never enumerate the AX tree twice for a single gesture.
    var container: XCUIElement?
    let navigation = app.buttons["navigation.chat"]
    let keyboard = app.keyboards.firstMatch
    func viewport() -> (bounds: CGRect, scrollTarget: XCUIElement) {
        let appFrame = app.frame
        var contentFrame = appFrame
        if let container { contentFrame = container.frame }
        else {
            let candidates = app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            for candidate in candidates where candidate.isHittable {
                let frame = candidate.frame
                if !frame.intersection(appFrame).isEmpty {
                    container = candidate; contentFrame = frame; break
                }
            }
        }
        var bounds = contentFrame.intersection(appFrame)
        if navigation.exists, navigation.isHittable {
            let frame = navigation.frame
            if frame.minY > bounds.minY { bounds.size.height = min(bounds.maxY, frame.minY) - bounds.minY }
        }
        if keyboard.exists {
            let frame = keyboard.frame
            if !frame.isEmpty, frame.minY > bounds.minY { bounds.size.height = min(bounds.maxY, frame.minY) - bounds.minY }
        }
        return (bounds.insetBy(dx: 0, dy: 4), container ?? app)
    }
    for attempt in 0...8 {
        let (bounds, scrollTarget) = viewport()
        let exists = element.exists
        // A virtualized Form row has no snapshot until scrolling materializes
        // it. Querying elementType before exists fails before any scroll occurs.
        if exists && visibility == .readableText && element.elementType != .staticText {
            XCTFail("Partial visibility is permitted only for read-only static text.", file: file, line: line)
            return
        }
        let frame = exists ? element.frame : .zero
        if exists && learningFrameIsVisible(frame, in: bounds, visibility: visibility) {
            // Long static text can have its tap point outside the viewport even
            // when its lines are visible; reading its label needs no tap point.
            if visibility == .readableText || element.isHittable { return }
        }
        guard attempt < 8 else {
            XCTFail("Learning element must meet its visibility requirement above navigation/keyboard: \(element.identifier)",
                    file: file, line: line)
            return
        }
        if exists && frame.minY < bounds.minY { scrollTarget.swipeDown() }
        else { scrollTarget.swipeUp() }
    }
}

func learningFrameIsVisible(_ frame: CGRect, in viewport: CGRect, visibility: LearningElementVisibility) -> Bool {
    guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
          !viewport.isEmpty, !viewport.isNull, !viewport.isInfinite else { return false }
    switch visibility {
    case .fullyVisible: return viewport.contains(frame)
    case .readableText: return !viewport.intersection(frame).isEmpty
    }
}
