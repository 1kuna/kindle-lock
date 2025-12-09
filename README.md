# kindle-lock

An iOS 26 app that locks social media apps until you've completed your daily Kindle reading goal. Uses Apple's Liquid Glass design language.

## How It Works

1. **Sign in** to your Amazon account via the app
2. **Select apps** you want blocked (social media, games, etc.)
3. **Read** on any Kindle device or app (progress syncs to cloud)
4. **Apps unlock** when you hit your daily goal

The app directly calls Amazon's Kindle web reader APIs (read.amazon.com) to track your reading progress—no server required.

## Requirements

- iPhone running iOS 26+
- macOS with Xcode 16+ (iOS 26 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Physical device (Screen Time APIs don't work in simulator)

## Quick Start

```bash
# Install XcodeGen
brew install xcodegen

# Generate Xcode project
cd KindleLock
xcodegen generate

# Open in Xcode
open KindleLock.xcodeproj
```

Then:
1. Select your Team in Signing & Capabilities for all targets
2. Connect your iPhone
3. Build and run (Cmd+R)

## Features

- **Liquid Glass UI** - Full iOS 26 design language
- **FamilyControls** - Uses Screen Time APIs to block selected apps
- **Custom Shields** - Branded screens when blocked apps are opened
- **Background Refresh** - Automatically syncs reading progress
- **No Server Required** - Direct Amazon API calls from device

## Project Structure

```
KindleLock/
├── KindleLock/           # Main app
├── ShieldConfiguration/  # Shield UI extension
├── ShieldAction/         # Shield button handler
└── project.yml           # XcodeGen config
```

See `KindleLock/README.md` for detailed iOS app documentation.

## Archived

The `archived/` directory contains the deprecated Python/Docker backend that was previously used to scrape Kindle progress from a Raspberry Pi server.

## License

MIT
