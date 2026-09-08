import Foundation
import Testing
@testable import Inbox

private let noon = Date(timeIntervalSince1970: 1_788_000_000)

@Test func theFrontMatterNamesTheTimeTheAppAndTheBundle() {
    let note = InboxNote.render(
        capturedAt: noon,
        appName: "Telegram",
        bundleID: "ru.keepcoder.Telegram",
        url: nil,
        text: "> Натали:\nтекст"
    )
    let lines = note.components(separatedBy: "\n")
    #expect(lines[0] == "---")
    #expect(lines[1].hasPrefix("captured: "))
    #expect(lines[2] == "app: \"Telegram\"")
    #expect(lines[3] == "bundle: ru.keepcoder.Telegram")
    #expect(lines[4] == "---")
    #expect(lines[5] == "")
}

@Test func theAddressIsWrittenOnlyWhenThereIsOne() {
    let withURL = InboxNote.render(
        capturedAt: noon,
        appName: "Safari",
        bundleID: "com.apple.Safari",
        url: "https://tracker.yandex.ru/PULSE-42",
        text: "задача"
    )
    #expect(withURL.contains("url: \"https://tracker.yandex.ru/PULSE-42\""))

    let withoutURL = InboxNote.render(
        capturedAt: noon, appName: "Telegram", bundleID: "ru.keepcoder.Telegram",
        url: nil, text: "задача"
    )
    #expect(!withoutURL.contains("url:"))
}

// The whole point of the file: whatever a model says about this text later has to stay checkable
// against what was actually copied. Nothing is cleaned, normalised or re-wrapped.
@Test func theBodyIsTheClipboardTextUnchanged() {
    let text = "> Натали:\n---\nэто не фронтматтер\n\n> Натали:\nвторое"
    let note = InboxNote.render(
        capturedAt: noon, appName: nil, bundleID: nil, url: nil, text: text
    )
    #expect(note.hasSuffix(text + "\n"))
}

@Test func aTextThatAlreadyEndsWithANewlineIsNotGivenAnother() {
    let note = InboxNote.render(
        capturedAt: noon, appName: nil, bundleID: nil, url: nil, text: "строка\n"
    )
    #expect(note.hasSuffix("строка\n"))
    #expect(!note.hasSuffix("строка\n\n"))
}

@Test func anApplicationNameWithASpaceStaysOneValue() {
    let note = InboxNote.render(
        capturedAt: noon, appName: "Яндекс Мессенджер", bundleID: "ru.yandex.messenger",
        url: nil, text: "текст"
    )
    #expect(note.contains("app: \"Яндекс Мессенджер\""))
}

// What the panel says out loud, so it is worth being a fact rather than an estimate: blank
// lines separate messages in every one of the four sources and are not lines of content.
@Test func theLineCountIgnoresBlankLines() {
    #expect(InboxNote.lineCount("> Натали:\nтекст\n\n> Натали:\nещё") == 4)
    #expect(InboxNote.lineCount("") == 0)
    #expect(InboxNote.lineCount("   \n\n") == 0)
}
