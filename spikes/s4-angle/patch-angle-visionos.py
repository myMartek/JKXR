#!/usr/bin/env python3
"""Lehrt Chromiums Build-System (in ANGLEs Checkout) visionOS als Zielplattform.

Chromiums //build kennt visionOS nicht — `grep -ri xros build/config/` liefert
nichts. Es ist aber bereits über iOS hinaus verallgemeinert: neben "iphoneos"
existiert "tvos" als `target_platform`. visionOS lässt sich deshalb als weiterer
Zweig derselben Struktur ergänzen, statt einen Sonderweg zu bauen.

Betroffen sind fünf Dateien, jeweils an der Stelle, an der schon zwischen
iphoneos und tvos unterschieden wird. Aufruf:

    python3 patch-angle-visionos.py angle/

Das Skript ist idempotent — bereits gepatchte Stellen werden übersprungen.
"""

import sys
from pathlib import Path

# (Datei, Suchtext, Ersatztext, Beschreibung)
PATCHES = [
    (
        "build/config/apple/mobile_config.gni",
        """    _target_platforms += [
      "iphoneos",
      "tvos",
    ]""",
        """    _target_platforms += [
      "iphoneos",
      "tvos",
      "xros",
    ]""",
        "xros als gültige target_platform zulassen",
    ),
    (
        "build/config/ios/ios_sdk.gni",
        """  } else if (target_platform == "tvos") {
    if (target_environment == "simulator") {
      ios_sdk_name = "appletvsimulator"
      ios_sdk_platform = "AppleTVSimulator"
    } else if (target_environment == "device") {
      ios_sdk_name = "appletvos"
      ios_sdk_platform = "AppleTVOS"
    } else {
      assert(false, "unsupported target_environment=$target_environment")
    }
  } else {""",
        """  } else if (target_platform == "tvos") {
    if (target_environment == "simulator") {
      ios_sdk_name = "appletvsimulator"
      ios_sdk_platform = "AppleTVSimulator"
    } else if (target_environment == "device") {
      ios_sdk_name = "appletvos"
      ios_sdk_platform = "AppleTVOS"
    } else {
      assert(false, "unsupported target_environment=$target_environment")
    }
  } else if (target_platform == "xros") {
    if (target_environment == "simulator") {
      ios_sdk_name = "xrsimulator"
      ios_sdk_platform = "XRSimulator"
    } else if (target_environment == "device") {
      ios_sdk_name = "xros"
      ios_sdk_platform = "XROS"
    } else {
      assert(false, "unsupported target_environment=$target_environment")
    }
  } else {""",
        "SDK-Namen für xros/xrsimulator auswählen",
    ),
    (
        "build/config/ios/BUILD.gn",
        """  } else if (target_platform == "tvos") {
    triplet_os = "apple-tvos"
  }""",
        """  } else if (target_platform == "tvos") {
    triplet_os = "apple-tvos"
  } else if (target_platform == "xros") {
    triplet_os = "apple-xros"
  }""",
        "Clang-Triple arm64-apple-xros<version> erzeugen",
    ),
    (
        "build/config/ios/rules.gni",
        """    } else if (target_platform == "tvos") {
      _build_info_plist = "//build/config/tvos/BuildInfo.plist"
    }""",
        """    } else if (target_platform == "tvos") {
      _build_info_plist = "//build/config/tvos/BuildInfo.plist"
    } else if (target_platform == "xros") {
      # Kein eigenes BuildInfo.plist für xros vorhanden; das iOS-Template
      # enthält nur SDK-/Xcode-Metadaten und passt unverändert.
      _build_info_plist = "//build/config/ios/BuildInfo.plist"
    }""",
        "BuildInfo.plist für xros auf das iOS-Template zeigen lassen",
    ),
    (
        "build/config/clang/BUILD.gn",
        """    if (target_platform == "iphoneos") {
      if (target_environment == "simulator") {
        libname = "iossim"
      } else if (target_environment == "device") {
        libname = "ios"
      } else if (target_environment == "catalyst") {
        libname = "osx\"""",
        """    if (target_platform == "xros") {
      # Clang liefert keine eigenen Sanitizer-Runtimes für xros; die
      # iOS-Varianten sind ABI-kompatibel. Nur relevant, wenn Sanitizer
      # aktiviert werden — für den ANGLE-Build ist das nicht der Fall.
      if (target_environment == "simulator") {
        libname = "iossim"
      } else {
        libname = "ios"
      }
    } else if (target_platform == "iphoneos") {
      if (target_environment == "simulator") {
        libname = "iossim"
      } else if (target_environment == "device") {
        libname = "ios"
      } else if (target_environment == "catalyst") {
        libname = "osx\"""",
        "Sanitizer-Runtime-Namen für xros abbilden",
    ),
    (
        "build/config/rust.gni",
        """  } else if (current_cpu == "arm64") {
    if (target_platform == "iphoneos") {""",
        """  } else if (current_cpu == "arm64") {
    if (target_platform == "xros") {
      # ANGLE baut ohne Rust; der Zweig existiert nur, damit die Datei nicht
      # beim Auswerten über eine unbekannte Plattform stolpert.
      if (target_environment == "simulator") {
        rust_abi_target = "aarch64-apple-visionos-sim"
      } else {
        rust_abi_target = "aarch64-apple-visionos"
      }
    } else if (target_platform == "iphoneos") {""",
        "Rust-ABI-Target für xros ergänzen",
    ),
    (
        "build/config/apple/sdk_info.py",
        """                          'watchos',
                          'watchsimulator',
                      ])""",
        """                          'watchos',
                          'watchsimulator',
                          'xros',
                          'xrsimulator',
                      ])""",
        "xros/xrsimulator in der Plattform-Allowlist von sdk_info.py zulassen",
    ),
    (
        "build/config/apple/codesign.py",
        """    if platform in ('appletvos', 'appletvsimulator'):
      return 'tvos'
    raise ValueError""",
        """    if platform in ('appletvos', 'appletvsimulator'):
      return 'tvos'
    if platform in ('xros', 'xrsimulator'):
      # visionOS-Bundles verhalten sich beim Signieren wie iOS-Bundles;
      # die Unterscheidung steuert nur das Info.plist-Layout.
      return 'ios'
    raise ValueError""",
        "Bundle-Typ für xros in codesign.py bestimmen",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Aufruf: {sys.argv[0]} <pfad-zum-angle-checkout>")
        return 2

    root = Path(sys.argv[1])
    if not (root / "build" / "config").is_dir():
        print(f"FEHLER: {root} sieht nicht nach einem ANGLE-Checkout aus")
        return 1

    applied = skipped = failed = 0

    for rel, needle, replacement, description in PATCHES:
        path = root / rel
        if not path.is_file():
            print(f"  FEHLT   {rel} — Datei nicht gefunden")
            failed += 1
            continue

        text = path.read_text()

        if replacement in text:
            print(f"  bereits {rel}: {description}")
            skipped += 1
            continue

        if needle not in text:
            print(f"  FEHLER  {rel}: Suchtext nicht gefunden ({description})")
            print("          Vermutlich hat sich Chromiums //build geändert.")
            failed += 1
            continue

        path.write_text(text.replace(needle, replacement, 1))
        print(f"  ok      {rel}: {description}")
        applied += 1

    print(f"\n{applied} angewandt, {skipped} bereits vorhanden, {failed} fehlgeschlagen")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
