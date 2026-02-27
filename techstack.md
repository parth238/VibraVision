# Tech Stack & File Map 📚

This document details the technologies used and the purpose of key files in the repository.

## 💻 Technology Stack

| Component | Technology | Description |
| :--- | :--- | :--- |
| **Framework** | **Flutter** (Dart 3) | Cross-platform UI and logic. |
| **Core Logic** | **C++ 17** | High-performance signal processing and FFT. |
| **Bridge** | **JNI / FFI** | Interface between Dart and Native C++. |
| **Charts** | `fl_chart` | Rendering the frequency spectrum. |
| **Camera** | `camera` package | Capturing raw image streams. |
| **Sensors** | `sensors_plus` | Accessing accelerometer for stability check. |

---

## 📂 File Structure & Purpose

Here is a map of the critical files in `c:\Users\lenovo\StudioProjects\vibravision`:

### 🟢 Root
*   `README.md`: Project overview and setup.
*   `technical_architecture.md`: System design and diagrams.
*   `blueprint.md`: Project mission and problem/solution.
*   `pubspec.yaml`: Dart dependencies and asset configuration.

### 🟡 Flutter (Dart) - `lib/`
*   **`lib/main.dart`**: **The Application Core.**
    *   *Purpose*: Handles the UI, camera preview, user interaction (RPM input), and displays results/charts.
    *   *Key Classes*: `VisionScreen`, `_VisionScreenState`.
*   **`lib/services/native_bridge.dart`** (Implied):
    *   *Purpose*: The communication channel. Defines the JNI/FFI methods to call C++ functions from Dart.

### 🔴 Native (C++) - `android/app/src/main/cpp/`
*   **`dsp_core.h`**: **The Physics Engine.**
    *   *Purpose*: Defines the `DSPCore` class and `AdaptiveThreshold` logic.
    *   *Key Logic*:
        *   `process()`: Main pipeline (Signal -> Window -> FFT -> Peaks).
        *   `diagnoseFault()`: The logic that decides if it's Unbalance, Misalignment, etc. based on RPM.
    *   *Structs*: `DSPResult`, `Peak`, `HealthStatus`.
*   **`dsp_core.cpp`** (Implied):
    *   *Purpose*: Implementation of the algorithms defined in the header.

### 🔵 Configuration - `android/app/src/main/`
*   `AndroidManifest.xml`: Android permissions (Camera).
*   `build.gradle`: Native build configuration (CMake/NDK setup).
