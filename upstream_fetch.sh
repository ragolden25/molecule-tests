#!/usr/bin/env bash
# upstream_fetch.sh - sourced by container-forge toolchain image builds (go, node22, node24)
#
# Online : detect latest upstream release, download, verify sha256, store in cache.
# Offline: (or any detect/download/verify failure) fall back to the newest cached
#          tarball that still verifies, so the daily build continues.
#
# After a successful call these are set:
#   UF_VERSION  e.g. go1.25.4 / v22.21.1
#   UF_TARBALL  full path to the verified tarball in the cache
#   UF_SOURCE   online | cache   (report "cache" to the dashboard as a warning, not a failure)
# Returns 1 only when upstream is unreachable AND nothing usable is cached.
#
# Usage:
#   source /path/to/upstream_fetch.sh
#   uf_get_go        || exit 1
#   uf_get_node 22   || exit 1
#
# Requires: curl, jq, sha256sum

UF_CACHE_ROOT="${UF_CACHE_ROOT:-/opt/container-forge/cache}"  # one subdir per toolchain
UF_KEEP="${UF_KEEP:-3}"                     # cached versions kept per toolchain
UF_TIMEOUT="${UF_TIMEOUT:-20}"              # seconds for metadata lookups
UF_GO_KIND="${UF_GO_KIND:-archive}"         # archive = linux-amd64 binary, source = go source tarball
UF_NODE_SUFFIX="${UF_NODE_SUFFIX:--linux-x64.tar.xz}"   # use ".tar.xz" for the node source tarball

uf_log() { echo "[upstream_fetch] $*" >&2; }

# download + verify + cache one file: name version url sha256
uf_download() {
    local name=$1 ver=$2 url=$3 sum=$4 file dir tmp
    file=$(basename "$url")
    dir="$UF_CACHE_ROOT/$name/$ver"
    if [[ -f "$dir/$file" ]] && echo "$sum  $dir/$file" | sha256sum -c --quiet - >/dev/null 2>&1; then
        UF_TARBALL="$dir/$file"
        uf_log "$name $ver already cached"
        return 0
    fi
    mkdir -p "$dir" || return 1
    tmp="$dir/.$file.part"
    if ! curl -fsSL --connect-timeout "$UF_TIMEOUT" --max-time 900 --retry 2 -o "$tmp" "$url"; then
        uf_log "$name: download failed: $url"
        rm -f "$tmp"; rmdir "$dir" 2>/dev/null
        return 1
    fi
    if ! echo "$sum  $tmp" | sha256sum -c --quiet - >/dev/null 2>&1; then
        uf_log "$name: checksum mismatch on $file"
        rm -f "$tmp"; rmdir "$dir" 2>/dev/null
        return 1
    fi
    mv -f "$tmp" "$dir/$file"
    echo "$sum  $file" > "$dir/$file.sha256"
    UF_TARBALL="$dir/$file"
    uf_log "$name $ver downloaded and verified"
}

# newest cached version whose tarball still verifies: name
uf_from_cache() {
    local name=$1 d s
    while read -r d; do
        [[ -n $d ]] || continue
        for s in "$d"/*.sha256; do
            [[ -f $s ]] || continue
            if (cd "$d" && sha256sum -c --quiet "$(basename "$s")" >/dev/null 2>&1); then
                UF_VERSION=$(basename "$d")
                UF_TARBALL="$d/$(basename "$s" .sha256)"
                UF_SOURCE=cache
                uf_log "$name: using cached $UF_VERSION ($UF_TARBALL)"
                return 0
            fi
        done
    done < <(find "$UF_CACHE_ROOT/$name" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -rV)
    uf_log "$name: upstream unavailable and no usable cached tarball"
    return 1
}

# keep the newest UF_KEEP versions: name
uf_prune() {
    find "$UF_CACHE_ROOT/$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort -V | head -n -"$UF_KEEP" | xargs -r rm -rf
}

uf_get_go() {
    local json ver file sum
    UF_VERSION= UF_TARBALL= UF_SOURCE=
    if json=$(curl -fsS --max-time "$UF_TIMEOUT" 'https://go.dev/dl/?mode=json' 2>/dev/null); then
        ver=$(jq -r '.[0].version // empty' <<<"$json" 2>/dev/null)
        read -r file sum < <(jq -r --arg k "$UF_GO_KIND" \
            '.[0].files[] | select(.kind==$k and (.kind=="source" or (.os=="linux" and .arch=="amd64"))) | "\(.filename) \(.sha256)"' \
            <<<"$json" 2>/dev/null | head -n1)
        if [[ -n $ver && -n $file && -n $sum ]] && uf_download go "$ver" "https://go.dev/dl/$file" "$sum"; then
            UF_VERSION=$ver UF_SOURCE=online
            uf_prune go
            return 0
        fi
    fi
    uf_log "go: upstream check failed, falling back to cache"
    uf_from_cache go
}

# uf_get_node 22 | 24  (latest release of that major line)
uf_get_node() {
    local major=$1 name="node$1" ver file sum
    UF_VERSION= UF_TARBALL= UF_SOURCE=
    ver=$(curl -fsS --max-time "$UF_TIMEOUT" https://nodejs.org/dist/index.json 2>/dev/null \
        | jq -r --arg m "v$major." '[.[] | select(.version | startswith($m))][0].version // empty' 2>/dev/null)
    if [[ $ver == v"$major".* ]]; then
        file="node-$ver$UF_NODE_SUFFIX"
        sum=$(curl -fsS --max-time "$UF_TIMEOUT" "https://nodejs.org/dist/$ver/SHASUMS256.txt" 2>/dev/null \
            | awk -v f="$file" '$2==f {print $1}')
        if [[ -n $sum ]] && uf_download "$name" "$ver" "https://nodejs.org/dist/$ver/$file" "$sum"; then
            UF_VERSION=$ver UF_SOURCE=online
            uf_prune "$name"
            return 0
        fi
    fi
    uf_log "$name: upstream check failed, falling back to cache"
    uf_from_cache "$name"
}
