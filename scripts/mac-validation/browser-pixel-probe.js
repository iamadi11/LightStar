// Evaluate in the public Shaka demo page. No screen capture or key extraction.
// Results describe this browser/asset only, not Netflix or Prime compatibility.
(async () => {
  if (!globalThis.shaka?.Player) throw new Error("Open the Shaka Player demo first");
  if (window.lightstarPixelProbe) throw new Error("Reload before repeating the probe");
  const panel = document.createElement("section");
  panel.style.cssText = "position:fixed;inset:0;z-index:2147483647;background:#222;color:white;overflow:auto";
  document.body.append(panel);
  const state = window.lightstarPixelProbe = {
    startedAt: new Date().toISOString(), userAgent: navigator.userAgent,
    shaka: shaka.Player.version, entries: [],
  };
  for (const [name, directory] of [["clear", "angel-one"], ["widevine", "angel-one-widevine"]]) {
    const label = document.createElement("h2"); label.textContent = name; panel.append(label);
    const video = document.createElement("video");
    video.muted = true; video.controls = true; video.crossOrigin = "anonymous";
    video.style.cssText = "width:640px;height:360px;max-width:100%;background:black";
    panel.append(video);
    const player = new shaka.Player();
    const entry = { name, video, player, errors: [], samples: [] };
    state.entries.push(entry);
    player.addEventListener("error", event => entry.errors.push({code:event.detail.code, category:event.detail.category}));
    await player.attach(video);
    player.configure({
      drm: { servers: { "com.widevine.alpha": "https://cwip-shaka-proxy.appspot.com/no_auth" } },
      streaming: { retryParameters: {maxAttempts: 1, timeout: 12000} },
    });
    // Start asynchronously so inspection can distinguish loading from pixel failure.
    entry.ready = player.load(`https://storage.googleapis.com/shaka-demo-assets/${directory}/dash.mpd`, 12)
      .then(async () => { await video.play(); entry.loaded = true; })
      .catch(error => {entry.failure = {name:error.name, message:error.message, code:error.code};});
  }
  state.sample = () => state.entries.map(entry => {
    const v = entry.video;
    const sample = {name:entry.name, time:v.currentTime, readyState:v.readyState,
      paused:v.paused, width:v.videoWidth, height:v.videoHeight, hasMediaKeys:!!v.mediaKeys,
      loaded:!!entry.loaded, failure:entry.failure, errors:entry.errors.slice(),
      keySystem:entry.player.keySystem(), decodedFrames:v.getVideoPlaybackQuality().totalVideoFrames};
    const canvas = document.createElement("canvas"); canvas.width = 48; canvas.height = 27;
    const ctx = canvas.getContext("2d", {willReadFrequently:true});
    try {
      const begin = performance.now();
      ctx.drawImage(v, 0, 0, 48, 27);
      const data = ctx.getImageData(0, 0, 48, 27).data;
      let sum = 0, max = 0, lit = 0, opaque = 0;
      const rgbSum = [0, 0, 0];
      for (let i = 0; i < data.length; i += 4) {
        for (let c = 0; c < 3; c++) {rgbSum[c] += data[i+c]; sum += data[i+c]; max = Math.max(max, data[i+c]);}
        if (Math.max(data[i], data[i+1], data[i+2]) > 10) lit++;
        if (data[i+3] === 255) opaque++;
      }
      sample.canvas = {mean:sum/(48*27*3), max, litPixels:lit, opaquePixels:opaque,
        rgbMean:rgbSum.map(n=>n/(48*27)), elapsedMs:performance.now()-begin};
    } catch (error) {sample.canvas = {error:error.name, message:error.message};}
    try {const frame = new VideoFrame(v); sample.videoFrame = {created:true, width:frame.displayWidth, height:frame.displayHeight}; frame.close();}
    catch (error) {sample.videoFrame = {error:error.name, message:error.message};}
    entry.samples.push(sample);
    return sample;
  });
  state.export = () => ({startedAt:state.startedAt, userAgent:state.userAgent, shaka:state.shaka,
    entries:state.entries.map(e=>({name:e.name, samples:e.samples}))});
  return {started:true, startedAt:state.startedAt, userAgent:state.userAgent, shaka:state.shaka};
})()
