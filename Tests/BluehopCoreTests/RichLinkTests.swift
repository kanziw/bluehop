import Foundation
import XCTest
@testable import BluehopCore

// MARK: - 링크 말풍선 fixture (실측 모양, 본문·주소는 지어낸 것)

/// `payload_data` 와 같은 모양(NSKeyedArchiver, `root → richLinkMetadata`)을 만드는 대역 클래스.
/// 실측(2026-10-15, macOS 26.0.1): 루트 클래스 `RichLink`(`richLinkMetadata`, `richLinkIsPlaceholder`),
/// 메타데이터 클래스 `LPLinkMetadata`(`title`·`siteName`·`summary`·`URL`·`originalURL`, 주소는 NSURL).
@objc(BluehopTestStubRichLink) final class StubRichLink: NSObject, NSCoding {
    let meta: StubLinkMetadata?
    init(meta: StubLinkMetadata?) { self.meta = meta }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(meta, forKey: "richLinkMetadata")
        coder.encode(meta == nil, forKey: "richLinkIsPlaceholder")
    }
}

@objc(BluehopTestStubLinkMetadata) final class StubLinkMetadata: NSObject, NSCoding {
    var title: String?, siteName: String?, summary: String?, url: URL?, originalURL: URL?
    init(title: String?, siteName: String?, summary: String?, url: URL?, originalURL: URL?) {
        self.title = title; self.siteName = siteName; self.summary = summary; self.url = url; self.originalURL = originalURL
    }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(title, forKey: "title")
        coder.encode(siteName, forKey: "siteName")
        coder.encode(summary, forKey: "summary")
        coder.encode(url.map { $0 as NSURL }, forKey: "URL")
        coder.encode(originalURL.map { $0 as NSURL }, forKey: "originalURL")
        coder.encode("article", forKey: "itemType")
    }
}

enum RichLinkFixture {
    static func payload(title: String?, siteName: String? = nil, summary: String? = nil,
                        url: String?, originalURL: String? = nil) -> Data {
        let meta = StubLinkMetadata(title: title, siteName: siteName, summary: summary,
                                    url: url.flatMap(URL.init(string:)), originalURL: (originalURL ?? url).flatMap(URL.init(string:)))
        return archive(StubRichLink(meta: meta))
    }

    /// 내가 iPhone 에서 보낸 링크 행처럼 메타데이터가 없는 자리표시 payload.
    static func placeholderPayload() -> Data { archive(StubRichLink(meta: nil)) }

    private static func archive(_ root: StubRichLink) -> Data {
        let a = NSKeyedArchiver(requiringSecureCoding: false)
        a.setClassName("RichLink", for: StubRichLink.self)
        a.setClassName("LPLinkMetadata", for: StubLinkMetadata.self)
        a.encode(root, forKey: NSKeyedArchiveRootObjectKey)
        a.finishEncoding()
        return a.encodedData
    }
}

extension FixtureChatDB {
    /// 실측 링크 말풍선 행: `balloon_bundle_id = URLBalloonProvider`, 본문 = 주소, `payload_data` = 링크 정보,
    /// 미리보기 그림은 `<UUID>.pluginPayloadAttachment`(mime 없음) 첨부. `downloaded=false` 면 파일이 아직 없다.
    @discardableResult
    func insertURLBalloon(text: String?, blobText: String? = nil, payload: Data?, previewFiles: Int = 3, downloaded: Bool = true,
                          fromMe: Bool = false, threadOriginator: String? = nil, threadPart: String? = nil,
                          bundleID: String = RichLink.urlBalloonBundleID) throws -> (rowid: Int64, guid: String) {
        let files: [(name: String, path: String?, mime: String?)] = (0..<previewFiles).map { _ in
            let name = UUID().uuidString + ".pluginPayloadAttachment"
            return (name, downloaded ? makeAttachmentFile(name, contents: "PNG-fake") : nil, nil)
        }
        let r = try insert(text: text, blobText: blobText, fromMe: fromMe, threadOriginator: threadOriginator,
                           threadPart: threadPart, attachments: files)
        try db.run("UPDATE message SET balloon_bundle_id = ?, payload_data = ?, cache_has_attachments = ? WHERE ROWID = ?",
                   [.text(bundleID), payload.map { .blob($0) } ?? .null, .int(previewFiles > 0 ? 1 : 0), .int(r.rowid)])
        try db.run("UPDATE attachment SET uti = 'dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy' WHERE transfer_name LIKE '%.pluginPayloadAttachment'")
        return r
    }
}

// MARK: - 단위: payload 읽기·텔레그램 글 모양

final class RichLinkParsingTests: XCTestCase {
    func testParsesObservedPayloadShape() throws {
        let data = RichLinkFixture.payload(title: "가짜 글 제목", siteName: "예시 블로그", summary: "요약",
                                           url: "https://blog.example.com/a/95")
        let m = try XCTUnwrap(RichLink.parse(payload: data))
        XCTAssertEqual(m.title, "가짜 글 제목")
        XCTAssertEqual(m.siteName, "예시 블로그")
        XCTAssertEqual(m.summary, "요약")
        XCTAssertEqual(m.url, "https://blog.example.com/a/95")
        XCTAssertEqual(m.originalURL, "https://blog.example.com/a/95")
    }

    func testPlaceholderAndGarbagePayloadGiveNil() {
        XCTAssertNil(RichLink.parse(payload: RichLinkFixture.placeholderPayload()))
        XCTAssertNil(RichLink.parse(payload: Data("not a plist".utf8)))
        XCTAssertNil(RichLink.parse(payload: Data()))
    }

    func testTelegramTextIsTitleThenOriginalURLWithPreviewOnThatURL() {
        let meta = RichLink.Metadata(title: "가짜\n제목", url: "https://news.example.com/view/1")
        let r = RichLink.telegramText(body: "https://news.example.com/view/1?section=x%2Fy", metadata: meta)
        XCTAssertEqual(r.text, "🔗 가짜 제목\nhttps://news.example.com/view/1?section=x%2Fy")
        XCTAssertEqual(r.previewURL, "https://news.example.com/view/1?section=x%2Fy")
    }

    func testTelegramTextWithoutTitleOrBody() {
        XCTAssertEqual(RichLink.telegramText(body: "https://a.example.com/x", metadata: nil).text, "https://a.example.com/x")
        let r = RichLink.telegramText(body: "", metadata: RichLink.Metadata(title: "제목", url: "https://a.example.com/c", originalURL: "https://a.example.com/o"))
        XCTAssertEqual(r.text, "🔗 제목\nhttps://a.example.com/o")
        XCTAssertEqual(r.previewURL, "https://a.example.com/o")
        // 제목이 주소와 같으면 두 번 쓰지 않는다.
        XCTAssertEqual(RichLink.telegramText(body: "https://a.example.com/x", metadata: RichLink.Metadata(title: "https://a.example.com/x")).text,
                       "https://a.example.com/x")
    }

    func testPluginPayloadName() {
        XCTAssertTrue(RichLink.isPluginPayload(transferName: "3C843323-35EB-49F2-AB3F-3EE63404306C.pluginPayloadAttachment"))
        XCTAssertFalse(RichLink.isPluginPayload(transferName: "IMG_0001.HEIC"))
    }
}

final class TelegramTextLinkTests: XCTestCase {
    func testHiddenLinkIsSpelledOut() {
        let text = "자세한 건 여기 보세요"
        let e = TGEntity(type: "text_link", offset: 6, length: 2, url: "https://docs.example.com/p")
        XCTAssertEqual(TelegramText.expandingTextLinks(text, entities: [e]), "자세한 건 여기 (https://docs.example.com/p) 보세요")
    }

    func testOffsetsAreUTF16AndSeveralLinksKeepTheirPlaces() {
        // 🔥 는 UTF-16 두 단위다.
        let text = "🔥 첫째 둘째"
        let es = [TGEntity(type: "text_link", offset: 3, length: 2, url: "https://a.example.com"),
                  TGEntity(type: "bold", offset: 0, length: 2),
                  TGEntity(type: "text_link", offset: 6, length: 2, url: "https://b.example.com")]
        XCTAssertEqual(TelegramText.expandingTextLinks(text, entities: es), "🔥 첫째 (https://a.example.com) 둘째 (https://b.example.com)")
    }

    func testVisibleOrBrokenLinksAreLeftAlone() {
        let text = "https://a.example.com"
        XCTAssertEqual(TelegramText.expandingTextLinks(text, entities: [TGEntity(type: "text_link", offset: 0, length: 21, url: "https://a.example.com")]), text)
        XCTAssertEqual(TelegramText.expandingTextLinks("짧음", entities: [TGEntity(type: "text_link", offset: 1, length: 9, url: "https://a.example.com")]), "짧음")
        XCTAssertEqual(TelegramText.expandingTextLinks("글", entities: nil), "글")
    }
}

// MARK: - 중계: 실측 사례(상대가 한 질문에 링크 말풍선을 섞어 여러 말풍선으로 답함)

final class RichLinkRelayTests: XCTestCase {
    /// 텔레그램 글(42)을 iMessage 로 보내고 메아리까지 맞춘 뒤, 그 메아리 행 guid 를 돌려준다.
    private func askFromTelegram(_ h: Harness, _ text: String = "링크 좀 찾아줘", id: Int64 = 42, update: Int64 = 1) async throws -> String {
        MockTelegram.enqueue([Harness.textUpdate(update, messageID: id, text: text)])
        await h.relay.tick()
        return try XCTUnwrap(h.fixture.db.query("SELECT guid FROM message WHERE is_from_me = 1 ORDER BY ROWID DESC LIMIT 1") { $0.text(0) }.first ?? nil)
    }

    private func replyIDs(_ calls: some Collection<RecordedRequest>) -> [Int64?] {
        calls.map { ($0.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64 }
    }

    private func preview(_ r: RecordedRequest) -> [String: AnyHashable]? {
        (r.json["link_preview_options"] as? [String: Any])?.compactMapValues { $0 as? AnyHashable }
    }

    /// 실측(2026-10-15): 한 질문에 상대가 답글 말풍선 → (반응) → 답글 → 링크 말풍선(미리보기 그림 3개 첨부) →
    /// 링크 2개 든 글 → 글 로 연달아 답했다. 고치기 전에는 텔레그램에 `<UUID>.pluginPayloadAttachment`
    /// 파일 3개 + 제목 없는 주소 한 줄이 따로 올라오고, 모든 말풍선이 같은 원글을 인용했다.
    func testObservedLinkReplyRunBecomesOneLinkCardAndOneReplyHeader() async throws {
        let h = try Harness.make()
        h.sender.echoAsAttributedBody = true
        try await h.relay.start()
        let ask = try await askFromTelegram(h)
        let before = MockTelegram.calls("sendMessage").count
        let link = "https://blog.example.com/@writer/95"
        try h.fixture.insert(text: "찾아볼게요.", threadOriginator: ask, threadPart: "0:0:8")
        try h.fixture.insert(text: "Liked “링크 좀 찾아줘”", assocType: 2001, assocGuid: "p:0/\(ask)")
        try h.fixture.insert(text: "후기 하나 찾았어요.", threadOriginator: ask, threadPart: "0:0:8")
        let card = try h.fixture.insertURLBalloon(text: link, payload: RichLinkFixture.payload(title: "가짜 글 제목", siteName: "예시 블로그", url: link),
                                                  threadOriginator: ask, threadPart: "0:0:8")
        try h.fixture.insert(text: "나머지 링크예요.\n하나: https://news.example.com/a.html\n둘: https://trends.example.org/124",
                             threadOriginator: ask, threadPart: "0:0:8")
        try h.fixture.insert(text: "목록은 원하시면 드릴게요.", threadOriginator: ask, threadPart: "0:0:8")
        await h.relay.tick()

        XCTAssertTrue(MockTelegram.calls("sendDocument").isEmpty, "미리보기 그림을 파일로 올리지 않는다")
        XCTAssertTrue(MockTelegram.calls("sendPhoto").isEmpty)
        let sent = Array(MockTelegram.calls("sendMessage").dropFirst(before))
        XCTAssertEqual(sent.map { $0.json["text"] as? String }, [
            "찾아볼게요.", "후기 하나 찾았어요.", "🔗 가짜 글 제목\n\(link)",
            "나머지 링크예요.\n하나: https://news.example.com/a.html\n둘: https://trends.example.org/124",
            "목록은 원하시면 드릴게요.",
        ])
        XCTAssertEqual(replyIDs(sent), [42, nil, nil, nil, nil], "같은 원글에 연달아 단 답글은 첫 말풍선만 인용한다")
        XCTAssertEqual(preview(sent[2]), ["url": link], "링크 말풍선만 그 주소로 미리보기를 켠다")
        for i in [0, 1, 3, 4] { XCTAssertEqual(preview(sent[i]), ["is_disabled": true]) }
        // 링크 말풍선도 텔레그램 글 하나에 매핑돼 반응·답글이 이어진다.
        XCTAssertNotNil(try h.state.tgMessageID(forGuid: card.guid, part: 0))
    }

    /// 실측(1216 모양): 본문 `text` 가 NULL 이고 주소는 attributedBody 에만, 미리보기 그림은 아직 안 내려왔다.
    /// 그림을 기다리느라 커서를 멈추지 않고 바로 보낸다.
    func testLinkBalloonWithBodyOnlyInAttributedBodyIsNotHeldForPreviewImages() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let original = "https://news.example.com/view/A1?section=society%2Fall"
        try h.fixture.insertURLBalloon(text: nil, blobText: original,
                                       payload: RichLinkFixture.payload(title: "[가짜] 내일 날씨 | 예시 뉴스", url: "https://news.example.com/view/A1"),
                                       previewFiles: 1, downloaded: false)
        await h.relay.tick()
        let r = try XCTUnwrap(MockTelegram.calls("sendMessage").last)
        XCTAssertEqual(r.json["text"] as? String, "🔗 [가짜] 내일 날씨 | 예시 뉴스\n\(original)")
        XCTAssertEqual(preview(r), ["url": original])
        XCTAssertTrue(MockTelegram.calls("sendDocument").isEmpty)
    }

    func testLinkBalloonWithUnreadablePayloadStillSendsURLOnce() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.fixture.insertURLBalloon(text: "https://a.example.com/x", payload: Data("garbage".utf8), previewFiles: 2)
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").map { $0.json["text"] as? String }, ["https://a.example.com/x"])
        XCTAssertTrue(MockTelegram.calls("sendDocument").isEmpty)
    }

    /// 다른 말풍선 앱 행이 글 없이 자료 첨부뿐이면, 조용히 사라지지 않게 못 옮겼다고 한 줄 남긴다.
    func testOtherAppBalloonWithOnlyPayloadIsNotSilentlyDropped() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.fixture.insertURLBalloon(text: nil, payload: nil, previewFiles: 1,
                                       bundleID: "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.example.game")
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").map { $0.json["text"] as? String }, ["[iMessage 앱 메시지라 옮기지 못함: com.example.game]"])
        XCTAssertTrue(MockTelegram.calls("sendDocument").isEmpty)
    }

    /// 사이에 다른 글(상대의 일반 글, 텔레그램에서 보낸 내 글)이 끼면 다음 답글은 다시 원글을 인용한다.
    func testReplyHeaderReturnsAfterAnotherMessageInterleaves() async throws {
        let h = try Harness.make()
        h.sender.echoAsAttributedBody = true
        try await h.relay.start()
        let ask = try await askFromTelegram(h)
        let before = MockTelegram.calls("sendMessage").count
        try h.fixture.insert(text: "답 1", threadOriginator: ask, threadPart: "0:0:8")
        try h.fixture.insert(text: "답글 아닌 글")
        try h.fixture.insert(text: "답 2", threadOriginator: ask, threadPart: "0:0:8")
        try h.fixture.insert(text: "답 3", threadOriginator: ask, threadPart: "0:0:8")
        await h.relay.tick()
        _ = try await askFromTelegram(h, "다른 질문", id: 43, update: 2)
        try h.fixture.insert(text: "답 4", threadOriginator: ask, threadPart: "0:0:8")
        await h.relay.tick()
        let sent = Array(MockTelegram.calls("sendMessage").dropFirst(before))
        XCTAssertEqual(sent.map { $0.json["text"] as? String }, ["답 1", "답글 아닌 글", "답 2", "답 3", "답 4"])
        XCTAssertEqual(replyIDs(sent), [42, nil, 42, nil, 42])
    }

    /// 내가 iPhone 에서 보낸 링크(메타데이터 없는 자리표시 payload)도 주소 한 통으로 미러한다.
    func testOwnLinkBalloonFromIPhoneIsMirroredAsURL() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.fixture.insertURLBalloon(text: "https://a.example.com/mcp", payload: RichLinkFixture.placeholderPayload(), previewFiles: 0, fromMe: true)
        await h.relay.tick()
        let r = try XCTUnwrap(MockTelegram.calls("sendMessage").last)
        XCTAssertEqual(r.json["text"] as? String, Relay.ownPrefix + "https://a.example.com/mcp")
        XCTAssertEqual(preview(r), ["url": "https://a.example.com/mcp"])
    }

    /// 텔레그램 → iMessage: 글자 뒤에 숨은 링크(text_link)는 주소를 펼쳐 보낸다(iMessage 는 서식이 없어 주소가 사라진다).
    func testTelegramHiddenLinkReachesIMessageWithURL() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        var u = Harness.textUpdate(1, messageID: 50, text: "이 글 보세요")
        var msg = u["message"] as! [String: Any]
        msg["entities"] = [["type": "text_link", "offset": 2, "length": 1, "url": "https://docs.example.com/p"]]
        u["message"] = msg
        MockTelegram.enqueue([u])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.last?.payload, "이 글 (https://docs.example.com/p) 보세요")
        XCTAssertEqual(try h.state.outbox(tgMessageID: 50).map(\.status), [.confirmed], "펼친 글 그대로 메아리가 맞는다")
    }
}
