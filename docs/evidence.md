# Evidence

The port is small enough that the honest failure mode is "I remember it working". This page
is the rule that stops that.

## Where things go

| path | contents | in git |
|---|---|---|
| `evidence/device/<timestamp>/` | read-only dumps: props, `/proc/cmdline`, partitions, battery | yes, they are small |
| `evidence/raw/` | unpacked `boot.img`, `dtbo.img`, decompiled DTS, `SHA256SUMS` | no, regenerable from the AP tar |
| `firmware` branch | vendor blobs needed at runtime (`adsp`, `cdsp`, `modem`, `wlan`, `a660` zap shader) | yes, on its own branch |
| `.cache/` | downloaded kernel and rootfs tarballs | no |

## Labels

- **Verified** — seen working on this unit, with a date in the README's what-works table.
- **Expected** — derived from the stock firmware's device tree or from the SoC's upstream
  support, not yet observed. Always say which.
- **Unverified** — came from somewhere else entirely (a forum post, a third-party decompile).
  Should not survive M0.

Every hardware claim in `patches/` or `docs/` should be traceable to a file under
`evidence/raw/` or to a line in a device dump. If it is not, it is a guess and gets labelled
as one.

## Reproducing the raw evidence

```sh
tools/extract-firmware.sh /path/to/AP_*.tar.md5
# evidence/raw/SHA256SUMS records every artefact
```

Two people running that command against the same firmware should get the same hashes; that
is what makes a claim about the panel or a regulator checkable rather than anecdotal.
