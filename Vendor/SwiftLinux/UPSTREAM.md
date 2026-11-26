# Swift notices for the Linux preview

Swift notice text is copied from the official Swift repositories at `swift-6.4.3-RELEASE`. The Linux preview statically links the Swift runtime; these are licensing materials, not vendored runtime binaries. Update the notices and this record together when changing the toolchain. Checksums refer to the included files. Trailing spaces were removed from the Corelibs Foundation and Dispatch notices.

| Included notice | Original file | SHA-256 |
| --- | --- | --- |
| swift.txt | [Source](https://raw.githubusercontent.com/swiftlang/swift/swift-6.4.3-RELEASE/LICENSE.txt) | 770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55 |
| swift-foundation.md | [Source](https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.4.3-RELEASE/LICENSE.md) | 2245a990b635558be210fb3eb4f8a6f7a49aebc0fefbf5859146a65ddc7ddcf3 |
| swift-foundation-NOTICE.txt | [Source](https://raw.githubusercontent.com/swiftlang/swift-foundation/swift-6.4.3-RELEASE/NOTICE.txt) | c2e757911b86a76230099804831d8d847a865e88b5912171627492a7a49f0456 |
| swift-corelibs-foundation.txt | [Source](https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.4.3-RELEASE/LICENSE) | 167beb36f181bd163c93c6feb45c68e5f9462fe1af55b278f7bfd1df20e673a3 |
| swift-corelibs-libdispatch.txt | [Source](https://raw.githubusercontent.com/swiftlang/swift-corelibs-libdispatch/swift-6.4.3-RELEASE/LICENSE) | 167beb36f181bd163c93c6feb45c68e5f9462fe1af55b278f7bfd1df20e673a3 |
| swift-foundation-icu.md | [Source](https://raw.githubusercontent.com/swiftlang/swift-foundation-icu/swift-6.4.3-RELEASE/LICENSE.md) | 2245a990b635558be210fb3eb4f8a6f7a49aebc0fefbf5859146a65ddc7ddcf3 |
| icu-76.1.txt | [ICU 76.1 source](https://raw.githubusercontent.com/unicode-org/icu/release-76-1/LICENSE) | 01edac20612b1e590c1c1cfb02b7218c6adc7b0a944eda7a1e03aeee10725aed |

ICU is 76.1 in the [embedded version header](https://raw.githubusercontent.com/swiftlang/swift-foundation-icu/swift-6.4.3-RELEASE/icuSources/include/_foundation_unicode/uvernum.h). Its Unicode notice above accompanies the Swift Foundation ICU notice.
