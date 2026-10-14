#!/usr/bin/env python3
"""Structural validator for the Xray configuration produced by lib/config_gen.sh.

The sandbox has no network access to release-assets.githubusercontent.com, so
`xray -test` cannot run here (it does run on the target machine during install).
This checker enforces the parts of the Xray schema that the generator is
responsible for, so a broken template is caught in CI rather than on a VPS.

Usage: validate_config.py <config.json>
Exit 0 = valid, 1 = invalid (problems printed to stdout).
"""

import base64
import json
import re
import sys

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
B64URL_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")


def main(path: str) -> int:
    problems: list[str] = []

    def need(cond: bool, msg: str) -> bool:
        if not cond:
            problems.append(msg)
        return cond

    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(f"cannot parse {path}: {exc}")
        return 1

    need(isinstance(cfg, dict), "top level must be an object")
    for key in ("log", "routing", "inbounds", "outbounds", "policy", "stats"):
        need(key in cfg, f"missing top-level key: {key}")

    inbounds = cfg.get("inbounds", [])
    outbounds = cfg.get("outbounds", [])
    need(len(inbounds) == 2, f"expected 2 inbounds (tunnel + api), got {len(inbounds)}")
    need(len(outbounds) == 2, f"expected 2 outbounds (freedom + blackhole), got {len(outbounds)}")

    # ---- main inbound ----------------------------------------------------
    tun = inbounds[0] if inbounds else {}
    need(tun.get("protocol") == "vless", "main inbound protocol must be vless")
    need(tun.get("settings", {}).get("decryption") == "none",
         "vless settings.decryption must be 'none'")
    need(tun.get("listen") in ("0.0.0.0", "::", None), "main inbound must listen on all interfaces")
    port = tun.get("port")
    need(isinstance(port, int) and 1 <= port <= 65535, f"invalid inbound port: {port!r}")

    clients = tun.get("settings", {}).get("clients", [])
    need(len(clients) >= 1, "at least one client is required")
    for i, client in enumerate(clients):
        need(UUID_RE.match(client.get("id", "")) is not None,
             f"client[{i}].id is not a UUID: {client.get('id')!r}")
        need(client.get("email"), f"client[{i}] needs an email (used for stats)")
        need(client.get("level") == 0, f"client[{i}].level must be 0")

    stream = tun.get("streamSettings", {})
    network = stream.get("network")
    security = stream.get("security")
    need(network in ("tcp", "ws", "grpc", "kcp"), f"unknown network: {network!r}")

    if security == "reality":
        need(network == "tcp", "REALITY requires the tcp network")
        rs = stream.get("realitySettings", {})
        need(B64URL_RE.match(rs.get("privateKey", "")) is not None,
             f"realitySettings.privateKey must be 43 chars of base64url: {rs.get('privateKey')!r}")
        if B64URL_RE.match(rs.get("privateKey", "")):
            raw = base64.urlsafe_b64decode(rs["privateKey"] + "=" * ((4 - len(rs["privateKey"]) % 4) % 4))
            need(len(raw) == 32, f"REALITY private key must decode to 32 bytes, got {len(raw)}")
        need(bool(rs.get("shortIds")), "realitySettings.shortIds must not be empty")
        for sid in rs.get("shortIds", []):
            need(re.fullmatch(r"[0-9a-f]{2,16}", sid) is not None,
                 f"shortId must be 2-16 hex chars: {sid!r}")
        need(bool(rs.get("serverNames")), "realitySettings.serverNames must not be empty")
        dest = rs.get("dest", "")
        need(re.fullmatch(r"[^:/]+:\d+", dest) is not None,
             f"realitySettings.dest must be host:port: {dest!r}")
        need(rs.get("xver") in (0, 1, 2), f"realitySettings.xver must be 0-2: {rs.get('xver')!r}")
        for client in clients:
            need(client.get("flow") == "xtls-rprx-vision",
                 "REALITY clients must use flow xtls-rprx-vision")
    elif security == "tls":
        ts = stream.get("tlsSettings", {})
        certs = ts.get("certificates", [])
        need(len(certs) == 1, "tlsSettings.certificates must hold exactly one entry")
        if certs:
            need(certs[0].get("certificateFile", "").endswith((".pem", ".crt")),
                 "certificateFile must be a pem/crt path")
            need(certs[0].get("keyFile", "").endswith(".key")
                 or certs[0].get("keyFile", "").endswith(".pem"),
                 "keyFile must be a .key/.pem path")
            need("/etc/vt/certs" in certs[0].get("certificateFile", ""),
                 "certificate path must point at the managed cert directory")
        for client in clients:
            if network == "ws":
                need("flow" not in client, "WebSocket clients must not set a flow")
        if network == "ws":
            ws = stream.get("wsSettings", {})
            need(ws.get("path", "").startswith("/"), f"wsSettings.path must start with /: {ws.get('path')!r}")
            need(len(ws.get("path", "")) >= 8, "wsSettings.path should be long enough to be unguessable")
    else:
        problems.append(f"unknown streamSettings.security: {security!r}")

    sniff = tun.get("sniffing", {})
    need(sniff.get("enabled") is True, "sniffing should be enabled on the tunnel inbound")
    need(set(sniff.get("destOverride", [])) >= {"http", "tls"},
         "sniffing.destOverride should cover http and tls")

    # ---- api inbound -----------------------------------------------------
    api = inbounds[1] if len(inbounds) > 1 else {}
    need(api.get("tag") == "api", "second inbound must be tagged 'api'")
    need(api.get("listen") == "127.0.0.1", "the api inbound must never be public")
    need(api.get("protocol") == "dokodemo-door", "api inbound must be dokodemo-door")

    # ---- outbounds -------------------------------------------------------
    tags = [o.get("tag") for o in outbounds]
    need("direct" in tags and "block" in tags, f"outbound tags must include direct and block: {tags}")
    protos = {o.get("tag"): o.get("protocol") for o in outbounds}
    need(protos.get("direct") == "freedom", "the 'direct' outbound must use the freedom protocol")
    need(protos.get("block") == "blackhole", "the 'block' outbound must use the blackhole protocol")

    # ---- routing ---------------------------------------------------------
    rules = cfg.get("routing", {}).get("rules", [])
    need(any(r.get("inboundTag") == ["api"] and r.get("outboundTag") == "api" for r in rules),
         "routing needs a rule that forwards the api inbound to the api outbound")
    private = [r for r in rules if isinstance(r.get("ip"), list)
               and "10.0.0.0/8" in r["ip"] and "192.168.0.0/16" in r["ip"]]
    need(bool(private), "routing must block private address ranges (SSRF protection)")
    for r in rules:
        if r.get("outboundTag"):
            need(r["outboundTag"] in tags + ["api"],
                 f"routing rule references unknown outbound: {r['outboundTag']!r}")
        if r.get("inboundTag"):
            known = [i.get("tag") for i in inbounds]
            for t in r["inboundTag"]:
                need(t in known, f"routing rule references unknown inbound: {t!r}")

    # ---- stats -----------------------------------------------------------
    policy = cfg.get("policy", {})
    need(policy.get("levels", {}).get("0", {}).get("statsUserUplink") is True,
         "per-user uplink stats must be enabled for `vt stats` to work")
    need(policy.get("levels", {}).get("0", {}).get("statsUserDownlink") is True,
         "per-user downlink stats must be enabled for `vt stats` to work")

    # ---- log -------------------------------------------------------------
    err_log = cfg.get("log", {}).get("error", "")
    need(err_log.startswith("/var/log/vt/"), f"error log should live in /var/log/vt: {err_log!r}")

    if problems:
        print(f"{path}: {len(problems)} problem(s)")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"{path}: OK")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
