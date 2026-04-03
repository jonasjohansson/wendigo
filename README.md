# Indigo3

A macOS app that bridges NDI and Syphon video sources to WebSocket clients via real-time H.264 encoding. Useful for sending live video from professional video tools to web browsers or custom applications over a local network.

## How it works

```
NDI / Syphon source  -->  Hardware H.264 encoder  -->  WebSocket server (port 9000)  -->  Browser / app
```

1. Indigo3 discovers available NDI and Syphon sources on your machine/network.
2. You add sources to create stream mappings, each with a unique stream ID.
3. Each source is captured, encoded to H.264 using macOS VideoToolbox (hardware-accelerated), and broadcast as binary WebSocket frames.
4. Clients connect, request a stream ID, and receive a live H.264 stream.

## Prerequisites

- **macOS 14+** (Sonoma or later)
- **Xcode 15+** with Swift 5.9
- **NDI SDK for Apple** installed at `/Library/NDI SDK for Apple/`
  - Download from [ndi.video](https://ndi.video/tools/ndi-sdk/)
- **Syphon sources** (optional) — any app that publishes Syphon frames (e.g., Resolume, MadMapper, VDMX)

## Building

```bash
# Clone the repo
git clone https://github.com/jonasjohansson/indigo3.git
cd indigo3

# Build with Swift Package Manager
swift build

# Or run directly
swift run Indigo3
```

You can also open `Package.swift` in Xcode for a GUI build/run experience.

## Usage

### 1. Launch the app

```bash
swift run Indigo3
```

A window opens with two panels:

- **Sources** (left) — lists discovered NDI and Syphon sources. Click **+** to add a source as a stream.
- **Streams** (right) — shows active stream mappings with stream ID, FPS, and connected client count.

### 2. Connect a WebSocket client

The server runs on **`ws://<your-ip>:9000`** (shown in the app).

**Stream discovery:**

Connect and send the text message `__list` to receive a JSON array of available streams:

```json
[{"streamId": "arena-floor", "name": "NDI: MACHINE (Arena - FLOOR)", "type": "NDI"}]
```

**Subscribe to a stream:**

Connect and send the stream ID as a text message (e.g., `arena-floor`). The server immediately sends:

1. SPS/PPS configuration (if available)
2. Latest keyframe (for instant decode)
3. Continuous H.264 frames

### 3. Binary frame format

Each WebSocket binary message has this layout:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 byte | Frame type: `0x00` = SPS/PPS config, `0x01` = keyframe, `0x02` = delta |
| 1 | 8 bytes | Presentation timestamp in microseconds (big-endian) |
| 9 | N bytes | H.264 NALU data |

**Config frame (`0x00`) payload:**

| Field | Size |
|-------|------|
| SPS length | 4 bytes (big-endian) |
| SPS data | N bytes |
| PPS length | 4 bytes (big-endian) |
| PPS data | N bytes |

### Example: browser client with jmuxer

```html
<script src="https://cdn.jsdelivr.net/npm/jmuxer/dist/jmuxer.min.js"></script>
<script>
const jmuxer = new JMuxer({ node: 'player', mode: 'video', debug: false });
const ws = new WebSocket('ws://localhost:9000');
ws.binaryType = 'arraybuffer';
ws.onopen = () => ws.send('arena-floor');
ws.onmessage = (e) => {
  const buf = new Uint8Array(e.data);
  const type = buf[0];
  const nalus = buf.slice(9);
  if (type === 0x00) return; // config handled by keyframe
  jmuxer.feed({ video: nalus });
};
</script>
<video id="player" autoplay muted></video>
```

## Architecture

| File | Role |
|------|------|
| `NDIReceiver.swift` | NDI source discovery and frame capture |
| `SyphonReceiver.swift` | Syphon source discovery and Metal-based frame capture |
| `StreamEncoder.swift` | Hardware H.264 encoding via VideoToolbox (auto-adapts to input resolution) |
| `WebSocketServer.swift` | NWConnection-based WebSocket server with per-stream routing and backpressure |
| `SourceManager.swift` | Orchestrates sources, encoders, and the server |
| `ContentView.swift` | SwiftUI interface |

## License

MIT
