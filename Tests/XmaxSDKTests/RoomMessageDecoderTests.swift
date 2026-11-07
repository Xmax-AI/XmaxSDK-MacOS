//
//  RoomMessageDecoderTests.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class RoomMessageDecoderTests: XCTestCase {
    func testPlainAckAndInvalidCounts() throws {
        var decoder = RoomMessageDecoder()
        let value = decoder.decode(sender: "bot", data: Data(#"{"event":"xid_ack","xid":"one","count":1}"#.utf8))
        XCTAssertEqual(value?.xid, "one")
        XCTAssertEqual(value?.count, 1)
        for count in ["true", "1.5", "\"1\"", "90071992547409920000000"] {
            XCTAssertNil(decoder.decode(sender: "bot", data: Data("{\"event\":\"xid_ack\",\"count\":\(count)}".utf8)))
        }
    }

    func testOutOfOrderFragmentsAreIsolatedBySenderAndResetOnLeave() throws {
        for event in ["__agora_chunk__", "__trtc_chunk__"] {
            var decoder = RoomMessageDecoder()
            let raw = "{\"event\":\"xid_ack\",\"xid\":\"one\",\"count\":2,\"unused\":\"\(String(repeating: "x", count: 1800))\"}"
            let parts = try RtcMessageCodec.encode(raw).map {
                Data(String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "__agora_chunk__", with: event).utf8)
            }
            XCTAssertGreaterThan(parts.count, 1)
            XCTAssertNil(decoder.decode(sender: "other", data: parts[0]))
            for part in parts.dropFirst().reversed() {
                XCTAssertNil(decoder.decode(sender: "bot", data: part))
            }
            let message = decoder.decode(sender: "bot", data: parts[0])
            XCTAssertEqual(message?.xid, "one")
            XCTAssertEqual(message?.count, 2)
            decoder.reset()
            XCTAssertNil(decoder.decode(sender: "other", data: parts.last!))
        }
    }

    func testRejectsInconsistentOrOversizedFragmentEnvelope() {
        var decoder = RoomMessageDecoder()
        for raw in [
            #"{"event":"__trtc_chunk__","eventId":"id","index":-1,"count":1,"data":"{}"}"#,
            #"{"event":"__trtc_chunk__","eventId":"id","index":0,"count":513,"data":"{}"}"#,
            #"{"event":"__trtc_chunk__","eventId":"id","index":0,"count":2,"data":"{"}"#,
            #"{"event":"__trtc_chunk__","eventId":"id","index":1,"count":3,"data":"}"}"#
        ] {
            XCTAssertNil(decoder.decode(sender: "bot", data: Data(raw.utf8)))
        }
        let finalPart = #"{"event":"__trtc_chunk__","eventId":"id","index":1,"count":2,"data":"\"event\":\"xid_ack\",\"xid\":\"one\",\"count\":1}"}"#
        let completed = decoder.decode(sender: "bot", data: Data(finalPart.utf8))
        XCTAssertEqual(completed?.xid, "one")
    }
}
