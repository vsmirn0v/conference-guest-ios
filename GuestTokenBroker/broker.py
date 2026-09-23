"""Minimal local Jazz guest-token broker. Run behind TLS and abuse controls if exposed."""

from __future__ import annotations

import base64
import binascii
from collections import defaultdict, deque
from dataclasses import dataclass
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
import time
from urllib import error, request
from urllib.parse import urlparse
from uuid import UUID, uuid4

from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives import hashes


CURVES = {
    "P-256": (ec.SECP256R1, hashes.SHA256, "ES256", 32),
    "P-384": (ec.SECP384R1, hashes.SHA384, "ES384", 48),
    "P-521": (ec.SECP521R1, hashes.SHA512, "ES512", 66),
}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decode_b64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


@dataclass(frozen=True)
class SDKKey:
    project_id: str
    kid: str
    algorithm: str
    signature_width: int
    key: ec.EllipticCurvePrivateKey
    digest: hashes.HashAlgorithm

    @classmethod
    def from_base64(cls, encoded: str) -> "SDKKey":
        # The SDK key is an encoded JSON object containing projectId and an EC JWK.
        try:
            document = json.loads(decode_b64url(encoded))
            jwk = document["key"]
            curve_type, digest_type, algorithm, width = CURVES[jwk["crv"]]
            if jwk["kty"] != "EC":
                raise ValueError("The Jazz SDK key must be an EC key")
            project_id = str(UUID(document["projectId"]))
            kid = jwk["kid"]
            private_key = ec.derive_private_key(
                int.from_bytes(decode_b64url(jwk["d"]), "big"), curve_type()
            )
            public = private_key.public_key().public_numbers()
            if public.x != int.from_bytes(decode_b64url(jwk["x"]), "big") or \
               public.y != int.from_bytes(decode_b64url(jwk["y"]), "big"):
                raise ValueError("Jazz SDK key coordinates do not match")
            if not isinstance(kid, str) or not kid or len(kid) > 200:
                raise ValueError("Invalid Jazz SDK key ID")
            return cls(project_id, kid, algorithm, width, private_key, digest_type())
        except (KeyError, TypeError, json.JSONDecodeError, UnicodeError, ValueError, binascii.Error) as exc:
            raise ValueError("Invalid Jazz SDK key") from exc

    def transport_token(self, guest_id: UUID, display_name: str) -> str:
        now = int(time.time())
        header = {"alg": self.algorithm, "kid": self.kid, "typ": "JWT"}
        payload = {
            "iat": now,
            "exp": now + 300,
            "jti": str(uuid4()),
            "sub": str(guest_id),
            "sdkProjectId": self.project_id,
            "iss": "jazz-guest-client",
            "userName": display_name,
        }
        compact = lambda obj: json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
        body = f"{b64url(compact(header))}.{b64url(compact(payload))}"
        der = self.key.sign(body.encode("ascii"), ec.ECDSA(self.digest))
        r, s = utils.decode_dss_signature(der)
        signature = r.to_bytes(self.signature_width, "big") + s.to_bytes(self.signature_width, "big")
        return f"{body}.{b64url(signature)}"


class TokenBroker:
    def __init__(self, sdk_key: SDKKey, jazz_api_base: str = "https://api.salutejazz.ru"):
        parsed = urlparse(jazz_api_base)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            raise ValueError("Jazz API base must be an HTTPS origin")
        self.sdk_key = sdk_key
        self.jazz_api_base = jazz_api_base.rstrip("/")
        self.attempts: dict[str, deque[float]] = defaultdict(deque)
        self.lock = Lock()

    def allow(self, address: str) -> bool:
        now = time.monotonic()
        with self.lock:
            attempts = self.attempts[address]
            while attempts and now - attempts[0] >= 60:
                attempts.popleft()
            if len(attempts) >= 12:
                return False
            attempts.append(now)
            return True

    def get_access_token(self, guest_id: UUID, display_name: str) -> str:
        transport = self.sdk_key.transport_token(guest_id, display_name)
        req = request.Request(
            f"{self.jazz_api_base}/v1/auth/login",
            method="POST",
            headers={"Accept": "application/json", "Authorization": f"Bearer {transport}"},
        )
        with request.urlopen(req, timeout=10) as response:
            data = response.read(8192)
        token = json.loads(data)["token"]
        if not isinstance(token, str) or not token or len(token) > 8192:
            raise ValueError("Jazz returned an invalid access token")
        return token


def handler_for(broker: TokenBroker):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path == "/healthz":
                self.respond(200, {"status": "ok"})
            else:
                self.respond(404, {"error": "not found"})

        def do_POST(self) -> None:
            if self.path != "/v1/guest-token":
                self.respond(404, {"error": "not found"})
                return
            if not broker.allow(self.client_address[0]):
                self.respond(429, {"error": "rate limit"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not (1 <= length <= 2048):
                    raise ValueError("Invalid request size")
                data = json.loads(self.rfile.read(length))
                raw_name = data["displayName"]
                if not isinstance(raw_name, str):
                    raise ValueError("Invalid display name")
                name = raw_name.strip()
                guest_id = UUID(data["guestId"])
                if not isinstance(name, str) or not (1 <= len(name) <= 80) or \
                   any(ord(char) < 32 for char in name) or guest_id.version != 4:
                    raise ValueError("Invalid guest")
            except (ValueError, TypeError, KeyError, json.JSONDecodeError):
                self.respond(400, {"error": "invalid guest request"})
                return
            try:
                token = broker.get_access_token(guest_id, name)
            except (error.URLError, TimeoutError, ValueError, KeyError, json.JSONDecodeError):
                self.respond(502, {"error": "Jazz authorization unavailable"})
                return
            self.respond(200, {"token": token})

        def respond(self, status: int, payload: dict[str, str]) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            # Never log a request body, invite, transport token or access token.
            print("broker:", format % args)

    return Handler


def main() -> None:
    encoded_key = os.environ.get("JAZZ_SDK_KEY_B64")
    if not encoded_key:
        raise SystemExit("Set JAZZ_SDK_KEY_B64 outside the repository")
    broker = TokenBroker(
        SDKKey.from_base64(encoded_key),
        os.environ.get("JAZZ_API_BASE_URL", "https://api.salutejazz.ru"),
    )
    host = os.environ.get("BIND_HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8765"))
    ThreadingHTTPServer((host, port), handler_for(broker)).serve_forever()


if __name__ == "__main__":
    main()
