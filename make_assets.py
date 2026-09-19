"""Render the original vector-style anchor mark, with no downloaded assets."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent / 'assets'
root.mkdir(exist_ok=True)
scale = 4
im = Image.new('RGBA', (256*scale, 256*scale))
d = ImageDraw.Draw(im)
def box(v): return tuple(int(x*scale) for x in v)
d.rounded_rectangle(box((6, 6, 250, 250)), radius=56*scale, fill='#167D70')
d.rounded_rectangle(box((19, 19, 237, 237)), radius=45*scale, outline='#3D9D90', width=2*scale)
d.ellipse(box((113, 48, 143, 78)), outline='#FFFFFF', width=9*scale)
d.line(box((128, 80, 128, 198)), fill='white', width=11*scale)
d.line(box((90, 112, 166, 112)), fill='white', width=11*scale)
d.arc(box((58, 74, 198, 204)), start=0, end=180, fill='white', width=11*scale)
d.polygon([box(p) for p in [(48,149),(61,121),(79,145)]],fill='white')
d.polygon([box(p) for p in [(177,145),(195,121),(208,149)]],fill='white')
d.ellipse(box((194, 38, 215, 59)), fill='#F3C677')
im = im.resize((256,256),Image.Resampling.LANCZOS)
im.save(root/'app.png')
im.save(root/'app.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
(root/'app.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect x="6" y="6" width="244" height="244" rx="56" fill="#167d70"/><rect x="19" y="19" width="218" height="218" rx="45" fill="none" stroke="#3d9d90" stroke-width="2"/><g fill="none" stroke="white" stroke-width="11"><circle cx="128" cy="63" r="15"/><path d="M128 80v118M90 112h76M58 139a70 65 0 0 0 140 0"/></g><g fill="white"><path d="m48 149 13-28 18 24zM177 145l18-24 13 28z"/></g><circle cx="204.5" cy="48.5" r="10.5" fill="#f3c677"/></svg>''',encoding='utf-8')
