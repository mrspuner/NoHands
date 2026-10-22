import Testing
@testable import Telegram

@Test func linksLoseBrackets() {
    #expect(TelegramText.html(fromMarkdown: "см. [[brandsim]]") == "см. brandsim")
}

@Test func htmlIsEscaped() {
    #expect(TelegramText.html(fromMarkdown: "a < b & c") == "a &lt; b &amp; c")
}

@Test func boldAndHeadings() {
    #expect(TelegramText.html(fromMarkdown: "### Созвон\n**ок**") == "<b>Созвон</b>\n<b>ок</b>")
}

@Test func inlineCodeBecomesCode() {
    #expect(TelegramText.html(fromMarkdown: "запусти `ls -la`") == "запусти <code>ls -la</code>")
}

@Test func chunksRespectLimit() {
    let paragraphs = (0..<10).map { _ in String(repeating: "а", count: 1000) }
    let text = paragraphs.joined(separator: "\n\n")
    let parts = TelegramText.chunks(text, limit: 4000)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.count <= 4000 })
    #expect(parts.joined(separator: "\n\n") == text)
}

@Test func shortTextIsOneChunk() {
    #expect(TelegramText.chunks("привет", limit: 4000) == ["привет"])
}

@Test func oversizedParagraphIsSplitByLines() {
    let lines = (0..<10).map { _ in String(repeating: "б", count: 100) }
    let parts = TelegramText.chunks(lines.joined(separator: "\n"), limit: 350)
    #expect(parts.count == 4)
    #expect(parts.allSatisfy { $0.count <= 350 })
    #expect(parts.joined(separator: "\n") == lines.joined(separator: "\n"))
}

@Test func oversizedLineIsHardSplit() {
    let parts = TelegramText.chunks(String(repeating: "в", count: 10_000), limit: 4000)
    #expect(parts.allSatisfy { $0.count <= 4000 })
    #expect(parts.joined() == String(repeating: "в", count: 10_000))
}

@Test func hardSplitNeverCutsInsideAnEntity() {
    // Entities land on every possible offset relative to the limit.
    for pad in 0..<6 {
        let line = String(repeating: "x", count: pad) + String(repeating: "&amp;", count: 20)
        let parts = TelegramText.chunks(line, limit: 12)
        #expect(parts.joined() == line)
        for part in parts {
            #expect(part.count <= 12)
            // Every "&" in a part is followed by its ";" inside the same part.
            var open = false
            for ch in part {
                if ch == "&" { open = true }
                if ch == ";" { open = false }
            }
            #expect(!open, "entity cut in \(part)")
        }
    }
}

@Test func hardSplitNeverCutsInsideATag() {
    let line = String(repeating: "<b>y</b>", count: 20)
    let parts = TelegramText.chunks(line, limit: 10)
    #expect(parts.joined() == line)
    for part in parts {
        #expect(part.count <= 10)
        #expect(part.filter { $0 == "<" }.count == part.filter { $0 == ">" }.count)
    }
}

@Test func buttonsAreExtracted() {
    let md = """
    Текст ответа.

    <!-- кнопки
    Созвон 20.10 16:33
    Lint 2026-10-26
    -->
    """
    let result = TelegramText.extractButtons(md)
    #expect(result.body == "Текст ответа.")
    #expect(result.buttons == ["Созвон 20.10 16:33", "Lint 2026-10-26"])
}

@Test func noButtonsBlockGivesEmpty() {
    let result = TelegramText.extractButtons("Просто текст")
    #expect(result.body == "Просто текст")
    #expect(result.buttons.isEmpty)
}
