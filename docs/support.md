# Bellnote Support

Need help? Open an issue at [github.com/CanBASCI/Bellnote/issues](https://github.com/CanBASCI/Bellnote/issues). Say what you did, what you expected and what happened, and which iOS version you use. Please do not put private notes or recordings in a public issue.

## What you need

Bellnote runs a language model and a speech model on your iPhone, so it asks more of the device than most apps.

| | Requirement |
|---|---|
| iOS | iOS 27 or later |
| Device | A real iPhone. The Simulator is not supported |
| Memory | 8 GB or more is recommended. Below 8 GB the larger text model is switched off, and the app says why |
| Free storage | About 10 GB is comfortable. See the table below |
| Network | Wi-Fi for the one-time downloads. Afterwards Bellnote works in airplane mode |

Please do not use Bellnote on an iPhone with less than 8 GB of memory if you want the full experience. The smaller text model still runs there, but the larger one is locked, and processing is slower and less thorough.

## Downloads

The models are not inside the app. That keeps the install small. You download them once, from the Models page in Settings, by tapping Download on each row. Nothing downloads by itself.

| Model | What it does | Size |
|---|---|---|
| Qwen 3.5 2B (text) | Notes, summaries, quizzes, assistant. Faster, lighter on memory, less thorough | about 1.6 GB |
| Qwen 3.5 4B (text, optional) | The same jobs. Slower, uses more memory, more accurate. Needs 8 GB of memory and 4 GB of free space | about 3.1 GB |
| Whisper large-v3 turbo | Speech to text for recordings | about 0.65 GB |
| FluidAudio | Tells speakers apart | about 0.16 GB |
| Supertonic | The voice for read aloud and Talk | about 0.15 GB |

You need one text model. The 2B model with the other three is about **2.6 GB**. With the 4B model as well it is about 5.7 GB. Keep some free space beyond the download: Whisper needs about as much again while Core ML prepares it.

Until the required models are installed, only Settings is open, on the Models page. The other tabs turn on by themselves when the last download finishes.

## Questions

**Why are Home, Files, Quiz and Assistant disabled when I open the app?**
The AI models are not installed yet. Open Settings, then Models, and tap Download on each row. The tabs open when the last one finishes.

**The row says "Preparing" after Whisper downloaded. Is that normal?**
Yes. The first time, Core ML builds the model for your iPhone's chip. It can take up to about four minutes. It happens once, as long as the model stays installed. Keep the app open.

**Can I stop a download?**
Yes, with the Stop control on the row. A partial download resumes later.

**Does it work offline?**
Yes, once the models are installed. Recording, notes, quizzes and the assistant do not need a network.

**How long does a recording take to process?**
A one-hour class takes on the order of 15 to 30 minutes. It depends on the iPhone and on which text model you chose. Keep the app open while it works. If the system stops it, Bellnote resumes from the last finished stage.

**Does Bellnote upload my recordings?**
No. Nothing leaves your iPhone. See the [privacy policy](privacy).

**Can I delete a model to get space back?**
Yes, from the Models page. Your notes stay. The tabs that need that model turn off until it is downloaded again.

**Which languages are supported?**
The app is in English and Turkish. A course has its own language, so a Turkish class stays Turkish in an English app.

**Why does Bellnote ask me to confirm I can record?**
Recording rules differ by country and school. Before the first recording of a course Bellnote asks you to confirm that you are allowed to record. See the [privacy policy](privacy) for more.
