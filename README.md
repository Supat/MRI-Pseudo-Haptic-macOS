# MRI Pseudo Haptic — macOS

Native macOS (SwiftUI + Objective-C++) application that

1. Captures live frames from a GigE Vision machine-vision camera using the **Allied Vision Vimba X** SDK.
2. Runs **Google MediaPipe** Hand Landmarker + Pose Landmarker on every frame.
3. Computes a signed wrist angle and classifies wrist activity as **Flexor** (palmar flexion), **Extensor** (dorsiflexion), or **Neutral**.
4. Renders the live video, the 21-point hand skeleton overlay, the forearm axis, and a wrist-angle HUD.
5. Broadcasts the wrist angle as newline-delimited JSON on a loopback TCP socket for downstream consumers (e.g. a haptics controller, Unity, Python logger).

## Project Layout

```
MRI-Pseudo-Haptic-macOS/
├── project.yml                        # XcodeGen specification
├── Models/                            # Drop MediaPipe .task files here
├── MRIPseudoHaptic/
│   ├── App/
│   │   ├── MRIPseudoHapticApp.swift
│   │   └── AppState.swift
│   ├── Camera/
│   │   ├── VimbaBridge.h              # Obj-C facade over VmbC
│   │   ├── VimbaBridge.mm             # C++ impl: streaming + CVPixelBuffer
│   │   └── VimbaCamera.swift          # Swift wrapper / Combine publisher
│   ├── HandTracking/
│   │   ├── HandLandmarker.swift       # MediaPipe HandLandmarker wrapper
│   │   ├── PoseLandmarker.swift       # MediaPipe PoseLandmarker wrapper
│   │   ├── WristAngleCalculator.swift # Signed angle + F/E classifier
│   │   └── FrameProcessor.swift       # Queue + pipeline orchestration
│   ├── Networking/
│   │   └── WristAngleBroadcaster.swift # Loopback TCP server (NWListener)
│   ├── Views/
│   │   ├── ContentView.swift          # Sidebar + live preview
│   │   ├── CameraPreviewView.swift    # MTKView + Core Image renderer
│   │   ├── HandOverlayView.swift      # SwiftUI Canvas skeleton overlay
│   │   └── StatusHUDView.swift        # Wrist angle HUD
│   └── Support/
│       ├── Info.plist
│       ├── MRIPseudoHaptic.entitlements
│       └── MRIPseudoHaptic-Bridging-Header.h
└── README.md
```

## Prerequisites

| Dependency | Version | Notes |
| --- | --- | --- |
| macOS | 13 Ventura or newer | Apple Silicon or Intel |
| Xcode | 15 or newer | Swift 5.9, `swiftc` |
| Allied Vision Vimba X | 2023-1 or newer | `libVmbC.dylib`, `VmbImageTransform` |
| MediaPipe Tasks Vision | 0.10.x | Prebuilt xcframework for macOS |
| XcodeGen | 2.38+ | `brew install xcodegen` |

## 1. Install Vimba X

Vimba X for macOS ships as a **`.dmg` disk image** — there is no
`.pkg` installer. You mount the image, drag the `VimbaX` folder to
wherever you want the SDK to live, and point the build at it. By
default this project expects the SDK to live at
`$(PROJECT_DIR)/ThirdParty/VimbaX`.

### 1a. Download and copy the SDK out of the DMG

1. Download **Vimba X for macOS** from the [Allied Vision developer
   portal](https://www.alliedvision.com/en/products/software/vimba-x-sdk/).
   The file is named something like `VimbaX_Setup-2024-1-macOS.dmg`.

2. Double-click the `.dmg` to mount it (Finder will open a window
   showing a folder called `VimbaX` or `VimbaX_<version>`).

3. Copy that folder out of the mounted image into this repository's
   `ThirdParty/` directory, and rename it to `VimbaX`:

   ```bash
   # Mount the DMG (Finder also does this when you double-click)
   hdiutil attach ~/Downloads/VimbaX_Setup-*-macOS.dmg

   # The DMG mounts at /Volumes/VimbaX (the volume name may include
   # the version number — adjust the glob if needed).
   mkdir -p ThirdParty
   cp -R /Volumes/VimbaX*/VimbaX* ThirdParty/VimbaX

   # Eject the image
   hdiutil detach /Volumes/VimbaX*
   ```

   If Finder shows the SDK folder with a version suffix
   (e.g. `VimbaX_2024-1`), just make sure you end up with
   `ThirdParty/VimbaX/` in this repo after the copy.

4. Verify the headers and dylibs landed in the expected spots:

   ```bash
   ls ThirdParty/VimbaX/api/include/VmbC/VmbC.h
   ls ThirdParty/VimbaX/api/lib/libVmbC.dylib
   ls ThirdParty/VimbaX/api/lib/libVmbImageTransform.dylib
   ls ThirdParty/VimbaX/cti/               # GenTL transport layers
   ```

   If your Vimba X release uses a slightly different internal layout
   (Allied Vision occasionally reshuffles folders between versions),
   open `Config/VimbaX.xcconfig` and change `VIMBA_X_HOME` — or the
   `HEADER_SEARCH_PATHS` / `LIBRARY_SEARCH_PATHS` lines — to point at
   the folder that actually contains `api/include/VmbC/VmbC.h`.

### 1b. Install somewhere else

If you'd rather drop the SDK into `/Applications`, `$HOME`, or
`/opt` instead of vendoring it in the repo, just drag the `VimbaX`
folder out of the DMG to that location and update
`Config/VimbaX.xcconfig`:

```
VIMBA_X_HOME = /Applications/VimbaX
```
or
```
VIMBA_X_HOME = $(HOME)/VimbaX
```
or
```
VIMBA_X_HOME = /opt/VimbaX
```

### 1c. Clear the Gatekeeper quarantine

Because the SDK was downloaded from the web and unpacked from a
`.dmg`, macOS will have tagged every dylib with the
`com.apple.quarantine` attribute. The first time the app loads
`libVmbC.dylib` that tag causes Gatekeeper to kill the process. Strip
it once:

```bash
xattr -dr com.apple.quarantine ThirdParty/VimbaX
```

(Replace the path if you installed to a different location.)

### 1d. Runtime: GenTL transport layers

At runtime Vimba X loads GenTL transport layer bundles (`.cti` files)
from the directories listed in the `GENICAM_GENTL64_PATH` environment
variable. Without it set, `VmbStartup` succeeds but no cameras are
discovered. Set the variable in the Xcode scheme so the running app
can find the GigE transport layer:

1. Product → Scheme → Edit Scheme…
2. Run → Arguments → Environment Variables
3. Add:
   `GENICAM_GENTL64_PATH = $(PROJECT_DIR)/ThirdParty/VimbaX/cti`
   (or an absolute path that matches your `VIMBA_X_HOME`).

Alternatively, `source ThirdParty/VimbaX/SetGenTLPath.sh` (or
`Install.sh`, depending on the release) in a terminal before
launching Xcode — the script exports the variable into the current
shell and any child processes inherit it.

### 1e. Sanity check

Launch **Vimba X Viewer** (found in `ThirdParty/VimbaX/Tools/` or
`ThirdParty/VimbaX/bin/`, depending on the release) once and verify
you can stream from your GigE camera. Configure the camera IP to be
on the same link-local or private subnet as your Mac. Set
`PacketSize` to something the host NIC can handle (typically 1500
for standard NICs, 9000 for jumbo frames).

## 2. Install MediaPipe Tasks Vision

MediaPipe Tasks Vision ships as a prebuilt framework. The cleanest path on macOS is CocoaPods:

```bash
sudo gem install cocoapods
cd MRI-Pseudo-Haptic-macOS
cat > Podfile <<'POD'
platform :osx, '13.0'
target 'MRIPseudoHaptic' do
  use_frameworks!
  pod 'MediaPipeTasksVision'
end
POD
pod install
```

Open `MRIPseudoHaptic.xcworkspace` afterwards (not the `.xcodeproj`). If you'd rather vendor the xcframework directly, drop it into `ThirdParty/MediaPipe/` and add it as an **Embedded Framework** on the `MRIPseudoHaptic` target.

Download the `.task` model files and put them in `Models/`:

```bash
mkdir -p Models
curl -L -o Models/hand_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task
curl -L -o Models/pose_landmarker_lite.task \
  https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task
```

`project.yml` already adds the `Models/` folder as a resource, so the files will be copied into the `.app` bundle.

## 3. Generate the Xcode project

```bash
brew install xcodegen        # one-time
xcodegen generate
open MRIPseudoHaptic.xcodeproj    # or the .xcworkspace if you ran `pod install`
```

Build and run the **MRIPseudoHaptic** scheme. macOS will prompt for camera permission on first launch; accept it. The GigE transport layer does **not** use AVFoundation — this permission is claimed only so the entitlement file remains consistent.

## 4. Usage

1. Connect the GigE camera and give it ~5 seconds to negotiate a link.
2. In the app sidebar, press **Refresh** — your camera appears in the picker.
3. Press **Start** to begin streaming. The live video appears in the centre with the hand skeleton overlay (green bones, yellow joints, red wrist, cyan dashed forearm axis).
4. The HUD in the bottom-right shows the signed wrist angle in degrees and the Flexor/Extensor/Neutral classification.
5. Press **Start Server** under *TCP Broadcaster* to begin publishing wrist angles on `127.0.0.1:45123`. Subscribe from any loopback client:

   ```bash
   nc 127.0.0.1 45123
   ```

   Every sample is a one-line JSON record:

   ```json
   {"t":1712760000.123,"angle":-12.5,"class":"Extensor","valid":true}
   ```

## Wrist angle math

The pipeline combines the MediaPipe **Pose** and **Hand** landmarkers:

- `forearm = pose.wrist − pose.elbow` (whichever arm is closer to the detected hand)
- `hand    = hand.middleMCP − hand.wrist`
- `θ = atan2(|forearm × hand|, forearm · hand)` — unsigned angle between the two vectors.
- `signed_angle = ±θ`, where the sign is chosen from the 2D cross product combined with MediaPipe's handedness prediction (`Left` vs `Right`).
- The output is low-pass filtered (one-pole, configurable `smoothing` factor) and thresholded against a configurable neutral zone (default ±8°) to classify:
  - `angle > +neutralZone` → **Flexor** (palmar flexion)
  - `angle < −neutralZone` → **Extensor** (dorsiflexion)
  - otherwise → **Neutral**

If the pose landmarker fails to detect the body, the code falls back to the assumption that the forearm points upward in the frame. This is obviously camera-dependent — for MRI ergonomic studies we recommend keeping pose detection enabled and framing the scene so the elbow is always visible.

## Performance notes

- The VmbFrame callback runs on Vimba's internal thread pool. `VimbaBridge.mm` converts each frame into a pooled BGRA `CVPixelBuffer` using `VmbImageTransform`, so MediaPipe never sees raw Bayer data.
- `FrameProcessor` drops frames if the previous inference has not finished, which keeps latency bounded. On an M2 Pro with the `hand_landmarker.task` float16 model and `pose_landmarker_lite.task`, end-to-end latency typically sits around 15–25 ms per frame.
- The SwiftUI preview uses `MTKView` + `CIContext` directly on the Vimba pixel buffer — no extra copies on the GPU path.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `VmbC.h not found` / linker can't find `-lVmbC` | `VIMBA_X_HOME` in `Config/VimbaX.xcconfig` does not point at a folder containing `api/include/VmbC/VmbC.h` and `api/lib/libVmbC.dylib`. Fix the path and re-run `xcodegen generate`. |
| `VmbStartup failed` on launch | The GenTL transport layers are not on the loader path. Set `GENICAM_GENTL64_PATH` in the Xcode scheme (see step 1c) or source `ThirdParty/VimbaX/Install.sh` in the shell you launch Xcode from. |
| Gatekeeper kills the app when it loads `libVmbC.dylib` | Clear the quarantine flag: `xattr -dr com.apple.quarantine ThirdParty/VimbaX`. |
| Camera is listed but `VmbCameraOpen` fails | Another process (Vimba X Viewer, another copy of the app) has the camera open. |
| Dropped frames / `Incomplete frame` errors | Bump `AcquisitionFrameRate` down or enable jumbo frames on your NIC. |
| MediaPipe throws `Task file not found` | Make sure `hand_landmarker.task` and `pose_landmarker_lite.task` were added to the target as resources and are in `Models/`. |
| App launches but the sandbox blocks the camera | This project intentionally runs **unsandboxed** (`com.apple.security.app-sandbox = false`) because the GigE transport layer needs raw socket access. Do not re-enable the sandbox. |
| TCP clients cannot connect | Confirm the port in the sidebar is free (`lsof -i :45123`) and that the broadcaster status reads `Listening on 127.0.0.1:…`. |

## License / third-party

- **Allied Vision Vimba X SDK** — proprietary, subject to Allied Vision's EULA.
- **MediaPipe** — Apache 2.0.
- This project's source code in `MRIPseudoHaptic/` is released under the repository license.
