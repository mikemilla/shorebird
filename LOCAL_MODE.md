# Local mode: code push with no server

This fork runs Shorebird entirely from your machine. You don't need an account
or a login, and nothing talks to `api.shorebird.dev`. Releases and patches live
in a folder on disk, and the CLI pushes patches straight to devices you choose.

Local mode is the default. To use a hosted server instead, set
`SHOREBIRD_HOSTED_URL` (for example `https://api.shorebird.dev`).

## Quick start (Android)

```sh
export PATH="/path/to/this/fork/bin:$PATH"

shorebird init                       # creates the app locally, sets base_url
shorebird release android            # builds and stores the release locally
shorebird preview -d emulator-5554   # installs the release on a device

# edit Dart code, then:
shorebird patch android -d emulator-5554     # push to one device
shorebird patch android --all-devices        # push to every connected device

# re-push an existing patch without rebuilding (defaults to the latest):
shorebird patches push --release-version 1.0.0+1 -d R5CT1234ABC
shorebird patches push --release-version 1.0.0+1 --all-devices
```

`-d` takes any serial from `adb devices` (emulator, USB, or wireless debugging)
and can be repeated. `--all-devices` targets every connected device that has
the app installed and skips the rest.

## How a push works

The updater built into the Shorebird engine only pulls patches over HTTP, so
the CLI briefly plays the server itself. For each device it:

1. Opens a listener on `127.0.0.1:47474`. It binds loopback only, so nothing is
   exposed on your network.
2. Runs `adb reverse tcp:47474 tcp:47474` so that device, and only that
   device, can reach the listener.
3. Relaunches the app. The updater checks in, downloads the patch, and reports
   `__patch_download__`.
4. Relaunches again. The app boots the patch and reports `__patch_install__`.
5. Prints `Running patch N` and removes the tunnel. Once every device is done,
   it closes the listener.

Devices you don't target never see the patch: they have no tunnel, so their
update checks fail quietly and they keep running whatever they had.

This works because `shorebird init` (or the first `shorebird release`) writes
`base_url: http://127.0.0.1:47474` into `shorebird.yaml`, and that file is
built into the app.

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
| `commands/patch/patch_command.dart` | New `-d/--device-id` and `--all-devices` |
| `code_push_client_wrapper.dart`, `shorebird_validator.dart`, `shorebird_env.dart` | Local mode switch; skips login in local mode |
| `artifact_manager.dart` | Reads `file://` artifact URLs |
| `init_command.dart`, `release_command.dart` | Write `base_url` in local mode |
| `executables/adb.dart` | `devices`, `isInstalled`, `forceStop`, `reverse`, `removeReverse` |

## Limits

- **Android only for now.** iOS needs a different transport, because a phone
  can't reach the Mac's `127.0.0.1` and there's no `adb reverse` equivalent.
  `shorebird release ios` and `shorebird patch ios` still store everything
  locally, but pushing to iOS devices isn't wired up yet.
- **Engine binaries are fetched from Shorebird's public CDN** the first time a
  Flutter revision is used, then cached. No account is involved, just like
  Flutter downloading its own engine.
- **Pushing reaches devices attached to this machine** over USB, wireless
  debugging, or as emulators. Shipping to users in the wild still needs an
  endpoint they can reach.
