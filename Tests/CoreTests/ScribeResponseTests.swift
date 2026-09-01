import Foundation
import Testing
@testable import Core

@Test func parsesTextAndLanguage() throws {
    let json = """
    {
      "language_code": "rus",
      "language_probability": 0.98,
      "text": "Начнём с деплоя.",
      "words": [
        {"text": "Начнём", "start": 0.1, "end": 0.6, "type": "word"}
      ]
    }
    """
    let response = try ScribeResponse.decode(Data(json.utf8))
    #expect(response.text == "Начнём с деплоя.")
    #expect(response.languageCode == "rus")
}

@Test func missingTextIsADecodingFailure() {
    let json = """
    {"language_code": "rus"}
    """
    #expect(throws: (any Error).self) {
        try ScribeResponse.decode(Data(json.utf8))
    }
}
