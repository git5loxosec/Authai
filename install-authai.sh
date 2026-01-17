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

CMDLINE_ZIP_URL="https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip"
CMDLINE_ZIP_SHA256="7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee"

log "Updating package indexes (no upgrade)..."
pkg update -y >/dev/null

log "Installing Termux dependencies..."
pkg install -y \
  openjdk-17 \
  aapt2 \
  android-tools \
  zip unzip \
  curl ca-certificates \
  coreutils findutils gawk sed grep \
  >/dev/null

mkdir -p "$ANDROID_HOME"

have_platforms(){ ls -1d "$ANDROID_HOME"/platforms/android-* >/dev/null 2>&1; }
have_build_tools(){ ls -1d "$ANDROID_HOME"/build-tools/* >/dev/null 2>&1; }

sdkmanager_path() {
  if [[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
    echo "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    return 0
  fi
  return 1
}

install_cmdline_tools() {
  if sdkmanager_path >/dev/null 2>&1; then
    log "cmdline-tools already present."
    return 0
  fi

  log "Downloading Android cmdline-tools..."
  local tmp="$HOME/.authai_tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  curl -L "$CMDLINE_ZIP_URL" -o "$tmp/cmdline.zip"

  log "Verifying cmdline-tools SHA-256..."
  local got
  got="$(sha256sum "$tmp/cmdline.zip" | awk '{print $1}')"
  [[ "$got" == "$CMDLINE_ZIP_SHA256" ]] || die "SHA-256 mismatch for cmdline-tools zip."

  log "Installing cmdline-tools into: $ANDROID_HOME/cmdline-tools/latest"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  unzip -q "$tmp/cmdline.zip" -d "$tmp/unzipped"

  # The zip contains: cmdline-tools/...
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
  cp -r "$tmp/unzipped/cmdline-tools/"* "$ANDROID_HOME/cmdline-tools/latest/"

  rm -rf "$tmp"
}

install_sdk_minimal() {
  if have_platforms && have_build_tools; then
    log "Android SDK looks complete at: $ANDROID_HOME"
    return 0
  fi

  install_cmdline_tools
  local SM
  SM="$(sdkmanager_path)" || die "sdkmanager not found after installing cmdline-tools."

  log "Preparing repositories.cfg..."
  mkdir -p "$HOME/.android"
  touch "$HOME/.android/repositories.cfg" || true

  log "Accepting SDK licenses..."
  yes | "$SM" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true

  log "Installing minimal SDK packages..."
  "$SM" --sdk_root="$ANDROID_HOME" \
    "platforms;android-34" \
    "build-tools;34.0.0" \
    >/dev/null

  have_platforms || die "SDK install failed: missing platforms/android-*/android.jar"
  have_build_tools || die "SDK install failed: missing build-tools/*"
  log "SDK ready."
}

install_sdk_minimal

log "Writing Authai -> $AUTH_BIN"
cat > "$AUTH_BIN" <<'AUTHAI_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

die(){ echo "[Authai ERROR] $*" >&2; exit 1; }
log(){ echo "[Authai] $*"; }

# banner
echo
echo "======================================"
echo " Authai - Java -> APK Builder (Termux)"
echo " by git5 LoxoSec 🐘"
echo " https://github.com/git5loxosec"
echo "======================================"
echo

# Avoid getcwd issues if current dir disappears
safe_cd() {
  local d="$1"
  cd "$d" 2>/dev/null || cd "$HOME" 2>/dev/null || die "Cannot enter a valid working directory."
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
safe_cd "$SCRIPT_DIR"

SRC_NAME="${1:-}"
APPNAME="${2:-}"
PKG_ARG="${3:-}"

[[ -n "$SRC_NAME" && -n "$APPNAME" ]] || die "Usage: authai File.java AppName [package.name]"
[[ "$SRC_NAME" == *.java ]] || die "Input file must end in .java"

SRC="$SCRIPT_DIR/$SRC_NAME"
[[ -f "$SRC" ]] || die "File must be next to where you run authai: $SRC_NAME (in: $SCRIPT_DIR)"

command -v aapt2 >/dev/null || die "Missing aapt2 (pkg install aapt2)"
command -v javac >/dev/null || die "Missing javac (pkg install openjdk-17)"
command -v java  >/dev/null || die "Missing java (pkg install openjdk-17)"
command -v zip   >/dev/null || die "Missing zip (pkg install zip)"
command -v zipalign >/dev/null || die "Missing zipalign (pkg install android-tools)"
command -v keytool >/dev/null || die "Missing keytool (pkg install openjdk-17)"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
[[ -d "$ANDROID_HOME" ]] || die "ANDROID_HOME not found: $ANDROID_HOME"

BT="$(ls -1d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${BT:-}" && -d "$BT" ]] || die "No build-tools found in $ANDROID_HOME/build-tools"

PLATFORM_DIR="$(ls -1d "$ANDROID_HOME"/platforms/android-* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${PLATFORM_DIR:-}" && -d "$PLATFORM_DIR" ]] || die "No platforms found in $ANDROID_HOME/platforms"
PLAT="$PLATFORM_DIR/android.jar"
[[ -f "$PLAT" ]] || die "android.jar not found: $PLAT"

APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || die "apksigner not executable: $APKSIGNER"

D8BIN="$BT/d8"
D8JAR="$BT/lib/d8.jar"
[[ -x "$D8BIN" || -f "$D8JAR" ]] || die "d8 missing in build-tools: $BT"

# Detect main public class
PUBLIC_CLASS="$(sed -nE 's/^[[:space:]]*public[[:space:]]+(final[[:space:]]+)?class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*.*/\2/p' "$SRC" | head -n 1 || true)"
[[ -n "$PUBLIC_CLASS" ]] || die "No 'public class X' found in $SRC_NAME"

# Detect package from file
PKG_IN_FILE="$(sed -nE 's/^[[:space:]]*package[[:space:]]+([a-zA-Z0-9_.]+)[[:space:]]*;.*/\1/p' "$SRC" | head -n 1 || true)"

if [[ -n "$PKG_ARG" ]]; then
  PKG="$PKG_ARG"
elif [[ -n "$PKG_IN_FILE" ]]; then
  PKG="$PKG_IN_FILE"
else
  PKG="com.authai.app"
fi

PKG_PATH="${PKG//.//}"

WORK="$HOME/authai_builds/${APPNAME,,}"
APPDIR="$WORK/app"
OUT="$WORK/out"
KEYDIR="$HOME/keystores"
KEYSTORE="$KEYDIR/authai_upload.jks"
ALIAS="authaiupload"

rm -rf "$WORK"
mkdir -p "$APPDIR/res/layout" "$APPDIR/res/values" "$APPDIR/src/$PKG_PATH" "$OUT" "$KEYDIR"

cat > "$APPDIR/AndroidManifest.xml" <<MAN
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$PKG">

  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="34"/>

  <application
      android:label="$APPNAME"
      android:allowBackup="false"
      android:extractNativeLibs="false"
      android:supportsRtl="true">

    <activity
        android:name=".$PUBLIC_CLASS"
        android:exported="true">

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

# Copy source to correct javac filename
SRC_DST="$APPDIR/src/$PKG_PATH/${PUBLIC_CLASS}.java"
cp "$SRC" "$SRC_DST"

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
mapfile -d '' CLASS_FILES < <(find "$OUT/classes" -type f -name "*.class" -print0)
(( ${#CLASS_FILES[@]} > 0 )) || die "No .class files found to convert."

if [[ -x "$D8BIN" ]]; then
  "$D8BIN" --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_FILES[@]}"
else
  java -cp "$D8JAR" com.android.tools.r8.D8 --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_FILES[@]}"
fi

[[ -f "$OUT/classes.dex" ]] || die "classes.dex was not created."

log "packaging..."
# Creamos un APK nuevo desde base.apk pero inyectando classes.dex ANTES de firmar,
# y sin romper el signing block después.
cp "$OUT/base.apk" "$OUT/unsigned.apk"

# Inyecta classes.dex (sin -j) desde el mismo directorio para mantener estructura zip correcta
(
  cd "$OUT"
  zip -q unsigned.apk classes.dex
)

log "zipalign..."
zipalign -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

log "signing..."
FINAL="$WORK/${APPNAME,,}-signed.apk"

# Fuerza firmas modernas (Android 15 las requiere en la práctica)
"$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias "$ALIAS" \
  --v1-signing-enabled true \
  --v2-signing-enabled true \
  --v3-signing-enabled true \
  --v4-signing-enabled false \
  --out "$FINAL" \
  "$OUT/aligned.apk"

log "verifying signature..."
"$APKSIGNER" verify --verbose "$FINAL" >/dev/null || die "apksigner verify failed."

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
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verifying signature..."
"$APKSIGNER" verify --verbose "$FINAL" >/dev/null || die "apksigner verify failed."

log "verifying zipalign..."
zipalign -c -v 4 "$FINAL" >/dev/null || die "zipalign -c failed."

log "OK -> $FINAL"
AUTHAI_EOF

chmod +x "$AUTH_BIN"

log "Writing uninstall -> $UNINSTALL_BIN"
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
rm -f "$AUTH_BIN" || true
rm -f "$UNINSTALL_BIN" || true

log "Removing builds..."
rm -rf "$HOME/authai_builds" || true

if [[ "$PURGE" == "--purge" ]]; then
  log "PURGE: removing keystore + android-sdk + support dir..."
  rm -rf "$HOME/keystores" || true
  rm -rf "$HOME/android-sdk" || true
  rm -rf "$HOME/.authai" || true
else
  log "Keeping keystore + android-sdk."
  log "To remove EVERYTHING: authai-uninstall --purge"
fi

log "Done."
UN_EOF

chmod +x "$UNINSTALL_BIN"

hash -r || true
log "Install complete ✅"
echo
echo "Usage:"
echo "  Put your .java file in the SAME folder where you run authai"
echo "  authai MyFile.java MyApp [com.my.package]"
echo
echo "Uninstall:"
echo "  authai-uninstall"
echo "  authai-uninstall --purge"
echo
