cd ~/Authai

cat > install-authai.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[Authai-Install] $*"; }
die(){ echo "[Authai-Install ERROR] $*" >&2; exit 1; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
AUTH_BIN="$PREFIX/bin/authai"
UNINSTALL_BIN="$PREFIX/bin/authai-uninstall"

log "Updating package indexes..."
pkg update -y >/dev/null || true

log "Installing dependencies..."
pkg install -y \
  openjdk-17 \
  aapt2 \
  android-tools \
  apksigner \
  zip \
  unzip \
  termux-tools >/dev/null

# --- verify required tooling exists in PATH ---
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing '$1' (installation failed)"; }
need aapt2
need javac
need java
need zip
need zipalign
need apksigner
need keytool

# --- locate Android framework files (no SDK needed) ---
pick_first() {
  for p in "$@"; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

FRAMEWORK_RES="$(pick_first \
  /system/framework/framework-res.apk \
  /system_ext/framework/framework-res.apk \
  /product/framework/framework-res.apk \
  /vendor/framework/framework-res.apk \
  )" || die "Cannot find framework-res.apk on this device."

FRAMEWORK_JAR="$(pick_first \
  /system/framework/framework.jar \
  /system_ext/framework/framework.jar \
  /product/framework/framework.jar \
  )" || die "Cannot find framework.jar on this device."

log "Using framework-res: $FRAMEWORK_RES"
log "Using framework-jar : $FRAMEWORK_JAR"

log "Writing authai to: $AUTH_BIN"
cat > "$AUTH_BIN" <<'AUTHAI_EOF'
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

SRC_NAME="${1:-}"
APPNAME="${2:-}"
PKG_ARG="${3:-}"

[[ -n "$SRC_NAME" && -n "$APPNAME" ]] || die "Usage: authai File.java AppName [package.name]"
[[ "$SRC_NAME" == *.java ]] || die "Source file must end with .java"
[[ -f "$SRC_NAME" ]] || die "File not found: $SRC_NAME (run authai from the folder containing your .java)"

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing '$1'"; }
need aapt2
need javac
need java
need zip
need zipalign
need apksigner
need keytool

# Platform files (no SDK)
pick_first() {
  for p in "$@"; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

FRAMEWORK_RES="$(pick_first \
  /system/framework/framework-res.apk \
  /system_ext/framework/framework-res.apk \
  /product/framework/framework-res.apk \
  /vendor/framework/framework-res.apk \
  )" || die "Cannot find framework-res.apk on this device."

FRAMEWORK_JAR="$(pick_first \
  /system/framework/framework.jar \
  /system_ext/framework/framework.jar \
  /product/framework/framework.jar \
  )" || die "Cannot find framework.jar on this device."

SRC="$SRC_NAME"

PKG_IN_FILE="$(sed -nE 's/^[[:space:]]*package[[:space:]]+([a-zA-Z0-9_.]+)[[:space:]]*;.*/\1/p' "$SRC" | head -n1 || true)"
PUBLIC_CLASS="$(sed -nE 's/^[[:space:]]*public[[:space:]]+(final[[:space:]]+)?class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/p' "$SRC" | head -n1 || true)"
[[ -n "$PUBLIC_CLASS" ]] || die "No public class found (expected: public class X) in $SRC_NAME"

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

cp -f "$SRC" "$APPDIR/src/$PKG_PATH/$PUBLIC_CLASS.java"

log "aapt2 compile..."
aapt2 compile --dir "$APPDIR/res" -o "$OUT/res.zip"

log "aapt2 link..."
mkdir -p "$OUT/gen"
aapt2 link \
  -I "$FRAMEWORK_RES" \
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
  -bootclasspath "$FRAMEWORK_JAR" \
  -d "$OUT/classes" \
  "$APPDIR/src/$PKG_PATH/$PUBLIC_CLASS.java" \
  "$RJAVA"

log "d8..."
# Use d8 if present; otherwise use the dx "d8" shim if available
D8BIN="$(command -v d8 || true)"
[[ -n "$D8BIN" ]] || die "d8 not found. Install: pkg install dx (or r8) then retry."

mapfile -t CLASS_FILES < <(find "$OUT/classes" -type f -name "*.class")
[[ "${#CLASS_FILES[@]}" -gt 0 ]] || die "No .class files produced."
"$D8BIN" --min-api 24 --lib "$FRAMEWORK_JAR" --output "$OUT" "${CLASS_FILES[@]}"
[[ -f "$OUT/classes.dex" ]] || die "classes.dex was not produced."

log "packaging..."
cp -f "$OUT/base.apk" "$OUT/unsigned.apk"
zip -q -j "$OUT/unsigned.apk" "$OUT/classes.dex"

log "zipalign..."
zipalign -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [[ ! -f "$KEYSTORE" ]]; then
  log "creating keystore..."
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
apksigner sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verifying..."
apksigner verify "$FINAL" >/dev/null || die "apksigner verify failed"

log "OK -> $FINAL"
AUTHAI_EOF

chmod +x "$AUTH_BIN"

log "Writing uninstall to: $UNINSTALL_BIN"
cat > "$UNINSTALL_BIN" <<'UN_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'
log(){ echo "[Authai-Uninstall] $*"; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
AUTH_BIN="$PREFIX/bin/authai"
UNINSTALL_BIN="$PREFIX/bin/authai-uninstall"
PURGE="${1:-}"

log "Removing binaries..."
rm -f "$AUTH_BIN" "$UNINSTALL_BIN" 2>/dev/null || true

log "Removing builds..."
rm -rf "$HOME/authai_builds" 2>/dev/null || true

if [[ "$PURGE" == "--purge" ]]; then
  log "PURGE: removing keystore..."
  rm -rf "$HOME/keystores" "$HOME/.authai" 2>/dev/null || true
else
  log "Keeping keystore."
  log "To remove everything: authai-uninstall --purge"
fi

log "Done."
UN_EOF

chmod +x "$UNINSTALL_BIN"
hash -r || true

log "Installed ✅"
echo "Run: authai File.java AppName [package.name]"
echo "Uninstall: authai-uninstall (or authai-uninstall --purge)"
EOF

chmod +x install-authai.sh
./install-authai.sh
