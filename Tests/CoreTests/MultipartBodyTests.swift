import Foundation
import Testing
@testable import Core

@Test func fieldsAppearWithBoundaryAndName() {
    var body = MultipartBody(boundary: "TESTBOUNDARY")
    body.addField(name: "model_id", value: "scribe_v2")
    let text = String(decoding: body.finalized(), as: UTF8.self)

    #expect(text.contains("--TESTBOUNDARY\r\n"))
    #expect(text.contains("Content-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
}

@Test func fileCarriesFilenameAndContentType() {
    var body = MultipartBody(boundary: "TESTBOUNDARY")
    body.addFile(name: "file", filename: "audio.mp3", contentType: "audio/mpeg", data: Data([0x49, 0x44]))
    let text = String(decoding: body.finalized(), as: UTF8.self)

    #expect(text.contains("name=\"file\"; filename=\"audio.mp3\""))
    #expect(text.contains("Content-Type: audio/mpeg"))
}

@Test func bodyEndsWithClosingBoundary() {
    var body = MultipartBody(boundary: "TESTBOUNDARY")
    body.addField(name: "a", value: "b")
    let text = String(decoding: body.finalized(), as: UTF8.self)

    #expect(text.hasSuffix("--TESTBOUNDARY--\r\n"))
}

@Test func repeatedFieldNameProducesRepeatedParts() {
    // Keyterms are sent as repeated fields with the same name.
    var body = MultipartBody(boundary: "B")
    body.addField(name: "keyterms", value: "Kubernetes")
    body.addField(name: "keyterms", value: "Телемост")
    let text = String(decoding: body.finalized(), as: UTF8.self)

    #expect(text.components(separatedBy: "name=\"keyterms\"").count == 3)
}
