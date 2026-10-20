# Bellnote — agent implementation spec

Version: 1.0 · 2026-10-09
Product name: Bellnote. Not translated in the UI. It is the brand: the class bell rings, the note remains.
Minimum: iOS 27.0. Any iPhone that runs iOS 27. Do not name a specific device in code, copy, or requirements.
Language of this spec: English, so a coding agent can implement it without translating comments.
UI copy: localized. Never hardcode Turkish or English strings in Swift.
Code, comments, identifiers, commits, and logs: English only. This is a hard rule. Git commits and pushes use the student's GitHub user as both author and committer. Do not set Cursor, the agent, or any tool as author, committer, or co-author. No `Co-authored-by` trailer.

## 0b. How the code is written

Write as a careful senior iOS engineer. A strong reviewer should be able to read a module without a tour.

- Swift 6 language mode, toolchain the one that ships with the iOS 27 SDK. Strict concurrency. UI work on the main actor. Capture, transcription, and model calls in actors. No shared mutable state across those boundaries.
- No force unwrap, no force try, no silently swallowed error. A failure sets the lecture stage and a localized message.
- Small types. A module does one job from section 9. Do not grow a god view model.
- Comments explain a constraint, not the next line. No commented-out code. No natural language other than English in comments.
- Strings only from the catalog. Previews use the English catalog.
- Side effects at the edges: files, microphone, notifications, model downloads. The linker and the gap rules are pure and tested without a device.
- Tests use Swift Testing (`@Test`, `#expect`) on the iOS 27 SDK. Cover bind, due-date math, missed versus cancelled, exam-row sorting, and the model-row lock. These run without a device. XCTest is only for an existing UI test if one is added. A UI test is not a substitute for these.
- Do not add a package, a pattern, or an abstraction the spec does not need. Prefer the system control over a custom one.

Out of scope for v1: journal, mood, songs, people graph, cloud, accounts, analytics, model training, hidden exam-room playback, iOS 26 fallback, meetings. A later release may add a meeting kind beside the course. Do not build it now. Do not add meeting screens, meeting copy, or a second pipeline. The course, lecture, and block types should not hardcode “student” into the storage layer, so a meeting can reuse them later. This spec remains the source of truth until it is revised.

## 0. What the agent must produce

A SwiftUI app a student installs, downloads two local models once, creates any course, optionally enters a weekly timetable, and starts a recording for that course. After stop, the phone turns the audio into timestamped notes that read like a careful handwritten set, only stricter: lists stay lists, emphasis is marked, assignments and back-references link to earlier lectures in the same course. The student can ask out loud, hear the answer from those notes, jump back to the minute, and say “quiz me on these topics” or “quiz me on notes between these dates.” Spoken answers are judged against the notes. A partial answer is completed from the note, not from outside knowledge.

The agent implements this from an empty Xcode project. Do not invent a journal mode. Do not special-case any subject. Do not call Private Cloud Compute. Do not fine-tune. Do not mention a specific iPhone model.

## 1. Product rules

1. One vault: courses. A course is a name the student types (Statistics, Organic Chemistry, Civil Procedure). No special case for any subject.
2. Audio, transcript, notes, speaker prints, quiz answers stay on device. No account, no upload, no analytics SDK.
3. Models are not in the IPA. After install the student downloads them once. Lectures work in airplane mode after that.
4. Weights never change. “Learning” is new SwiftData rows.
5. The model emits tags and prose. Linking is Swift. If a fact is not in a stored block, it is not written.
6. Classroom chatter stays in the audio file and out of the note body.
7. Recording cannot start until the student attests they have permission. A recording indicator is always visible.
8. Spoken study playback is for the student at home. No stealth exam mode.
9. Code, identifiers, comments, commit messages, and log messages are English. User-facing strings live in a string catalog.
10. Visual design is native iOS 27 Liquid Glass. Use system buttons, toolbars, tab bars, sheets, lists, and materials. Do not draw a custom control, a custom blur, or a second visual language where a system control exists.

## 1b. Liquid Glass

Use the iOS 27 system chrome. Toolbars, tab bars, and bottom actions pick up Liquid Glass from the system. Do not restyle them with custom blurs.

- Primary actions are `Button` with a system role, placed in a `ToolbarItem` or a safe-area bar. Record, pause, resume, and stop are system buttons, not drawn circles.
- Course list and note list use `List` and `NavigationStack`. Inset grouped style. Swipe actions are system swipe actions.
- Recording state is a system indicator plus a localized status string. Do not invent a branded recorder skin.
- Sheets for consent, lecturer confirmation, and exam date use `.presentationDetents` and the system grabber.
- Emphasis is a system tint and a symbol (`exclamationmark`), not a custom badge bitmap.
- Layout uses the system safe area and Dynamic Type. Do not hardcode a screen width, a device size, or a point width for a control. The same screens must fit the smallest and largest iPhone that runs iOS 27, in portrait. Landscape is not a v1 layout.

## 1c. Shape of the screens

Three content levels, no more. Term home, one course, one lecture. Settings, model download, exams, the pending list, and the timetable are sheets or segments on those levels, not a fourth vault. A back button returns one level. There is no dashboard of charts.

A course opens on its lectures, newest first. Under the title, one line: open assignments, and the exam date if set. That line is the only summary. Tapping it opens the assignment table. Columns are task, due, done. Done is a switch. No cards inside cards.

Record is the single primary button on the course. Ask and quiz are the same microphone control, with a segmented choice: Ask, Quiz. Filters are a second sheet, not a toolbar of chips. Default filter is the whole course. The student adds a topic or a date only if they want one.

A lecture opens on the note. Summary and raw are segments, not separate destinations. Emphasis is a short section at the top of the note, not a third product. A timestamp is a text button. Tapping plays. Assignments mentioned in the lecture are rows that deep-link to the course table.

Voice answers are a sheet over the course: the spoken text, then the source rows. Dismiss returns to the same lecture list. Nothing in this flow uses a custom illustration, a gradient hero, or a second navigation scheme.

## 1d. Timetable and reminders

The timetable belongs to the term, one table. A slot is weekday, start, end, course, and place. The course page shows only its own slots. Do not keep a second timetable. The student can type rows, or photograph a printed or on-screen schedule. The photo stays on device. Vision reads the text on device. The app proposes slots. Nothing is saved until the student confirms the table. A misread row is edited or deleted. The photo can be kept on the term or discarded. It is never uploaded.

Tapping a slot offers three choices, remembered per slot:

- None.
- Notification, a chosen number of minutes before start.
- Alert with sound, the same lead time. This is a local notification with sound, delivered by the app. It is not a silent write into the system Clock app. If the student wants a Clock alarm, the app opens Clock with the time filled only where the system allows. It does not pretend to have set one.

The notification title is the course name and the start time, from the catalog plus the slot. Tapping it opens that course. It does not start the microphone. Permission for notifications is asked the first time they choose notification or alert, not at first launch. Denied permission leaves the slot on None and says why. No account, no remote push. All of this is local.

## 1e. Year and term

A timetable belongs to a term, not to the whole degree. The student creates a term: year of study, term, and the calendar dates that term runs. Labels are localized, the stored values are numbers. First year, first term. First year, second term. Second year, first term. A term can also be named, if the school does not use that numbering.

Courses, weekly slots, the photographed schedule, and exam dates live in the open term. Switching term switches the home list. Past terms stay. Their notes stay. A Monday 09:00 slot in last year’s first term does not notify this year.

The photo flow is per term. One photo, typed rows, or a PDF fills that term’s table. A PDF is copied in by the document picker and read on device with PDFKit. A scanned page uses Vision. The app proposes slots. Nothing is saved until the student confirms the table. A misread row is edited or deleted. The photo or PDF can be kept on the term or discarded. It is never uploaded. The student can edit a week if a slot changes, or change the slot for the rest of the term. A time change updates later reminders. It does not move lectures already recorded. The default week is the current week inside the term dates.

Below the timetable, one chart section, collapsed until opened. A bar per course for weekly hours, from the slots. A second line for the term total, weeks in the term times those weekly hours. No yearly chart. No grade chart. A cancelled week the student marked is subtracted. A missed week is not subtracted, because the slot still existed. The chart is Swift Charts, system style, and reads the same numbers as text for VoiceOver. It does not score the student.

Exam dates are fields on the course inside the term: midterm, final, and any other the student adds. They are often known only a week ahead, so the field starts empty. When the student sets a midterm, the same slot choice appears: none, notification, sound, and how many days before. A reminder opens that course. It does not start the microphone. It does not invent an exam date from the photo unless the photo actually shows one and the student confirms it.

## 1f. Exams tab

The term has a segment: Courses, Exams. Exams is a list, not a new vault. Each row is one sitting: course, kind (midterm, final, other), date, start time, optional end time, place if the student typed it. Empty until the student, or a confirmed photo, fills it. Sorted by date. A sitting with no time yet shows the date and “time not set.”

The row and the course are the same record. Editing the date on the course edits the tab. Editing it on the tab edits the course. Deleting a course deletes its sittings. A sitting never points at another term. After the result is announced, the student can type a score on that sitting. The field starts empty. The app does not infer it. It is not a GPA and it is not charted. Voice can read it only when asked for that exam.

Tapping a row opens that course already filtered to the exam: emphasis, exam-scope topics, open assignments due before the sitting, and notes up to the day before the exam. The microphone still does not start. “Quiz me for this exam” uses that filter. Topics the lecturer never named are not added.

Reminders hang off the sitting, not off a floating calendar event. The student picks none, notification, or sound, and how long before. The text is course, kind, date, and time. Several sittings on one day appear as separate rows, in time order. Overlaps are shown, not resolved. The app does not guess which exam matters more.

## 1g. Missed lectures, lock, board photo

A slot has a place: in person, online, or remote. The student sets it. It can change for one week. Online is a live class from elsewhere. Remote is distance teaching, not a live meeting. Neither replaces the gap marks. A slot with no lecture that day is a gap, not a note. The course list shows the date and “no recording.” It does not invent notes. The student marks the gap as missed or cancelled. Missed stays visible as missed. Cancelled stays visible as cancelled and does not count as a missed class. Neither creates notes. The mark can be changed later. An online class can be recorded, missed, or cancelled like any other. The app does not join the online meeting.

## 1h. Course page

The course page is the second level. It holds the lecturer, the inventory, attendance, and the lecture list. Nothing here is required except the course name.

Lecturer fields are optional, each its own row, typed by the student: title, given name, family name, phone, email, and one extra contact row if they shared something else. Empty rows are hidden. The app does not look them up.

Inventory is filled from lecture blocks, not from a catalog. A spoken book, chapter, or required tool becomes a row: title as spoken, kind (book, chapter, other), source minute, and whether it was also an assignment. “We will use this book in the course” is inventory. “Read chapter 4 by next week” is inventory and an assignment. A title that was not spoken is not added. The student can edit a misheard title. The row links back to the minute.

Files the lecturer sent, by mail or chat, are added by the student to that course. The system share sheet or document picker copies the file into the course folder. The app does not read WhatsApp or Mail by itself. The copy is the one the course opens. Kinds include PDF, slide, image, and other. A file can be tied to an inventory row, an assignment, or a lecture minute. Removing it removes the copy in the app, not the original in Files. Nothing is uploaded. Voice can list them: “what files are on this course.”

A PDF the student added can be asked about. Text is extracted on device with PDFKit. A scanned page is read with Vision, on device. The picked text model answers only from that text, and cites the page. If the page has no text, it says so. It does not mix in lecture notes unless the student asks “from the notes and this file.” The file is not uploaded. Quiz filters can include one chosen file, still without facts from outside it.

“Summarize this file” and “where does this topic sit” never send the whole PDF to the model. Extract text per page on device. Rank pages by topic overlap with the question or the lecture block. Read only the top pages, cite those page numbers, and say when no page matches. The student can confirm a pair, and that pair is reused. Nearby pages are not attached.

The morning view of a course is this page, not a dashboard. Under the title: next slot or next exam, open assignments, and one attendance line — recorded, missed, cancelled, no recording yet. That line can open a simple bar for the term. It does not score the student. Lecturer fields and inventory sit below the lecture list, collapsed until opened. Voice can read them: “what books were named”, “what did the lecturer ask for”, “how many sessions have no recording.” Answers come from these rows.

A slide deck is a file, same rules as a PDF. A photo of an exam paper attaches to that sitting, not to the note body. If the student says a question appeared there, that topic is preferred in the next drill. The answer key remains the lecture block. A sentence the student writes under a block is marked as theirs and is never the key. The term home can show three lines before a course is opened: next exam, open assignments, slots with no recording. No chart wall. If a file is removed, its page links are removed with it.

The app locks with Face ID, or the device passcode if Face ID is off. The lock is on by default. Notes, audio, and the timetable are behind it. The lock screen of the phone still shows a recording indicator while capture is running. Notifications show the course name and time, not the note text.

A board photo is taken by the student, during the recording, from a system camera button next to pause. It does not replace the audio. The shutter stores one image and the recorded second, so it sits on that minute of the note. They can take several. After the lecture they can also add a photo to an existing minute. The image stays on device. If they ask, Vision reads it on device into the missing row. If it cannot read it, the row stays missing and the photo remains. The camera is never opened by the timetable photo flow. That flow only reads a schedule the student already framed.

## 2. Stack, current as of October 2026

- Xcode with the iOS 27 SDK. Deployment target iOS 27.0. Swift 6 language mode, toolchain the one that ships with that SDK. SwiftUI. SwiftData.
- Speech: `SpeechAnalyzer` + `SpeechTranscriber`, assets via `AssetInventory`. Long-form, on-device, no one-minute cap. Locale from the course, defaulting to the app language.
- Speaker clusters: FluidAudio (Core ML, on-device diarization). Pin the package version in the project.
- Text models: `mlx-swift-lm` / `MLXFoundationModels`. Requires the iOS 27 SDK. `MLXLanguageModel` conforms to `FoundationModels.LanguageModel` and is passed to `LanguageModelSession`. Guided output via `@Generable`.
- Do not enable Private Cloud Compute or third-party tools on any session.
- Do not use AFM 3 Core Advanced. It needs more memory than an 8 GB phone has. Skip it rather than gating the app to a named device.
- Text model: Qwen 3.5 2B or Qwen 3.5 4B, 4-bit. The student downloads one or both and picks one in Settings. That one model does every text job: window tags, AI correction, page, summary, quiz, spoken script, and Ask. If the picked model is not installed but the other one is, use the installed one. If neither is installed, tell the student and do not download. Do not use `SystemLanguageModel` for tags. Apple Speech is the transcript only. Thinking off.
- Optional transcript: Whisper large-v3 turbo through WhisperKit, on device. Chosen by the student in Settings, only after the student downloads it. It reads the whole recording and each word goes to the speaker whose FluidAudio run covers it. Not downloaded up front.
- TTS: `AVSpeechSynthesizer` with the course locale. No extra TTS model in v1.
- Speech in: course-locale dictation through `SpeechAnalyzer`, on device, for questions and quiz answers.
- Processing stays in the foreground. A background task may be asked, but do not promise it finishes. If the system suspends it, persist the last finished stage and resume on next open. A ready notification is sent only after the page is saved.
- Memory: only the picked text model is loaded. Never keep both resident. If a device cannot load 4B, the student can still use 2B for every job and the localized model screen says so. Do not name the device.

Default downloads, not bundled:

- `mlx-community/Qwen3.5-2B-MLX-4bit` (~1.5 GB). Any text job. Smaller and faster.
- `mlx-community/Qwen3.5-4B-MLX-4bit` (~2.9 GB). Any text job. Larger and more accurate.
- Qwen 3.5 9B was tried on an 8 GB phone and does not fit. The weights alone are 5.6 GB, and the system closed the app while they loaded. Do not offer it.
- `argmaxinc/whisperkit-coreml`, folder `openai_whisper-large-v3-v20240930_turbo_632MB`, with the tokenizer files of `openai/whisper-large-v3` (~0.65 GB in all). Only when the student taps Download. Core ML prepares it for the chip right after the download, because that takes minutes the first time.

The app downloads these from the public Hugging Face `mlx-community` repos. No student account, no developer token, no signup screen. The student never sees the URL. The model screen groups the rows: AI models (2B, 4B), speech to text (Whisper), audio (FluidAudio, Supertonic). Each row shows the parameter size, the file size, and the job. Partial downloads resume. Deleting a model does not delete notes. SpeechAnalyzer assets come from `AssetInventory`, not from Hugging Face.

Before download, read physical memory and free disk. Do not name the device. Lock 2B if free space is under 2 GB. Lock 4B if free space is under 4 GB, or if physical memory is under 8 GB, and say why. On 8 GB and above, both rows are available. The Settings model picker lists only installed text models and drives every text job. After install, run a short timed sample and show the measured page speed. If that sample is too slow, leave 4B installed but default the picker to 2B.

Never keep both loaded. If the student changes the picked model, unload the old one before loading the new one.

## 3. Localization

- String Catalog `Localizable.xcstrings`. Base development language English. First translation Turkish. On first launch, follow the system language. If it is neither, use English. Settings can switch the app language between English and Turkish without following the system. A third language is a catalog edit, not a code edit.
- Course content language is independent of UI language. A Turkish lecture in an English UI stays Turkish. An English lecture stays English in the stored note. If the student asks for an explanation in Turkish, or asks a Turkish question about that course, the answer is Turkish and every claim cites the English block and minute. The stored note is not replaced by the translation. A quiz answer in Turkish is scored against that block. If the match is uncertain, the English sentence is read back. Do not invent a Turkish wording the lecturer did not say.
- No Turkish (or any natural language) in comments, type names, or logs.
- Format dates and numbers with `FormatStyle` and the app locale.
- VoiceOver labels come from the same catalog.

## 4. Student flow

1. Create a course: name, optional lecturer label, locale, optional weekly slots (weekday + start + end).
2. Home shows courses. A slot that is active now is pinned with the course name. Tapping it opens that course, it does not start the microphone. If the student taps record while a slot is current, or within five minutes before it, ask “Start this recording for {course}?” Confirm uses that course. Exam starts the recording as an oral exam for that course and opens a sitting of kind other, titled by the student, defaulting to oral exam. If the exam is only the opening minutes and the class continues, the student sets two handles on the recording, start minute and end minute. That span becomes the sitting. The remainder stays a lecture. They can also stop at the end of the exam and start a second recording for the class. Other opens the course picker. New name creates a lecture under a name they type, in the open term. If two slots overlap, list both and do not pick one. A scheduled exam sitting still does not offer this prompt. The oral-exam choice is only on the class-time prompt, because the lecturer may start one without notice. Never start the microphone from the timetable alone.
3. Record only after two unchecked attestations: “I am allowed to record this class” and “The lecturer or school permitted recording.” No “don’t ask again.” Later lectures in that course show a one-line confirm. On confirm, write an attestation on that lecture: the two statements, the time, the app version, and whether Face ID succeeded. The student cannot start if either box is unchecked. The attestation is kept with the lecture and shown in its details. It is the student’s own confirmation, not proof that the lecturer consented. Deleting the lecture deletes the attestation. It is not uploaded.
4. Controls: pause, resume, stop. Recording continues if the screen locks or the student switches apps. It uses background audio. It does not continue if the app is force-quit. A Live Activity (`liveactivity` widget extension) shows the recording on the Lock Screen under the clock and in the Dynamic Island, with the course name, elapsed recorded time, and recording or paused. The Lock Screen banner and the expanded Island offer pause or resume, “I didn't get this”, and stop (App Intents). Lock Screen stop ends the lecture without the in-app “End this lecture?” ask. Compact Island stays display-only. A message banner does not stop capture. A phone call, alarm, or other audio interruption pauses and keeps the file. When it ends, ask to resume. Do not resume by itself. Stop asks “End this lecture?” No leaves it paused. Yes closes the file and marks it unprocessed. Recording does not stop itself at one hour or at the slot’s end. A block class can run two hours with no break. The slot end does not close the file. Do not start transcription or models on that tap. A short break is not long enough, and the battery may be low.
5. Process now with no model downloaded still starts the transcript if the system speech asset is installed. When no text model is installed, ask first ("No AI model installed": process anyway or cancel), so the student is not surprised after minutes of transcript work. The transcript is saved before the tags stage. If no text model is installed there, stop with a message that says to download one, keep the transcript, and resume at the tags stage on the next run. It stops at the first step that needs a missing model, names that model, and opens Settings on that model’s download row. Do not open the top of Settings. Download, then return to the lecture and resume the last finished stage. Unprocessed lectures also appear in a Pending list on the term home, newest first, with course name, date, and recorded length. Processing one does not block recording the next course. The student can select several pending lectures and tap Process all. They run as a queue, in the order selected, one at a time. The next starts only after the previous page is saved or has failed. Do not load two transcripts or two models at once. A failure skips to the next and leaves the failed card marked. Cancel stops the current one and leaves the rest pending. Start automatically only when the phone is charging, idle, and the app is open. On low battery, do not start. If the student leaves during recording, processing, or a model download, confirm before the screen goes. Recording: continue in the background, or stop and keep the file. Say that force-quit ends it. Processing: keep the app open, or leave and resume the last finished stage later. Do not say it will finish in the background. Download: continue in the background, or cancel the file. Do not block a leave with no choice. If the phone becomes hot, or the student wants everything stopped, a Stop control is on the recording screen, the Live Activity, the processing card, and the download row. Stop ends the microphone, cancels the queue, and cancels the download. The file and any finished stage stay. If the system kills the app for heat, the same rule holds: resume later from the last finished stage, do not restart from the beginning, and do not delete the recording. A one-hour lecture is on the order of 15–30 minutes to process. Treat that as a guide, not a promise. It depends on the phone, the transcript, and whether 4B loads. When a lecture finishes processing, send a local notification: course name, start time, and that the note is ready. No note text. Tapping it opens that lecture, not the day’s other sessions. This uses the same notification permission. If it was denied, the card still changes to ready and no alert is sent. Several recordings of the same course on the same day are separate lectures, distinguished by start time and recorded length. A break that ends the recording starts a new lecture. A pause does not.
6. Permissions are asked at the moment of use. Microphone on the first record. Camera on the first board or timetable photo. Notifications on the first reminder choice. Face ID on first launch, because the lock is on by default. A denial disables only that action.
7. Optional tap “I didn’t get this” stores a second offset. No naming during capture.
8. While processing, the card shows the stage: audio, speakers, transcript, tags, page, links.
9. Ready lecture has three tabs: Summary, Notes, Raw. At most three suggestions, each with a source. Tap a timestamp to play.
10. After the first lecture, ask once about the longest cluster: “Is this the lecturer?” Yes stores that print in the course cluster. Front-row and back-row are extra prints, not one threshold.
11. Student may set an exam date on the course. That builds the evening drill. After the exam, ask whether to delete the audio. Notes remain.

## 5. Pipeline after stop

One file, three reads, never concurrent with model load.

1. Speech activity. Paused gaps are already absent. Remaining ranges are speech.
2. v1 speaker pass: the longest speech run is the narrator candidate. Short overlapping whispers are `room` and are not transcribed. A near, short turn that starts with an address to the lecturer is `question`. Do not build front-row and back-row print matching in v1. FluidAudio may supply the runs. If it fails, one narrator and room is enough.
3. `SpeechAnalyzer` transcribes narrator and question ranges with timestamps. If the quality gate fails, the student can pick the Whisper transcript in Settings.
4. Tag each window with the picked text model. Invalid struct: retry once. Still invalid: keep raw text, do not link. If no text model is installed, log it once, skip the remaining windows, and keep the raw text.
5. Compose the page from tags only, not from raw audio, with the same picked model.
6. `Linker.bind` runs on reference and exam-scope tags.
7. Do not rely on `BGProcessingTask` to finish a lecture. Rebind when the app is open. If a link is still pending, the card says so.

Expect on the order of 15–30 minutes for a one-hour lecture. The student can leave the app. Persist the stage. Resume from the last finished window if the system kills the process.

Known gap, not built yet: windows of a single speaker. The transcript joins the words of one speaker into one line, and a new block starts only when the speaker changes. A lecture with one narrator is therefore one block, whatever its length. Seen in the logs of a one-minute Whisper recording: 14 Whisper segments became `Transcript blocks=1`, the tag call got the whole text as one window (1067 characters, 29 seconds, then `Failed to parse generated content`), every assignment pointed to minute 00:00, and tapping it played to the end of the file. A one-hour lecture would be one block of about 50,000 characters; this was not tried.

Proposed fix, to be done only if the student asks, or suggested to the student when a problem like the ones above appears again (a failed or very slow tag stage on a long lecture, tasks or notes that all point to 00:00, a source tap that plays to the end of the file):

1. After the speaker pass, cut the line of one speaker at Whisper segment ends into windows. Group segments into one window until it reaches about 600 characters or 45 seconds, whichever comes first, and never cut inside a segment. Each window is a `Block` with its own start second. Do not make one block per segment: one hour is about 800 segments, which is too many rows and too many model calls. About 80–120 windows per hour is the aim.
2. Tag each window as step 4 already says. A window that fails is kept as raw text and does not stop the others.
3. A task, a source tap and the pause at the end of a task sentence then use the real start of its window and the start of the next one.
4. Measure the tag time on a long lecture before the sizes are fixed. The window size trades the number of model calls against the length of one call.

Related, smaller, also not built: `numbers: [Double]` in `WindowTag` made the 4B model write digits until the 256-token limit, and the answer could not be parsed. If this happens again, take the numbers out of the model's shape and read them in Swift from the spoken text of the window; a number must still be spoken in the window.

## 6. Speakers

Prints are vectors stored per course, not names glued to audio.

First lecture: Speaker 1, 2, 3. Ask only about the longest cluster. Optional second question for the near short cluster (“this is me”). Everything else can stay Room.

Later lecture: longest cluster is the narrator candidate. If it is roughly near any print in the lecturer set, label Lecturer. If not, label Narrator and ask once. A yes appends that day’s print. Never apply a single cosine cutoff across front row and back row. Short turns do not inherit the lecturer name. Unknown stays unlabeled. Prints do not cross courses. Deleting prints makes the next lecture numeric again.

## 7. Tag schema

Window tagger must return this shape. Use `@Generable` on iOS 27. Do not ask the model for free JSON in the prompt.

```swift
@Generable
struct WindowTag {
    var language: String
    var speakerRole: String
    var kind: String
    var topics: [String]
    var text: String
    var listItems: [String]
    var numbers: [Double]
    var importanceCue: Bool
    var missing: Bool
}
```

`kind` is one of: definition, list, example, emphasis, reference, assignment, examScope, decision, other.

A list is filled only if the lecturer enumerated. If they announced five items and two are unintelligible, store five rows and mark the missing ones. Do not invent items. If no numbers were spoken, `numbers` is empty and no chart is drawn.

Assignment and reference are separate optional structs, produced only when the wording is in the window: a due hint such as next week, a topic, a time hint such as previous lecture. Due dates are computed from the lecture date. A book title that was not spoken is left missing.

## 8. Linking

```swift
func bind(_ block: Block, in notes: [Block]) -> Link {
    let pool = notes.filter { $0.courseId == block.courseId && $0.at < block.at }
    let window = pool.filter { block.timeHint?.contains($0.at, relativeTo: block.at) ?? true }
    let hit = window.first { topicMatch($0.topics, block.topics) }
        ?? window.first { embedScore($0, block) > 0.86 }
    return Link(from: block.id, to: hit?.id, why: hit == nil ? "no-match" : "topic+time")
}
```

`topicMatch` normalizes case, hyphens, and diacritics. “p-value” and “p value” match. “mean” and “expected value” do not, unless the student marks them as the same topic. That pair is stored as a `TopicAlias` and reused. Embedding is a fallback only above 0.86. Below that, the link target is nil and the UI says no matching note. Contradictions are linked and shown side by side, never merged.

Exam scope uses the same function once per named topic. A named topic with no note stays on the list with an empty target.

## 9. Modules

Single app target.

- `App` — scene, model gate, background task registration.
- `Capture` — `AVAudioEngine`, mono AAC m4a around 32 kbps, pause segments, interruption, lock-screen indicator.
- `Consent` — first-lecture attestations, later one-line confirm.
- `Schedule` — weekly slots, “happening now” pin. Never auto-starts the mic.
- `Separate` — FluidAudio wrapper, role rules, lecturer print set.
- `Transcribe` — `SpeechAnalyzer`, asset install, quality gate, optional Whisper.
- `Extract` — window tags, one retry.
- `Compose` — picked text model page, summary, quiz items, spoken script. Input is always tags.
- `Bind` — topic, time, aliases. No model.
- `Store` — SwiftData plus files under `Documents/Courses/{id}/`.
- `Review` — drill, flashcards, score.
- `Speak` — `AVSpeechSynthesizer`, paragraph steps.
- `Suggest` — at most three rows, each with a source.
- `ModelGate` — actor. Serial load. The old text model is released before another loads. Cancel on lecture delete.

## 10. SwiftData

```swift
@Model final class Course {
    var name: String
    var localeIdentifier: String
    var examDate: Date?
    @Relationship(deleteRule: .cascade) var slots: [CourseSlot]
    @Relationship(deleteRule: .cascade) var lectures: [Lecture]
    @Relationship(deleteRule: .cascade) var voiceprints: [Voiceprint]
    @Relationship(deleteRule: .cascade) var aliases: [TopicAlias]
}

@Model final class Lecture {
    var course: Course
    var startedAt: Date
    var recordedSeconds: Int
    var state: String // recording, paused, processing, ready, failed
    var stage: String
    var audioRelativePath: String?
    /// Where the microphone ran: iPhone or appleWatch. Not a marketing model name. All captures so far are
    /// iPhone; Watch is not in v1. The field is stored so a later Watch run can tell the sources apart.
    var captureSource: String
}

@Model final class Block {
    var lecture: Lecture
    var second: Int
    var role: String // narrator, question, room, unknown
    var kind: String
    var text: String
    var topics: [String]
    var importance: Bool
    var missing: Bool
    var userFlag: Bool
}

@Model final class Link {
    var from: Block
    var to: Block?
    var why: String
}

@Model final class Assignment {
    var course: Course
    var text: String
    var due: Date?
    var source: Block
    var done: Bool
}

@Model final class QuizAttempt {
    var course: Course
    var at: Date
    var correct: Int
    var partial: Int
    var wrong: Int
}
```

Deleting a lecture asks first. Yes removes that recording, its note, its attestation, its board photos, and links that point at it. The course, the timetable, and other lectures stay. An exam score typed on a sitting stays if the student keeps the sitting. Deleting the course asks separately and removes its lectures, files, and sittings. Neither delete can be undone. The recording cannot be shared, exported, AirDropped, or opened in the share sheet. No encrypted audio export. Playback stays inside the lecture. Notes, assignments, and exam rows can be written to an encrypted file the student exports. Audio is not in that file. A note may also be copied as text only after a confirm.

## 11. Screens

- Course list with optional “now” pin.
- Course: lectures, open assignments, exam date, record button.
- Recorder: pause, resume, stop, elapsed recorded time, didn’t-get-this.
- Processing stages.
- Lecture: Summary, Notes, Raw. Emphasis strip. Assignments. Linked lectures. Tap timestamp to play.
- Ask: “summarize this course”, “what were the assignments”, “explain {topic}”. Answers come from stored blocks. A Source button under the answer opens that recording’s Raw tab at the block that best matched the question (this recording when Ask is opened from a lecture; whichever recording supplied the block when Ask is opened from the course). Listen stays on the lecture bar menu and reads the note aloud.
- Drill: up to 10 questions from emphasis, missing, and previously missed blocks. Score is correct / partial / wrong. Never “you passed.”
- Models: download 2B, 4B and Whisper, resume partial files, delete models without deleting notes. Whisper is in its own speech to text group.

Charts only when `numbers` is non-empty: bar, line, two groups, Swift Charts. No spreadsheet engine. A table may export as CSV inside the encrypted file.

## 12. Suggestions

At most three, each sourced:

- Exam topic with no note.
- Assignment past due or due soon, not marked done.
- Emphasis block the student missed, or a quiz item missed more than once.
- Reference with a nil link: “no matching lecture — pick one.”
- Missing formula: “spoken as on the board; add a photo to retry.”

No “this will be on the exam” unless the lecturer said it. No cross-course suggestions.

## 13. Voice, in both directions

The note is the source. Voice is only how the student asks and how the app reads the answer.

Ask. A system microphone button on the course page. The student speaks in the course language: “what did the lecturer assign”, “explain the last lecture”, “read the emphasis from notes between 1 October and 20 October.” `SpeechAnalyzer` writes the question on device. Swift selects blocks in that course, optionally filtered by topic and date range. The picked text model writes the answer only from those blocks. Source under the answer opens the matching block in that recording’s Raw tab. Listen on the lecture bar still reads the note aloud. If the range has no notes, the sheet says so. It does not switch courses.

Quiz. The student says “quiz me on these topics” or “quiz me on notes between these dates.” Swift builds the set: emphasis first, then missing and previously missed, inside the filter. The picked text model writes questions from those blocks only. The student answers by voice. The answer is transcribed, then scored against the block text.

- Covered: correct. Read the source sentence.
- Incomplete: partial. Read what was missing, then the stored sentence. Do not add a fact that is not in the note.
- Contradicted: wrong. Read the stored sentence and the timestamp.
- No stored note for the requested topic: skip the question and say the lectures do not contain it.

The score is correct / partial / wrong. Never “you passed.” A date filter that matches nothing produces no questions.

Playback of a note, a list, or an emphasis strip uses the same synthesizer, paragraph by paragraph, with pause and replay.

## 13b. Study actions

Every action below uses the same gate. Swift selects blocks in the open course. Optional filters are topic, date range, lecture, kind, and emphasis. The picked text model speaks only from that selection. An empty selection is spoken as empty. No second course, no outside fact, no “this will be on the exam” unless a block is `examScope`.

Read:

- This lecture, from the summary or from a chosen minute.
- This topic across lectures, in date order, with the date spoken before each part.
- Emphasis only, assignments only, or rows the student marked as not understood.
- A list, in order. Missing rows are spoken as missing, not filled.
- A contradiction pair, both sentences, both dates. Do not merge them.

Ask:

- “What did the lecturer assign, and what is still open?”
- “What did they say was in scope?” Named topics with no note are spoken as missing.
- “Where did this term get defined?” Reads the definition block and the minute.
- “Repeat the example.” Reads the example block, or says there is none.
- “What is due before {date}?” Reads open assignments whose due date falls before that date.

Quiz filters, spoken or typed:

- Topics the student names.
- A date range.
- Emphasis only.
- Assignments only, recalled in the lecturer’s wording.
- Rows marked not understood.
- Items missed last time.
- List order: the app speaks the title, the student says the items, missing items are read back in order.
- A spoken number from a stored example: judged against `numbers` and the sentence, not recomputed from a textbook.

Follow-up. A partial answer gets one spoken completion from the same block, then the next question. A wrong answer offers “read the minute” and does not start a lecture of its own. The student can say “stop”, “repeat”, “skip”, or “open that minute.”

Session. A drill remembers the cursor. “Continue” resumes the same filter. The evening pass, if an exam date is set, prefers emphasis, open assignments, and missed items inside the exam scope. No exam date means no evening pass. The student can still start any filter by hand.

Briefing. “What changed this week?” reads new topics, new emphasis, new assignments, and any new nil link. It is a list, not an essay.

## 13c. Talking with the notes, in the lecturer’s framing

The student should feel they are being questioned by the person who taught the course. That feeling comes from selection and wording, not from a fake persona that invents facts.

Question priority, in order:

1. Blocks the lecturer marked in speech: “this will be on the exam”, “this is important”, “do not mix these up.”
2. Topics that recur across lectures. A topic said three times outranks a topic said once.
3. Exam-scope topics the lecturer named later. A named topic with no note is spoken as missing, not quizzed from outside knowledge.
4. Lists they enumerated, examples they worked, definitions they repeated.
5. Rows the student missed last time.

Wording. The question uses the lecturer’s terms from the block. “What did I say a small p means in this course?” is allowed. “What does the literature say?” is not. The spoken stem may use first person only as a frame over a stored sentence: “I told you not to write the formula without the interpretation. What was the interpretation?” The interpretation that is read back must be the block text.

Turn taking. The student can interrupt: “ask me that again”, “give me the example”, “why was that marked important?” The reply cites the minute. A follow-up that the notes cannot answer ends with “that was not in the lectures.” It does not improvise a tutorial.

Weight. The session opens on the heaviest topics, not a random sample. After those are answered, it moves to the long tail. The student can say “only what you said was important” and the filter drops to emphasis and exam-scope blocks.

## 13d. Assignments

An assignment exists when a spoken sentence carries a homework cue (for example “haftaya”, “ödev”, “araştırıp gelin”), or when the AI correction adds an `ASSIGNMENT:` line whose words are from that text and sit next to such a cue. Cue-bearing sentences are the primary source; model lines are secondary and must not invent or replace the lecturer’s wording when both name the same task. The lecturer’s sentence, the source minute, and a due date computed from the hint are stored. A block tagged `assignment` alone does not create a row. The student marks it done. The model never marks it done.

The course page has an assignment list: open, done, missing due date. Done is a system toggle. Undoing it returns the row to open.

Spoken questions, answered from that list in the open course:

- “What did the lecturer assign?” Every row, open and done, with the due date and the source minute.
- “What have I not done?” Open rows only.
- “What is waiting?” Open rows whose due date is still ahead, then undated open rows.
- “What is overdue?” Open rows past due.
- “What did I finish?” Rows the student marked done.
- “What is due before {date}?” Open rows with a due date on or before that date.
- “When is {assignment} due?” The stored due date, or “no date was spoken.”

A book, chapter, or page that was not in the sentence is not invented. Marking done does not delete the source block. Another course’s assignments are not read.

## 14. Storage and battery

- About 15 MB per hour at 32 kbps mono AAC. Forty hours is under 1 GB.
- No model during capture.
- Night pass only when idle and charging.
- After the exam date, ask to delete audio. Default keep until the student answers.

## 15. Legal UI, not a legal opinion

The checkboxes are an attestation, not consent from the lecturer. Microphone purpose string: recording a class the student is permitted to record, for personal notes, on device. Recording indicator required. Sharing off unless the student exports.

## 16. Build order

1. Course, slot, recorder, pause/resume/stop, consent, m4a on disk. No model.
2. SpeechAnalyzer transcript with timestamps, airplane mode.
3. FluidAudio roles and the one-time lecturer question.
4. Model download gate, one picked text model for tags and page.
5. Linker, assignments, emphasis strip.
6. Ask, spoken playback, drill.
7. Background resume, audio delete prompt, string catalog Turkish.

Do not start with the quiz. A lecture that is not a faithful page makes every later feature false.

## 17. Done when

On a real one-hour class, airplane mode, iOS 27:

- Paused gap is not in the file.
- Room audio is not in the note body.
- An enumerated list keeps its count, with missing rows marked.
- An emphasis phrase is on the strip and a normal sentence is not.
- “Last lecture” does not attach to the wrong course or the wrong date.
- A formula that was not spoken is absent.
- A summary row always has a date and a timestamp.
- A second course does not appear in the first course’s answers.
- UI language can be Turkish while code and comments stay English.
- No network call during processing after models are installed.
