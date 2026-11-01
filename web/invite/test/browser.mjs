// Run with DOORLIGHT_PLAYWRIGHT_MODULE pointing to the provisioned playwright
// module entrypoint. Uses only an isolated profile and routed fixture origins.
import assert from 'node:assert/strict';
import { readFile, mkdir, mkdtemp } from 'node:fs/promises';
import { resolve, join, extname, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { buildSite, inspectSiteOutput, verifySiteManifest } from '../build.mjs';

if (!process.env.DOORLIGHT_PLAYWRIGHT_MODULE) throw new Error('Set DOORLIGHT_PLAYWRIGHT_MODULE to the provisioned Playwright entrypoint');
const { chromium } = await import(pathToFileURL(process.env.DOORLIGHT_PLAYWRIGHT_MODULE).href);
const parent = resolve('local/tmp');
await mkdir(parent, { recursive: true });
const workspace = await mkdtemp(join(parent, 'invite-browser-'));
const output = join(workspace, 'site');
const origin = 'https://invites.example.test';
const id = 'abcdef0123456789abcdef0123456789abcdef01';
await buildSite({ origin, windowsDownload: 'https://downloads.example.test/doorlight.zip', androidDownload: 'https://downloads.example.test/doorlight.apk' }, output);
const manifest = await inspectSiteOutput(output);
const browser = await chromium.launchPersistentContext(join(workspace, 'profile'), { channel: 'msedge', headless: true, serviceWorkers: 'block' });
const requests = [];
const errors = [];
try {
  await browser.route('**/*', async route => {
    const request = route.request();
    const url = new URL(request.url());
    requests.push({ url: request.url(), referrer: request.headers().referer });
    if (url.origin !== origin) return route.abort();
    const relative = url.pathname.endsWith('/') ? `${url.pathname}index.html` : url.pathname;
    const file = resolve(output, `.${relative}`);
    assert.ok(file.startsWith(output + sep));
    try {
      await route.fulfill({ body: await readFile(file), contentType: ({ '.html':'text/html', '.mjs':'text/javascript', '.css':'text/css', '.png':'image/png', '.ttf':'font/ttf' })[extname(file)] ?? 'application/octet-stream', headers: {
        'Referrer-Policy': 'no-referrer',
        'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      } });
    } catch { await route.fulfill({ status:404, body:'' }); }
  });
  const page = await browser.newPage();
  page.on('pageerror', error => errors.push(error.message));
  await page.setViewportSize({ width: 1100, height: 950 });
  await page.goto(`${origin}/invite/#v=1&id=${id}&name=Zo%C3%AB+%26+Mara`);
  await page.locator('#continue').waitFor({ state: 'visible' });
  await page.evaluate(() => document.fonts.ready);
  assert.equal(await page.locator('#heading').innerText(), 'Zoë & Mara invited you to Doorlight');
  assert.equal(await page.locator('#continue').getAttribute('href'), `sybl://add/${id}?name=Zo%C3%AB+%26+Mara`);
  assert.equal(await page.locator('#windows-download').getAttribute('href'), 'https://downloads.example.test/doorlight.zip');
  assert.equal(await page.locator('#android-download').getAttribute('rel'), 'noopener noreferrer');
  await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(() => document.activeElement.id), 'continue');
  await page.screenshot({ path: join(workspace, 'desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: join(workspace, 'mobile.png'), fullPage: true });
  await page.evaluate(() => { document.documentElement.style.fontSize = '36px'; });
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).fontSize), '36px');
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
  await page.locator('#android-download').scrollIntoViewIfNeeded();
  await page.screenshot({ path: join(workspace, 'mobile-text200.png'), fullPage: true });
  await page.evaluate(() => { location.hash = `v=1&id=${'a'.repeat(40)}&name=%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E`; });
  await page.waitForFunction(() => document.querySelector('#heading').textContent.includes('<img'));
  assert.equal(await page.locator('#heading img').count(), 0);
  await page.evaluate(() => { location.hash += '&name=duplicate'; });
  await page.waitForFunction(() => document.querySelector('#invitation').hidden);
  assert.equal(await page.locator('#continue').getAttribute('href'), null);
  assert.ok(requests.every(value => value.url.startsWith(origin) && !value.url.includes(id) && !value.url.includes('Mara') && !value.referrer));
  assert.deepEqual(errors, []);
  await verifySiteManifest(output, manifest);
  console.log(`Browser invitation and final manifest checks passed; captures are in ${workspace}`);
} finally {
  await browser.close();
}
