import Testing
@testable import Keystorm

struct DictationFillerCleanupTests {
    @Test("Fillers and stutters go; real words stay",
          arguments: [
            ("Äh, bitte schick mir die Datei", "Bitte schick mir die Datei"),
            ("äh bitte schick mir die Datei", "Bitte schick mir die Datei"),
            ("I think, uh, we should go", "I think, we should go"),
            ("I think uh we should go", "I think we should go"),
            ("Um, I wanted to ask", "I wanted to ask"),
            ("Wir treffen uns um 10 Uhr", "Wir treffen uns um 10 Uhr"),
            ("Wir kommen, um zu helfen", "Wir kommen, um zu helfen"),
            ("I wanted to to ask if the the plan works", "I wanted to ask if the plan works"),
            ("That that is fine and he had had enough", "That that is fine and he had had enough"),
            ("Das ist ähm gut", "Das ist gut"),
            ("Hello world.", "Hello world."),
            ("Ich ich komme morgen", "Ich komme morgen"),
            ("Okay. Äh, next point", "Okay. Next point"),
            ("Hello team.\num I think it works great.", "Hello team.\nI think it works great."),
            ("So um I think we should go", "So I think we should go"),
            ("Ich glaube wir sollten um Hilfe bitten", "Ich glaube wir sollten um Hilfe bitten"),
            ("Let's meet at um 10", "Let's meet at um 10"),
            ("Uh-huh, that works", "Uh-huh, that works"),
            ("Uh-oh, the build broke", "Uh-oh, the build broke"),
            ("She said mm-hmm and left", "She said mm-hmm and left"),
            ("Hmm, that is odd", "That is odd"),
            ("Let's meet on Tuesday. No wait, Wednesday at 10.", "Let's meet on Tuesday no wait Wednesday at 10."),
            ("Wir treffen uns am Dienstag. Nein, warte, am Mittwoch um zehn.",
             "Wir treffen uns am Dienstag nein warte am Mittwoch um zehn."),
            ("Book Monday. Scratch that, Tuesday afternoon.", "Book Monday scratch that Tuesday afternoon."),
            ("It works. I mean it.", "It works. I mean it."),
            ("We said no. Wait for the signal.", "We said no. Wait for the signal."),
          ])
    func rules(source: String, expected: String) {
        #expect(DictationFillerCleanup.apply(to: source) == expected)
    }

    @Test("A transcript that is only a filler is left as spoken")
    func loneFiller() {
        #expect(DictationFillerCleanup.apply(to: "äh") == "äh")
        #expect(DictationFillerCleanup.apply(to: "") == "")
    }
}
