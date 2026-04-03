# indigo3 Design

## Purpose

macOS app that receives NDI and Syphon video sources and streams them as low-latency H.264 over WebSocket to a web browser (elverket). Designed for 5 simultaneous 1920x1080 streams at real-time latency (~100-200ms).

## Non-goals

- Virtual camera output (dropped — system extension pain from indigo2)
- Cross-platform (macOS only, Swift native)
- Cloud relay (direct WebSocket connection only)

## Architecture

```
NDI/Syphon Sources
       |
  SourceManager (discover + receive)
       |
  CVPixelBuffer (per source)
       |
  VTCompressionSession (hardware H.264, per stream)
       |
  Raw H.264 NALUs
       |
  NWListener WebSocket Server
  ws://hostname:9000/stream/{id}
       |
  elverket browser
  WebCodecs VideoDecoder -> WebGL texture
```

## Components

### SourceManager
- Discovers NDI sources via `NDIlib_find` (polls every 2s)
- Discovers Syphon sources via `SyphonServerDirectory`
- Manages source-to-stream mappings
- Publishes state for SwiftUI binding

### NDIReceiver
- Adapted from indigo2
- Connects to NDI source, receives frames on dedicated dispatch queue
- Outputs `CVPixelBuffer` (BGRA) via callback
- One instance per active NDI mapping

### SyphonReceiver
- Adapted from indigo2
- Uses `SyphonMetalClient` for GPU frame capture
- Outputs `CVPixelBuffer` via Metal blit to pixel buffer
- One instance per active Syphon mapping

### StreamEncoder
- One `VTCompressionSession` per active stream
- Hardware-accelerated H.264 via VideoToolbox
- Configuration:
  - `kVTCompressionPropertyKey_RealTime: true`
  - `kVTCompressionPropertyKey_MaxKeyFrameInterval: 30` (1 keyframe/sec at 30fps)
  - `kVTCompressionPropertyKey_AverageBitRate: 8_000_000` (8 Mbps per stream)
  - `kVTCompressionPropertyKey_ProfileLevel: H264_High_AutoLevel`
  - `kVTCompressionPropertyKey_AllowFrameReordering: false` (no B-frames, lower latency)
- Extracts SPS/PPS from keyframes for decoder initialization
- Outputs raw NALUs via callback

### WebSocketServer
- `NWListener` on configurable port (default 9000)
- Path-based routing: `/stream/{id}` for video, `/api/sources` for source list
- Binary WebSocket frames with minimal header:
  - Byte 0: type (0x00 = config SPS/PPS, 0x01 = keyframe, 0x02 = delta)
  - Bytes 1-8: timestamp (uint64, microseconds)
  - Bytes 9+: H.264 NALU data
- On new client connect: immediately sends latest SPS/PPS + keyframe so decoder can initialize
- Broadcasts frames to all connected clients per stream
- Tracks connected client count per stream

### SwiftUI Interface
- Left panel: discovered NDI + Syphon sources with "Add Stream" button
- Right panel: active streams showing:
  - Source name
  - Stream URL (ws://...)
  - Encoding stats (fps, bitrate)
  - Connected client count
  - Start/stop/remove controls
- Status bar: server port, total bandwidth

## Browser Protocol (elverket side)

```javascript
const ws = new WebSocket('ws://hostname:9000/stream/1');
ws.binaryType = 'arraybuffer';

const decoder = new VideoDecoder({
  output: (frame) => {
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
    frame.close();
  },
  error: (e) => console.error(e)
});

ws.onmessage = (e) => {
  const view = new DataView(e.data);
  const type = view.getUint8(0);
  const timestamp = Number(view.getBigUint64(1));
  const nalu = new Uint8Array(e.data, 9);

  if (type === 0x00) {
    // SPS/PPS — configure decoder
    decoder.configure({
      codec: 'avc1.640028', // High profile
      codedWidth: 1920,
      codedHeight: 1080,
    });
  } else {
    decoder.decode(new EncodedVideoChunk({
      type: type === 0x01 ? 'key' : 'delta',
      timestamp: timestamp,
      data: nalu,
    }));
  }
};
```

## Dependencies

- **NDI SDK** (`/Library/NDI SDK for Apple/`) — C library, same as indigo2
- **Syphon** — Objective-C framework via CSyphon wrapper from indigo2
- **Apple frameworks**: VideoToolbox, Network, CoreVideo, Metal, SwiftUI

## Performance Budget (5 streams)

| Metric | Per stream | Total |
|--------|-----------|-------|
| Resolution | 1920x1080 | - |
| Frame rate | 30 fps | 150 fps encode |
| Bitrate | 8 Mbps | 40 Mbps |
| Encode latency | ~5ms (VideoToolbox HW) | - |
| Network latency | ~50-150ms (internet) | - |
| End-to-end target | < 200ms | - |

VideoToolbox supports up to 8 simultaneous hardware encode sessions on Apple Silicon, so 5 streams is within budget.

## Project Structure

```
indigo3/
  Package.swift
  Sources/
    Indigo3/
      Indigo3App.swift
      ContentView.swift
      SourceManager.swift
      NDIReceiver.swift
      SyphonReceiver.swift
      StreamEncoder.swift
      WebSocketServer.swift
    CSyphon/          (copied from indigo2)
    CNDI/             (copied from indigo2)
```

No Xcode project — pure Swift Package Manager with `executableTarget`. Build with `swift build` or open `Package.swift` in Xcode.

## What's different from indigo2

| | indigo2 | indigo3 |
|--|---------|---------|
| Output | Virtual camera (CMIOExtension) | H.264 WebSocket stream |
| System extension | Yes (approval + reboot pain) | None |
| IPC | IOSurface + JSON file polling | None (single process) |
| Entitlements | System extension install, sandbox disabled | Network server only |
| Browser integration | N/A | WebCodecs + WebGL textures |
| Complexity | ~1500 LOC + extension | ~800 LOC estimated |
