import AVFoundation
import XCTest
@testable import CamFetti

final class PlaybackTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testLoginReturnsToken() throws {
        let ok = json(#"[{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"abc123"}}}]"#)
        XCTAssertEqual(try ReolinkClient.parseLogin(ok), "abc123")
    }

    func testLoginFailureIsWrongPassword() {
        let bad = json(#"[{"cmd":"Login","code":1,"error":{"detail":"login failed","rspCode":-7}}]"#)
        XCTAssertThrowsError(try ReolinkClient.parseLogin(bad)) { XCTAssertEqual($0 as? ReolinkClient.Failure, .wrongPassword) }
    }

    func testLoginOnSomethingElseIsNotReolink() {
        XCTAssertThrowsError(try ReolinkClient.parseLogin(json("<html>hi</html>"))) {
            XCTAssertEqual($0 as? ReolinkClient.Failure, .notReolink)
        }
    }

    func testProbeRecognizesPleaseLoginFirst() {
        XCTAssertTrue(ReolinkClient.isReolinkReply(json(#"[{"cmd":"GetDevInfo","code":1,"error":{"detail":"please login first","rspCode":-6}}]"#)))
        XCTAssertFalse(ReolinkClient.isReolinkReply(json(#"{"error":"nope"}"#)))
        XCTAssertFalse(ReolinkClient.isReolinkReply(json("<html></html>")))
    }

    func testCardDetection() throws {
        XCTAssertTrue(try ReolinkClient.parseHasCard(json(#"[{"cmd":"GetHddInfo","code":0,"value":{"HddInfo":[{"capacity":30524,"format":1,"mount":1,"number":0,"size":401,"storageType":2}]}}]"#)))
        XCTAssertFalse(try ReolinkClient.parseHasCard(json(#"[{"cmd":"GetHddInfo","code":0,"value":{"HddInfo":[]}}]"#)))
    }

    func testDaysFromMonthTables() throws {
        // October: days 11 to 31. November: days 1 to 7.
        let data = json(#"[{"cmd":"Search","code":0,"value":{"SearchResult":{"Status":[{"mon":10,"table":"0000000000111111111111111111111","year":2026},{"mon":11,"table":"111111100000000000000000000000","year":2026}]}}}]"#)
        let days = try ReolinkClient.parseDays(data, timeZone: tz)
        XCTAssertEqual(days.count, 28)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        XCTAssertEqual(cal.dateComponents([.month, .day], from: days.first!), DateComponents(month: 10, day: 11))
        XCTAssertEqual(cal.dateComponents([.month, .day], from: days.last!), DateComponents(month: 11, day: 7))
    }

    func testClipsParseAndSortOldestFirst() throws {
        let data = json(#"[{"cmd":"Search","code":0,"value":{"SearchResult":{"File":[{"EndTime":{"day":7,"hour":20,"min":58,"mon":11,"sec":13,"year":2026},"StartTime":{"day":7,"hour":20,"min":57,"mon":11,"sec":37,"year":2026},"name":"Rec_20261108_015737_541_M.mp4","size":12202936,"type":"main"},{"EndTime":{"day":7,"hour":9,"min":1,"mon":11,"sec":0,"year":2026},"StartTime":{"day":7,"hour":9,"min":0,"mon":11,"sec":0,"year":2026},"name":"Rec_early.mp4","size":"100","type":"main"}]}}}]"#)
        let clips = try ReolinkClient.parseClips(data, timeZone: tz)
        XCTAssertEqual(clips.map(\.name), ["Rec_early.mp4", "Rec_20261108_015737_541_M.mp4"])
        XCTAssertEqual(clips[1].duration, 36)
        XCTAssertEqual(clips[0].size, 100)
    }

    func testEmptySearchIsNoClips() throws {
        XCTAssertEqual(try ReolinkClient.parseClips(json(#"[{"cmd":"Search","code":0,"value":{"SearchResult":{"channel":0}}}]"#), timeZone: tz), [])
    }

    func testTimeObjectRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_794_103_057) // 2026-11-07 ~20:57 New York
        let object = ReolinkClient.timeObject(date, timeZone: tz)
        XCTAssertEqual(ReolinkClient.date(from: object, timeZone: tz), date)
    }

    func testPlaybackURLEncodesNameAndToken() throws {
        let client = ReolinkClient(base: URL(string: "http://192.168.1.9")!, username: "u", password: "p")
        let clip = Recording(name: "Rec 1&2.mp4", start: .now, end: .now, size: 1)
        let url = try XCTUnwrap(client.playbackURL(for: clip, token: "tok"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/cgi-bin/api.cgi")
        XCTAssertEqual(items.first { $0.name == "source" }?.value, "Rec 1&2.mp4")
        XCTAssertEqual(items.first { $0.name == "cmd" }?.value, "Playback")
        XCTAssertFalse(url.absoluteString.contains("p@"), "no password in the URL")
    }

    func testLabels() {
        XCTAssertEqual(PlaybackView.durationText(36), "36s")
        XCTAssertEqual(PlaybackView.durationText(125), "2m 05s")
    }

    /// Reads a real Reolink's card. Skipped unless CAMFETTI_REOLINK holds base64 JSON {"host","user","pass"}.
    /// Signs in once and never retries. Prints no secrets.
    func testRealReolinkCard() async throws {
        guard let b64 = ProcessInfo.processInfo.environment["CAMFETTI_REOLINK"], let data = Data(base64Encoded: b64),
              let cfg = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let host = cfg["host"], let user = cfg["user"], let pass = cfg["pass"] else {
            throw XCTSkip("no Reolink configured")
        }
        let client = ReolinkClient(base: URL(string: "http://\(host)")!, username: user, password: pass)
        let probe = await client.isReolink()
        XCTAssertTrue(probe)
        let token = try await client.login()
        do {
            let card = try await client.hasCard(token)
            XCTAssertTrue(card)
            let days = try await client.days(token, from: Date().addingTimeInterval(-30 * 86400), to: Date())
            let newest = try XCTUnwrap(days.first)
            let clips = try await client.clips(token, on: newest)
            let clip = try XCTUnwrap(clips.last)
            print("REOLINK days=\(days.count) clipsNewestDay=\(clips.count) last=\(clip.start) dur=\(clip.duration)s")
            var request = URLRequest(url: try XCTUnwrap(client.playbackURL(for: clip, token: token)))
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let (body, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(body.dropFirst(4).prefix(4), Data("ftyp".utf8))
            let asset = AVURLAsset(url: try XCTUnwrap(client.playbackURL(for: clip, token: token)))
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks).map(\.mediaType)
            print("REOLINK asset duration=\(duration.seconds)s tracks=\(tracks.map(\.rawValue))")
            XCTAssertGreaterThan(duration.seconds, 1)
            XCTAssertTrue(tracks.contains(.video))
        } catch {
            await client.logout(token)
            throw error
        }
        await client.logout(token)
    }
}
