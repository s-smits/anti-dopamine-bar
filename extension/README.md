# Socials only in Socials

A browser extension that blocks social media and YouTube unless Anti-Dopamine Dock is in its gated mode
(Socials). The dock answers `http://127.0.0.1:47391/mode?browser=<name>` with the current mode and
the sites to block: the config's `socialSites`, or the list in `modeserver.swift`. Outside Socials
a page on one of them goes to a short notice and comes back by itself once you switch to Socials.
With the dock not running, nothing is blocked.

One source, two manifests: `manifest.json` for Chromium browsers (Brave, Chrome, Edge, Arc) and
`manifest.firefox.json` for Firefox. `build.sh` puts each into the app, and the app copies them to
`~/.config/workspace-bar/extensions/{chromium,firefox}`; load the extension from there (see the
main README) so a rebuild of the app updates it in place. After an update, press the extension's
reload button on the browser's extensions page.

The extension names its browser in each request (Firefox, Brave, otherwise Chrome), so each is
its own add-in in the dock's menu.
