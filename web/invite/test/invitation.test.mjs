import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, writeFile, readdir, mkdir, rm, symlink, unlink } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { configuredOrigin, parseInvitation, applicationLink } from '../invitation.mjs';
import { buildSite, validateConfig, inspectSiteOutput, verifySiteManifest, publicPaths, readSiteJson } from '../build.mjs';

const origin = 'https://invites.example.test';
const id = 'abcdef0123456789abcdef0123456789abcdef01';
const link = `${origin}/invite/#v=1&id=${id}`;

test('fragment names round trip through a compatible installed-app link', () => {
  const invite = parseInvitation(`${link}&name=Zo%C3%AB+%26+Mara`, origin);
  assert.deepEqual(invite, { id, name: 'Zoë & Mara' });
  assert.equal(applicationLink(invite), `sybl://add/${id}?name=Zo%C3%AB+%26+Mara`);
  assert.deepEqual(parseInvitation(link, origin), { id, name: '' });
  assert.equal(parseInvitation(`${link}&name=%0Ahidden`, origin).name, '');
  assert.equal(parseInvitation(`${link}&name=${'x'.repeat(65)}`, origin).name, '');
});

test('only the configured origin and bounded unambiguous fragment are accepted', () => {
  for (const bad of [
    `${link}&id=${id}`, `${link}&%69d=${id}`, `${link}&other=true`, `${link}&name=a&name=b`,
    `${link}&name`, `${link}&name=%FF`, `${link}&name=%C0%AF`, `${link}&name=%`,
    `${link}&name=%GG`, `${link}&name=a b`, `${link}\n`, `${link}&name=${'x'.repeat(1025)}`,
    link.replace('v=1', 'v=2'), link.replace(id, 'not-an-id'), link.replace('/invite/', '/other/'),
    link.replace('/invite/#', '/invite/?#'), link.replace('/invite/#', `/invite/?id=${id}#`),
    link.replace('invites.example.test', 'invites.example.test.evil.test'),
    link.replace('https://', 'http://'), link.replace('https://', 'https://user@'),
    link.replace('example.test/', 'example.test:444/'),
  ]) assert.equal(parseInvitation(bad, origin), null, bad);
  assert.equal(parseInvitation(link, ''), null);
  for (const bad of ['', 'http://example.test', `${origin}/other`, `${origin}?`, `${origin}#`, `${origin}:443`, 'https://bad..test']) assert.equal(configuredOrigin(bad), null, bad);
});

test('release configuration rejects credentials, unknown fields and invalid signer fingerprints', () => {
  assert.throws(() => validateConfig({ origin, analytics: true }));
  assert.throws(() => validateConfig({ origin, windowsDownload: 'javascript:alert(1)' }));
  assert.throws(() => validateConfig({ origin, androidDownload: 'https://secret@download.example.test/app.apk' }));
  for (const suffix of ['?token=private', '?', '#private', '#']) {
    assert.throws(() => validateConfig({ origin, windowsDownload: `https://download.example.test/app.zip${suffix}` }));
  }
  assert.throws(() => validateConfig({ origin, androidCertificateSha256: ['not-a-certificate'] }));
  assert.equal(validateConfig({ origin }).androidCertificateSha256.length, 0);
});

test('one release configuration generates site, Dart origin and optional Android association', async t => {
  const parent = resolve('local/tmp');
  await mkdir(parent, { recursive: true });
  const output = await mkdtemp(join(parent, 'invite-site-test-'));
  t.after(async () => {
    assert.ok(output.startsWith(parent + (process.platform === 'win32' ? '\\' : '/')));
    await rm(output, { recursive: true });
  });
  const certificate = Array(32).fill('AB').join(':');
  await buildSite({ origin, windowsDownload: 'https://downloads.example.test/doorlight.zip', androidCertificateSha256: [certificate] }, output);
  const defines = JSON.parse(await readFile(join(output, 'dart-defines.json'), 'utf8'));
  assert.deepEqual(defines, { DOORLIGHT_INVITE_ORIGIN: origin, DOORLIGHT_VERIFIED_APP_LINKS: 'true' });
  const links = JSON.parse(await readFile(join(output, '.well-known/assetlinks.json'), 'utf8'));
  assert.equal(links[0].target.package_name, 'app.sybl.sybl');
  assert.deepEqual(links[0].target.sha256_cert_fingerprints, [certificate]);
  const config = await readFile(join(output, 'invite/config.mjs'), 'utf8');
  assert.ok(config.includes(origin));
  assert.ok(!config.includes(id));
  assert.ok((await readFile(join(output, '_headers'), 'utf8')).includes("connect-src 'none'"));
  await assert.rejects(buildSite({ origin }, output), /empty directory/);
  assert.deepEqual(JSON.parse(await readFile(join(output, '.well-known/assetlinks.json'), 'utf8')), links);
  const fresh = join(output, 'fresh');
  await buildSite({ origin }, fresh);
  assert.deepEqual(JSON.parse(await readFile(join(fresh, '.well-known/assetlinks.json'), 'utf8')), []);
  assert.equal(JSON.parse(await readFile(join(fresh, 'dart-defines.json'), 'utf8')).DOORLIGHT_VERIFIED_APP_LINKS, 'false');
});

test('staging refuses unexpected files without modifying or deleting them', async t => {
  const parent = resolve('local/tmp');
  await mkdir(parent, { recursive: true });
  const output = await mkdtemp(join(parent, 'invite-stale-test-'));
  t.after(async () => {
    assert.ok(output.startsWith(parent + (process.platform === 'win32' ? '\\' : '/')));
    await rm(output, { recursive: true });
  });
  await writeFile(join(output, 'private-diagnostic.txt'), 'synthetic-private-data');
  await assert.rejects(buildSite({ origin }, output), /empty directory/);
  assert.deepEqual(await readdir(output), ['private-diagnostic.txt']);
  assert.equal(await readFile(join(output, 'private-diagnostic.txt'), 'utf8'), 'synthetic-private-data');
});

test('final manifest lists exactly public files and separate build metadata; tampering fails', async t => {
  const parent = resolve('local/tmp');
  await mkdir(parent, { recursive: true });
  const output = await mkdtemp(join(parent, 'invite-manifest-test-'));
  t.after(async () => {
    assert.ok(output.startsWith(parent + (process.platform === 'win32' ? '\\' : '/')));
    await rm(output, { recursive: true });
  });
  await buildSite({ origin }, output);
  const manifest = await inspectSiteOutput(output);
  assert.deepEqual(manifest.publicFiles.map(file => file.path).sort(), publicPaths);
  assert.deepEqual(manifest.buildOnlyFiles.map(file => file.path), ['dart-defines.json']);
  assert.ok(manifest.publicFiles.every(file => /^[a-f0-9]{64}$/.test(file.sha256) && file.bytes > 0));
  assert.deepEqual(await verifySiteManifest(output, manifest), manifest);
  await writeFile(join(output, 'invite/config.mjs'), 'altered');
  await assert.rejects(verifySiteManifest(output, manifest), /does not match/);
  await writeFile(join(output, 'invite/assets/private.txt'), 'synthetic private data');
  await assert.rejects(inspectSiteOutput(output), /Unexpected/);
  assert.equal(await readFile(join(output, 'invite/assets/private.txt'), 'utf8'), 'synthetic private data');
  await unlink(join(output, 'invite/assets/private.txt'));
  await unlink(join(output, 'invite/index.html'));
  await assert.rejects(inspectSiteOutput(output), /Incomplete/);
});

test('linked staging ancestors and nested entries fail without writing through them', async t => {
  const parent = resolve('local/tmp');
  await mkdir(parent, { recursive: true });
  const fixture = await mkdtemp(join(parent, 'invite-linked-test-'));
  t.after(async () => {
    assert.ok(fixture.startsWith(parent + (process.platform === 'win32' ? '\\' : '/')));
    await rm(fixture, { recursive: true });
  });
  const target = join(fixture, 'target');
  await mkdir(target);
  const linked = join(fixture, 'linked');
  await symlink(target, linked, 'junction');
  await assert.rejects(buildSite({ origin }, join(linked, 'child')), /symbolic links or junctions/);
  assert.deepEqual(await readdir(target), []);
  const output = join(fixture, 'site');
  await buildSite({ origin }, output);
  await symlink(target, join(output, 'invite/assets/linked'), 'junction');
  await assert.rejects(inspectSiteOutput(output), /Linked staging entry/);
  assert.deepEqual(await readdir(target), []);
});

test('malformed private configuration is not echoed in parse errors', async t => {
  const parent = resolve('local/tmp');
  await mkdir(parent, { recursive: true });
  const output = await mkdtemp(join(parent, 'invite-config-error-test-'));
  t.after(async () => {
    assert.ok(output.startsWith(parent + (process.platform === 'win32' ? '\\' : '/')));
    await rm(output, { recursive: true });
  });
  const config = join(output, 'owner-config.json');
  await writeFile(config, '{"private":"synthetic-private-marker",broken');
  await assert.rejects(readSiteJson(config), error => {
    assert.equal(error.message, 'Site configuration or manifest could not be read as valid JSON');
    assert.equal(error.stack.includes('synthetic-private-marker'), false);
    return true;
  });
});
