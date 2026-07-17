import XCTest
@testable import Stub

final class P1ProtocolTests: XCTestCase {
    private let capturedSessionKey: UInt32 = 0xDCD60DCF

    func testCRCRegistrationMatchesOfficialCapture() {
        let registration = capturedSessionKey ^ P1Protocol.standardCRCKey
        XCTAssertEqual(registration.littleEndianBytes, [0xEE, 0x98, 0xA0, 0xE9])
    }

    func testInitializationMatchesOfficialFirstFrames() {
        let writes = P1Protocol.initializationWrites(sessionKey: capturedSessionKey)
        XCTAssertEqual(writes[0], P1Protocol.capturedAuthPacket)
        XCTAssertEqual(writes[1].hexString, "0218010400ee98a0e9794eb55f03")
        XCTAssertEqual(writes[2].hexString, "020a0201000137d602ae03")
    }

    func testPrintRasterUses384DotRowsAndFiveMillimetreFeed() {
        let raster = Data(repeating: 0xFF, count: P1Protocol.imagePayloadBytes)
        let writes = P1Protocol.printWrites(raster: raster, sessionKey: capturedSessionKey)
        let stream = writes.dropFirst(2).reduce(into: Data()) { $0.append($1) }
        let parsed = P1Protocol.parseFrames(stream)
        XCTAssertTrue(parsed.trailing.isEmpty)
        XCTAssertEqual(parsed.frames.count, 5)
        XCTAssertEqual(parsed.frames.first(where: { $0.command == P1Protocol.Command.printData })?.payload.count, 1008)
        XCTAssertEqual(parsed.frames.last?.payload, Data([0x18, 0x01]))
    }

    func testPowerOffPresetPayloadsUseSecondsAsLittleEndianUInt16() {
        XCTAssertEqual(P1Protocol.powerOffPayload(.minutes(3)), Data([0xB4, 0x00]))
        XCTAssertEqual(P1Protocol.powerOffPayload(.minutes(60)), Data([0x10, 0x0E]))
        XCTAssertEqual(P1Protocol.powerOffPayload(.minutes(600)), Data([0xA0, 0x8C]))
        XCTAssertEqual(P1Protocol.powerOffPayload(.never), Data([0x00, 0x00]))
    }

    func testPowerOffSetFrameAndRepliesUseCommand20Response() {
        let frame = P1Protocol.frame(
            command: P1Protocol.Command.setPowerOffTime,
            sequence: 9,
            payload: P1Protocol.powerOffPayload(.minutes(3)),
            seed: capturedSessionKey
        )
        let parsed = P1Protocol.parseFrames(frame)
        XCTAssertEqual(parsed.frames.first?.command, P1Protocol.Command.setPowerOffTime)
        XCTAssertEqual(parsed.frames.first?.payload, Data([0xB4, 0x00]))
        XCTAssertEqual(P1Protocol.replyCommands[P1Protocol.Command.setPowerOffTime], 0x20)
        XCTAssertEqual(P1Protocol.replyCommands[P1Protocol.Command.getPowerOffTime], 0x20)
    }

    func testUnknownPowerOffValueIsPreserved() {
        let duration = PowerOffDuration.from(rawValue: 17)
        XCTAssertEqual(duration, .unknown(17))
        XCTAssertEqual(duration.rawValue, 17)
        XCTAssertFalse(duration.isPreset)

        XCTAssertEqual(PowerOffDuration.from(rawValue: 3600), .minutes(60))
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
