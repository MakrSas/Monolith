# bgra2png.py IN.bgra OUT.png: a raw BGRA frame (HV_PVG_SHOT_RAW, name ...-WxH.bgra) to PNG, without ImageIO.
import re, struct, sys, zlib
src, dst = sys.argv[1], sys.argv[2]
w, h = map(int, re.search(r'(\d+)x(\d+)\.bgra$', src).groups())
d = open(src, 'rb').read()
rows = bytearray()
for y in range(h):
    rows.append(0)
    r = d[y * w * 4:(y + 1) * w * 4]
    for x in range(w):
        b, g, rr = r[x * 4], r[x * 4 + 1], r[x * 4 + 2]
        rows += bytes((rr, g, b))
def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
open(dst, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))
