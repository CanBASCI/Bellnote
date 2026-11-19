# Bellnote - Information for App Review

This page goes with the notes in App Store Connect. It explains how to test Bellnote, why it needs large downloads, and what each permission and entitlement is for.

## Summary

Bellnote is a study app. A student records a class they are allowed to record. The app turns the recording into a transcript, a summary, notes and homework, each linked to the minute it was said. All of it runs on the device. There is no account, no sign-in, no server and no analytics.

## Please test on the right device

- **A real iPhone on iOS 27**, with **8 GB of memory or more**, about **10 GB of free storage** and **Wi-Fi**.
- **Please do not test on the Simulator.** The on-device AI uses the device GPU and Neural Engine.
- **Please do not test on an iPhone with less than 8 GB of memory.** There the larger text model is switched off by the app (it says why), the smaller model runs slower and less thoroughly, and the result does not show the app as designed.

## Why the downloads are large

The AI models are not inside the app. If they were, the install would be several gigabytes. Instead the student downloads them once, on purpose, from the Models page in Settings.

| Model | Role | Size |
|---|---|---|
| Qwen 3.5 2B, 4-bit | Text model for notes, summaries, quizzes and the assistant | about 1.6 GB |
| Qwen 3.5 4B, 4-bit (optional) | The same jobs, more accurate. Needs 8 GB of memory and 4 GB of free space | about 3.1 GB |
| Whisper large-v3 turbo (Core ML) | Speech to text for recordings | about 0.65 GB |
| FluidAudio | Speaker separation | about 0.16 GB |
| Supertonic | Voice for read aloud and Talk | about 0.15 GB |

With the 2B model the total is about **2.6 GB**. With the 4B model as well it is about 5.7 GB. Allow 5 to 10 minutes on Wi-Fi.

**What gets downloaded.** Model weights (data), from public Hugging Face repositories. No executable code is downloaded. Nothing downloads unless the student taps Download. The app never sends any information about the user in these requests. See the [privacy policy](privacy).

**Why other tabs are disabled at first.** Until the required models are installed, only Settings is open, on the Models page. This is deliberate: without the models the other tabs have nothing they can do. They turn on by themselves when the last download finishes. A note at the top of the page names what is missing, and tapping a line scrolls to that row.

**First-time preparation.** After the Whisper download the row says Preparing. Core ML builds the model for the chip, which can take up to about four minutes the first time. It happens once. Please keep the app open and do not force-quit.

**Offline.** After the downloads, everything works in airplane mode.

## Step-by-step test (about 5 minutes after the downloads)

1. Open the app. A short walkthrough appears the first time. Tap Skip or go through it.
2. Face ID unlocks the app (optional lock, can be turned off in Settings).
3. Settings opens on **Models**. Tap **Download** on each row: a text model (2B is enough), Whisper, FluidAudio and Supertonic. Wait for **Preparing** to finish.
4. The other tabs turn on. On Home, create a **term** and then a **course** (any name).
5. Open the course and tap **record**. The app asks you to tick two boxes: you are allowed to record this class, and the lecturer or school permitted it. Tick both and allow the microphone. Speak for 30 to 60 seconds. As an alternative, tap **Load recording** and pick an audio file already on the phone. Tap **Stop**.
6. Open the lecture and tap **Process**. Keep the app open. The card shows the stage: audio, speakers, transcript, tags, page. A short clip takes a few minutes. When it is ready you get **Summary**, **Notes** and **Raw** tabs. Tap a timestamp to hear that minute.
7. **Files** tab: add a PDF to the course. **Quiz** tab: pick the course, tap **Prepare**, answer the questions, then tap **Review wrong answers** and **Source** to open the PDF at the right page.
8. **Assistant** tab: ask a question about the course by text or voice. Answers cite the stored note and minute.

## Permissions and capabilities

| Item | Why |
|---|---|
| Microphone | Recording a class. Asked on the first recording |
| Camera | A board photo during a recording, or reading a schedule the student frames. Asked on first use |
| Face ID / passcode | Optional lock for notes, on by default, can be turned off in Settings |
| Speech Recognition | On-device dictation for questions to the assistant |
| Notifications | Optional reminders before class, and a note that a recording is ready. No note text is in a notification |
| Background audio (`audio`) | A recording continues when the screen locks or the student switches apps, so a class is not lost |
| Live Activity | Shows the recording on the Lock Screen and in the Dynamic Island with pause, resume and stop. It makes the recording visible |
| Increased Memory Limit (`com.apple.developer.kernel.increased-memory-limit`) | Loading the on-device language model needs more memory than the default limit |

Each permission is asked at the moment of use. A denial turns off only that feature.

## Recording and consent

Recording never starts from the timetable or by itself. It starts only when the student taps record **and** confirms two statements: I am allowed to record this class, and the lecturer or school permitted recording. There is no "don't ask again". The confirmation is stored with the recording and shown in its details. A recording indicator is visible the whole time. Bellnote is for personal study notes and has no sharing of recordings.

## Privacy

- App Privacy answer: **Data Not Collected**.
- No tracking and no advertising identifier. No analytics or advertising SDK.
- Audio, transcripts, notes, speaker prints and quiz answers stay on the device.
- The only network use is the model download, started by the student.
- Third-party code in the app: MLX Swift (text models), WhisperKit (speech to text), FluidAudio (speaker separation) and sherpa-onnx (voice). All run on the device. The Hugging Face Swift packages are used only to download the model files you ask for.

See the full [privacy policy](privacy).

## Also useful to know

- The app is in English and Turkish.
- iPhone only, portrait.
- If a download is interrupted it resumes. A Stop control on the row cancels it.
- If a recording is still being processed when the student leaves, the app asks first and resumes from the last finished stage later.

## Contact

Open an issue at [github.com/CanBASCI/Bellnote/issues](https://github.com/CanBASCI/Bellnote/issues), or use the contact details in App Store Connect.
