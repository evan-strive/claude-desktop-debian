#!/usr/bin/env node
// _asar-helper.js — extract or repack asar files without relying on the
// system npm/npx. Installs @electron/asar locally on first run if needed.
//
// Usage (always invoke with the explicit node binary, not via PATH):
//   /path/to/node _asar-helper.js extract <asar> <outdir>
//   /path/to/node _asar-helper.js pack    <dir>  <asar>

'use strict';

const { execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const [, , cmd, arg1, arg2] = process.argv;

if (!cmd || !arg1 || !arg2) {
  process.stderr.write('Usage: node _asar-helper.js extract|pack <src> <dst>\n');
  process.exit(1);
}

// Install @electron/asar locally if not already present.
function requireAsar() {
  const localPkg = path.join(__dirname, 'node_modules', '@electron', 'asar');
  if (fs.existsSync(localPkg)) {
    return require(localPkg);
  }
  try {
    return require('@electron/asar');
  } catch (_) { /* not globally available, install locally */ }

  const npmCli = path.join(
    path.dirname(process.execPath), '..', 'lib',
    'node_modules', 'npm', 'bin', 'npm-cli.js',
  );
  if (!fs.existsSync(npmCli)) {
    process.stderr.write(
      `Error: cannot find npm-cli.js at ${npmCli}\n` +
      'Install @electron/asar manually: npm install -g @electron/asar\n',
    );
    process.exit(1);
  }

  process.stdout.write('[asar-helper] Installing @electron/asar locally...\n');
  execFileSync(
    process.execPath,
    [npmCli, 'install', '--prefix', __dirname, '--no-save', '@electron/asar'],
    { stdio: 'inherit' },
  );
  return require(localPkg);
}

const asar = requireAsar();

if (cmd === 'extract') {
  asar.extractAll(arg1, arg2);
  process.stdout.write(`Extracted: ${arg1} → ${arg2}\n`);
} else if (cmd === 'pack') {
  asar.createPackageWithOptions(arg1, arg2, {}).then(() => {
    process.stdout.write(`Packed: ${arg1} → ${arg2}\n`);
  }).catch((err) => {
    process.stderr.write(`Error packing: ${err.message}\n`);
    process.exit(1);
  });
} else {
  process.stderr.write(`Unknown command: ${cmd}\n`);
  process.exit(1);
}
