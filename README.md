🐘 Authai

Authai is a lightweight Java → APK builder designed for Termux, focused on Android development, testing, and learning.

It allows you to convert a single Java file into a fully signed, installable Android APK without Android Studio or Gradle.

> by git5 · LoxoSec

---

⚠️ Disclaimer

Authai is intended for educational, testing, and development purposes.

You are responsible for how you use the generated APKs.

---

✨ Features

Java → APK in one command

Automatic Android SDK bootstrap

Automatic keystore creation & reuse

APK signing (v2 / v3 schemes)

Zipalign verification

Package auto-detection

Public class auto-detection

Works entirely inside Termux

Single-file installer

Built-in uninstall

APK verification helpers

Optional icon support (PNG auto-resize to 512×512)

No Gradle, no Android Studio, no IDE required

---

📦 Installation

git clone https://github.com/git5loxosec/Authai.git

cd Authai

chmod +x install-authai.sh

./install-authai.sh

After installation:

authai

---

🧪 Usage

authai File.java AppName [package.name]

Example

authai MainApp.java DemoApp

With package:

authai MainApp.java DemoApp com.example.demo

Generated APK:

~/authai_builds/demoapp/demoapp-signed.apk

---

🖼 Icon Support

Authai can:

Auto-detect icon.png if present

Accept any PNG filename

Resize it to 512×512 automatically

Inject it into the APK

If no icon is provided, the APK is generated normally.

---

🔍 APK Verification (Optional)

APK="$HOME/authai_builds/demoapp/demoapp-signed.apk"
BT="$(ls -1d "$HOME/android-sdk/build-tools/"* | sort -V | tail -n 1)"

"$BT/apksigner" verify --verbose --print-certs "$APK"
zipalign -c -v 4 "$APK"
aapt2 dump badging "$APK"
unzip -t "$APK"

---

📲 Install APK

GUI

termux-open "$APK"

ADB

adb install -r "$APK"

---

🗑 Uninstall

authai-uninstall

Full cleanup:

authai-uninstall --purge

---

🧠 Philosophy

Authai exists to make Android APK building:

Simple
Transparent
Portable
Educational
Minimal
No hidden magic. No bloated tooling.
