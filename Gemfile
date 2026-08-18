source "https://rubygems.org"

# Auf dieselbe Nebenversion festgenagelt wie die anderen Apps, die sich das
# match-Repo teilen: match verschluesselt versionsabhaengig, und ein aelteres
# fastlane scheitert an einem von einem neueren geschriebenen Repo mit einem
# irrefuehrenden "Invalid password".
gem "fastlane", "~> 2.235"

# apply_project_settings schreibt Signierung und Version in das erzeugte
# Xcode-Projekt. fastlane bringt xcodeproj selbst mit, aber nur als
# Abhaengigkeit -- hier wird es direkt benutzt, also steht es auch hier.
gem "xcodeproj"
