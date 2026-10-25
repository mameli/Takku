import Foundation

/// Writes the Summary with a Provider: in one request if the Transcript fits in the model's
/// context, otherwise summarising in blocks and merging the partial summaries. A full-text Template
/// is rewritten in blocks of about 10 minutes, joined in order.
public struct Summarizer: Sendable {
    private let client: ChatClient
    private let maxContextTokens: Int
    private let log: SummaryLog.Recorder?

    /// Below this context there is no useful room left for the Transcript after rules and reply.
    public static let minimumContextTokens = 8_192

    /// With `log`, every request and reply is also copied there.
    public init(client: ChatClient, maxContextTokens: Int, log: SummaryLog.Recorder? = nil) {
        self.client = client
        self.maxContextTokens = max(maxContextTokens, Self.minimumContextTokens)
        self.log = log
    }

    /// The Summary, as the title is asked on and as the Meeting note shows it.
    public struct Summary: Equatable, Sendable {
        public let text: String
        /// `text` with the Transcript's Screenshots under the points they belong to.
        public let withScreenshots: String
    }

    /// The model cites the Transcript times of every point; they are removed here, after the
    /// merge has used those of the partial summaries and the Screenshots have been placed with them,
    /// together with any star of a marked paragraph.
    public func summarize(_ prompt: SummaryPrompt) async throws -> Summary {
        let reply = try await reply(prompt)
        let transcript = prompt.transcript
        let clean = { SummaryPrompt.removingMarks(SummaryPrompt.removingCitedTimes($0)) }
        return Summary(
            text: clean(reply),
            withScreenshots: clean(Screenshot.placing(transcript.screenshots, in: reply, paragraphs: transcript.paragraphs))
        )
    }

    private func reply(_ prompt: SummaryPrompt) async throws -> String {
        if prompt.isFullText {
            return try await fullText(prompt)
        }
        if prompt.fits(maxContextTokens: maxContextTokens) {
            return try await client(.single).complete(prompt.singleRequest())
        }
        var partials = try await complete(prompt.partialRequests(maxContextTokens: maxContextTokens), as: .partial)
        // Very long Meetings: summaries are merged in groups until the final merge fits in the context.
        while !prompt.mergeFits(partials: partials, maxContextTokens: maxContextTokens) {
            let groups = prompt.groupRequests(partials: partials, maxContextTokens: maxContextTokens)
            guard groups.count < partials.count else { break }
            partials = try await complete(groups, as: .group)
        }
        return try await client(.merge).complete(prompt.mergeRequest(partials: partials))
    }

    /// A full-text Template: even a Transcript that would fit in one request is rewritten block by
    /// block, since a model asked for a very long text in one reply shortens it more and more as it
    /// goes. Each block is told the heading the previous one ended under; the parts are joined, not merged.
    private func fullText(_ prompt: SummaryPrompt) async throws -> String {
        let blocks = prompt.fullTextBlocks(maxContextTokens: maxContextTokens)
        let client = client(.block)
        var parts: [String] = []
        for (index, block) in blocks.enumerated() {
            let request = prompt.fullTextRequest(
                part: index + 1, of: blocks.count, paragraphs: block,
                previousHeading: parts.last.flatMap(SummaryPrompt.lastHeading)
            )
            parts.append(try await client.complete(request))
        }
        return SummaryPrompt.joiningFullTextParts(parts)
    }

    private func complete(_ requests: [[ChatMessage]], as kind: SummaryLog.Call.Kind) async throws -> [String] {
        let client = client(kind)
        var replies: [String] = []
        for request in requests {
            replies.append(try await client.complete(request))
        }
        return replies
    }

    private func client(_ kind: SummaryLog.Call.Kind) -> ChatClient {
        log.map { client.recording(into: $0, as: kind) } ?? client
    }
}
