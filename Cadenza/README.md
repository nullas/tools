# Cadenza: a piano practice app for iOS

Cadenza is an original SwiftUI app built around the practice loop that apps like flowkey made
popular. You pick a song, watch the music scroll past a playhead, and play along on a real
piano. The app listens and waits for you. It shares no code, artwork, songs or branding with
any existing product. All bundled music is in the public domain.

## Features

| | |
|---|---|
| **Song library** | Nine public-domain pieces from *Mary Had a Little Lamb* to Bach's *Prelude in C*, with level filters and search. |
| **Courses** | Three courses (First Steps, Reading Notes, Chords) with short lessons. Each lesson has an exercise. |
| **Scrolling sheet music** | A grand staff drawn live: clefs, time signature, ledger lines, accidentals, stems, flags, dots and bar numbers. You can drag it to scrub while paused. |
| **Falling notes** | Switch to a falling-notes view whose notes line up with the keys below. |
| **Wait mode** | The music stops at each note or chord until you play it. Turn it off to play at tempo, with timing windows. |
| **Hands** | Practise the left hand, the right hand, or both. The app can play the other hand for you. |
| **Speed & loops** | Play at 25–125% speed. Loop any range of bars. |
| **Three ways to play** | **Microphone** for an acoustic piano, **MIDI** for USB or Bluetooth LE keyboards (with Apple's pairing screen), or the **on-screen keyboard** (multi-touch, glissando). |
| **Built-in piano sound** | An additive synthesizer with inharmonic partials and pitch-dependent decay. No sample files needed. |
| **Feedback** | Keys and notes light up in hand colours, turn green when hit and red when missed. You get stars, accuracy and a mistake count at the end. |
| **Progress** | Daily goal ring, streak, weekly practice chart, best score per song. Lessons are ticked off as you complete them. |
| **Extras** | Metronome, note-name labels, a Listen mode that plays the song for you. |

## Building

You need Xcode 15 or newer (iOS 17 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd Cadenza
xcodegen            # creates Cadenza.xcodeproj and Cadenza/Info.plist
open Cadenza.xcodeproj
```

Select your development team under *Signing & Capabilities*, then run on a device.
The simulator works with the on-screen keyboard and MIDI, but you need a real device to hear a piano
through the microphone.

## Project layout

```
Cadenza/
├── App/CadenzaApp.swift          entry point; injects Library, ProgressStore, InputManager
├── Models/
│   ├── MusicTheory.swift         pitch parsing, names, staff positions
│   ├── Song.swift                Song / NoteEvent, bar maths, text-notation parser
│   ├── Library.swift             loads songs.json and courses.json
│   └── ProgressStore.swift       scores, streaks, practice minutes (UserDefaults)
├── Practice/
│   ├── PracticeSession.swift     the engine: clock, wait mode, scoring, loops, accompaniment
│   └── NoteReceiver.swift        input protocol
├── Audio/
│   ├── PianoSynth.swift          real-time synthesizer (AVAudioSourceNode)
│   ├── MicNoteDetector.swift     FFT note detection that knows which notes to expect
│   ├── MIDIInput.swift           CoreMIDI (Universal MIDI Packets)
│   └── InputManager.swift        routes touch / MIDI / mic notes to the session
├── Views/
│   ├── Library/…                 Home, Songs, Song detail, Courses, Lessons, Profile, Settings
│   └── Player/…                  PlayerView, sheet music & falling notes canvases, keyboard
└── Resources/songs.json, courses.json
```

### How listening works

Picking out arbitrary chords from microphone audio is hard. A practice app, though, always
knows which notes it is waiting for. `PracticeSession` publishes those notes, and
`MicNoteDetector` only checks whether each one has just been struck:

1. It takes a 4096-point Hann-windowed FFT every 1024 samples.
2. For each candidate note it sums the weighted spectral peaks at its first five harmonics.
3. It accepts the note if:
   - that sum is well above the median noise floor,
   - it is louder than the neighbouring semitones,
   - and it is rising compared with the previous frame, so a string that is still ringing does not count again.

If the app hears notes you did not play, raise `presenceRatio` in `MicNoteDetector`. Use headphones if
the app's own accompaniment triggers detection.

## Adding songs

Songs are written in a compact text notation in `Cadenza/Resources/songs.json`:

```json
{
  "id": "ode-to-joy", "title": "Ode to Joy", "composer": "Ludwig van Beethoven",
  "level": "easy", "tempo": 100, "beatsPerBar": 4, "key": "C major",
  "right": "E4:1 E4 F4 G4 | G4 F4 E4 D4 | … | D4:1.5 C4:0.5 C4:2",
  "left":  "C3:4 | G2:4 | …"
}
```

- Separate tokens with spaces.
- `:n` sets a length in beats, and it carries over to the next notes until you change it.
- `+` makes a chord, e.g. `C4+E4+G4:2`.
- `r` is a rest.
- `|` bar lines are optional, but the validator uses them.
- Optional fields: `beatUnit` (8 for x/8 time), `pickup` (beats in the opening partial bar).

Check bar lengths before committing:

```sh
node Scripts/validate_songs.mjs
```

## Tests

`CadenzaTests` covers the notation parser, bar maths, content loading, the practice engine
(wait mode, chords, free-tempo scoring, hand selection, loops) and progress persistence.
In Xcode, press ⌘U.
