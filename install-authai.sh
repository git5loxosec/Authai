#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

banner() {
  echo "======================================"
  echo " Authai Installer "
  echo " by git5 LoxoSec 🐘"
  echo "======================================"
  echo
}

die(){ echo "[Installer ERROR] $*" >&2; exit 1; }
log(){ echo "[Installer] $*"; }

usage(){
  cat <<'EOF'
Usage:
  ./install-authai.sh install
  ./install-authai.sh uninstall
  ./install-authai.sh doctor

What this does:
  - install: writes the authai CLI into $PREFIX/bin/authai
  - uninstall: removes $PREFIX/bin/authai
  - doctor: checks common deps (java, android sdk path, imagemagick optional)
EOF
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 1; }

banner

AUTH_DST="$PREFIX/bin/authai"

doctor(){
  log "Checking deps..."
  command -v bash >/dev/null || die "bash missing"
  command -v python >/dev/null 2>&1 || log "python missing (optional)"
  command -v java >/dev/null || die "java missing (pkg install openjdk-17 and/or openjdk-21)"
  command -v aapt2 >/dev/null 2>&1 || log "aapt2 missing (recommended: pkg install aapt2)"
  command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || \
    log "ImageMagick missing (needed for --icon): pkg install imagemagick"

  if [[ -n "${ANDROID_HOME:-}" ]] && [[ -d "$ANDROID_HOME" ]]; then
    log "ANDROID_HOME=$ANDROID_HOME"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" ]] && [[ -d "$ANDROID_SDK_ROOT" ]]; then
    log "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
  elif [[ -d "$HOME/android-sdk" ]]; then
    log "Found SDK at $HOME/android-sdk"
  else
    log "SDK not found (expected ANDROID_HOME/ANDROID_SDK_ROOT or ~/android-sdk)"
  fi

  log "Doctor done."
}

install(){
  mkdir -p "$(dirname "$AUTH_DST")"

  cat > "$AUTH_DST" <<'AUTHAI_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

banner() {
  echo "======================================"
  echo " Authai — Android APK Builder (Termux)"
  echo " Works on Android 15, no root!"
  echo " by git5 LoxoSec 🐘"
  echo "======================================"
  echo
}

log(){ echo "[Authai] $*"; }
die(){ echo "[Authai ERROR] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  authai <project_dir> --name <AppName> --pkg <com.example.app> [--icon /path/icon.png]

Notes:
  - Gradle wrapper REQUIRED (project must include ./gradlew)
  - Stages to: ~/.authai_work/<safe_name> (never touches original project)
  - Logs to: ~/authai_trace.txt
EOF
}

safe_cd_home() { cd "$HOME" 2>/dev/null || true; }

abs_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || { echo ""; return 0; }
  if command -v python >/dev/null 2>&1; then
    python -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$p"
  else
    case "$p" in
      /*) echo "$p" ;;
      *)  echo "$PWD/$p" ;;
    esac
  fi
}

# args
[[ $# -ge 1 ]] || { usage; exit 1; }

INPUT="$1"; shift
NAME=""
PKG=""
ICON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --pkg)  PKG="${2:-}"; shift 2 ;;
    --icon) ICON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[[ -n "$INPUT" ]] || die "Missing project_dir"
[[ -n "$NAME"  ]] || die "Missing --name <AppName>"
[[ -n "$PKG"   ]] || die "Missing --pkg <com.example.app>"

banner
safe_cd_home

INPUT_ABS="$(abs_path "$INPUT")"
[[ -d "$INPUT_ABS" ]] || die "Project dir not found: $INPUT_ABS"
[[ -f "$INPUT_ABS/gradlew" ]] || die "Not a Gradle wrapper project: missing $INPUT_ABS/gradlew"

log "Args OK. Input: $INPUT_ABS"

# staging
WORKROOT="$HOME/.authai_work"
SAFE_ID="$(echo "$NAME" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
[[ -n "$SAFE_ID" ]] || SAFE_ID="app"

STAGE="$WORKROOT/$SAFE_ID"
rm -rf "$STAGE" 2>/dev/null || true
mkdir -p "$STAGE"

log "Gradle mode -> staging project to: $STAGE"
cp -a "$INPUT_ABS/." "$STAGE/"

cd "$STAGE" || die "Failed cd to stage: $STAGE"
chmod +x ./gradlew 2>/dev/null || true

# choose JAVA_HOME by Gradle wrapper version
GW_PROP="$STAGE/gradle/wrapper/gradle-wrapper.properties"
[[ -f "$GW_PROP" ]] || die "gradle-wrapper.properties not found in project"

G_VER="$(grep -E 'distributionUrl=.*gradle-[0-9.]+' "$GW_PROP" | sed -n 's/.*gradle-\([0-9.]*\).*/\1/p' | head -n1 || true)"
[[ -n "$G_VER" ]] || die "Cannot parse Gradle version from wrapper properties"

JAVA17="$PREFIX/lib/jvm/java-17-openjdk"
JAVA21="$PREFIX/lib/jvm/java-21-openjdk"

pick_java() {
  local v="$1"
  if [[ "$(printf '%s\n%s\n' "8.5" "$v" | sort -V | head -n1)" == "8.5" ]]; then
    [[ -d "$JAVA21" ]] && { echo "$JAVA21"; return 0; }
  fi
  [[ -d "$JAVA17" ]] && { echo "$JAVA17"; return 0; }
  [[ -d "$JAVA21" ]] && { echo "$JAVA21"; return 0; }
  return 1
}

JAVA_HOME_CHOSEN="$(pick_java "$G_VER" || true)"
[[ -n "${JAVA_HOME_CHOSEN:-}" ]] || die "No Java found. Install: pkg install openjdk-17 (and/or openjdk-21)"
export JAVA_HOME="$JAVA_HOME_CHOSEN"
export PATH="$JAVA_HOME/bin:$PATH"
log "Gradle wrapper=$G_VER -> Using JAVA_HOME=$JAVA_HOME"

export GRADLE_USER_HOME="$STAGE/.gradle"

# Android SDK (fix 'SDK location not found')
ensure_android_sdk() {
  local sdk=""

  if [[ -n "${ANDROID_HOME:-}" ]] && [[ -d "$ANDROID_HOME" ]]; then
    sdk="$ANDROID_HOME"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" ]] && [[ -d "$ANDROID_SDK_ROOT" ]]; then
    sdk="$ANDROID_SDK_ROOT"
  elif [[ -d "$HOME/android-sdk" ]]; then
    sdk="$HOME/android-sdk"
  fi

  [[ -n "$sdk" ]] || die "Android SDK not found. Set ANDROID_HOME/ANDROID_SDK_ROOT or install to ~/android-sdk"

  export ANDROID_HOME="$sdk"
  export ANDROID_SDK_ROOT="$sdk"

  printf 'sdk.dir=%s\n' "$sdk" > "$STAGE/local.properties"
  log "Using Android SDK: $sdk"
}

ensure_android_sdk

# patch gradle.properties safely
patch_gradle_properties() {
  local gp="$STAGE/gradle.properties"
  touch "$gp" 2>/dev/null || true

  if [[ -s "$gp" ]]; then
    local lastchar
    lastchar="$(tail -c 1 "$gp" 2>/dev/null || true)"
    [[ -n "$lastchar" ]] && printf '\n' >> "$gp"
  fi

  local aapt2_bin
  aapt2_bin="$(command -v aapt2 || true)"
  if [[ -n "$aapt2_bin" ]]; then
    if grep -q '^android\.aapt2FromMavenOverride=' "$gp" 2>/dev/null; then
      sed -i "s|^android\.aapt2FromMavenOverride=.*|android.aapt2FromMavenOverride=$aapt2_bin|g" "$gp" || true
    else
      printf 'android.aapt2FromMavenOverride=%s\n' "$aapt2_bin" >> "$gp"
    fi
  fi

  grep -q '^org\.gradle\.jvmargs=' "$gp" 2>/dev/null || printf 'org.gradle.jvmargs=-Xmx1024m\n' >> "$gp"
}

patch_gradle_properties

# icon injection (overwrite; avoid duplicate resources)
inject_icon() {
  local icon_path="${1:-}"
  [[ -n "$icon_path" ]] || return 0

  local icon_abs
  icon_abs="$(abs_path "$icon_path")"
  [[ -f "$icon_abs" ]] || die "Icon not found: $icon_abs"

  local res="$STAGE/app/src/main/res"
  [[ -d "$res" ]] || die "Expected Android app module at: $res (no app/src/main/res)"

  # wipe existing launcher resources inside STAGE to avoid duplicates
  find "$res" -type f \( \
      -name 'ic_launcher.*' \
      -o -name 'ic_launcher_round.*' \
      -o -name 'ic_launcher_foreground.*' \
      -o -name 'ic_launcher_background.*' \
    \) -path '*/mipmap*/*' -delete 2>/dev/null || true

  find "$res" -type f -name 'ic_launcher*.xml' -path '*/mipmap-anydpi-*/*' -delete 2>/dev/null || true

  log "Using icon: $icon_abs"

  mkdir -p "$res/mipmap-mdpi-v4" "$res/mipmap-hdpi-v4" "$res/mipmap-xhdpi-v4" \
           "$res/mipmap-xxhdpi-v4" "$res/mipmap-xxxhdpi-v4"

  local tmp="$STAGE/.authai_icon_512.png"

  if command -v magick >/dev/null 2>&1; then
    magick "$icon_abs" -auto-orient -resize 512x512^ -gravity center -extent 512x512 "$tmp"
    magick "$tmp" -resize 48x48   "$res/mipmap-mdpi-v4/ic_launcher.png"
    magick "$tmp" -resize 72x72   "$res/mipmap-hdpi-v4/ic_launcher.png"
    magick "$tmp" -resize 96x96   "$res/mipmap-xhdpi-v4/ic_launcher.png"
    magick "$tmp" -resize 144x144 "$res/mipmap-xxhdpi-v4/ic_launcher.png"
    magick "$tmp" -resize 192x192 "$res/mipmap-xxxhdpi-v4/ic_launcher.png"
  elif command -v convert >/dev/null 2>&1; then
    convert "$icon_abs" -auto-orient -resize 512x512^ -gravity center -extent 512x512 "$tmp"
    convert "$tmp" -resize 48x48   "$res/mipmap-mdpi-v4/ic_launcher.png"
    convert "$tmp" -resize 72x72   "$res/mipmap-hdpi-v4/ic_launcher.png"
    convert "$tmp" -resize 96x96   "$res/mipmap-xhdpi-v4/ic_launcher.png"
    convert "$tmp" -resize 144x144 "$res/mipmap-xxhdpi-v4/ic_launcher.png"
    convert "$tmp" -resize 192x192 "$res/mipmap-xxxhdpi-v4/ic_launcher.png"
  else
    die "ImageMagick not installed (needed for --icon): pkg install imagemagick"
  fi

  rm -f "$tmp" 2>/dev/null || true
}

inject_icon "${ICON:-}"

# build
TRACE="$HOME/authai_trace.txt"
rm -f "$TRACE" 2>/dev/null || true

log "Running ./gradlew assembleDebug (logs -> $TRACE)"
if ./gradlew assembleDebug --no-daemon >"$TRACE" 2>&1; then
  APK_PATH="$(find "$STAGE" -type f -name "*.apk" \
    -path "*/build/outputs/apk/*" \
    -not -path "*/build-cache/*" \
    -not -path "*/androidTest/*" \
    -not -name "*unaligned*" | head -n 1 || true)"

  [[ -f "${APK_PATH:-}" ]] || die "Build finished but APK not located. Check $TRACE"

  OUTDIR="$HOME/authai_builds/$SAFE_ID"
  mkdir -p "$OUTDIR"
  FINAL="$OUTDIR/${SAFE_ID}-debug.apk"
  cp -f "$APK_PATH" "$FINAL"

  log "OK -> $FINAL"
  echo
  echo "Next:"
  echo "  cp -f \"$FINAL\" \"$HOME/storage/downloads/\""
  echo "  termux-open \"$HOME/storage/downloads/$(basename "$FINAL")\""
  exit 0
else
  echo "------ Gradle failed (tail) ------" >&2
  tail -n 80 "$TRACE" >&2 || true
  echo "---------------------------------" >&2
  die "Gradle build failed. See: $TRACE"
fi
AUTHAI_EOF

  chmod +x "$AUTH_DST"
  log "Installed -> $AUTH_DST"
  log "Try: authai --help"
}

uninstall(){
  if [[ -f "$AUTH_DST" ]]; then
    rm -f "$AUTH_DST"
    log "Removed -> $AUTH_DST"
  else
    log "Nothing to remove."
  fi
}

case "$cmd" in
  install) install ;;
  uninstall) uninstall ;;
  doctor) doctor ;;
  *) usage; exit 1 ;;
esac
