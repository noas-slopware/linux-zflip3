#!/usr/bin/env python3
"""Dump a Qualcomm CamX/CHI "Parameter Parser V2.0.0" binary (e.g. Samsung
com.samsung.sensormodule.*.bin) as a nested JSON tree.

    python3 -I tools/chromatix-dump.py <file.bin> [--hex] > out.json

File layout (all little-endian):

  0x00  "QTI Chromatix Header" magic, 0x1c u32 file size
  0x28  "Parameter Parser V2.0.0 (...)" version string
  0x98  u32 offset of the section table (0xa0), u32 section count (3)
  0xa0  sections, 3 x u64 {id, offset, size}:
          0 = symbol table, 1 = data, 2 = 0x20-byte trailer
  symbol table: 0x48-byte records
          u64 id, char name[32], u64 flags, u64 parent, u64 offset, u64 size
        offset is relative to the data section. Records whose parent is 0
        are the top-level structures (sensorDriverData, cameraModuleData,
        EEPROMDriverData, ...); every other record is the out-of-line storage
        of one array or optional element, named after that element.
  data: each structure is a sequence of 8-byte slots. A scalar takes one
        slot (an integer, an IEEE double, or an IEEE float in the low 32
        bits). An array or optional element takes two slots {count, id};
        `id` names the symbol record holding the elements. Ids are handed
        out depth-first in field order, starting right after the top-level
        records, so a parse that consumes them in order is self-checking.
        Arrays of scalars are packed at their natural width (1/2/4/8 bytes)
        and padded to 8; char arrays count the terminating NUL.

Only element names that have out-of-line storage are present in the file.
Names of plain scalar fields come from the tables below, which follow the
CamX sensor driver XML naming; slots without a confident name are emitted as
"_slotN". Unknown structures are decoded generically.

Limits of the generic path (it never applies inside sensorDriverData or
cameraModuleData, which are fully tabled):
  - a packed scalar array where several element widths fit the padded size is
    read at the widest one;
  - a slot holding an f32 is printed as an integer (e.g. 1073741824 = 2.0f in
    PDConfigData); only doubles are recognised by bit pattern.
"""
import json
import struct
import sys

STRING_RECORDS = {
    'sensorName', 'moduleType', 'sensorVersion', 'modeName', 'moduleName',
    'eepromName', 'flashName', 'actuatorName', 'oisName', 'pdafName',
    'EEPROMName', 'name', 'Name', '[0]', 'realToRegGain', 'regToRealGain',
}

# Kernel enum msm_camera_power_seq_type (techpack/camera cam_sensor_cmn_header.h)
POWER_TYPES = ['MCLK', 'VANA', 'VDIG', 'VIO', 'VAF', 'VAF_PWDM', 'CUSTOM_REG1',
               'CUSTOM_REG2', 'RESET', 'STANDBY', 'CUSTOM_GPIO1', 'CUSTOM_GPIO2',
               'CUSTOM_GPIO3', 'CUSTOM_GPIO4', 'VANA1']


def P(record, elem):
    """Array/optional field: two slots {count, id}; `record` is the expected
    symbol name, `elem` the element type (struct table name or scalar kind:
    'u', 'f32', 'f64', 'str', 'strlist', 'auto')."""
    return ('ptr', record, elem)


def S(n, prefix='_slot', start=0, kind='u'):
    return [(f'{prefix}{start + i}', kind) for i in range(n)]


STRUCTS = {
    'sensorDriverData': [
        ('moduleVersion.majorRevision', 'u'),
        ('moduleVersion.minorRevision', 'u'),
        ('moduleVersion.incrRevision', 'u'),
        ('slaveInfo.sensorName', P('sensorName', 'str')),
        ('slaveInfo.moduleType', P('moduleType', 'auto')),
        ('slaveInfo.slaveAddress', 'u'),
        ('slaveInfo.regAddrType', 'u'),
        ('slaveInfo.regDataType', 'u'),
        ('slaveInfo.sensorIdRegAddr', 'u'),
        ('slaveInfo.sensorId', 'u'),
        ('slaveInfo.sensorIdMask', 'u'),
        ('slaveInfo.i2cFrequencyMode', 'u'),
        ('slaveInfo.powerUpSequence', P('powerSetting', 'powerSetting')),
        ('slaveInfo.powerDownSequence', P('powerSetting', 'powerSetting')),
        ('regAddrInfo.xOutput', 'u'),
        ('regAddrInfo.yOutput', 'u'),
        ('regAddrInfo.frameLengthLines', 'u'),
        ('regAddrInfo.lineLengthPixelClock', 'u'),
        ('regAddrInfo.coarseIntgTimeAddr', 'u'),
        ('regAddrInfo.middleCoarseIntgTimeAddr', P('middleCoarseIntgTimeAddr', 'u')),
        ('regAddrInfo.shortCoarseIntgTimeAddr', P('shortCoarseIntgTimeAddr', 'u')),
        ('regAddrInfo.globalGainAddr', 'u'),
        ('regAddrInfo.middleGlobalGainAddr', P('middleGlobalGainAddr', 'u')),
        ('regAddrInfo.shortGlobalGainAddr', P('shortGlobalGainAddr', 'u')),
        ('regAddrInfo.digitalGlobalGainAddr', P('digitalGlobalGainAddr', 'u')),
        ('regAddrInfo.middleDigitalGlobalGainAddr', P('middleDigitalGlobalGainAddr', 'u')),
        ('regAddrInfo.shortDigitalGlobalGainAddr', P('shortDigitalGlobalGainAddr', 'u')),
        ('regAddrInfo.digitalGainRedAddr', P('digitalGainRedAddr', 'u')),
        ('regAddrInfo.digitalGainGreenRedAddr', P('digitalGainGreenRedAddr', 'u')),
        ('regAddrInfo.digitalGainBlueAddr', P('digitalGainBlueAddr', 'u')),
        ('regAddrInfo.digitalGainGreenBlueAddr', P('digitalGainGreenBlueAddr', 'u')),
        ('regAddrInfo.testPatternRAddr', 'u'),
        ('regAddrInfo.testPatternGrAddr', 'u'),
        ('regAddrInfo.testPatternBAddr', 'u'),
        ('regAddrInfo.testPatternGbAddr', 'u'),
        ('resolutionInfo', P('resolutionInfo', 'resolutionInfo')),
        ('exposureControlInfo.maxAnalogGain', 'f64'),
        ('exposureControlInfo.maxDigitalGain', 'f64'),
        ('exposureControlInfo.minAnalogGain', P('minAnalogGain', 'f64')),
        ('exposureControlInfo.verticalOffset', 'u'),
        ('exposureControlInfo.multiCamLineDelta', P('multiCamLineDelta', 'u')),
        ('exposureControlInfo.maxLineCount', 'u'),
        ('exposureControlInfo.minLineCount', P('minLineCount', 'u')),
        ('exposureControlInfo.middleMaxLineCount', P('middleMaxLineCount', 'u')),
        ('exposureControlInfo.middleMinLineCount', P('middleMinLineCount', 'u')),
        ('exposureControlInfo.shortMaxLineCount', P('shortMaxLineCount', 'u')),
        ('exposureControlInfo.shortMinLineCount', P('shortMinLineCount', 'u')),
        ('exposureControlInfo.isFastStandbyEnabled', P('isFastStandbyEnabled', 'u')),
        ('exposureControlInfo.isFLLAutomaticTrackingEnabled', P('isFLLAutomaticTrackingEnabled', 'u')),
        ('exposureControlInfo._slot74', 'f64'),
        ('exposureControlInfo.realToRegGain', P('realToRegGain', 'str')),
        ('exposureControlInfo.regToRealGain', P('regToRealGain', 'str')),
        ('streamOnSettings', P('regSetting', 'regSetting')),
        ('streamOffSettings', P('regSetting', 'regSetting')),
        ('groupHoldOnSettings', P('regSetting', 'regSetting')),
        ('groupHoldOffSettings', P('regSetting', 'regSetting')),
        ('masterSettings', P('masterSettings', 'regList')),
        ('slaveSettings', P('slaveSettings', 'regList')),
        ('softwareSyncConfiguration', P('softwareSyncConfiguration', 'auto')),
        ('temperatureReadInfo', P('temperatureReadInfo', 'auto')),
        ('initSettings', P('initSettings', 'initSetting')),
        ('calSettings', P('calSettings', 'auto')),
        ('extraSettings', P('extraSettings', 'auto')),
        ('testPatternData', P('testPatternData', 'testPattern')),
        ('colorLevelInfo.whiteLevel', 'u'),
        ('colorLevelInfo.rPedestal', 'u'),
        ('colorLevelInfo.grPedestal', 'u'),
        ('colorLevelInfo.bPedestal', 'u'),
        ('colorLevelInfo.gbPedestal', 'u'),
        ('pixelArrayInfo.activeDimension', P('dimension', 'dimension')),
        *S(6, 'pixelArrayInfo._slot', 110),
        ('delayInfo', P('delayInfo', 'delayInfo')),
        ('_slot118', 'f64'),
        ('_slot119', 'f64'),
        ('_slot120', 'u'),
        ('noiseCoefficent', P('noiseCoefficent', 'noise')),
        ('noiseCoefficientBayer', P('noiseCoefficientBayer', 'auto')),
        ('optimalSizeInfo', P('optimalSizeInfo', 'auto')),
        ('supportRetention', P('supportRetention', 'auto')),
        ('remosaicOnSettings', P('remosaicOnSettings', 'auto')),
        ('remosaicOffSettings', P('remosaicOffSettings', 'auto')),
    ],
    'powerSetting': [('configType', 'u'), ('configValue', 'u'), ('delayMs', 'u')],
    'regSetting': [
        ('slaveAddr', P('slaveAddr', 'u')),
        ('registerAddr', 'u'),
        ('registerData', P('registerData', 'u')),
        ('regAddrType', 'u'),
        ('regDataType', 'u'),
        ('operation', 'u'),
        ('delayUs', P('delayUs', 'u')),
    ],
    'resolutionInfo': [
        ('sensorVersion', P('sensorVersion', 'str')),
        ('resolutionData', P('resolutionData', 'resolutionData')),
    ],
    'resolutionData': [
        ('colorFilterArrangement', 'u'),
        ('streamInfo.streamConfiguration', P('streamConfiguration', 'streamConfiguration')),
        ('lineLengthPixelClock', 'u'),
        ('frameLengthLines', 'u'),
        ('minHorizontalBlanking', 'u'),
        ('minVerticalBlanking', 'u'),
        ('outputPixelClock', 'u'),
        ('horizontalBinning', 'u'),
        ('verticalBinning', 'u'),
        ('frameRate', 'f64'),
        ('laneCount', 'u'),
        ('downScaleFactor', P('downScaleFactor', 'f32')),
        ('settleTimeNs', 'u'),
        ('is3Phase', 'u'),
        ('integrationInfo', P('integrationInfo', 'auto')),
        ('resSettings', P('regSetting', 'regSetting')),
        *S(4, '_slot', 20),
        ('exposureInfo', P('exposureInfo', 'auto')),
        ('frameOffsetInfo', P('frameOffsetInfo', 'auto')),
        ('HDRExposureType', P('HDRExposureType', 'auto')),
        ('ZZHDRInfo', P('ZZHDRInfo', 'auto')),
        ('HDR3ExposureInfo', P('HDR3ExposureInfo', 'auto')),
        ('RemosaicTypeInfo', P('RemosaicTypeInfo', 'auto')),
        ('capability', P('capability', 'u')),
        ('ADCReadoutTime', P('ADCReadoutTime', 'f64')),
        ('_slot40', 'u'),
        ('mipiFlags', P('mipiFlags', 'u')),
        ('maxAnalogGain', P('maxAnalogGain', 'f64')),
        ('modeName', P('modeName', 'strlist')),
    ],
    'streamConfiguration': [
        ('vc', 'u'), ('dt', 'u'),
        ('frameDimension.xStart', 'u'), ('frameDimension.yStart', 'u'),
        ('frameDimension.width', 'u'), ('frameDimension.height', 'u'),
        ('bitWidth', 'u'), ('type', 'u'),
    ],
    'initSetting': [('_slot0', 'u'), ('regSetting', P('regSetting', 'regSetting'))],
    'testPattern': [('mode', 'u'), ('settings', P('regSetting', 'regSetting'))],
    'regList': [('regSetting', P('regSetting', 'regSetting'))],
    'noise': [(f'coefficient{i}', 'f64') for i in range(4)],
    'dimension': [('xStart', 'u'), ('yStart', 'u'), ('width', 'u'), ('height', 'u')],
    'delayInfo': [
        ('delayType', P('delayType', 'auto')),
        ('linecount', P('linecount', 'u')),
        ('gain', P('gain', 'u')),
        ('frameLengthLines', P('frameLengthLines', 'u')),
        *S(3, '_slot', 8),
    ],
    'cameraModuleData': [
        ('moduleVersion.majorRevision', 'u'),
        ('moduleVersion.minorRevision', 'u'),
        ('moduleVersion.incrRevision', 'u'),
        ('moduleConfiguration', P('moduleConfiguration', 'moduleConfiguration')),
    ],
    'moduleConfiguration': [
        ('cameraId', 'u'),
        ('moduleName', P('moduleName', 'strlist')),
        ('sensorName', P('sensorName', 'str')),
        ('sensorSlaveAddress', P('sensorSlaveAddress', 'u')),
        ('sensorI2CFrequencyMode', P('sensorI2CFrequencyMode', 'u')),
        ('actuatorName', P('actuatorName', 'strlist')),
        ('oisName', P('oisName', 'strlist')),
        ('eepromName', P('eepromName', 'strlist')),
        ('eepromSlaveAddress', P('eepromSlaveAddress', 'u')),
        ('flashName', P('flashName', 'strlist')),
        ('chromatixName', P('Name', 'strlist')),
        ('i2cFrequencyMode', P('i2cFrequencyMode', 'u')),
        ('_slot23', 'u'),
        ('_slot24', 'u'),
        ('CSIInfo.laneAssign', P('laneAssign', 'u')),
        ('CSIInfo.isComboMode', P('isComboMode', 'u')),
        ('CSIInfo.cphyDphyComboMode', P('cphyDphyComboMode', 'u')),
        ('lensInformation.focalLength', 'f64'),
        ('lensInformation.fNumber', 'f64'),
        ('lensInformation._slot33', 'f64'),
        ('lensInformation._slot34', 'f64'),
        ('lensInformation.horizontalViewAngle', 'f64'),
        ('lensInformation.verticalViewAngle', 'f64'),
        ('lensInformation.maxRollDegree', P('maxRollDegree', 'f64')),
        ('lensInformation.maxPitchDegree', P('maxPitchDegree', 'f64')),
        ('lensInformation.maxYawDegree', P('maxYawDegree', 'f64')),
        ('pdafName', P('pdafName', 'strlist')),
        ('depthConversionLibInfo', P('depthConversionLibInfo', 'auto')),
    ],
}
# Element types picked by record name when a generic walk meets them.
BY_RECORD = {'regSetting': 'regSetting', 'powerSetting': 'powerSetting',
             'streamConfiguration': 'streamConfiguration'}


class Decoder:
    def __init__(self, data):
        self.d = data
        if not data.startswith(b'QTI Chromatix Header'):
            raise ValueError('not a QTI Chromatix file')
        tab, nsec = struct.unpack_from('<II', data, 0x98)
        self.sections = [struct.unpack_from('<QQQ', data, tab + 24 * i) for i in range(nsec)]
        sym = next(s for s in self.sections if s[0] == 0)
        dat = next(s for s in self.sections if s[0] == 1)
        self.base, self.dsize = dat[1], dat[2]
        self.recs = {}
        for off in range(sym[1], sym[1] + sym[2], 0x48):
            rid, = struct.unpack_from('<Q', data, off)
            name = data[off + 8:off + 40].split(b'\0')[0].decode('ascii', 'replace')
            flags, parent, roff, rsz = struct.unpack_from('<QQQQ', data, off + 40)
            self.recs[rid] = (name, flags, parent, roff, rsz)
        self.tops = [r for r in sorted(self.recs) if self.recs[r][2] == 0]
        self.next_id = max(self.tops) + 1
        self.used = set(self.tops)

    # -- primitives -----------------------------------------------------
    def slot(self, off):
        if off + 8 > self.dsize:
            raise ValueError(f'slot at data+0x{off:x} outside data section')
        return struct.unpack_from('<Q', self.d, self.base + off)[0]

    def scalar(self, off, kind):
        v = self.slot(off)
        if kind == 'f64':
            return struct.unpack('<d', struct.pack('<Q', v))[0]
        if kind == 'f32':
            return struct.unpack('<f', struct.pack('<I', v & 0xffffffff))[0]
        if kind == 'auto':
            return self.guess(v)
        return v - (1 << 64) if v >> 63 else v

    @staticmethod
    def guess(v):
        hi = v >> 32
        if hi and ((hi >> 20) & 0x7ff) >= 0x3c0 and ((hi >> 20) & 0x7ff) < 0x440:
            return struct.unpack('<d', struct.pack('<Q', v))[0]
        return v - (1 << 64) if v >> 63 else v

    def take_ref(self, off, want=None):
        count, rid = self.slot(off), self.slot(off + 8)
        if rid != self.next_id:
            raise ValueError(f'data+0x{off:x}: expected id {self.next_id} for '
                             f'{want!r}, found {rid} (count {count})')
        name, _f, _p, roff, rsz = self.recs[rid]
        if want is not None and name != want:
            raise ValueError(f'id {rid}: expected record {want!r}, found {name!r}')
        self.next_id += 1
        self.used.add(rid)
        return count, name, roff, rsz

    def looks_like_ref(self, off, end):
        return off + 16 <= end and self.slot(off + 8) == self.next_id \
            and self.next_id in self.recs

    # -- arrays ---------------------------------------------------------
    def array(self, count, name, roff, rsz, elem):
        if count == 0:
            if rsz:
                raise ValueError(f'{name}: count 0 but size {rsz}')
            return '' if elem == 'str' else []
        raw = self.d[self.base + roff:self.base + roff + rsz]
        if elem == 'str' or (elem == 'auto' and self.is_string(name, count, rsz, raw)):
            return raw[:count].split(b'\0')[0].decode('ascii', 'replace')
        packed = rsz % count or rsz // count <= 8
        if elem in ('u', 'f32', 'f64') or (elem == 'auto' and packed
                                           and name not in BY_RECORD):
            width = self.scalar_width(count, rsz, elem)
            out = []
            for i in range(count):
                b = raw[i * width:(i + 1) * width]
                v = int.from_bytes(b, 'little')
                if elem == 'f64':
                    v = struct.unpack('<d', b)[0]
                elif elem == 'f32':
                    v = struct.unpack('<f', b[:4])[0]
                elif elem == 'auto':
                    v = self.guess(v)
                out.append(v)
            return out
        if rsz % count:
            raise ValueError(f'{name}: size {rsz} not a multiple of count {count}')
        es = rsz // count
        if elem == 'strlist':
            return [self.struct_at(roff + i * es, es, [('s', P('[0]', 'str'))])['s']
                    for i in range(count)]
        if elem == 'auto':
            elem = BY_RECORD.get(name)
        table = STRUCTS.get(elem) if elem else None
        if table is not None and len(table_slots(table)) * 8 != es:
            raise ValueError(f'{name}: element size {es} does not match table {elem}')
        return [self.struct_at(roff + i * es, es, table) for i in range(count)]

    @staticmethod
    def is_string(name, count, rsz, raw):
        if name in STRING_RECORDS:
            return True
        if rsz != (count + 7) // 8 * 8 or rsz == count * 8:
            return False
        return raw[count - 1] == 0 and all(32 <= c < 127 for c in raw[:count - 1])

    @staticmethod
    def scalar_width(count, rsz, elem):
        if elem == 'f64':
            return 8
        for w in (8, 4, 2, 1):
            if (count * w + 7) // 8 * 8 == rsz:
                return w
        raise ValueError(f'cannot size scalar array: count {count}, size {rsz}')

    # -- structures -----------------------------------------------------
    def struct_at(self, off, size, table):
        out = {}
        if table is None:
            return self.generic(off, size)
        pos = off
        for fname, kind in table:
            if isinstance(kind, tuple):
                _, want, elem = kind
                count, name, roff, rsz = self.take_ref(pos, want)
                val = self.array(count, name, roff, rsz, elem)
                pos += 16
            else:
                val = self.scalar(pos, kind)
                pos += 8
            put(out, fname, val)
        if pos != off + size:
            raise ValueError(f'table covers {pos - off} bytes of a {size}-byte struct')
        return out

    def generic(self, off, size):
        out = {}
        i, end = 0, off + size
        while off + 8 * i < end:
            o = off + 8 * i
            if self.looks_like_ref(o, end):
                count, name, roff, rsz = self.take_ref(o)
                key = name if name not in out else f'{name}@{i}'
                out[key] = self.array(count, name, roff, rsz, 'auto')
                i += 2
            else:
                out[f'_slot{i}'] = self.guess(self.slot(o))
                i += 1
        return out

    def decode(self):
        tree = {}
        for rid in self.tops:
            name, flags, _p, roff, rsz = self.recs[rid]
            tree[name] = self.struct_at(roff, rsz, STRUCTS.get(name))
        missing = sorted(set(self.recs) - self.used)
        if missing or self.next_id != max(self.recs) + 1:
            raise ValueError(f'{len(missing)} records not consumed, first {missing[:5]}')
        return tree


def table_slots(table):
    out = []
    for _n, kind in table:
        out += [0, 0] if isinstance(kind, tuple) else [0]
    return out


def put(d, dotted, val):
    parts = dotted.split('.')
    for p in parts[:-1]:
        d = d.setdefault(p, {})
    d[parts[-1]] = val


def annotate(node):
    """Add readable names next to a few enums whose values we can pin down."""
    if isinstance(node, dict):
        if 'configType' in node and 'delayMs' in node:
            t = node['configType']
            node['configTypeName'] = POWER_TYPES[t] if 0 <= t < len(POWER_TYPES) else None
        for v in node.values():
            annotate(v)
    elif isinstance(node, list):
        for v in node:
            annotate(v)


HEX_KEYS = {'registerAddr', 'registerData', 'slaveAddr', 'slaveAddress', 'sensorIdRegAddr',
            'sensorId', 'sensorIdMask', 'xOutput', 'yOutput', 'frameLengthLines',
            'lineLengthPixelClock', 'coarseIntgTimeAddr', 'globalGainAddr', 'dt',
            'laneAssign'}


def hexify(node, key=None, in_addr=False):
    if isinstance(node, dict):
        addr_ctx = key == 'regAddrInfo'
        return {k: hexify(v, k, addr_ctx or in_addr) for k, v in node.items()}
    if isinstance(node, list):
        return [hexify(v, key, in_addr) for v in node]
    if isinstance(node, int) and (key in HEX_KEYS and (in_addr or key not in
                                  ('frameLengthLines', 'lineLengthPixelClock'))
                                  or (in_addr and key.endswith('Addr'))):
        return hex(node)
    return node


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        sys.stderr.write(__doc__.split('\n\n')[1] + '\n')
        return 2
    with open(args[0], 'rb') as f:
        data = f.read()
    dec = Decoder(data)
    tree = dec.decode()
    annotate(tree)
    meta = {
        'file': args[0].rsplit('/', 1)[-1],
        'size': len(data),
        'parser': data[0x28:0x98].split(b'\0')[0].decode(),
        'sections': [{'id': s[0], 'offset': s[1], 'size': s[2]} for s in dec.sections],
        'records': len(dec.recs),
        'topLevel': [dec.recs[r][0] for r in dec.tops],
    }
    out = {'_meta': meta, **tree}
    if '--hex' in argv:
        out = hexify(out)
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
