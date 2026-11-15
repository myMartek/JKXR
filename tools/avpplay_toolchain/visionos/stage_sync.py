#!/usr/bin/env python3
"""The part of AVP Play's toolchain contract that copies a game's folder trees – which JKXR does not have.

    stage_sync.py --phase all --device <udid> --dry-run    build the mirror, say what it holds
    stage_sync.py --phase all --device <udid>              build the mirror and copy it

AVP Play runs this only for a recipe's trees of the roles `game` and `sysroot` (Installer.swift, stage: `hasTrees`).
JKXR's recipe has neither. What the two games need on the headset are their original data files, and those are the
recipe's trees of the role `data`: AVP Play fetches them from the player's own Steam purchases, checks them against
the recipe's marker files and copies them to Documents/JediOutcast and Documents/JediAcademy itself
(Installer.swift, stageDataTrees). Nothing of the games passes through this toolchain.

So this script keeps the interface and does nothing: a dry run leaves an empty mirror (nothing belongs on the
headset from here), a copy has nothing to copy. It exists so that the contract holds if AVP Play ever calls it, and
so that a reader looking for "where does the game data go" finds the answer here.

Runs with the Python that comes with Xcode (3.9).
"""
import argparse
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phase", choices=("base", "start", "all"), default="all")
    ap.add_argument("--device")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    target = os.environ.get("KLEPTON_TARGET", "jkxr")
    mirror = pathlib.Path(os.environ.get("KL_LX_MIRROR") or HERE / "build" / "lxstage" / target / "lx")
    mirror.mkdir(parents=True, exist_ok=True)

    if args.dry_run:
        print("[stage] dry run - nothing to mirror: JKXR has no game or runtime trees (its game data are the "
              "recipe's data trees, which AVP Play copies itself); the mirror at %s is empty" % mirror)
    else:
        print("[stage] nothing to copy: JKXR's game data are the recipe's data trees, which AVP Play copies itself")
    return 0


if __name__ == "__main__":
    sys.exit(main())
