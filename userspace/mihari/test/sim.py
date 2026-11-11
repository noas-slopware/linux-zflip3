#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Drive mihari through a fake sysfs tree and check every tick against a
reference written from the stock code: the HAL's virtual thermistors and
heatmap, SDHMS's Q.o.D() (LRP2), C0224w (SIOP level), Z1.n()/X1 (step-0
limiters) and cpufreq_limit's three-cluster mapping.

usage: sim.py DAEMON MODEL.CONF
"""

import os
import shutil
import subprocess
import sys
import tempfile

DAEMON, MODEL = sys.argv[1], sys.argv[2]
INV = -999

# The phone's tables (2026-11-11, kernel #12)
F0 = [300000, 403200, 499200, 595200, 691200, 806400, 902400, 998400, 1094400, 1209600, 1305600,
      1401600, 1497600, 1612800, 1708800, 1804800]
F4 = [710400, 844800, 960000, 1075200, 1209600, 1324800, 1440000, 1555200, 1670400, 1766400,
      1881600, 1996800, 2112000, 2227200, 2342400, 2419200]
V4 = [576000, 604000, 628000, 652000, 668000, 696000, 720000, 748000, 776000, 800000, 828000,
      864000, 896000, 928000, 964000, 980000]
F7 = [844800, 960000, 1075200, 1190400, 1305600, 1420800, 1555200, 1670400, 1785600, 1900800,
      2035200, 2150400, 2265600, 2380800, 2496000, 2592000, 2688000, 2764800, 2841600]
V7 = [568000, 584000, 588000, 600000, 608000, 620000, 644000, 664000, 688000, 708000, 736000,
      772000, 816000, 856000, 892000, 932000, 964000, 972000, 988000]
GPU = [315, 379, 443, 491, 540, 608, 676, 738, 778, 840]

ADC = [("AP", "ap_thm", "ap_therm", 1), ("WIFI", "wf_thm", "wf_therm", 1),
       ("CF", "cf_thm", "cf_therm", 1), ("BAT", "wpc_thm", "temp", 5),
       ("USB", "usb_thm", "usb_temp", 5), ("CHG", "chg_thm", "chg_temp", 5),
       ("SUBBATRAW", "sub_bat_thm", "sub_bat_temp", 5)]
ZONES = [("PATHM", "lte-pa1-thermal"), ("PA1THM", "lte-pa2-thermal"),
         ("LRPTHM", "mmw-pa1-thermal"), ("MMWTHM", "mmw-pa3-thermal")]
INPUTS = ["AP", "BAT", "SUBBATRAW", "USB", "CHG", "WIFI", "CF", "PATHM", "PA1THM", "LRPTHM",
          "MMWTHM", "FCAM", "UPSPK", "DNSPK"]
FACES = ["AP2_F", "CHG2_F", "MEM2_F", "WIFI2_F", "AP2_R", "CHG2_R", "MEM2_R", "WIFI2_R"]

# ---- model ----
forms, tables, levels, lim, release = {}, {}, [], {}, 350
for line in open(MODEL):
    w = line.split()
    if not w or w[0].startswith("#"):
        continue
    if w[0] == "form":
        forms[w[1]] = (float(w[2]), {k: float(v) for k, v in (x.split("=") for x in w[3:])})
    elif w[0] == "table":
        tables[w[1]] = ([int(x) for x in w[2].split(",")], [int(x) for x in w[3].split(",")])
    elif w[0] == "levels":
        levels = [tuple(map(int, x.split(":"))) for x in w[1:]]
    elif w[0] == "limiter":
        lim[w[1]] = ([int(x) for x in w[2].split(":")], [int(x) for x in w[3].split(":")])
    elif w[0] == "release":
        release = int(w[1])


def to_temp(tab, adc):        # sec_thermistor convert_adc_to_temper
    a, t = tab
    lo, hi = 0, len(a) - 1
    if a[lo] >= adc:
        return t[lo]
    if a[hi] <= adc:
        return t[hi]
    while lo <= hi:
        mid = (lo + hi) // 2
        if a[mid] > adc:
            hi = mid - 1
        elif a[mid] < adc:
            lo = mid + 1
        else:
            return t[mid]
    return t[hi] + int((t[lo] - t[hi]) * (adc - a[hi]) / (a[lo] - a[hi]))


def code_for(tab, deci):      # inverse, to fake a reading
    a, t = tab
    for i in range(len(a) - 1):
        if t[i] >= deci >= t[i + 1]:
            uv = a[i] + (a[i + 1] - a[i]) * (t[i] - deci) / (t[i] - t[i + 1])
            return int(round(uv * 0x70e4 / 1875000))
    raise ValueError(deci)


def uv_of(code):
    return code * 1875000 // 0x70e4


# ---- reference ----
class Ref:
    def __init__(self):
        self.fcam = self.up = self.dn = INV
        self.folded = self.lid_seen = None
        self.lid_at = 0
        self.lv_c = 0
        self.ap = []
        unified = sorted([f for f in F7 if f > F0[-1] // 2], reverse=True) + \
            sorted([f // 2 for f in F0], reverse=True)
        self.l = {
            "CPUFreqMax": dict(level=0, cur=-1, list=unified, period=9000),
            "GPUFreqMax": dict(level=0, cur=-1, list=sorted(GPU, reverse=True), period=19000),
        }
        for v in self.l.values():
            v.update(acc=0, last=None, d=INV, e=INV, f=INV)
        # cpu_voltage_cooling: prime (higher top voltage) against gold
        self.vf = []
        idy = len(F4) - 1
        for i in range(len(F7) - 1, -1, -1):
            while idy >= 0 and V4[idy] > V7[i]:
                idy -= 1
            self.vf.append((F7[i], F4[max(idy, 0)]))

    def a(self, x, y):
        if x == y:
            return 0
        if x == -1:
            return -1
        if y == -1:
            return 1
        return 1 if x < y else -1

    def stepto(self, L, n):
        lst = L["list"]
        i = 0 if L["cur"] == -1 else (lst.index(L["cur"]) if L["cur"] in lst else -1)
        if i == -1:
            return -1
        i = min(max(i + n, 0), len(lst) - 1)
        return -1 if i == 0 else lst[i]

    def z(self, L, target, n):
        if self.a(L["cur"], target) > 0:
            e = self.stepto(L, -n)          # f(): higher
            if self.a(target, e) > 0:
                return target
        else:
            e = self.stepto(L, n)           # e(): lower
            if self.a(target, e) < 0:
                return target
        return e

    def x1b(self, L, target, lrp, ap, bat, lv):
        L["acc"] = 0
        c = lrp if lrp >= -300 else ap
        i7 = 1
        if L["d"] == INV:
            L["d"] = c
            return self.z(L, target, 1)
        i8 = c - L["d"]
        L["e"] = i8
        L["d"] = c
        if L["f"] == INV:
            L["f"] = i8
            return self.z(L, target, 1)
        i9 = 0
        y = 0 if self.a(L["cur"], target) == 0 else -self.a(L["cur"], target)
        if y >= 0:
            i10 = L["e"]
            i6 = 3 if i10 >= 10 else 2 if i10 > 6 else 0 if i10 < -2 else 1
            i11 = L["f"]
            i9 = i6 if (i11 >= 0 or i10 >= i11) else 0
            if lv > 4:
                i7 = max(i9, 3)
            elif lv > 1:
                i7 = max(i9, 2)
            elif lv == 1:
                i7 = max(i9, 1)
            else:
                i7 = i9
        else:
            if (lrp <= -200 or lrp > release) and bat > release:
                i12 = L["e"]
                i5 = L["f"]
                if i12 >= 0 or i5 >= 0:
                    if i5 > 3 and i12 > i5:
                        i7 = i9
                elif i12 < i5 or i5 < -12:
                    i7 = 2
                elif i12 < -18 and i5 < -18:
                    i7 = 3
            else:
                i7 = 99
        L["f"] = L["e"]
        return self.z(L, target, i7)

    def z1n(self, name, skin, now, lrp, ap, bat, lv):
        L = self.l[name]
        temps, vals = lim[name]
        i = L["level"]
        if skin >= temps[i]:
            while i < len(temps) - 1 and skin >= temps[i + 1]:
                i += 1
        else:
            while i > 0 and not skin >= temps[i - 1]:
                i -= 1
        L["level"] = i
        dt = now - L["last"]
        L["last"] = now
        if L["acc"] < L["period"]:
            L["acc"] += dt
        if L["acc"] >= L["period"]:
            L["cur"] = self.x1b(L, vals[i], lrp, ap, bat, lv)

    def cpu_max(self, v):
        if v == -1:
            return [F0[-1], F4[-1], F7[-1]]
        big_min = min(f for f in F7 if f > F0[-1] // 2)
        if v < big_min:
            return [min(1612800, v * 2), 844800 if v == F0[-1] // 2 else F4[0], F7[0]]
        p = min(v, F7[-1])
        gold = p
        for i in range(1, len(self.vf)):
            if self.vf[i][0] == p:
                gold = self.vf[i - 1][1]
        return [F0[-1], min(gold, F4[-1]), p]

    def tick(self, now, st):
        x = {}
        for name, label, tab, n in ADC:
            codes = [st["codes"][label]] * max(n, 3) if n > 1 else [st["codes"][label]]
            uvs = [uv_of(c) for c in codes]
            if n > 1:
                mx, mn, tot = uvs[0], uvs[0], 0
                for i, u in enumerate(uvs):
                    if i:
                        if u > mx:
                            mx = u
                        elif u < mn:
                            mn = u
                    tot += u
                uv = (tot - mx - mn) // (len(uvs) - 2)
            else:
                uv = uvs[0]
            x[name] = to_temp(tables[tab], uv)
        for name, z in ZONES:
            x[name] = int(st["zones"][z] / 100)
        # HAL CameraThermistor / SpeakerThermistor
        d = x["USB"]
        if self.fcam != INV:
            if st["front"]:
                d += 80
            d = self.fcam + (d - self.fcam) * 0.264
        self.fcam = d

        def spk(prev, ref, amp_c, k1):
            v = float(ref)
            if prev != INV:
                amp = amp_c / 0.1
                if v <= amp:
                    v = (amp - v) * k1 + v
                v = prev + (v - prev) * 0.15
            return v
        self.dn = spk(self.dn, x["USB"], st["amp_spk"], 0.3)
        self.up = spk(self.up, x["CF"], st["amp_ear"], 0.05)
        x["FCAM"], x["UPSPK"], x["DNSPK"] = int(self.fcam), int(self.up), int(self.dn)
        # fold, 30 s
        if self.folded is None:
            self.folded = self.lid_seen = st["lid"]
        if st["lid"] != self.lid_seen:
            self.lid_seen, self.lid_at = st["lid"], now
        if self.lid_seen != self.folded and now - self.lid_at >= 30000:
            self.folded = self.lid_seen
        face = {}
        for f in FACES:
            c, k = forms[f]
            face[f] = int(c + sum(k[i] * x[i] for i in k))
        best = INV
        for f in FACES[4 if self.folded else 0:]:
            if face[f] >= -300 and face[f] > best:
                best = face[f]
        skin = best
        self.ap = (self.ap + [x["AP"]])[-15:]
        ap_avg = int(sum(self.ap) / len(self.ap))
        # C0224w
        c = self.lv_c
        if skin >= levels[c][1]:
            while c < len(levels) - 1 and skin >= levels[c + 1][1]:
                c += 1
        else:
            while c > 0 and not skin >= levels[c][1]:
                c -= 1
        self.lv_c = c
        lv = levels[c][0]
        for name in ("CPUFreqMax", "GPUFreqMax"):
            if self.l[name]["last"] is None:
                self.l[name]["last"] = now
            self.z1n(name, skin, now, skin, ap_avg, x["BAT"], lv)
        cpu, gpu = self.l["CPUFreqMax"]["cur"], self.l["GPUFreqMax"]["cur"]
        return dict(lrp2=skin, lv=lv, folded=int(self.folded), cpu=cpu, gpu=gpu,
                    max=self.cpu_max(cpu), x=x)


# ---- fake tree ----
root = tempfile.mkdtemp(prefix="mihari-sim-")


def put(rel, val):
    p = os.path.join(root, rel.lstrip("/"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(f"{val}\n")


def get(rel):
    return open(os.path.join(root, rel.lstrip("/"))).read().strip()


for pol, fr in ((0, F0), (4, F4), (7, F7)):
    put(f"/sys/devices/system/cpu/cpufreq/policy{pol}/scaling_available_frequencies",
        " ".join(map(str, fr)))
    put(f"/sys/devices/system/cpu/cpufreq/policy{pol}/scaling_max_freq", fr[-1])
for cpu, fr, vv in (("cpu4", F4, V4), ("cpu7", F7, V7)):
    for f, v in zip(fr, vv):
        put(f"/sys/kernel/debug/opp/{cpu}/opp:{f * 1000}-0/supply-0/u_volt_target", v)
put("/sys/class/devfreq/3d00000.gpu/available_frequencies", " ".join(str(m * 1000000) for m in GPU))
put("/sys/class/devfreq/3d00000.gpu/max_freq", GPU[-1] * 1000000)
put("/sys/bus/i2c/devices/16-001a/name", "imx374")
for i, (_, z) in enumerate(ZONES):
    put(f"/sys/class/thermal/thermal_zone{i}/type", z)


def scenario():
    """Idle, an all-core load that heats the phone, folding, camera, music, then cooling."""
    t = 0
    for k in range(260):
        if k < 20:
            heat = 0
        elif k < 120:
            heat = (k - 20) / 100
        elif k < 160:
            heat = 1.0
        else:
            heat = max(0.0, 1.0 - (k - 160) / 60)
        base = 300 + 150 * heat               # internal parts, deci-C
        st = dict(
            temps={"AP": base + 60 * heat, "WIFI": base, "CF": base - 10, "BAT": base - 30,
                   "USB": base - 20, "CHG": base, "SUBBATRAW": base - 25},
            zones={z: (base + 20) * 100 for _, z in ZONES},
            front=60 <= k < 90, lid=1 if 130 <= k < 150 else 0,
            amp_ear=int(base / 10 + 15) if 100 <= k < 140 else -1,
            amp_spk=int(base / 10 + 25) if 100 <= k < 140 else -1)
        yield t, st
        t += 10000


ref = Ref()
p = subprocess.Popen([DAEMON, MODEL], env={"MIHARI_ROOT": root}, stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, text=True)
fails = 0
seen = set()
for t, st in scenario():
    st["codes"] = {}
    for name, label, tab, _ in ADC:
        code = code_for(tables[tab], int(st["temps"][name]))
        st["codes"][label] = code
        put(f"/sys/bus/iio/devices/iio:device1/in_temp_{label}_raw", code)
    for i, (_, z) in enumerate(ZONES):
        put(f"/sys/class/thermal/thermal_zone{i}/temp", int(st["zones"][z]))
    put("/sys/bus/i2c/devices/16-001a/power/runtime_status", "active" if st["front"] else "suspended")
    put("/sim/lid", st["lid"])
    put("/sim/amp-Earpiece", st["amp_ear"])
    put("/sim/amp-Speaker", st["amp_spk"])
    p.stdin.write(f"{t}\n")
    p.stdin.flush()
    out = dict(kv.split("=", 1) for kv in p.stdout.readline().split())
    r = ref.tick(t, st)
    got = dict(lrp2=int(out["lrp2"]), lv=int(out["lv"]), folded=int(out["folded"]),
               cpu=int(out["cpu"]), gpu=int(out["gpu"]))
    want = {k: r[k] for k in got}
    sysmax = [int(get(f"/sys/devices/system/cpu/cpufreq/policy{q}/scaling_max_freq")) for q in (0, 4, 7)]
    gpumax = int(get("/sys/class/devfreq/3d00000.gpu/max_freq")) // 1000000
    want_gpu = GPU[-1] if r["gpu"] == -1 else r["gpu"]
    xs = {k: int(out[k]) for k in INPUTS}
    if got != want or sysmax != r["max"] or gpumax != want_gpu or xs != r["x"]:
        fails += 1
        if fails <= 5:
            print(f"t={t // 1000}s MISMATCH daemon={got} {sysmax} {gpumax} ref={want} {r['max']} {want_gpu}")
            print("  inputs daemon", xs)
            print("  inputs ref   ", r["x"])
    state = (r["cpu"], r["gpu"], r["lv"])
    if state not in seen or t % 200000 == 0:
        seen.add(state)
        print(f"t={t // 1000:4d}s lrp2={r['lrp2'] / 10:5.1f} lv={r['lv']:2d} folded={r['folded']} "
              f"CPUFreqMax={r['cpu']:8d} -> {sysmax} GPU={gpumax}")
p.stdin.close()
p.wait()
shutil.rmtree(root)
print("ticks checked, mismatches:", fails)
sys.exit(1 if fails else 0)
