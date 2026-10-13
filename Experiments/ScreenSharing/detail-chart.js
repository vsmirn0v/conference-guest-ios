// Disposable QA room only. Supplies generated pixels to the browser's normal
// Share Screen button, without selecting or capturing any desktop content.
(() => {
  const canvas = document.createElement('canvas');
  canvas.width = 3840; canvas.height = 2160;
  const context = canvas.getContext('2d');
  context.fillStyle = '#fff'; context.fillRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = '#000';
  [16, 20, 24, 32, 48, 64].forEach((size, index) => {
    context.font = `${size}px monospace`;
    context.fillText(`${size} px — Screen detail / Чёткость текста — ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789`, 80, 100 + index * 110);
  });
  const stream = canvas.captureStream(5);
  stream.getVideoTracks()[0].contentHint = 'detail';
  const original = navigator.mediaDevices.getDisplayMedia;
  navigator.mediaDevices.getDisplayMedia = async () => stream;
  let tick = 0;
  const timer = setInterval(() => {
    context.fillStyle = tick++ % 2 ? '#080' : '#00f';
    context.fillRect(80, 1200, 100, 100);
  }, 200);
  window.rockDetailChart = { stop() {
    clearInterval(timer); stream.getTracks().forEach(track => track.stop());
    navigator.mediaDevices.getDisplayMedia = original;
  }, settings() { return stream.getVideoTracks()[0].getSettings(); } };
  return window.rockDetailChart.settings();
})()
