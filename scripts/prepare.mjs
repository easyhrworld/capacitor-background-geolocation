import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { delimiter, resolve } from 'node:path';

// Git installs in the host app's npm CI must build without requiring Bun.
// Bun's pack lifecycle also needs the package-local binaries added explicitly.
const { scripts } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
execSync(scripts.build, {
  stdio: 'inherit',
  env: { ...process.env, PATH: `${resolve('node_modules/.bin')}${delimiter}${process.env.PATH ?? ''}` },
});
