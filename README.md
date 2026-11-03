# Bubble

Bubble is the ultimate personal assistant for your Mac. It's free and open source. I built it because I wanted one app that could answer questions about whatever's on my screen, write and reply for me (only when I say yes), type what I say, and record and edit videos, without handing my data to yet another company.

There's no account, no analytics and no subscription.

## What it does

### Record your screen

Hover over what you want to record and click. It can be a window, a single Chrome tab (just the page), an app, an area you draw or the whole screen. Before it starts, a 3, 2, 1 countdown tints exactly what's going to be recorded.

- Your camera sits in a round bubble you can drag around. You can blur the background, darken it or cut it out completely. This uses Apple's Vision framework and runs on your Mac.
- Your mic goes through a noise reducer, and you can also record the sound playing on your Mac.
- A small pill lets you pause, restart, discard or finish. It follows you between apps, desktops, full screen apps and displays, and it never shows up in the video.
- Passwords, email addresses, phone and card numbers, API keys and similar codes are blurred as you record. Bubble reads the screen on your Mac to find them, and password managers are left out of the recording altogether. It catches most things but not everything, so do check before you share.
- You can draw on the screen while recording: a pen, a highlighter, ink that fades after a few seconds, lines, arrows, boxes and circles. Wobbly shapes tidy themselves up. There's also a lasso, an eraser, undo, and one button that clears everything. Viewers see the drawings, but not the toolbar.
- Each recording is named after the page or window you recorded, then refined using what you talked about.
- Videos are saved in `~/Desktop/Bubble Recordings` and show up in Bubble's library.

### Turn recordings into reels

One click turns any recording into Original, 1:1, 9:16 and 16:9 versions, which are the shapes Instagram offers. Bubble cuts out the pauses for you and adds big captions timed to what you say.

The editor is a full video editor, and you can use it in light or dark mode:

- A timeline with thumbnails and the sound wave. You can trim, split and delete clips, or press and drag across the timeline to pick any stretch. Each clip or stretch can have its own speed, volume, and mix of your mic and the computer's sound. Undo, redo and keyboard shortcuts work the way you'd expect (Space, S, Delete, the arrow keys, T and Z).
- You can edit by text. Fix a word in the transcript and the captions update, or select words and press Delete to cut them from the video. One click removes every um, uh, repeated word and retake.
- The sound tools run on your Mac. Enhance speech uses Apple's voice isolation. Remove echo takes out your own voice coming back through a call. Polish adds EQ, compression and a limiter. You can also even out loudness and hit a Social, Podcast or TV loudness target, and set your mic and the computer's sound to their own volumes.
- You can add titles, labels and typewriter text with animations, zooms that push in like a camera, another video on top (picture in picture or full screen B roll), and logos or screenshots. Drop files straight onto the editor, drag things on the preview to place them, and drag them on the timeline to time them.
- Subtitles come in five styles (classic, karaoke, highlight, box and minimal), in any colour and size, and you can fix any word by typing.
- You can blur, pixelate or block out part of the recording (a name, a face, a password) for as long as you need, and add a film filter.
- The canvas can fit, fill or float the recording in a frame over a blurred, solid or gradient background. You can also adjust colour, add fades, add music that dips while you talk, and show a progress bar. Export at 720p, 1080p or 4K.

You can also just ask Claude in the editor, for example "make it under 60 seconds", "add a title that says Day 24" or "zoom in when I show the code". For a longer recipe, Full job runs it step by step with your own scripts and tools while you watch. A job only works on its own inside the folders your recipe names. Deleting, moving, using the internet and opening apps all wait for your OK, and it never posts anything.

For accurate captions, Bubble uses [Whisper](https://github.com/ggml-org/whisper.cpp) on your Mac if it's installed (`brew install whisper-cpp`, then download the model from the editor). Otherwise it uses Apple's speech recognition.

### Dictate

Double tap ⌥ Option anywhere and start talking. When you pause, Bubble types a tidy version wherever your cursor is. You can also tap ⌥ once to finish straight away.

It removes fillers and stutters, applies your corrections ("at 5, no wait, 6"), and understands "new line" and "new paragraph". You can save snippets too: say a phrase and Bubble types the text you saved for it. If Whisper is set up it uses that, because it's much more accurate. Otherwise it uses Apple's on device recognition.

### Ask Bubble

Ask Bubble is a see through chat that floats over your screen. Press ⌥\ to show or hide it, and ⌥ with the arrow keys to move it. It feels like texting a friend: your messages are on the right and its replies come back as short texts on the left. Click its picture to give it a face (a dinosaur, panda, fox and more) and a nickname, restyle it from the palette button, and react to each other's messages.

- It looks at your screen when you ask, taking one screenshot that leaves out its own window.
- With Listen on, it hears your Mac's sound, like the other people on a call or a video you're watching, and transcribes it on your Mac. Listen never uses your microphone. To talk to it yourself, use Talk (⌥⇧\).
- Answers can include code, links, YouTube videos that play in the chat, pictures from Wikimedia Commons, 2D and 3D molecule structures from PubChem, and charts or diagrams it draws for you.
- It can draft emails, and prepare messages in Messenger, Instagram, WhatsApp or Messages by opening the chat and typing the message in. It never presses send for you.
- If you've been using ChatGPT, go to Settings → Assistant, copy a short prompt into ChatGPT and paste its answer back. Bubble keeps that on your Mac (`about-me.md`, readable only by you) so it already knows a bit about you. You can delete it any time.

There are two ways to connect it to an AI:

1. Claude Code (my recommendation). Bubble uses the Claude Code installed on your Mac, signed in with your Claude account. That brings in your memory notes, your `CLAUDE.md` files and your connected apps (Gmail, Calendar, Notion and so on), and lets it take actions for you.
2. An API key only. Bubble talks to Claude directly with your own Anthropic API key. It's simpler, but it doesn't have any of that context.

## Safety

I've built Ask Bubble so it can't do anything behind your back.

- Nothing gets sent to anyone without you. Sending an email needs you to press Approve (or say "yes"). Messages in Messenger, Instagram, WhatsApp and Messages are only typed in, and you press Enter yourself.
- Changes need your approval. Reading and searching happen freely, but anything that writes files, runs commands, or creates, sends, edits or deletes something in your apps shows an Approve or Deny card first.
- It's protected against prompt injection. A web page, email or file could contain text written to trick an assistant, so Bubble always asks before Claude reads key, password or history files (`~/.ssh`, keychains, browser data, shell history, `.env` files and the like), searches your whole home folder, or opens a web address that has data tucked into it. This applies even to tools you've set to "Always allow".
- Bubble doesn't keep any passwords. It uses the apps and browser you're already signed into. Claude Code keeps its own sign in details in your Keychain, and Bubble never sees them.
- Its local tool server is private. It only listens on `127.0.0.1` and needs a random secret that changes every time Bubble starts.
- It's visible on purpose. The chat shows up in screen shares and recordings like any other window, and a red dot shows whenever it's listening. You can hide the chat from recordings and screen shares when it's private (one switch covers Bubble's own recordings and Zoom, Meet and the rest), but please don't use that to cheat.

## Privacy

Everything stays on your Mac unless you use a feature that needs the internet:

| When | What's sent | To |
| --- | --- | --- |
| You ask Ask Bubble something | Your question, one screenshot (if the eye is on) and the recent transcript (if Listen is on) | Anthropic, through Claude Code or your API key |
| You use AI polish or the reel editor chat | The text of your dictation, or the video's transcript and edit settings (never the audio or video) | Anthropic, with your API key |
| An answer shows a picture, molecule or video | The search words or compound name | Wikimedia Commons, PubChem or YouTube |
| You download the Whisper model | Nothing about you, it's a plain download | Hugging Face |

Your chats with Ask Bubble are saved on your Mac in `~/Library/Application Support/Bubble/Chats`, readable only by you, so it can pick up where you left off. They're kept for 30 days by default, which you can change in Settings. Screenshots are never saved. If "Check for updates" is on, Bubble reads one small public file from its website once a day to see if there's a newer version.

Audio is never uploaded. Speech recognition, Whisper, captions and the sound tools all run on your Mac. Your API key lives in the macOS Keychain. Snippets (`~/Library/Application Support/Bubble/snippets.json`) and the latest Ask Bubble screenshot are readable only by your user account. Recordings, transcripts, settings and the log (`~/Library/Logs/Bubble.log`) stay on your Mac.

If you use Listen on a call, the other people's voices get transcribed too. Please tell them, the same as you would if you were recording.

## What you need

- macOS 15 (Sequoia) or later, on Apple silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`). You don't need the full Xcode.
- Optional: [Claude Code](https://claude.com/claude-code), signed in, for Ask Bubble with your own context, and `brew install whisper-cpp` for more accurate captions and dictation

## Build and install

```bash
git clone https://github.com/HarryNGU/bubble.git
cd bubble
./tools/make-signing-cert.sh   # once: a local signing certificate (see below)
./build.sh                     # builds and installs ~/Applications/Bubble.app
```

Open Bubble from `~/Applications`. A short welcome chat introduces Bubble and walks you through setting it up. macOS will ask for Screen Recording, camera and microphone access. After you allow Screen Recording, quit and reopen Bubble. For dictation, allow Speech Recognition and Accessibility (so it can notice ⌥⌥ in other apps and type into them). If on device dictation isn't available, turn on Dictation once in System Settings → Keyboard so macOS downloads the speech model.

Why the certificate? macOS ties privacy permissions to an app's signature. Without a signature that stays the same, every rebuild looks like a new app and you'd have to allow Screen Recording all over again. `make-signing-cert.sh` creates a self signed certificate in your login keychain that's only used to sign your own build. If you skip it, `build.sh` signs the app ad hoc instead.

## Shortcuts

You can change any of these by clicking it in Bubble.

| Keys | What it does |
| --- | --- |
| ⌥⇧R | Open the picker, or finish while recording |
| ⌥⇧A | Draw an area, then record it |
| Double tap ⌥ | Start dictating. It finishes when you pause (tap ⌥ to finish early, Esc to cancel) |
| ⌥\ | Show or hide Ask Bubble |
| ⌥⇧\ | Talk to Ask Bubble |
| ⌘↩ (with Ask Bubble open) | Ask about the screen |
| ⌥ and the arrow keys (with Ask Bubble open) | Move Ask Bubble |

## How the code fits together

| File | What it does |
| --- | --- |
| `Sources/Recorder.swift` | Screen capture with ScreenCaptureKit, written to MP4 with AVAssetWriter; pausing, cropping and mixing the audio |
| `Sources/Picker.swift`, `Sources/Overlays.swift`, `Sources/Draw.swift` | The hover picker, recording pill, countdown and toast, and drawing on the screen while recording |
| `Sources/Camera.swift`, `Sources/Mic.swift`, `Sources/Denoiser.swift` | The camera bubble, microphone capture and the noise reducer |
| `Sources/Library.swift`, `Sources/Glyphs.swift` | The main window (library and settings) and Bubble's symbols |
| `Sources/Reels.swift`, `Sources/Editor.swift` | Pause cutting, captions, and the editor's model, page and Claude chat |
| `Sources/Studio.swift`, `Sources/StudioTimeline.swift`, `Sources/StudioPanels.swift`, `Sources/StudioStyle.swift`, `Sources/AudioStudio.swift` | Everything else in the editor: text, zooms, videos, pictures, music, canvas and colour, the compositor that draws each frame, the audio mix, the timeline, the tool panels, the editor's look, and the sound tools (voice isolation, echo removal, polish and loudness) |
| `Sources/Whisper.swift` | Whisper for captions and voice, run on your Mac |
| `Sources/Dictation.swift`, `Sources/Cleaner.swift`, `Sources/Snippets.swift` | Dictation, the clean up rules, AI polish and snippets |
| `Sources/Assistant.swift`, `Sources/ClaudeCode.swift`, `Sources/BubbleTools.swift` | Ask Bubble: the panel, live listening, the Claude Code session and its safety rules, and Bubble's local tools |
| `Sources/Shortcuts.swift` | Global shortcuts you can change by clicking them |
| `Sources/Chats.swift` | Saved Ask Bubble chats, history and how long they're kept |
| `Sources/Onboarding.swift` | The welcome chat: permissions, connecting your AI and Bubble's promises |
| `Sources/Updates.swift` | The daily update check |
| `Sources/Namer.swift` | Automatic titles |

For testing, `Bubble --selftest 6 [screen|area|window|chrome] [pause|restart]` records without the countdown and then quits. `--pickertest`, `--countdowntest`, `--edit <file>`, `--assisttest [question]` and `--dicttest` open those parts directly.

## Contributing

Issues and pull requests are welcome. All I ask is that you keep Bubble private by default: no accounts or analytics, nothing leaves the Mac unless the user turns it on, and nothing gets sent to other people without the user saying so.

## Licence

MIT. You're free to fork it, change it and ship it.
