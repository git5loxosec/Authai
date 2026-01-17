#!/data/data/com.termux/files/usr/bin/bash
# --- Banner ---
echo "======================================"
echo " Authai - Java -> APK Builder (Termux)"
echo " by git5 LoxoSec 🐘"
echo " https://github.com/git5loxosec"
echo "======================================"
echo

set -euo pipefail
IFS=$'\n\t'

die(){ echo "[Authai ERROR] $*" >&2; exit 1; }
log(){ echo "[Authai] $*"; }

safe_pwd() {
  if cd "${PWD:-}" 2>/dev/null; then pwd
  elif cd "$HOME" 2>/dev/null; then pwd
  else die "Cannot determine a valid working directory."
  fi
}
WORKDIR="$(safe_pwd)"

SRC_NAME="${1:-}"
APPNAME="${2:-}"
PKG_ARG="${3:-}"

[[ -n "$SRC_NAME" && -n "$APPNAME" ]] || die "Usage: authai File.java AppName [package.name]"
[[ "$SRC_NAME" == *.java ]] || die "Source file must end with .java"

SRC="$WORKDIR/$SRC_NAME"
[[ -f "$SRC" ]] || die "File not found: $SRC"

command -v aapt2    >/dev/null || die "Missing aapt2"
command -v javac    >/dev/null || die "Missing javac"
command -v java     >/dev/null || die "Missing java"
command -v zip      >/dev/null || die "Missing zip"
command -v zipalign >/dev/null || die "Missing zipalign"
command -v keytool  >/dev/null || die "Missing keytool"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
[[ -d "$ANDROID_HOME" ]] || die "ANDROID_HOME not found: $ANDROID_HOME"

BT="$(ls -1d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "$BT" ]] || die "No build-tools found"

PLATFORM_DIR="$(ls -1d "$ANDROID_HOME"/platforms/android-* 2>/dev/null | sort -V | tail -n 1 || true)"
PLAT="$PLATFORM_DIR/android.jar"
[[ -f "$PLAT" ]] || die "android.jar not found"

APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || die "apksigner missing"

D8BIN="$BT/d8"
D8JAR="$BT/lib/d8.jar"

PKG_IN_FILE="$(sed -nE 's/^package[[:space:]]+([a-zA-Z0-9_.]+);/\1/p' "$SRC" | head -n1)"
PUBLIC_CLASS="$(sed -nE 's/^public[[:space:]]+class[[:space:]]+([A-Za-z0-9_]+).*/\1/p' "$SRC" | head -n1)"
[[ -n "$PUBLIC_CLASS" ]] || die "No public class found"

PKG="${PKG_ARG:-${PKG_IN_FILE:-com.authai.app}}"
PKG_PATH="${PKG//.//}"

WORK="$HOME/authai_builds/${APPNAME,,}"
APPDIR="$WORK/app"
OUT="$WORK/out"
KEYDIR="$HOME/keystores"
KEYSTORE="$KEYDIR/authai_upload.jks"
ALIAS="authaiupload"

rm -rf "$WORK"
mkdir -p "$APPDIR/res/values" "$APPDIR/src/$PKG_PATH" "$OUT" "$KEYDIR"

cat > "$APPDIR/AndroidManifest.xml" <<MAN
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$PKG">
  <application android:label="$APPNAME">
    <activity android:name=".$PUBLIC_CLASS" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
MAN

cat > "$APPDIR/res/values/strings.xml" <<STR
<resources>
  <string name="app_name">$APPNAME</string>
</resources>
STR

cp "$SRC" "$APPDIR/src/$PKG_PATH/$PUBLIC_CLASS.java"

log "aapt2 compile..."
aapt2 compile --dir "$APPDIR/res" -o "$OUT/res.zip"

log "aapt2 link..."
mkdir -p "$OUT/gen"
aapt2 link -I "$PLAT" --manifest "$APPDIR/AndroidManifest.xml" --min-sdk-version 24 --target-sdk-version 34 --java "$OUT/gen" -o "$OUT/base.apk" "$OUT/res.zip"

log "javac..."
mkdir -p "$OUT/classes"
javac -source 8 -target 8 -classpath "$PLAT" -d "$OUT/classes" "$APPDIR/src/$PKG_PATH/$PUBLIC_CLASS.java" "$OUT/gen/$PKG_PATH/R.java"

log "d8..."
"$D8BIN" --min-api 24 --lib "$PLAT" --output "$OUT" $(find "$OUT/classes" -name "*.class")

log "packaging..."
cp "$OUT/base.apk" "$OUT/unsigned.apk"
zip -q -j "$OUT/unsigned.apk" "$OUT/classes.dex"

log "zipalign..."
zipalign -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [[ ! -f "$KEYSTORE" ]]; then
  log "creating keystore..."
  keytool -genkeypair -v -keystore "$KEYSTORE" -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Authai,O=Authai"
fi

log "signing..."
FINAL="$WORK/${APPNAME,,}-signed.apk"
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verifying..."
"$APKSIGNER" verify "$FINAL" >/dev/null

log "OK -> $FINAL"
