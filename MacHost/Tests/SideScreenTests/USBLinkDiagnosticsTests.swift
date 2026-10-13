import XCTest
import Network
@testable import HarmonyScreen
final class USBLinkDiagnosticsTests: XCTestCase {
    func testUnknownAndAmbiguousLinksAreNotClaimedAsUSB3() {
        let usb: [String:Any] = ["USB Product Name":"HDC Device", "UsbLinkSpeed":NSNumber(value:5_000_000_000 as UInt64)]
        XCTAssertEqual(USBLinkDiagnostics.speedMbps(properties:[usb]),5000)
        XCTAssertEqual(USBLinkDiagnostics.speedMbps(properties:[]),0)
        XCTAssertEqual(USBLinkDiagnostics.speedMbps(properties:[usb,usb]),0)
        XCTAssertEqual(USBLinkDiagnostics.speedMbps(properties:[["USB Product Name":"HDC Device"]]),0)
        XCTAssertEqual(USBLinkDiagnostics.speedMbps(properties:[["USB Product Name":"Other", "UsbLinkSpeed":NSNumber(value:5_000_000_000 as UInt64)]]),0)
    }
    func testDiagnosticsOptInPreservesFollowingPingAndKeyframe() async throws {
        let server=StreamingServer(port:0)
        defer { server.stop() }
        let keyframe=expectation(description:"following request survived")
        server.onKeyframeRequested={ force in XCTAssertTrue(force); keyframe.fulfill() }
        try await server.start()
        let client=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:server.boundPort!)!,using:.tcp)
        defer { client.cancel() }
        let ready=expectation(description:"ready")
        client.stateUpdateHandler={ if case .ready = $0 { ready.fulfill() } }
        client.start(queue:DispatchQueue(label:"diagnostics-test"))
        await fulfillment(of:[ready],timeout:2)
        let info=expectation(description:"opt-in response first")
        client.receive(minimumIncompleteLength:5,maximumLength:5) { data,_,_,error in
            XCTAssertNil(error); XCTAssertEqual(data?.first,19); XCTAssertEqual(data?.count,5); info.fulfill()
        }
        client.send(content:Data([18,4,0,0,0,0,0,0,0,1,7,1]),completion:.contentProcessed {_ in})
        await fulfillment(of:[info,keyframe],timeout:2)
    }
    func testBoundedTestPacketHasExpectedLengthAndCheckPattern() {
        let p=USBLinkDiagnostics.testPacket()
        XCTAssertEqual(p.count,16*1024*1024+5)
        XCTAssertEqual(Array(p.prefix(5)),[21,1,0,0,0])
        for i in [0,1,255,256,65535,65536,USBLinkDiagnostics.testBytes-1] {
            XCTAssertEqual(p[i+5],UInt8(truncatingIfNeeded:i*73+19))
        }
    }
}
