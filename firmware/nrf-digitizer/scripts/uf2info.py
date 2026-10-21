#!/usr/bin/env python3
"""Print (and optionally check) start address and family ID of a UF2 file.

    python3 uf2info.py zephyr.uf2 [--expect-start 0x26000]
"""
import argparse
import struct
import sys

UF2_MAGIC0, UF2_MAGIC1, UF2_FLAG_FAMILY = 0x0A324655, 0x9E5D5157, 0x00002000


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('file')
    p.add_argument('--expect-start', type=lambda s: int(s, 0))
    p.add_argument('--expect-family', type=lambda s: int(s, 0), default=0xADA52840)
    a = p.parse_args()

    data = open(a.file, 'rb').read()
    addrs, families = [], set()
    for off in range(0, len(data), 512):
        m0, m1, flags, addr, size, _, _, fam = struct.unpack('<8I', data[off:off + 32])
        if (m0, m1) != (UF2_MAGIC0, UF2_MAGIC1):
            print(f'{a.file}: bad UF2 block at offset {off}', file=sys.stderr)
            return 1
        addrs.append((addr, size))
        if flags & UF2_FLAG_FAMILY:
            families.add(fam)

    start = min(x for x, _ in addrs)
    end = max(x + s for x, s in addrs)
    fams = ', '.join(hex(f) for f in sorted(families)) or 'none'
    print(f'{a.file}: {len(addrs)} blocks, 0x{start:05x}-0x{end:05x}, family {fams}')

    ok = True
    if a.expect_start is not None and start != a.expect_start:
        print(f'  expected start 0x{a.expect_start:05x}!', file=sys.stderr)
        ok = False
    if families != {a.expect_family}:
        print(f'  expected family 0x{a.expect_family:08x}!', file=sys.stderr)
        ok = False
    if end > 0xF4000:
        print('  image overlaps the UF2 bootloader at 0xF4000!', file=sys.stderr)
        ok = False
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
