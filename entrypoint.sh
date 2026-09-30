#!/bin/sh
set -e

DATA_DIR=/data/app_data/openclaw
TARGET=/home/node/.openclaw

mkdir -p "$DATA_DIR"
chown -R node:node "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [ ! -L "$TARGET" ] || [ "$(readlink "$TARGET")" != "$DATA_DIR" ]; then
    rm -rf "$TARGET"
    ln -s "$DATA_DIR" "$TARGET"
    chown -h node:node "$TARGET"
fi

ZONE_DOMAIN="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_NAME="${OPENHOST_APP_NAME:-openclaw}"
APP_ORIGIN="https://${APP_NAME}.${ZONE_DOMAIN}"

ANTHROPIC_API_KEY=""
OPENAI_API_KEY=""
GEMINI_API_KEY=""
OPENCLAW_GATEWAY_PASSWORD=""
GRANT_URL=""
if [ -n "$OPENHOST_ROUTER_URL" ] && [ -n "$OPENHOST_APP_TOKEN" ]; then
    secrets_response=$(curl -sS -X POST \
        -H "Authorization: Bearer $OPENHOST_APP_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"keys": ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "OPENCLAW_GATEWAY_PASSWORD"]}' \
        "$OPENHOST_ROUTER_URL/api/services/v2/call/secrets/get" 2>/dev/null || true)
    # Emits shell-quoted KEY=value lines for the secrets that are present.
    eval "$(printf '%s' "$secrets_response" | python3 -c 'import sys,json,shlex
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k, v in (d.get("secrets") or {}).items():
    if k in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "OPENCLAW_GATEWAY_PASSWORD") and v:
        print(f"{k}={shlex.quote(v)}")
grant_url = d.get("grant_url") or (d.get("required_grant") or {}).get("grant_url", "")
if grant_url:
    print(f"GRANT_URL={shlex.quote(grant_url)}")' 2>/dev/null || true)"
fi

[ -n "$ANTHROPIC_API_KEY" ] && echo "[entrypoint] ANTHROPIC_API_KEY loaded from secrets service"
[ -n "$OPENAI_API_KEY" ] && echo "[entrypoint] OPENAI_API_KEY loaded from secrets service"
[ -n "$GEMINI_API_KEY" ] && echo "[entrypoint] GEMINI_API_KEY loaded from secrets service"
if [ -n "$GRANT_URL" ]; then
    echo "[entrypoint] secrets permission needed — approve at: $GRANT_URL"
    echo "[entrypoint] After approving, run: oh app reload openclaw"
fi
if [ -z "$ANTHROPIC_API_KEY$OPENAI_API_KEY$GEMINI_API_KEY" ]; then
    echo "[entrypoint] no provider API key in secrets; add one there or log in to a provider from the Control UI"
fi
if [ -n "$OPENCLAW_GATEWAY_PASSWORD" ]; then
    echo "[entrypoint] gateway auth: password (OPENCLAW_GATEWAY_PASSWORD)"
else
    echo "[entrypoint] gateway auth: trusted-proxy (router auto-login)"
fi

# Password is passed as an argument, never interpolated into the Python source.
runuser -u node -- python3 - "$OPENCLAW_GATEWAY_PASSWORD" "$ANTHROPIC_API_KEY" "$GEMINI_API_KEY" <<PY
import json
import sys
from pathlib import Path

password, has_anthropic, has_gemini = sys.argv[1], bool(sys.argv[2]), bool(sys.argv[3])

cfg_path = Path("$DATA_DIR/openclaw.json")
cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}

gw = cfg.setdefault("gateway", {})
if password:
    # When the router reaches the gateway from the host's own interface IP,
    # OpenClaw's trusted-proxy spoofing guard rejects it
    # (trusted_proxy_local_interface_source); password auth sidesteps that.
    gw["auth"] = {"mode": "password", "password": password}
else:
    gw["auth"] = {
        "mode": "trusted-proxy",
        "trustedProxy": {
            "userHeader": "X-OpenHost-Is-Owner",
            "requiredHeaders": ["X-OpenHost-Is-Owner"],
            "allowUsers": ["true"],
            "allowLoopback": True,
        },
    }
gw["trustedProxies"] = ["0.0.0.0/0", "::/0"]
control_ui = gw.setdefault("controlUi", {})
control_ui["allowedOrigins"] = ["${APP_ORIGIN}"]
control_ui["dangerouslyDisableDeviceAuth"] = True

# Only set a default model when none is configured, so a model picked in the
# Control UI (OpenAI, Gemini, ChatGPT login, ...) survives restarts.
agents_defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
if "model" not in agents_defaults:
    if has_anthropic:
        agents_defaults["model"] = {"primary": "anthropic/claude-sonnet-4-6"}
    elif has_gemini:
        agents_defaults["model"] = {"primary": "google/gemini-3.1-pro-preview"}

cfg_path.write_text(json.dumps(cfg, indent=2))
PY

export ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY
exec runuser -u node --whitelist-environment=ANTHROPIC_API_KEY,OPENAI_API_KEY,GEMINI_API_KEY -- "$@"
