#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[Authai-Install] $*"; }
die(){ echo "[Authai-Install ERROR] $*" >&2; exit 1; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
AUTH_BIN="$PREFIX/bin/authai"
UNINSTALL_BIN="$PREFIX/bin/authai-uninstall"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_HOME

CMDLINE_TOOLS_DIR="$ANDROID_HOME/cmdline-tools/latest"
SDKMANAGER="$CMDLINE_TOOLS_DIR/bin/sdkmanager"

ACTION="${1:-install}"
PURGE="${2:-}"

# -------------------- Uninstall (single-file support) --------------------
do_uninstall() {
  log "Removing binaries..."
  rm -f "$AUTH_BIN" "$UNINSTALL_BIN" 2>/dev/null || true

  log "Removing builds..."
  rm -rf "$HOME/authai_builds" 2>/dev/null || true

  if [[ "${PURGE:-}" == "--purge" ]]; then
    log "PURGE: removing keystore + android-sdk..."
    rm -rf "$HOME/keystores" "$HOME/.authai" "$HOME/android-sdk" 2>/dev/null || true
  else
    log "Keeping keystore + android-sdk (use: ./install-authai.sh uninstall --purge)"
  fi

  log "Done ✅"
}

if [[ "$ACTION" == "uninstall" ]]; then
  do_uninstall
  exit 0
fi

# -------------------- Install deps --------------------
log "Updating packages..."
pkg update -y

log "Installing dependencies..."
pkg install -y \
  openjdk-17 \
  aapt2 \
  android-tools \
  zip \
  unzip \
  curl \
  ca-certificates \
  termux-tools

command -v java >/dev/null 2>&1 || die "Java not found after installing openjdk-17"

# -------------------- SDK bootstrap --------------------
have_build_tools(){ ls -1d "$ANDROID_HOME"/build-tools/* >/dev/null 2>&1; }
have_platform_jar(){ ls -1 "$ANDROID_HOME"/platforms/android-*/android.jar >/dev/null 2>&1; }

ensure_sdkmanager() {
  if [[ -x "$SDKMANAGER" ]]; then
    return 0
  fi

  log "Bootstrapping sdkmanager..."
  mkdir -p "$ANDROID_HOME/cmdline-tools" "$ANDROID_HOME/tmp"

  local zip="$ANDROID_HOME/tmp/cmdline-tools.zip"
  local url="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"

  log "Downloading commandline-tools..."
  curl -L --fail --retry 3 --retry-delay 1 -o "$zip" "$url" \
    || die "Failed to download commandline-tools"

  log "Unzipping commandline-tools..."
  rm -rf "$ANDROID_HOME/tmp/unzip"
  mkdir -p "$ANDROID_HOME/tmp/unzip"
  unzip -q "$zip" -d "$ANDROID_HOME/tmp/unzip" || die "Failed to unzip commandline-tools"

  # Google zip contains: cmdline-tools/
  rm -rf "$CMDLINE_TOOLS_DIR"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/tmp/unzip/cmdline-tools" "$CMDLINE_TOOLS_DIR" \
    || die "Unexpected commandline-tools zip structure"

  rm -rf "$ANDROID_HOME/tmp"
  [[ -x "$SDKMANAGER" ]] || die "sdkmanager not found after bootstrap"
}

ensure_minimal_sdk() {
  log "Checking Android SDK at: $ANDROID_HOME"
  mkdir -p "$ANDROID_HOME"

  ensure_sdkmanager

  mkdir -p "$HOME/.android"
  touch "$HOME/.android/repositories.cfg" 2>/dev/null || true

  log "Accepting licenses..."
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true

  log "Installing minimal SDK packages..."
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
    "platform-tools" \
    "build-tools;34.0.0" \
    "platforms;android-34" >/dev/null

  have_build_tools || die "SDK install incomplete: missing build-tools/* in $ANDROID_HOME"
  have_platform_jar || die "SDK install incomplete: missing platforms/android-*/android.jar in $ANDROID_HOME"

  log "SDK installed."
}

ensure_minimal_sdk

# -------------------- Write authai --------------------
log "Writing authai to: $AUTH_BIN"
cat > "$AUTH_BIN" <<'AUTHAI_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# --- Banner (ONLY ONE banner, by design) ---
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
[[ -f "$SRC" ]] || die "File not found: $SRC (run authai from the folder containing your .java)"

command -v aapt2    >/dev/null || die "Missing aapt2 (pkg install aapt2)"
command -v javac    >/dev/null || die "Missing javac (pkg install openjdk-17)"
command -v java     >/dev/null || die "Missing java  (pkg install openjdk-17)"
command -v zip      >/dev/null || die "Missing zip   (pkg install zip)"
command -v unzip    >/dev/null || die "Missing unzip (pkg install unzip)"
command -v zipalign >/dev/null || die "Missing zipalign (pkg install android-tools)"
command -v keytool  >/dev/null || die "Missing keytool (pkg install openjdk-17)"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
[[ -d "$ANDROID_HOME" ]] || die "ANDROID_HOME not found: $ANDROID_HOME"

BT="$(ls -1d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${BT:-}" && -d "$BT" ]] || die "No build-tools found in: $ANDROID_HOME/build-tools"

PLATFORM_DIR="$(ls -1d "$ANDROID_HOME"/platforms/android-* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${PLATFORM_DIR:-}" && -d "$PLATFORM_DIR" ]] || die "No platforms found in: $ANDROID_HOME/platforms"
PLAT="$PLATFORM_DIR/android.jar"
[[ -f "$PLAT" ]] || die "android.jar not found: $PLAT"

APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || die "apksigner missing/executable: $APKSIGNER"

D8BIN="$BT/d8"
D8JAR="$BT/lib/d8.jar"
[[ -x "$D8BIN" || -f "$D8JAR" ]] || die "d8 not found in build-tools: $BT"

# package + public class detection (robust to indentation)
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

# Manifest: include versionCode/versionName + uses-sdk to avoid empty version fields
cat > "$APPDIR/AndroidManifest.xml" <<MAN
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$PKG"
    android:versionCode="1"
    android:versionName="1.0">

    <uses-sdk
        android:minSdkVersion="24"
        android:targetSdkVersion="34" />

    <application
        android:label="$APPNAME"
        android:allowBackup="false">

        <activity
            android:name=".$PUBLIC_CLASS"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
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
  -I "$PLAT" \
  --manifest "$APPDIR/AndroidManifest.xml" \
  --min-sdk-version 24 \
  --target-sdk-version 34 \
  --version-code 1 \
  --version-name "1.0" \
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
  "$APPDIR/src/$PKG_PATH/$PUBLIC_CLASS.java" \
  "$RJAVA"

log "d8..."
mapfile -t CLASS_FILES < <(find "$OUT/classes" -type f -name "*.class")
[[ "${#CLASS_FILES[@]}" -gt 0 ]] || die "No .class files produced."

if [[ -x "$D8BIN" ]]; then
  "$D8BIN" --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_FILES[@]}"
else
  java -cp "$D8JAR" com.android.tools.r8.D8 --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_FILES[@]}"
fi
[[ -f "$OUT/classes.dex" ]] || die "classes.dex was not produced."

log "packaging..."
cp -f "$OUT/base.apk" "$OUT/unsigned.apk"
zip -q -j "$OUT/unsigned.apk" "$OUT/classes.dex"

log "zipalign..."
zipalign -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

mkdir -p "$KEYDIR"
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
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verifying..."
"$APKSIGNER" verify --verbose "$FINAL" >/dev/null || die "apksigner verify failed"
zipalign -c -v 4 "$FINAL" >/dev/null || die "zipalign verify failed"

log "OK -> $FINAL"
AUTHAI_EOF
chmod +x "$AUTH_BIN"

# -------------------- Write authai-uninstall --------------------
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
  log "PURGE: removing keystore + android-sdk..."
  rm -rf "$HOME/keystores" "$HOME/.authai" "$HOME/android-sdk" 2>/dev/null || true
else
  log "Keeping keystore + android-sdk."
  log "To remove everything: authai-uninstall --purge"
fi

log "Done ✅"
UN_EOF
chmod +x "$UNINSTALL_BIN"

hash -r || true
log "Installed ✅"
echo "Run: authai File.java AppName [package.name]"
echo "Uninstall: authai-uninstall   (or: authai-uninstall --purge)"
echo "Also supported: ./install-authai.sh uninstall [--purge]"
echo
echo "======================================"
echo " APK Verification (optional)"
echo "======================================"
echo
echo "You can verify the generated APK with:"
echo
echo 'APK="$HOME/authai_builds/'"${APPNAME,,}"'/'"${APPNAME,,}"'-signed.apk"'
echo 'BT="$(ls -1d "$HOME/android-sdk/build-tools/"* | sort -V | tail -n 1)"'
echo
echo '"$BT/apksigner" verify --verbose --print-certs "$APK"'
echo 'zipalign -c -v 4 "$APK"'
echo 'aapt2 dump badging "$APK" | egrep -i '\''package:|versionCode|versionName|sdkVersion|targetSdkVersion|launchable-activity'\'''
echo 'unzip -t "$APK" | tail -n 5'
echo
echo "======================================"
echo
