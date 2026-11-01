import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { convertV4MiniflareOptions, Miniflare, Response as RuntimeResponse } from 'miniflare';

const relayRoot = fileURLToPath(new URL('../', import.meta.url));
const scratchRoot = fileURLToPath(new URL('../../../local/tmp/', import.meta.url));
const handle = 'A'.repeat(43);
const deletedHandle = 'D'.repeat(43);
const secret = 'B'.repeat(43);
const otherSecret = 'C'.repeat(43);
const token = 'synthetic-fcm-token-1234567890';
const snapshotRecord = {
  token,
  secretHash: createHash('sha256').update(secret).digest('base64url'),
};
const unregisteredError = {
  error: {
    code: 404,
    status: 'NOT_FOUND',
    details: [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode: 'UNREGISTERED' }],
  },
};

// This test-only Worker has no public route. It reaches the real exported
// Durable Object through a local binding and calls its private bootstrap RPC.
const operatorScript = `
import { DurableObject } from 'cloudflare:workers';
export class AdapterProbe extends DurableObject {
  async inspect() {
    await this.ctx.storage.put('synthetic-probe', { value: 7 });
    const result = { synchronousGet: typeof this.ctx.storage.kv?.get === 'function' };
    try {
      result.sameBackingValue = this.ctx.storage.kv.get('synthetic-probe')?.value === 7;
    } catch (error) {
      result.storageError = error.name + ': ' + error.message;
    }
    const holder = { fetchImpl: fetch };
    try {
      result.memberFetchStatus = (await holder.fetchImpl('https://network-forbidden.invalid/adapter-probe')).status;
    } catch (error) {
      result.memberFetchError = error.name + ': ' + error.message;
    }
    const localFetch = fetch;
    try {
      result.localFetchStatus = (await localFetch('https://network-forbidden.invalid/adapter-probe')).status;
    } catch (error) {
      result.localFetchError = error.name + ': ' + error.message;
    }
    return result;
  }
}
export default {
  async fetch(request, env) {
    const { operation, handle, record } = await request.json();
    if (operation === 'diagnose') {
      return Response.json(await env.ADAPTER_PROBE.getByName('synthetic').inspect());
    }
    const stub = env.AUTHORITY.get(env.AUTHORITY.idFromName(handle));
    if (operation === 'bootstrap') {
      return new Response(null, { status: await stub.bootstrap(handle, record) });
    }
    if (operation === 'read') {
      return stub.fetch('https://registration.internal/v1/registrations/' + handle);
    }
    if (operation === 'wake') {
      await stub.wake(handle);
      return new Response(null, { status: 204 });
    }
    if (operation === 'network-check') {
      return fetch('https://network-forbidden.invalid/probe');
    }
    return new Response(null, { status: 400 });
  }
};`;

function registration(name = handle, owner = secret, nextToken = token, method = 'PUT') {
  return {
    url: `http://127.0.0.1/v1/registrations/${name}`,
    options: {
      method,
      headers: { authorization: `Bearer ${owner}`, 'content-type': 'application/json', 'cf-connecting-ip': '192.0.2.1' },
      body: method === 'PUT' ? JSON.stringify({ token: nextToken }) : undefined,
    },
  };
}

test('real fixed admission authority retains global and source bounds across SQLite reconstruction',
  { timeout: 30000 }, async (t) => {
    await mkdir(scratchRoot, { recursive: true });
    const runPath = await mkdtemp(join(scratchRoot, 'wake-admission-runtime-'));
    const options = convertV4MiniflareOptions({
      host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
      resourcePersistencePath: join(runPath, 'persist'),
      isolatedResourcePersistencePath: join(runPath, 'persist'),
      resourceTmpPath: join(runPath, 'tmp'), unsafeDevRegistryPath: join(runPath, 'registry'),
      modulesRoot: relayRoot,
      modules: [
        { type: 'ESModule', path: join(relayRoot, 'src/index.mjs') },
        { type: 'ESModule', path: join(relayRoot, 'src/worker.mjs') },
      ],
      compatibilityDate: '2026-08-11',
      durableObjects: {
        WAKE_REGISTRATION_AUTHORITY: { className: 'WakeRegistration', useSQLite: true },
        WAKE_ADMISSION: { className: 'WakeAdmission', useSQLite: true },
      },
      bindings: {
        WAKE_REGISTRATION_MIGRATION: 'complete', WAKE_REQUESTS_PER_MINUTE: '2',
        WAKE_SOURCE_REQUESTS_PER_MINUTE: '1', WAKE_SOURCE_CAPACITY: '2', WAKE_HANDLE_CAPACITY: '1',
      },
      outboundService: () => { throw new Error('No provider work allowed'); },
    });
    let mf = new Miniflare(options);
    t.after(async () => { await mf.dispose(); });
    const unknown = async (index) => mf.dispatchFetch(`http://127.0.0.1/v1/wakes/${String(index).padStart(43, 'Z')}`, {
      method: 'POST', headers: { 'cf-connecting-ip': '192.0.2.1' },
    });
    for (let index = 0; index < 50; index += 1) assert.equal((await unknown(index)).status, 202);
    assert.equal((await put(mf)).status, 503); // Same source already spent its one slot.
    const input = registration();
    input.options.headers['cf-connecting-ip'] = '192.0.2.2';
    assert.equal((await mf.dispatchFetch(input.url, input.options)).status, 204);
    await mf.dispose();
    mf = new Miniflare(options);
    input.options.headers['cf-connecting-ip'] = '192.0.2.3';
    assert.equal((await mf.dispatchFetch(input.url, input.options)).status, 503);
    assert.equal((await unknown(999)).status, 202);
    t.diagnostic(`Synthetic admission reconstruction: ${runPath}`);
  });

test('real SQLite admission reclaims expired slots across multiple index pages',
  { timeout: 30000 }, async (t) => {
    await mkdir(scratchRoot, { recursive: true });
    const runPath = await mkdtemp(join(scratchRoot, 'wake-pages-runtime-'));
    const script = `
import { WakeAdmission } from './src/index.mjs';
import { WakeAdmissionStore } from './src/worker.mjs';
export class PageProbe extends WakeAdmission {
  constructor(state, env) {
    super(state, env);
    this.admission = new WakeAdmissionStore(state, env, { now: () => 1000000 });
  }
  async seedAndAdmit() {
    await this.ctx.storage.transaction(async (tx) => {
      for (let index = 0; index < 130; index += 1) {
        await tx.put('handle:' + String(index).padStart(43, 'A'), { expiresAt: 999999 });
      }
      await tx.put('handle-count', 130);
    });
    const admitted = await this.admission.admit('B'.repeat(43), 'C'.repeat(43), true);
    return { admitted, count: await this.ctx.storage.get('handle-count') };
  }
}
export default {
  async fetch(_request, env) {
    return Response.json(await env.PROBE.getByName('provider-wide-v1').seedAndAdmit());
  }
};`;
    const mf = new Miniflare(convertV4MiniflareOptions({
      host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
      resourcePersistencePath: join(runPath, 'persist'),
      isolatedResourcePersistencePath: join(runPath, 'persist'),
      resourceTmpPath: join(runPath, 'tmp'), unsafeDevRegistryPath: join(runPath, 'registry'),
      modulesRoot: relayRoot,
      modules: [
        { type: 'ESModule', path: join(relayRoot, 'page-probe.mjs'), contents: script },
        { type: 'ESModule', path: join(relayRoot, 'src/index.mjs') },
        { type: 'ESModule', path: join(relayRoot, 'src/worker.mjs') },
      ],
      compatibilityDate: '2026-08-11',
      durableObjects: { PROBE: { className: 'PageProbe', useSQLite: true } },
      bindings: {
        WAKE_REGISTRATION_MIGRATION: 'complete', WAKE_REQUESTS_PER_MINUTE: '1000',
        WAKE_SOURCE_REQUESTS_PER_MINUTE: '1000', WAKE_SOURCE_CAPACITY: '1000',
        WAKE_HANDLE_CAPACITY: '130',
      },
      outboundService: () => { throw new Error('No external network allowed'); },
    }));
    t.after(() => mf.dispose());
    assert.deepEqual(await (await mf.dispatchFetch('http://127.0.0.1/')).json(),
      { admitted: true, count: 1 });
  });

async function put(mf, name = handle, owner = secret, nextToken = token) {
  const { url, options } = registration(name, owner, nextToken);
  return mf.dispatchFetch(url, options);
}

test('SQLite alarms retire dormant tokens, preserve renewal, and roll back atomically',
  { timeout: 30000 }, async (t) => {
    await mkdir(scratchRoot, { recursive: true });
    const runPath = await mkdtemp(join(scratchRoot, 'wake-alarm-runtime-'));
    // Only this local adapter exposes inspection/clock fixtures. Production
    // alarm dispatch remains inherited from the actual Worker entry class.
    const script = `
import { WakeRegistration, WakeAdmission } from './src/index.mjs';
export { WakeAdmission };
export class AlarmProbe extends WakeRegistration {
  async alarm() {
    await super.alarm();
    await this.ctx.storage.put('deliveries', (await this.ctx.storage.get('deliveries') ?? 0) + 1);
  }
  async inspect() {
    return {
      row: await this.ctx.storage.get('registration'),
      alarm: await this.ctx.storage.getAlarm(),
      deliveries: await this.ctx.storage.get('deliveries') ?? 0,
    };
  }
  async fetch(request) {
    const { operation, handle, record } = await request.json();
    if (operation === 'register' || operation.startsWith('seed-')) {
      const namespace = this.registration.env.WAKE_ADMISSION;
      if (!await namespace.get(namespace.idFromName('provider-wide-v1')).reserve(handle)) {
        throw new Error('Synthetic alarm admission reservation failed');
      }
    }
    if (operation === 'register') {
      await this.registration.change(handle, record.secretHash, record);
    } else if (operation.startsWith('seed-')) {
      await this.ctx.storage.transaction(async (tx) => {
        await tx.deleteAlarm();
        if (operation === 'seed-absent') {
          await tx.delete('registration');
          return;
        }
        const row = { version: 1, handle, record, revision: 7 };
        if (operation === 'seed-future') row.expiresAt = Date.now() + 60000;
        if (operation === 'seed-expired') row.expiresAt = Date.now() - 1;
        if (operation === 'seed-deleted') row.record = null;
        if (operation === 'seed-invalidated') row.record = { ...record, token: null };
        await tx.put('registration', row);
        if (operation === 'seed-deleted' || operation === 'seed-invalidated') {
          await tx.setAlarm(Date.now() + 60000);
        }
      });
    } else if (operation === 'expiry' || operation === 'early' || operation === 'rollback') {
      try {
        await this.ctx.storage.transaction(async (tx) => {
          const row = await tx.get('registration');
          const now = Date.now();
          await tx.put('registration', { ...row, expiresAt: now + (operation === 'early' ? 60000 : 600) });
          await tx.setAlarm(now + (operation === 'early' ? 100 : 600));
          if (operation === 'rollback') throw new Error('synthetic rollback');
        });
      } catch (error) {
        if (operation !== 'rollback') throw error;
      }
    }
    return Response.json(await this.inspect());
  }
}
export default {
  async fetch(request, env) {
    const input = await request.clone().json();
    const stub = env.PROBE.getByName('synthetic-alarm');
    if (input.operation === 'reconcile') {
      const status = await stub.reconcileExpiry(input.handle);
      return Response.json({ status, ...await stub.inspect() });
    }
    return stub.fetch(request);
  }
};`;
    const mf = new Miniflare(convertV4MiniflareOptions({
      host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
      resourcePersistencePath: join(runPath, 'persist'),
      isolatedResourcePersistencePath: join(runPath, 'persist'),
      resourceTmpPath: join(runPath, 'tmp'), unsafeDevRegistryPath: join(runPath, 'registry'),
      modulesRoot: relayRoot,
      modules: [
        { type: 'ESModule', path: join(relayRoot, 'alarm-probe.mjs'), contents: script },
        { type: 'ESModule', path: join(relayRoot, 'src/index.mjs') },
        { type: 'ESModule', path: join(relayRoot, 'src/worker.mjs') },
      ],
      compatibilityDate: '2026-08-11',
      durableObjects: {
        PROBE: { className: 'AlarmProbe', useSQLite: true },
        WAKE_ADMISSION: { className: 'WakeAdmission', useSQLite: true },
      },
      bindings: {
        WAKE_REGISTRATION_MIGRATION: 'complete', WAKE_REQUESTS_PER_MINUTE: '1000',
        WAKE_SOURCE_REQUESTS_PER_MINUTE: '1000', WAKE_SOURCE_CAPACITY: '1000',
        WAKE_HANDLE_CAPACITY: '1000',
      },
      outboundService: () => { throw new Error('No external network allowed'); },
    }));
    t.after(() => mf.dispose());
    const operate = async (operation) => (await mf.dispatchFetch('http://127.0.0.1/', {
      method: 'POST', body: JSON.stringify({ operation, handle, record: snapshotRecord }),
    })).json();
    const awaitDelivery = async (previous) => {
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        const state = await operate('inspect');
        if (state.deliveries > previous) return state;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      assert.fail('real local SQLite alarm was not delivered');
    };
    const registered = await operate('register');
    assert.equal(registered.alarm, registered.row.expiresAt);
    assert.ok(registered.alarm > Date.now() + 29 * 86400000);
    assert.deepEqual(await operate('rollback'), registered);
    const early = await operate('early');
    const rescheduled = await awaitDelivery(early.deliveries);
    assert.deepEqual(rescheduled.row, early.row);
    assert.equal(rescheduled.alarm, early.row.expiresAt);
    const expiring = await operate('expiry');
    assert.equal(expiring.row.record.token, token);
    const retired = await awaitDelivery(expiring.deliveries);
    assert.deepEqual(retired.row.record, { ...snapshotRecord, token: null });
    assert.equal(retired.row.revision, expiring.row.revision + 1);
    assert.equal(retired.alarm, null);
    const legacyFuture = await operate('seed-future');
    assert.equal(legacyFuture.alarm, null);
    const reconciled = await operate('reconcile');
    assert.equal(reconciled.status, 204);
    assert.deepEqual(reconciled.row, legacyFuture.row);
    assert.equal(reconciled.alarm, legacyFuture.row.expiresAt);
    for (const kind of ['missing', 'expired']) {
      const legacy = await operate('seed-' + kind);
      assert.equal(legacy.alarm, null);
      const cleaned = await operate('reconcile');
      assert.equal(cleaned.status, 204);
      assert.deepEqual(cleaned.row, {
        ...legacy.row, revision: legacy.row.revision + 1,
        record: { ...snapshotRecord, token: null },
      });
      assert.equal(cleaned.alarm, null);
    }
    for (const kind of ['deleted', 'invalidated', 'absent']) {
      const legacy = await operate('seed-' + kind);
      const cleaned = await operate('reconcile');
      assert.equal(cleaned.status, 204);
      assert.deepEqual(cleaned.row, legacy.row);
      assert.equal(cleaned.alarm, null);
    }
    t.diagnostic(`Synthetic SQLite alarm storage: ${runPath}`);
  });

async function remove(mf, name = handle, owner = secret) {
  const { url, options } = registration(name, owner, undefined, 'DELETE');
  return mf.dispatchFetch(url, options);
}

async function operate(mf, operation, name = handle, record = snapshotRecord) {
  const operator = await mf.getWorker('snapshot-operator');
  return operator.fetch('http://private-binding.invalid/', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ operation, handle: name, record }),
  });
}

test('real Worker entry point retains transactional ownership and migration gates in SQLite',
  { timeout: 180000 }, async (t) => {
    await mkdir(scratchRoot, { recursive: true });
    const runPath = await mkdtemp(join(scratchRoot, 'wake-runtime-'));
    t.diagnostic(`Synthetic durable storage: ${runPath}`);
    // Generated test key only. No credentials, identities or environment files are read.
    const { privateKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    const providerRequests = [];
    const deniedRequests = [];
    let wakeSent;
    let oauthEntered;
    let oauthGate;
    let fcmEntered;
    let fcmGate;
    const acceptedFcm = () => RuntimeResponse.json({ name: 'synthetic-message' });
    let fcmResponse = acceptedFcm;
    let mf;
    // Every global outbound request terminates in this local handler. It never
    // forwards to fetch(), a socket, Cloudflare, Google or any other provider.
    const outboundService = async (request) => {
      const url = new URL(request.url);
      if (request.method === 'POST' && url.href === 'https://oauth2.googleapis.com/token') {
        providerRequests.push({ kind: 'oauth', body: await request.text() });
        oauthEntered?.();
        if (oauthGate) await oauthGate;
        return RuntimeResponse.json({ access_token: 'synthetic-access-token-1234567890', expires_in: 3000 });
      }
      if (request.method === 'POST' &&
          url.href === 'https://fcm.googleapis.com/v1/projects/sybl-runtime-test/messages:send') {
        const body = await request.json();
        providerRequests.push({ kind: 'fcm', body });
        wakeSent?.(body);
        fcmEntered?.();
        if (fcmGate) await fcmGate;
        return fcmResponse();
      }
      if (url.href === 'https://network-forbidden.invalid/adapter-probe') {
        return new RuntimeResponse(null, { status: 599 });
      }
      deniedRequests.push(url.href);
      return new RuntimeResponse(null, { status: 599 });
    };
    // Pinned Miniflare 5 exposes this converter for the documented v4 option
    // form. Use its current persistence fields; old *Persist keys are ignored.
    const options = (phase) => convertV4MiniflareOptions({
      host: '127.0.0.1',
      port: 0,
      cf: false,
      telemetry: { enabled: false },
      resourcePersistencePath: join(runPath, 'persist'),
      isolatedResourcePersistencePath: join(runPath, 'persist'),
      resourceTmpPath: join(runPath, 'tmp'),
      unsafeDevRegistryPath: join(runPath, 'registry'),
      workers: [
        {
          name: 'relay',
          modulesRoot: relayRoot,
          modules: [
            { type: 'ESModule', path: join(relayRoot, 'src/index.mjs') },
            { type: 'ESModule', path: join(relayRoot, 'src/worker.mjs') },
          ],
          compatibilityDate: '2026-08-11',
          durableObjects: {
            WAKE_REGISTRATION_AUTHORITY: { className: 'WakeRegistration', useSQLite: true },
            WAKE_ADMISSION: { className: 'WakeAdmission', useSQLite: true },
          },
          kvNamespaces: { WAKE_REGISTRATIONS: 'synthetic-legacy' },
          bindings: {
            WAKE_REGISTRATION_MIGRATION: phase,
            WAKE_REQUESTS_PER_MINUTE: '1000',
            WAKE_SOURCE_REQUESTS_PER_MINUTE: '1000',
            WAKE_SOURCE_CAPACITY: '1000',
            WAKE_HANDLE_CAPACITY: '1000',
            FIREBASE_PROJECT_ID: 'sybl-runtime-test',
            FIREBASE_CLIENT_EMAIL: 'synthetic@sybl-runtime-test.invalid',
            FIREBASE_PRIVATE_KEY: privateKey,
          },
          outboundService,
        },
        {
          name: 'snapshot-operator',
          modules: true,
          script: operatorScript,
          compatibilityDate: '2026-08-11',
          durableObjects: {
            AUTHORITY: { className: 'WakeRegistration', scriptName: 'relay', useSQLite: true },
            ADAPTER_PROBE: { className: 'AdapterProbe', useSQLite: true },
          },
          outboundService,
        },
      ],
    });
    const restart = async (phase) => {
      if (mf) await mf.dispose();
      mf = new Miniflare(options(phase));
      const ready = await mf.ready;
      assert.equal(ready.hostname, '127.0.0.1');
    };
    t.after(async () => { if (mf) await mf.dispose(); });

    await t.test('blocked is closed; all outbound access is intercepted locally', async () => {
      await restart('blocked');
      assert.equal((await put(mf)).status, 503);
      assert.equal((await operate(mf, 'bootstrap')).status, 503);
      assert.equal((await operate(mf, 'read')).status, 503);
      assert.equal((await operate(mf, 'network-check')).status, 599);
      assert.deepEqual(deniedRequests, ['https://network-forbidden.invalid/probe']);
    });

    await t.test('native fetch receiver and synchronous SQLite API diagnostics', async () => {
      const result = await (await operate(mf, 'diagnose')).json();
      t.diagnostic(`Synthetic runtime adapter result: ${JSON.stringify(result)}`);
      assert.equal(result.synchronousGet, true);
      assert.equal(result.sameBackingValue, true);
      assert.equal(result.localFetchStatus, 599);
    });

    await t.test('importing never converts a stale deleted KV value into authority', async () => {
      await restart('importing');
      const legacy = await mf.getKVNamespace('WAKE_REGISTRATIONS', 'relay');
      await legacy.put(deletedHandle, JSON.stringify(snapshotRecord));
      assert.equal((await mf.dispatchFetch(`http://127.0.0.1/v1/wakes/${deletedHandle}`, {
        method: 'POST',
      })).status, 202);
      assert.equal((await put(mf, deletedHandle)).status, 503);
      assert.equal((await remove(mf, deletedHandle)).status, 503);
      assert.equal((await operate(mf, 'read', deletedHandle)).status, 503);
      assert.equal(providerRequests.length, 0);
      assert.equal(await legacy.get(deletedHandle), JSON.stringify(snapshotRecord));
    });

    await t.test('private RPC imports once and public HTTP cannot read or bootstrap', async () => {
      assert.equal((await operate(mf, 'bootstrap')).status, 204);
      assert.equal((await operate(mf, 'bootstrap')).status, 204);
      assert.deepEqual(await (await operate(mf, 'read')).json(), snapshotRecord);
      // Snapshot import is not authenticated owner renewal. Legacy expiry
      // cannot authorize OAuth/provider work, but its owner remains intact.
      assert.equal((await operate(mf, 'wake')).status, 204);
      assert.deepEqual(await (await operate(mf, 'read')).json(), { ...snapshotRecord, token: null });
      assert.equal(providerRequests.length, 0);
      assert.equal((await put(mf, handle, otherSecret)).status, 401);
      assert.equal((await mf.dispatchFetch(`http://127.0.0.1/v1/registrations/${handle}`)).status, 405);
      assert.equal((await mf.dispatchFetch(`http://127.0.0.1/v1/bootstrap/${handle}`, {
        method: 'POST', body: JSON.stringify(snapshotRecord),
      })).status, 404);
      assert.equal((await put(mf, handle, secret, `${token}-updated`)).status, 204);
      assert.equal((await operate(mf, 'bootstrap')).status, 409);
    });

    await t.test('public malformed requests keep their bounded rejection contract', async () => {
      assert.equal((await put(mf, handle, 'invalid')).status, 401);
      assert.equal((await mf.dispatchFetch(`http://127.0.0.1/v1/wakes/${handle}`, {
        method: 'POST', body: '{}',
      })).status, 400);
      assert.equal((await mf.dispatchFetch(`http://127.0.0.1/v1/registrations/${handle}`, {
        method: 'PUT',
        headers: { authorization: `Bearer ${secret}` },
        body: ' '.repeat(25000),
      })).status, 413);
      assert.equal(providerRequests.length, 0);
      assert.equal((await (await operate(mf, 'read')).json()).token, `${token}-updated`);
    });

    await t.test('complete retains imported records and serializes concurrent first owners', async () => {
      await restart('complete');
      assert.equal((await operate(mf, 'bootstrap')).status, 503);
      assert.equal((await operate(mf, 'read', deletedHandle)).status, 404);
      const current = await (await operate(mf, 'read')).json();
      assert.deepEqual(current, { ...snapshotRecord, token: `${token}-updated` });
      for (const prefix of ['E', 'F', 'G']) {
        const name = prefix.repeat(43);
        const results = await Promise.all([
          put(mf, name, secret, `${token}-first`),
          put(mf, name, otherSecret, `${token}-second`),
        ]);
        assert.deepEqual(results.map((response) => response.status).sort(), [204, 401]);
      }
    });

    await t.test('real OAuth and FCM call paths use only the local provider boundary', async () => {
      let timeout;
      const sent = new Promise((resolve, reject) => {
        wakeSent = resolve;
        timeout = setTimeout(() => reject(new Error('Local FCM fixture was not called')), 5000);
      });
      try {
        const response = await mf.dispatchFetch(`http://127.0.0.1/v1/wakes/${handle}`, {
          method: 'POST', headers: { 'cf-connecting-ip': '192.0.2.1' },
        });
        assert.equal(response.status, 202);
        assert.equal(await response.text(), '');
        assert.deepEqual(await sent, {
          message: {
            token: `${token}-updated`, data: { w: '1' }, android: { priority: 'high', ttl: '60s' },
          },
        });
        assert.deepEqual(providerRequests.map((entry) => entry.kind), ['oauth', 'fcm']);
        await Promise.all(Array.from({ length: 20 }, () => operate(mf, 'wake')));
        assert.deepEqual(providerRequests.map((entry) => entry.kind), ['oauth', 'fcm']);
        assert.deepEqual(deniedRequests, ['https://network-forbidden.invalid/probe']);
      } finally {
        clearTimeout(timeout);
        wakeSent = undefined;
      }
    });

    await t.test('deletion survives runtime reconstruction and cannot be undone by old snapshot', async () => {
      assert.equal((await remove(mf)).status, 204);
      await restart('importing');
      assert.equal((await operate(mf, 'read')).status, 404);
      assert.equal((await operate(mf, 'bootstrap')).status, 409);
      assert.equal((await put(mf, handle, otherSecret, `${token}-new-owner`)).status, 503);
      assert.equal((await remove(mf, handle, secret)).status, 503);
      assert.equal((await operate(mf, 'read')).status, 404);
    });

    await t.test('real DO revision fences late OAuth after deletion and token ABA', async (t) => {
      for (const [prefix, mutation] of [
        ['H', 'delete'], ['I', 'rotate'],
        ['J', 'delete-and-recreate'], ['K', 'rotate-away-and-back'],
      ]) {
        await t.test(mutation, async () => {
          // Full restart also removes the isolate's OAuth cache. Use a fresh
          // synthetic handle, while retaining real persisted SQLite storage.
          await restart('complete');
          const name = prefix.repeat(43);
          assert.equal((await put(mf, name)).status, 204);
          const before = providerRequests.length;
          let releaseOAuth;
          let timeout;
          const entered = new Promise((resolve, reject) => {
            oauthEntered = resolve;
            timeout = setTimeout(() => reject(new Error('Delayed local OAuth fixture was not called')), 5000);
          });
          oauthGate = new Promise((resolve) => { releaseOAuth = resolve; });
          // Wait on the actual DO RPC here so the assertion follows the entire
          // wake. Public opaque-202 dispatch is covered in the Node/public cases.
          const pending = operate(mf, 'wake', name);
          try {
            await entered;
            if (mutation.startsWith('delete')) {
              assert.equal((await remove(mf, name)).status, 204);
            } else {
              assert.equal((await put(mf, name, secret, `${token}-rotated`)).status, 204);
            }
            if (mutation === 'delete-and-recreate' || mutation === 'rotate-away-and-back') {
              assert.equal((await put(mf, name)).status,
                mutation === 'delete-and-recreate' ? 410 : 204);
            }
            releaseOAuth();
            assert.equal((await pending).status, 204);
            assert.deepEqual(providerRequests.slice(before).map((entry) => entry.kind), ['oauth']);
            if (!mutation.startsWith('delete')) {
              assert.equal((await operate(mf, 'wake', name)).status, 204);
              assert.deepEqual(providerRequests.slice(before).map((entry) => entry.kind), ['oauth']);
            }
          } finally {
            clearTimeout(timeout);
            releaseOAuth();
            oauthEntered = undefined;
            oauthGate = undefined;
            await pending;
          }
        });
      }
      assert.deepEqual(deniedRequests, ['https://network-forbidden.invalid/probe']);
    });

    await t.test('UNREGISTERED removes the token and preserves its owner across runtime restart', async () => {
      const name = 'L'.repeat(43);
      assert.equal((await put(mf, name)).status, 204);
      fcmResponse = () => RuntimeResponse.json(unregisteredError, { status: 404 });
      assert.equal((await operate(mf, 'wake', name)).status, 204);
      const retired = { token: null, secretHash: snapshotRecord.secretHash };
      assert.deepEqual(await (await operate(mf, 'read', name)).json(), retired);
      await restart('complete');
      assert.deepEqual(await (await operate(mf, 'read', name)).json(), retired);
      const before = providerRequests.length;
      assert.equal((await operate(mf, 'wake', name)).status, 204);
      assert.equal(providerRequests.length, before);
      assert.equal((await put(mf, name, otherSecret)).status, 401);
      assert.equal((await remove(mf, name, otherSecret)).status, 401);
      assert.equal((await put(mf, name, secret, `${token}-refreshed`)).status, 204);
      fcmResponse = acceptedFcm;
      await new Promise((resolve) => setTimeout(resolve, 10010));
      assert.equal((await operate(mf, 'wake', name)).status, 204);
      assert.equal(providerRequests.at(-1).kind, 'fcm');
      assert.equal(providerRequests.at(-1).body.message.token, `${token}-refreshed`);
      assert.equal((await remove(mf, name)).status, 204);
      assert.equal((await operate(mf, 'read', name)).status, 404);
    });

    await t.test('late UNREGISTERED cannot retire a replacement after SQLite commit and reconstruction', async (t) => {
      for (const [prefix, mutation] of [
        ['M', 'rotate'], ['N', 'delete-and-recreate'], ['O', 'rotate-away-and-back'],
      ]) {
        await t.test(mutation, async () => {
          const name = prefix.repeat(43);
          assert.equal((await put(mf, name)).status, 204);
          let releaseFcm;
          let timeout;
          const entered = new Promise((resolve, reject) => {
            fcmEntered = resolve;
            timeout = setTimeout(() => reject(new Error('Delayed local FCM response was not reached')), 5000);
          });
          fcmGate = new Promise((resolve) => { releaseFcm = resolve; });
          fcmResponse = () => RuntimeResponse.json(unregisteredError, { status: 404 });
          const pending = operate(mf, 'wake', name);
          try {
            await entered;
            if (mutation === 'delete-and-recreate') {
              assert.equal((await remove(mf, name)).status, 204);
              assert.equal((await put(mf, name, otherSecret)).status, 410);
            } else {
              assert.equal((await put(mf, name, secret, `${token}-rotated`)).status, 204);
              if (mutation === 'rotate-away-and-back') assert.equal((await put(mf, name)).status, 204);
            }
            const currentResponse = await operate(mf, 'read', name);
            const current = mutation === 'delete-and-recreate' ? null : await currentResponse.json();
            if (current === null) assert.equal(currentResponse.status, 404);
            releaseFcm();
            assert.equal((await pending).status, 204);
            const after = await operate(mf, 'read', name);
            if (current === null) assert.equal(after.status, 404);
            else assert.deepEqual(await after.json(), current);
            await restart('complete');
            const restored = await operate(mf, 'read', name);
            if (current === null) assert.equal(restored.status, 404);
            else assert.deepEqual(await restored.json(), current);
            fcmResponse = acceptedFcm;
            const beforeRetry = providerRequests.length;
            assert.equal((await operate(mf, 'wake', name)).status, 204);
            const retryRequests = providerRequests.slice(beforeRetry);
            if (current === null) assert.equal(retryRequests.length, 0);
            else for (const entry of retryRequests.filter((item) => item.kind === 'fcm')) {
              assert.equal(entry.body.message.token, current.token);
            }
            const afterRetry = await operate(mf, 'read', name);
            if (current === null) assert.equal(afterRetry.status, 404);
            else assert.deepEqual(await afterRetry.json(), current);
          } finally {
            clearTimeout(timeout);
            releaseFcm();
            fcmEntered = undefined;
            fcmGate = undefined;
            fcmResponse = acceptedFcm;
            await pending;
          }
        });
      }
      assert.deepEqual(deniedRequests, ['https://network-forbidden.invalid/probe']);
    });
  });
