#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[Authai-Install] $*"; }
die(){ echo "[Authai-Install ERROR] $*" >&2; exit 1; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
AUTH_BIN="$PREFIX/bin/authai"                                   UNINSTALL_BIN="$PREFIX/bin/authai-uninstall"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_HOME

log "Actualizando indices..."
pkg update -y || true
dpkg --configure -a >/dev/null 2>&1 || true

log "Instalando dependencias..."
pkg install -y \
  openjdk-17 \
  aapt2 \
  android-tools \
  zip \
  unzip \
  curl \
  ca-certificates \
  termux-tools || { dpkg --configure -a; pkg install -y openjdk-17 aapt2 android-tools zip unzip curl ca-certificates termux-tools; }

have_build_tools(){ ls -1d "$ANDROID_HOME"/build-tools/* >/dev/null 2>&1; }
have_platforms(){ ls -1d "$ANDROID_HOME"/platforms/android-* >/dev/null 2>&1; }

find_sdkmanager() {
  if [[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
    echo "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    return 0
  fi
  if command -v sdkmanager >/dev/null 2>&1; then
    command -v sdkmanager
    return 0
  fi
  return 1
}

ensure_sdk() {
  mkdir -p "$ANDROID_HOME"
  if have_build_tools && have_platforms; then
    log "Android SDK detectado en $ANDROID_HOME"
    return 0
  fi

  if SM="$(find_sdkmanager)"; then
    log "sdkmanager encontrado: $SM"
    mkdir -p "$HOME/.android"
    : > "$HOME/.android/repositories.cfg" 2>/dev/null || true

    yes | "$SM" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true

    log "Instalando SDK minimo (platform-tools, build-tools 34.0.0, platform 34)..."
    "$SM" --sdk_root="$ANDROID_HOME" \
      "platform-tools" \
      "build-tools;34.0.0" \
      "platforms;android-34" || true
  fi

  have_build_tools && have_platforms || die "SDK incompleto en $ANDROID_HOME. Debe existir build-tools/* y platforms/android-*/android.jar"
  log "SDK listo."
}

ensure_sdk

log "Instalando Authai en: $AUTH_BIN"
cat > "$AUTH_BIN" <<'AUTHAI_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

die(){ echo "[Authai ERROR] $*" >&2; exit 1; }
log(){ echo "[Authai] $*"; }

# Evita crashear si el cwd desaparece
safe_cwd() {
  pwd >/dev/null 2>&1 || cd "$HOME" || die "No puedo entrar a un directorio valido."
}
safe_cwd

# Banner
clear
cat <<'BANNER'
======================================
 Authai - Java -> APK Builder (Termux)
 by git5 LoxoSec 🐘
 https://github.com/git5loxosec
======================================
BANNER
echo

SRC_ARG="${1:-}"
APPNAME="${2:-}"
PKG_ARG="${3:-}"

[[ -n "$SRC_ARG" && -n "$APPNAME" ]] || die "Uso: authai Archivo.java AppName [package.name]"
[[ "$SRC_ARG" == *.java ]] || die "Archivo debe terminar en .java"

# El archivo se toma desde donde lo invocas (no junto a authai)
if [[ "$SRC_ARG" == /* || "$SRC_ARG" == ./* || "$SRC_ARG" == ../* ]]; then
  SRC="$SRC_ARG"
else
  SRC="$(pwd)/$SRC_ARG"
fi
[[ -f "$SRC" ]] || die "No existe el archivo: $SRC_ARG (buscado en: $(pwd))"

command -v aapt2 >/dev/null || die "Falta aapt2 (pkg install aapt2)"
command -v javac >/dev/null || die "Falta javac (pkg install openjdk-17)"
command -v java  >/dev/null || die "Falta java (pkg install openjdk-17)"
command -v zip   >/dev/null || die "Falta zip (pkg install zip)"
command -v zipalign >/dev/null || die "Falta zipalign (pkg install android-tools)"
command -v keytool >/dev/null || die "Falta keytool (pkg install openjdk-17)"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
[[ -d "$ANDROID_HOME" ]] || die "ANDROID_HOME no existe: $ANDROID_HOME"

BT="$(ls -1d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${BT:-}" && -d "$BT" ]] || die "No hay build-tools en $ANDROID_HOME/build-tools"

PLATFORM_DIR="$(ls -1d "$ANDROID_HOME"/platforms/android-* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${PLATFORM_DIR:-}" && -d "$PLATFORM_DIR" ]] || die "No hay platforms en $ANDROID_HOME/platforms"
PLAT="$PLATFORM_DIR/android.jar"
[[ -f "$PLAT" ]] || die "No encuentro android.jar: $PLAT"

APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || die "No encuentro apksigner en: $APKSIGNER"

D8BIN="$BT/d8"
D8JAR="$BT/lib/d8.jar"
[[ -x "$D8BIN" || -f "$D8JAR" ]] || die "No encuentro d8 en build-tools: $BT"

# Clase publica principal
PUBLIC_CLASS="$(sed -nE 's/^[[:space:]]*public[[:space:]]+(final[[:space:]]+)?class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*.*/\2/p' "$SRC" | head -n 1 || true)"
[[ -n "$PUBLIC_CLASS" ]] || die "No detecto 'public class X' en el archivo."

# Package detectado (si existe)
PKG_IN_FILE="$(sed -nE 's/^[[:space:]]*package[[:space:]]+([a-zA-Z0-9_.]+)[[:space:]]*;.*/\1/p' "$SRC" | head -n 1 || true)"

if [[ -n "${PKG_ARG:-}" ]]; then
  PKG="$PKG_ARG"
elif [[ -n "${PKG_IN_FILE:-}" ]]; then
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

# Copia el src con nombre correcto (javac exige match)
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
[[ -f "$RJAVA" ]] || die "R.java no generado (package mismatch). Esperaba: $RJAVA"

javac -source 8 -target 8 \
  -classpath "$PLAT" \
  -d "$OUT/classes" \
  "$SRC_DST" \
  "$RJAVA"

log "d8..."
# FIX REAL: pasar .class como ARRAY (no string con espacios)
mapfile -d '' -t CLASS_ARR < <(find "$OUT/classes" -type f -name "*.class" -print0)
(( ${#CLASS_ARR[@]} > 0 )) || die "No hay .class para convertir."

if [[ -x "$D8BIN" ]]; then
  "$D8BIN" --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_ARR[@]}"
else
  java -cp "$D8JAR" com.android.tools.r8.D8 --min-api 24 --lib "$PLAT" --output "$OUT" "${CLASS_ARR[@]}"
fi

[[ -f "$OUT/classes.dex" ]] || die "No se creó classes.dex"

log "empaquetando..."
cp "$OUT/base.apk" "$OUT/unsigned.apk"
zip -q -j "$OUT/unsigned.apk" "$OUT/classes.dex"

log "zipalign..."
zipalign -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [[ ! -f "$KEYSTORE" ]]; then
  log "creando keystore..."
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Authai,O=Authai"
else
  log "usando keystore existente: $KEYSTORE"
fi

log "firmando..."
FINAL="$WORK/${APPNAME,,}-signed.apk"
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" --out "$FINAL" "$OUT/aligned.apk"

log "verificando firma..."
"$APKSIGNER" verify --verbose "$FINAL" >/dev/null || die "apksigner verify fallo."

log "verificando zipalign..."
zipalign -c -v 4 "$FINAL" >/dev/null || die "zipalign -c fallo."

log "OK -> $FINAL"
AUTHAI_EOF

chmod +x "$AUTH_BIN"

log "Creando desinstalador en: $UNINSTALL_BIN"
cat > "$UNINSTALL_BIN" <<'UN_EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[Authai-Uninstall] $*"; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
AUTH_BIN="$PREFIX/bin/authai"
UNINSTALL_BIN="$PREFIX/bin/authai-uninstall"
PURGE="${1:-}"

rm -f "$AUTH_BIN" "$UNINSTALL_BIN" 2>/dev/null || true
rm -rf "$HOME/authai_builds" 2>/dev/null || true

if [[ "$PURGE" == "--purge" ]]; then
  rm -rf "$HOME/keystores" "$HOME/android-sdk" "$HOME/.authai" 2>/dev/null || true
  log "PURGE completo."
else
  log "Desinstalado. (keystore y android-sdk se conservan)"
  log "Para borrar TODO: authai-uninstall --purge"
fi

log "Listo."
UN_EOF

chmod +x "$UNINSTALL_BIN"
hash -r || true

log "Instalación lista."
echo "Uso: authai TuArchivo.java MiApp [com.tu.paquete]"
echo "Uninstall: authai-uninstall   (o authai-uninstall --purge)"
