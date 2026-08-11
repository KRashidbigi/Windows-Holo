# Windows Holo

[![Port of JustinGamer191/Holo](https://shields.io)](https://github.com)

A universal, ultra-lightweight, zero-dependency acoustic tap-tracking utility built for **all Windows 10 and 11 laptops** (supporting both **x64** and **ARM64** architectures). 

Turn the physical desk space surrounding your laptop into four interactive macro zones using only your device's built-in microphone—no extra hardware required.

## Universal Macro Layout
* **Upper Left (Left Rear):** Master Volume Up
* **Lower Left (Left Front):** Master Volume Down
* **Upper Right (Right Rear):** Open Microsoft Teams
* **Lower Right (Right Front):** Open VS Code

## How to Run
1. Clone or download this repository.
2. Double-click `LaunchHolo.bat` to bypass execution rules safely for this session.
3. Follow the terminal prompts to calibrate your 4 physical desk quadrants (5 taps each).

## Crucial Troubleshooting for All Laptops
Because modern laptop manufacturers include heavy AI filtering to remove table noises, **you must turn off microphone enhancements** for this script to function:
1. Open the Windows Start Menu, search for **Samsung Settings**, **HP Command Center**, or **Realtek Audio Console** (depending on your brand) and turn off **AI Noise Canceling** / **Vocal Isolation**.
2. Alternatively, press `Win + R`, type `mmsys.cpl`, go to the **Recording** tab -> **Microphone Properties** -> **Advanced**, and uncheck **Enable audio enhancements**.

## Architectural Mapping: macOS vs. Windows Port

| Feature Component | Original macOS Implementation (Swift) | This Universal Windows Port (PowerShell) |
| :--- | :--- | :--- |
| **Audio Capture Engine** | `AVFoundation` / `AVAudioEngine` | `winmm.dll` (`waveInOpen` API via P/Invoke) |
| **Processor Support** | Apple Silicon (M1/M2/M3) | Universal **Intel, AMD (x64) & Snapdragon (ARM64)** |
| **Classification Model**| K-Nearest Neighbors Classifier | In-memory Euclidean Distance Matrix Loops |

## Credits & Acknowledgments
This project is an unofficial Windows port inspired by the macOS utility **[Holo](https://github.com)** developed by **[JustinGamer191](https://github.com)**. 
