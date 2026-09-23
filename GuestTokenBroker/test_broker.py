import base64
import json
from http.server import ThreadingHTTPServer
from threading import Thread
from unittest import TestCase
from unittest.mock import patch
from urllib import error, request
from uuid import uuid4

from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives import hashes

from broker import SDKKey, TokenBroker, decode_b64url, handler_for


class BrokerTests(TestCase):
    def make_key(self):
        private = ec.generate_private_key(ec.SECP384R1())
        numbers = private.private_numbers()
        public = numbers.public_numbers
        encode = lambda value: base64.urlsafe_b64encode(value.to_bytes(48, "big")).rstrip(b"=").decode()
        document = {
            "projectId": str(uuid4()),
            "key": {
                "kty": "EC", "crv": "P-384", "kid": "test-key",
                "d": encode(numbers.private_value),
                "x": encode(public.x), "y": encode(public.y),
            },
        }
        encoded = base64.b64encode(json.dumps(document).encode()).decode()
        return SDKKey.from_base64(encoded), private

    def test_transport_token_uses_verifiable_jose_signature_and_guest_claims(self):
        sdk_key, private = self.make_key()
        guest = uuid4()
        token = sdk_key.transport_token(guest, "Guest")
        header_part, payload_part, signature_part = token.split(".")
        header = json.loads(decode_b64url(header_part))
        payload = json.loads(decode_b64url(payload_part))
        self.assertEqual(header["alg"], "ES384")
        self.assertEqual(payload["sub"], str(guest))
        self.assertEqual(payload["userName"], "Guest")
        self.assertEqual(payload["exp"] - payload["iat"], 300)
        signature = decode_b64url(signature_part)
        self.assertEqual(len(signature), 96)
        r = int.from_bytes(signature[:48], "big")
        s = int.from_bytes(signature[48:], "big")
        private.public_key().verify(
            utils.encode_dss_signature(r, s),
            f"{header_part}.{payload_part}".encode(),
            ec.ECDSA(hashes.SHA384()),
        )

    def test_rejects_mismatched_public_coordinates(self):
        sdk_key, private = self.make_key()
        numbers = private.private_numbers()
        other = ec.generate_private_key(ec.SECP384R1()).public_key().public_numbers()
        encode = lambda value: base64.urlsafe_b64encode(value.to_bytes(48, "big")).rstrip(b"=").decode()
        encoded = base64.b64encode(json.dumps({
            "projectId": sdk_key.project_id,
            "key": {"kty": "EC", "crv": "P-384", "kid": "bad",
                    "d": encode(numbers.private_value), "x": encode(other.x), "y": encode(other.y)},
        }).encode()).decode()
        with self.assertRaises(ValueError):
            SDKKey.from_base64(encoded)

    def test_limits_anonymous_token_requests(self):
        sdk_key, _ = self.make_key()
        broker = TokenBroker(sdk_key, "https://provider.example")
        with patch("broker.time.monotonic", return_value=100):
            self.assertTrue(all(broker.allow("192.0.2.1") for _ in range(12)))
            self.assertFalse(broker.allow("192.0.2.1"))
            self.assertTrue(broker.allow("192.0.2.2"))
        with patch("broker.time.monotonic", return_value=161):
            self.assertTrue(broker.allow("192.0.2.1"))

    def test_http_endpoint_validates_guest_and_returns_only_access_token(self):
        class FakeBroker:
            def allow(self, address):
                return True

            def get_access_token(self, guest_id, display_name):
                self.last_guest = (guest_id, display_name)
                return "example-provider-access-token"

        fake = FakeBroker()
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(fake))
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            valid = json.dumps({"guestId": str(uuid4()), "displayName": "Guest"}).encode()
            response = request.urlopen(request.Request(
                base + "/v1/guest-token", valid,
                {"Content-Type": "application/json"}, method="POST"
            ))
            self.assertEqual(json.load(response), {"token": "example-provider-access-token"})
            self.assertEqual(fake.last_guest[1], "Guest")
            invalid = json.dumps({"guestId": str(uuid4()), "displayName": 42}).encode()
            with self.assertRaises(error.HTTPError) as caught:
                request.urlopen(request.Request(base + "/v1/guest-token", invalid, method="POST"))
            self.assertEqual(caught.exception.code, 400)
            caught.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
