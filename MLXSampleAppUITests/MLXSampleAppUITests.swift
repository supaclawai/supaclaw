import XCTest

final class MLXSampleAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSendPromptProducesOutput() throws {
        let app = XCUIApplication()
        app.launch()

        let promptField = app.textFields["prompt_field"]
        XCTAssertTrue(
            promptField.waitForExistence(timeout: 10),
            "Prompt field (accessibilityIdentifier: prompt_field) did not appear within 10 seconds."
        )

        promptField.tap()
        promptField.typeText("hey there")

        let sendButton = app.buttons["send_button"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 5),
            "Send button (accessibilityIdentifier: send_button) did not appear within 5 seconds."
        )
        sendButton.tap()

        let deadline = Date().addingTimeInterval(120)
        var lastText = ""
        while Date() < deadline {
            let outputText = app.descendants(matching: .any)["output_text"]
            guard outputText.exists else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                continue
            }

            let candidate = outputText.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return
            }

            if let value = outputText.value as? String {
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedValue.isEmpty {
                    return
                }
                lastText = trimmedValue
            } else {
                lastText = candidate
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTFail(
            "Output text stayed empty for 120 seconds after tapping send_button. Last observed label/value: '\(lastText)'."
        )
    }
}
