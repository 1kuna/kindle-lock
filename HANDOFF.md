# KindleLock Handoff - 2026-06-22

This handoff is repo-state-only. No discoverable owner thread or saved project
history was available for `/Users/zach/Documents/Git/kindle-lock`, so the
existing root `HANDOFF.md` was treated as a draft and checked against the live
repository before replacement.

## Repository State

- Repo: `/Users/zach/Documents/Git/kindle-lock`
- Branch: `main`
- HEAD: `327b17f34b381793aacac6ee4ae417c14c0f5e4e`
- HEAD subject: `Checkpoint KindleLock handoff`
- Remote: `origin https://github.com/1kuna/kindle-lock.git`
- Remote status after `git fetch --prune origin`: `main`, `origin/main`, and
  `origin/HEAD` all point at `327b17f34b381793aacac6ee4ae417c14c0f5e4e`.
- Working tree before this handoff replacement: clean.

## Current Product Shape

The active product is the iOS app under `KindleLock/`. The old Python/Docker
backend is in `archived/` and is not the active path.

The generated Xcode project currently has four targets:

- `KindleLock`: main iOS app.
- `ShieldConfiguration`: Managed Settings shield UI extension.
- `ShieldAction`: Managed Settings shield action extension.
- `KindleAPITester`: separate debug app depending on `swift-kindle`; the main
  app uses its own `KindleAPIService`, not this package.

`KindleLock/project.yml` is the source config for regenerating the project. It
sets iOS deployment target `26.0`, Swift `6.0`, development team `A74G8926JQ`,
main bundle id `com.kindlelock.app`, and embeds the two shield extensions.

## Kindle API And Progress State

Authentication is WKWebView-based:

- `AmazonLoginView` loads `https://read.amazon.com/kindle-library`.
- `KindleAuthService.deviceTokenCaptureScript` injects JavaScript at document
  start to intercept fetch, XHR, and sendBeacon calls containing
  `getDeviceToken`.
- Successful auth requires Amazon cookies including `at-main` and `session-id`,
  plus a captured or previously stored device token.
- Cookies, device token, and ADP session token are stored through
  `KeychainService`.

Reading progress is direct-to-Amazon, no server:

- Quick library fetch: `/kindle-library/search?...querySize=20`.
- Full/deep library fetch: paginated `/kindle-library/search?...querySize=50`,
  capped in code at 20 pages.
- Position fetch: `/service/mobile/reader/startReading`.
- ADP session token acquisition: `/service/web/register/getDeviceToken`.
- Metadata comes from the `metadataUrl` returned by `startReading`; it is JSONP
  and is parsed for `startPosition` and `endPosition`.

Important distinction: `KindleAPIService.fetchLibraryWithProgress(...)` enriches
books in parallel with a task group and sorts results back to the original
library order. `AppState.refreshProgress()` uses that parallel path after first
fetching the quick library list. `AppState.triggerManualRefresh()` and
`AppState.performDeepScan()` still enrich books sequentially.

Daily progress is percentage-point based:

- Effective day rolls over at the configured reset hour, default `4`.
- New days inherit the previous day's last known book percentages as baselines.
- Only positive deltas from start-of-day percentage are counted.
- Last known percentages are kept as a high-water mark to dampen Whispersync
  position fluctuation.
- `TodayProgress` now initializes and encodes `date`; the shield extension has a
  mirror `ShieldTodayProgress` that must stay structurally aligned for decoding.

## FamilyControls And Shield State

The main app requests FamilyControls authorization for `.individual` on launch
and retry paths. Selected apps, categories, and web domains are stored as a
`FamilyActivitySelection` in the app group defaults.

`ShieldManager` applies shields through `ManagedSettingsStore`:

- `store.shield.applications` for selected application tokens.
- `store.shield.applicationCategories = .specific(...)` for selected category
  tokens.
- `store.shield.webDomains` for selected web domain tokens.
- When the reading goal is met, `AppState.updateShields()` clears all managed
  settings; otherwise it applies the current selection.

The shield extension configuration is present in both `KindleLock/project.yml`
and the generated plists:

- `ShieldConfiguration`: extension point
  `com.apple.deviceactivitymonitor.shield-configuration`, principal class
  `$(PRODUCT_MODULE_NAME).ShieldConfigurationExtension`.
- `ShieldAction`: extension point
  `com.apple.deviceactivitymonitor.shield-action`, principal class
  `$(PRODUCT_MODULE_NAME).ShieldActionExtension`.

`ShieldConfigurationExtension` reads cached progress from the shared app group
and displays custom shield copy with `Open Kindle` and `Check Progress` labels.
`ShieldActionExtension` currently returns `.defer` for primary and secondary
button taps; it does not directly open Kindle or KindleLock.

## Validation Performed

Local, narrow validation only:

- `git fetch --prune origin`
  - Result: local `main` already matched `origin/main`.
- `xcodebuild -list -project KindleLock/KindleLock.xcodeproj`
  - Result: project resolves packages and lists targets/schemes.
- `xcodebuild build -project KindleLock/KindleLock.xcodeproj -scheme KindleLock -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`
  - Result: `** BUILD SUCCEEDED **`.

No broad validation was run. No product code was changed. No push was performed.
There are no dedicated test targets visible in the Xcode project.

## Blockers And Cautions

- Simulator build only proves compile/package structure. FamilyControls
  authorization, ManagedSettings enforcement, and shield UI/action behavior need
  a physical iPhone with the proper Screen Time/FamilyControls entitlement path.
- Amazon `read.amazon.com` endpoints and login/device-token behavior are
  undocumented and can drift. Verify live responses before assuming this API
  shape is stable.
- Device token capture is load-bearing. If login appears successful but API
  calls fail, inspect the actual WKWebView traffic/captured token path first.
- `project.yml` and the generated Xcode project both currently contain shield
  extension metadata. If the project is regenerated, confirm the generated
  `Info.plist` output still has the `NSExtension` point identifiers and principal
  classes.
- The parallel enrichment performance claim still needs real-account timing.
  Measure the path that actually uses `fetchLibraryWithProgress(...)`; manual
  refresh and deep scan are still sequential in current code.
- Shield button labels imply opening Kindle/KindleLock, but the action extension
  currently defers to the system instead of opening URLs itself.

## Exact Next Steps

1. On a physical iPhone, install the app with the intended team/signing setup
   and confirm FamilyControls authorization succeeds.
2. Complete setup end to end: Amazon login, required cookies, captured device
   token, ADP token acquisition, app/category/domain selection, and setup
   completion.
3. With a real account, run the normal refresh path and verify:
   - quick library fetch returns the expected books,
   - parallel enrichment preserves order,
   - metadata cache fills with start/end positions,
   - today's percentage delta matches actual Kindle reading,
   - shields are applied before the goal and removed after the goal.
4. Open blocked apps/web domains on device and confirm the custom shield UI is
   shown and button behavior is acceptable despite `.defer`.
5. Time the parallel refresh path against a realistic library. Do not infer the
   performance of `fetchLibraryWithProgress(...)` from manual refresh or deep
   scan, because those are sequential today.
6. If XcodeGen is run, review the diff before committing and specifically check
   app-extension Info.plist metadata, bundle ids, entitlements, and embedded
   extension dependencies.
