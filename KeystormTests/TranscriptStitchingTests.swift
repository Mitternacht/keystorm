import Testing
@testable import Keystorm

/// Windows are decoded one segment at a time, so the same word can come out on both sides of a seam.
@MainActor
struct TranscriptStitchingTests {
    private func transcript(_ text: String, _ start: Double, _ end: Double) -> TranscriptRevision {
        TranscriptRevision(rawText: text, text: text, segmentIDs: [], startTime: start, endTime: end,
                           timingPrecision: .window, configurationID: nil, isComplete: true)
    }

    @Test("A word that comes out on both sides of a seam is kept once",
          arguments: [
            ("Wir reden über", "über das Budget.", "Wir reden über das Budget."),
            ("Se acabó todos los días", "días para siempre.", "Se acabó todos los días para siempre."),
            ("We have a cleaner mobile", "mobile experience.", "We have a cleaner mobile experience."),
            ("Es geht um das Ziel", "Ziel. Danach weiter.", "Es geht um das Ziel. Danach weiter."),
            ("Es geht um das Ziel,", "Ziel danach weiter.", "Es geht um das Ziel, danach weiter.")
          ])
    func seamDuplicateIsRemoved(first: String, second: String, expected: String) {
        let parts = [transcript(first, 0, 5), transcript(second, 5, 10)]
        #expect(WorkspaceModel.stitchedText(parts, \.text) == expected)
    }

    @Test("A repeated word inside a segment, across a pause, or across a gap in the audio is never touched")
    func otherRepeatsStay() {
        #expect(WorkspaceModel.stitchedText([transcript("It was very very good", 0, 5), transcript("and then it ended", 5, 10)], \.text)
                == "It was very very good and then it ended")
        // A pause keeps the timeline apart, so the same word on either side is two spoken words.
        #expect(WorkspaceModel.stitchedText([transcript("I said no", 0, 5), transcript("no more", 12, 17)], \.text)
                == "I said no no more")
        #expect(WorkspaceModel.stitchedText([transcript("Eins zwei", 0, 5), transcript("drei vier", 5, 10)], \.text)
                == "Eins zwei drei vier")
    }

    @Test("Empty segments and a single segment stitch without surprises")
    func edges() {
        #expect(WorkspaceModel.stitchedText([], \.text).isEmpty)
        #expect(WorkspaceModel.stitchedText([transcript("Hallo Welt", 0, 5)], \.text) == "Hallo Welt")
        #expect(WorkspaceModel.stitchedText([transcript("Hallo", 0, 5), transcript("", 5, 10), transcript("Hallo Welt", 10, 15)], \.text)
                == "Hallo Welt")
    }

    // MARK: Words both windows left to the other

    @Test("A word both windows pushed to the other side of the seam is put back",
          arguments: [
            (["Ende"], ["Ende"], "Am", ["Ende"]),
            (["probar"], ["probar"], "para", ["probar"]),
            (["Ende,"], ["ende"], "Am", ["Ende,"]),
            (["so", "that"], ["so", "that"], "is", ["so", "that"]),
            (["a", "b"], ["x", "a"], "w", ["a"]),
            (["a", "b", "c", "d"], ["x", "a", "b", "c"], "w", ["a", "b", "c"])
          ] as [([String], [String], String, [String])])
    func lostSeamWordIsRecovered(tail: [String], lead: [String], lastOwned: String, expected: [String]) {
        #expect(WorkspaceModel.seamBridge(tail: tail, lead: lead, lastOwned: lastOwned) == expected)
    }

    @Test("A bridge is never invented when the windows disagree, are empty, or only repeat a word")
    func noBridgeWithoutAgreement() {
        // The windows heard different things at the seam: nothing to add.
        #expect(WorkspaceModel.seamBridge(tail: ["my"], lead: ["mi"], lastOwned: "es").isEmpty)
        #expect(WorkspaceModel.seamBridge(tail: [], lead: ["Ende"], lastOwned: "Am").isEmpty)
        #expect(WorkspaceModel.seamBridge(tail: ["Ende"], lead: [], lastOwned: "Am").isEmpty)
        // Punctuation alone is not a word.
        #expect(WorkspaceModel.seamBridge(tail: ["-"], lead: ["-"], lastOwned: nil).isEmpty)
        // The left window already ended on this word, so it is a repeat the speaker said, not a lost one.
        #expect(WorkspaceModel.seamBridge(tail: ["very"], lead: ["very"], lastOwned: "very").isEmpty)
        #expect(WorkspaceModel.seamBridge(tail: ["Very,"], lead: ["very"], lastOwned: "very").isEmpty)
        // No previous word kept at all is fine.
        #expect(WorkspaceModel.seamBridge(tail: ["Hallo"], lead: ["Hallo"], lastOwned: nil) == ["Hallo"])
    }
}
