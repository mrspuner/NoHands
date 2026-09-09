import Foundation
import Testing
@testable import Inbox

@Test func theSlugComesFromTheBundleIdentifier() {
    let source = InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil)
    #expect(source.slug == "telegram")
}

@Test func anApplicationWithoutAnIdentifierStillHasASlug() {
    #expect(InboxSource(appName: "Что-то", bundleID: nil, url: nil).slug == "app")
}

// Asking an application for its front document raises the automation consent dialog, so the
// list of who is worth asking is a closed one — and everything outside it is not a refusal,
// it is simply an application with no address to give.
@MainActor
@Test func onlyBrowsersAreAskedForAnAddress() {
    #expect(FrontmostSource.browsers["com.apple.Safari"] != nil)
    #expect(FrontmostSource.browsers["ru.keepcoder.Telegram"] == nil)
    #expect(FrontmostSource.browsers["ru.yandex.desktop.telemost"] == nil)
}

private func source(url: String?) -> InboxSource {
    InboxSource(appName: "Safari", bundleID: "com.apple.Safari", url: url)
}

// Tracker and Messenger are both Safari, and before this both folders were named `-safari`.
// The address is the only thing that tells them apart.
@Test func aBrowserCaptureIsNamedAfterTheHost() {
    #expect(source(url: "https://tracker.yandex.ru/CRM-123").slug == "tracker")
    #expect(source(url: "https://360.yandex.ru/messenger").slug == "360")
}

@Test func wwwIsNotAName() {
    #expect(source(url: "https://www.example.com/page").slug == "example")
}

// No address means no browser: the bundle identifier is what names the folder, as before.
@Test func withoutAnAddressTheBundleIdentifierNamesTheFolder() {
    #expect(InboxSource(appName: "Telegram", bundleID: "ru.keepcoder.Telegram", url: nil).slug == "telegram")
}

// A string that is not an address must not produce a folder named after its wreckage.
@Test func anUnparsableAddressFallsBackToTheBundleIdentifier() {
    #expect(source(url: "не адрес").slug == "safari")
}
