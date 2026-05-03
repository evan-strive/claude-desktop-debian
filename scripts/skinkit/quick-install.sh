#!/usr/bin/env bash
#===============================================================================
# Skinkit quick-install — patches an already-installed Claude Desktop in place,
# without rebuilding the .deb. Idempotent; rerun to update CSS or the loader.
#
# Requires sudo (writes to /usr/lib/claude-desktop). Backs up the original
# app.asar to /usr/lib/claude-desktop/.../app.asar.skinkit-backup the first
# time it runs.
#
# Usage:
#   ./scripts/skinkit/quick-install.sh           # apply skinkit
#   ./scripts/skinkit/quick-install.sh --revert  # restore from backup
#===============================================================================

set -uo pipefail

# sudo drops nvm/user PATH; re-exec with the invoking user's PATH preserved.
if [[ -n "${SUDO_USER:-}" && -z "${SKINKIT_PATH_PRESERVED:-}" ]]; then
	user_path=$(sudo -u "$SUDO_USER" bash -lc 'echo "$PATH"' 2>/dev/null || echo '')
	if [[ -n "$user_path" ]]; then
		exec sudo env PATH="$user_path" SKINKIT_PATH_PRESERVED=1 \
			"$(realpath "$0")" "$@"
	fi
fi

ASAR_PATH='/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar'
BACKUP_PATH="${ASAR_PATH}.skinkit-backup"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
skinkit_src="$script_dir"

if [[ ! -f "$ASAR_PATH" ]]; then
	echo "Error: Claude Desktop asar not found at $ASAR_PATH"
	echo "Is claude-desktop installed?"
	exit 1
fi

if [[ "${1:-}" == '--revert' ]]; then
	if [[ ! -f "$BACKUP_PATH" ]]; then
		echo "Error: no backup found at $BACKUP_PATH"
		exit 1
	fi
	echo "Restoring original asar from backup..."
	sudo cp "$BACKUP_PATH" "$ASAR_PATH"
	echo "Done. Restart Claude Desktop."
	exit 0
fi

# Locate or install asar tool
if command -v asar &> /dev/null; then
	asar_exec='asar'
elif command -v npx &> /dev/null; then
	asar_exec='npx --yes @electron/asar'
else
	echo "Error: need 'asar' or 'npx' on PATH. Install with:"
	echo "  npm install -g @electron/asar"
	exit 1
fi

echo "Skinkit quick-install"
echo "  asar:    $ASAR_PATH"
echo "  source:  $skinkit_src"
echo

# Backup once
if [[ ! -f "$BACKUP_PATH" ]]; then
	echo "Backing up original asar..."
	sudo cp "$ASAR_PATH" "$BACKUP_PATH"
fi

# Always start from the pristine backup so we don't double-patch
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

echo "Extracting asar to $work_dir/contents..."
cp "$BACKUP_PATH" "$work_dir/app.asar"
$asar_exec extract "$work_dir/app.asar" "$work_dir/contents" || {
	echo 'Error: asar extract failed'
	exit 1
}

# We need the existing frame-fix-entry.js setup — but the installed asar
# already has those wrappers built in by the original .deb. So we operate
# on whatever entry the installed app uses.
contents="$work_dir/contents"

# Find the current main entry
current_main=$(node -e "console.log(require('$contents/package.json').main)")
echo "  current main entry: $current_main"

# Copy skinkit files
echo "Installing skinkit/ into asar..."
mkdir -p "$contents/skinkit"
cp -a "$skinkit_src/_skinkit.js" "$skinkit_src/manifest.json" \
	"$skinkit_src"/*.css "$contents/skinkit/" || exit 1

# Inject loader. Strategy: prepend a tiny shim to the current main entry.
# We mark our injection so reruns are idempotent.
entry_file="$contents/$current_main"

if grep -q 'SKINKIT_LOADER_INJECTED' "$entry_file"; then
	echo "  loader already present (rebuilding from backup wipes this — good)"
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
$asar_exec pack "$contents" "$work_dir/app.asar.new" || {
	echo 'Error: asar pack failed'
	exit 1
}

echo "Installing patched asar (sudo required)..."
sudo cp "$work_dir/app.asar.new" "$ASAR_PATH"

echo
echo "Done. Restart Claude Desktop to see the skin picker."
echo "  Pick a skin via the floating widget in the bottom-right of the window."
echo "  To revert:   $0 --revert"
