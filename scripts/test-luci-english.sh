#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
node - "$root" <<'JS'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const files = fs.readdirSync(path.join(root, 'luci-ikev2-manager'))
	.filter(name => /\.(js|json)$/.test(name))
	.map(name => 'luci-ikev2-manager/' + name)
	.concat([ 'luci-ikev2-domains/editor.js', 'windows-profile-installer/Program.cs' ]);
for (const file of files) {
	const source = fs.readFileSync(path.join(root, file), 'utf8');
	if (/[\p{Script=Arabic}\p{Script=Cyrillic}]/u.test(source))
		throw new Error('Non-English interface text remains in ' + file);
}
const shared = fs.readFileSync(path.join(root, 'luci-ikev2-manager/shared.js'), 'utf8');
if (/languageSwitch|Vazirmatn|defaultLanguage/.test(shared))
	throw new Error('Unused localization code remains');
console.log('English-only interface checks OK');
JS
