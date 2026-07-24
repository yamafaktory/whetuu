#!/bin/sh
#
# whetū installer. Detects your platform, downloads the matching release from
# GitHub, verifies it against the published SHA256SUMS, and installs the binary.
#
#   curl --proto '=https' --tlsv1.2 -fsSL https://yamafaktory.github.io/whetuu/install.sh | sh
#
# Environment:
#   WHETUU_NO_MODIFY     set to 1 to skip editing the shell config. The script
#                        then prints the lines and leaves them to you.
#   WHETUU_INSTALL_DIR   where to put the binary (default: see pick_dir below).
#                        Through a pipe, set it on the shell, not on curl:
#                        curl -fsSL <url> | WHETUU_INSTALL_DIR=/opt/bin sh
#   WHETUU_VERSION       install a specific tag, e.g. v0.1.3 (default: latest)
#
# It appends the init line to the config of the shell in $SHELL, guarded so
# running it twice changes nothing. A PATH line joins it only when the install
# directory is not already on PATH. Set WHETUU_NO_MODIFY=1 to have it print them
# instead. It touches no other file and never the config of a shell you do not
# use.

set -eu

repo=yamafaktory/whetuu
tmp=
default_dir="$HOME/.local/bin"

die() {
    printf 'whetuu: %s\n' "$1" >&2
    exit 1
}

say() {
    printf 'whetuu: %s\n' "$1"
}

cleanup() {
    [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not on PATH"
}

# Downloads $1 to $2 using whichever fetcher is present.
fetch() {
    if command -v curl >/dev/null 2>&1; then
        # --proto '=https' and --tlsv1.2 stop a redirect from downgrading the
        # transport. This fetches a binary you are about to run.
        curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2" || die "could not download $1"
    else
        wget -qO "$2" "$1" || die "could not download $1"
    fi
}

# The release target triple for this machine, or empty when unsupported.
detect_target() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Linux) suffix=linux-musl ;;
        Darwin) suffix=macos ;;
        *) return 1 ;;
    esac
    case "$arch" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64) cpu=aarch64 ;;
        *) return 1 ;;
    esac

    printf '%s-%s' "$cpu" "$suffix"
}

# The XDG Base Directory spec names $HOME/.local/bin for user-specific
# executables, and most systems already have it on PATH. That usually leaves the
# shell config one line shorter than a directory of our own would.
#
# Never /usr/local/bin. That needs sudo, and sudo cannot prompt for a password
# when this script arrives through a pipe: stdin is the script itself. An
# install that asks for a password it cannot read is worse than one that puts
# the binary somewhere you own.
pick_dir() {
    if [ -n "${WHETUU_INSTALL_DIR:-}" ]; then
        printf '%s' "$WHETUU_INSTALL_DIR"
        return
    fi

    printf '%s' "$default_dir"
}

# Whether $1 is already an entry in PATH, so the config never gains a line that
# repeats what the system does for you.
on_path() {
    case ":${PATH:-}:" in
        *":$1:"*) return 0 ;;
        *) return 1 ;;
    esac
}

command -v curl >/dev/null 2>&1 || need wget
need tar
need uname

target=$(detect_target) || die "unsupported platform: $(uname -s) $(uname -m). Prebuilt binaries cover Linux and macOS on x86_64 and aarch64."

version=${WHETUU_VERSION:-}
if [ -z "$version" ]; then
    need sed
    tmp_tag=$(
        if command -v curl >/dev/null 2>&1; then
            curl --proto '=https' --tlsv1.2 -fsSL "https://api.github.com/repos/$repo/releases/latest"
        else
            wget -qO- "https://api.github.com/repos/$repo/releases/latest"
        fi
    ) || die "could not reach the GitHub API to find the latest release"
    version=$(printf '%s' "$tmp_tag" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$version" ] || die "could not parse the latest release tag"
fi

tarball="whetuu-$version-$target.tar.gz"
base="https://github.com/$repo/releases/download/$version"

tmp=$(mktemp -d)
say "downloading $tarball"
fetch "$base/$tarball" "$tmp/$tarball"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"

# Verify before unpacking, so a bad download never reaches your disk as a
# binary. Both tools print "<sum>  <name>", which is what SHA256SUMS holds.
say "verifying checksum"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$tmp/$tarball" | cut -d' ' -f1)
else
    die "need sha256sum or shasum to verify the download"
fi
# SHA256SUMS lists names as "./whetuu-...", so compare the basename exactly
# rather than pattern matching a filename full of dots.
expected=$(awk -v want="$tarball" '{ name = $2; sub(/^\.\//, "", name); if (name == want) print $1 }' "$tmp/SHA256SUMS")
[ -n "$expected" ] || die "$tarball is not listed in SHA256SUMS"
[ "$actual" = "$expected" ] || die "checksum mismatch for $tarball. Refusing to install."

tar -xzf "$tmp/$tarball" -C "$tmp" || die "could not unpack $tarball"
[ -f "$tmp/whetuu" ] || die "the archive did not contain a whetuu binary"
chmod +x "$tmp/whetuu"

dir=$(pick_dir)
mkdir -p "$dir" 2>/dev/null || die "could not create $dir. Set WHETUU_INSTALL_DIR to a directory you can write to."
[ -w "$dir" ] || die "$dir is not writable. Set WHETUU_INSTALL_DIR to a directory you can write to, for example: curl -fsSL <url> | WHETUU_INSTALL_DIR=\"\$HOME/bin\" sh"
mv "$tmp/whetuu" "$dir/whetuu"

say "installed $version to $dir/whetuu"

# Versions up to 0.1.5 installed to ~/.whetuu/bin and put that on PATH ahead of
# everything. Left alone it keeps winning, and the upgrade looks like it did
# nothing. Say so rather than delete a directory we no longer own.
if [ -e "$HOME/.whetuu" ]; then
    say "note: an older install is still in $HOME/.whetuu, and the PATH line in"
    say "      your shell config makes it win. Remove the directory and that"
    say "      line, then open a new shell."
fi

# The shell in $SHELL is the login shell, so it owns the config file worth
# editing. A shell we do not recognise gets instructions and no edits.
case "${SHELL:-}" in
    */fish) user_shell=fish ; rc="$HOME/.config/fish/config.fish" ;;
    */zsh) user_shell=zsh ; rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    */bash) user_shell=bash ; rc="$HOME/.bashrc" ;;
    *) user_shell= ; rc= ;;
esac

# Written into the config verbatim, so it names the directory the binary really
# went to rather than the default.
lines_for() {
    printf '\n# whetuu\n'
    if [ "$needs_path" = yes ]; then
        case "$1" in
            fish) printf 'fish_add_path "%s"\n' "$path_literal" ;;
            *) printf 'export PATH="%s:$PATH"\n' "$path_literal" ;;
        esac
    fi
    case "$1" in
        fish) printf 'whetuu init fish | source\n' ;;
        zsh) printf 'eval "$(whetuu init zsh)"\n' ;;
        bash) printf 'eval "$(whetuu init bash)"\n' ;;
    esac
}

if on_path "$dir"; then
    needs_path=no
else
    needs_path=yes
fi

# At the default the config gets $HOME unexpanded, so it keeps working if the
# account moves. A directory you named is written out as you gave it.
if [ "$dir" = "$default_dir" ]; then
    path_literal='$HOME/.local/bin'
else
    path_literal=$dir
fi

configured=no
if [ -n "$user_shell" ] && [ "${WHETUU_NO_MODIFY:-}" != 1 ]; then
    # A custom install dir is not what the lines above assume, so leave the
    # config alone rather than write a path that is wrong.
    if [ "$dir" != "$default_dir" ]; then
        say "custom install directory, so your shell config is left alone"
    elif [ -f "$rc" ] && grep -q 'whetuu init' "$rc" 2>/dev/null; then
        say "$rc already sets up whetuu, leaving it alone"
        configured=yes
    else
        mkdir -p "$(dirname "$rc")" 2>/dev/null || true
        if lines_for "$user_shell" >> "$rc" 2>/dev/null; then
            say "added whetuu to $rc"
            configured=yes
        else
            say "could not write $rc, so here are the lines to add yourself"
        fi
    fi
fi

printf '\n'
if [ "$configured" = yes ]; then
    printf 'Open a new shell and you are done.\n'
else
    if [ -n "$user_shell" ]; then
        printf 'Add this to %s, then open a new shell:\n' "$rc"
        printf '%s' "$(lines_for "$user_shell")"
        printf '\n'
    else
        printf 'Add one line to your shell config, then open a new shell:\n\n'
        printf '  fish   ~/.config/fish/config.fish    whetuu init fish | source\n'
        printf '  bash   ~/.bashrc                     eval "$(whetuu init bash)"\n'
        printf '  zsh    ~/.zshrc                      eval "$(whetuu init zsh)"\n'
        printf '\nPut %s on your PATH too.\n' "$dir"
    fi
fi

printf '\nThe prompt needs a Nerd Font: https://www.nerdfonts.com\n'
