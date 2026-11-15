# AVP Play toolchain adapter

This folder lets [AVP Play](https://github.com/myMartek/avp-play), the Mac app that builds and installs VR games
for the Apple Vision Pro, install JKXR: it fetches the games' data from the player's own Steam purchases, builds
the app from this repository on the player's Mac, signs it with their team, installs it and copies the data.

AVP Play couples to a toolchain only through files and environment variables. This folder is such a toolchain, of
its own kind (`jkxr`), as described in AVP Play's `docs/recipes.md` under "A toolchain of the game's own":

| File | What AVP Play does with it | What it does here |
| --- | --- | --- |
| `visionos/run.sh device` | builds and installs; success is exit 0 and the line `BUILD SUCCEEDED` | `prepare-visionos.sh`, then `xcodebuild` with the player's team and bundle id, then `devicectl` |
| `visionos/stage_sync.py` | copies a recipe's game and runtime trees | nothing: JKXR has neither (see below) |
| `visionos/targets.py` | reads the target's row | `jkxr-outcast` and `jkxr-academy`, kind `jkxr` |
| `visionos/gen_xcodeproj.py` | looks for the names of the build options a toolchain supports | names only what `run.sh` honours |
| `toolchain.json` | version, commit, ancestors, kind | written by `make_manifest.py` (git-ignored) |

## Two targets, two apps

One target per game, so that each game is its own tile in AVP Play and its own app on the headset: someone who
owns only one of them installs only that one. Both are built from the same checkout. The target's `game` is
written into the app (`Info.plist`, `JKXRGame`), which then opens on a start card for that game alone; the
picture on that card is the one AVP Play takes from the player's own library and hands to the build. The
TestFlight build leaves `JKXRGame` empty and carries both games, as before.

## The games' data

They never pass through this toolchain. In the recipe they are two trees of the role `data`, one per game, each
with the Steam app, its pinned depot manifest and marker files that identify the right version. AVP Play fetches
them with the player's own Steam sign-in, checks them against the markers, and copies them to
`Documents/JediOutcast/base` and `Documents/JediAcademy/base` – the folders the app has always read, so a player
who copied the files in by hand before finds them in the same place.

The app needs from each installation:

| Game | Steam app | Files |
| --- | --- | --- |
| Jedi Outcast | 6030 | `GameData/base/assets0.pk3`, `assets1.pk3`, `assets2.pk3`, `assets5.pk3` |
| Jedi Academy | 6020 | `GameData/base/assets0.pk3` … `assets3.pk3` |

## Tools

AVP Play runs `run.sh` with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so the build uses only what macOS and Xcode
bring, plus two tools Xcode lacks. Homebrew's are used when they are installed; otherwise each is downloaded once
from its own project's releases and checked against a SHA-256 written in `run.sh`:

- [cmake](https://github.com/Kitware/CMake) 4.3.3 (BSD-3-Clause)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) 2.46.0 (MIT)

Both are kept in `build-visionos/avpplay-tools`, beside the rest of the build.

## Signing

The app asks for no entitlement beyond what every signed app has. A free Apple team can therefore sign it: AVP
Play's switch for free teams, which leaves out extended virtual addressing, is accepted and has nothing to leave
out. Its profiles run out after seven days; AVP Play signs installed games again before that.

## Using a checkout as the toolchain

```sh
python3 tools/avpplay_toolchain/make_manifest.py
avpplay toolchain use jkxr --toolchain "$PWD/tools/avpplay_toolchain"
avpplay install jkxr-outcast --team <team ID>
```

The checkout's path must not contain a blank.
