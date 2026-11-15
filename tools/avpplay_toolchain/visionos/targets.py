#!/usr/bin/env python3
"""The targets this toolchain builds, in the shape AVP Play reads (it parses TARGETS with `ast`, plain strings only,
and calls `targets.py <target> <key>` for single values).

    targets.py jkxr-outcast kind      jkxr
    targets.py jkxr-outcast game      outcast
    targets.py jkxr-outcast bundle    <user>.dev.klepton.target.jkxr-outcast   (AVP Play's default naming)

`kind` "jkxr" tells AVP Play that this is not a Klepton (Android or Linux) target: JKXR is an open-source engine,
compiled from this repository for visionOS on the player's Mac.

Two targets, one per game, so that two recipes – two tiles in AVP Play – make two apps: someone who owns only one
of the games can still install it. Both are built from the same checkout, so the engines are compiled once; `game`
is burnt into the app (Info.plist JKXRGame), which then starts straight into that game. The TestFlight build
leaves it empty and carries both.

There is no `devicetree`: the games' data are not a tree this toolchain copies. They are the recipe's data trees,
which AVP Play fetches from the player's own Steam purchases and copies to Documents/JediOutcast and
Documents/JediAcademy itself (Installer.swift, stageDataTrees) – the folders the app has always read.

There is no `saves` either, because nothing would read it: AVP Play backs up saved games from one fixed place,
Documents/android-files (Saves.swift, SaveRules.root), and the games keep theirs under Library/Application
Support/OpenJO (Outcast) and .../OpenJA (Academy). Naming the folder here would suggest a backup that does not
happen.

Runs with the Python that comes with Xcode (3.9).
"""
import getpass
import re
import sys

TARGETS = {
    "jkxr-outcast": {
        "kind": "jkxr",
        "display": "Jedi Outcast",
        "game": "outcast",
    },
    "jkxr-academy": {
        "kind": "jkxr",
        "display": "Jedi Academy",
        "game": "academy",
    },
}


def bundle_scope(user):
    """The user name as AVP Play puts it in front of a bundle id (BundleNaming.swift, bundleScope)."""
    return re.sub(r"[^A-Za-z0-9-]", "-", user).strip("-").lower()


def bundle_for(target, user=None):
    scope = bundle_scope(user or getpass.getuser())
    return ".".join(p for p in (scope, "dev.klepton.target", target) if p)


def resolve(target):
    if target not in TARGETS:
        raise KeyError(target)
    row = dict(TARGETS[target], name=target)
    row["bundle"] = bundle_for(target)
    return row


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        row = resolve(argv[1])
    except KeyError:
        return 1
    value = row.get(argv[2])
    if not isinstance(value, str) or not value:
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
