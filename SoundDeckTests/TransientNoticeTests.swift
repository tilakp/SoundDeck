import Testing
@testable import SoundDeck

@Test func noticeShowsAndExpires() {
    var notice = TransientNotice()
    #expect(notice.text == nil)
    let token = notice.show("File missing")
    #expect(notice.text == "File missing")
    notice.expire(token)
    #expect(notice.text == nil)
}

@Test func olderExpiryKeepsNewerMessage() {
    var notice = TransientNotice()
    let first = notice.show("First")
    let second = notice.show("Second")
    notice.expire(first)
    #expect(notice.text == "Second")
    notice.expire(second)
    #expect(notice.text == nil)
}

@Test func sameMessageAgainRestartsThePeriod() {
    var notice = TransientNotice()
    let first = notice.show("Same")
    _ = notice.show("Same")
    notice.expire(first)
    #expect(notice.text == "Same")
}

@Test func noticeDurationIsFourSeconds() {
    #expect(TransientNotice.duration == 4)
}
