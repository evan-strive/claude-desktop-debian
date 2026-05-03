#!/usr/bin/env bash
#===============================================================================
# Skinkit quick-install — patches an already-installed Claude Desktop in place,
# without rebuilding the .deb. Idempotent; rerun to update CSS or the loader.
#
# Usage:
#   sudo ./scripts/skinkit/quick-install.sh           # apply skinkit
#   sudo ./scripts/skinkit/quick-install.sh --revert  # restore from backup
#===============================================================================

set -uo pipefail

ASAR_PATH='/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar'
BACKUP_PATH="${ASAR_PATH}.skinkit-backup"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
skinkit_src="$script_dir"

# ---------------------------------------------------------------------------
# Find a Node.js binary that is >= v18. Checks nvm dirs of the invoking user
# first (so root doesn't use the system Node v12), then falls back to PATH.
# ---------------------------------------------------------------------------
find_node() {
	local nvm_base="/home/${SUDO_USER:-$USER}/.nvm/versions/node"
	if [[ -d "$nvm_base" ]]; then
		for node_bin in "$nvm_base"/*/bin/node; do
			[[ -x "$node_bin" ]] || continue
			local major
			major=$("$node_bin" -e 'process.stdout.write(process.version.replace(/^v/,"").split(".")[0])' 2>/dev/null || echo 0)
			if [[ "${major:-0}" -ge 18 ]]; then
				echo "$node_bin"
				return 0
			fi
		done
	fi
	local p
	p=$(command -v node 2>/dev/null || true)
	if [[ -n "$p" ]]; then
		local major
		major=$("$p" -e 'process.stdout.write(process.version.replace(/^v/,"").split(".")[0])' 2>/dev/null || echo 0)
		if [[ "${major:-0}" -ge 18 ]]; then
			echo "$p"
			return 0
		fi
	fi
	return 1
}

NODE=$(find_node || true)
if [[ -z "$NODE" ]]; then
	echo "Error: no Node.js >= 18 found."
	echo "Install Node.js 20+ via nvm, then retry."
	exit 1
fi
NPX="$(dirname "$NODE")/npx"
echo "Using Node: $NODE ($("$NODE" --version))"

# ---------------------------------------------------------------------------

if [[ ! -f "$ASAR_PATH" ]]; then
	echo "Error: Claude Desktop asar not found at $ASAR_PATH"
	exit 1
fi

if [[ "${1:-}" == '--revert' ]]; then
	if [[ ! -f "$BACKUP_PATH" ]]; then
		echo "Error: no backup found at $BACKUP_PATH"
		exit 1
	fi
	echo "Restoring original asar from backup..."
	cp "$BACKUP_PATH" "$ASAR_PATH"
	echo "Done. Restart Claude Desktop."
	exit 0
fi

echo "Skinkit quick-install"
echo "  asar:   $ASAR_PATH"
echo "  source: $skinkit_src"
echo

# Backup once from the canonical installed asar
if [[ ! -f "$BACKUP_PATH" ]]; then
	echo "Backing up original asar..."
	cp "$ASAR_PATH" "$BACKUP_PATH"
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

echo "Extracting asar..."
cp "$BACKUP_PATH" "$work_dir/app.asar"
"$NPX" --yes @electron/asar extract "$work_dir/app.asar" "$work_dir/contents" || {
	echo 'Error: asar extract failed'
	exit 1
}

contents="$work_dir/contents"

current_main=$("$NODE" -e "console.log(require('$contents/package.json').main)")
echo "  main entry: $current_main"

echo "Installing skinkit/ into asar..."
mkdir -p "$contents/skinkit"
cp -a "$skinkit_src/_skinkit.js" "$skinkit_src/manifest.json" \
	"$skinkit_src"/*.css "$contents/skinkit/" || exit 1

entry_file="$contents/$current_main"
if grep -q 'SKINKIT_LOADER_INJECTED' "$entry_file"; then
	echo "  skinkit already present in backup (clean re-inject)"
fi

shim=$(mktemp)
cat > "$shim" << 'EOFSHIM'
// SKINKIT_LOADER_INJECTED
try {
  require('./skinkit/_skinkit')(require('electron'));
} catch (e) {
  console.error('[Skinkit] init failed:', e && e.message);
}
EOFSHIM

cat "$shim" "$entry_file" > "${entry_file}.new"
mv "${entry_file}.new" "$entry_file"
rm "$shim"

echo "Repacking asar..."
"$NPX" --yes @electron/asar pack "$contents" "$work_dir/app.asar.new" || {
	echo 'Error: asar pack failed'
	exit 1
}

echo "Installing patched asar..."
cp "$work_dir/app.asar.new" "$ASAR_PATH"

echo
echo "Done. Fully quit and restart Claude Desktop."
echo "  Skin picker: floating widget in the bottom-right of the window."
echo "  Revert:      sudo $0 --revert"
