Ananta OTT — EPG remote navigation update
Remote controls
Enter/Select while the sidebar is hidden opens the channel list only.
Right while the channel list is open opens the three-day EPG and immediately enables its selection highlight.
Up/Down browses programme entries while EPG is visible; the highlighted programme is scrolled into view.
Enter while the EPG guide is open is ignored so it cannot unexpectedly switch channels.
Left closes the guide / returns to categories; Back hides the sidebar.
Build
Upload the contents of this folder to the repository root. Keep `.github/workflows/build-apk.yml` and remove any duplicate `build-apk-fixed.yml`. Run the workflow in GitHub Actions and install the generated APK.
Audio limitation
This project still uses Flutter `video_player` and Android's native playback stack. Volume is set to 100%, but no app-level volume setting can create a missing audio track or guarantee support for every codec on every Android TV device. Some streams require a supported audio codec or a different native player/decoder implementation. Test the affected stream and inspect Android playback logs before choosing a decoder change.
The source has not been compiled or tested on a physical TV box in this package.

Audio compatibility update
Playback is implemented with media_kit/libmpv rather than Flutter video_player. The bundled native playback libraries provide broader codec support, intended to address MPEG Audio Layer 1/2 (MPGA/MP2) streams. This source has not been compiled or device-tested in this environment; verify the GitHub Actions build and test on the target Android TV device.
