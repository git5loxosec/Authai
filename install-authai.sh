#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

die(){ echo "[Authai ERROR] $*" >&2; exit 1; }
log(){ echo "[Authai] $*"; }

# --- Banner ---
echo "======================================"
echo " Authai - Java -> APK Builder (Termux)"
echo " by git5 LoxoSec 🐘"
echo " https://github.com/git5loxosec"
echo "======================================"
echo

# --- Safe working dir: build from current directory, not from where authai is installed ---
safe_pwd() {
  # PWD puede romperse si el directorio ya no existe
  if cd "${PWD:-}" 2>/dev/null; then
    pwd
  elif cd "$HOME" 2>/dev/null; then
    pwd
  else
    die "Cannot determine a valid working directory."
  fi
}
WORKDIR="$(safe_pwd)"

SRC_NAME="${1:-}"
APPNAME="${2:-}"
PKG_ARG="${3:-}"

[[ -n "$SRC_NAME" && -n "$APPNAME" ]] || die "Usage: authai File.java AppName [package.name]"
[[ "$SRC_NAME" == *.java ]] || die "Source file must end with .java"

SRC="$WORKDIR/$SRC_NAME"
[[ -f "$SRC" ]] || die "File not found: $SRC (run authai from the folder that contains your .java)"

# --- Required tools (Termux) ---
command -v aapt2    >/dev/null || die "Missing aapt2. Install: pkg install aapt2"
command -v javac    >/dev/null || die "Missing javac. Install: pkg install openjdk-17"
command -v java     >/dev/null || die "Missing java.  Install: pkg install openjdk-17"
command -v zip      >/dev/null || die "Missing zip.   Install: pkg install zip"
command -v zipalign >/dev/null || die "Missing zipalign. Install: pkg install android-tools"
command -v keytool  >/dev/null || die "Missing keytool. Install: pkg install openjdk-17"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
[[ -d "$ANDROID_HOME" ]] || die "ANDROID_HOME not found: $ANDROID_HOME"

# Latest build-tools + platform
BT="$(ls -1d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${BT:-}" && -d "$BT" ]] || die "No build-tools found in: $ANDROID_HOME/build-tools"

PLATFORM_DIR="$(ls -1d "$ANDROID_HOME"/platforms/android-* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${PLATFORM_DIR:-}" && -d "$PLATFORM_DIR" ]] || die "No platforms found in: $ANDROID_HOME/platforms"
PLAT="$PLATFORM_DIR/android.jar"
[[ -f "$PLAT" ]] || die "android.jar not found: $PLAT"

APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || die "apksigner not found/executable: $APKSIGNER"

D8BIN="$BT/d8"
D8JAR="$BT/lib/d8.jar"
[[ -x "$D8BIN" || -f "$D8JAR" ]] || die "d8 not found in build-tools: $BT"

# --- Detect package + public class ---
PKG_IN_FILE="$(sed -nE 's/^[[:space:]]*package[[:space:]]+([a-zA-Z0-9_.]+)[[:space:]]*;.*/\1/p' "$SRC" | head -n 1 || true)"

PUBLIC_CLASS="$(sed -nE 's/^[[:space:]]*public[[:space:]]+(final[[:space:]]+)?class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*.*/\2/p' "$SRC" | head -n 1 || true)"
[[ -n "$PUBLIC_CLASS" ]] || die "Could not detect a 'public class X' in $SRC_NAME"

if [[ -n "$PKG_ARG" ]]; then
  PKG="$PKG_ARG"
elif [[ -n "$PKG_IN_FILE" ]]; then
  PKG="$PKG_IN_FILE"
else
  PKG="com.authai.app"
fi
PKG_PATH="${PKG//.//}"

# --- Build dirs ---
WORK="$HOME/authai_builds/${APPNAME,,}"
APPDIR="$WORK/app"
OUT="$WORK/out"
KEYDIR="$HOME/keystores"
KEYSTORE="$KEYDIR/authai_upload.jks"
ALIAS="authaiupload"

rm -rf "$WORK"
mkdir -p "$APPDIR/res/values" "$APPDIR/src/$PKG_PATH" "$OUT" "$KEYDIR"

# --- Manifest + resources ---
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

# Copy java to correct name/path
SRC_DST="$APPDIR/src/$PKG_PATH/${PUBLIC_CLASS}.java"
cp -f "$SRC" "$SRC_DST"

log "aapt2 compile..."
aapt2 compile --dir "$APPDIR/res" -o "$OUT/res.zip"

log "aapt2 link..."
mkdir -p "$OUT/gen"
aapt2 link \
  -I "$PLAT" \
  --manifest "$APPDIR/AndroidManifest.xml" \
  --min-sdk-version 24 \
  --target-sdk-version 34 \
  --java "$OUT/gen" \
  -o "$OUT/base.apk" \
  "$OUT/res.zip"

log "javac..."
mkdir -p "$OUT/classes"
RJAVA="$OUT/gen/$PKG_PATH/R.java"
[[ -f "$RJAVA" ]] || die "R.java not generated (package mismatch). Expected: $RJAVA"

javac -source 8 -target 8 \
  -classpath "$PLAT" \
  -d "$OUT/classes" \
  "$SRC_DST" \
  "$RJAVA"

log "d8..."
# IMPORTANT FIX: use an array (prevents NoSuchFileException caused by passing as one arg)
mapfile -t CLASS_FILES < <(find "$OUT/classes" -type f -name "*.class")
[[ "${#CLASS_FILES[@]}" -gt 0 ]] || die "No .class files produced by javac."

if [[ -x "$D8BIN" ]]; then
  "$D8BIN" --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_FILES[@]}"
else
  java -cp "$D8JAR" com.android.tools.r8.D8 --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_FILES[@]}"
fi
[[ -f "$OUT/classes.dex" ]] || die "classes.dex was not produced."

log "packaging..."
cp "$OUT/base.apk" "$OUT/unsigned.apk"
zip -q -j "$OUT/unsigned.apk" "$OUT/classes.dex"

log "zipalign..."
zipalign -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# --- Keystore auto-create ---
mkdir -p "$KEYDIR"
if [[ ! -f "$KEYSTORE" ]]; then
  log "creating keystore: $KEYSTORE"
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Authai,O=Authai"
else
  log "using existing keystore: $KEYSTORE"
fi

log "signing..."
FINAL="$WORK/${APPNAME,,}-signed.apk"
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verifying signature..."
"$APKSIGNER" verify --verbose "$FINAL" >/dev/null || die "apksigner verify failed."

log "verifying zipalign..."
zipalign -c -v 4 "$FINAL" >/dev/null || die "zipalign verify failed."

log "OK -> $FINAL"
