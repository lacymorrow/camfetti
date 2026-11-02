# CamFetti

iPhone camera viewer (SwiftUI, iOS 18+, Swift 6 strict concurrency).

- Project file is generated: edit `project.yml`, then `xcodegen generate`. Never hand-edit the .xcodeproj.
- Tests need the rig: `rig/start.sh` (MediaMTX on :8554, fake Thingino on :8080, Bonjour "Rig Porch"). `rig/stop.sh` after.
- Build/test: `xcodebuild test -scheme CamFetti -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd`.
- If simctl hangs: `killall -9 com.apple.CoreSimulator.CoreSimulatorService`, retry once.
- Site: static files in `site/`, Vercel project `camfetti`, domain camfetti.lacy.sh.
- Rules: never log or persist camera passwords outside the Keychain. Never retry a camera login after a 401 (cameras lock out). Thingino motor params must stay integers (upstream `json-motor.cgi` evals the query string).
- No em dashes in any copy. Public copy goes through `humanizer`.
- TestFlight: `scripts/testflight.sh` archives Release (build number = 9 + commit count) and uploads with the App Store Connect API key. `scripts/testflight.sh export` builds the signed store IPA without uploading.
