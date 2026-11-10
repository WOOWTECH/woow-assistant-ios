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
    var previousTargetWasPresent = false
    var searchUp = true
    var maximumDistance: CGFloat = 120
    var lastKnownIdentifier = "unmaterialized element"
    var searchAnchor: XCUIElement?
    var searchAnchorFrame: CGRect?
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
        if exists { lastKnownIdentifier = element.identifier }
        if exists && learningFrameIsVisible(frame, in: bounds, visibility: visibility) {
            // Long static text can have its tap point outside the viewport even
            // when its lines are visible; reading its label needs no tap point.
            if visibility == .readableText || element.isHittable { return }
        }
        guard attempt < 8 else {
            XCTFail("Learning element must meet its visibility requirement above navigation/keyboard: \(lastKnownIdentifier)",
                    file: file, line: line)
            return
        }
        let targetIsPresent = exists && !frame.isEmpty
        if !targetIsPresent && previousTargetWasPresent {
            searchUp.toggle()
            maximumDistance = max(24, maximumDistance / 2)
        } else if !targetIsPresent, let anchor = searchAnchor,
                  let previousFrame = searchAnchorFrame, anchor.exists,
                  abs(anchor.frame.minY - previousFrame.minY) < 1 {
            // A missing row may be above the starting viewport. At a real
            // boundary, reverse instead of spending every remaining gesture
            // pushing against the same end of the List.
            searchUp.toggle()
        }
        searchAnchor = nil; searchAnchorFrame = nil
        if !targetIsPresent {
            // Only the unknown-target search needs an anchor. Capture a stable
            // identified visible label, never a virtualized cell's index.
            for label in scrollTarget.staticTexts.allElementsBoundByIndex where label.exists {
                let identifier = label.identifier
                let labelFrame = label.frame
                if !identifier.isEmpty, bounds.intersects(labelFrame) {
                    searchAnchor = scrollTarget.staticTexts[identifier].firstMatch
                    searchAnchorFrame = labelFrame
                    break
                }
            }
        }
        let scrollFrame = scrollTarget.frame
        guard let drag = LearningScrollDrag.make(
            listFrame: scrollFrame, viewport: bounds,
            targetFrame: targetIsPresent ? frame : nil,
            searchUp: searchUp, maximumDistance: maximumDistance, visibility: visibility
        ) else {
            XCTFail("No safe bounded scroll can reveal \(lastKnownIdentifier); visibility remains required.",
                    file: file, line: line)
            return
        }
        // Full-list swipes skipped virtualized skill controls on SE and then
        // kept scrolling away from them. Reuse the bounded import/rollback
        // gesture; hold before release to prevent an inertial overshoot.
        let origin = scrollTarget.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: drag.start.x - scrollFrame.minX,
                                               dy: drag.start.y - scrollFrame.minY))
        let end = origin.withOffset(CGVector(dx: drag.end.x - scrollFrame.minX,
                                             dy: drag.end.y - scrollFrame.minY))
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        previousTargetWasPresent = targetIsPresent
        searchUp = drag.end.y < drag.start.y
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

/// Shared pure geometry for scrolling inside a visible List/Form viewport.
/// Coordinates scroll the container; they never replace tapping a control.
struct LearningScrollDrag {
    let start: CGPoint
    let end: CGPoint

    static func make(listFrame: CGRect, viewport: CGRect, targetFrame: CGRect?,
                     searchUp: Bool, maximumDistance: CGFloat,
                     visibility: LearningElementVisibility = .fullyVisible) -> Self? {
        guard valid(listFrame), valid(viewport), listFrame.contains(viewport),
              viewport.width >= 48, maximumDistance.isFinite, maximumDistance > 0 else { return nil }
        let limit = min(maximumDistance, viewport.height * 0.3)
        guard limit >= 16 else { return nil }
        let up: Bool
        let distance: CGFloat
        if let targetFrame {
            guard valid(targetFrame),
                  visibility == .readableText || targetFrame.height <= viewport.height,
                  targetFrame.minX >= viewport.minX, targetFrame.maxX <= viewport.maxX else { return nil }
            if targetFrame.maxY > viewport.maxY {
                up = true
                distance = min(limit, max(24, targetFrame.maxY - viewport.maxY + 12))
            } else if targetFrame.minY < viewport.minY {
                up = false
                distance = min(limit, max(24, viewport.minY - targetFrame.minY + 12))
            } else {
                // Already in the viewport: scrolling cannot establish why a
                // control is not hittable, so never substitute a coordinate tap.
                return nil
            }
        } else {
            up = searchUp
            distance = limit
        }
        let displacement = up ? distance : -distance
        let start = CGPoint(x: viewport.midX, y: viewport.midY + displacement / 2)
        let end = CGPoint(x: viewport.midX, y: viewport.midY - displacement / 2)
        guard viewport.contains(start), viewport.contains(end) else { return nil }
        return Self(start: start, end: end)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            && [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy { $0.isFinite }
    }
}
