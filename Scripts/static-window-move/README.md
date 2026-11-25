# Static window move on macOS build 26B8132

This probe asks an already running yabai-sb Dock service to move one ChatGPT or Chrome window to WindowServer Y = −120 points. It holds the window there for about a second and restores its original position. Run each app separately on the main display, with a normal window sufficiently tall to remain partly visible across the top edge.

The runner requires Python 3 and Xcode Command Line Tools. Run as the logged-in user. The transport matches yabai-sb scripting-addition protocol 2.1.45 at commit 9c461d281ce2a63ef08f131cc66684fc4702d66d. It checks the socket owner, Dock peer executable, and protocol version before submitting a move. The observer uses window IDs, bounds and point hit tests. Leave Screen Recording permission off for this test. [Protocol definitions](https://github.com/braun-steven/yabai-sb/blob/9c461d281ce2a63ef08f131cc66684fc4702d66d/osax/common.h) · [Window move implementation](https://github.com/braun-steven/yabai-sb/blob/9c461d281ce2a63ef08f131cc66684fc4702d66d/osax/payload.m#L877-L894)

From the OmniWM repository root, open both apps and list their visible windows.

```sh
python3 Scripts/static-window-move/probe.py
```

Use the current window ID from that list. The script gives you four seconds to bring the target to the front. Keep the window still during the test. Repeat for the other app.

```sh
python3 Scripts/static-window-move/probe.py --window WINDOW_ID
```

A pass requires every one of 20 samples to show the requested position and original width and height. A point in the visible part must still hit the window, and a point in the strip it vacated must stop hitting it. The script prints the observed frames and hit IDs as JSON, checks restoration, and exits with a nonzero status on failure. A missing service or an obstructed baseline means the move was never tested.

Before moving anything, the runner writes a recovery journal outside the repo. It attempts restoration on failure or interruption. If restoration fails or the process is killed outright, use the journal path printed by that run while the same app window is still open.

```sh
python3 Scripts/static-window-move/probe.py --restore JOURNAL_PATH
```
