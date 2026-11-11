#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate b2q-siopd's model data from the stock firmware.

Stock estimates the skin temperature (LRP2) in its thermal HAL from
/vendor/etc/mercury.json, a linear heatmap of 14 sensors, and throttles on it
from SamsungDeviceHealthManagerService's SIOP table. This writes everything
b2q-siopd needs into one text file, so none of Samsung's data is in the repo:

  form    the heatmap collapsed to one linear form per heat source and face
          (AP2_F .. WIFI2_R): the mean over the source's rectangle of
          intercept + sum(coef * (x - mean) / scale), checked against a
          literal evaluation of the HAL's loop
  table   stock's thermistor tables (sec_thermistor adc_array/temp_array and
          sec_battery's tables), in stock's "uV" and deci-Celsius
  levels  SIOP levels (siop_default.xml, the b2q table has none)
  limiter the AP component's CPUFreqMax and GPUFreqMax (tempType SKIN)
  release releaseSTS, 350 unless the tables set it

usage: extract-siop-data.py [--vendor DIR] [--dtbo DTS] [--sdhms APK] [--out FILE]
"""

import argparse
import json
import random
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCES = ["AP2", "CHG2", "MEM2", "WIFI2"]


def forms(mercury):
    d = json.load(open(mercury))["heatmap"]
    w, h = d["width"], d["height"]
    out = {}
    for face, suf in (("front", "F"), ("rear", "R")):
        f = d[face]
        inputs = [k for k in f if k not in ("heatsource", "intercept")]
        for s in SOURCES:
            r0, c0, r1, c1 = f["heatsource"][s[:-1]]
            cells = [r * w + c for r in range(r0, r1) for c in range(c0, c1)]
            n = len(cells)
            ic = f["intercept"]
            const = sum(ic["coef"][i] for i in cells) / n + ic["mean"]
            coef = {}
            for k in inputs:
                a = sum(f[k]["coef"][i] for i in cells) / n / f[k]["scale"] * ic["scale"]
                const -= a * f[k]["mean"]
                coef[k] = a
            out[f"{s}_{suf}"] = (const, coef)

    # the HAL's Predictor2D::predict_heat_sources + average_heat_sources
    def literal(face, x):
        f = d[face]
        pix = [0.0] * (w * h)
        for k in f:
            if k in ("heatsource", "intercept"):
                continue
            for i in range(w * h):
                pix[i] += (x[k] - f[k]["mean"]) / f[k]["scale"] * f[k]["coef"][i]
        ic = f["intercept"]
        pix = [p * ic["scale"] + ic["coef"][i] + ic["mean"] for i, p in enumerate(pix)]
        res = {}
        for s, (r0, c0, r1, c1) in f["heatsource"].items():
            v = [pix[r * w + c] for r in range(r0, r1) for c in range(c0, c1)]
            res[s] = sum(v) / len(v)
        return res

    names = [k for k in d["front"] if k not in ("heatsource", "intercept")]
    rnd = random.Random(0)
    worst = 0.0
    for _ in range(50):
        x = {k: rnd.uniform(200, 550) for k in names}
        for face, suf in (("front", "F"), ("rear", "R")):
            lit = literal(face, x)
            for s in SOURCES:
                c, t = out[f"{s}_{suf}"]
                worst = max(worst, abs(c + sum(t[k] * x[k] for k in t) - lit[s[:-1]]))
    if worst > 1e-6:
        sys.exit(f"collapsed forms disagree with the heatmap by {worst}")
    return out


def signed(v):
    return v - (1 << 32) if v >= 1 << 31 else v


def cells(dts, prop):
    m = re.search(re.escape(prop) + r" = <([^>]*)>", dts)
    if not m:
        sys.exit(f"{prop} not found in the stock dtbo")
    return [signed(int(x, 16)) for x in m.group(1).split()]


def tables(dtbo):
    dts = open(dtbo).read()
    out = {}
    # sec_thermistor: sec-ap/-cf/-wf-thermistor
    for name in ("ap_therm", "cf_therm", "wf_therm"):
        m = re.search(r'io-channel-names = "%s";(.*?)\};' % name, dts, re.S)
        if not m:
            sys.exit(f"{name} not found in the stock dtbo")
        out[name] = (cells(m.group(1), "adc_array"), cells(m.group(1), "temp_array"))
    # sec_battery
    for name in ("temp", "usb_temp", "chg_temp", "wpc_temp", "sub_bat_temp"):
        out[name] = (cells(dts, f"battery,{name}_table_adc"),
                     cells(dts, f"battery,{name}_table_data"))
    return out


def siop(apk):
    z = zipfile.ZipFile(apk)
    model = ET.fromstring(z.read("res/raw/siop_b2q_sm8350.xml"))
    default = ET.fromstring(z.read("res/raw/siop_default.xml"))
    ap = next(c for c in model.iter("component")
              if c.get("name") == "AP" and c.get("tempType") == "SKIN" and not c.get("region"))
    limiters = {}
    for lim in ap.iter("limiter"):
        if lim.get("name") in ("CPUFreqMax", "GPUFreqMax"):
            if lim.get("step") != "0":
                sys.exit(f"{lim.get('name')}: step {lim.get('step')}, only step 0 is ported")
            limiters[lim.get("name")] = (lim.get("temp"), lim.get("value"))
    def setting(path):
        e = model.find(path)
        return e if e is not None else default.find(path)

    levels = setting("modelsettings/levels")
    lv = [(lvl.get("id"), lvl.get("temp")) for lvl in levels.iter("level")]
    rel = setting("modelsettings/releaseSTS")
    release = int(rel.get("temp")) if rel is not None and int(rel.get("temp")) > 0 else 350
    skin = model.find("modelsettings/Skin")
    if skin is None or skin.get("type") != "LRP2":
        sys.exit("the b2q table no longer runs its skin on LRP2")
    return limiters, lv, release


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vendor", default=REPO / ".cache/fw/super/vfs")
    ap.add_argument("--dtbo", default=REPO / "evidence/raw/dtbo/entry.3.dts")
    ap.add_argument("--sdhms", required=True, help="SamsungDeviceHealthManagerService.apk")
    ap.add_argument("--out", default=REPO / "out/firmware/usr/share/b2q-siop/model.conf")
    a = ap.parse_args()

    f = forms(Path(a.vendor) / "etc/mercury.json")
    t = tables(a.dtbo)
    limiters, levels, release = siop(a.sdhms)

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as o:
        o.write("# b2q-siopd model data from the stock firmware (tools/extract-siop-data.py)\n")
        for name, (c, coef) in f.items():
            o.write(f"form {name} {c!r}" + "".join(f" {k}={v!r}" for k, v in coef.items()) + "\n")
        for name, (adc, temp) in t.items():
            o.write(f"table {name} " + ",".join(map(str, adc)) + " " + ",".join(map(str, temp)) + "\n")
        o.write("levels " + " ".join(f"{i}:{tmp}" for i, tmp in levels) + "\n")
        for name, (temp, value) in limiters.items():
            o.write(f"limiter {name} {temp} {value}\n")
        o.write(f"release {release}\n")
    print(f"wrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
