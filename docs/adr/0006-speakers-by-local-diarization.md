# Speakers are told apart by local diarization of the Others Track, and named only by the Summary

The others in a call were all "Others" in the Transcript, so the Summary could not say who said or will do what. Takku now diarizes the Others Track on the Mac with FluidAudio's offline pipeline (pyannote community-1), already a dependency for Parakeet, and writes *Speaker 1*, *Speaker 2*… in the Transcript. The Me Track needs no diarization: it is one person, and keeping it separate makes the Others Track the easy case (fewer voices, no overlap with the user). On five real Recordings (13 to 41 minutes, 3 to 7 voices) it took 3 to 8 seconds, and with two or three clear voices the turns matched the conversation; with many people talking over each other more replies are mixed or left as *Others*.

Names are not attached to voices by Takku. The Summary model takes a Speaker's name from what is said (the name they introduce themselves with, or answer to when called) and never writes "Speaker N": for a Speaker without a name it leaves out who, with no placeholder. The Transcript keeps the numbers.

Rejected for now:

- **Voice enrollment** (saving colleagues' voice embeddings to recognise them in later Meetings): voice embeddings are biometric data under the GDPR, and recording them for colleagues needs their consent.
- **Reading the active speaker from Teams** through the Accessibility API, as Granola does: works only with the Teams desktop app, breaks when its interface changes, and needs another permission. It can be added later to name the Speakers by majority vote, on top of diarization.
- **Microsoft Graph transcripts**: need the organiser to turn on Teams transcription and the tenant admin's consent, and the transcription is then Microsoft's, not local.
- **Desert Ant's Who** in place of FluidAudio: on two Meetings it agreed on 98% of the words and was right more often on the rest, but its license is not free and Takku is meant to be. [The comparison](../who-vs-fluidaudio.md).

## Consequences

- A Speaker number holds within one Meeting only: *Speaker 2* in two Meetings can be two different people.
- An Utterance takes one Speaker even when two voices share it (recognition joins them into one sentence); splitting by word times is left for when it shows up as a problem.
- Diarization is not cached: Retry runs it again, a few seconds.
