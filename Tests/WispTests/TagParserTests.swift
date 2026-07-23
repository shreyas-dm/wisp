import Foundation
@testable import WispKit

/// Runs a full string through a fresh parser in one consume + finish.
private func parseWhole(_ input: String) -> [ResponseChunk] {
    var parser = ResponseTagParser()
    return parser.consume(input) + parser.finish()
}

private func joinedText(_ chunks: [ResponseChunk]) -> String {
    chunks.compactMap {
        if case .text(let text) = $0 { return text }
        return nil
    }.joined()
}

private func tags(_ chunks: [ResponseChunk]) -> [ResponseTag] {
    chunks.compactMap {
        if case .tag(let tag) = $0 { return tag }
        return nil
    }
}

func tagParserTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("plain text passes through untouched") {
            let chunks = parseWhole("just a normal sentence, no tags at all.")
            t.expectEqual(chunks, [.text("just a normal sentence, no tags at all.")])
        },

        TestCase("point tag mid-sentence") {
            let chunks = parseWhole("Click Export [[point:e42]] in the toolbar.")
            t.expectEqual(joinedText(chunks), "Click Export  in the toolbar.")
            t.expectEqual(tags(chunks), [.point(elementID: "e42")])
        },

        TestCase("tag survives a split at every offset") {
            let full = "Click here [[point:e42]] now"
            for cut in 0...full.count {
                var parser = ResponseTagParser()
                let head = String(full.prefix(cut))
                let tail = String(full.dropFirst(cut))
                var chunks = parser.consume(head)
                chunks += parser.consume(tail)
                chunks += parser.finish()
                t.expectEqual(joinedText(chunks), "Click here  now", "cut=\(cut)")
                t.expectEqual(tags(chunks), [.point(elementID: "e42")], "cut=\(cut)")
            }
        },

        TestCase("coordinate point forms") {
            t.expectEqual(
                tags(parseWhole("Look [[point:100,200,1]]")),
                [.pointCoordinate(x: 100, y: 200, displayIndex: 1)]
            )
            t.expectEqual(
                tags(parseWhole("Look [[point:12.5, 40]]")),
                [.pointCoordinate(x: 12.5, y: 40, displayIndex: 0)]
            )
        },

        TestCase("screenshot request alone") {
            let chunks = parseWhole("[[screenshot]]")
            t.expectEqual(chunks, [.tag(.screenshotRequest)])
        },

        TestCase("remember fact with punctuation and colons") {
            let chunks = parseWhole("Noted! [[remember:Prefers vim: yes, really. Uses zsh.]]")
            t.expectEqual(tags(chunks), [.remember(fact: "Prefers vim: yes, really. Uses zsh.")])
            t.expectEqual(joinedText(chunks), "Noted! ")
        },

        TestCase("unknown tag emitted verbatim") {
            let chunks = parseWhole("before [[foo:bar]] after")
            t.expectEqual(chunks, [.text("before [[foo:bar]] after")])
        },

        TestCase("empty remember is malformed, emitted verbatim") {
            let chunks = parseWhole("[[remember:]]")
            t.expectEqual(chunks, [.text("[[remember:]]")])
        },

        TestCase("invalid point ID is malformed, emitted verbatim") {
            let chunks = parseWhole("[[point:zzz]]")
            t.expectEqual(chunks, [.text("[[point:zzz]]")])
        },

        TestCase("unterminated tag flushes as text at finish") {
            var parser = ResponseTagParser()
            let first = parser.consume("start [[point:e1")
            t.expectEqual(first, [.text("start ")])
            t.expectEqual(parser.finish(), [.text("[[point:e1")])
        },

        TestCase("trailing single bracket joins next delta") {
            var parser = ResponseTagParser()
            var chunks = parser.consume("abc[")
            t.expectEqual(chunks, [.text("abc")])
            chunks = parser.consume("[point:e2]] d")
            t.expectEqual(joinedText(chunks), " d")
            t.expectEqual(tags(chunks), [.point(elementID: "e2")])
        },

        TestCase("back-to-back tags with no text between") {
            let chunks = parseWhole("[[point:e1]][[point:e2]]")
            t.expectEqual(chunks, [.tag(.point(elementID: "e1")), .tag(.point(elementID: "e2"))])
        },

        TestCase("text on both sides of a tag") {
            let chunks = parseWhole("a [[screenshot]] b")
            t.expectEqual(chunks, [.text("a "), .tag(.screenshotRequest), .text(" b")])
        },

        TestCase("overlong unterminated candidate released as literal text") {
            let literal = "[[" + String(repeating: "x", count: 250)
            var parser = ResponseTagParser()
            let chunks = parser.consume(literal) + parser.finish()
            t.expectEqual(joinedText(chunks), literal)
            t.expectEqual(tags(chunks), [])
        },

        TestCase("real tag after an overlong literal still parses") {
            let input = "[[" + String(repeating: "x", count: 250) + " then [[point:e5]] done"
            let chunks = parseWhole(input)
            t.expectEqual(tags(chunks), [.point(elementID: "e5")])
            t.expect(joinedText(chunks).hasSuffix(" then  done"), "surrounding text preserved")
        },

        TestCase("OCR element IDs (t-prefix) are pointable") {
            let chunks = parseWhole("read this line [[point:t7]] here")
            t.expectEqual(tags(chunks), [.point(elementID: "t7")])
            t.expectEqual(joinedText(chunks), "read this line  here")
        },

        TestCase("unknown ID prefixes are not point tags") {
            let chunks = parseWhole("[[point:x7]]")
            t.expectEqual(tags(chunks), [], "x-prefix rejected")
            t.expectEqual(joinedText(chunks), "[[point:x7]]", "malformed tag surfaces as text")
        },

        TestCase("step tag parses with element ID and instruction") {
            let chunks = parseWhole("Here's how. [[step:e5:Open the File menu]][[step:e9:Choose Export…]]")
            t.expectEqual(tags(chunks), [
                .step(elementID: "e5", instruction: "Open the File menu"),
                .step(elementID: "e9", instruction: "Choose Export…"),
            ])
            t.expectEqual(joinedText(chunks), "Here's how. ")
        },

        TestCase("step tag survives a split at every offset") {
            let full = "Go [[step:e12:Click the Save button]] on"
            for cut in 0...full.count {
                var parser = ResponseTagParser()
                let head = String(full.prefix(cut))
                let tail = String(full.suffix(full.count - cut))
                let chunks = parser.consume(head) + parser.consume(tail) + parser.finish()
                t.expectEqual(
                    tags(chunks),
                    [.step(elementID: "e12", instruction: "Click the Save button")],
                    "split at \(cut)"
                )
            }
        },

        TestCase("step without an instruction is literal text") {
            let chunks = parseWhole("[[step:e5]]")
            t.expectEqual(tags(chunks), [])
            t.expectEqual(joinedText(chunks), "[[step:e5]]")
        },

        TestCase("step accepts OCR t-prefixed targets, rejects other prefixes") {
            let okChunks = parseWhole("[[step:t3:Read the banner text]]")
            t.expectEqual(tags(okChunks), [.step(elementID: "t3", instruction: "Read the banner text")])
            let badChunks = parseWhole("[[step:z3:Nope]]")
            t.expectEqual(tags(badChunks), [])
            t.expectEqual(joinedText(badChunks), "[[step:z3:Nope]]")
        },

        TestCase("step instruction may itself contain colons") {
            let chunks = parseWhole("[[step:e2:Set the ratio to 16:9]]")
            t.expectEqual(tags(chunks), [.step(elementID: "e2", instruction: "Set the ratio to 16:9")])
        },

        TestCase("recall tag parses and empty recall is literal") {
            let chunks = parseWhole("[[recall:docker error yesterday]]")
            t.expectEqual(tags(chunks), [.recall(query: "docker error yesterday")])
            t.expectEqual(joinedText(chunks), "")
            let empty = parseWhole("[[recall:]]")
            t.expectEqual(tags(empty), [])
            t.expectEqual(joinedText(empty), "[[recall:]]")
        },

        TestCase("recall tag survives streaming splits") {
            let full = "[[recall:the site I showed you]]"
            for cut in 0...full.count {
                var parser = ResponseTagParser()
                let head = String(full.prefix(cut))
                let tail = String(full.suffix(full.count - cut))
                let chunks = parser.consume(head) + parser.consume(tail) + parser.finish()
                t.expectEqual(tags(chunks), [.recall(query: "the site I showed you")], "split at \(cut)")
            }
        },
    ]
}
