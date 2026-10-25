# FluidAudio vs Who

A comparison of Takku's diarizer, FluidAudio's offline pipeline (pyannote community-1, [ADR 0006](adr/0006-speakers-by-local-diarization.md)), with Desert Ant's [Who](https://desertant.com/models/who/), on the Others Track of real Recordings. Both diarized the same Track, joined as Takku joins it, and their turns were given to the Transcript's utterances with `assigningSpeakers`, as Takku does. The utterances on which the two disagree were judged by ear; where they agree, neither was checked.

## 2026-10-25: FluidAudio 0.17.7, Who 4.1.0 (fp16, model v0.3.1)

Two work Meetings (the copies of `scripts/retry-e2e`), M3 Pro with 18 GB, Parakeet v3 utterances.

| Recording | Speakers in the Transcript F / W | Run F / W | Peak memory F / W | Agreement (words) | Apart | Votes F / W / neither / unvoted |
|---|---|---|---|---|---|---|
| 54 min | 4 / 6 | 11.2 / 5.1 s | 882 / 493 MB | 98.0% | 29 | 1 / 17 / 9 / 2 |
| 24 min | 3 / 2 | 4.1 / 2.2 s | 763 / 376 MB | 98.0% | 7 | 3 / 1 / 3 / 0 |
| **Total** | | | | | **36** | **4 / 18 / 12 / 2** |

- FluidAudio split one voice in two in the 54-minute Meeting: a Speaker 3 whose lines were Speaker 1's. Who kept them together.
- Who told apart a voice that speaks rarely (the moderator of the Q&A), which FluidAudio shared between two Speakers.
- Who left more short lines as *Others*: three in the 24-minute Meeting that FluidAudio had right.
- Goodbyes with several people talking at once: neither is right.
- Who's first load took 105 s (download and Core ML compile), then under 0.3 s.

## Decision: Takku stays on FluidAudio

Takku is meant to be entirely free, and Who is not. Its license is source-available: free under 100,000 monthly active devices per platform, with attribution in the app, and a commercial license above. The SDK also asks Desert Ant's server for a license every month (a random install id, the bundle id and the model, no audio). The quality gain does not outweigh that: the two disagree on 2% of the words, and Who was better on that 2% across two Meetings and one listener. Takku waits for FluidAudio to improve instead of changing diarizer.

Also against Who: 81 MB more to download, still in beta, at most four voices per five-minute window.
