#!/usr/bin/env python3
"""Not a project generator: the app's Xcode project is made by xcodegen from visionos/App/project.yml, as part of
prepare-visionos.sh, which run.sh calls.

AVP Play decides which of its build options a toolchain supports by looking for the option's variable name in this
file (Toolchain.swift, supports...). So this file names exactly the variables run.sh honours, and nothing else:

    KLEPTON_BUNDLE_ID          the app's bundle id
    KLEPTON_APP_VERSION        CFBundleShortVersionString
    KLEPTON_APP_BUILD          CFBundleVersion (AVP Play's stamp: <game build>.<toolchain number>)
    KLEPTON_DISPLAY_OVERRIDE   the app's name on the Home View
    KLEPTON_DISPLAY_SUFFIX     added to the name
    KLEPTON_EVA                AVP Play sets it to 0 for a free Apple team, to leave out the extended-virtual-
                               addressing entitlement. JKXR never asks for that entitlement (nor for any other
                               beyond what every signed app has), so there is nothing to leave out: the value is
                               accepted and changes nothing, and a free team can sign the app.

Deliberately absent, because this app cannot do them (AVP Play then leaves the option out instead of building
something that does not work): the controller presets for other controllers, test switches, the render-scale
preset, the room-measuring default, a game language chosen at build time (both games choose theirs in their own
options), and mods. Add a name here only together with the code in run.sh that honours it – and never mention
one in passing: the check is a plain text search.
"""
import sys

if __name__ == "__main__":
    print(__doc__, file=sys.stderr)
    sys.exit(2)
