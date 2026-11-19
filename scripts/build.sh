#!/usr/bin/env bash
# build.sh — build Liftoff, or the standalone helper with --settings-button.
# Needs JDK 17+ and an Android SDK with build-tools and a platform >= 30 (scripts/setup-toolchain.sh fetches both).
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  "")
    APP="$ROOT/app"
    OUT="$ROOT/build/home"
    APK="$ROOT/build/Liftoff.apk"
    MIN_API=28
    [ -f "$CONFIG" ] || die "No liftoff.json. Copy liftoff.example.json to liftoff.json and edit it."
    python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG" || die "liftoff.json isn't valid JSON."
    ;;
  --settings-button)
    APP="$ROOT/settings-button"
    OUT="$ROOT/build/settings-button"
    APK="$OUT/LiftoffSettingsButton.apk"
    MIN_API=30
    ;;
  *) die "usage: scripts/build.sh [--settings-button]" ;;
esac

# Java
JH="${JAVA_HOME:-}"
for c in "$TOOLCHAIN"/jdk*/Contents/Home "$TOOLCHAIN"/jdk*; do [ -n "$JH" ] || { [ -x "$c/bin/javac" ] && JH="$c"; }; done
[ -n "$JH" ] || JH="$(/usr/libexec/java_home -v 17+ 2>/dev/null || true)"
[ -n "$JH" ] && [ -x "$JH/bin/javac" ] || die "No JDK found. Run scripts/setup-toolchain.sh, or set JAVA_HOME to a JDK 17+."
export JAVA_HOME="$JH" PATH="$JH/bin:$PATH"

# Android SDK
SDK=""
for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$TOOLCHAIN/sdk" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
  [ -z "$SDK" ] && [ -n "$c" ] && [ -d "$c/build-tools" ] && SDK="$c"
done
[ -n "$SDK" ] || die "No Android SDK found. Run scripts/setup-toolchain.sh, or set ANDROID_HOME."
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
JAR="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)/android.jar"
[ -f "$JAR" ] || die "No Android platform in $SDK/platforms. Install one: sdkmanager \"platforms;android-30\""

rm -rf "$OUT"; mkdir -p "$OUT"/{classes,dex,gen,res,assets}
cp -R "$APP/res" "$OUT/res-src"
if [ "$APP" = "$ROOT/app" ]; then
  say "Staging resources and your config"
  cp -R "$APP/assets/." "$OUT/assets/"
  # The app only needs these keys. The TV address and tweaks stay on your computer.
  python3 -I - "$CONFIG" "$OUT/assets/liftoff.json" <<'PY_CONFIG'
import json, sys
c = json.load(open(sys.argv[1]))
keep = {k: c[k] for k in ("apps", "weather", "nowPlaying", "lights", "background", "clock") if k in c}
json.dump(keep, open(sys.argv[2], "w"), indent=1)
PY_CONFIG
  img="$(conf 'c.get("background",{}).get("image")')"
  if [ -n "$img" ]; then
    case "$img" in /*) ;; *) img="$ROOT/$img";; esac
    [ -f "$img" ] || die "background.image not found: $img"
    ext="$(echo "${img##*.}" | tr A-Z a-z)"; [ "$ext" = jpeg ] && ext=jpg
    [ "$ext" = png ] || [ "$ext" = jpg ] || die "background.image must be a .png or .jpg"
    rm -f "$OUT"/res-src/drawable-nodpi/home_bg.*; cp "$img" "$OUT/res-src/drawable-nodpi/home_bg.$ext"
    say "Background image: $(basename "$img")"
  fi
fi

say "Compiling (build-tools $(basename "$BT"), $(basename "$(dirname "$JAR")"))"
"$BT/aapt2" compile --dir "$OUT/res-src" -o "$OUT/res/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest "$APP/AndroidManifest.xml" -A "$OUT/assets" \
  -o "$OUT/unsigned.apk" --java "$OUT/gen" "$OUT/res/res.zip"
STUBS=""; [ -f "$BT/core-lambda-stubs.jar" ] && STUBS=":$BT/core-lambda-stubs.jar"
sources=()
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find "$APP/src" "$OUT/gen" -name '*.java' -print0)
javac -nowarn -Xlint:-options -source 8 -target 8 -encoding UTF-8 -bootclasspath "$JAR$STUBS" -classpath "$JAR" \
  -d "$OUT/classes" "${sources[@]}"
classes=()
while IFS= read -r -d '' file; do classes+=("$file"); done < <(find "$OUT/classes" -name '*.class' -print0)
"$BT/d8" --lib "$JAR" --min-api "$MIN_API" --output "$OUT/dex" "${classes[@]}"
cp "$OUT/unsigned.apk" "$OUT/with-dex.apk"; (cd "$OUT/dex" && zip -q ../with-dex.apk classes.dex)
"$BT/zipalign" -f 4 "$OUT/with-dex.apk" "$OUT/aligned.apk"

# A signing key made once on this computer. Keep it: Android only accepts updates signed with the same key.
KS="$ROOT/.keystore/liftoff.keystore"
if [ ! -f "$KS" ]; then
  mkdir -p "$(dirname "$KS")"
  keytool -genkeypair -keystore "$KS" -storepass liftoff -keypass liftoff -alias liftoff -keyalg RSA \
    -keysize 2048 -validity 36500 -dname "CN=Liftoff local build" >/dev/null 2>&1
  say "Made a signing key at .keystore/liftoff.keystore (keep it for future updates)"
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:liftoff --out "$APK" "$OUT/aligned.apk"
"$BT/apksigner" verify "$APK"
rm -f "$OUT"/Liftoff.apk.idsig
say "Built ${APK#"$ROOT/"} ($(du -h "$APK" | cut -f1 | tr -d ' '))"
