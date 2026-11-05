// Passive, bounded observation of the existing video. Does not navigate,
// change quality, play, pause, draw, or modify page content.
// presentedFrames counts browser submissions for composition, not Mac FPS.
(() => new Promise((resolve) => {
  const video = document.querySelector('video');
  if (!video || typeof video.requestVideoFrameCallback !== 'function') {
    resolve({error: 'Video frame callbacks unavailable'});
    return;
  }
  const state = () => ({url: location.href, time: video.currentTime,
    width: video.videoWidth, height: video.videoHeight, paused: video.paused,
    ready: video.readyState, quality: video.getVideoPlaybackQuality().toJSON?.()
      ?? {totalVideoFrames: video.getVideoPlaybackQuality().totalVideoFrames,
          droppedVideoFrames: video.getVideoPlaybackQuality().droppedVideoFrames}});
  const before = state(), started = performance.now(), utc = Date.now();
  const frames = [];
  let handle, finished = false, omitted = 0;
  function observe(now, metadata) {
    if (finished) return;
    if (frames.length < 512) {
      frames.push({now, ...metadata});
    } else {
      omitted++;
    }
    handle = video.requestVideoFrameCallback(observe);
  }
  handle = video.requestVideoFrameCallback(observe);
  setTimeout(() => {
    finished = true;
    video.cancelVideoFrameCallback(handle);
    resolve({started, ended: performance.now(), utc, timeOrigin: performance.timeOrigin,
      before, after: state(), frames, omitted});
  }, 6000);
}))()
