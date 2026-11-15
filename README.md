# JKXR for Apple Vision Pro

A native visionOS port of [JKXR](https://github.com/Team-Beef-Studios/JKXR) by Team Beef – the open-source engine,
based on [OpenJK](https://github.com/JACoders/OpenJK), that brings two first-person action classics of the early
2000s (SW:JK) to virtual reality. This fork takes it to Apple Vision Pro as a fully immersive app: not a window you
look at, but a world you stand in.

> **No game files are included.** This is an engine port. To play, you need your own copies of *Jedi Outcast*
> and/or *Jedi Academy*, for example from Steam. The app tells you exactly which files it is missing.

For Meta Quest, Pico and PC VR, use [Team Beef's original](https://github.com/Team-Beef-Studios/JKXR).

## What this fork adds

- **A native visionOS app.** Rendered per eye through Compositor Services from the live head pose, foveated, at the
  device's full resolution rather than into a downscaled buffer.
- **Both games in one app**, chosen in the launcher window.
- **PlayStation VR2 Sense controllers**, each tracked on its own with position, orientation and handedness. A
  standard game controller works as well; then you aim by looking.
- **Room-scale play.** Aim by pointing, lean around corners, duck under things that are really above you. The melee
  weapon follows your hand one to one.
- **Menus, briefings and cut-scenes** sit on a panel anchored in the room instead of being pinned to your face, and
  reappear in front of you whenever you open them.
- **Rendering on Metal.** The engine's OpenGL is translated through [gl4es](https://github.com/ptitSeb/gl4es) and
  [ANGLE](https://chromium.googlesource.com/angle/angle).

## Game files

Copy the original data files from your installation into the app's folder, using the Files app on the headset:

| Game | Files | Folder in the app |
|---|---|---|
| Jedi Outcast | `assets0.pk3`, `assets1.pk3`, `assets2.pk3`, `assets5.pk3` | `JediOutcast/base` |
| Jedi Academy | `assets0.pk3` … `assets3.pk3` | `JediAcademy/base` |

The launcher window shows for each game whether its files are complete.

## Building

You need a Mac with Xcode and the visionOS SDK (visionOS 26.4 or later on the device), and two tools from Homebrew:

```sh
brew install cmake xcodegen
```

Set your own development team in `visionos/App/project.yml` (`DEVELOPMENT_TEAM`), then:

```sh
./prepare-visionos.sh
```

This builds gl4es, the engines for both games, the partially linked objects the app is made from, and the Xcode
project. The first run takes about 45 minutes. Open `visionos/App/JKXR.xcodeproj` afterwards and run it on your
Vision Pro.

**After changing engine code**, rebuild in this order:

```sh
cmake --build visionos/build
./link-visionos.sh
```

and only then build the app in Xcode. The app links the objects that `link-visionos.sh` produces, not the
libraries `cmake` builds – skip that step and Xcode still reports success, with the old engine inside.

## Credits

This fork:

- visionOS port: Marcel Wlotzka

JKXR, from Team Beef's original:

- Team Beef are DrBeef, Baggyg, Bummser
- Lead programmer: DrBeef
- JKXR Companion App: BaggyG
- Additional development contributions: MuadDib, BaggyG
- VR-compatible weapon models: Vince Crusty and Elin
- VR-compatible hand models: LennyGuy20

With special thanks to Team Beef's patrons and Discord members, the OpenJK development team, and Raven Software
for creating these games and releasing their engine source.

## Licence

GPLv2, like JKXR and OpenJK – see [LICENSE.txt](LICENSE.txt).

## Disclaimer

THIS ENGINE PORT IS NOT MADE, DISTRIBUTED, OR SUPPORTED BY ACTIVISION PUBLISHING, INC., RAVEN SOFTWARE, OR LUCASARTS ENTERTAINMENT COMPANY, LLC. ELEMENTS™ & © LUCASFILM LTD.™ & DISNEY, INC.™ AND/OR ITS LICENSORS. STAR WARS®, JEDI®, & JEDI KNIGHT® ARE REGISTERED TRADEMARKS OF LUCASFILM LTD™ AND WALT DISNEY, INC.™ STAR WARS®, JEDI®, & JEDI KNIGHT® ARE REGISTERED TRADEMARKS OF LUCASFILM LTD™ & DISNEY, INC.™
