import { readFile, writeFile, mkdir, copyFile, readdir, lstat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { configuredOrigin } from './invitation.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

export const publicPaths = Object.freeze([
  '_headers', '.well-known/assetlinks.json',
  ...['index.html','style.css','app.mjs','invitation.mjs','config.mjs'].map(name => `invite/${name}`),
  ...['mark.png','hero.png','NOTICE.txt','HankenGrotesk-Variable.ttf','Fraunces-Variable.ttf','OFL-HankenGrotesk.txt','OFL-Fraunces.txt'].map(name => `invite/assets/${name}`),
].sort());
const buildOnlyPaths = ['dart-defines.json'];

async function refuseLinkedAncestors(path) {
  const parent = dirname(path);
  if (parent !== path) await refuseLinkedAncestors(parent);
  try {
    if ((await lstat(path)).isSymbolicLink()) throw new Error('Staging path must not contain symbolic links or junctions');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

export async function inspectSiteOutput(output) {
  const out = resolve(output);
  await refuseLinkedAncestors(out);
  const expected = new Set([...publicPaths, ...buildOnlyPaths]);
  const directories = new Set(['invite', 'invite/assets', '.well-known']);
  const files = [];
  async function visit(directory, relative = '') {
    for (const name of (await readdir(directory)).sort()) {
      const path = relative ? `${relative}/${name}` : name;
      const absolute = join(directory, name);
      const info = await lstat(absolute);
      if (info.isSymbolicLink()) throw new Error('Linked staging entry refused');
      if (info.isDirectory() && directories.has(path)) await visit(absolute, path);
      else if (info.isFile() && expected.delete(path)) {
        const bytes = await readFile(absolute);
        files.push({ path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
      } else throw new Error('Unexpected staging entry refused');
    }
  }
  await visit(out);
  if (expected.size) throw new Error('Incomplete site output');
  files.sort((a, b) => a.path.localeCompare(b.path, 'en'));
  return {
    version: 1,
    publicFiles: files.filter(file => publicPaths.includes(file.path)),
    buildOnlyFiles: files.filter(file => buildOnlyPaths.includes(file.path)),
  };
}

export async function verifySiteManifest(output, manifest) {
  const actual = await inspectSiteOutput(output);
  if (JSON.stringify(actual) !== JSON.stringify(manifest)) throw new Error('Site output does not match its recorded manifest');
  return actual;
}

export async function readSiteJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch { throw new Error('Site configuration or manifest could not be read as valid JSON'); }
}

export function validateConfig(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      Object.keys(input).some(key => !['origin','windowsDownload','androidDownload','androidCertificateSha256'].includes(key))) throw new Error('Unknown invitation configuration field');
  const origin = configuredOrigin(input.origin);
  if (!origin) throw new Error('Set a canonical owned HTTPS origin without a path, port, query or fragment');
  const download = value => {
    if (value == null || value === '') return null;
    if (typeof value !== 'string' || value.length > 2048 || /[\u0000-\u0020\u007f]/.test(value)) throw new Error('Invalid download URL');
    let url;
    try { url = new URL(value); } catch { throw new Error('Invalid download URL'); }
    if (url.protocol !== 'https:' || url.username || url.password || value.includes('?') || value.includes('#')) throw new Error('Downloads must be public HTTPS URLs without credentials, queries or fragments');
    return url.href;
  };
  const certificates = input.androidCertificateSha256 ?? [];
  if (!Array.isArray(certificates) || certificates.length > 8 || certificates.some(value =>
    typeof value !== 'string' || !/^(?:[A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}$/.test(value))) throw new Error('Invalid Android certificate SHA-256 fingerprint');
  return Object.freeze({ origin, windowsDownload: download(input.windowsDownload), androidDownload: download(input.androidDownload), androidCertificateSha256: [...new Set(certificates.map(value => value.toUpperCase()))] });
}

export async function buildSite(config, output) {
  const validated = validateConfig(config);
  const out = resolve(output);
  await refuseLinkedAncestors(out);
  await mkdir(out, { recursive: true });
  if ((await lstat(out)).isSymbolicLink() || (await readdir(out)).length !== 0) {
    throw new Error('Output must be an empty directory, not a symbolic link; choose a fresh staging directory');
  }
  const page = join(out, 'invite');
  await mkdir(join(page, 'assets'), { recursive: true });
  for (const name of ['index.html','style.css','app.mjs','invitation.mjs']) await copyFile(join(root, 'web/invite', name), join(page, name));
  await copyFile(join(root, 'web/invite/_headers'), join(out, '_headers'));
  for (const name of ['mark.png','hero.png','NOTICE.txt']) await copyFile(join(root, 'apps/doorlight/assets/brand', name), join(page, 'assets', name));
  for (const name of ['HankenGrotesk-Variable.ttf','Fraunces-Variable.ttf','OFL-HankenGrotesk.txt','OFL-Fraunces.txt']) await copyFile(join(root, 'apps/doorlight/assets/fonts', name), join(page, 'assets', name));
  const publicConfig = { origin: validated.origin, windowsDownload: validated.windowsDownload, androidDownload: validated.androidDownload };
  await writeFile(join(page, 'config.mjs'), `export default Object.freeze(${JSON.stringify(publicConfig)});\n`);
  const links = validated.androidCertificateSha256.length > 0;
  await mkdir(join(out, '.well-known'), { recursive: true });
  await writeFile(join(out, '.well-known/assetlinks.json'), JSON.stringify(links ? [{
    relation: ['delegate_permission/common.handle_all_urls'],
    target: { namespace: 'android_app', package_name: 'app.sybl.sybl', sha256_cert_fingerprints: validated.androidCertificateSha256 },
  }] : [], null, 2) + '\n');
  await writeFile(join(out, 'dart-defines.json'), JSON.stringify({
    DOORLIGHT_INVITE_ORIGIN: validated.origin,
    DOORLIGHT_VERIFIED_APP_LINKS: String(links),
  }, null, 2) + '\n');
  await inspectSiteOutput(out);
  return validated;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  const verify = args[0] === '--verify';
  const [configPath, output = 'local/invite-site'] = args;
  if (!configPath || args.length > 2 || (verify && args.length !== 2)) throw new Error('Usage: node web/invite/build.mjs <owner-config.json> [output-directory] OR --verify <output-directory>');
  const outputPath = resolve(output);
  // Restrict generated material to this project's ignored local workspace.
  if (!outputPath.startsWith(join(root, 'local') + '\\') && !outputPath.startsWith(join(root, 'local') + '/')) throw new Error('Output must be under the project local directory');
  const manifestPath = `${outputPath}.manifest.json`;
  if (verify) {
    await verifySiteManifest(outputPath, await readSiteJson(manifestPath));
    console.log('Site paths and bytes match the recorded manifest. Publication approval remains separate.');
  } else {
    await buildSite(await readSiteJson(configPath), outputPath);
    // Keep this inspection record beside staging, not inside the upload root.
    await writeFile(manifestPath, JSON.stringify(await inspectSiteOutput(outputPath), null, 2) + '\n', { flag: 'wx' });
    console.log('Built and inventoried the invitation site. Publish only manifest publicFiles after release approval.');
  }
}
