#!/usr/bin/env bash
# Manage the optional TCL Settings-button helper without changing the TV's Home app.
source "$(dirname "$0")/lib.sh"

case "${1:-status}" in
  install|status|remove) action="${1:-status}" ;;
  *) die "usage: scripts/settings-button.sh [install|status|remove]" ;;
esac

need_tv
PKG=app.liftoff.settingsbutton

installed() {
  local packages
  packages="$(sh_tv pm list packages --user 0 "$PKG")" || die "Cannot read installed packages from the TV."
  grep -Fxq "package:$PKG" <<<"$packages"
}

case "$action" in
  install)
    sdk="$(sh_tv getprop ro.build.version.sdk)"
    [[ "$sdk" =~ ^[0-9]+$ ]] && [ "$sdk" -ge 30 ] || die "The helper requires Android TV 11 or newer."
    sh_tv pm list packages --user 0 -e com.tcl.settings | grep -Fx 'package:com.tcl.settings' >/dev/null ||
      die "TCL Settings is unavailable. This helper opens TCL's native Quick Settings."
    D="$(tvdir)"
    compgen -G "$D/backup-*/device.txt" >/dev/null || die "Run scripts/backup.sh for this TV first."

    "$ROOT/scripts/build.sh" --settings-button
    adbtv install -r --no-incremental --user 0 "$ROOT/build/settings-button/LiftoffSettingsButton.apk"
    sh_tv cmd appops set "$PKG" APP_AUTO_START allow ||
      warn "This firmware did not accept the auto-start permission. Verify the helper after restarting the TV."
    sh_tv am start --user 0 -n "$PKG/.SetupActivity"
    say "Enable Liftoff Settings Button under Accessibility on your TV, then run this script with status."
    ;;
  status)
    if ! installed; then say "Liftoff Settings Button is not installed on this TV."; exit 0; fi
    services="$(sh_tv settings --user 0 get secure enabled_accessibility_services)"
    case ":$services:" in
      *":$PKG/$PKG.SettingsButtonService:"*|*":$PKG/.SettingsButtonService:"*) ;;
      *) say "Installed. Enable Liftoff Settings Button in the TV's Accessibility settings."; exit 0 ;;
    esac
    accessibility="$(sh_tv dumpsys accessibility)" || die "Cannot read the TV's accessibility status."
    if awk '/Bound services:/ && /label=Liftoff Settings Button[,\]]/ { bound = 1 } END { exit !bound }' <<<"$accessibility"; then
      say "Liftoff Settings Button is running. Test the physical Settings button from the HDMI input."
    else
      warn "The TV lists the helper as enabled, but it is not running. Turn it off and back on in Accessibility, then check again."
    fi
    ;;
  remove)
    if installed; then
      sh_tv pm uninstall --user 0 "$PKG"
      if installed; then die "The helper is still installed for the TV owner."; fi
    fi
    say "Liftoff Settings Button is removed."
    ;;
esac
