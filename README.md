# SpiderRoute for iOS

SpiderRoute is a GPS companion for bicycle and scooter rides. See your speed, follow your position on the map, bring a route to follow, and record rides to revisit later.

**[Website: spiderroute.com](https://spiderroute.com)** · **[Website / backend repository](https://github.com/IgorShadurin/spiderroute.com)**

## What you can do

- View live GPS speed with digital and gauge displays, configurable colors, and audible speed warnings.
- Explore Apple Maps or OpenStreetMap, follow your current location, and open an edge-to-edge map.
- Show a large optional clock over the map. Its visibility is remembered between launches.
- Download OpenStreetMap regions for offline use and manage downloads on the device.
- Import GPX, KML, GeoJSON, and CSV routes; display distance markers and choose route direction.
- Record rides with SpiderRoute Plus, including background tracking and recovery of saved progress after an interrupted session.
- Revisit saved rides and export them as GPX, KML, GeoJSON, or CSV.
- Enable an optional mirrored HUD in Settings. HUD is free and off by default.
- Use the optional paired-phone Remote Camera feature over a local connection.

Map browsing, full-screen maps, location following, offline downloads, imported routes, live speed, and speed warnings are available without Plus. Only starting a new ride recording requires Plus. HUD, ride history, iCloud sync, and export of existing saved rides are free. Plus supports annual and lifetime purchases through StoreKit; see the app for current availability and pricing.

The app supports iPhone and iPad on **iOS 15 or later**, with 52 localization bundles. It displays routes and location; it does not provide turn-by-turn navigation. The website has its own codebase, linked above; this repository does not imply automatic account or route synchronization with that website.

## Build and run

1. Clone this repository and open `SpeedometerGPS.xcodeproj` in a current Xcode.
2. Let Xcode resolve the pinned MapLibre Swift package.
3. Select the **SpeedometerGPS** scheme and an iPhone or iPad simulator, then Run.
4. To run on your own phone, select your development team under Signing & Capabilities. Use bundle and iCloud container identifiers belonging to your team when necessary. The repository contains no signing keys or provisioning profiles.

The internal target and bundle names retain `SpeedometerGPS` for compatibility with the existing app and saved data; the public app name is SpiderRoute.

A simulator build from the terminal:

```sh
./scripts/build-simulator.sh
```

Pass an available simulator name as the first argument if needed. The script only builds; it does not install, erase data, or run tests. The committed Xcode project is ready to use; `project.yml` is its XcodeGen source.

## Development

App code lives in `SpeedometerGPS/`, with feature folders for maps, speed, rides, settings, onboarding, purchases, and Remote Camera. `SpeedometerGPSTests/` and `SpeedometerGPSUITests/` contain the test code. Run selected tests from Xcode when working on the corresponding behavior.

The build validates localization tables. To run that check directly:

```sh
./scripts/i18n-check.sh --release
```

`Config/Configuration.storekit` supports local purchase development. Production purchases and iCloud require your own correctly configured Apple services.

## Maps, privacy, and repository contents

Recorded rides and imported routes are stored on the device, with optional iCloud route sync. Map requests contact the chosen map provider. Remote Camera uses local pairing. See the [privacy policy](https://spiderroute.com/ios/privacy).

OpenStreetMap and OpenMapTiles attribution remains visible in the app. MapLibre notices are included in `SpeedometerGPS/MapLibreNotices.txt`. The bundled offline-region boundary catalog comes from public-domain Natural Earth data; its source, license link, and checksums are in `SpeedometerGPS/OfflineRegions/SOURCE.json`.

This repository publishes a clean snapshot of the app. It excludes the previous development history, personal route files, device reports, generated marketing assets, test recordings, local deployment scripts, build products, credentials, and signing material. The approximately 40 MB region geometry file is a runtime resource used by the offline map picker, not a test dataset.
