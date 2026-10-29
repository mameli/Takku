# Speakers are told apart by local diarization of the Others Track, and named only by the Summary

The others in a call were all "Others" in the Transcript, so the Summary could not say who said or will do what. Takku now diarizes the Others Track on the Mac through FluidAudio, already a dependency for Parakeet: first with its offline pipeline (pyannote community-1), since 1.11.0 with NVIDIA's Nemotron 3 Diarization (see below), and writes *Speaker 1*, *Speaker 2*… in the Transcript. The Me Track needs no diarization: it is one person, and keeping it separate makes the Others Track the easy case (fewer voices, no overlap with the user). On five real Recordings (13 to 41 minutes, 3 to 7 voices) it took 3 to 8 seconds, and with two or three clear voices the turns matched the conversation; with many people talking over each other more replies are mixed or left as *Others*.

Takku does not attach names to voices by itself. The Summary model takes a Speaker's name from what is said (the name they introduce themselves with, or answer to when called) and never writes "Speaker N": for a Speaker without a name it leaves out who, with no placeholder. The Transcript keeps the numbers.

Rejected for now:

- **Reading the active speaker from Teams** through the Accessibility API, as Granola does: works only with the Teams desktop app, breaks when its interface changes, and needs another permission. It can be added later to name the Speakers by majority vote, on top of diarization.
- **Microsoft Graph transcripts**: need the organiser to turn on Teams transcription and the tenant admin's consent, and the transcription is then Microsoft's, not local.
- **Desert Ant's Who** in place of FluidAudio: on two Meetings it agreed on 98% of the words and was right more often on the rest, but its license is not free and Takku is meant to be. [The comparison](../who-vs-fluidaudio.md).

Changed in 1.11.0: **Nemotron 3 Diarization** replaces pyannote community-1. It is free (OpenMDW 1.1), runs in the FluidAudio Takku already had, and on the same two Meetings it made neither mistake Who had found (a voice split in two, a voice that speaks rarely shared between two Speakers), and gave a voice to short replies community-1 left as *Others*. It costs 190 MB instead of 22 and allows at most 8 voices per Meeting. [The comparison](../who-vs-fluidaudio.md).

Changed later: **voice recognition**, rejected at first, is now offered, off by default. Voice embeddings are biometric data under the GDPR, and keeping colleagues' embeddings needs their consent. So the user turns it on in Settings after a warning, the embeddings stay in one file on the Mac (`voices.json`, readable by the user only, never in the Vault or in `~/.takku`, which may be synced), and each name can be forgotten. It only suggests a name in *Name speakers…*, shown as recognised by voice, and the user confirms it by saving: a wrong name in a note is worse than none. The embedding comes from the samples the window already plays, with WeSpeaker through FluidAudio (the 22 MB models of the old pipeline, kept for this). Diarization is not touched: Nemotron gives no embeddings, and computing them while naming needs neither a new cache nor a Retry.

## Consequences

- A Speaker number holds within one Meeting only: *Speaker 2* in two Meetings can be two different people. Only voice recognition, when on, links them, and only as a suggestion.
- Voices are recognised only while the audio of a Meeting is kept.
- An Utterance takes one Speaker even when two voices share it (recognition joins them into one sentence); splitting by word times is left for when it shows up as a problem.
- The turns are cached per Recording, keyed by the Others Segments and a diarizer version, bumped to 2 for Nemotron: a Retry diarizes again only after a change.
