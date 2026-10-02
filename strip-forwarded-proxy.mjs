// Forwards :18789 to the gateway on 127.0.0.1:18790 with forwarded-client
// headers removed. The router reaches the gateway from the host's own IP, so
// OpenClaw can't attribute those headers and rejects the request
// (proxy_attribution_required). Only used in password auth mode.
import http from "node:http";
import net from "node:net";

const LISTEN_PORT = 18789;
const GATEWAY_PORT = 18790;
const STRIP = new Set(["forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto", "x-forwarded-port", "x-real-ip"]);

const cleanHeaders = (raw) => {
  const out = [];
  for (let i = 0; i < raw.length; i += 2) {
    const name = raw[i].toLowerCase();
    // tailscale serve adds Tailscale-User-* identity headers, which OpenClaw
    // also treats as proxy-shaped and rejects.
    if (!STRIP.has(name) && !name.startsWith("tailscale-")) out.push(raw[i], raw[i + 1]);
  }
  return out;
};

const server = http.createServer((req, res) => {
  const upstream = http.request(
    { host: "127.0.0.1", port: GATEWAY_PORT, method: req.method, path: req.url, headers: cleanHeaders(req.rawHeaders) },
    (up) => {
      res.writeHead(up.statusCode, up.rawHeaders);
      up.pipe(res);
    },
  );
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502);
    res.end();
  });
  req.pipe(upstream);
});

// WebSocket upgrades: replay the handshake with clean headers, then pipe raw bytes.
server.on("upgrade", (req, socket, head) => {
  const upstream = net.connect(GATEWAY_PORT, "127.0.0.1", () => {
    const h = cleanHeaders(req.rawHeaders);
    let msg = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < h.length; i += 2) msg += `${h[i]}: ${h[i + 1]}\r\n`;
    upstream.write(msg + "\r\n");
    if (head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

server.listen(LISTEN_PORT);
