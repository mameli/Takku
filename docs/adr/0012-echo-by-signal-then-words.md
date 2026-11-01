# Echo is removed by the signal first and the words second; Silero drops sentences without speech

With the call on the speakers the microphone hears the others, and the recognizer writes their words as mine. Up to 1.13.0 a run of Me Utterances was echo when 80% of its words appeared, in order, in the Others Track at the same moment. It missed echo the recognizer spelled differently (the microphone hears it degraded) and threw away what I said right after or over the others, when it fell in the same run.

The echo removal now looks at the audio first, as [Hex](https://github.com/anomalyco/hex) does (MIT, `src/meeting/echo.rs`, ported in `EchoSignal`): the level of both Tracks every 20 ms, the lag and the correlation of the microphone behind the system audio, the bleed it explains. A run the delayed Others Track explains is echo whatever its words; a run well above that prediction is mine and stays, even with matching words. When the signal cannot tell, the word rule decides as before, with words of 4+ letters that are 60% the same counting as one. With headphones the correlation stays low and every sound is mine. Hex measured on a real call with laptop speakers: echo-like Me lines from 49 of 77 to 1 of 10, none of the 6 real ones lost. Takku's numbers are still to be measured on its Recordings.

Sentences the recognizer makes up on noise (a click, a cough) passed the level-based speech ranges and the stock-sentence list. Silero, through FluidAudio's `VadManager`, now gives a speech probability every 256 ms of each Segment; an Utterance with no 256 ms above 0.4 within half a second of it is dropped. Hex measured on an Italian call: 1 of 152 made-up lines kept, 32 of 33 real ones kept.

Both are measured once per Segment and kept in its transcription cache (`SegmentSignal`), so a Reprocess does not decode the audio again, and an older Recording is measured on its first Reprocess.

Rejected: echo cancellation (Voice Processing IO), dropped in 1.6.0 because it took over the microphone of the call app ([#3](https://github.com/mameli/Takku/issues/3)); running Silero before the recognizer, which would save time but leave every existing cache stale.

## Consequences

- Without levels for every Segment with Utterances (an unreadable file), the echo removal falls back to the words alone: a Track missing where it has speech would look silent and the signal would judge wrong.
- Without the speech detector (offline at the first use) every Utterance is kept, and the Segment is measured again at the next Processing.
- Silero also hears the others' voice in the microphone: it does not help against echo, only against noise.
