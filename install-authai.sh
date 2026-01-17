#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[Authai-Install] $*"; }
die(){ echo "[Authai-Install ERROR] $*" >&2; exit 1; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="$PREFIX/bin"
AUTH_BIN="$BIN_DIR/authai"
UNINSTALL_BIN="$BIN_DIR/authai-uninstall"

AUTH_HOME="$HOME/.authai"
AUTH_TOOLS="$AUTH_HOME/tools"
AUTH_PLAT="$AUTH_HOME/platforms"
AUTH_PLATFORM_JAR="$AUTH_PLAT/android-34/android.jar"
AUTH_R8_JAR="$AUTH_TOOLS/r8.jar"

mkdir -p "$BIN_DIR" "$AUTH_TOOLS" "$AUTH_PLAT"

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. (installer should have installed it)"; }

download(){
  # usage: download URL OUTFILE
  local url="$1" out="$2"
  curl -fsSL "$url" -o "$out" || return 1
  return 0
}

ensure_android_jar(){
  if [[ -f "$AUTH_PLATFORM_JAR" ]]; then
    return 0
  fi

  log "Fetching android.jar (API 34) into: $AUTH_PLATFORM_JAR"
  mkdir -p "$(dirname "$AUTH_PLATFORM_JAR")"
  local tmpzip="$AUTH_HOME/platform.zip"
  rm -f "$tmpzip" 2>/dev/null || true

  # Try a few known platform-34 revisions (Google sometimes bumps rXX)
  local ok=0
  for r in 06 05 04 03 02 01; do
    local url="https://dl.google.com/android/repository/platform-34_r${r}.zip"
    log "Downloading: platform-34_r${r}.zip"
    if download "$url" "$tmpzip"; then ok=1; break; fi
  done
  [[ "$ok" -eq 1 ]] || die "Could not download Android platform zip (API 34). Check internet and try again."

  rm -rf "$AUTH_PLAT/android-34" 2>/dev/null || true
  mkdir -p "$AUTH_PLAT"

  unzip -q "$tmpzip" -d "$AUTH_PLAT"

  # The zip extracts into "android-34/"
  [[ -f "$AUTH_PLATFORM_JAR" ]] || die "android.jar not found after unzip. Expected: $AUTH_PLATFORM_JAR"
  rm -f "$tmpzip" 2>/dev/null || true
}

ensure_r8(){
  if [[ -f "$AUTH_R8_JAR" ]]; then
    return 0
  fi

  log "Fetching r8 (D8) jar into: $AUTH_R8_JAR"
  mkdir -p "$AUTH_TOOLS"

  # R8 jar from Maven Central (Java-only; works on Termux ARM)
  # If one version fails (rare), try a few.
  local ok=0
  for v in \
    "8.3.37" \
    "8.2.51" \
    "8.1.56" \
    "8.0.40"
  do
    local url="https://repo1.maven.org/maven2/com/android/tools/r8/${v}/r8-${v}.jar"
    log "Downloading: r8-${v}.jar"
    if download "$url" "$AUTH_R8_JAR"; then ok=1; break; fi
  done
  [[ "$ok" -eq 1 ]] || die "Could not download r8 jar. Check internet and try again."
}

log "Updating packages..."
pkg update -y >/dev/null

log "Installing dependencies..."
pkg install -y \
  openjdk-17 \
  aapt2 \
  android-tools \
  apksigner \
  zip \
  unzip \
  curl \
  ca-certificates \
  termux-tools >/dev/null

need_cmd java
need_cmd javac
need_cmd aapt2
need_cmd zip
need_cmd unzip
need_cmd zipalign
need_cmd apksigner
need_cmd keytool
need_cmd curl

ensure_android_jar
ensure_r8

log "Writing: $AUTH_BIN"
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

SRC="$PWD/$SRC_NAME"
[[ -f "$SRC" ]] || die "File not found: $SRC"

command -v aapt2    >/dev/null || die "Missing aapt2"
command -v javac    >/dev/null || die "Missing javac"
command -v java     >/dev/null || die "Missing java"
command -v zip      >/dev/null || die "Missing zip"
command -v zipalign >/dev/null || die "Missing zipalign"
command -v apksigner >/dev/null || die "Missing apksigner"
command -v keytool  >/dev/null || die "Missing keytool"

AUTH_HOME="$HOME/.authai"
PLAT="$AUTH_HOME/platforms/android-34/android.jar"
R8JAR="$AUTH_HOME/tools/r8.jar"
[[ -f "$PLAT" ]] || die "android.jar missing: $PLAT (re-run install-authai.sh)"
[[ -f "$R8JAR" ]] || die "r8.jar missing: $R8JAR (re-run install-authai.sh)"

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
  "$APPDIR/src/$PKG_PATH/$PUBLIC_CLASS.java" \
  "$RJAVA"

log "d8 (via r8.jar)..."
mapfile -t CLASS_FILES < <(find "$OUT/classes" -type f -name "*.class")
[[ "${#CLASS_FILES[@]}" -gt 0 ]] || die "No .class files produced."

java -cp "$R8JAR" com.android.tools.r8.D8 \
  --min-api 24 \
  --lib "$PLAT" \
  --output "$OUT" \
  "${CLASS_FILES[@]}"

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
fi

log "signing..."
FINAL="$WORK/${APPNAME,,}-signed.apk"
apksigner sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verifying..."
apksigner verify "$FINAL" >/dev/null || die "apksigner verify failed"

log "OK -> $FINAL"
AUTHAI_EOF
chmod +x "$AUTH_BIN"

log "Writing: $UNINSTALL_BIN"
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
  log "PURGE: removing keystore + authai cache..."
  rm -rf "$HOME/keystores" "$HOME/.authai" "$HOME/.authai" 2>/dev/null || true
else
  log "Keeping keystore + ~/.authai."
  log "To remove everything: authai-uninstall --purge"
fi

hash -r 2>/dev/null || true
log "Done."
UN_EOF
chmod +x "$UNINSTALL_BIN"

hash -r 2>/dev/null || true
log "Installed ✅"
echo "Run:"
echo "  authai File.java AppName [package.name]"
echo
echo "Uninstall:"
echo "  authai-uninstall"
echo "  authai-uninstall --purge"
