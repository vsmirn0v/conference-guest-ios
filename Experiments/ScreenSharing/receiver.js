// Run in the independent, receive-only browser participant before publishing.
(() => {
  if (window.rockResizeReceiver) return 'already observing';
  const state = window.rockResizeReceiver = { frames: [], reset() { this.frames = []; } };
  const watched = new WeakSet();
  const discover = () => document.querySelectorAll('video').forEach(video => {
    if (watched.has(video)) return;
    watched.add(video);
    const canvas = document.createElement('canvas'); canvas.width = 24; canvas.height = 24;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    let last = 0;
    const frame = (now, metadata) => {
      if (now - last >= 80 && metadata.width > 0 && metadata.height > 0) {
        last = now;
        try {
          context.drawImage(video, 0, 0, 24, 24);
          const pixels = context.getImageData(0, 0, 24, 24).data;
          let hash = 2166136261;
          for (const value of pixels) hash = Math.imul(hash ^ value, 16777619) >>> 0;
          state.frames.push({ width: metadata.width, height: metadata.height, hash, time: Date.now() });
          if (state.frames.length > 1800) state.frames.splice(0, state.frames.length - 1800);
        } catch (error) { state.error = String(error); }
      }
      if (video.isConnected) video.requestVideoFrameCallback(frame);
      else watched.delete(video);
    };
    video.requestVideoFrameCallback(frame);
  });
  state.timer = setInterval(discover, 250); discover();
  return 'observing decoded browser frames';
})()
