import av,pathlib,hashlib
root=pathlib.Path(__file__).parent
for original in sorted(root.glob('*.h264')):
 def decode(p):
  c=av.CodecContext.create('h264','r');frames=[]
  for packet in c.parse(p.read_bytes())+c.parse(b''):frames+=c.decode(packet)
  frames+=c.decode(None)
  return frames[0]
 a,b=decode(original),decode(original.with_suffix('.h264.normalized'))
 assert (b.colorspace,b.color_primaries,b.color_trc)==(1,1,1),(original,b.colorspace,b.color_primaries,b.color_trc)
 assert b.color_range==(a.color_range or 1)
 assert all(all(bytes(pa)[r*pa.line_size:r*pa.line_size+pa.width]==bytes(pb)[r*pb.line_size:r*pb.line_size+pb.width] for r in range(pa.height)) for pa,pb in zip(a.planes,b.planes)),original
 print(original.name,'pixels identical','range',b.color_range,'color709')
