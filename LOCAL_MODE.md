# Local mode: code push with no server

This fork runs Shorebird entirely from your machine. You don't need an account
or a login, and nothing talks to `api.shorebird.dev`. Releases and patches live
in a folder on disk, and the CLI pushes patches straight to devices you choose.

Local mode is the default. To use a hosted server instead, set
`SHOREBIRD_HOSTED_URL` (for example `https://api.shorebird.dev`).

## Quick start

```sh
export PATH="/path/to/this/fork/bin:$PATH"

shorebird init                       # creates the app locally, sets base_url
shorebird release android            # builds and stores the release locally
shorebird preview -d emulator-5554   # installs the release on a device

# edit Dart code, then:
shorebird patch android -d emulator-5554     # push to one device
shorebird patch android --all-devices        # push to every connected device

# iOS: same commands; -d takes the UDID (from `xcrun devicectl list devices`)
# or the device name
shorebird release ios --export-method development
shorebird preview --platform ios -d 00008110-000A1B2C3D4E5F6A
shorebird patch ios -d "My iPhone"
shorebird patch ios --all-devices

# re-push an existing patch without rebuilding (defaults to the latest):
shorebird patches push --release-version 1.0.0+1 -d R5CT1234ABC
shorebird patches push --release-version 1.0.0+1 --all-devices
```

On Android, `-d` takes any serial from `adb devices` (emulator, USB, or
wireless debugging). On iOS it takes a paired device's UDID or name. It can be
repeated. `--all-devices` targets every reachable device of the patch's
platform that has the app installed, and skips the rest.

## How a push works

The updater built into the Shorebird engine only pulls patches over HTTP, so
the CLI briefly plays the server itself. For each Android device it:

1. Opens a listener on `127.0.0.1` at a free port. It binds loopback only, so
   nothing is exposed on your network.
2. Runs `adb reverse tcp:47474 tcp:<that port>` so that device, and only that
   device, can reach it. Each device gets its own port, so the CLI knows
   exactly which device checked in.
3. Relaunches the app. The updater checks in, downloads the patch, and reports
   `__patch_download__`.
4. Relaunches again. The app boots the patch and reports `__patch_install__`.
5. Prints `Running patch N` and removes the tunnel. Once every device is done,
   it closes the listener.

### When a patch takes effect: `--apply`

| `--apply` | What the CLI does |
| --- | --- |
| `now` (default) | Steps 3 and 4 above: the device is running the patch when the push ends. |
| `next-launch` | Doesn't touch the app. It waits (up to 10 minutes) for someone to open it, the patch downloads in the background, and it takes effect on the launch after that. |

Use `next-launch` when you want the app's own update UI to handle it.

### How the app presents it: `--update-ui`

Each patch carries a style that apps using
[`package:shorebird_update_ui`](packages/shorebird_update_ui) act on:
`silent` (default), `banner-now`, `banner-next-launch`, or `wall`. Set it when
patching (`shorebird patch ios --update-ui wall`) or change it when re-pushing
(`shorebird patches push --update-ui banner-now ...`). Apps read it from
`GET /api/v1/patches/policy`, which the push listener serves next to the
updater's endpoints.

Devices you don't target never see the patch: they have no tunnel, so their
update checks fail quietly and they keep running whatever they had.

This works because `shorebird init` (or the first `shorebird release`) writes
`base_url: http://127.0.0.1:47474` into `shorebird.yaml`, and that file is
built into the app.

### iOS

A phone can't reach the Mac's `127.0.0.1`, and iOS has no `adb reverse`, so
iPhones connect over Wi-Fi instead:

- For iOS builds only, `shorebird release ios` and `shorebird patch ios` swap
  `base_url` to the Mac's Bonjour name (`http://<LocalHostName>.local:47474`).
  The swap lasts only for the build, and `shorebird.yaml` is restored after.
  Set `SHOREBIRD_LOCAL_IOS_HOST` to use a different host.
- During a push, the listener binds only to the addresses of the Mac's active
  network interface. It runs for the few seconds of the push and only serves
  the patch being pushed.
- The app is relaunched with `xcrun devicectl device process launch
  --terminate-existing`, so the phone must be paired, unlocked and on the
  same Wi-Fi as the Mac.
- The first time the app connects, iOS asks for **Local Network** access.
  Allow it. Add an `NSLocalNetworkUsageDescription` to `Info.plist` so the
  prompt explains why.

## Where things live

| What | Where | Override |
| --- | --- | --- |
| Apps, releases, patches (`db.json`) and artifacts (`files/`) | `~/.shorebird_local` | `SHOREBIRD_LOCAL_DIR` |
| Push port (baked into the app at release time) | `47474` | `SHOREBIRD_LOCAL_PORT` |

Back up `~/.shorebird_local` like source code: you need the release artifacts
to build patches for that release.

## What changed from upstream

| File | Change |
| --- | --- |
| `packages/shorebird_cli/lib/src/local/local_store.dart` | JSON-file store for apps, channels, releases, patches and artifacts |
| `packages/shorebird_cli/lib/src/local/local_code_push_client.dart` | Implements the code push API in-process, so the stock `CodePushClient` and every command work unchanged |
| `packages/shorebird_cli/lib/src/local/patch_push.dart` | Short-lived updater endpoint plus adb push orchestration |
| `commands/patches/push_command.dart` | New `shorebird patches push` |
| `commands/patch/patch_command.dart` | New `-d/--device-id`, `--all-devices`, `--apply`, `--update-ui` |
| `code_push_client_wrapper.dart`, `shorebird_validator.dart`, `shorebird_env.dart` | Local mode switch; skips login in local mode |
| `artifact_manager.dart` | Reads `file://` artifact URLs |
| `init_command.dart`, `release_command.dart` | Write `base_url` in local mode |
| `executables/adb.dart` | `devices`, `isInstalled`, `forceStop`, `reverse`, `removeReverse` |
| `executables/devicectl/devicectl.dart` | `relaunchApp`, `isAppInstalled` |
| `local/local_base_url.dart` | Points iOS builds' `base_url` at the Mac's `.local` name |
| `packages/shorebird_update_ui` (new) | Flutter widgets for the four update styles, with a native Android restart |

## Limits

- **iOS releases carry the Mac's hostname.** If you rename the Mac, releases
  built before the rename can't reach it anymore. Cut a new release.
- **Engine binaries are fetched from Shorebird's public CDN** the first time a
  Flutter revision is used, then cached. No account is involved, just like
  Flutter downloading its own engine.
- **Pushing reaches devices attached to this machine** over USB, wireless
  debugging, or as emulators. Shipping to users in the wild still needs an
  endpoint they can reach.
