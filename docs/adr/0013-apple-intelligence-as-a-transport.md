# Apple Intelligence is a Provider behind the same Chat Completions client

Apple Intelligence gives every Mac with macOS 26 a local model through Foundation Models: free, offline, nothing to install. Takku uses it in two places: as a Summary Profile like the others, and for the title of a Meeting recorded with *Transcript* only, which before stayed *Meeting*.

The Profile goes through `ChatClient` as every Provider does (ADR 0004): its transport, instead of sending the request over the network, reads the Chat Completions body, gives the system messages to the model as instructions and the rest as the prompt, and answers with a Chat Completions body. Summaries in blocks, the merge, the title, the error handling and the Summary log work unchanged, and there is still one adapter. A dedicated client with guided generation (`@Generable`) was rejected: it would duplicate the Summary flow for one Provider.

The model is small, so two things change for it only:

- **Context**: what the system reports (`SystemLanguageModel.contextSize`: 4,096 tokens on macOS 26, 8,192 on macOS 27), read at every Summary rather than stored, and not raised to the 8,192 minimum the Summarizer applies to a Profile's value (`isReportedContext`).
- **Room for the reply**: a quarter of the context instead of 4,096 tokens, which would leave nothing for the Transcript.

Its Markdown repeats nested list markers (`- - text`); the transport fixes them before the reply reaches the Summarizer. Guardrails are `.permissiveContentTransformations`: meetings talk about anything, and the default refuses too much.

Measured on a real 53-minute Italian Meeting on macOS 27: 3 partial summaries and a merge, 185 seconds, no context errors. The titles were good (about one second each). The Summary was clearly poorer than with a large model: fewer facts, repetitions, some points unclear. It is offered as the free, private option, said to be less precise, never as the default.

## Consequences

- On macOS 15, or without Apple Intelligence turned on, the Profile is not offered, and an existing one fails with a message that says why.
- The title without a Summary is written only when Apple Intelligence is available; otherwise the note keeps its provisional name, as before.
