#!/usr/bin/env python3
"""Check a running Relay session using generated files only.

Usage: python3 verify-local.py SESSION_URL RECEIVING_FOLDER STREAMING_TEST_FILE
Start a session with a generated 32 MB file and a disposable receiving folder.
Pass the absolute paths to the receiving folder and shared file.
"""
import hashlib
import json
import pathlib
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base = sys.argv[1].rstrip("/")
destination = pathlib.Path(sys.argv[2])
source = pathlib.Path(sys.argv[3])
parsed = urllib.parse.urlsplit(base)
origin = f"{parsed.scheme}://{parsed.netloc}"
client = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path, data=None, headers=None, method=None):
    req = urllib.request.Request(base + path, data=data, headers=headers or {}, method=method)
    try:
        with client.open(req, timeout=20) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def passed(condition, message):
    if not condition:
        raise AssertionError(message)
    print("PASS:", message, flush=True)


code, headers, page = request("/")
passed(code == 200 and b"Relay" in page, "The real session serves the browser transfer page")
code, _, data = request("/api")
manifest = json.loads(data)
passed(code == 200 and manifest["canUpload"], "The selected receiving folder enables uploads")
large = next(file for file in manifest["files"] if file["name"] == source.name)
file_route = "/files/" + large["id"]
expected = source.read_bytes()
code, headers, downloaded = request(file_route)
passed(code == 200 and hashlib.sha256(downloaded).digest() == hashlib.sha256(expected).digest(), "A 32 MB streamed download matches the original bytes")
passed("attachment" in headers["Content-Disposition"], "Downloads request browser file saving")
code, headers, body = request(file_route, method="HEAD")
passed(code == 200 and not body and int(headers["Content-Length"]) == len(expected), "HEAD reports the correct file size")
code, headers, chunk = request(file_route, headers={"Range": "bytes=100-999"})
passed(code == 206 and chunk == expected[100:1000], "Partial downloads return exactly the requested bytes")
code, _, chunk = request(file_route, headers={"Range": "bytes=-321"})
passed(code == 206 and chunk == expected[-321:], "Suffix ranges return the correct bytes")
passed(request(file_route, headers={"Range": "bytes=999999999999-"})[0] == 416, "Invalid ranges are rejected")
passed(request("/files/not-shared")[0] == 404, "Unselected files cannot be downloaded")
bad_base = base.replace(parsed.path, "/s/not-a-valid-session")
try:
    client.open(bad_base + "/api", timeout=5)
    raise AssertionError("A wrong token must fail")
except urllib.error.HTTPError as error:
    passed(error.code == 404, "A wrong session token is rejected")

upload_headers = {"Origin": origin, "X-Relay-Upload": "1", "Content-Type": "application/octet-stream"}
filename = "upload-verification-✓.txt"
route = "/upload?name=" + urllib.parse.quote(filename)
payload = b"Generated upload verification\n"
code, _, result = request(route, data=payload, headers=upload_headers)
saved = json.loads(result)["savedAs"]
passed(code == 200 and (destination / saved).read_bytes() == payload, "Uploads save exact bytes to the chosen folder")
code, _, result = request(route, data=b"second copy", headers=upload_headers)
second = json.loads(result)["savedAs"]
passed(code == 200 and saved != second and (destination / saved).read_bytes() == payload, "Duplicate filenames preserve the existing file")
passed(request(route, data=b"no", headers={"X-Relay-Upload": "1"})[0] == 403, "Uploads from an unexpected origin are rejected")
passed(request(route, data=b"no", headers={"Origin": origin})[0] == 403, "Uploads require the session page's custom header")
passed(request("/upload?name=..%2Foutside.txt", data=b"no", headers=upload_headers)[0] == 400, "Upload path traversal is rejected")
passed(request("/upload?name=.hidden", data=b"no", headers=upload_headers)[0] == 400, "Hidden upload filenames are rejected")
passed(request(route, data=b"", headers=upload_headers)[0] == 200, "Empty files can be uploaded")

before = set(destination.glob(".relay-*.part"))
with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as connection:
    header = f"POST {parsed.path}/upload?name=interrupted.txt HTTP/1.1\r\nHost: {parsed.netloc}\r\nOrigin: {origin}\r\nX-Relay-Upload: 1\r\nContent-Length: 1000000\r\n\r\n"
    connection.sendall(header.encode() + b"unfinished")
time.sleep(0.3)
passed(set(destination.glob(".relay-*.part")) == before and not (destination / "interrupted.txt").exists(), "Interrupted uploads leave no partial files")
print("Local HTTP verification complete. Use another device on the same Wi-Fi to test connectivity.")
