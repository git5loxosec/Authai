
 Authai - Java -> APK Builder (Termux)
 by git5 LoxoSec 🐘
 https://github.com/git5loxosec


Authai is a lightweight Android APK builder for Termux that compiles a single Java file into a fully signed, aligned, and installable APK using only Android SDK tools.

No Android Studio.  
No Gradle.  
No templates.  

Just Java → APK.

## Features

- Native Termux execution
- No Android Studio
- No Gradle
- Uses official Android SDK tools only
- Automatic resource generation
- Automatic dexing with D8
- Automatic APK alignment
- Automatic APK signing
- Automatic APK verification
- Deterministic build pipeline
- Works in restricted Android environments

---

## Dependencies

All dependencies will be automatically installed in Termux:

  openjdk-17
  aapt2
  android-tools
  zip
  unzip
  curl
  ca-certificates
  termux-tools

---

⚠️ Disclaimer

Authai is provided for educational and research purposes only.

The authors (git5 / LoxoSec) are not responsible for any misuse, damage, legal issues, or consequences derived from APKs built with this tool.

You are fully responsible for the code you compile and distribute.


---

🔐 Responsible Use

Authai exposes low-level Android build mechanics.
Use it only in legal, ethical, and controlled environments.


---

📜 License

Authai is released under GNU GPL v3.
All derivative works must remain open-source and properly attributed.
