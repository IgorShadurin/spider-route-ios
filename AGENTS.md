# SpiderRoute engineering guide

## Scope

This is the native iOS app. Website/backend: https://github.com/IgorShadurin/spiderroute.com. Website: https://spiderroute.com.

Keep current user instructions ahead of project defaults. Preserve unrelated work. Use narrowly scoped commits. Never commit credentials, signing assets, personal GPS tracks, physical-device identifiers, local machine paths, generated campaigns, recordings, or build output.

## Product contracts

- iOS 15 is the compatibility floor; iPhone and iPad are supported. Treat iPhone 6s Plus as a performance constraint.
- Keep the internal SpeedometerGPS target and existing saved-data formats compatible.
- Default navigation is Map, Speed, Rides; Camera appears only for its opt-in role.
- Live speed, warnings, map browsing, following, full-screen maps, offline downloads, and imported routes do not require Plus. Only new ride recording requires verified Plus access. HUD, ride history, iCloud sync, and saved-ride exports are free.
- HUD is default-off in Settings, with a header launch action only when enabled. Retain live speed, mirror, colors, canvas rotation, and readable dark controls.
- Full-screen clock visibility persists in AppSettings, defaulting to hidden. Fit unboxed HH:mm digits into the fixed space beside the controls. Follow/Collapse controls and metrics must not move when the clock changes visibility.
- Keep visible map attribution and safe-area clearance. Do not send recorded tracks to a map provider.
- Recording starts explicitly in the foreground. Background location runs only while recording. Restore the normal idle timer when the scene becomes inactive.
- Checkpoint incrementally with durable SQLite transactions; never serialize the entire growing route on each GPS update. Recovery must not invent locations or connect a gap after termination.
- Keep route rendering bounded and responsive on older devices. Preserve original source coordinates and segment breaks independently from display simplification.
- Keep StoreKit verification, same-tap purchase loading, restore, offer-code redemption, and legal links intact. Never implement custom access codes or Release entitlement bypasses.
- All user-facing strings belong in the existing 52 localization bundles. Preserve placeholders, VoiceOver, Reduce Motion, Dynamic Type, and right-to-left layouts.
- Remote Camera is optional. Keep authenticated local pairing, explicit start/stop commands, camera-authoritative state, and recording survival across disconnects.

## Working and checking

Open SpeedometerGPS.xcodeproj, scheme SpeedometerGPS. scripts/build-simulator.sh builds without device-specific signing. scripts/i18n-check.sh --release validates localization. Use focused unit/UI tests when requested and appropriate; respect explicit requests not to run tests. Inspect affected UI in the simulator. Do not treat a build as full device, performance, purchase, or release validation.

The public tree intentionally excludes private operational guides, previous validation reports, local provisioning scripts, and generated artifacts. Do not restore them from local archives. Signing and production Apple-service configuration belong outside Git.
