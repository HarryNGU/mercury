# Testing Bubble (private beta)

Thanks for trying Bubble before anyone else. It's my take on the ultimate personal assistant: it floats over your Mac, answers questions about your screen, types what you say anywhere, drafts things for you (it never sends anything without your OK), listens along to calls and videos, and records and edits your screen.

This is an early build, so things will break. Finding them is exactly what I need your help with.

## What you need

- A Mac on macOS 15 (Sequoia) or later. Apple silicon and Intel both work.
- About 15 minutes to set it up and have a first look.
- Optional, for the assistant: [Claude Code](https://claude.com/claude-code) signed in (run `claude`, then `/login` in Terminal), or an Anthropic API key.
- Optional, for much better speech recognition: [Homebrew](https://brew.sh), then `brew install whisper-cpp`. Bubble will offer to download the speech model itself (574 MB).

## Install

1. Open `Bubble-1.3.3.dmg` and drag Bubble into Applications.
2. Optional: check it's the same file I sent. In Terminal, run `shasum -a 256 Bubble-1.3.3.dmg`. It should print
   `4e7c84c5427c80185632f491bc92db60c0920019390189f1887ad101721e63b5`.
3. Open Bubble. This beta isn't notarised by Apple yet, so macOS will refuse to open it the first time. Go to System Settings → Privacy & Security, scroll down to the message about Bubble, click Open Anyway and confirm. You only have to do this once per version.
4. Bubble introduces itself in a short chat and asks for each permission as it goes. After you allow Screen Recording, macOS may ask you to quit and reopen it. It picks up where you left off.

Each new beta build might ask for the permissions again. That's normal for builds that aren't signed by Apple.

## What to try

Tick these off as you go, and make a note of anything that's odd, slow, confusing or ugly.

**First run**
- [ ] The welcome chat. Was every step clear? Did any permission request catch you off guard?
- [ ] If you can, try it on a brand new user account too (System Settings → Users & Groups), so nothing is already allowed.

**Ask Bubble** (⌥\ to show or hide it)
- [ ] Ask about something on screen, like a web page, a PDF or a spreadsheet.
- [ ] Ask for a picture, a molecule ("show me caffeine's structure") or a YouTube video.
- [ ] Ask it to make a chart or diagram. It should appear right in the chat, not in a browser tab, and clicking it should open it in Preview.
- [ ] Ask it to draft an email or a message. Check that it shows an Allow or Deny card before sending anything, and that Deny really stops it.
- [ ] Talk to it with ⌥⇧\ and then stop speaking. Does it finish on its own?
- [ ] Turn on Listen while a YouTube video plays. Does the transcript keep up with the video, and ignore your own voice?
- [ ] Click Bubble's picture to change its face and nickname, and react to a message (hover over it, or right click).
- [ ] Share your screen in Zoom or Meet, or record with Bubble, and open the panel. Turn Visibility off on the bar, then back on. The panel should disappear from the share and the recording (and come back), while you can still see it the whole time.
- [ ] Hover over Listen, Visibility and the eye. Each one should explain itself in a card that's easy to read.
- [ ] Type a message using Shift+Return for a new line. Scroll up to the top of a long chat and use Jump to present.
- [ ] Select text in the chat and in the typing box with your mouse. The panel should stay where it is. Drag the bar along the top to move it.
- [ ] Move the panel with ⌥ and the arrow keys. Try it over a full screen app too.
- [ ] Go to Settings → Assistant → "What Bubble knows about you", paste in what ChatGPT knows about you, then ask Bubble something personal.

**Chats are remembered**
- [ ] Ask Bubble something, quit Bubble (⌘Q), open it again and show the panel. Your chat should still be there.
- [ ] Start a new chat (⌘N in the panel, or the pencil button), then reopen the old one from the clock button.
- [ ] In Settings → Assistant → Chat history, try "Don't keep" and "Delete all chats".

**Feels like a proper Mac app**
- [ ] Go through the menu bar: Bubble, File, Edit, View, Window and Help. Does everything do what it says?
- [ ] ⌘, opens Settings, ⌘1 to ⌘6 switch pages, and About Bubble shows the version.
- [ ] In Settings → General, turn on "Open Bubble when you log in", restart your Mac, and check it starts quietly in the menu bar.
- [ ] The Dock icon should only appear while Bubble's window is open.

**Dictation**
- [ ] Double tap ⌥ in Notes, Messages, a text box in your browser, and Slack. Talk, then pause. Did it type the right thing in the right place?
- [ ] Try correcting yourself mid sentence ("at 5, no wait, 6").

**Recording**
- [ ] Record a window, a Chrome tab, an area and the whole screen. Try pause, restart and discard.
- [ ] While recording, switch to other apps and desktops. The pill should come with you and never show in the video.
- [ ] While recording, click the pen on the pill and draw. Try the pen, highlighter, disappearing ink, an arrow, and a wobbly circle (it should tidy itself up). Try the lasso, the eraser, undo and Clear. Click Done and use your apps again, and the drawings should stay. Are the drawings in the video, and the toolbar not?
- [ ] Record a page showing an email address, a phone number or an API key (made up ones are fine). They should be blurred in the video from the very first frame. Let me know about anything private it missed, or anything it blurred that it shouldn't have.

**Editing**
- [ ] On a recording in the library, click Make reels. Are the captions accurate and in time?
- [ ] Click a clip on the timeline, drag its ends to trim it, press S to split it, and try 2× on one clip. Does the preview update straight away? Do undo and redo work?
- [ ] Press and drag across the video on the timeline to pick a stretch, adjust its ends, then try Cut it, Keep only and 2×.
- [ ] Pick a clip in a recording of a call and give it its own mix in Sound mix (for example Mic only). Does that part sound right?
- [ ] In Transcript, fix a wrong word in Fix words. Do the captions change straight away? In Cut video, select some words and press Delete, then click a crossed out word to bring it back.
- [ ] Space should play and pause, ← and → should jump 5 seconds, and you should be able to drag the bar under the preview. Try the light and dark looks too (the sun or moon at the top).
- [ ] In Audio, turn on Enhance speech, Remove echo (on a call recording) and Polish voice. Once the progress finishes, is the background noise gone and the echo of your voice removed? Try the Social loudness target and the two track volumes.
- [ ] Add a blur box in Media, drag it over something in the frame, and try Blur, Pixelate and Block out. Try a filter in Colour.
- [ ] Add a title (T) and a zoom (Z). Drag the title around on the preview, and drag both along the timeline. Try the animations and the caption styles.
- [ ] Drop a video, a picture and a song onto the editor. Does the video play on top (try picture in picture and full screen)? Does the music get quieter while you talk?
- [ ] Ask Claude for a change in Quick edit ("make it under 60 seconds", "add a title"), then Export. Do the videos play, and do they look like the preview?
- [ ] Switch to Full job and paste in a longer recipe. Can you follow the steps? Does it ask before doing anything risky?

**Things that should never happen** (tell me straight away if they do)
- Bubble sends, deletes or changes anything without you allowing it.
- Bubble listens, looks at your screen or records when you didn't ask it to.
- Bubble freezes your Mac or won't quit.

## Reporting a problem

Open an issue at [github.com/HarryNGU/bubble/issues](https://github.com/HarryNGU/bubble/issues), or just message me, with:

- what you did, what you expected, and what happened instead;
- a screenshot or short screen recording if you can;
- your Mac model and macOS version (Apple menu → About This Mac).

Bubble keeps a log at `~/Library/Logs/Bubble.log`. It helps a lot, but please read it before you share it, because it can contain the names of apps and windows you've used. Only send the lines around the problem.

If you find a security problem, please report it privately (GitHub → Security → Report a vulnerability) rather than in a public issue.

## Be considerate of others

If you turn on Listen during a call, the other people's voices are transcribed (on your Mac). Let them know first, the same as you would before recording.

## Removing Bubble

Quit it, drag it from Applications to the Bin, and if you like, delete `~/Library/Application Support/Bubble` and `~/Library/Logs/Bubble.log`. Your recordings in `~/Desktop/Bubble Recordings` stay until you delete them. You can also remove its permissions in System Settings → Privacy & Security.
