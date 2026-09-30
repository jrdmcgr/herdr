#!/usr/bin/env bash
# install.sh — build Herdr.app from this checkout's own herdr source, wrapped
# in a pinned/verified copy of the official Ghostty.app, and activate it at
# ~/Applications/Herdr.app.
#
# Unlike a normal app install, this always *builds* rather than downloads:
# the herdr binary it ships is compiled from whatever is checked out here
# (README: check out/merge the branches you want first), so the result is
# reproducible on any machine that clones this repo and has the toolchain —
# not tied to a symlink back into this checkout.
#
# The wrapping Ghostty is pinned by version + sha256 + minisig signature and
# checked against an already-installed, officially-signed /Applications/
# Ghostty.app before anything is touched. The prior release remains available
# for rollback.
#
# usage:
#   ./install.sh              build + activate
#   ./install.sh --rollback [RELEASE_ID]
#   ./install.sh --verify
set -euo pipefail

ghostty_version='1.3.0'
ghostty_sha256='f074cb4edf5bb27275d8e05741cfc739271e27fffd97a4fa069a7fdcb0e6f648'
ghostty_minisign_key='RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV'
ghostty_bundle_id='com.mitchellh.ghostty'
ghostty_team_id='24VZTF6M5V'
herdr_bundle_id="${HERDR_MACOS_BUNDLE_ID:-dev.jrdmcgr.herdr}"
app_name='Herdr.app'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
definition_dir="$repo_root/macos/app"
applications_dir="${HOME}/Applications"
state_dir="${HOME}/Library/Application Support/Herdr/installer"
cache_root="${HOME}/Library/Caches/herdr-macos/ghostty-${ghostty_version}"
mode='build'
launch_after=true
rollback_id=''

usage() {
	printf '%s\n' \
		'Usage:' \
		'  ./install.sh [options]' \
		'  ./install.sh --rollback [RELEASE_ID] [options]' \
		'  ./install.sh --verify [options]' \
		'' \
		'Options:' \
		'  --rollback [ID]         Activate the prior or named release' \
		'  --verify                Verify the active application' \
		'  --applications-dir DIR  Canonical app directory (default: ~/Applications)' \
		'  --state-dir DIR         Versioned release state directory' \
		'  --no-launch             Activate without launching' \
		'  -h, --help              Show this help'
}

while (($#)); do
	case "$1" in
	--rollback)
		mode='rollback'
		if (($# > 1)) && [[ "${2}" != --* ]]; then
			shift
			rollback_id="$1"
		fi
		;;
	--verify) mode='verify' ;;
	--applications-dir)
		shift
		applications_dir="${1:?--applications-dir requires a path}"
		;;
	--state-dir)
		shift
		state_dir="${1:?--state-dir requires a path}"
		;;
	--no-launch) launch_after=false ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'Unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

[[ "$(uname -s)" == Darwin ]] || {
	printf 'Herdr.app can only be built and installed on macOS.\n' >&2
	exit 1
}
for tool in codesign ditto cargo git; do
	command -v "$tool" >/dev/null || {
		printf '%s is required.\n' "$tool" >&2
		exit 1
	}
done

release_root="$state_dir/releases"
current_link="$state_dir/current"
previous_link="$state_dir/previous"
activation_log="$state_dir/activations.tsv"
ghostty_xdg_root="$state_dir/xdg"
ghostty_config="$ghostty_xdg_root/ghostty/config"
canonical_app="$applications_dir/$app_name"
lock_dir="$state_dir/.install-lock"
mkdir -p "$applications_dir" "$release_root"
if ! mkdir "$lock_dir" 2>/dev/null; then
	printf 'Another Herdr install or rollback is already running.\n' >&2
	exit 1
fi

stage_dir=''
next_app=''
prior_app=''
config_next=''
cleanup() {
	[[ -z "$stage_dir" ]] || rm -rf "$stage_dir"
	[[ -z "$next_app" ]] || rm -rf "$next_app"
	[[ -z "$prior_app" ]] || rm -rf "$prior_app"
	[[ -z "$config_next" ]] || rm -f "$config_next"
	rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

herdr_bin_path() { printf '%s/Contents/Resources/herdr\n' "$canonical_app"; }

verify_app() {
	local app="$1" herdr_bin
	herdr_bin="$(herdr_bin_path)"
	[[ -d "$app" ]] || {
		printf 'Herdr app bundle is missing: %s\n' "$app" >&2
		return 1
	}
	[[ -x "$app/Contents/MacOS/ghostty" ]] || {
		printf 'Herdr terminal executable is missing: %s\n' "$app/Contents/MacOS/ghostty" >&2
		return 1
	}
	[[ -x "$app/Contents/Resources/herdr" ]] || {
		printf 'Bundled herdr binary is missing: %s\n' "$app/Contents/Resources/herdr" >&2
		return 1
	}
	[[ -f "$app/Contents/Resources/herdr.ghostty" ]] || {
		printf 'Herdr terminal configuration is missing.\n' >&2
		return 1
	}
	if grep -Eq '^[[:space:]]*config-default-files[[:space:]]*=' "$app/Contents/Resources/herdr.ghostty"; then
		printf 'Herdr terminal configuration must rely on its isolated XDG root.\n' >&2
		return 1
	fi
	grep -Fq "$herdr_bin" "$app/Contents/Resources/herdr.ghostty" || {
		printf 'Herdr terminal configuration does not point at the bundled herdr binary.\n' >&2
		return 1
	}
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$herdr_bundle_id" ]] || {
		printf 'Unexpected Herdr bundle identifier.\n' >&2
		return 1
	}
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == ghostty ]] || {
		printf 'Herdr must preserve Ghostty as its native bundle executable.\n' >&2
		return 1
	}
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:XDG_CONFIG_HOME' "$app/Contents/Info.plist")" == "$ghostty_xdg_root" ]] || {
		printf 'Herdr does not point at its isolated terminal configuration root.\n' >&2
		return 1
	}
	codesign --verify --deep --strict "$app"
}

resolve_link() {
	local link="$1" target
	[[ -L "$link" ]] || return 1
	target="$(readlink "$link")"
	if [[ "$target" == /* ]]; then
		printf '%s\n' "$target"
	else
		printf '%s/%s\n' "$(cd "$(dirname "$link")" && pwd -P)" "$target"
	fi
}

managed_release_app() {
	local app="$1"
	[[ "$app" == "$release_root"/*"/$app_name" ]]
}

active_release() {
	local active=''
	if [[ -L "$canonical_app" ]]; then
		active="$(resolve_link "$canonical_app")"
	elif [[ -d "$canonical_app" && -L "$current_link" ]]; then
		active="$(resolve_link "$current_link")"
	else
		return 1
	fi
	managed_release_app "$active" || return 1
	printf '%s\n' "$active"
}

prune_releases() {
	local current_release="$1" retained_release=''
	if [[ -L "$previous_link" ]]; then
		retained_release="$(dirname "$(resolve_link "$previous_link")")"
	fi
	local candidate
	for candidate in "$release_root"/*; do
		[[ -d "$candidate" && ! -L "$candidate" ]] || continue
		[[ "$candidate" == "$current_release" || "$candidate" == "$retained_release" ]] &&
			continue
		rm -rf "$candidate"
	done
}

activate() {
	local target="$1" prior='' current_next='' previous_next='' shader_next=''
	verify_app "$target"
	managed_release_app "$target" || {
		printf 'Refusing to activate an app outside the managed release store.\n' >&2
		return 1
	}
	if [[ -e "$canonical_app" || -L "$canonical_app" ]]; then
		prior="$(active_release)" || {
			printf 'Refusing to replace a non-managed app at %s.\n' "$canonical_app" >&2
			return 1
		}
	fi

	next_app="$applications_dir/.Herdr-next.$$.app"
	ditto --rsrc --extattr "$target" "$next_app"
	verify_app "$next_app"

	if [[ "$launch_after" == true ]]; then
		osascript -e "tell application id \"$herdr_bundle_id\" to quit" >/dev/null 2>&1 || true
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			pgrep -f '/Herdr\.app/Contents/MacOS/ghostty' >/dev/null 2>&1 || break
			sleep 1
		done
		if pgrep -f '/Herdr\.app/Contents/MacOS/ghostty' >/dev/null 2>&1; then
			printf 'Herdr did not quit; the release was not switched.\n' >&2
			return 1
		fi
	fi

	if [[ -n "$prior" && "$prior" != "$target" ]]; then
		previous_next="$state_dir/.previous.$$"
		ln -s "$prior" "$previous_next"
	fi
	current_next="$state_dir/.current.$$"
	ln -s "$target" "$current_next"

	if [[ -e "$canonical_app" || -L "$canonical_app" ]]; then
		prior_app="$applications_dir/.Herdr-prior.$$.app"
		mv "$canonical_app" "$prior_app"
	fi
	if ! mv "$next_app" "$canonical_app"; then
		[[ -z "$prior_app" ]] || mv "$prior_app" "$canonical_app"
		return 1
	fi
	next_app=''
	rm -rf "$prior_app"
	prior_app=''

	# Copy the pinned config + shader into the isolated XDG root Ghostty reads
	# from (LSEnvironment:XDG_CONFIG_HOME). herdr itself never sees this root
	# (herdr.ghostty.in unsets XDG_CONFIG_HOME before exec'ing herdr), so this
	# only isolates Ghostty's own settings from your other profiles.
	mkdir -p "$(dirname "$ghostty_config")"
	config_next="$ghostty_config.next.$$"
	cp "$canonical_app/Contents/Resources/herdr.ghostty" "$config_next"
	mv -f "$config_next" "$ghostty_config"
	config_next=''
	shader_next="$(dirname "$ghostty_config")/cursor_warp.glsl.next.$$"
	cp "$canonical_app/Contents/Resources/cursor_warp.glsl" "$shader_next"
	mv -f "$shader_next" "$(dirname "$ghostty_config")/cursor_warp.glsl"

	if [[ -n "$previous_next" ]]; then
		mv -fh "$previous_next" "$previous_link"
	fi
	mv -fh "$current_next" "$current_link"
	printf '%s\t%s\t%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$(basename "$(dirname "$target")")" \
		"$target" >>"$activation_log"
	prune_releases "$(dirname "$target")"
	if [[ "$launch_after" == true ]]; then
		open "$canonical_app"
	fi
	printf 'Herdr active release: %s\n' "$(basename "$(dirname "$target")")"
}

resolve_zig() {
	if command -v brew >/dev/null && brew --prefix zig@0.15 >/dev/null 2>&1; then
		printf '%s/bin/zig\n' "$(brew --prefix zig@0.15)"
		return 0
	fi
	if command -v zig >/dev/null && zig version | grep -q '^0\.15'; then
		command -v zig
		return 0
	fi
	printf 'zig 0.15 is required (brew install zig@0.15).\n' >&2
	return 1
}

verified_ghostty_source() {
	local archive="$cache_root/ghostty-${ghostty_version}.tar.gz"
	local signature="$archive.minisig"
	local source="$cache_root/source"
	mkdir -p "$cache_root"
	if [[ ! -f "$archive" ]]; then
		curl --fail --location --output "$archive" \
			"https://release.files.ghostty.org/${ghostty_version}/ghostty-${ghostty_version}.tar.gz"
	fi
	if [[ ! -f "$signature" ]]; then
		curl --fail --location --output "$signature" \
			"https://release.files.ghostty.org/${ghostty_version}/ghostty-${ghostty_version}.tar.gz.minisig"
	fi
	[[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$ghostty_sha256" ]] || {
		printf 'Ghostty source archive digest does not match the pin.\n' >&2
		return 1
	}
	command -v minisign >/dev/null || {
		printf 'Homebrew minisign is required.\n' >&2
		return 1
	}
	minisign -Vm "$archive" -x "$signature" -P "$ghostty_minisign_key" >/dev/null
	if [[ ! -f "$source/macos/Sources/App/macOS/MainMenu.xib" ]]; then
		[[ ! -e "$source" ]] || {
			printf 'Ghostty source cache is incomplete: %s\n' "$source" >&2
			return 1
		}
		local extract
		extract="$(mktemp -d "$cache_root/.extract.XXXXXX")"
		tar -xzf "$archive" -C "$extract" --strip-components=1
		mv "$extract" "$source"
	fi
	printf '%s\n' "$source"
}

compile_main_menu() {
	local app="$1" source="$2" xib="$stage_dir/MainMenu.xib"
	cp "$source/macos/Sources/App/macOS/MainMenu.xib" "$xib"
	sed -i '' \
		-e 's/title="Ghostty"/title="Herdr"/g' \
		-e 's/title="About Ghostty"/title="About Herdr"/g' \
		-e 's/title="Make Ghostty the Default Terminal"/title="Make Herdr the Default Terminal"/g' \
		-e 's/title="Hide Ghostty"/title="Hide Herdr"/g' \
		-e 's/title="Quit Ghostty"/title="Quit Herdr"/g' \
		-e 's/title="Ghostty Help"/title="Herdr Help"/g' \
		-e 's/selector="showAbout:"/selector="orderFrontStandardAboutPanel:"/' \
		"$xib"
	sed -i '' '/<menuItem title="Check for Updates\.\.\."/,/<\/menuItem>/d' "$xib"
	ibtool --compile "$app/Contents/Resources/MainMenu.nib" "$xib"
}

print_herdr_keys_reminder() {
	local config="${XDG_CONFIG_HOME:-${HOME}/.config}/herdr/config.toml"
	# Deliberately not auto-merged: that file is your hand-curated, git-tracked
	# dotfiles config (dotfiles/src/.config/herdr/config.toml), and it already
	# has its own [keys] and [ui] tables — an automated append risks a second,
	# invalid [ui] table, or clobbering settings you reviewed by hand. Add the
	# lines below yourself if you want them; skip any already covered.
	printf '\nAdd to %s if you want the new bindings/UI keys (see %s for context):\n\n' \
		"$config" "$definition_dir/herdr-keys.toml"
	cat "$definition_dir/herdr-keys.toml"
}

set_plist() {
	local plist="$1" key="$2" value="$3"
	/usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null ||
		/usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
}

brand_bundle_metadata() {
	local app="$1"
	local plist="$app/Contents/Info.plist"
	local permission_keys=(
		NSAppleEventsUsageDescription
		NSBluetoothAlwaysUsageDescription
		NSCalendarsUsageDescription
		NSCameraUsageDescription
		NSContactsUsageDescription
		NSLocalNetworkUsageDescription
		NSLocationUsageDescription
		NSMicrophoneUsageDescription
		NSMotionUsageDescription
		NSPhotoLibraryUsageDescription
		NSRemindersUsageDescription
		NSSpeechRecognitionUsageDescription
		NSSystemAdministrationUsageDescription
	)
	local key value
	for key in "${permission_keys[@]}"; do
		value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
		set_plist "$plist" "$key" "${value//Ghostty/Herdr}"
	done
	set_plist "$plist" NSServices:0:NSMenuItem:default "New Herdr Tab Here"
	set_plist "$plist" NSServices:1:NSMenuItem:default "New Herdr Window Here"
	set_plist "$plist" UTExportedTypeDeclarations:0:UTTypeDescription "Herdr Surface Identifier"
	set_plist "$plist" UTExportedTypeDeclarations:0:UTTypeIdentifier \
		"${herdr_bundle_id}.surface-id"

	local plugin_plist="$app/Contents/PlugIns/DockTilePlugin.plugin/Contents/Info.plist"
	set_plist "$plugin_plist" CFBundleDisplayName "Herdr Dock Tile Plugin"
	set_plist "$plugin_plist" CFBundleIdentifier "${herdr_bundle_id}.dock-tile"

	local scripting_definition="$app/Contents/Resources/Ghostty.sdef"
	sed -i '' -e 's/Ghostty/Herdr/g' -e 's/HerdrScript/GhosttyScript/g' \
		"$scripting_definition"
}

build_herdr_binary() {
	local zig_bin
	zig_bin="$(resolve_zig)" || return 1
	(cd "$repo_root" && ZIG="$zig_bin" cargo build --release --locked)
	[[ -x "$repo_root/target/release/herdr" ]] || {
		printf 'cargo build did not produce target/release/herdr.\n' >&2
		return 1
	}
	printf '%s/target/release/herdr\n' "$repo_root"
}

build_app() {
	local ghostty_app='/Applications/Ghostty.app'
	[[ -d "$ghostty_app" ]] || {
		printf 'Install Ghostty.app %s first.\n' "$ghostty_version" >&2
		exit 1
	}
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ghostty_app/Contents/Info.plist")" == "$ghostty_bundle_id" ]] || {
		printf 'The source application is not official Ghostty.\n' >&2
		exit 1
	}
	[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ghostty_app/Contents/Info.plist")" == "$ghostty_version" ]] || {
		printf 'Ghostty.app must be version %s (bump the pin in install.sh to upgrade).\n' "$ghostty_version" >&2
		exit 1
	}
	codesign --verify --deep --strict "$ghostty_app"
	local signature
	signature="$(codesign -dv --verbose=4 "$ghostty_app" 2>&1 || true)"
	grep -Fq "TeamIdentifier=$ghostty_team_id" <<<"$signature" || {
		printf 'Ghostty.app is not signed by the expected upstream team.\n' >&2
		exit 1
	}
	# `command -v ibtool` is true even with only the Command Line Tools installed
	# (the shim lives at /usr/bin/ibtool either way) but the shim just prints an
	# error and exits non-zero without full Xcode, so actually invoke it.
	ibtool --version >/dev/null 2>&1 || {
		printf 'ibtool requires full Xcode, not just the Command Line Tools (menu-bar rebrand needs it).\n' >&2
		exit 1
	}

	local herdr_bin ghostty_source
	herdr_bin="$(build_herdr_binary)"
	ghostty_source="$(verified_ghostty_source)"

	stage_dir="$(mktemp -d "$release_root/.build.XXXXXX")"
	local app="$stage_dir/$app_name"
	ditto --rsrc --extattr "$ghostty_app" "$app"

	cp "$herdr_bin" "$app/Contents/Resources/herdr"
	chmod +x "$app/Contents/Resources/herdr"
	codesign --force --sign - "$app/Contents/Resources/herdr"

	sed "s#@HERDR_BIN@#$(herdr_bin_path)#" "$definition_dir/herdr.ghostty.in" \
		>"$app/Contents/Resources/herdr.ghostty"
	cp "$definition_dir/cursor_warp.glsl" "$app/Contents/Resources/cursor_warp.glsl"
	cp "$definition_dir/Herdr.icns" "$app/Contents/Resources/Herdr.icns"
	cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE-HERDR-APACHE-2.0.txt"
	cp "$ghostty_source/LICENSE" "$app/Contents/Resources/LICENSE-GHOSTTY-MIT.txt"
	compile_main_menu "$app" "$ghostty_source"

	local plist="$app/Contents/Info.plist"
	set_plist "$plist" CFBundleDisplayName Herdr
	set_plist "$plist" CFBundleName Herdr
	set_plist "$plist" CFBundleIdentifier "$herdr_bundle_id"
	set_plist "$plist" CFBundleExecutable ghostty
	set_plist "$plist" CFBundleIconFile Herdr.icns
	set_plist "$plist" LSEnvironment:XDG_CONFIG_HOME "$ghostty_xdg_root"
	set_plist "$plist" NSHumanReadableCopyright "Terminal implementation: Ghostty ${ghostty_version}"
	/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$plist" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$plist" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c 'Delete :SUEnableAutomaticChecks' "$plist" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$plist" 2>/dev/null || true
	brand_bundle_metadata "$app"

	codesign --force --deep --sign - "$app"
	verify_app "$app"

	local git_sha dirty='' release_id
	git_sha="$(git -C "$repo_root" rev-parse --short=12 HEAD)"
	git -C "$repo_root" diff --quiet -- . ':!macos' || dirty='-dirty'
	release_id="ghostty-${ghostty_version}-herdr-${git_sha}${dirty}"
	local release_dir="$release_root/$release_id"
	rm -rf "$release_dir"
	mv "$stage_dir" "$release_dir"
	stage_dir=''

	activate "$release_dir/$app_name"
	print_herdr_keys_reminder
}

case "$mode" in
build) build_app ;;
verify)
	verify_app "$canonical_app"
	printf 'Herdr verification passed: %s\n' "$canonical_app"
	;;
rollback)
	target=''
	if [[ -n "$rollback_id" ]]; then
		target="$release_root/$rollback_id/$app_name"
	elif [[ -L "$previous_link" ]]; then
		target="$(resolve_link "$previous_link")"
	else
		printf 'No Herdr rollback release is available.\n' >&2
		exit 1
	fi
	activate "$target"
	;;
esac
