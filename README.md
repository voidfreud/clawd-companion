# Clawd Companion

A tiny pixel-art Clawd who lives on your Mac's desktop. Clawd walks along the bottom of your screen, climbs onto your windows, naps when you step away, and reacts to what you're doing, all in a see-through overlay that never gets in the way of your clicks.

> Unofficial fan project. Not made by or affiliated with Anthropic.

## What Clawd does

- **Lives on your screen.** Walks, sits, stretches, looks around, dances, and sometimes wanders off one edge of the screen and comes back from the other.
- **Climbs your windows.** Jumps onto window title bars and walks along them. Rides along when you move the window, and falls off when you close it.
- **Notices you.** Says hello when you've gone quiet, falls asleep when you're away, and welcomes you back with how long you were gone. Suggests a stretch after each hour of work. Different lines at night, in the morning and in the evening.
- **Comments on your apps.** Has something to say about code editors, terminals, browsers, chat apps, music (dance break!) and more, without nagging.
- **Sees the interface (optional).** With the Accessibility permission, Clawd covers its eyes at password fields, types along when you type, reacts to error and "save changes?" dialogs, and says "Careful!" when your cursor rests on a Delete button.
- **Has needs.** Food, energy and mood drain slowly. Feed snacks, throw the ball, and pet Clawd to keep it happy. A small thought bubble shows what it wants.

### Controls

- **Click** Clawd to pet it. **Drag** to pick Clawd up and toss it.
- **Right-click** Clawd for snacks, the ball, naps, Stay put, size, colour, and its needs.
- **Menu bar icon** for the same actions, plus Hide, See the Interface, and Open at Login.

## Install

You build Clawd on your own Mac, so macOS trusts it without any security warnings.

**Requirements:** macOS 13 (Ventura) or later, and Apple's free command-line tools. If you don't have the tools yet, install them first:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/voidfreud/clawd-companion.git
cd clawd-companion
./native/build.sh --install
```

This builds `Desk Clawd.app`, copies it to `/Applications` and launches it. Clawd drops in from the top of your screen. There's no Dock icon; look for the little Clawd in your menu bar.

To build without installing (the app lands in `native/build/`):

```bash
./native/build.sh
```

### Let Clawd see the interface (optional)

1. Click the Clawd icon in the menu bar and choose **Let Clawd See the Interface…**
2. In **System Settings → Privacy & Security → Accessibility**, switch **Desk Clawd** on.

Clawd notices within a couple of seconds and says "I can see now!". You can switch it off any time with **See the Interface** in the menu bar menu.

## Privacy

Everything stays on your Mac. Clawd makes no network requests.

- **Without extra permissions,** Clawd uses the positions of your windows (not their contents), the name of the app in front, and how long since your last keypress or mouse movement.
- **With Accessibility on,** Clawd also reads window titles, the kind of field you're focused on, the text of dialogs, and the label of the button under a resting cursor. It only uses these to pick a reaction, and only watches the app in front.
- Nothing is stored except Clawd's own state (needs, size, colour, Stay put).

## Troubleshooting

- **Clawd doesn't walk.** Check that **Stay put** isn't ticked in the menu bar menu or the right-click menu.
- **Clawd stopped reacting to the interface after a rebuild.** Without an Apple Development certificate, each build gets a new ad-hoc signature, and macOS may forget the Accessibility permission. Switch Desk Clawd off and on again in System Settings → Privacy & Security → Accessibility.
- **Clawd isn't on screen.** It may have wandered off for a bit; it comes back within a minute. Or use **Show Clawd** in the menu bar menu.
- **Diagnostic log.** To see what Clawd receives from the system:

  ```bash
  defaults write local.deskclawd debugLog -bool true
  ```

  Relaunch Clawd; the log goes to `~/Library/Logs/DeskClawd.log`. Turn it off with `defaults delete local.deskclawd debugLog`.

## Uninstall

Untick **Open at Login** in the menu bar menu if you turned it on, then:

```bash
osascript -e 'quit app id "local.deskclawd"'
```

```bash
rm -rf "/Applications/Desk Clawd.app" ~/Library/WebKit/local.deskclawd
```

```bash
defaults delete local.deskclawd
```

## How it's built

- [`desk-clawd.html`](desk-clawd.html) is Clawd: drawing, animation, behaviour and speech, in one self-contained page.
- [`native/main.swift`](native/main.swift) is a small macOS host. It shows the page in a transparent, click-through window above your other windows, and passes in what Clawd can know about your desktop: window edges, idle time, the front app and, with permission, the interface.
- [`native/build.sh`](native/build.sh) compiles the host and packages the app.

`desk-clawd.html` also runs on its own as a Claude artifact. There, Clawd walks, eats and plays, but can't see your windows or apps.

## License

All rights reserved. No license is granted for reuse or redistribution of this code.
