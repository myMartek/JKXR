# Installing JKXR on Apple Vision Pro

JKXR brings two first-person action classics of the early 2000s, *Jedi Outcast* and *Jedi Academy*, to Apple Vision
Pro as a fully immersive app. **No game files are included:** you bring your own copy of each game you want to
play, for example from Steam.

There are two ways to get the app onto your headset. Both build it from this source on your own Mac.

## What you need

- **Apple Vision Pro** with visionOS 26.4 or later
- **A Mac with Apple silicon** and [Xcode](https://apps.apple.com/app/xcode/id497799835), with its visionOS platform
  installed (Xcode › Settings › Components)
- **An Apple account signed in to Xcode.** The app asks for no special permission, so a free account should do;
  with one, the app runs for seven days and is then installed again.
- **PlayStation VR2 Sense controllers**, paired with the headset. A standard game controller works as well; then
  you aim by looking.
- **Your own copy of the game**:

| Game | Steam app | Files the app needs (in the game's `GameData/base` folder) |
| --- | --- | --- |
| Jedi Outcast | 6030 | `assets0.pk3`, `assets1.pk3`, `assets2.pk3`, `assets5.pk3` |
| Jedi Academy | 6020 | `assets0.pk3`, `assets1.pk3`, `assets2.pk3`, `assets3.pk3` |

## Way 1: with AVP Play (game files fetched for you)

[AVP Play](https://github.com/myMartek/avp-play) is a Mac app that builds and installs VR games for the Vision Pro.
From version 1.10.18 on it knows both games, each as an app of its own:

1. Install AVP Play and go through its **Setup**: Xcode, your Apple team, your Vision Pro, and your **Steam
   sign-in**.
2. Open **Jedi Outcast** or **Jedi Academy** and press **Install**.

AVP Play asks Steam whether your account owns the game, downloads exactly the version it was made for and checks it.
It fetches this repository at a tested commit, builds the app on your Mac (the first build takes about 45 minutes,
later ones are quick), installs it, and copies the game files into the app. The adapter it uses is in
[`tools/avpplay_toolchain`](tools/avpplay_toolchain/README.md).

## Way 2: build it yourself

### 1. Tools

```sh
brew install cmake xcodegen
```

### 2. Your team

Set your own development team in `visionos/App/project.yml` (`DEVELOPMENT_TEAM`), and a bundle identifier of your
own (`PRODUCT_BUNDLE_IDENTIFIER`).

### 3. Build

From the root of your checkout:

```sh
./prepare-visionos.sh
```

This builds gl4es, the engines for both games, the partially linked objects the app is made from, and the Xcode
project. The first run takes about 45 minutes.

### 4. Install

Connect the Vision Pro to Xcode (Window › Devices and Simulators; the headset needs Developer Mode, under
Settings › Privacy & Security). Open `visionos/App/JKXR.xcodeproj`, choose your Vision Pro as the destination and
press Run. This app carries both games; you pick one in its start window.

### 5. Your game files

The app shows which files it is missing. Either:

- **on the headset:** in the app's start window, open **Settings** and choose **Choose files…**, then pick the
  `.pk3` files, for example from iCloud Drive; or
- **with the Files app:** copy the files into the app's folder, `JediOutcast/base` or `JediAcademy/base`.

The files are in your game installation, in `GameData/base`. With Steam on a Mac or PC: right-click the game ›
Manage › Browse local files. Steam's console can also fetch the Windows version on any computer:
`download_depot 6030 6031` (Jedi Outcast) or `download_depot 6020 6021` (Jedi Academy).

## Playing

- **Start:** press **Start** in the app's window.
- **Performance panel:** hold Create and Options together for a second.
- **Optional textures:** the app's **Settings** offer sharper texture packs as an optional download.

After changing engine code yourself, rebuild with `cmake --build visionos/build`, then `./link-visionos.sh`, and
only then build the app in Xcode. The app links the objects `link-visionos.sh` makes, not the libraries `cmake`
builds.
