#!/usr/bin/env python3
"""CI helper: the development certificates automatic signing makes ("Created via API").

Every TestFlight run on a fresh runner makes a new one, and the team's limit is ten; the eleventh
run then fails ("Your account has reached the maximum number of certificates"). So the job lists
the ids before the archive and revokes, afterwards, the ones that appeared during it.

  asc-certs.py list            → ids of the team's development certificates, one per line
  asc-certs.py revoke-new FILE → revoke development certificates "Created via API" not in FILE

Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_FILE (the .p8). Standard library + openssl only.
Never prints the key."""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request


def b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def raw_signature(der: bytes) -> bytes:
    """DER ECDSA signature (SEQUENCE of two INTEGERs) → r || s, 32 bytes each."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02
        n = der[i + 1]
        out += der[i + 2 : i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00")
        i += 2 + n
    return out


def token() -> str:
    head = b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
    now = int(time.time())
    body = b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
                           "aud": "appstoreconnect-v1"}).encode())
    signing = f"{head}.{body}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_FILE"]],
                         input=signing, capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64(raw_signature(der))}"


def call(method: str, path: str):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            t = r.read()
            return r.status, (json.loads(t.decode(), strict=False) if t else {})
    except urllib.error.HTTPError as e:
        return e.code, {}


def development():
    st, d = call("GET", "/v1/certificates?limit=200&filter%5BcertificateType%5D=DEVELOPMENT"
                        "&fields%5Bcertificates%5D=name,certificateType")
    if st != 200:
        sys.exit(f"listing certificates: {st}")
    return [(c["id"], c["attributes"].get("name", "")) for c in d.get("data", [])]


if __name__ == "__main__":
    if sys.argv[1] == "list":
        print("\n".join(i for i, _ in development()))
    elif sys.argv[1] == "revoke-new":
        before = set(open(sys.argv[2]).read().split())
        for cid, name in development():
            if cid not in before and "Created via API" in name:
                st, _ = call("DELETE", f"/v1/certificates/{cid}")
                print(f"revoked this run's development certificate: {st}")
