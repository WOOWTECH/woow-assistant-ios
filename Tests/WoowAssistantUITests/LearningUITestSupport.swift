import XCTest

/// SwiftUI may report a List descendant as hittable while its frame is covered by
/// the custom bottom navigation or keyboard. Scroll it fully into the content
/// viewport before tapping; never fall back to a blind screen coordinate.
func revealLearningElement(_ element: XCUIElement, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
    func scrollContainer() -> XCUIElement? {
        (app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex)
            .first { $0.exists && $0.isHittable && !$0.frame.intersection(app.frame).isEmpty }
    }
    func viewport() -> CGRect {
        var bounds = scrollContainer()?.frame.intersection(app.frame) ?? app.frame
        let navigation = app.buttons["navigation.chat"]
        if navigation.exists, navigation.isHittable, navigation.frame.minY > bounds.minY {
            bounds.size.height = min(bounds.maxY, navigation.frame.minY) - bounds.minY
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, !keyboard.frame.isEmpty, keyboard.frame.minY > bounds.minY {
            bounds.size.height = min(bounds.maxY, keyboard.frame.minY) - bounds.minY
        }
        return bounds.insetBy(dx: 0, dy: 4)
    }
    for _ in 0..<8 {
        let bounds = viewport()
        if element.exists, element.isHittable, !element.frame.isEmpty,
           bounds.contains(element.frame) { return }
        let scrollTarget = scrollContainer() ?? app
        if element.exists, element.frame.minY < bounds.minY { scrollTarget.swipeDown() }
        else { scrollTarget.swipeUp() }
    }
    XCTAssertTrue(element.exists && element.isHittable && viewport().contains(element.frame),
                  "Learning control must be visible above navigation/keyboard before tapping: \(element.identifier)",
                  file: file, line: line)
}
