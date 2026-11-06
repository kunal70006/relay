# Relay

Send and receive files between a Mac running Relay and a phone, tablet, or computer on the same Wi-Fi. The other device only needs a web browser.

## Get Relay

[Download Relay](https://github.com/kunal70006/relay/releases/latest) for Apple silicon Macs running macOS 14 or later.

## Transfer files

1. In Relay, add files to send, choose a folder to receive into, or do both.
2. Click **Start sharing**. On the other device, scan the QR code or open the session link in a browser.
3. Choose **Download** or **Choose files** on the transfer page. Click **Stop sharing** on the Mac when done.

The IP link is the default. **Use Mac name** gives you a link that can keep working after both devices switch to a Wi-Fi network that supports Bonjour.

Keep the upload tab open for automatic retries. Uploads support up to 20 GiB per file. Transfers use unencrypted HTTP, so use trusted Wi-Fi and keep the session link private.

## Build from source

Install Xcode or the Apple command line tools, then run these commands from the repository root.

```sh
zsh build.sh "$PWD/Relay.app"
./Relay.app/Contents/MacOS/Relay --verify
open ./Relay.app
```

[MIT License](LICENSE)
