# shorebird_update_ui example

The demo app for local-mode code push. It shows which code is running
(`label` in `lib/main.dart`) and wraps the app in `UpdateGate`.

```sh
export PATH="/path/to/the/fork/bin:$PATH"
shorebird init --force            # creates the app in your local store
shorebird release android         # or: shorebird release ios --export-method development
shorebird preview --platform android -d emulator-5554

# edit the label, then pick a style:
shorebird patch android -d emulator-5554 --apply next-launch --update-ui banner-now
```

**iOS signing:** put your team in `ios/Flutter/Signing.xcconfig` (git-ignored):

```
DEVELOPMENT_TEAM = ABCDE12345
```

Then change the bundle identifier (`dev.mikemiller.shorebirdPushDemo`) to one
your team owns.
