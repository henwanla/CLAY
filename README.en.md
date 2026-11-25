# CLAY

[简体中文](README.md) · [Changelog](CHANGELOG.md) · [GitHub Releases](https://github.com/henwanla/CLAY/releases)

CLAY is a native macOS proxy app with subscriptions, menu bar controls, PAC routing, live traffic, and a connection inspector. The published 0.3.0 preview targets Apple Silicon and macOS 13 or later. This page also describes source features that are not in the published 0.3.0 package.

## Getting started

1. **Local preview (build 4 and later):** Open `CLAY.app`. If you have not selected another core, CLAY uses the bundled Mihomo with a pinned fingerprint. To use a different trusted core, choose it in Settings (**设置**). Verify the source and select it again after replacing or upgrading an external core.
2. **GitHub release:** Download `CLAY-0.3.0-macos-arm64.zip` and the matching `.zip.sha256`. In the download directory, run `shasum -a 256 -c CLAY-0.3.0-macos-arm64.zip.sha256` before extracting the ZIP. The public package requires you to install Mihomo separately, as shown below. The app has an ad hoc signature and has no Developer ID signature or notarization. If macOS blocks the package, you can build it from source under your usual security policy.
3. Under Subscriptions (**订阅**), select Add subscription (**添加订阅…**) and enter your provider’s HTTPS link. Under Nodes (**节点**), you can also paste share links or import UTF-8 JSON, YAML, or text files.
4. Choose a node and select Connect macOS (**连接 macOS**) from the main window or menu bar. CLAY starts the local proxy and sets up system PAC for the current primary network service or the service you choose in PAC Rules. For manual setup, use Start local proxy only (**仅启动本机代理**) and enter the HTTP/SOCKS5 address from Overview (**概览**) in the app. In the **published 0.3.0 package**, use Start (**启动**) and then Apply to macOS (**应用到 macOS**) under PAC Rules.
5. Closing the window keeps CLAY and its proxy running. In new builds, the menu bar also lets you switch nodes and routing modes. Quit CLAY or press `⌘Q` to end the session. CLAY does not launch automatically at login.

### Install Mihomo for the public package

From [Mihomo v1.19.34](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34), download `mihomo-darwin-arm64-v1.19.34.gz` from the official Assets list. Verify both the archive and the extracted executable:

```sh
(
  set -eu
  echo '1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c  mihomo-darwin-arm64-v1.19.34.gz' | shasum -a 256 -c
  mkdir -p "$HOME/.local/bin"
  clay_candidate="$(mktemp "$HOME/.local/bin/.mihomo.XXXXXX")"
  trap 'rm -f "$clay_candidate"' EXIT
  gzip -dc mihomo-darwin-arm64-v1.19.34.gz > "$clay_candidate"
  printf 'a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34  %s\n' "$clay_candidate" | shasum -a 256 -c
  chmod 755 "$clay_candidate"
  mv -f "$clay_candidate" "$HOME/.local/bin/mihomo-v1.19.34"
)
```

Stop if either hash differs. In Settings (**设置**) → Choose Mihomo (**选择 Mihomo…**), press `⌘⇧G`, enter `~/.local/bin`, and select `mihomo-v1.19.34`. Other trusted builds can be selected; the tested core is v1.19.34.

## Routing and app setup

Builds from the newer source let you choose a routing mode from Overview or the menu bar. **Rule** uses the policy loaded from PAC Rules; **Global** sends traffic that reaches the local proxy through the selected node; **Direct** connects that traffic to its destination without using a node. Switching modes leaves macOS network settings alone. Existing connections may keep their previous routes. Restart the core to apply edited rules to incoming proxy traffic; update PAC separately. Traffic that PAC sends directly never reaches the core.

| Mode | How to use it | Scope |
| --- | --- | --- |
| Manual connection | Start CLAY and manually enter its HTTP/SOCKS5 address in an app. | Only apps configured with that address; macOS settings stay as they were. |
| Local PAC | Under PAC Rules, select Start local PAC (**启动本机 PAC**), then copy its loopback URL to a PAC-capable app. | Only apps configured with that PAC URL; macOS settings stay as they were. |
| System PAC | Select Connect macOS (**连接 macOS**). You can choose the network service in PAC Rules. | Changes the selected service. Temporarily disables that service’s manual HTTP, HTTPS, and SOCKS proxies and automatic proxy discovery. |

Rules run from top to bottom. The first match wins; unmatched traffic uses your chosen Direct or Proxy default. The initial default is Proxy. Loopback is always direct. Explicit rules can override the optional local and private address bypass. Rules match exact domains or IPs, domain suffixes, domain keywords, and IPv4 CIDR ranges. CIDR applies to literal IPv4 addresses without a DNS lookup. Enter a domain, IP, or URL to see which rule matches. Paste rules one per line to append them in bulk, for example:

```text
DOMAIN,docs.example.com,DIRECT
DOMAIN-SUFFIX,example.com,PROXY
IP-CIDR,10.0.0.0/8,DIRECT
```

Rule edits are saved locally. Select Update to apply edits to a running PAC. The local PAC URL changes when you update it, so copy the new URL into manually configured apps. CLAY saves the previous proxy settings for the selected network service before applying system PAC. Use Restore original settings (**恢复原系统设置**) to turn it off; CLAY also tries to restore the previous settings when you stop or quit. macOS may request administrator authorization on apply or restore. Only clients that honor macOS proxy settings will use system PAC. After a forced exit, reopen CLAY and use Restore original network proxy settings (**恢复原网络代理设置**) if prompted. If another tool has taken over, CLAY leaves its settings in place. To apply system PAC to a different network service, restore the original service before choosing the new one.

## Dashboards, subscriptions, and diagnostics

- **Overview** shows upload and download rates, a short traffic history, session totals, and active connection count. **Connections** can filter by destination, rule, or route; sort by time or transfer size; and close one connection or all connections. Connection data is used in the current session. Traffic routed directly by PAC bypasses the core and does not count toward the totals.
- **Subscriptions** can be added, manually refreshed, selected, or removed. A failed refresh keeps the last usable list. Changes apply after restarting the proxy. New builds migrate the old JSON to an encrypted cache and keep its key in a separate private local directory. A process or backup with access to both can still read the subscriptions. Do not edit the migrated cache with an older build. Subscription downloads follow same-origin redirects; for a move to another site, use the trusted final URL. Manual imports last until you quit the app.
- **Diagnostics** can compare two rounds of node probes and copy a report without node names, server addresses, UUIDs, subscription URLs, or raw configuration. Probes send a request through the node to a 204 endpoint at gstatic.com.

**Compatibility:** VMess and VLESS share links, Base64 lists, V2Ray/Xray JSON outbounds, and inline `proxies` entries from Clash/Mihomo YAML or JSON. New builds also import Shadowsocks SIP002 links using supported AEAD ciphers, and TCP/TLS Trojan links. These two protocols can also be imported from inline Clash entries, without plugins or bypassing Trojan certificate validation. A subscription has a 2 MiB download limit and can import up to 100 compatible nodes. CLAY does not run imported providers, policy groups, rules, DNS, inbounds, or TUN settings.

## Build and verify

```sh
bash scripts/swift-local.sh build -c release
.build/release/CLAYCoreChecks
python3 scripts/smoke-subscriptions.py .build/release/CLAYCoreChecks
```

`clay-portable` validates local node files and generates PAC. On macOS and Linux it can read summary counters from a specified local Mihomo controller. The Linux development build can run a verified Mihomo binary in the foreground for manual proxy setup. It leaves system proxy settings alone and does not fetch subscription or provider URLs embedded in input. See the [platform roadmap](docs/跨平台路线.md) for usage and test coverage.

[Contributing](CONTRIBUTING.md) · [Verification record](docs/验收记录.md) · [Release process](docs/RELEASING.md) · [Security maintenance](docs/安全维护.md)

Original CLAY code uses the [MIT License](LICENSE). Yams and libyaml have [separate upstream license notices](https://github.com/henwanla/CLAY/blob/main/Vendor/Yams/UPSTREAM.md). Mihomo is a standalone GPL dependency. The local preview keeps its license and pinned upstream source reference; the public ZIP does not redistribute it.
