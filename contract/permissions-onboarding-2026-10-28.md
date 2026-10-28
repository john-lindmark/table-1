# Permissions step after sign-in (2026-10-28)

iOS and Android, client-only. Web has no step (no pushes, location only on Nearby).

Before this, iOS showed the notifications prompt the moment sign-in finished, and both apps showed the location
prompt as soon as the Events home opened, with no word on why. Now one screen explains both first, and the system
asks only when the player taps **Turn on**.

## The screen

Under the mark, like sign-in and the name step:

- **Notifications**: know the moment your round is paired, when your opponent reports a result and when you're
  invited to an event; friends' trades and price drops on your wants too.
- **Location**: see events starting near you and join without a code, and pin your own event to the venue. Only while
  the app is open, and only a rough area is kept (the ~1 km geohash cell in `presence_cells`), never the exact spot.
- Each row shows **On** (accent) or **Off** once answered; nothing before.
- "Change either any time in iOS / Android settings."
- **Skip for now** (ghost) and **Turn on** (accent). Turn on shows the system prompt for each permission still unasked
  (iOS: notifications, then location; Android: one `RequestMultiplePermissions` with `POST_NOTIFICATIONS` on 13+ and
  coarse + fine location), then goes into the app whatever the answers.

## When it shows

After sign-in and after the name step (new email accounts), before the tabs, when
`shouldShow(seen, notifications, location)` = `!seen && (notifications == unasked || location == unasked)`.

- `seen` is per device (iOS `UserDefaults` `onboarding.permissions.seen`, Android prefs `onboarding` /
  `permissions.seen`), set by either button.
- iOS reads `unasked` from the system (`.notDetermined`). Android can't tell never-asked from refused, so anything not
  granted counts as unasked until the step has been seen. Below Android 13 notifications count as on.
- A pending join QR, sign-up link or tapped link waits behind the step and opens after it.
- iOS reads the notifications setting with a 2 s limit (`PermissionsStep.notifications()` → nil); no answer counts as
  nothing to ask, so a silent notifications service can never hold sign-in on the loading screen (the iOS 27.1
  simulator never answers). The location status waits for the manager's first callback (`LocationFix.status()`),
  since a new `CLLocationManager` says notDetermined until then.
- Debug: iOS `-T1Permissions`, Android `--ez permissionsDemo true` show it whatever was answered.

## Nothing else asks cold

- iOS `PushController.didSignIn` no longer prompts: it registers only when allowed. `PushController.ask()` is the
  step's prompt. Skipping means no notifications prompt later unless the player turns them on in Settings.
- The Events home refreshes the nearby-alerts area cell only when location is already allowed
  (iOS `LocationFix.currentIfAllowed`, Android `PermissionsStep.locationAllowed`). Nearby, Create event and the
  organizer's venue pin still ask when tapped, since the player asked for a location there.

## Telemetry

`onboarding_permissions` {choice: `turn_on` | `skip`, notifications, location: `unasked` | `on` | `off`}; the screen
is `onboarding_permissions`. `push_permission` {granted} as before.

## Tests

`PermissionsTests` (iOS), `PermissionsTest` (Android): shows while something is unasked, not when both are answered,
never once seen.
