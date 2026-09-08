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
