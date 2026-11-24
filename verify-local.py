#!/usr/bin/env python3
"""Check a running Relay session using generated files only.

Usage: python3 verify-local.py SESSION_URL RECEIVING_FOLDER STREAMING_TEST_FILE [SHARED_FOLDER]
Start a session with a generated 32 MB file and a disposable receiving folder.
Pass the absolute paths to the receiving folder and shared file. To check
folder sharing, also share a generated folder and pass its absolute path.
"""
import hashlib
import io
import json
import pathlib
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

base = sys.argv[1].rstrip("/")
destination = pathlib.Path(sys.argv[2])
source = pathlib.Path(sys.argv[3])
shared_folder = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else None
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

if shared_folder:
    entry = next(file for file in manifest["files"] if file.get("folder") and file["name"] == shared_folder.name + ".zip")
    folder_route = "/files/" + entry["id"]
    code, headers, archive = request(folder_route)
    passed(code == 200 and len(archive) == entry["size"] == int(headers["Content-Length"]), "A shared folder downloads at its advertised ZIP size")
    passed(headers["Content-Type"] == "application/zip" and ".zip" in headers["Content-Disposition"], "Folder downloads are saved as .zip files")
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        passed(bundle.testzip() is None, "The folder ZIP passes CRC checks")
        on_disk = {
            str(path.relative_to(shared_folder.parent)): path.read_bytes()
            for path in shared_folder.rglob("*")
            if path.is_file() and not path.is_symlink()
            and not any(part.startswith(".") for part in path.relative_to(shared_folder).parts)
        }
        in_zip = {info.filename: bundle.read(info) for info in bundle.infolist() if not info.is_dir()}
        passed(in_zip == on_disk and entry["items"] == len(on_disk), "The folder ZIP holds every visible file with its exact bytes")
    code, headers, body = request(folder_route, method="HEAD")
    passed(code == 200 and not body and int(headers["Content-Length"]) == entry["size"], "HEAD reports the folder ZIP size")
    code, _, whole = request(folder_route, headers={"Range": "bytes=100-"})
    passed(code == 200 and whole == archive, "Folder downloads ignore ranges and resend the whole ZIP")
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


def folder_upload(directory, name, data, batch):
    query = urllib.parse.urlencode({"name": name, "dir": directory, "batch": batch}, quote_via=urllib.parse.quote)
    return request("/upload?" + query, data=data, headers=upload_headers)


folder_name = f"Folder upload ✓ {uuid.uuid4().hex[:8]}"
first_batch = str(uuid.uuid4())
code, _, result = folder_upload(f"{folder_name}/nested/deeper", "photo.bin", b"first", first_batch)
saved = json.loads(result)["savedAs"]
passed(code == 200 and saved == f"{folder_name}/nested/deeper/photo.bin" and (destination / saved).read_bytes() == b"first",
       "Folder uploads recreate their subfolders in the chosen folder")
code, _, result = folder_upload(folder_name, "top.txt", b"top", first_batch)
passed(code == 200 and json.loads(result)["savedAs"] == f"{folder_name}/top.txt", "Files from one folder upload stay together")
code, _, result = folder_upload(f"{folder_name}/nested", "photo.bin", b"second", str(uuid.uuid4()))
second = json.loads(result)["savedAs"]
passed(code == 200 and second == f"{folder_name} (1)/nested/photo.bin" and (destination / saved).read_bytes() == b"first",
       "A second upload of the same folder gets its own folder")
for bad in ["../outside", "a/../../outside", "a//b", ".hidden", "a/.git", "/absolute", "a\\b"]:
    passed(folder_upload(bad, "x.txt", b"no", str(uuid.uuid4()))[0] == 400, f"Unsafe folder path {bad!r} is rejected")
passed(request("/upload?" + urllib.parse.urlencode({"name": "x.txt", "dir": "NoBatch"}), data=b"no", headers=upload_headers)[0] == 400,
       "Folder uploads require a batch ID")
passed(not (destination.parent / "outside").exists() and not (destination / "NoBatch").exists(), "Rejected folder uploads create nothing")

before = set(destination.glob(".relay-*.part"))
with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as connection:
    header = f"POST {parsed.path}/upload?name=interrupted.txt HTTP/1.1\r\nHost: {parsed.netloc}\r\nOrigin: {origin}\r\nX-Relay-Upload: 1\r\nContent-Length: 1000000\r\n\r\n"
    connection.sendall(header.encode() + b"unfinished")
time.sleep(0.3)
passed(set(destination.glob(".relay-*.part")) == before and not (destination / "interrupted.txt").exists(), "Interrupted uploads leave no partial files")

upload_id = str(uuid.uuid4())
resume_payload = hashlib.shake_256(b"Relay resumable upload").digest(10 * 1024 * 1024 + 7)
break_at = 127_003
status_route = f"/upload?id={upload_id}"
resume_route = f"{status_route}&name=resume-verification.bin&total={len(resume_payload)}"
with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as connection:
    header = (
        f"POST {parsed.path}{resume_route}&offset=0 HTTP/1.1\r\n"
        f"Host: {parsed.netloc}\r\nOrigin: {origin}\r\nX-Relay-Upload: 1\r\n"
        f"Content-Length: {len(resume_payload)}\r\n\r\n"
    )
    connection.sendall(header.encode() + resume_payload[:break_at])

deadline = time.monotonic() + 5
while True:
    code, _, data = request(status_route, headers={"X-Relay-Upload": "1"})
    state = json.loads(data)
    if code == 200 and state.get("offset") == break_at and not state.get("busy"):
        break
    if time.monotonic() >= deadline:
        raise AssertionError("Relay did not preserve the written bytes after disconnecting")
    time.sleep(0.05)

code, _, data = request(resume_route + f"&offset={break_at}", data=resume_payload[break_at:], headers=upload_headers)
state = json.loads(data)
passed(
    code == 200 and state["offset"] == len(resume_payload) and (destination / state["savedAs"]).read_bytes() == resume_payload,
    "A request larger than 8 MiB resumes at the exact saved byte and writes the original contents",
)
print("Local HTTP verification complete. Use another device on the same Wi-Fi to test connectivity.")
