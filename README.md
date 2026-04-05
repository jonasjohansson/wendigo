# Wendigo

A macOS app that bridges NDI and Syphon video sources to WebSocket clients via real-time HEVC (H.265) encoding. Useful for sending live video from professional video tools to web browsers or custom applications over a local network.

## How it works

```
NDI / Syphon source  -->  Hardware HEVC encoder  -->  WebSocket server (port 9000)  -->  Browser / app
```

1. Wendigo discovers available NDI and Syphon sources on your machine/network.
2. You add sources to create stream mappings, each with a unique stream ID.
3. Each source is captured, encoded to HEVC using macOS VideoToolbox (hardware-accelerated on Apple Silicon), and broadcast as binary WebSocket frames.
4. Clients connect, request a stream ID, and receive a live HEVC stream.

## Prerequisites

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** Mac (for hardware HEVC encoding)
- **Xcode 15+** with Swift 5.9
- **NDI SDK for Apple** installed at `/Library/NDI SDK for Apple/`
  - Download from [ndi.video](https://ndi.video/tools/ndi-sdk/)
- **Syphon sources** (optional) — any app that publishes Syphon frames (e.g., Resolume, MadMapper, VDMX)

## Building & Installing

```bash
# Clone the repo
git clone https://github.com/jonasjohansson/wendigo.git
cd wendigo

# Build release and install to /Applications
bash bundle.sh

# Or run directly from source
swift run Wendigo
```

You can also open `Package.swift` in Xcode for a GUI build/run experience.

## Usage

### 1. Launch the app

Open Wendigo from `/Applications`, or run `swift run Wendigo` from the repo.

A window opens with two panels:

- **Sources** (left) — lists discovered NDI and Syphon sources. Click **+** to add a source as a stream.
- **Streams** (right) — shows active stream mappings with stream ID, FPS, and connected client count. Click **Preview** on any stream to see a live video preview.

### 2. Connect a WebSocket client

The server runs on **`ws://<your-ip>:9000`** (shown in the app).

**Stream discovery:**

Connect and send the text message `__list` to receive a JSON array of available streams:

```json
[{"streamId": "arena-floor", "name": "NDI: MACHINE (Arena - FLOOR)", "type": "NDI"}]
```

**Subscribe to a stream:**

Connect and send the stream ID as a text message (e.g., `arena-floor`). The server immediately sends:

1. VPS/SPS/PPS configuration (if available)
2. Latest keyframe (for instant decode)
3. Continuous HEVC frames

### 3. Binary frame format

Each WebSocket binary message has this layout:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 byte | Frame type: `0x00` = VPS/SPS/PPS config, `0x01` = keyframe, `0x02` = delta |
| 1 | 8 bytes | Presentation timestamp in microseconds (big-endian) |
| 9 | N bytes | HEVC NALU data |

**Config frame (`0x00`) payload:**

| Field | Size |
|-------|------|
| VPS length | 4 bytes (big-endian) |
| VPS data | N bytes |
| SPS length | 4 bytes (big-endian) |
| SPS data | N bytes |
| PPS length | 4 bytes (big-endian) |
| PPS data | N bytes |

### Example: browser client with WebCodecs

```html
<canvas id="canvas"></canvas>
<script>
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');

const decoder = new VideoDecoder({
  output: (frame) => {
    canvas.width = frame.displayWidth;
    canvas.height = frame.displayHeight;
    ctx.drawImage(frame, 0, 0);
    frame.close();
  },
  error: (e) => console.error(e),
});

let configured = false;
const ws = new WebSocket('ws://localhost:9000');
ws.binaryType = 'arraybuffer';
ws.onopen = () => ws.send('arena-floor');

ws.onmessage = (e) => {
  const buf = new Uint8Array(e.data);
  const type = buf[0];
  const view = new DataView(e.data, 1, 8);
  const timestamp = Number(view.getBigUint64(0));
  const nalus = buf.slice(9);

  if (type === 0x00) {
    // Parse VPS/SPS/PPS from config frame
    // Configure decoder with codec string 'hev1.1.6.L93.B0'
    decoder.configure({
      codec: 'hev1.1.6.L93.B0',
      optimizeForLatency: true,
    });
    configured = true;
    return;
  }

  if (!configured) return;

  decoder.decode(new EncodedVideoChunk({
    type: type === 0x01 ? 'key' : 'delta',
    timestamp: timestamp,
    data: nalus,
  }));
};
</script>
```

## Architecture

| File | Role |
|------|------|
| `NDIReceiver.swift` | NDI source discovery and frame capture with pixel buffer pooling |
| `SyphonReceiver.swift` | Syphon source discovery and async Metal-based frame capture |
| `StreamEncoder.swift` | Hardware HEVC encoding via VideoToolbox (auto-adapts to input resolution) |
| `WebSocketServer.swift` | NWConnection-based WebSocket server with per-stream routing and backpressure |
| `SourceManager.swift` | Orchestrates sources, encoders, preview, and the server |
| `ContentView.swift` | SwiftUI interface with live video preview |
| `bundle.sh` | Build release and install to /Applications |

## License

MIT
