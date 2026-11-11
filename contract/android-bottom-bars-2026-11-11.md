# Android: bottom menus, panels and sheets sit on the navigation bar (2026-11-11)

Android only, client-only. John: "android still has issues with the bottom buttons (like in deck photos camera/photo
roll actions) not showing up in the correct place. This is true for folks with both bottom android bars enabled and
disabled, review across all places where that type of interaction shows up in the app and fix in a consistent way."

## What was wrong

Every menu, panel and selector sheet that rises from the bottom over a scrim goes through `T1Overlay` (Kit.kt):
`T1Menu` (deck photo source, person menus, More menus, every option list), `T1Panel` (notes, History, pickers),
card detail's `Sheet` (attribute pickers, Insights filters), the tracker's Options and Roll dice, and the command zone
picker. `T1Overlay` was a Compose `Popup`. Compose 1.7 measures a popup's content against
`Configuration.screenHeightDp`, and an app targeting Android 15+ gets a Configuration that counts the status and
navigation bars, while the popup window itself is laid out between the bars. The content came out taller than its
window by the bars' height, so a bottom-aligned menu lost its last rows: on an Android 15 emulator the deck photo menu
showed "Take a photo" only, with "Choose from photos" and Cancel behind the bar, and the note panel lost its Save
button, with three-button navigation and with gesture navigation alike. It is the bug full-screen dialogs had on
2026-11-06 (`T1FullScreenDialog`), in the other window type.

## The rule

- `T1Overlay` draws in the same window as `T1FullScreenDialog` (`T1Window`): a dialog window that covers the whole
  display, edge to edge, when Compose measures for the whole screen (`FullScreenWindow.coversBars`, Android 15+), and
  the platform's floating window otherwise (Android 14 and older, where it already matches). Overlays clear the
  platform dim and animation (`FullScreenWindow.plain`): the 60 % scrim is ours, and it now covers the bars too.
- The bottom edge of anything over the scrim pads with `Modifier.sheetInsets()`: the navigation bar (three buttons or
  the gesture strip), the keyboard when it is up, and a side navigation bar or cutout in landscape. A panel's bottom
  button now rides above the keyboard instead of behind it.
- A full-height overlay (the command zone picker) pads with `safeDrawingPadding()`.
- No screen draws a Compose `Popup` of its own, and no overlay pads with `navigationBarsPadding()` /
  `statusBarsPadding()` alone (`OverlayWindowTest`). Full-screen dialogs still go through `T1FullScreenDialog`
  (`FullScreenDialogTest`).

## Checking it

Debug builds: `--es t1Overlays menu|panel|sheet|dice|dialog` opens a gallery of every kind of bottom surface without
signing in (`OverlayGallery`), e.g.

    adb shell am start -S -n site.table1.events/.MainActivity --es t1Overlays menu

Switch navigation modes with `adb shell cmd overlay enable com.android.internal.systemui.navbar.threebutton` or
`…navbar.gestural`. Checked on an Android 15 emulator (Pixel 8 size, 1080 × 2400) in both modes, before and after:
the menu, panel, sheet, Roll dice and a full-screen dialog's bottom buttons, and the panel with the keyboard up.
Android 14 and older not run (no emulator image here); overlays there get the floating dialog window that
full-screen dialogs already use on those versions.
