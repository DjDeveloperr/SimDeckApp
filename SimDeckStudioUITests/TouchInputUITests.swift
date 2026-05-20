import Foundation
import XCTest

final class TouchInputUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPinchEmitsTwoPointMultiTouch() {
        let app = XCUIApplication()
        app.launchArguments = ["--simdeck-touch-input-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Touch Input Test"].waitForExistence(timeout: 5))

        app.pinch(withScale: 2.0, velocity: 1.0)

        let multiTouchEvent = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "multi")
        ).firstMatch
        XCTAssertTrue(multiTouchEvent.waitForExistence(timeout: 3))

        let singleTouchEvent = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "single")
        ).firstMatch
        XCTAssertFalse(singleTouchEvent.exists)
    }

    func testControllerPinchAgainstConnectedSimulator() throws {
        let launchURL = try e2eLaunchURL()
        let app = launchControllerApp(launchURL: launchURL)

        let streamSurface = app.otherElements["touch-input-surface"].firstMatch
        XCTAssertTrue(streamSurface.waitForExistence(timeout: 20), "Stream touch surface did not appear.")

        streamSurface.pinch(withScale: 2.0, velocity: 1.0)
        try waitForTargetTouchLog(containing: "multi", from: launchURL)
    }

    func testStreamScreenIgnoresInteriorHorizontalSwipe() throws {
        let app = try launchControllerApp()

        let streamSurface = app.otherElements["touch-input-surface"].firstMatch
        XCTAssertTrue(streamSurface.waitForExistence(timeout: 20), "Stream touch surface did not appear.")

        for startX in [0.12, 0.35] {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            start.press(forDuration: 0.08, thenDragTo: end)

            XCTAssertTrue(
                streamSurface.waitForExistence(timeout: 2),
                "Stream screen popped after an interior horizontal swipe from \(startX)."
            )
        }
    }

    func testCompactStreamBackButtonAndScreenEdgeSwipeReturnToSimulatorList() throws {
        var app = try launchControllerApp()

        var streamSurface = app.otherElements["touch-input-surface"].firstMatch
        XCTAssertTrue(streamSurface.waitForExistence(timeout: 20), "Stream touch surface did not appear.")

        let backButton = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Back", "Simulators"])
        ).firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 3), "Compact stream back button was missing.")
        backButton.tap()
        XCTAssertFalse(streamSurface.waitForExistence(timeout: 1), "Stream screen stayed open after tapping back.")

        app.terminate()
        app = try launchControllerApp()
        streamSurface = app.otherElements["touch-input-surface"].firstMatch
        XCTAssertTrue(streamSurface.waitForExistence(timeout: 20), "Stream touch surface did not appear.")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0, thenDragTo: end)

        XCTAssertFalse(streamSurface.waitForExistence(timeout: 1), "Stream screen stayed open after a phone-edge back swipe.")
    }

    private func launchControllerApp() throws -> XCUIApplication {
        let launchURL = try e2eLaunchURL()
        return launchControllerApp(launchURL: launchURL)
    }

    private func launchControllerApp(launchURL: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--simdeck-e2e-controller", "--simdeck-open-url=\(launchURL.absoluteString)"]
        app.launch()
        return app
    }

    private func e2eLaunchURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let rawLaunchURL = environment["SIMDECK_E2E_URL"] ?? environment["TEST_RUNNER_SIMDECK_E2E_URL"] else {
            throw XCTSkip("Set SIMDECK_E2E_URL to run the controller-to-target simulator pinch test.")
        }
        guard let launchURL = URL(string: rawLaunchURL) else {
            throw XCTSkip("SIMDECK_E2E_URL is not a valid URL.")
        }
        return launchURL
    }

    private func waitForTargetTouchLog(
        containing text: String,
        from launchURL: URL,
        timeout: TimeInterval = 8
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabels: [String] = []
        repeat {
            lastLabels = (try? targetTouchLabels(from: launchURL)) ?? lastLabels
            if lastLabels.contains(where: { $0.contains(text) }) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTFail("Target simulator did not log \(text) touch input. Last labels: \(lastLabels.joined(separator: " | "))")
    }

    private func targetTouchLabels(from launchURL: URL) throws -> [String] {
        let parameters = try queryParameters(from: launchURL)
        guard let host = parameters["host"],
              let portValue = parameters["port"],
              let port = Int(portValue),
              let device = parameters["device"] ?? parameters["udid"] else {
            throw XCTSkip("SIMDECK_E2E_URL must include host, port, and device.")
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/api/simulators/\(device)/accessibility-tree"
        components.queryItems = [
            URLQueryItem(name: "source", value: "native-ax"),
            URLQueryItem(name: "maxDepth", value: "6")
        ]
        guard let url = components.url else {
            throw XCTSkip("Could not build SimDeck accessibility URL.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
            } else {
                result = .success(data ?? Data())
            }
        }
        .resume()

        guard semaphore.wait(timeout: .now() + 2) == .success,
              let result else {
            throw XCTSkip("Timed out reading target simulator accessibility tree.")
        }

        let data = try result.get()
        let object = try JSONSerialization.jsonObject(with: data)
        return accessibilityLabels(in: object).filter {
            $0 == "Touch Input Test" || $0.hasPrefix("single") || $0.hasPrefix("multi")
        }
    }

    private func queryParameters(from url: URL) throws -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw XCTSkip("SIMDECK_E2E_URL is missing query parameters.")
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private func accessibilityLabels(in object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            let ownLabel = (dictionary["AXLabel"] as? String).map { [$0] } ?? []
            return ownLabel + dictionary.values.flatMap(accessibilityLabels)
        }
        if let array = object as? [Any] {
            return array.flatMap(accessibilityLabels)
        }
        return []
    }
}
