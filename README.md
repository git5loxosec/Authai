# 🐘 Authai — Android APK Builder (Termux) *

### Works on Android 15!

Authai is a small Termux-first CLI that builds a debug APK from an existing Gradle Wrapper Android project.  
It stages (copies) your project into a clean workspace, applies a few Termux compatibility tweaks, optionally injects a launcher icon, then runs `./gradlew assembleDebug`.

It **never modifies your original project**.

---

# What it does (precise)

- Validates inputs (`project_dir`, `--name`, `--pkg`, optional `--icon`)
- Copies the project into: `~/.authai_work/<safe_name>`
- Sets Java (17 or 21) based on Gradle wrapper version
- Ensures Android SDK path is visible to Gradle via `local.properties`
- Patches `gradle.properties` (AAPT2 override if present, stable JVM args)
- (Optional) Overwrites launcher resources inside the staged project to avoid duplicate resource errors
- Runs: `./gradlew assembleDebug --no-daemon`
- Copies the resulting APK to: `~/authai_builds/<safe_name>/<safe_name>-debug.apk`
- Writes build logs to: `~/authai_trace.txt`

---

# Dependencies

## Required (Authai runtime)
- **Termux**
- **bash** (Termux default)
- **java**: `openjdk-17` (recommended) or `openjdk-21`
- **Android SDK** at one of:
  - `$ANDROID_HOME`
  - `$ANDROID_SDK_ROOT`
  - `~/android-sdk`
- A **Gradle Wrapper project** (must include `./gradlew`)

## Recommended
- **python** (for absolute path resolution; fallback exists if missing)
- **aapt2** (Termux native; used via `android.aapt2FromMavenOverride=...`)

## Optional (only if using `--icon`)
- **ImageMagick** (`magick` or `convert`)  
  Install: ```pkg install imagemagick```

---

# Install

You install Authai via the installer script shown in your final code:

```
chmod +x install-authai.sh
./install-authai.sh install
```

This writes the CLI to:

$PREFIX/bin/authai


Verify:
```
command -v authai
authai --help
```

---

Doctor (dependency check)
```
./install-authai.sh doctor
```
Checks:

bash, python (optional), java, aapt2 (recommended), ImageMagick (optional)

Android SDK location via env vars or ~/android-sdk


---

Usage
```
authai <project_dir> --name <AppName> --pkg <com.example.app> [--icon /path/icon.png]
```
Example:

authai "$HOME/android-simple-calculator" \
  --name AndroidCalc \
  --pkg com.authai.calc \
  --icon "$HOME/icon.png"

Outputs:

APK: ~/authai_builds/<safe_name>/<safe_name>-debug.apk

Logs: ~/authai_trace.txt

Staging workspace: ~/.authai_work/<safe_name>


---

Notes / behavior

Why staging?

Staging isolates the build so Authai can:

safely write local.properties, tweak gradle.properties, and replace launcher icon files

avoid polluting or breaking the source repo

make repeated builds reproducible (clean workspace every run)


Icon injection behavior

If --icon is provided, Authai:

deletes existing ic_launcher* and related launcher assets inside the staged project only

generates mipmap PNGs in mipmap-*-v4 from a 512×512 normalized source image

prevents the Duplicate resources error that happens when both .png and .webp variants coexist


---

Uninstall
```
./install-authai.sh uninstall
```
Removes:

$PREFIX/bin/authai

⚠️ Disclaimer

Authai is intended for educational, testing, and development purposes.

You are responsible for how you use the generated APKs.
