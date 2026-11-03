# usage: parse_hitches.py <hitches.xml> <frame-lifetimes.xml> <seconds> — xctrace repeats values by ref.
import sys
import xml.etree.ElementTree as ET


def rows(path):
    try:
        root = ET.parse(path).getroot()
    except Exception:
        return [], {}
    ids = {e.attrib['id']: e for e in root.iter() if 'id' in e.attrib}
    return root.findall('.//row'), ids


hitches, ids = rows(sys.argv[1])
frames, _ = rows(sys.argv[2])
seconds = float(sys.argv[3])
durations = []
for row in hitches:
    cell = row.find('duration')
    if cell is not None:
        cell = ids.get(cell.attrib.get('ref'), cell)
        durations.append(int(cell.text) / 1e6)
total = sum(durations)
print(f"frames: {len(frames)}  hitches: {len(durations)}  total: {total:.0f} ms  = {total / seconds:.1f} ms/s"
      f"  worst: {max(durations, default=0):.0f} ms" + ("  NOTHING MOVED" if not frames else ""))
