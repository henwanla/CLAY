# CLAY

[简体中文](README.md) · [Changelog](CHANGELOG.md) · [GitHub Releases](https://github.com/henwanla/CLAY/releases)

CLAY is a native macOS proxy app for VMess and VLESS. It brings subscriptions, menu bar controls, PAC routing, a live traffic chart, and a connection inspector into one app. Version 0.3.0 is a preview. The downloadable app is for Apple Silicon and targets macOS 13 or later.

## Getting started

1. **Local preview:** Open `CLAY.app`. It can find `Dependencies/mihomo` beside the app. If you move the app on its own, use Settings to pick the core again.
2. **GitHub release:** Download `CLAY-0.3.0-macos-arm64.zip` and the matching `.zip.sha256`. In the download directory, run `shasum -a 256 -c CLAY-0.3.0-macos-arm64.zip.sha256` before extracting the ZIP. The public package requires you to install Mihomo separately, as shown below. The app has an ad hoc signature and has no Developer ID signature or notarization. If macOS blocks the package, you can build it from source under your usual security policy.
3. Under Subscriptions (**订阅**), select Add subscription (**添加订阅…**) and enter your provider’s HTTPS link. Under Nodes (**节点**), you can also paste share links or import UTF-8 JSON, YAML, or text files.
4. Choose a node and select Start (**启动**). Overview (**概览**) shows a local address that accepts HTTP and SOCKS5. Use PAC Rules (**PAC 规则**) when you want traffic to follow routing rules.
5. Closing the window keeps CLAY and its proxy running. The menu bar shows status and lets you copy an address, reopen the window, or start and stop the proxy. Quit CLAY or press `⌘Q` to end the session. CLAY does not launch automatically at login.

### Install Mihomo for the public package

From [Mihomo v1.19.34](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34), download `mihomo-darwin-arm64-v1.19.34.gz` from the official Assets list. Verify both the archive and the extracted executable:

```sh
shasum -a 256 mihomo-darwin-arm64-v1.19.34.gz
# Expected: 1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c
mkdir -p "$HOME/.local/bin"
gzip -dc mihomo-darwin-arm64-v1.19.34.gz > "$HOME/.local/bin/mihomo-v1.19.34"
shasum -a 256 "$HOME/.local/bin/mihomo-v1.19.34"
# Expected: a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34
chmod 755 "$HOME/.local/bin/mihomo-v1.19.34"
```

Stop if either hash differs. In Settings (**设置**) → Choose Mihomo (**选择 Mihomo…**), press `⌘⇧G`, enter `~/.local/bin`, and select `mihomo-v1.19.34`. Other trusted builds can be selected; the tested core is v1.19.34.

## PAC routing

| Mode | How to use it | Scope |
| --- | --- | --- |
| Standalone proxy | Start CLAY and manually enter its HTTP/SOCKS5 address in an app. | Only apps configured with that address; macOS settings stay as they were. |
| Local PAC | Under PAC Rules, select Start local PAC (**启动本机 PAC**), then copy its loopback URL to a PAC-capable app. | Only apps configured with that PAC URL; macOS settings stay as they were. |
| System PAC | Pick a network service in PAC Rules and select Apply to macOS (**应用到 macOS**). | Changes the selected service. Temporarily disables that service’s manual HTTP, HTTPS, and SOCKS proxies and automatic proxy discovery. |

Rules run from top to bottom. The first match wins; unmatched traffic uses your chosen Direct or Proxy default. The initial default is Proxy. Loopback is always direct. Explicit rules can override the optional local and private address bypass. Rules match exact domains or IPs, domain suffixes, domain keywords, and IPv4 CIDR ranges. CIDR applies to literal IPv4 addresses without a DNS lookup. Enter a domain, IP, or URL to see which rule matches. Paste rules one per line to append them in bulk, for example:

```text
DOMAIN,docs.example.com,DIRECT
DOMAIN-SUFFIX,example.com,PROXY
IP-CIDR,10.0.0.0/8,DIRECT
```

Rule edits are saved locally. Select Update to apply edits to a running PAC. The local PAC URL changes when you update it, so copy the new URL into manually configured apps. CLAY saves the previous proxy settings for the selected network service before applying system PAC. Use Restore original settings (**恢复原系统设置**) to turn it off; CLAY also tries to restore the previous settings when you stop or quit. macOS may request administrator authorization on apply or restore. Only clients that honor macOS proxy settings will use system PAC. After a forced exit, reopen CLAY and use Restore original network proxy settings (**恢复原网络代理设置**) if prompted. If another tool has taken over, CLAY leaves its settings in place. To apply system PAC to a different network service, restore the original service before choosing the new one.

## Dashboards, subscriptions, and diagnostics

- **Overview** shows upload and download rates, a short traffic history, session totals, and active connection count. **Connections** can filter by destination, rule, or route; sort by time or transfer size; and close one connection or all connections. Connection data is used in the current session. Traffic routed directly by PAC bypasses the core and does not count toward the totals.
- **Subscriptions** can be added, manually refreshed, selected, or removed. A failed refresh keeps the last usable list. Changes to subscriptions apply after restarting the proxy, keeping the running session on its original list. Subscription URLs and cached responses are stored under `~/Library/Application Support/CLAY/Subscriptions/` and may contain credentials. Manual imports last until you quit the app.
- **Diagnostics** can compare two rounds of node probes and copy a report without node names, server addresses, UUIDs, subscription URLs, or raw configuration. Probes send a request through the node to a 204 endpoint at gstatic.com.

**Compatibility:** VMess and VLESS share links, Base64 lists of share links, V2Ray/Xray JSON outbounds, and inline `proxies` entries from Clash/Mihomo YAML or JSON. A subscription has a 2 MiB download limit and can import up to 100 compatible nodes. Plain HTTP is accepted for loopback fixtures. Supported transports include TCP/RAW, WebSocket, and gRPC, with common TLS and SNI options and VLESS REALITY/Vision. CLAY extracts compatible nodes. It does not run imported provider URLs, policy groups, rules, DNS, inbounds, or TUN settings. CLAY's PAC rules are independent of source files. Full Clash profile execution, TUN, XHTTP, and complex proxy chains are outside this release.

## Build and verify

```sh
bash scripts/swift-local.sh build -c release
.build/release/CLAYCoreChecks
python3 scripts/smoke-subscriptions.py .build/release/CLAYCoreChecks
```

[Contributing](https://github.com/henwanla/CLAY/blob/main/CONTRIBUTING.md) · [Verification record](https://github.com/henwanla/CLAY/blob/main/docs/验收记录.md) · [Release process](https://github.com/henwanla/CLAY/blob/main/docs/RELEASING.md)

Original CLAY code uses the [MIT License](LICENSE). Yams and libyaml have [separate upstream license notices](https://github.com/henwanla/CLAY/blob/main/Vendor/Yams/UPSTREAM.md). Mihomo is a standalone GPL dependency. The local preview keeps its license and pinned upstream source reference; the public ZIP does not redistribute it.
