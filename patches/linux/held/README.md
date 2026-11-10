# Held patches

Not applied by `tools/build-kernel.sh --apply` (it only globs `patches/linux/NNNN-*.patch`).

- `0043-media-iris-register-the-encoder-on-SM8350-again.patch`: held back on 2026-11-10 at
  Noa's call. Any encode on SM8350 resets the SoC on the first input frame (see STATE.md), so
  `/dev/video1` stays unregistered (0021's SM8350 skip) until the encoder works.
