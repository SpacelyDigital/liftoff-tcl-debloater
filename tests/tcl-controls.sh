#!/usr/bin/env bash
# Supporting CLI regression checks. Every ADB call goes to a disposable local fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/liftoff-tcl-controls.XXXXXX")"
FIXTURE="$(cd "$FIXTURE" && pwd)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/repo/scripts" "$FIXTURE/repo/catalog" \
  "$FIXTURE/repo/state/test-tv/backup-fixture"
cp "$ROOT"/scripts/{lib,debloat,cleanup-list,tweaks,settings-button}.sh "$FIXTURE/repo/scripts/"
cp "$ROOT/catalog/debloat.tsv" "$FIXTURE/repo/catalog/debloat.tsv"

export FAKE_ADB_ROOT="$FIXTURE"
export PATH="$FIXTURE/bin:$PATH"
export TV=fixture.invalid:5555
export LIFTOFF_CONFIG="$FIXTURE/repo/liftoff.json"
cat > "$FIXTURE/bin/adb" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path
import sys

root = Path(os.environ["FAKE_ADB_ROOT"])
args = sys.argv[1:]
if args == ["connect", "fixture.invalid:5555"]:
    sys.exit(0)
if args[:2] != ["-s", "fixture.invalid:5555"]:
    sys.exit("Unexpected fake ADB target")
args = args[2:]
if args == ["get-state"]:
    print("device")
    sys.exit(0)
if args == ["install", "-r", "--no-incremental", "--user", "0",
            str(root / "repo/build/settings-button/LiftoffSettingsButton.apk")]:
    if not Path(args[-1]).is_file():
        sys.exit("The helper build did not create an APK")
    with (root / "adb.log").open("a") as log:
        log.write(" ".join(args) + "\n")
    installed_file = root / "installed.txt"
    if "app.liftoff.settingsbutton" not in installed_file.read_text().splitlines():
        with installed_file.open("a") as output:
            output.write("app.liftoff.settingsbutton\n")
    print("Success")
    sys.exit(0)
if not args or args[0] != "shell":
    sys.exit("Unexpected fake ADB operation")
args = args[1:]
with (root / "adb.log").open("a") as log:
    log.write(" ".join(args) + "\n")
disabled_file = root / "disabled.txt"
disabled = disabled_file.read_text().splitlines()
if args == ["getprop", "ro.serialno"]:
    print("test-tv")
elif args == ["getprop", "ro.build.version.sdk"]:
    print((root / "sdk.txt").read_text().strip())
elif args[:3] == ["pm", "list", "packages"]:
    packages = (root / "installed.txt").read_text().splitlines()
    options = args[3:]
    if "--user" in options:
        index = options.index("--user")
        if options[index + 1] != "0":
            sys.exit("Unexpected fake ADB user")
        del options[index:index + 2]
    if "-d" in options:
        packages = disabled
    elif "-e" in options:
        packages = [package for package in packages if package not in disabled]
    filters = [option for option in options if not option.startswith("-")]
    for package in packages:
        if not filters or filters[0] in package:
            print("package:" + package)
elif args[:4] == ["pm", "disable-user", "--user", "0"] and len(args) == 5:
    package = args[4]
    if package not in disabled:
        with disabled_file.open("a") as output:
            output.write(package + "\n")
    print("Package " + package + " new state: disabled-user")
elif args[:3] == ["cmd", "package", "resolve-activity"]:
    print("app.liftoff.home/.HomeActivity")
elif args[:3] == ["cmd", "appops", "get"]:
    print("RUN_ANY_IN_BACKGROUND: allow")
elif args[:3] == ["cmd", "appops", "set"]:
    pass
elif args == ["am", "start", "--user", "0", "-n",
              "app.liftoff.settingsbutton/.SetupActivity"]:
    pass
elif args == ["settings", "--user", "0", "get", "secure", "enabled_accessibility_services"]:
    print((root / "accessibility-services.txt").read_text().strip())
elif args == ["dumpsys", "accessibility"]:
    print((root / "accessibility-dump.txt").read_text())
elif args == ["pm", "uninstall", "--user", "0", "app.liftoff.settingsbutton"]:
    installed_file = root / "installed.txt"
    packages = installed_file.read_text().splitlines()
    packages.remove("app.liftoff.settingsbutton")
    installed_file.write_text("\n".join(packages) + "\n")
    print("Success")
else:
    sys.exit("Unexpected fake ADB command: " + " ".join(args))
PY
chmod +x "$FIXTURE/bin/adb"
[ "$(command -v adb)" = "$FIXTURE/bin/adb" ]
cat > "$FIXTURE/installed.txt" <<'EOF'
com.tcl.gamebar
app.liftoff.settingsbutton
com.tcl.suspension
com.tcl.settings
com.google.android.apps.tv.launcherx
com.tcl.messagebox
org.example.ordinary
EOF
: > "$FIXTURE/disabled.txt"
: > "$FIXTURE/adb.log"
cat > "$LIFTOFF_CONFIG" <<'JSON'
{
  "apps": [],
  "tweaks": {
    "noBackground": [
      "com.tcl.gamebar", "app.liftoff.settingsbutton", "com.tcl.suspension",
      "com.tcl.settings", "com.tcl.messagebox", "org.example.ordinary"
    ]
  }
}
JSON

# Include a complete backup so this fixture also works with stricter backup validation.
BACKUP="$FIXTURE/repo/state/test-tv/backup-fixture"
printf '%s\n' 'Fixture TCL TV' > "$BACKUP/device.txt"
sed 's/^/package:/' "$FIXTURE/installed.txt" > "$BACKUP/packages-all.txt"
printf '%s\n' 'app.liftoff.home/.HomeActivity' > "$BACKUP/home.txt"
for name in packages-disabled packages-user settings-global settings-secure settings-system; do
  : > "$BACKUP/$name.txt"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fqx -- "$2" "$1" || fail "Missing expected line: $2"; }
excludes() { ! grep -Fq -- "$2" "$1" || fail "Unexpected text: $2"; }

PROTECTED=(com.tcl.gamebar app.liftoff.settingsbutton com.tcl.suspension com.tcl.settings)
LEDGER="$FIXTURE/repo/state/test-tv/disabled.txt"
bash "$FIXTURE/repo/scripts/debloat.sh" "${PROTECTED[@]}" \
  com.google.android.apps.tv.launcherx com.tcl.messagebox org.example.ordinary \
  > "$FIXTURE/debloat.out" 2>&1
contains "$LEDGER" com.tcl.messagebox
contains "$LEDGER" org.example.ordinary
excludes "$LEDGER" com.google.android.apps.tv.launcherx
excludes "$FIXTURE/adb.log" 'pm disable-user --user 0 com.google.android.apps.tv.launcherx'
for package in "${PROTECTED[@]}"; do
  excludes "$LEDGER" "$package"
  excludes "$FIXTURE/adb.log" "pm disable-user --user 0 $package"
done

bash "$FIXTURE/repo/scripts/debloat.sh" --risky "${PROTECTED[@]}" \
  com.google.android.apps.tv.launcherx com.tcl.messagebox \
  > "$FIXTURE/risky.out" 2>&1
contains "$LEDGER" com.google.android.apps.tv.launcherx
contains "$FIXTURE/adb.log" 'pm disable-user --user 0 com.google.android.apps.tv.launcherx'
[ "$(wc -l < "$LEDGER" | tr -d ' ')" = 3 ] || fail 'Unexpected disable ledger entries'
for package in "${PROTECTED[@]}"; do
  excludes "$FIXTURE/adb.log" "pm disable-user --user 0 $package"
done

bash "$FIXTURE/repo/scripts/tweaks.sh" > "$FIXTURE/tweaks.out" 2>&1
APP_OPS="$FIXTURE/repo/state/test-tv/appops.tsv"
for package in "${PROTECTED[@]}"; do
  excludes "$APP_OPS" "$package"
  excludes "$FIXTURE/adb.log" "cmd appops set $package "
done
for package in com.tcl.messagebox org.example.ordinary; do
  contains "$FIXTURE/adb.log" "cmd appops set $package RUN_ANY_IN_BACKGROUND ignore"
  contains "$APP_OPS" "$(printf '%s\tRUN_ANY_IN_BACKGROUND\tallow' "$package")"
done

# Exercise protected entries in both the catalog and the updated-app fallback list.
: > "$FIXTURE/disabled.txt"
python3 - "$FIXTURE/repo/catalog/debloat.tsv" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
protected = {"com.tcl.gamebar", "app.liftoff.settingsbutton", "com.tcl.suspension", "com.tcl.settings"}
rows = [row for row in path.read_text().splitlines() if row.split("\t")[0] not in protected]
path.write_text("\n".join(rows) + "\n")
PY
bash "$FIXTURE/repo/scripts/cleanup-list.sh" > "$FIXTURE/cleanup-fallback.out"
for package in "${PROTECTED[@]}"; do
  excludes "$FIXTURE/cleanup-fallback.out" "$package"
  printf '%s\tFixture control\tfixture\tsafe\tFixture control\n' "$package" \
    >> "$FIXTURE/repo/catalog/debloat.tsv"
done
contains "$FIXTURE/cleanup-fallback.out" '  org.example.ordinary'
grep -Fq com.tcl.messagebox "$FIXTURE/cleanup-fallback.out" || fail 'Ordinary catalog app omitted'
bash "$FIXTURE/repo/scripts/cleanup-list.sh" > "$FIXTURE/cleanup-catalog.out"
for package in "${PROTECTED[@]}"; do
  excludes "$FIXTURE/cleanup-catalog.out" "$package"
done
contains "$FIXTURE/cleanup-catalog.out" '  org.example.ordinary'
grep -Fq com.tcl.messagebox "$FIXTURE/cleanup-catalog.out" || fail 'Ordinary catalog app omitted'

# Stub only compilation. Installer, status and removal still use the real helper CLI.
cat > "$FIXTURE/repo/scripts/build.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" = 1 ] && [ "$1" = --settings-button ]
printf '%s\n' "$1" >> "$FAKE_ADB_ROOT/build.log"
mkdir -p "$FAKE_ADB_ROOT/repo/build/settings-button"
: > "$FAKE_ADB_ROOT/repo/build/settings-button/LiftoffSettingsButton.apk"
SH
chmod +x "$FIXTURE/repo/scripts/build.sh"
: > "$FIXTURE/build.log"
: > "$FIXTURE/adb.log"
HELPER=app.liftoff.settingsbutton
HELPER_CLI="$FIXTURE/repo/scripts/settings-button.sh"
grep -Fvx "$HELPER" "$FIXTURE/installed.txt" > "$FIXTURE/without-helper.txt"
mv "$FIXTURE/without-helper.txt" "$FIXTURE/installed.txt"
bash "$HELPER_CLI" status > "$FIXTURE/helper-before-install.out" 2>&1
grep -Fq 'is not installed on this TV' "$FIXTURE/helper-before-install.out" || fail 'Missing helper reported as installed'
printf '%s\n' 29 > "$FIXTURE/sdk.txt"
if bash "$HELPER_CLI" install > "$FIXTURE/unsupported.out" 2>&1; then
  fail 'Helper installation accepted Android 10'
fi
grep -Fq 'requires Android TV 11' "$FIXTURE/unsupported.out" || fail 'Missing Android version explanation'
[ ! -s "$FIXTURE/build.log" ] || fail 'Unsupported TV reached the builder'
excludes "$FIXTURE/adb.log" 'install -r '

printf '%s\n' 30 > "$FIXTURE/sdk.txt"
printf '%s\n' com.tcl.settings > "$FIXTURE/disabled.txt"
if bash "$HELPER_CLI" install > "$FIXTURE/no-tcl-settings.out" 2>&1; then
  fail 'Helper installation accepted unavailable TCL Settings'
fi
grep -Fq 'TCL Settings is unavailable' "$FIXTURE/no-tcl-settings.out" || fail 'Missing TCL Settings explanation'
[ ! -s "$FIXTURE/build.log" ] || fail 'Unavailable TCL Settings reached the builder'
excludes "$FIXTURE/adb.log" 'install -r '

: > "$FIXTURE/disabled.txt"
bash "$HELPER_CLI" install > "$FIXTURE/helper-install.out" 2>&1
contains "$FIXTURE/installed.txt" "$HELPER"
contains "$FIXTURE/build.log" --settings-button
[ "$(wc -l < "$FIXTURE/build.log" | tr -d ' ')" = 1 ] || fail 'Unexpected helper build count'
contains "$FIXTURE/adb.log" "install -r --no-incremental --user 0 $FIXTURE/repo/build/settings-button/LiftoffSettingsButton.apk"
contains "$FIXTURE/adb.log" "cmd appops set $HELPER APP_AUTO_START allow"
contains "$FIXTURE/adb.log" "am start --user 0 -n $HELPER/.SetupActivity"
grep -Fq 'Enable Liftoff Settings Button under Accessibility' "$FIXTURE/helper-install.out" || fail 'Missing manual enable instruction'

printf '%s\n' null > "$FIXTURE/accessibility-services.txt"
: > "$FIXTURE/accessibility-dump.txt"
bash "$HELPER_CLI" status > "$FIXTURE/helper-disabled.out" 2>&1
grep -Fq 'Installed. Enable Liftoff Settings Button' "$FIXTURE/helper-disabled.out" || fail 'Installed helper reported as enabled'
excludes "$FIXTURE/helper-disabled.out" 'is running.'
printf '%s\n' "$HELPER/.SettingsButtonServiceExtra" > "$FIXTURE/accessibility-services.txt"
bash "$HELPER_CLI" status > "$FIXTURE/helper-similar-name.out" 2>&1
grep -Fq 'Installed. Enable Liftoff Settings Button' "$FIXTURE/helper-similar-name.out" || fail 'Similar service name matched the helper'

for component in "$HELPER/.SettingsButtonService" "$HELPER/$HELPER.SettingsButtonService"; do
  printf '%s\n' "org.example.accessibility/.Service:$component" > "$FIXTURE/accessibility-services.txt"
  printf '%s\n' 'Enabled services: [{label=Liftoff Settings Button,}]' \
    'Bound services: [{label=Another Service,}]' > "$FIXTURE/accessibility-dump.txt"
  bash "$HELPER_CLI" status > "$FIXTURE/helper-unbound.out" 2>&1
  grep -Fq 'enabled, but it is not running' "$FIXTURE/helper-unbound.out" || fail 'Enabled helper reported as bound'
  excludes "$FIXTURE/helper-unbound.out" 'is running.'

  printf '%s\n' 'Bound services: [{label=Liftoff Settings Button,}]' > "$FIXTURE/accessibility-dump.txt"
  bash "$HELPER_CLI" status > "$FIXTURE/helper-bound.out" 2>&1
  grep -Fq 'Liftoff Settings Button is running.' "$FIXTURE/helper-bound.out" || fail 'Bound helper reported as stopped'
done
excludes "$FIXTURE/adb.log" 'cmd package set-home-activity'
excludes "$FIXTURE/adb.log" 'settings --user 0 put secure'
excludes "$FIXTURE/adb.log" 'settings put secure'

# Removal must target exactly this package, preserve other apps and issue no accessibility writes.
printf '%s\n' app.liftoff.settingsbutton.extra >> "$FIXTURE/installed.txt"
cp "$FIXTURE/accessibility-services.txt" "$FIXTURE/accessibility-before.txt"
: > "$FIXTURE/adb.log"
bash "$HELPER_CLI" remove > "$FIXTURE/helper-remove.out" 2>&1
contains "$FIXTURE/adb.log" "pm uninstall --user 0 $HELPER"
if grep -Fqx "$HELPER" "$FIXTURE/installed.txt"; then fail 'Helper remained installed'; fi
contains "$FIXTURE/installed.txt" app.liftoff.settingsbutton.extra
contains "$FIXTURE/installed.txt" com.tcl.settings
contains "$FIXTURE/installed.txt" org.example.ordinary
cmp "$FIXTURE/accessibility-before.txt" "$FIXTURE/accessibility-services.txt"
bash "$HELPER_CLI" status > "$FIXTURE/helper-missing.out" 2>&1
grep -Fq 'is not installed on this TV' "$FIXTURE/helper-missing.out" || fail 'Missing helper reported as installed'
bash "$HELPER_CLI" remove > "$FIXTURE/helper-remove-again.out" 2>&1
[ "$(grep -Fc "pm uninstall --user 0 $HELPER" "$FIXTURE/adb.log")" = 1 ] || fail 'Removal was not precise and idempotent'
excludes "$FIXTURE/adb.log" 'settings --user 0 put secure'
excludes "$FIXTURE/adb.log" 'settings put secure'
excludes "$FIXTURE/adb.log" 'cmd package set-home-activity'

printf '%s\n' 'PASS: protected controls, risky launcher, cleanup, background limits and helper CLI'
