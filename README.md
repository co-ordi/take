# Take

A small menu-bar screen recorder for macOS. Press a shortcut, count down from 3, talk over your screen, press it again. The video lands in `~/Movies/Take`, and goes into Photos when you say so.

## Build it with your AI

Easiest way to get it on your Mac: paste this into Claude Code (or Codex, Cursor or any coding assistant that can run commands):

> Clone https://github.com/co-ordi/take, read AGENTS.md, then build and install Take on my Mac and walk me through the permissions.

It needs macOS 15 or later. Prefer doing it yourself? See **Building** below.

## Using it

- Click the ⦿ in the menu bar and hit **Record**, or press **⌃⌥⌘R** from anywhere.
- The menu bar counts 3, 2, 1, then shows a red dot and a timer.
- **Pause** with **⌃⌥⌘P** or the pause button that appears next to the timer. The timer goes grey with an orange pause sign. Press again to carry on. The paused stretch is cut out, so you get one continuous video.
- To stop, click the timer or press **⌃⌥⌘R** again (this works while paused too). Either one cancels during the countdown.
- The video saves to `~/Movies/Take` as `Take 2026-10-05 at 14.03.22.mov`. A notification says "Saved", with an **Add to Photos** button; clicking the notification shows the file in Finder.
- **Recordings** in the menu (folded like the other sections) lists the latest five with their length. Each has **Add to Photos**, which turns into **In Photos ✓** once it's there. Click a recording's date to show it in Finder; **Show all** opens the folder. Switch on **Add new recordings to Photos** (off by default) to have every new recording added after it saves. Take never asks for Photos access unless you add a recording or switch that on; if you refuse, the switch goes back off.
- **30 fps / 60 fps** for Full screen and Vertical (remembered, 30 by default). 60 is smoother for scrolling and motion, with bigger files.
- Menu switches, all remembered: **Full screen / Vertical 9:16 / Camera only**, **Microphone** (with a live level meter, on by default), **Voice isolation** (on by default), **Computer sound** (off by default), **Camera bubble**, **Notes**. Under **More**: **Clean screen** (on by default) and **Open at login**. Only one of the folded sections opens at a time, and on a small screen the menu scrolls rather than growing past the screen.
- **Voice isolation** runs your microphone through Apple's own voice isolation (the effect built into macOS) when the recording is saved: room noise and hum drop away, your voice stays as it was and in sync. It only touches the microphone, and adds a second or two to saving.
- **Computer sound** records what your Mac plays as well, for showing a video or an app that makes sound. It's off by default, which keeps notification pings and music out; when it's on, it's mixed with your voice into one audio track.
- Take's menu, timer, notes and 9:16 frame never appear in the video. The camera bubble does.

## Camera bubble

- Switch **Camera bubble** on and it appears straight away, so you can see yourself and drag it into place before recording. It stays up (through recordings too) until you switch it off, and remembers where you left it. It doesn't open by itself at launch; opening the menu brings it back.
- **Size, shape and look** (folded under the switch):
  - **Size** slider, and **Shape**: circle, rounded square, portrait (3:4) or wide (16:9).
  - **Mirror** (on by default) and a thin **Border**.
  - **Look**: one-tap presets (Natural, Bright, Warm, Cool, Soft, Mono), then **Light**, **Warmth** and **Contrast** sliders to fine-tune. **Reset** goes back to Natural.
  - **Effects and background…** opens macOS's own Video Effects panel (Portrait, Studio Light, Edge Light, Background, Reactions). It's a system panel, so it can't sit inside Take, but whatever you turn on there shows in the bubble and in recordings. Underneath, Take lists which of Portrait, Studio Light, Background and Center Stage are on (macOS doesn't report Edge Light to apps).
- Light lifts the shadows and mid-tones but keeps white pinned, so a dim face brightens without the window behind you blowing out.
- Everything changes live, and what you see in the bubble is exactly what gets recorded.

## Camera only

Take picks your camera's best format (for the bubble too). If it tops out at 720p, as some MacBook cameras do, Take scales it up to 1080p with a high-quality filter and adds a light sharpen, so it looks clean rather than soft.

Pick **Camera only** to record just yourself: the camera, with your look and any macOS video effects, plus the microphone. No screen and no computer sound. Choose **16:9** (1920x1080) or **9:16** (1080x1920, for Shorts and Reels; it's cropped from the camera's landscape picture, so a touch softer). A preview window shows exactly what will be recorded: drag it where you like (it remembers), and its × turns the camera off. Mirror applies to the recording too, so it matches the preview. Pause, the timer, saving to `~/Movies/Take` and Add to Photos all work as usual.

## Notes

Switch **Notes** on for a small see-through window that stays on top. Type or paste your bullet points; they're saved as you type. The two buttons in its corner make the text smaller or larger; drag the window anywhere and resize it from its edges. It's never in the recording, so you can read from it while you talk. Its close button switches Notes off.

## Vertical 9:16

Pick **Vertical 9:16** and an orange frame appears. Drag it by its edge or label to choose what gets recorded, and drag the bottom-right corner to make it bigger or smaller (it stays 9:16). The frame shows during the countdown and disappears once recording starts. Videos come out at 1080x1920, ready for Shorts and Reels. The frame's position is remembered; the × hides it without leaving vertical mode. If you want your face in a vertical video, put the camera bubble inside the frame.

## Clean screen

On by default. While recording, notifications (and the Notification Centre panel and desktop widgets) and your desktop icons are left out of the video. Nothing is changed on your Mac: no Focus mode, no hidden icons, they just aren't captured. Finder's ordinary windows still record as normal (a Finder window opened mid-recording joins the video within a couple of seconds).

## Deleting a recording

If you've added a recording to Photos, deleting it in `~/Movies/Take` (or moving it to the Bin) deletes the same video from Photos. macOS always asks first ("Allow Take to delete this video?"); that confirmation is the system's and can't be skipped. Say Don't Allow to keep the Photos copy. Only videos Take itself put into Photos are ever touched. Renaming a recording, or moving it to another folder on the Mac, leaves Photos alone. Files deleted while Take was closed are caught up shortly after it next opens.

This needs full Photos access (not just "add"), which Take asks for the first time you add a recording to Photos. Without it, or with nothing added, the folder watcher does nothing. Take keeps a small record of which file matches which Photos video in `~/Library/Application Support/Take/photos.json`.

## Building

You need a Mac on macOS 15 or later and Apple's Command Line Tools (`xcode-select --install`; full Xcode isn't needed). Then:

```sh
git clone https://github.com/co-ordi/take.git
cd take
./build.sh
open ~/Applications/Take.app
```

`build.sh` compiles with `swiftc`, assembles `Take.app`, signs it and installs it to `~/Applications/Take.app`. If Take is running it builds and signs but doesn't install; quit Take and run it again. On first use, Take's set-up card walks you through the permissions it needs.

The icon lives in `Resources/AppIcon.icns`. To redraw it: `swift scripts/make-icon.swift Resources/AppIcon.icns`.

### Signing, and keeping permissions across rebuilds

macOS ties Screen Recording, Microphone and Camera permissions to an app's signature. By default `build.sh` signs ad hoc, and an ad hoc signature changes with every build, so after a rebuild macOS asks for those permissions again.

To avoid that, create your own local code-signing certificate named **Take Local Signing** (Keychain Access → Certificate Assistant → Create a Certificate…, Certificate Type: Code Signing). `build.sh` uses it automatically when it's in your login keychain; the first time, macOS may ask whether `codesign` can use the key: enter your login password and choose **Always Allow**. Run the build with the Mac unlocked; if the screen is locked, `build.sh` stops rather than waiting on a dialog nobody can see. It's a local certificate only, trusted for nothing else, and no key ever goes in this repo.

To remove it later: Keychain Access → login keychain → My Certificates → delete **Take Local Signing**, or `security delete-identity -c "Take Local Signing"`.

## Permissions: the set-up card

Whenever something Take needs is missing, the menu opens with a **Set up Take** card at the top. It's also under **More > Permissions** any time. One row each for Screen & audio recording, Microphone, Camera (optional) and Notifications (optional), each showing **Allowed**, **Not yet** or **Off in Settings**, with one button:

- **Allow** shows the macOS prompt.
- **Open Settings** goes straight to that page in System Settings (macOS won't show a prompt twice, so a "no" has to be changed there).
- **Allow all** goes through everything needed and not yet asked: microphone, camera (if the bubble is on) and notifications first, then screen recording. Photos isn't part of set-up at all.
- Screen recording only takes effect after a restart. Once you've switched Take on in Settings, the card offers **Restart Take**.

Statuses refresh every time the menu opens. Switching Microphone or Camera bubble on asks for it straight away; a "no" never switches them back off, the card just shows what to fix. Photos never stops a recording: videos always save to `~/Movies/Take`.

The level meter next to Microphone only runs while the menu is open (macOS shows its orange microphone dot meanwhile), and only once the microphone is allowed.

macOS sometimes asks again, every so often, whether Take can keep recording the screen. That's the system checking in; allow it.

If permissions ever get muddled (say after switching between signed and ad hoc builds), reset them and approve again: `tccutil reset All com.coordi.take`.

## What's where

| File | Does |
| --- | --- |
| `Sources/AppController.swift` | Menu-bar items, countdown, timer, pause, permission checks, start and stop |
| `Sources/PopoverView.swift` | What's in the menu (SwiftUI) |
| `Sources/MenuPanel.swift` | The menu's window: pinned under the menu-bar icon, grows downwards, closes on a click outside or Esc |
| `Sources/Recorder.swift` | ScreenCaptureKit: what's in the picture (clean screen), full screen or a 9:16 slice, sound and microphone |
| `Sources/TakeWriter.swift` | Writes the .mov as it records (H.264 High, 30 fps, about 0.15 bits per pixel: roughly 18 Mbps for a 2560x1600 screen, 10 Mbps for 1080p, keyframe every 2 s) and cuts out paused stretches |
| `Sources/Saver.swift` | Folds the audio tracks into one, saves to `~/Movies/Take`, Add to Photos, the notification and its button |
| `Sources/VoiceIsolation.swift` | Apple's voice isolation over the microphone track as the recording is saved, with its delay taken out |
| `Sources/Recordings.swift` | The latest recordings for the menu, and whether each is in Photos |
| `Sources/CameraBubble.swift` | The floating camera window: camera frames through Core Image into a Metal view |
| `Sources/CameraRecorder.swift` | Camera-only recording and its preview window |
| `Sources/CameraSettings.swift` | Bubble size, shape, mirror, border and look, remembered; the look filters |
| `Sources/NotesWindow.swift` | The speaker notes window |
| `Sources/FrameOverlay.swift` | The draggable 9:16 frame |
| `Sources/MicMeter.swift` | The microphone level in the menu |
| `Sources/Permissions.swift` | Permission statuses, prompts and Settings links for the set-up card |
| `Sources/PhotosSync.swift` | Deletes the Photos copy when a recording file is deleted |
| `Sources/HotKey.swift` | The ⌃⌥⌘R and ⌃⌥⌘P shortcuts (no Accessibility permission needed) |

Notes:

- Audio is 48 kHz AAC at 256 kbps. With Computer sound on, it and the microphone are recorded as two tracks, then mixed into one before saving, because some players and editors only use the first track. The video isn't re-encoded at that step.
- The microphone is the Mac's default input. If that's a virtual device such as BlackHole, Take uses the built-in microphone instead. It never changes your sound settings.
- The camera bubble uses the Mac's own camera, so a nearby iPhone (Continuity Camera) doesn't take over.
