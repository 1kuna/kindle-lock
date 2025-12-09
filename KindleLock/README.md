# KindleLock iOS App

An iOS 26 app using Apple's Liquid Glass design language that blocks social media apps until you complete your daily Kindle reading goal.

## Requirements

- macOS with Xcode 16+ (iOS 26 SDK)
- iPhone running iOS 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation
- Raspberry Pi backend running (see parent directory)

## Setup

### 1. Install XcodeGen

```bash
brew install xcodegen
```

### 2. Generate Xcode Project

```bash
cd KindleLock
xcodegen generate
```

This creates `KindleLock.xcodeproj` from `project.yml`.

### 3. Open in Xcode

```bash
open KindleLock.xcodeproj
```

### 4. Configure Signing

1. Select the KindleLock target
2. Go to Signing & Capabilities
3. Select your Team
4. Repeat for ShieldConfiguration and ShieldAction targets

### 5. Build and Run

- Connect your iPhone (Screen Time APIs require physical device)
- Select your device as the run destination
- Build and run (Cmd+R)

## Project Structure

```
KindleLock/
├── KindleLock/                    # Main app target
│   ├── KindleLockApp.swift        # App entry point
│   ├── Models/
│   │   ├── AppState.swift         # Observable app state
│   │   └── ReadingProgress.swift  # API models
│   ├── Services/
│   │   ├── APIService.swift       # Backend API client
│   │   ├── ShieldManager.swift    # ManagedSettings wrapper
│   │   └── SettingsStore.swift    # UserDefaults persistence
│   ├── Views/
│   │   ├── ContentView.swift      # Root navigation
│   │   ├── SetupFlow/             # Onboarding views
│   │   ├── Dashboard/             # Main app views
│   │   └── Settings/              # Settings view
│   └── Shared/
│       └── Constants.swift        # Shared constants
├── ShieldConfiguration/           # Shield UI extension
└── ShieldAction/                  # Shield button handler extension
```

## Features

- **Liquid Glass UI**: Full iOS 26 Liquid Glass design with `glassEffect()` modifiers
- **FamilyControls**: Uses Screen Time APIs to block selected apps
- **Background Refresh**: Periodically syncs reading progress
- **Custom Shields**: Branded shield screens when blocked apps are opened

## Entitlements

The app requires the FamilyControls entitlement:
- `com.apple.developer.family-controls`

This entitlement can be requested at App Store submission time. For development, it works with your development team's provisioning profile.

## Configuration

1. **Server URL**: Enter your Raspberry Pi's IP address (e.g., `http://192.168.1.100:8080`)
2. **API Key**: Optional, leave empty if not configured on the server
3. **Blocked Apps**: Select apps/categories to block using the FamilyActivityPicker

## Testing

- **Simulator**: Screen Time APIs don't work in the simulator. Use a physical device.
- **Local Network**: Ensure your iPhone and Pi are on the same network
- **Shield Testing**: After selecting apps, try opening a blocked app to see the custom shield

## Troubleshooting

### "FamilyControls authorization failed"
- Make sure the entitlement is properly configured
- The user needs to grant permission in Settings > Screen Time

### "Connection failed"
- Verify the Pi backend is running: `curl http://<pi-ip>:8080/health`
- Check firewall settings on the Pi
- Ensure both devices are on the same network

### Shield not appearing
- Shields only appear when `goalMet` is false
- Check that you've selected apps to block
- Try removing and re-adding the blocked apps

## Architecture

The app uses:
- **@Observable** macro for state management (Swift 5.9+)
- **SwiftUI** with iOS 26 Liquid Glass APIs
- **FamilyControls/ManagedSettings** for app blocking
- **App Groups** for sharing data with extensions
