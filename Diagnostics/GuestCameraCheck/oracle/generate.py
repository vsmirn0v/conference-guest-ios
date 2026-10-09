import av, pathlib
out=pathlib.Path(__file__).parent
for profile in ('baseline','main','high'):
 for signal in (False,True):
  ctx=av.CodecContext.create('libx264','w');ctx.width=320;ctx.height=240;ctx.pix_fmt='yuv420p';ctx.time_base=__import__('fractions').Fraction(1,30)
  ctx.options={'profile':profile,'preset':'ultrafast','x264-params': ('colorprim=bt709:transfer=bt709:colormatrix=bt709:videoformat=pal:fullrange=on:force-cfr=1' if signal else 'force-cfr=1')}
  if profile!='baseline':ctx.options['preset']='medium'
  frame=av.VideoFrame(320,240,'yuv420p');frame.pts=0
  for p in frame.planes:p.update(bytes([80 if p==frame.planes[0] else 128])*p.buffer_size)
  data=b''.join(bytes(p) for p in list(ctx.encode(frame))+list(ctx.encode(None)))
  (out/f'{profile}-{signal}.h264').write_bytes(data)
print('generated six independent streams')
