#!/usr/bin/env python3
"""Stdio-to-loopback bridge for the native Rock'N'Roll MCP profile."""
from __future__ import annotations

import argparse
import http.client
import json
import os
import pathlib
import stat
import sys
from typing import Iterable

PROTOCOL_VERSION = "2025-03-26"


class BridgeError(Exception):
    pass


def default_endpoint_file() -> pathlib.Path:
    return pathlib.Path.home() / ".config/rocknroll-mcp/endpoint.json"


def default_config_file() -> pathlib.Path:
    return pathlib.Path.home() / ".config/rocknroll-mcp/client.json"


def read_json(path: pathlib.Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise BridgeError(f"Missing configuration: {path}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise BridgeError(f"Invalid configuration {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise BridgeError(f"Configuration must be a JSON object: {path}")
    return value


def write_private_json(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.chmod(temporary, stat.S_IRUSR | stat.S_IWUSR)
    temporary.replace(path)


class NativeHTTPClient:
    def __init__(self, endpoint_file: pathlib.Path, config_file: pathlib.Path):
        self.endpoint_file = endpoint_file
        self.config_file = config_file

    def _endpoint(self) -> tuple[str, int, str]:
        endpoint = read_json(self.endpoint_file)
        host = endpoint.get("host")
        port = endpoint.get("port")
        path = endpoint.get("path", "/mcp")
        if host not in {"127.0.0.1", "localhost", "::1"} or not isinstance(port, int) or not isinstance(path, str):
            raise BridgeError("The endpoint file must describe a loopback HTTP endpoint.")
        return str(host), int(port), path

    def _token(self) -> str:
        if not self.config_file.exists():
            host, port, _ = self._endpoint()
            endpoint = read_json(self.endpoint_file)
            pairing = endpoint.get("pairing_token")
            if not isinstance(pairing, str) or not pairing:
                raise BridgeError("No paired client token exists and the endpoint has no pairing token.")
            response = self._request("POST", "/pair", {"pairing_token": pairing, "client": "codex"}, token=None)
            token = response.get("client_token")
            if not isinstance(token, str) or not token:
                raise BridgeError("The native server did not issue a client token.")
            write_private_json(self.config_file, {"token": token, "client": "codex"})
        config = read_json(self.config_file)
        token = config.get("token")
        if not isinstance(token, str) or not token:
            raise BridgeError("The client configuration has no token.")
        return token

    def _request(self, method: str, override_path: str | None, body: dict | None, token: str | None) -> dict:
        host, port, path = self._endpoint()
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        payload = json.dumps(body or {}, ensure_ascii=False).encode("utf-8") if body is not None else None
        connection = http.client.HTTPConnection(host, port, timeout=30)
        try:
            connection.request(method, override_path or path, body=payload, headers=headers)
            response = connection.getresponse()
            raw = response.read()
        except OSError as exc:
            raise BridgeError(f"The Rock'N'Roll native MCP endpoint is unavailable: {exc}") from exc
        finally:
            connection.close()
        try:
            decoded = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BridgeError(f"Invalid native MCP response with HTTP {response.status}.") from exc
        if response.status == 401:
            raise BridgeError("The native MCP client token was rejected.")
        if response.status == 403:
            raise BridgeError("The MCP client lacks permission for this operation.")
        if response.status == 503:
            raise BridgeError("The native Rock'N'Roll application is unavailable.")
        if response.status >= 400:
            if isinstance(decoded, dict):
                message = decoded.get("message") or decoded.get("error") or f"Native MCP HTTP {response.status}"
            else:
                message = f"Native MCP HTTP {response.status}"
            raise BridgeError(str(message))
        if not isinstance(decoded, dict):
            raise BridgeError("The native MCP endpoint returned a non-object response.")
        return decoded

    def call(self, request: dict) -> dict:
        token = self._token()
        return self._request("POST", None, request, token=token)


def tool_error(message: str, code: str = "APP_NOT_RUNNING") -> dict:
    return {
        "content": [{"type": "text", "text": json.dumps({"error": {"code": code, "message": message, "retryable": False, "details": {}}}, ensure_ascii=False)}],
        "isError": True,
    }


def serve(stdin: Iterable[str], stdout, client: NativeHTTPClient) -> None:
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
        except (json.JSONDecodeError, ValueError):
            stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}) + "\n")
            stdout.flush()
            continue
        method = request.get("method")
        if method in {"notifications/initialized", "notifications/cancelled", "notifications/progress"}:
            continue
        try:
            if method == "initialize":
                response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "rocknroll-native", "version": "0.1.0"},
                }}
            elif method == "ping":
                response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {}}
            else:
                response = client.call(request)
        except BridgeError as exc:
            if method == "tools/call":
                response = {"jsonrpc": "2.0", "id": request.get("id"), "result": tool_error(str(exc))}
            else:
                response = {"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32000, "message": str(exc)}}
        stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        stdout.flush()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Rock'N'Roll native MCP stdio bridge")
    parser.add_argument("--endpoint-file", type=pathlib.Path, default=default_endpoint_file())
    parser.add_argument("--config-file", type=pathlib.Path, default=default_config_file())
    args = parser.parse_args(argv)
    client = NativeHTTPClient(args.endpoint_file.expanduser().resolve(), args.config_file.expanduser().resolve())
    try:
        serve(sys.stdin, sys.stdout, client)
    except BrokenPipeError:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
