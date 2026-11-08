# Anti-Dopamine Dock

![The Anti-Dopamine Dock in 30 seconds](docs/demo.gif)

<sub>[The same video as an MP4](docs/demo.mp4), sharper.</sub>

A small dock for macOS that keeps the apps you work in apart from the apps built to hold your
attention. You sort your apps into modes. Switching modes hides one set of apps and brings back the
other, all at once.

Feeds and video sites are easy to open and hard to close. So the third mode, Socials, is not free:
during a focus round you have to wait for it. On a break it opens right away. The dock has no
streaks, badges or rewards of its own, because those would hook you too. It is a fairly *nuchter*
piece of software: sober, practical, and not out to entertain you.

## Install

You need macOS 14 or later and Apple's command line tools (`xcode-select --install`). Then, in this
folder:

```sh
./build.sh
```

This builds the app, puts it in `~/Applications` and starts it now and at every login. The first
time it runs, macOS asks for **Accessibility** access (System Settings, Privacy & Security). The
dock needs it to hide, show and focus windows, and for its keyboard shortcuts.

Build the app yourself rather than running a copy someone sends you.

## Using it

**Modes.** There are three to start with: Profile 1, Profile 2 and Socials. Click one to switch.
An app you open joins the mode you are in. Right-click an app's icon to move it to another mode, or
to keep it in every mode. Browsers are in every mode from the start, and the browser extension
(below) keeps social sites to Socials.

**Cards.** Hover over a mode to see its top five apps, and click one to open it there.

**The timer.** Click it to start a 25-minute focus round. Click it again to pause, and once more to
resume. Breaks are 5 minutes, with a longer one after every fourth round and a lunch break after the
eighth. Right-click the timer to skip ahead, reset it, or start the day over.

**Socials.** On a break, or with the timer paused, Socials opens at once. When the break ends you go
back to where you were. During a focus round:

- The first three clicks on Socials only warn you.
- The fourth starts a wait that lasts until the break.
- Every click after that cuts the wait by 20%. Stop clicking for 5 seconds and the full wait comes
  back.
- If you just left Socials, you can go back within 5 seconds without waiting.
- An app you pick from Socials' card in the last minute of the wait shows beside the countdown, and
  opens by itself when the wait is over.

**The dock itself.** Drag it to move it, and double-click an empty spot to centre it again.
Right-click it for the menu: settings, add-ins, size, and quit.

## Add-ins

Turn these on and off under **Add-ins** in the dock's menu. Only the ones for apps you have
installed are listed.

- **Cmd-Tab for this mode only**: a switcher that lists only the current mode's apps.
- **Option-1 to 3**: switch modes from the keyboard.
- **Raycast**: Raycast leaves out Socials' apps unless you are in Socials.
- **Rectangle**: Rectangle's window layouts leave room for the dock.
- **Brave, Chrome, Firefox**: the browser extension blocks social sites in that browser.
- **Custom hooks**: run your own scripts on every switch. Choose **Open Hooks Folder** in the menu;
  `example.sh.off` there shows how. For safety, a script runs only if you own it and no one else
  can change it.

Turning an add-in off puts things back the way they were.

## The browser extension

The extension keeps social media and YouTube closed unless Socials is open (you are in Socials, on
a break, or the timer is paused). A blocked page comes back by itself as soon as it is. If the dock
is not running, nothing is blocked.

To install it, choose **Add-ins > Show Browser Extension Folder** in the dock's menu, then:

- **Brave, Chrome, Edge, Arc**: on the browser's extensions page, turn on Developer mode, choose
  **Load unpacked** and pick the `chromium` folder.
- **Firefox**: in `about:debugging`, choose **This Firefox**, then **Load Temporary Add-on**, and
  pick `firefox/manifest.json`. It lasts until Firefox restarts.

## Settings

Choose **Edit Config…** in the dock's menu, then **Reload Config** when you are done. There you can:

- rename the modes and change their icons, colours and apps;
- change the length of focus rounds and breaks (`pomodoro`);
- change which sites the extension blocks (`socialSites`).

## If something is off

- The log is `~/Library/Logs/workspace-bar.log`, and your hooks' output is in
  `workspace-bar-hooks.log` beside it.
- Mode-only Cmd-Tab and window focusing use macOS features Apple does not document, as AltTab does.
  If a macOS update removes them, only those two features stop working.
- With Raycast 2, macOS asks once to let the Raycast add-in read Raycast's settings.

## For developers

- `./build.sh --no-install` only builds the app and the extension zips into `build/`.
- `tests/run.sh` runs the tests. `tests/sweep.md` lists what is checked by hand before a release.

## Licence

GPL-3.0, see `LICENSE`. The window focusing in `main.swift` follows
[AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0) by lwouis and contributors.
