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
    // Navigation/keyboard transitions can replace the containing Form/List.
    // Cache its AX identity, not its position in a changing query result, and
    // validate it before reusing its geometry for the next gesture.
    var container: XCUIElement?
    let navigation = app.buttons["navigation.chat"]
    let keyboard = app.keyboards.firstMatch
    func viewport() -> (bounds: CGRect, scrollTarget: XCUIElement, scrollFrame: CGRect) {
        let appFrame = app.frame
        var contentFrame = appFrame
        func visibleFrame(of candidate: XCUIElement) -> CGRect? {
            guard candidate.exists, candidate.isHittable,
                  let snapshot = try? candidate.snapshot() else { return nil }
            let frame = snapshot.frame
            guard !frame.isNull, !frame.isInfinite, !frame.isEmpty,
                  !frame.intersection(appFrame).isEmpty else { return nil }
            return frame
        }
        if let cached = container, let frame = visibleFrame(of: cached) {
            contentFrame = frame
        } else {
            container = nil
            // 1b0f3d8: two CollectionViews became one during presentation. An
            // index-1 element then failed on frame despite the Form still being
            // present. Accessibility bindings survive changes to result order.
            let candidates = app.collectionViews.allElementsBoundByAccessibilityElement
                + app.scrollViews.allElementsBoundByAccessibilityElement
            for candidate in candidates {
                guard let frame = visibleFrame(of: candidate) else { continue }
                container = candidate; contentFrame = frame; break
            }
        }
        var bounds = contentFrame.intersection(appFrame)
        // A Form can cover the whole window while its top rows sit behind the
        // native navigation bar. iOS 17 reported y=6.7 for an obscured static
        // text, inside the former viewport, with an unhittable (-1,-1) point.
        // Keep the full visibility requirement and scroll below the actual bar.
        let topBars = app.navigationBars.allElementsBoundByAccessibilityElement.compactMap {
            visibleFrame(of: $0)
        }
        bounds = learningViewportBelowNavigationBars(bounds, bars: topBars)
        if navigation.exists, navigation.isHittable {
            let frame = navigation.frame
            if frame.minY > bounds.minY { bounds.size.height = min(bounds.maxY, frame.minY) - bounds.minY }
        }
        if keyboard.exists {
            let frame = keyboard.frame
            if !frame.isEmpty, frame.minY > bounds.minY { bounds.size.height = min(bounds.maxY, frame.minY) - bounds.minY }
        }
        return (bounds.insetBy(dx: 0, dy: 4), container ?? app, contentFrame)
    }
    var previousTargetWasPresent = false
    var hasSeenTarget = false
    var searchUp = true
    var maximumDistance: CGFloat = 120
    var lastKnownIdentifier = "unmaterialized element"
    var previousContent: LearningScrollContent?
    var reversedAtBoundary = false
    for attempt in 0...8 {
        let (bounds, scrollTarget, scrollFrame) = viewport()
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
        hasSeenTarget = hasSeenTarget || targetIsPresent
        // One snapshot supplies all visible labels, including metadata without
        // identifiers. Avoid a separate AX query for every row on each gesture.
        let content = targetIsPresent ? nil : learningScrollContent(in: scrollTarget, viewport: bounds)
        if !targetIsPresent && previousTargetWasPresent {
            searchUp.toggle()
            maximumDistance = max(24, maximumDistance / 2)
        } else if let content, let previousContent, content.isUnchanged(from: previousContent) {
            // A missing row may be above the starting viewport. At a real
            // boundary, reverse instead of spending every remaining gesture
            // pushing against the same end of the List. A pinned label alone
            // is not a boundary: the entire visible text set must be unchanged.
            guard !reversedAtBoundary else {
                XCTFail("Learning search made no visible progress in either direction while revealing \(lastKnownIdentifier).",
                        file: file, line: line)
                return
            }
            searchUp.toggle()
            reversedAtBoundary = true
        }
        previousContent = content
        guard let drag = LearningScrollDrag.make(
            listFrame: scrollFrame, viewport: bounds,
            targetFrame: targetIsPresent ? frame : nil,
            searchUp: searchUp, maximumDistance: maximumDistance, visibility: visibility,
            searchByPage: !hasSeenTarget
        ) else {
            XCTFail("No safe bounded scroll can reveal \(lastKnownIdentifier); visibility remains required.",
                    file: file, line: line)
            return
        }
        // Eight 120pt drags stopped inside PDF metadata on SE/current before the
        // status row. Search half a viewport while its position is unknown, so
        // successive views overlap; retain fine corrections once it appears.
        // Hold before release to prevent an inertial overshoot.
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

private func learningScrollContent(in element: XCUIElement, viewport: CGRect) -> LearningScrollContent? {
    guard let snapshot = try? element.snapshot() else { return nil }
    var rows: [LearningScrollContent.Row] = []
    func visit(_ node: XCUIElementSnapshot) {
        if node.elementType == .staticText, !node.frame.isEmpty, viewport.intersects(node.frame),
           !node.identifier.isEmpty || !node.label.isEmpty {
            rows.append(.init(identifier: node.identifier, label: node.label, frame: node.frame))
        }
        for child in node.children { visit(child) }
    }
    visit(snapshot)
    return rows.isEmpty ? nil : LearningScrollContent(viewport: viewport, rows: rows)
}

/// Compare actual visible content, not reusable cell indices. Labels stay in
/// memory; they are never written to diagnostics by this helper.
struct LearningScrollContent {
    struct Row {
        let identifier: String
        let label: String
        let frame: CGRect
    }
    let viewport: CGRect
    let rows: [Row]

    func isUnchanged(from previous: Self) -> Bool {
        guard viewport == previous.viewport, !rows.isEmpty, rows.count == previous.rows.count else { return false }
        return zip(rows, previous.rows).allSatisfy { current, old in
            current.identifier == old.identifier && current.label == old.label
                && abs(current.frame.minX - old.frame.minX) < 1
                && abs(current.frame.minY - old.frame.minY) < 1
                && abs(current.frame.width - old.frame.width) < 1
                && abs(current.frame.height - old.frame.height) < 1
        }
    }
}

/// Remove only overlapping, visible native navigation bars. Frames come from
/// the current AX query on each gesture, not a cached device-specific inset.
func learningViewportBelowNavigationBars(_ viewport: CGRect, bars: [CGRect]) -> CGRect {
    func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && !frame.isEmpty
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
    }
    guard valid(viewport) else { return .zero }
    let top = bars.filter { valid($0) && viewport.intersects($0) }
        .reduce(viewport.minY) { max($0, $1.maxY) }
    return CGRect(x: viewport.minX, y: min(top, viewport.maxY),
                  width: viewport.width, height: max(0, viewport.maxY - top))
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
                     visibility: LearningElementVisibility = .fullyVisible,
                     searchByPage: Bool = false) -> Self? {
        guard valid(listFrame), valid(viewport), listFrame.contains(viewport),
              viewport.width >= 48, maximumDistance.isFinite, maximumDistance > 0 else { return nil }
        // Page search is opt-in and only for an unmaterialized target. Other
        // callers (including Memory import/rollback) retain their 120pt limit.
        let limit = searchByPage && targetFrame == nil
            ? viewport.height * 0.5 : min(maximumDistance, viewport.height * 0.3)
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
