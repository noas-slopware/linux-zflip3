# Hardware video decode (Galaxy Z Flip3, SM-F711N)

Device: `<phone>`, user `<user>`, Arch Linux aarch64, Plasma Mobile,
kernel 7.3.1 with a hand-built out-of-tree `qcom_iris` module.

**Status, 2026-11-10: not fully working.** VP9 and H.264 without B-frames decode in
hardware and were checked in Firefox 159 on YouTube. H.264 with B-frames is broken until
the kernel carries the two qcom-va-driver patches (below). HEVC decodes but logs
pending-picture warnings; treat HEVC as untested.

## Hardware

- Qualcomm Iris decoder at `/dev/video0` (`iris_driver`), stateful M2M, exposes
  H.264/HEVC/VP9 output formats.
- DRM render node `/dev/dri/renderD128`.
- No `/dev/media*`, no stateless codec controls. This is a stateful driver, so the
  Bootlin `libva-v4l2-request` backend is the wrong tool.

## Backend in use

[`github.com/nyanmisaka/libva-v4l2-qcom`](https://github.com/nyanmisaka/libva-v4l2-qcom),
package name `qcom-va-driver 1.1.1`, built from source at `~/src/qcom-va-driver`:

```sh
meson setup build --buildtype=release --prefix=/usr -Dlibdir=lib \
  -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled
meson compile -C build && sudo meson install -C build
```

Installs `/usr/lib/dri/qcom_drv_video.so` with `msm_drv_video.so` and
`v4l2_drv_video.so` aliases, so libva selects it automatically. Not owned by pacman.

`tools/build-qcom-va-driver.sh` reproduces this build, applies the local patch below and
installs the result.

### Local patch

`patches/qcom-va-driver/local-0001-make-decode-order-controls-optional.patch` makes
`V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY(_ENABLE)` failures non-fatal. Required because the
kernel module lacks the upstream decode-order patch.

### Do not use the AUR stateless packages

- `libva-v4l2-request` (1.3-1) ships a tarball that is actually `asahi-va-driver`, and its
  `prepare()` cds into a directory name that doesn't exist.
- `libva-v4l2-request-git` fails to compile against modern kernel headers (HEVC structs
  moved into `linux/v4l2-controls.h`, control IDs renamed `V4L2_CID_STATELESS_HEVC_*`,
  `dpb[].rps` and `num_rps_poc_*` removed).

## Capabilities

`vainfo --display drm --device /dev/dri/renderD128`:

```
H264 ConstrainedBaseline/Main/High, HEVCMain/Main10, VP9Profile0/2, all VLD
```

The exact output lists those profiles as VLD entries; no AV1 profile is advertised.

## Measurements

1080p, 10 s, `ffmpeg -f null -`:

| codec | software | hardware |
|---|---|---|
| VP9 | 1.646 s wall / 4.909 s user | 0.902 s wall / 0.434 s user |
| H264 | 0.936 s wall / 3.887 s user | 0.600 s wall / 0.308 s user |

H.264 (no B-frames) output is bit-exact vs software: PSNR inf.

## Known broken

- **H.264 with B-frames** (`-bf 2`) fails with `surface sync timeout` /
  `Failed to begin picture decode`. Do not describe the decoder as fully working.
- **HEVC** decodes but logs pending-picture warnings; treat as untested.

### Root cause and next step

The kernel needs the qcom-va-driver patches `patches/0001` (decode-order output) and
`patches/0002` (larger capture pools). Those two are written for HFI **gen2**; this phone is
Gen1 (SM8350, `vpu20_4v.mbn`). The Gen1 ports are `patches/linux/0041-*` (display-delay
controls, mapped to `HFI_PROPERTY_PARAM_VDEC_OUTPUT_ORDER` = `HFI_OUTPUT_ORDER_DECODE`, the
property venus uses on these firmwares) and `0042-*` (CAPTURE limit 64 on the Gen1 decoder).
Both apply on top of the current 0021 and compile with W=1; neither has been built into a
kernel or run on the phone yet. Retest H.264 with `-bf 2` and HEVC once they are installed.
`local-0001` turns a rejected display-delay control into a trace line and carries on, so a
failed 0041 would look exactly like "B-frames still broken". For the retest, first check
the kernel side: `v4l2-ctl -d /dev/video0 --list-ctrls` must list
`display_delay_enable` and `display_delay`, and the libva trace must not print
`DISPLAY_DELAY unsupported` or `DISPLAY_DELAY_ENABLE unsupported`. Only then does a B-frame
result say anything about decode order. Drop `local-0001` once 0041 is confirmed.

0041-0043 are all in the `qcom-iris` module, so the test is a module swap with no new image:
`scratch/iris-port/ko/decode/qcom-iris.ko` (0021 + 0041 + 0042, encoder still skipped on
SM8350) and `scratch/iris-port/ko/decode-encoder/qcom-iris.ko` (also 0043). Both are built
in M= mode against kernel #81's `Module.symvers` (no `CONFIG_MODVERSIONS`, vermagic
`7.3.1 SMP preempt mod_unload aarch64`) and signed with the tree's key from 2026-11-06, which
#81 embeds. `modinfo -n qcom_iris` on the phone names the file to replace (keep the old
one next to it). Test `decode` first. A firmware crash from the encoder takes the shared VPU down,
decode included, so the `decode-encoder` module only goes in after decode is confirmed.

## Firefox

Profile `atc5ksyj.default-release`, `user.js`:

```js
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.hardware-video-decoding.enabled", true);
```

The same file also sets a Firefox-for-Android UA:

```
Mozilla/5.0 (Android 15; Mobile; rv:159.0) Gecko/159.0 Firefox/159.0
```

so sites serve mobile layouts on the 1080x2640 panel at scale 3.

### Verified in Firefox 159, 2026-11-10

YouTube playback uses hardware decode. While playing 1080p:

- only the RDD process maps `qcom_drv_video.so` and holds `/dev/video0` open;
- RDD CPU is 1.8% of one core over an 8 s sample, versus ~49% of a core measured for
  software VP9 1080p;
- the codec served is VP9 (no AV1 profile is advertised);
- remaining CPU load during playback is page JS and compositing (Firefox main ~58%,
  YouTube content process ~48%), not decoding.

Still untested: H.264 streams with B-frames are expected to fail per the kernel patch gap;
the VP9 path YouTube uses is unaffected. If a site ever stalls mid-video, that is the
B-frame case: the fix is still the kernel patches, not a pref. The mobile-UI half is for a
human to eyeball: it should look like `m.youtube.com` now, since the UA override is live in
the same profile.

## Revert

Delete the two prefs from `user.js`, then:

```sh
sudo rm /usr/lib/dri/qcom_drv_video.so /usr/lib/dri/msm_drv_video.so \
        /usr/lib/dri/v4l2_drv_video.so
```
