# Relay

Relay sends files between an Apple silicon Mac and an iPhone on the same Wi-Fi. Open the transfer page in Safari on your iPhone.

## Build and run

On macOS 14 or later, install Xcode or the Apple command line tools. From the repository root, run:

```sh
zsh build.sh "$PWD/Relay.app"
open ./Relay.app
```

## Transfer files

1. Drag in files or click **Choose files…** to send. To receive, click **Choose folder…** and pick where uploads should go. You can set up either direction or both.
2. Click **Start sharing**. Scan the QR code with the iPhone camera or copy the session link and open it in Safari.
3. Tap **Download** to save a shared file, or **Choose files** to send a file to the Mac.
4. Click **Stop sharing** when finished. Start a new session to change the files or receiving folder.

Relay streams downloads in 256 KiB buffers and receives uploads in 64 KiB buffers. The browser sends one slice of up to 8 MiB at a time. Uploads are capped at 20 GiB per file and require free space on the Mac. Duplicate filenames get numbered copies.

Keep Relay and the iPhone upload tab open. Uploads retry temporary connection failures and continue from the last completed slice. Use **Retry upload** if automatic retries stop. Relay keeps incomplete uploads for 30 minutes of inactivity, then clears them. Stopping the session clears pending uploads. Completed files stay in the selected folder. For downloads, check Safari's Downloads for resume or retry. Re-select any shared file that changed on the Mac.

New sessions show the IP address in the link and QR code. If both devices move to another Wi-Fi network, scan the updated QR code once the Mac gets its new IP address. **Use Mac name** gives you a link that can keep working across Wi-Fi changes on networks that support Bonjour. Use a trusted Wi-Fi network and keep the session link private. Transfers use unencrypted HTTP.

## Verify

Run the built app's local checks from the repository root:

```sh
./Relay.app/Contents/MacOS/Relay --verify
```

For HTTP integration checks, share a generated 32 MB file named `streaming-test.bin` and choose a disposable receiving folder. Run with Python 3, supplying the session link and the two absolute paths:

```sh
python3 verify-local.py SESSION_URL DISPOSABLE_RECEIVING_FOLDER STREAMING_TEST_FILE
```

The integration check writes generated files to the selected folder and checks download bytes, byte ranges, uploads, and session access. The bundle uses ad hoc signing for local testing.

## License

Relay is available under the [MIT License](LICENSE).
