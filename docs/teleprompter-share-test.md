# Verse panel: hide-from-share test (manual, on your Mac)

Covers the meeting cards too (the owner, 2026-10-15: cards hide by default, same as the prompter); also check that a
live answer card is invisible on the other side.

Goal: find out, per app, whether the prompter panel is invisible to the other side of a screen share while
"Hide Verse from screen sharing (cards and prompter)" is on. The app asks macOS to leave the panel out of captures
(`NSWindow.sharingType = .none` on the whole notch panel: meeting cards, statuses and the prompter). Public reports say ScreenCaptureKit-based
capture can ignore this on macOS 15 and later, so this has to be checked per app. Nothing here is automated.

You need a second device or a second account that watches the share (a phone with the Meet/Zoom/Teams app, or a
colleague). A recording made by the meeting app itself is a second option; a screenshot you take yourself is not
a valid test (it can differ from what the other side receives).

## Setup (once)
1. Build and open Verse (`app/scripts/bundle-app.sh`, then open `app/build/Verse.app`).
2. Settings > Teleprompter: "Hide Verse from screen sharing (cards and prompter)" ON. Mode: Classic (no microphone needed for this test).
3. Menu bar > "Teleprompter scripts…", paste a few lines of text, press Read. The prompter appears under the notch.
   Shortcuts while it is open: Ctrl+Option+P start/pause, B/N previous/next page, A/S slower/faster, H back to the top of the
   page, X close.

## For each app: Meet in Comet, Zoom, Teams
Run the three shares below, with the prompter open and reading. Write down what the viewer sees.

| # | Share | Hide ON: panel visible to the viewer? | Hide OFF (control): visible? |
|---|---|---|---|
| 1 | Entire screen (the display with the notch) | | |
| 2 | One window (the meeting app's own window, then a different app's window) | | |
| 3 | A browser tab (Meet in Comet only) | | |

Steps:
1. Join a test meeting with the second device. Start the share (case 1, 2 or 3).
2. In Verse press Ctrl+Option+P so the text is moving. Look at the viewer's screen for 10 seconds.
3. Record: panel visible / not visible / only the dark band visible.
4. Turn the setting OFF (it applies at once), look again. The panel must now be visible; if it is not, the viewer
   is not showing what you think (the control failed, discard that row).
5. Also check the meeting cards: they are never hidden by this setting (it only applies while the prompter is open).
   Open a card without the prompter and confirm whether the viewer sees it. This is a finding, not a bug in this test.

## Record the result here
Date, macOS version, app versions, and the table above filled in for each app. If any app still shows the panel with
Hide ON, say so plainly in the Verse notes: for that app, do not share the whole screen while reading; share one window.
