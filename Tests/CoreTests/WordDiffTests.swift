import Testing
@testable import Core

@Test func identicalTextsHaveNoErrors() {
    let result = WordDiff.compare(
        reference: ["привет", "мир"],
        candidate: ["привет", "мир"]
    )
    #expect(result.errorRate == 0)
    #expect(result.substitutions == 0)
    #expect(result.deletions == 0)
    #expect(result.insertions == 0)
}

@Test func detectsSubstitution() {
    let result = WordDiff.compare(
        reference: ["выкатили", "новую", "версию"],
        candidate: ["выкатили", "новую", "версии"]
    )
    #expect(result.substitutions == 1)
    #expect(result.deletions == 0)
    #expect(result.insertions == 0)
    #expect(result.operations.contains(.substitution(reference: "версию", candidate: "версии")))
}

@Test func detectsMissingWord() {
    let result = WordDiff.compare(
        reference: ["мы", "выкатили", "версию"],
        candidate: ["мы", "версию"]
    )
    #expect(result.deletions == 1)
    #expect(result.operations.contains(.deletion("выкатили")))
}

@Test func detectsExtraWord() {
    let result = WordDiff.compare(
        reference: ["мы", "версию"],
        candidate: ["мы", "уже", "версию"]
    )
    #expect(result.insertions == 1)
    #expect(result.operations.contains(.insertion("уже")))
}

@Test func errorRateIsRelativeToReferenceLength() {
    let result = WordDiff.compare(
        reference: ["раз", "два", "три", "четыре"],
        candidate: ["раз", "два", "три", "пять"]
    )
    #expect(result.referenceWordCount == 4)
    #expect(abs(result.errorRate - 0.25) < 0.0001)
}

@Test func emptyCandidateMeansEverythingIsMissing() {
    let result = WordDiff.compare(reference: ["раз", "два"], candidate: [])
    #expect(result.deletions == 2)
    #expect(result.errorRate == 1.0)
}

@Test func emptyReferenceGivesZeroRateWithoutDividingByZero() {
    let result = WordDiff.compare(reference: [], candidate: ["раз"])
    #expect(result.insertions == 1)
    #expect(result.errorRate == 0)
}

@Test func operationsAreInReadingOrder() {
    let result = WordDiff.compare(
        reference: ["раз", "два", "три"],
        candidate: ["раз", "три"]
    )
    #expect(result.operations == [.match("раз"), .deletion("два"), .match("три")])
}
