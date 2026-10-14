import Foundation
import XCTest
@testable import BluehopCore

/// 대화 고르기: 터미널 입출력 없이 상태 기계·키 해석·번호 고르기만.
final class ChatPickerTests: XCTestCase {
    let items = [
        ChatPicker.Item(guid: "any;-;+821011112222", handle: "+821011112222", detail: "iMessage", mappedTo: "family"),
        ChatPicker.Item(guid: "any;-;+821033334444", handle: "+821033334444", detail: "iMessage"),
        ChatPicker.Item(guid: "any;-;+15555550123", handle: "+15555550123", detail: "SMS"),
    ]

    func testStartsOnFirstSelectableAndMovesWithinBounds() {
        var p = ChatPicker(items: items, pageSize: 2)
        XCTAssertEqual(p.current?.handle, "+821033334444")   // 첫 줄은 이미 매핑돼 건너뜀
        XCTAssertEqual(p.handle(.down), .pending)
        XCTAssertEqual(p.current?.handle, "+15555550123")
        XCTAssertEqual(p.scroll, 1)
        _ = p.handle(.down)
        XCTAssertEqual(p.cursor, 2)                           // 끝에서 멈춤
        _ = p.handle(.home)
        XCTAssertEqual(p.cursor, 0)
        XCTAssertEqual(p.scroll, 0)
        _ = p.handle(.up)
        XCTAssertEqual(p.cursor, 0)
        _ = p.handle(.end)
        XCTAssertEqual(p.cursor, 2)
        _ = p.handle(.pageUp)
        XCTAssertEqual(p.cursor, 0)
    }

    func testMappedChatCannotBePicked() {
        var p = ChatPicker(items: items)
        _ = p.handle(.home)
        XCTAssertEqual(p.handle(.enter), .pending)
        XCTAssertTrue(p.render(title: "t").last?.contains("family") == true)
        _ = p.handle(.down)
        XCTAssertEqual(p.handle(.enter), .picked(items[1]))
    }

    func testTypingFiltersIgnoringPunctuation() {
        var p = ChatPicker(items: items)
        for c in "3333-4444" { _ = p.handle(.char(c)) }
        XCTAssertEqual(p.visible.map(\.handle), ["+821033334444"])
        XCTAssertEqual(p.handle(.enter), .picked(items[1]))
        var q = ChatPicker(items: items)
        for c in "SMS" { _ = q.handle(.char(c)) }
        XCTAssertEqual(q.visible.count, 1)
        _ = q.handle(.backspace)
        XCTAssertEqual(q.filter, "SM")
        for c in "zzz" { _ = q.handle(.char(c)) }
        XCTAssertTrue(q.visible.isEmpty)
        XCTAssertEqual(q.handle(.enter), .pending)
        XCTAssertTrue(q.render(title: "t").contains("  (맞는 대화 없음)"))
    }

    func testEscapeAndInterruptCancel() {
        var p = ChatPicker(items: items)
        XCTAssertEqual(p.handle(.escape), .cancelled)
        XCTAssertEqual(p.handle(.interrupt), .cancelled)
    }

    func testRenderMarksCursorAndPaging() {
        let many = (0..<30).map { ChatPicker.Item(guid: "any;-;h\($0)", handle: "h\($0)") }
        var p = ChatPicker(items: many, pageSize: 5)
        _ = p.handle(.pageDown)
        let lines = p.render(title: "제목")
        XCTAssertEqual(lines[0], "제목")
        XCTAssertEqual(lines.filter { $0.hasPrefix("› ") }, ["› h5"])
        XCTAssertEqual(lines.count, 2 + 5 + 1)
        XCTAssertEqual(lines.last, "  30개 중 2–6")
    }

    func testKeyDecoder() {
        let esc: UInt8 = 0x1B
        let (keys, rest) = KeyDecoder.decode([esc, 0x5B, 0x41, esc, 0x5B, 0x42, esc, 0x4F, 0x48, esc, 0x5B, 0x36, 0x7E, 0x0D, 0x7F, 0x03, 0x61]
                                             + Array("한".utf8))
        XCTAssertEqual(keys, [.up, .down, .home, .pageDown, .enter, .backspace, .interrupt, .char("a"), .char("한")])
        XCTAssertEqual(rest, [])
        // 덜 들어온 순서는 남겨 둔다
        XCTAssertEqual(KeyDecoder.decode([esc, 0x5B]).rest, [esc, 0x5B])
        XCTAssertEqual(KeyDecoder.decode([0xED, 0x95]).rest, [0xED, 0x95])
        // ESC 하나만
        XCTAssertEqual(KeyDecoder.decode([esc]).keys, [.escape])
        XCTAssertEqual(KeyDecoder.decode([esc, 0x5B, 0x35, 0x7E, esc, 0x5B, 0x46]).keys, [.pageUp, .end])
    }

    func testNumberedFallback() {
        XCTAssertEqual(NumberedChoice.render(items)[0], "1   +821011112222  iMessage  [매핑 family, 고를 수 없음]")
        XCTAssertEqual(NumberedChoice.choose("2", items: items), .picked(items[1]))
        XCTAssertEqual(NumberedChoice.choose(" q ", items: items), .cancelled)
        XCTAssertEqual(NumberedChoice.choose(nil, items: items), .cancelled)
        if case .invalid = NumberedChoice.choose("1", items: items) {} else { XCTFail() }
        if case .invalid = NumberedChoice.choose("9", items: items) {} else { XCTFail() }
        if case .invalid = NumberedChoice.choose("x", items: items) {} else { XCTFail() }
    }

    func testChatListingMarksMappedAndFilters() {
        let list = [ChatDB.ChatSummary(guid: "any;-;+821011112222", handle: "+821011112222", lastRowID: 9, service: "iMessage", lastMessageAt: 1_800_000_000),
                    ChatDB.ChatSummary(guid: "any;-;+821033334444", handle: "+821033334444", lastRowID: 3)]
        let cfg = BluehopConfig(mappings: [mapping("family")])
        let items = ChatListing.items(list, cfg: cfg)
        XCTAssertEqual(items.map(\.mappedTo), ["family", nil])
        XCTAssertTrue(items[0].detail.hasPrefix("iMessage · 마지막 "))
        XCTAssertEqual(ChatListing.filter(list, search: "3333 4444").map(\.guid), ["any;-;+821033334444"])
        XCTAssertEqual(ChatListing.filter(list, search: nil).count, 2)
        let json = ChatListing.json(list, cfg: cfg)
        let chats = json["chats"] as? [[String: Any?]]
        XCTAssertEqual(chats?.count, 2)
        XCTAssertEqual(chats?[0]["mappedTo"] as? String, "family")
        XCTAssertEqual(chats?[0]["lastMessageAt"] as? String, "2027-01-15T08:00:00Z")
    }

    func testChatListFromFixture() throws {
        let fx = try FixtureChatDB()
        try fx.insert(chat: 2, text: "x")
        let list = try fx.reader().listOneToOneChats(limit: 10)
        XCTAssertEqual(list.map(\.guid), ["any;-;+821033334444", "any;-;+821011112222"])   // 최근 순, 단체방 제외
        XCTAssertNil(list[0].service)   // fixture 에는 service_name 이 없다
        XCTAssertEqual(ChatDB.unixTime(appleDate: 0), nil)
        XCTAssertEqual(ChatDB.unixTime(appleDate: 1_000_000_000_000_000_000), 1_000_000_000 + 978_307_200)
        XCTAssertEqual(ChatDB.unixTime(appleDate: 600_000_000), 600_000_000 + 978_307_200)
    }
}
