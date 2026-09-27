# Generic audio visualization helper

This helper provides local audio visualization for the optional Mac++ Shell feature. It publishes aggregate spectrum, level, and tempo data to local shared memory; raw PCM is not published or saved. It does not ship a hardware-vendor renderer or an external device-control checkout.

The helper is not built or started by the Shell build. macOS requests audio-capture consent when the helper is first started. Use a stable signing identity if you later install a build and want that consent to remain associated with the same app identity.

The public build script stages output in an ignored build directory and does not install, load, or launch a background service:

```sh
MACPP_BUILD_STAGE_ONLY=1 ./apps/AudioCore/build-public-audio.sh
```
