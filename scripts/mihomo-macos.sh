# Pinned inputs for the public Apple Silicon package; sourced by Bash scripts.
mihomo_version=v1.19.34
mihomo_commit=0455d0d28c4526937380505153e65a843d8612e8
mihomo_archive_sha=1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c
mihomo_binary_sha=a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34
mihomo_source_sha=db0cc4145fe4024e9c2386bd4768bf23a69c8789610d56d7243819e2f77c0cfe

check_mihomo_sha() {
  local actual
  actual="$(shasum -a 256 < "$2" | cut -d ' ' -f 1)"
  if [[ "$actual" != "$1" ]]; then
    printf 'Mihomo SHA-256 mismatch: %s\n' "${2##*/}" >&2
    return 1
  fi
}
