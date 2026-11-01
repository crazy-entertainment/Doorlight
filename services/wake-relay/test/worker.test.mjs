import assert from 'node:assert/strict';
import test from 'node:test';

import { createWorker as createProductionWorker, WakeRegistrationStore, WakeAdmissionStore } from '../src/worker.mjs';

function createWorker(options = {}) {
  const worker = createProductionWorker();
  return {
    fetch(request, env, context) {
      // Network and OAuth belong to the real DO handler. Only its external
      // adapters are replaced; the public Worker still dispatches its real RPC.
      if (env.WAKE_REGISTRATION_AUTHORITY instanceof MemoryAuthority) {
        env.WAKE_REGISTRATION_AUTHORITY.providerOptions = {
          fetchImpl: async () => { throw new Error('External fetch is forbidden in unit tests'); },
          ...options,
        };
      }
      return worker.fetch(request, env, context);
    },
  };
}

const handle = 'A'.repeat(43);
const secret = 'B'.repeat(43);
const token = 'fcm-registration-token-1234567890';

class MemoryKv {
  values = new Map();

  async get(key) {
    return this.values.get(key) ?? null;
  }

  async put(key, value) {
    this.values.set(key, value);
  }

  async delete(key) {
    this.values.delete(key);
  }
}

class MemoryTransactionalStorage {
  values = new Map();
  alarmAt = null;
  tail = Promise.resolve();
  failCommit = false;
  failTransactionRead = false;
  kv = {
    get: (key) => structuredClone(this.values.get(key)),
    put: (key, value) => {
      if (this.failCommit) throw new Error('synthetic synchronous write failure');
      this.values.set(key, structuredClone(value));
    },
  };

  async get(key) {
    return structuredClone(this.values.get(key));
  }

  async transaction(callback) {
    const previous = this.tail;
    let release;
    this.tail = new Promise((resolve) => { release = resolve; });
    await previous;
    const staged = structuredClone(this.values);
    let alarmAt = this.alarmAt;
    try {
      const result = await callback({
        get: async (key) => {
          if (this.failTransactionRead) throw new Error('synthetic transaction read failure');
          return structuredClone(staged.get(key));
        },
        put: async (key, value) => { staged.set(key, structuredClone(value)); },
        delete: async (key) => { staged.delete(key); },
        list: async ({ prefix = '', startAfter = '', limit = 128 } = {}) => new Map(
          [...staged.entries()].filter(([key]) => key.startsWith(prefix) && key > startAfter)
            .sort(([left], [right]) => left.localeCompare(right)).slice(0, limit),
        ),
        setAlarm: async (time) => { alarmAt = time; },
        deleteAlarm: async () => { alarmAt = null; },
      });
      if (this.failCommit) throw new Error('synthetic transaction commit failure');
      this.values = staged;
      this.alarmAt = alarmAt;
      return result;
    } finally {
      release();
    }
  }
}

class MemoryAuthority {
  stores = new Map();

  constructor(env) { this.env = env; }
  idFromName(name) { return name; }
  storageFor(name) {
    if (!this.stores.has(name)) this.stores.set(name, new MemoryTransactionalStorage());
    return this.stores.get(name);
  }

  get(name) {
    // Recreate the production handler on every request; only durable storage survives.
    const handler = () => new WakeRegistrationStore(
      { storage: this.storageFor(name) }, this.env, this.providerOptions,
    );
    return {
      fetch: (request) => handler().fetch(request),
      bootstrap: (handle, record) => handler().bootstrap(handle, record),
      wake: (handle) => handler().wake(handle),
    };
  }
}

const storage = (env, name = handle) => env.WAKE_REGISTRATION_AUTHORITY.storageFor(name);
const storedRecord = (env, name = handle) => storage(env, name).values.get('registration')?.record ?? null;

test('many unknown wake handles never activate handle objects or grow the registration index', async () => {
  const env = environment();
  env.WAKE_REQUESTS_PER_MINUTE = '20';
  env.WAKE_SOURCE_REQUESTS_PER_MINUTE = '5';
  const worker = createWorker({ accessToken: async () => { throw new Error('unexpected OAuth'); } });
  for (let index = 0; index < 250; index += 1) {
    const unknown = `${index}`.padStart(43, 'Z');
    const input = request(`/v1/wakes/${unknown}`, { method: 'POST' });
    input.headers.set('cf-connecting-ip', `192.0.2.${index % 10 + 1}`);
    const response = await worker.fetch(input, env);
    assert.equal(response.status, 202);
    assert.equal(await response.text(), '');
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
  assert.equal(env.WAKE_REGISTRATION_AUTHORITY.stores.size, 0);
  assert.equal(env.admissionStorage.values.size, 1);
  assert.equal(env.admissionStorage.values.get('requests').times.length, 20);
});

test('fixed admission quotas serialize sources, survive reconstruction and roll over without handle allocation', async () => {
  const env = environment();
  env.WAKE_REQUESTS_PER_MINUTE = '3';
  env.WAKE_SOURCE_REQUESTS_PER_MINUTE = '2';
  let now = 100000;
  const gate = () => new WakeAdmissionStore({ storage: env.admissionStorage }, env, { now: () => now });
  const outcomes = await Promise.all(Array.from({ length: 10 }, () => gate().admit(secret, handle)));
  assert.equal(outcomes.filter((value) => value === 'unknown').length, 2);
  assert.equal(await gate().admit('C'.repeat(43), handle), 'unknown');
  assert.equal(await gate().admit('D'.repeat(43), handle), false);
  now += 60000;
  assert.equal(await gate().admit(secret, handle), 'unknown');
  assert.equal(env.admissionStorage.values.get('requests').times.length, 1);
  assert.equal(env.admissionStorage.values.has(`handle:${handle}`), false);
});

test('admission source and handle capacity fails closed while recognized ownership and deletion remain usable', async () => {
  const env = environment();
  env.WAKE_SOURCE_CAPACITY = '1';
  env.WAKE_HANDLE_CAPACITY = '1';
  const worker = createWorker({ accessToken: async () => 'access', fetchImpl: async () => new Response() });
  const put = (name = handle) => worker.fetch(request(`/v1/registrations/${name}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env);
  assert.equal((await put()).status, 204);
  assert.equal((await put('C'.repeat(43))).status, 503);
  assert.equal(env.WAKE_REGISTRATION_AUTHORITY.stores.size, 1);
  const other = request(`/v1/registrations/${handle}`, { method: 'DELETE', bearer: secret });
  other.headers.set('cf-connecting-ip', '192.0.2.2');
  assert.equal((await worker.fetch(other, env)).status, 503);
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  }), env)).status, 204);
  assert.equal((await put()).status, 410);
  assert.equal((await put('C'.repeat(43))).status, 204);
  assert.equal(env.admissionStorage.values.get('handle-count'), 1);
});

test('orphaned claims and inactive leases release finite capacity', async () => {
  const env = environment();
  env.WAKE_HANDLE_CAPACITY = '1';
  let now = 100000;
  const gate = () => new WakeAdmissionStore({ storage: env.admissionStorage }, env, { now: () => now });
  const second = 'C'.repeat(43);
  assert.equal(await gate().admit(secret, handle, true), true);
  assert.equal(await gate().admit(secret, second, true), false);
  now += 5 * 60 * 1000 + 1;
  assert.equal(await gate().admit(secret, second, true), true);
  assert.equal(env.admissionStorage.values.has(`handle:${handle}`), false);
  assert.equal(env.admissionStorage.values.get('handle-count'), 1);
  assert.equal(await gate().activate(second), true);
  now += 31 * 24 * 60 * 60 * 1000;
  assert.equal(await gate().admit(secret, handle, true), true);
  assert.equal(env.admissionStorage.values.has(`handle:${second}`), false);
  assert.equal(env.admissionStorage.values.get('handle-count'), 1);
});

test('failed slot release leaves a deleted handle retryable without reviving it', async () => {
  const env = environment();
  const worker = createWorker();
  const put = request(`/v1/registrations/${handle}`, { method: 'PUT', bearer: secret, body: { token } });
  assert.equal((await worker.fetch(put, env)).status, 204);
  const original = env.WAKE_ADMISSION.get;
  env.WAKE_ADMISSION.get = () => ({
    admit: (...args) => original().admit(...args),
    activate: (...args) => original().activate(...args),
    release: async () => false,
  });
  const remove = () => worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  }), env);
  assert.equal((await remove()).status, 503);
  assert.equal(storedRecord(env), null);
  assert.equal(env.admissionStorage.values.get('handle-count'), 1);
  env.WAKE_ADMISSION.get = original;
  assert.equal((await remove()).status, 204);
  assert.equal(env.admissionStorage.values.get('handle-count'), 0);
});

test('missing limits, trusted source or admission binding suppress wakes before handle objects', async () => {
  for (const mode of ['quota', 'source', 'binding', 'storage']) {
    const env = environment();
    const input = request(`/v1/wakes/${handle}`, { method: 'POST' });
    if (mode === 'quota') env.WAKE_REQUESTS_PER_MINUTE = '0';
    if (mode === 'source') input.headers.delete('cf-connecting-ip');
    if (mode === 'binding') delete env.WAKE_ADMISSION;
    if (mode === 'storage') env.admissionStorage.failCommit = true;
    assert.equal((await createWorker().fetch(input, env)).status, 202);
    assert.equal(env.WAKE_REGISTRATION_AUTHORITY.stores.size, 0);
    assert.equal(env.admissionStorage.values.size, 0);
  }
});

function request(path, { method = 'GET', bearer = '', body } = {}) {
  const headers = new Headers();
  headers.set('cf-connecting-ip', '192.0.2.1');
  if (bearer) headers.set('authorization', `Bearer ${bearer}`);
  if (body !== undefined) headers.set('content-type', 'application/json');
  return new Request(`https://wake.example${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function environment(kv = new MemoryKv(), phase = 'complete') {
  const env = {
    WAKE_REGISTRATIONS: kv,
    // This fixture has a verified empty legacy namespace, unlike a production cutover.
    WAKE_REGISTRATION_MIGRATION: phase,
    WAKE_REQUESTS_PER_MINUTE: '100000',
    WAKE_SOURCE_REQUESTS_PER_MINUTE: '100000',
    WAKE_SOURCE_CAPACITY: '1000',
    WAKE_HANDLE_CAPACITY: '10000',
    FIREBASE_PROJECT_ID: 'sybl-test',
    FIREBASE_CLIENT_EMAIL: 'sender@sybl-test.iam.gserviceaccount.com',
    FIREBASE_PRIVATE_KEY: 'unused-by-test-token-provider',
  };
  env.WAKE_REGISTRATION_AUTHORITY = new MemoryAuthority(env);
  env.admissionStorage = new MemoryTransactionalStorage();
  env.WAKE_ADMISSION = {
    idFromName: (name) => { assert.equal(name, 'provider-wide-v1'); return name; },
    get: () => new WakeAdmissionStore({ storage: env.admissionStorage }, env),
    activate: (handle) => new WakeAdmissionStore({ storage: env.admissionStorage }, env).activate(handle),
    release: (handle) => new WakeAdmissionStore({ storage: env.admissionStorage }, env).release(handle),
  };
  return env;
}

test('registration stores a secret hash and never stores the bearer secret', async () => {
  const env = environment();
  const worker = createWorker({ accessToken: async () => 'access' });

  const response = await worker.fetch(
    request(`/v1/registrations/${handle}`, {
      method: 'PUT',
      bearer: secret,
      body: { token },
    }),
    env,
  );

  assert.equal(response.status, 204);
  const saved = storedRecord(env);
  assert.equal(saved.token, token);
  assert.notEqual(saved.secretHash, secret);
  assert.equal(JSON.stringify(saved).includes(secret), false);
});

test('registration update and delete require the first registration secret', async () => {
  const env = environment();
  const worker = createWorker({ accessToken: async () => 'access' });
  const first = request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  });
  assert.equal((await worker.fetch(first, env)).status, 204);

  const rejected = request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: 'C'.repeat(43), body: { token: `${token}-new` },
  });
  assert.equal((await worker.fetch(rejected, env)).status, 401);

  const removed = request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  });
  assert.equal((await worker.fetch(removed, env)).status, 204);
  assert.equal(storedRecord(env), null);
});

test('wake always returns accepted and sends only the fixed data marker', async () => {
  const env = environment();
  const calls = [];
  const worker = createWorker({
    accessToken: async () => 'access-token',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      return new Response(JSON.stringify({ name: 'ok' }), { status: 200 });
    },
  });
  await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env);

  const known = await worker.fetch(
    request(`/v1/wakes/${handle}`, { method: 'POST' }), env,
  );
  const unknown = await worker.fetch(
    request(`/v1/wakes/${'D'.repeat(43)}`, { method: 'POST' }), env,
  );

  assert.equal(known.status, 202);
  assert.equal(unknown.status, 202);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://fcm.googleapis.com/v1/projects/sybl-test/messages:send');
  const payload = JSON.parse(calls[0].options.body);
  assert.deepEqual(payload, {
    message: {
      token,
      data: { w: '1' },
      android: { priority: 'high', ttl: '60s' },
    },
  });
  assert.equal(JSON.stringify(payload).includes(handle), false);
});

test('wake hides FCM failure and malformed requests fail closed', async () => {
  const env = environment();
  const worker = createWorker({
    accessToken: async () => 'access-token',
    fetchImpl: async () => new Response('no', { status: 503 }),
  });
  await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env);

  assert.equal((await worker.fetch(
    request(`/v1/wakes/${handle}`, { method: 'POST' }), env,
  )).status, 202);
  assert.equal((await worker.fetch(
    request('/v1/registrations/not-a-handle', {
      method: 'PUT', bearer: secret, body: { token },
    }), env,
  )).status, 404);
  assert.equal((await worker.fetch(
    request(`/v1/registrations/${handle}`, {
      method: 'PUT', bearer: secret, body: { token: '' },
    }), env,
  )).status, 400);
});

const unregisteredResponse = () => Response.json({
  error: {
    code: 404,
    status: 'NOT_FOUND',
    details: [{
      '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
      errorCode: 'UNREGISTERED',
    }],
  },
}, { status: 404 });

test('confirmed unregistered FCM token is removed while its registration owner is retained', async () => {
  let now = Date.now();
  const env = environment();
  let providerCalls = 0;
  let authorizationCalls = 0;
  let response = unregisteredResponse;
  const worker = createWorker({
    now: () => now,
    accessToken: async () => { authorizationCalls += 1; return 'synthetic-access-token'; },
    fetchImpl: async () => { providerCalls += 1; return response(); },
  });
  const put = (owner = secret, nextToken = token) => worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: owner, body: { token: nextToken },
  }), env);
  const wake = () => worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env);
  assert.equal((await put()).status, 204);
  const original = structuredClone(storedRecord(env));
  assert.equal((await wake()).status, 202);
  assert.deepEqual(storedRecord(env), { token: null, secretHash: original.secretHash });
  assert.equal(storage(env).values.get('registration').revision, 2);
  assert.equal((await wake()).status, 202);
  assert.equal(providerCalls, 1);
  assert.equal(authorizationCalls, 1);
  assert.equal((await put('C'.repeat(43), `${token}-new-owner`)).status, 401);
  assert.equal((await put(secret, `${token}-refreshed`)).status, 204);
  response = () => new Response(null, { status: 200 });
  now += 10000;
  assert.equal((await wake()).status, 202);
  assert.equal(providerCalls, 2);
  assert.equal(storedRecord(env).token, `${token}-refreshed`);
});

test('late unregistered response cannot retire a replacement registration or same-token ABA', async (t) => {
  for (const mutation of ['none', 'rotate', 'delete', 'delete-and-recreate', 'rotate-away-and-back']) {
    await t.test(mutation, async () => {
      const env = environment();
      let enterProvider;
      let releaseProvider;
      const entered = new Promise((resolve) => { enterProvider = resolve; });
      const released = new Promise((resolve) => { releaseProvider = resolve; });
      const worker = createWorker({
        accessToken: async () => 'synthetic-access-token',
        fetchImpl: async () => { enterProvider(); await released; return unregisteredResponse(); },
      });
      const put = (nextToken = token, owner = secret) => worker.fetch(request(`/v1/registrations/${handle}`, {
        method: 'PUT', bearer: owner, body: { token: nextToken },
      }), env);
      assert.equal((await put()).status, 204);
      const pending = worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env);
      await entered;
      if (mutation.startsWith('delete')) {
        assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
          method: 'DELETE', bearer: secret,
        }), env)).status, 204);
      } else if (mutation !== 'none') {
        assert.equal((await put(`${token}-rotated`)).status, 204);
      }
      if (mutation === 'delete-and-recreate') assert.equal((await put(token, 'C'.repeat(43))).status, 410);
      if (mutation === 'rotate-away-and-back') assert.equal((await put()).status, 204);
      const before = structuredClone(storage(env).values);
      releaseProvider();
      assert.equal((await pending).status, 202);
      if (mutation === 'none') {
        assert.deepEqual(storedRecord(env), { token: null, secretHash: before.get('registration').record.secretHash });
      } else {
        assert.deepEqual(storage(env).values, before);
      }
    });
  }
});

test('ambiguous, transient, corrupt and failed provider responses cannot retire a token', async (t) => {
  const body = await unregisteredResponse().json();
  const cases = [
    ...[200, 400, 401, 403, 429, 500, 503].map((status) => [
      `HTTP ${status}`, () => Response.json(body, { status }),
    ]),
    ['no typed detail', () => Response.json({ error: { code: 404, status: 'NOT_FOUND' } }, { status: 404 })],
    ['wrong type', () => Response.json({ error: { ...body.error, details: [
      { '@type': 'type.googleapis.com/google.rpc.ErrorInfo', errorCode: 'UNREGISTERED' },
    ] } }, { status: 404 })],
    ['conflicting typed details', () => Response.json({ error: { ...body.error, details: [
      ...body.error.details, { ...body.error.details[0], errorCode: 'INTERNAL' },
    ] } }, { status: 404 })],
    ['wrong structured code', () => Response.json({ error: { ...body.error, code: 403 } }, { status: 404 })],
    ['wrong structured status', () => Response.json({ error: { ...body.error, status: 'PERMISSION_DENIED' } }, { status: 404 })],
    ['invalid argument', () => Response.json({ error: { ...body.error, details: [
      { ...body.error.details[0], errorCode: 'INVALID_ARGUMENT' },
    ] } }, { status: 404 })],
    ['invalid JSON', () => new Response('{', { status: 404 })],
    ['JSON null', () => new Response('null', { status: 404 })],
    ['invalid UTF-8', () => {
      const prefix = new TextEncoder().encode('{"message":"');
      const suffix = new TextEncoder().encode('",' + JSON.stringify(body).slice(1));
      return new Response(new Uint8Array([...prefix, 0xff, ...suffix]), { status: 404 });
    }],
    ['body read failure', () => new Response(new ReadableStream({
      start(controller) { controller.error(new Error('synthetic provider body failure')); },
    }), { status: 404 })],
    ['network failure', () => { throw new Error('synthetic provider network failure'); }],
  ];
  for (const [name, response] of cases) {
    await t.test(name, async () => {
      const env = environment();
      const worker = createWorker({
        accessToken: async () => 'synthetic-access-token', fetchImpl: async () => response(),
      });
      assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
        method: 'PUT', bearer: secret, body: { token },
      }), env)).status, 204);
      const before = structuredClone(storage(env).values);
      assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
      assert.deepEqual(storage(env).values.get('registration'), before.get('registration'));
      assert.equal(storage(env).values.get('wake-admission').length, 1);
    });
  }
});

test('unregistered response parsing stops at its byte bound without token retirement', async () => {
  const env = environment();
  let pulls = 0;
  let cancelled = false;
  const worker = createWorker({
    accessToken: async () => 'synthetic-access-token',
    fetchImpl: async () => new Response(new ReadableStream({
      pull(controller) {
        pulls += 1;
        if (pulls === 1) controller.enqueue(new TextEncoder().encode(' '.repeat(8193)));
        else controller.enqueue(new TextEncoder().encode('{"unread":"tail"}'));
      },
      cancel() { cancelled = true; },
    }, { highWaterMark: 0 }), { status: 404 }),
  });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 204);
  const before = structuredClone(storage(env).values);
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  assert.equal(pulls, 1);
  assert.equal(cancelled, true);
  assert.deepEqual(storage(env).values.get('registration'), before.get('registration'));
      assert.equal(storage(env).values.get('wake-admission').length, 1);
});

test('token replacement during provider body parsing is checked again at cleanup commit', async () => {
  const env = environment();
  let enterBody;
  let releaseBody;
  const entered = new Promise((resolve) => { enterBody = resolve; });
  const released = new Promise((resolve) => { releaseBody = resolve; });
  const bytes = new TextEncoder().encode(await unregisteredResponse().text());
  const worker = createWorker({
    accessToken: async () => 'synthetic-access-token',
    fetchImpl: async () => new Response(new ReadableStream({
      async pull(controller) {
        enterBody();
        await released;
        controller.enqueue(bytes);
        controller.close();
      },
    }, { highWaterMark: 0 }), { status: 404 }),
  });
  const put = (nextToken) => worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token: nextToken },
  }), env);
  assert.equal((await put(token)).status, 204);
  const pending = worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env);
  await entered;
  assert.equal((await put(`${token}-new`)).status, 204);
  const before = structuredClone(storage(env).values);
  releaseBody();
  assert.equal((await pending).status, 202);
  assert.deepEqual(storage(env).values, before);
});

test('failed invalid-token cleanup commit preserves the owner and can retry', async () => {
  const env = environment();
  let now = Date.now();
  let failCleanup = true;
  const worker = createWorker({
    now: () => now,
    accessToken: async () => 'synthetic-access-token',
    fetchImpl: async () => {
      // Admission and submission succeeded; fail only the terminal retirement.
      storage(env).failCommit = failCleanup;
      return unregisteredResponse();
    },
  });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 204);
  const before = structuredClone(storage(env).values);
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  assert.deepEqual(storage(env).values.get('registration'), before.get('registration'));
  assert.equal(storage(env).values.get('wake-submissions').length, 1);
  failCleanup = false;
  storage(env).failCommit = false;
  now += 10000;
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  assert.deepEqual(storedRecord(env), { token: null, secretHash: before.get('registration').record.secretHash });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: 'C'.repeat(43),
  }), env)).status, 401);
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  }), env)).status, 204);
  assert.equal(storedRecord(env), null);
});

test('completed deletion or rotation retires a wake waiting for OAuth', async (t) => {
  for (const mutation of ['delete', 'rotate', 'delete-and-recreate', 'rotate-away-and-back']) {
    await t.test(mutation, async () => {
      let now = Date.now();
      const env = environment();
      let enterOAuth;
      let releaseOAuth;
      const entered = new Promise((resolve) => { enterOAuth = resolve; });
      const released = new Promise((resolve) => { releaseOAuth = resolve; });
      const providerRequests = [];
      const worker = createWorker({
        now: () => now,
        accessToken: async () => { enterOAuth(); await released; return 'synthetic-access-token'; },
        fetchImpl: async (url, options) => {
          providerRequests.push({ url: String(url), body: JSON.parse(options.body) });
          return new Response();
        },
      });
      const put = (nextToken = token) => worker.fetch(request(`/v1/registrations/${handle}`, {
        method: 'PUT', bearer: secret, body: { token: nextToken },
      }), env);
      assert.equal((await put()).status, 204);
      const pendingWake = worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env);
      await entered;
      if (mutation.startsWith('delete')) {
        assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
          method: 'DELETE', bearer: secret,
        }), env)).status, 204);
      } else {
        assert.equal((await put(`${token}-rotated`)).status, 204);
      }
      if (mutation === 'delete-and-recreate' || mutation === 'rotate-away-and-back') {
        assert.equal((await put()).status, mutation === 'delete-and-recreate' ? 410 : 204);
      }
      releaseOAuth();
      assert.equal((await pendingWake).status, 202);
      assert.deepEqual(providerRequests, []);
      if (mutation !== 'delete' && mutation !== 'delete-and-recreate') {
        now += 10000;
        assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
        assert.equal(providerRequests.length, 1);
        assert.equal(providerRequests[0].body.message.token, storedRecord(env).token);
      }
    });
  }
});

test('wake final storage faults and changed authority fail closed', async (t) => {
  for (const fault of ['missing API', 'read throws', 'missing row', 'corrupt row',
    'changed owner', 'changed token', 'changed revision']) {
    await t.test(fault, async () => {
      const env = environment();
      let providerCalls = 0;
      const worker = createWorker({
        accessToken: async () => 'synthetic-access-token',
        fetchImpl: async () => { providerCalls += 1; return new Response(); },
      });
      assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
        method: 'PUT', bearer: secret, body: { token },
      }), env)).status, 204);
      const before = structuredClone(storage(env).values);
      if (fault === 'missing API') {
        storage(env).kv = undefined;
      } else {
        storage(env).kv.get = () => {
          if (fault === 'read throws') throw new Error('synthetic final read failure');
          if (fault === 'missing row') return undefined;
          if (fault === 'corrupt row') return { version: 1, handle, record: {} };
          const changed = structuredClone(before.get('registration'));
          if (fault === 'changed owner') changed.record.secretHash = 'D'.repeat(43);
          if (fault === 'changed token') changed.record.token = `${token}-different`;
          if (fault === 'changed revision') changed.revision += 1;
          return changed;
        };
      }
      assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
      assert.equal(providerCalls, 0);
      assert.deepEqual(storage(env).values.get('registration'), before.get('registration'));
      assert.equal(storage(env).values.get('wake-admission').length, 1);
    });
  }
});

test('deletion can complete while an already submitted provider request remains pending', async () => {
  const env = environment();
  let enterProvider;
  let releaseProvider;
  const entered = new Promise((resolve) => { enterProvider = resolve; });
  const released = new Promise((resolve) => { releaseProvider = resolve; });
  let providerCalls = 0;
  const worker = createWorker({
    accessToken: async () => 'synthetic-access-token',
    fetchImpl: async () => {
      providerCalls += 1;
      enterProvider();
      await released;
      return new Response();
    },
  });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 204);
  const pendingWake = worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env);
  await entered;
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  }), env)).status, 204);
  assert.equal(storedRecord(env), null);
  releaseProvider();
  assert.equal((await pendingWake).status, 202);
  assert.equal(providerCalls, 1);
});

test('provider fetch keeps its free-function receiver at the native adapter boundary', async () => {
  const env = environment();
  let observedReceiver = 'not called';
  let providerCalls = 0;
  const worker = createWorker({
    accessToken: async () => 'synthetic-access-token',
    // Workerd's native fetch rejects a Store receiver. This matches the actual
    // runtime adapter probe; an arrow function would hide that failure.
    fetchImpl: async function () {
      observedReceiver = this;
      if (this !== undefined) throw new TypeError('Illegal invocation');
      providerCalls += 1;
      return new Response();
    },
  });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 204);
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  assert.equal(observedReceiver, undefined);
  assert.equal(providerCalls, 1);
});

test('no asynchronous gap separates final authority check and provider submission', async () => {
  const env = environment();
  const events = [];
  let deleted;
  const deletionCompleted = new Promise((resolve) => { deleted = resolve; });
  const worker = createWorker({
    accessToken: async () => 'synthetic-access-token',
    fetchImpl: async () => { events.push('provider submitted'); return new Response(); },
  });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 204);
  storage(env).kv.get = (key) => {
    const current = structuredClone(storage(env).values.get(key));
    if (key !== 'registration') return current;
    queueMicrotask(async () => {
      events.push('later event began');
      const response = await worker.fetch(request(`/v1/registrations/${handle}`, {
        method: 'DELETE', bearer: secret,
      }), env);
      events.push(`delete completed ${response.status}`);
      deleted();
    });
    return current;
  };
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  await deletionCompleted;
  assert.deepEqual(events, ['provider submitted', 'later event began', 'delete completed 204']);
});

test('pre-revision rows remain readable and each later change gets a checked revision', async () => {
  const env = environment();
  const original = await seedLegacy(new MemoryKv());
  storage(env).values.set('registration', { version: 1, handle, record: original });
  await env.WAKE_ADMISSION.get().reserve(handle);
  let providerCalls = 0;
  const worker = createWorker({
    accessToken: async () => 'synthetic-access-token',
    fetchImpl: async () => { providerCalls += 1; return new Response(); },
  });
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  assert.equal(providerCalls, 0);
  assert.equal(storedRecord(env).token, null);
  const put = () => worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token: `${token}-updated` },
  }), env);
  assert.equal((await put()).status, 204);
  assert.equal(storage(env).values.get('registration').revision, 2);
  for (const revision of [0, -1, 1.5, '1', Number.MAX_SAFE_INTEGER]) {
    storage(env).values.set('registration', { version: 1, handle, record: original, revision });
    const before = structuredClone(storage(env).values);
    assert.equal((await put()).status, 503);
    assert.deepEqual(storage(env).values, before);
  }
});

test('revisionless deletion tombstone cannot regain ownership or an admission slot', async () => {
  const env = environment();
  const old = { version: 1, handle, record: null };
  storage(env).values.set('registration', structuredClone(old));
  const worker = createWorker();
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 410);
  assert.deepEqual(storage(env).values.get('registration'), old);
  assert.equal(env.admissionStorage.values.get('handle-count'), 0);
  env.WAKE_REGISTRATION_MIGRATION = 'importing';
  assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(
    handle, await seedLegacy(new MemoryKv())), 409);
  assert.equal(env.admissionStorage.values.get('handle-count'), 0);
});

test('failed or corrupt storage reads cannot replace or delete a registration', async (t) => {
  const cases = [
    ['read failure', () => { throw new Error('synthetic KV read failure'); }],
    ['unexpected missing value', () => null],
    ['invalid JSON', () => '{'],
    ['JSON null', () => 'null'],
    ['missing fields', () => '{}'],
    ['invalid token', () => ({ version: 1, handle, record: { token: '', secretHash: 'D'.repeat(43) } })],
    ['invalid hash', () => ({ version: 1, handle, record: { token, secretHash: 'bad-hash' } })],
  ];
  for (const [name, read] of cases) {
    for (const method of ['PUT', 'DELETE']) {
      await t.test(`${method}: ${name}`, async () => {
        const kv = new MemoryKv();
        const env = environment(kv);
        const worker = createWorker();
        await worker.fetch(request(`/v1/registrations/${handle}`, {
          method: 'PUT', bearer: secret, body: { token },
        }), env);
        const before = structuredClone(storage(env).values);
        storage(env).get = async () => read();

        const response = await worker.fetch(request(`/v1/registrations/${handle}`, {
          method, bearer: 'C'.repeat(43),
          body: method === 'PUT' ? { token: `${token}-new` } : undefined,
        }), env);

        assert.equal(response.status, 503);
        assert.equal(await response.text(), '');
        assert.equal(response.headers.get('cache-control'), 'no-store');
        assert.deepEqual(storage(env).values, before);
      });
    }
  }
});

test('storage failures leave wake responses accepted with no provider request', async () => {
  for (const read of [
    () => { throw new Error('synthetic KV read failure'); },
    () => JSON.stringify({ token, secretHash: 'bad-hash' }),
  ]) {
    const env = environment();
    storage(env).get = async () => read();
    const pending = [];
    let providerCalls = 0;
    const worker = createWorker({
      accessToken: async () => { providerCalls += 1; return 'access'; },
      fetchImpl: async () => { providerCalls += 1; return new Response(); },
    });
    for (const context of [{}, { waitUntil: (promise) => pending.push(promise) }]) {
      const response = await worker.fetch(
        request(`/v1/wakes/${handle}`, { method: 'POST' }), env, context,
      );
      assert.equal(response.status, 202);
      assert.equal(await response.text(), '');
    }
    await Promise.all(pending);
    assert.equal(providerCalls, 0);
  }
});

test('clean absence permits registration and repeated deletion; the owner can update', async () => {
  const env = environment();
  const worker = createWorker();
  const remove = () => request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  });
  assert.equal((await worker.fetch(remove(), env)).status, 204);
  for (const nextToken of [token, `${token}-new`]) {
    assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
      method: 'PUT', bearer: secret, body: { token: nextToken },
    }), env)).status, 204);
    assert.equal(storedRecord(env).token, nextToken);
  }
  assert.equal((await worker.fetch(remove(), env)).status, 204);
  assert.equal((await worker.fetch(remove(), env)).status, 204);
});

function streamedRequest(path, chunks, { method = 'PUT', headers = {} } = {}) {
  let reads = 0;
  let cancelled = false;
  const body = new ReadableStream({
    pull(controller) {
      if (reads === chunks.length) controller.close();
      else controller.enqueue(chunks[reads++]);
    },
    cancel() { cancelled = true; },
  }, { highWaterMark: 0 });
  return {
    request: new Request(`https://wake.example${path}`, {
      method, headers: { authorization: `Bearer ${secret}`, 'cf-connecting-ip': '192.0.2.1', ...headers }, body, duplex: 'half',
    }),
    reads: () => reads,
    cancelled: () => cancelled,
  };
}

test('registration accepts the full token range, including maximally escaped JSON', async () => {
  const env = environment();
  const worker = createWorker();
  const wire = '{"\\u0074\\u006f\\u006b\\u0065\\u006e":"' + '\\u0000'.repeat(4096) + '"}';
  const escaped = streamedRequest(`/v1/registrations/${handle}`, [new TextEncoder().encode(wire)]);
  assert.equal((await worker.fetch(escaped.request, env)).status, 204);
  assert.equal(storedRecord(env).token, '\0'.repeat(4096));
  for (const nextToken of ['A'.repeat(20), 'A'.repeat(4096), '😀'.repeat(2048)]) {
    assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
      method: 'PUT', bearer: secret, body: { token: nextToken },
    }), env)).status, 204);
  }
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token: 'A'.repeat(4097) },
  }), env)).status, 400);
});

test('registration rejects excess bytes before consuming or parsing the full stream', async () => {
  const env = environment();
  let storageReads = 0;
  storage(env).get = async () => { storageReads += 1; return undefined; };
  const worker = createWorker();
  const input = streamedRequest(`/v1/registrations/${handle}`, [
    new TextEncoder().encode(' '.repeat(25000)),
    new TextEncoder().encode(JSON.stringify({ token })),
  ], { headers: { 'content-length': '0' } });

  const response = await worker.fetch(input.request, env);
  assert.equal(response.status, 413);
  assert.equal(input.reads(), 1);
  assert.equal(input.cancelled(), true);
  assert.equal(storageReads, 0);
  assert.equal(storage(env).values.size, 0);
});

test('registration counts UTF-8 bytes and preserves split UTF-8 input', async () => {
  const env = environment();
  const worker = createWorker();
  const oversized = streamedRequest(`/v1/registrations/${handle}`, [
    new TextEncoder().encode(JSON.stringify({ token, extra: 'é'.repeat(12500) })),
  ]);
  assert.equal((await worker.fetch(oversized.request, env)).status, 413);
  assert.equal(storage(env).values.size, 0);

  const nextToken = 'é'.repeat(20);
  const bytes = new TextEncoder().encode(JSON.stringify({ token: nextToken }));
  const split = streamedRequest(`/v1/registrations/${handle}`, [bytes.subarray(0, 11), bytes.subarray(11)]);
  assert.equal((await worker.fetch(split.request, env)).status, 204);
  assert.equal(storedRecord(env).token, nextToken);
});

test('wake rejects nonempty bodies before storage or provider access', async () => {
  const env = environment();
  let storageReads = 0;
  let providerCalls = 0;
  storage(env).get = async () => { storageReads += 1; return undefined; };
  const worker = createWorker({
    accessToken: async () => { providerCalls += 1; return 'access'; },
    fetchImpl: async () => { providerCalls += 1; return new Response(); },
  });
  for (const value of ['{}', ' ', '\0']) {
    const input = streamedRequest(`/v1/wakes/${handle}`, [new TextEncoder().encode(value)], {
      method: 'POST', headers: { 'content-length': '0' },
    });
    assert.equal((await worker.fetch(input.request, env)).status, 400);
    assert.equal(input.cancelled(), true);
  }
  assert.equal(storageReads, 0);
  assert.equal(providerCalls, 0);
  const emptyStream = streamedRequest(`/v1/wakes/${handle}`, [], { method: 'POST' });
  assert.equal((await worker.fetch(emptyStream.request, env)).status, 202);
});

test('concurrent first claims by different secrets cannot both become owners', { timeout: 2000 }, async () => {
  const kv = new MemoryKv();
  const reads = [];
  kv.get = () => new Promise((resolve) => {
    reads.push(resolve);
    if (reads.length === 2) for (const release of reads) release(null);
  });
  const env = environment(kv);
  const durableReads = [];
  storage(env).get = () => new Promise((resolve) => {
    durableReads.push(resolve);
    if (durableReads.length === 2) for (const release of durableReads) release(undefined);
  });
  const workers = [createWorker(), createWorker()];
  const responses = await Promise.all(workers.map((worker, index) => worker.fetch(
    request(`/v1/registrations/${handle}`, {
      method: 'PUT', bearer: index === 0 ? secret : 'C'.repeat(43),
      body: { token: `${token}-${index}` },
    }), env,
  )));
  assert.deepEqual(responses.map((response) => response.status).sort(), [204, 401]);
});

test('stale legacy KV absence cannot replace an established registration owner', async () => {
  const kv = new MemoryKv();
  const env = environment(kv);
  const worker = createWorker();
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 204);
  kv.get = async () => null;
  const response = await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: 'C'.repeat(43), body: { token: `${token}-replacement` },
  }), env);
  assert.equal(response.status, 401);
});

async function seedLegacy(kv, ownerSecret = secret) {
  const secretHash = Buffer.from(await crypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(ownerSecret),
  )).toString('base64url');
  const record = { token, secretHash };
  kv.values.set(handle, JSON.stringify(record));
  return record;
}

test('unapproved migration phases cannot turn legacy absence into new ownership', async () => {
  for (const phase of [undefined, 'blocked', 'unknown', 'importing']) {
    const env = environment();
    env.WAKE_REGISTRATION_MIGRATION = phase;
    const worker = createWorker();
    for (const method of ['PUT', 'DELETE']) {
      const response = await worker.fetch(request(`/v1/registrations/${handle}`, {
        method, bearer: secret, body: method === 'PUT' ? { token } : undefined,
      }), env);
      assert.equal(response.status, 503);
      assert.equal(await response.text(), '');
    }
    assert.equal(storage(env).values.size, 0);
  }
});

test('public requests cannot import a deleted handle from stale positive legacy KV', async (t) => {
  // The validated live snapshot omits this deleted handle. An edge KV read can
  // still return its old owner and token; that value cannot authorize an import.
  for (const method of ['POST', 'PUT', 'DELETE']) {
    await t.test(method, async () => {
      const kv = new MemoryKv();
      await seedLegacy(kv);
      const before = structuredClone(kv.values);
      const env = environment(kv, 'importing');
      let providerCalls = 0;
      const worker = createWorker({
        accessToken: async () => { providerCalls += 1; return 'access'; },
        fetchImpl: async () => { providerCalls += 1; return new Response(); },
      });
      const resource = method === 'POST' ? 'wakes' : 'registrations';
      const response = await worker.fetch(request(`/v1/${resource}/${handle}`, {
        method, bearer: secret, body: method === 'PUT' ? { token: `${token}-updated` } : undefined,
      }), env);
      assert.equal(response.status, method === 'POST' ? 202 : 503);
      assert.equal(storage(env).values.size, 0);
      assert.equal(providerCalls, 0);
      assert.deepEqual(kv.values, before);
    });
  }
});

test('legacy read and record failures cannot authorize runtime import', async () => {
  for (const read of [
    () => { throw new Error('synthetic legacy read failure'); },
    () => undefined, () => '{', () => 'null', () => '{}',
    () => JSON.stringify({ token, secretHash: 'invalid' }),
  ]) {
    const kv = new MemoryKv();
    await seedLegacy(kv);
    const before = new Map(kv.values);
    let legacyReads = 0;
    kv.get = async () => { legacyReads += 1; return read(); };
    const env = environment(kv, 'importing');
    let providerCalls = 0;
    const worker = createWorker({ accessToken: async () => { providerCalls += 1; return 'access'; } });
    for (const method of ['PUT', 'DELETE']) {
      assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
        method, bearer: 'C'.repeat(43), body: method === 'PUT' ? { token } : undefined,
      }), env)).status, 503);
    }
    assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
    assert.equal(providerCalls, 0);
    assert.equal(legacyReads, 0);
    assert.deepEqual(kv.values, before);
    assert.equal(storage(env).values.size, 0);
  }
});

test('private bootstrap preserves the snapshot owner and the public Worker cannot read or import records', async () => {
  const kv = new MemoryKv();
  const snapshotRecord = await seedLegacy(kv);
  const env = environment(kv, 'importing');
  // The operator supplies this validated snapshot record. Cold GET is read-only.
  const cold = await env.WAKE_REGISTRATION_AUTHORITY.get(handle).fetch(
    request(`/v1/registrations/${handle}`),
  );
  assert.equal(cold.status, 503);
  assert.equal(storage(env).values.size, 0);
  assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, snapshotRecord), 204);
  const imported = await env.WAKE_REGISTRATION_AUTHORITY.get(handle).fetch(
    request(`/v1/registrations/${handle}`),
  );
  assert.equal(imported.status, 200);
  assert.deepEqual(await imported.json(), snapshotRecord);
  assert.deepEqual(storedRecord(env), snapshotRecord);

  const worker = createWorker();
  const hidden = await worker.fetch(request(`/v1/registrations/${handle}`), env);
  assert.equal(hidden.status, 405);
  assert.equal(await hidden.text(), '');
  for (const [path, status] of [
    [`/v1/registrations/${handle}`, 405],
    [`/v1/bootstrap/${handle}`, 404],
    [`/v1/registrations/${handle}/bootstrap`, 404],
  ]) {
    assert.equal((await worker.fetch(request(path, {
      method: 'POST', body: snapshotRecord,
    }), env)).status, status);
  }
  kv.get = async () => { throw new Error('legacy service is now unavailable'); };
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token: `${token}-updated` },
  }), env)).status, 204);
  assert.equal(storedRecord(env).token, `${token}-updated`);
  assert.deepEqual(JSON.parse(kv.values.get(handle)), snapshotRecord);
});

test('deletion tombstone blocks legacy resurrection and every later claim of its handle', async () => {
  const kv = new MemoryKv();
  const snapshotRecord = await seedLegacy(kv);
  const env = environment(kv, 'importing');
  assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, snapshotRecord), 204);
  let providerCalls = 0;
  const worker = createWorker({ accessToken: async () => { providerCalls += 1; return 'access'; } });
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  }), env)).status, 204);
  assert.deepEqual(storage(env).values.get('registration'), { version: 1, handle, record: null, revision: 2, expiresAt: null });
  assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, snapshotRecord), 409);
  assert.deepEqual(storage(env).values.get('registration'), { version: 1, handle, record: null, revision: 2, expiresAt: null });
  assert.equal((await worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env)).status, 202);
  assert.equal(providerCalls, 0);
  const nextSecret = 'C'.repeat(43);
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: nextSecret, body: { token: `${token}-new-owner` },
  }), env)).status, 503);
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'DELETE', bearer: secret,
  }), env)).status, 503);
  assert.equal(storedRecord(env), null);
});

test('private bootstrap requires the import gate and a valid snapshot record', async () => {
  const snapshotRecord = await seedLegacy(new MemoryKv());
  for (const phase of [undefined, 'blocked', 'unknown', 'complete']) {
    const env = environment();
    env.WAKE_REGISTRATION_MIGRATION = phase;
    assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, snapshotRecord), 503);
    assert.equal(storage(env).values.size, 0);
  }
  for (const record of [null, undefined, {}, { token: '', secretHash: snapshotRecord.secretHash },
    { token, secretHash: 'invalid' }]) {
    const env = environment(new MemoryKv(), 'importing');
    assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, record), 400);
    assert.equal(storage(env).values.size, 0);
  }
  const env = environment(new MemoryKv(), 'importing');
  assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap('invalid', snapshotRecord), 400);
  assert.equal(storage(env).values.size, 0);
});

test('private bootstrap is idempotent but cannot overwrite an existing or updated snapshot owner', async () => {
  const env = environment(new MemoryKv(), 'importing');
  const owner = env.WAKE_REGISTRATION_AUTHORITY.get(handle);
  const first = await seedLegacy(new MemoryKv());
  const second = await seedLegacy(new MemoryKv(), 'C'.repeat(43));
  assert.deepEqual((await Promise.all([
    owner.bootstrap(handle, first), owner.bootstrap(handle, second),
  ])).sort(), [204, 409]);
  const current = storedRecord(env);
  assert.equal(await owner.bootstrap(handle, current), 204);
  assert.deepEqual(storedRecord(env), current);
  const currentSecret = current.secretHash === first.secretHash ? secret : 'C'.repeat(43);
  assert.equal((await createWorker().fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: currentSecret, body: { token: `${token}-updated` },
  }), env)).status, 204);
  assert.equal(await owner.bootstrap(handle, current), 409);
  assert.equal(storedRecord(env).token, `${token}-updated`);
});

test('failed private bootstrap storage operations cannot publish a snapshot record', async () => {
  const snapshotRecord = await seedLegacy(new MemoryKv());
  for (const fault of ['failTransactionRead', 'failCommit']) {
    const env = environment(new MemoryKv(), 'importing');
    storage(env)[fault] = true;
    assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, snapshotRecord), 503);
    assert.equal(storage(env).values.size, 0);
    storage(env)[fault] = false;
    assert.equal(await env.WAKE_REGISTRATION_AUTHORITY.get(handle).bootstrap(handle, snapshotRecord), 204);
    assert.deepEqual(storedRecord(env), snapshotRecord);
  }
});

test('failed durable transaction cannot commit an update or erase its owner', async () => {
  for (const method of ['PUT', 'DELETE']) {
    const env = environment();
    const worker = createWorker();
    assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
      method: 'PUT', bearer: secret, body: { token },
    }), env)).status, 204);
    const before = structuredClone(storage(env).values);
    storage(env).failCommit = true;
    assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
      method, bearer: secret, body: method === 'PUT' ? { token: `${token}-updated` } : undefined,
    }), env)).status, 503);
    assert.deepEqual(storage(env).values, before);
  }
});

test('different handles have separate durable ownership and unknown wakes store no row', async () => {
  const env = environment();
  const worker = createWorker();
  for (const [name, owner] of [[handle, secret], ['D'.repeat(43), 'C'.repeat(43)]]) {
    assert.equal((await worker.fetch(request(`/v1/registrations/${name}`, {
      method: 'PUT', bearer: owner, body: { token: `${token}-${name}` },
    }), env)).status, 204);
  }
  assert.notEqual(storedRecord(env).secretHash, storedRecord(env, 'D'.repeat(43)).secretHash);
  const unknown = 'E'.repeat(43);
  assert.equal((await worker.fetch(request(`/v1/wakes/${unknown}`, { method: 'POST' }), env)).status, 202);
  assert.equal(storage(env, unknown).values.size, 0);
});

test('missing authority binding cannot fall back to legacy KV writes', async () => {
  const env = environment();
  delete env.WAKE_REGISTRATION_AUTHORITY;
  const worker = createWorker();
  assert.equal((await worker.fetch(request(`/v1/registrations/${handle}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env)).status, 503);
  assert.equal(env.WAKE_REGISTRATIONS.values.size, 0);
});

function admissionFixture(overrides = {}) {
  let time = 1800000000000;
  const env = environment();
  env.WAKE_ADMISSION.get = () => new WakeAdmissionStore(
    { storage: env.admissionStorage }, env, { now: () => time },
  );
  const calls = { oauth: 0, provider: 0 };
  const worker = createWorker({
    now: () => time,
    accessToken: async () => { calls.oauth += 1; return 'synthetic-access-token'; },
    fetchImpl: async () => { calls.provider += 1; return new Response(); },
    ...overrides,
  });
  return {
    env, calls, advance: (ms) => { time += ms; },
    alarm: () => new WakeRegistrationStore(
      { storage: storage(env) }, env, { now: () => time },
    ).alarm(),
    reconcile: (name = handle) => new WakeRegistrationStore(
      { storage: storage(env) }, env, { now: () => time },
    ).reconcileExpiry(name),
    put: (owner = secret) => worker.fetch(request(`/v1/registrations/${handle}`, {
      method: 'PUT', bearer: owner, body: { token },
    }), env),
    wake: () => worker.fetch(request(`/v1/wakes/${handle}`, { method: 'POST' }), env),
    remove: () => worker.fetch(request(`/v1/registrations/${handle}`, {
      method: 'DELETE', bearer: secret,
    }), env),
  };
}

test('concurrent wakes reserve one durable slot before OAuth and survive handler reconstruction', async () => {
  const f = admissionFixture();
  await f.put();
  const results = await Promise.all(Array.from({ length: 100 }, () => f.wake()));
  assert.ok(results.every((result) => result.status === 202));
  assert.deepEqual(f.calls, { oauth: 1, provider: 1 });
  f.advance(9999);
  await f.wake();
  assert.equal(f.calls.oauth, 1);
  f.advance(1);
  await f.wake();
  assert.deepEqual(f.calls, { oauth: 2, provider: 2 });
});

test('rolling hour permits at most 60 admissions and renewal cannot reset admission', async () => {
  const f = admissionFixture();
  await f.put();
  for (let index = 0; index < 60; index += 1) {
    await f.wake();
    f.advance(10000);
  }
  assert.equal(f.calls.provider, 60);
  await f.put();
  await f.wake();
  assert.equal(f.calls.oauth, 60);
  assert.equal(storage(f.env).values.get('wake-admission').length, 60);
  f.advance(2999999);
  await f.wake();
  assert.equal(f.calls.provider, 60);
  f.advance(1);
  await f.wake();
  assert.equal(f.calls.provider, 61);
  assert.equal(storage(f.env).values.get('wake-admission').length, 60);
});

test('retired handle never sends another wake or accepts a new owner', async () => {
  const f = admissionFixture();
  await f.put();
  await f.wake();
  await f.remove();
  assert.equal((await f.put('C'.repeat(43))).status, 410);
  await f.wake();
  assert.equal(f.calls.provider, 1);
  f.advance(10000);
  await f.wake();
  assert.equal(f.calls.provider, 1);
});

test('30-day expiry retires only the token and authenticated renewal restores eligibility', async () => {
  const f = admissionFixture();
  await f.put();
  f.advance(30 * 86400000);
  await f.wake();
  assert.deepEqual(f.calls, { oauth: 0, provider: 0 });
  assert.equal(storedRecord(f.env).token, null);
  assert.equal((await f.put('C'.repeat(43))).status, 401);
  assert.equal((await f.put()).status, 204);
  await f.wake();
  assert.equal(f.calls.provider, 1);
});

test('dormant registration alarm retires its token only at the deadline and is idempotent', async () => {
  const f = admissionFixture();
  await f.put();
  const db = storage(f.env);
  const deadline = db.alarmAt;
  assert.equal(deadline, 1800000000000 + 30 * 86400000);
  db.values.set('wake-admission', [1800000000000]);
  db.values.set('wake-submissions', [1800000000000]);
  const owner = storedRecord(f.env).secretHash;
  f.advance(30 * 86400000 - 1);
  await f.alarm();
  assert.equal(storedRecord(f.env).token, token);
  assert.equal(db.alarmAt, deadline);
  f.advance(1);
  await f.alarm();
  assert.deepEqual(storedRecord(f.env), { token: null, secretHash: owner });
  assert.equal(db.alarmAt, null);
  const retired = structuredClone(db.values);
  await f.alarm();
  assert.deepEqual(db.values, retired);
  assert.deepEqual(db.values.get('wake-admission'), [1800000000000]);
  assert.deepEqual(db.values.get('wake-submissions'), [1800000000000]);
  assert.deepEqual(f.calls, { oauth: 0, provider: 0 });
  assert.equal((await f.put('C'.repeat(43))).status, 401);
  assert.equal((await f.put()).status, 204);
  assert.equal(storedRecord(f.env).token, token);
  assert.ok(db.alarmAt > deadline);
});

test('delayed old alarm preserves renewal and deleted tombstones', async () => {
  const f = admissionFixture();
  await f.put();
  f.advance(29 * 86400000);
  await f.put();
  const db = storage(f.env);
  const renewed = structuredClone(db.values);
  const renewedDeadline = db.alarmAt;
  f.advance(86400000);
  await f.alarm();
  assert.deepEqual(db.values, renewed);
  assert.equal(db.alarmAt, renewedDeadline);
  await f.remove();
  const deleted = structuredClone(db.values);
  assert.equal(db.alarmAt, null);
  f.advance(30 * 86400000);
  await f.alarm();
  await f.alarm();
  assert.deepEqual(db.values, deleted);
  assert.equal(storedRecord(f.env), null);
});

test('alarm and registration writes commit atomically and failed expiry retries safely', async () => {
  const f = admissionFixture();
  await f.put();
  const db = storage(f.env);
  const original = structuredClone(db.values);
  const deadline = db.alarmAt;
  f.advance(86400000);
  db.failCommit = true;
  assert.equal((await f.put()).status, 503);
  assert.deepEqual(db.values, original);
  assert.equal(db.alarmAt, deadline);
  assert.equal((await f.remove()).status, 503);
  assert.deepEqual(db.values, original);
  assert.equal(db.alarmAt, deadline);
  f.advance(29 * 86400000);
  await assert.rejects(f.alarm(), /commit failure/);
  assert.deepEqual(db.values, original);
  assert.equal(db.alarmAt, deadline);
  db.failCommit = false;
  await f.alarm();
  assert.equal(storedRecord(f.env).token, null);
  assert.equal(db.alarmAt, null);
});

test('invalid or legacy expiry never acquires new wake authority', async () => {
  for (const expiresAt of [undefined, null, '1800000000000', -1, 1.5, Number.MAX_SAFE_INTEGER]) {
    const f = admissionFixture();
    await f.put();
    storage(f.env).values.get('registration').expiresAt = expiresAt;
    await f.wake();
    assert.equal(f.calls.oauth, 0);
    assert.equal(storedRecord(f.env).token, null);
  }
});

test('private expiry reconciliation is complete-only and has no public route', async () => {
  const f = admissionFixture();
  await f.put();
  const db = storage(f.env);
  db.alarmAt = null;
  const before = structuredClone(db.values);
  for (const phase of ['blocked', 'importing', undefined, 'COMPLETE']) {
    f.env.WAKE_REGISTRATION_MIGRATION = phase;
    assert.equal(await f.reconcile(), 503);
    assert.equal(db.alarmAt, null);
    assert.deepEqual(db.values, before);
  }
  f.env.WAKE_REGISTRATION_MIGRATION = 'complete';
  assert.equal(await f.reconcile('invalid'), 400);
  assert.equal(await f.reconcile('C'.repeat(43)), 503);
  assert.deepEqual(db.values, before);
  assert.equal(db.alarmAt, null);
  const response = await createWorker().fetch(request(`/v1/reconcile/${handle}`, { method: 'POST' }), f.env);
  assert.equal(response.status, 404);
  assert.equal(await f.reconcile(), 204);
  assert.equal(db.alarmAt, db.values.get('registration').expiresAt);
  assert.deepEqual(db.values, before);
  assert.deepEqual(f.calls, { oauth: 0, provider: 0 });
});

test('private reconciliation applies existing expiry policy without assigning legacy dates', async () => {
  for (const expiresAt of [undefined, null, '1800000000000', -1, 1.5, 1800000000000, Number.MAX_SAFE_INTEGER]) {
    const f = admissionFixture();
    await f.put();
    const db = storage(f.env);
    const row = db.values.get('registration');
    row.expiresAt = expiresAt;
    db.alarmAt = null;
    const owner = row.record.secretHash;
    const revision = row.revision;
    assert.equal(await f.reconcile(), 204);
    assert.deepEqual(db.values.get('registration'), {
      ...row, revision: revision + 1, record: { token: null, secretHash: owner },
    });
    assert.equal(db.alarmAt, null);
    const retired = structuredClone(db.values);
    assert.equal(await f.reconcile(), 204);
    assert.deepEqual(db.values, retired);
    assert.deepEqual(f.calls, { oauth: 0, provider: 0 });
  }
});

test('private reconciliation preserves absent, deleted and invalidated owners and clears stale alarms', async () => {
  for (const kind of ['absent', 'deleted', 'invalidated']) {
    const f = admissionFixture();
    if (kind !== 'absent') await f.put();
    const db = storage(f.env);
    if (kind === 'deleted') await f.remove();
    if (kind === 'invalidated') db.values.get('registration').record.token = null;
    db.alarmAt = 1800000000000;
    const before = structuredClone(db.values);
    assert.equal(await f.reconcile(), 204);
    assert.deepEqual(db.values, before);
    assert.equal(f.env.admissionStorage.values.get('handle-count') ?? 0,
      kind === 'invalidated' ? 1 : 0);
    assert.equal(f.env.admissionStorage.values.has(`handle:${handle}`),
      kind === 'invalidated');
    assert.equal(db.alarmAt, null);
  }
});

test('private stale invalidation cannot remove a concurrently renewed wake slot', async () => {
  const f = admissionFixture();
  assert.equal((await f.put()).status, 204);
  storage(f.env).values.get('registration').record.token = null;
  let entered;
  let release;
  const seen = new Promise((resolve) => { entered = resolve; });
  const gate = new Promise((resolve) => { release = resolve; });
  const original = f.env.WAKE_ADMISSION.get;
  f.env.WAKE_ADMISSION.get = () => ({
    admit: (...args) => original().admit(...args),
    activate: (...args) => original().activate(...args),
    retireLegacy: async (...args) => { entered(); await gate; return original().retireLegacy(...args); },
  });
  const pending = f.reconcile();
  await seen;
  assert.equal((await f.put()).status, 204);
  release();
  assert.equal(await pending, 204);
  assert.equal(f.env.admissionStorage.values.get('handle-count'), 1);
  assert.equal((await f.wake()).status, 202);
  assert.equal(f.calls.provider, 1);
});

test('private reconciliation leases imported near-expiry owner to its actual deadline', async () => {
  const env = environment();
  env.WAKE_HANDLE_CAPACITY = '1';
  const initial = await seedLegacy(new MemoryKv());
  const now = Date.now();
  const deadline = now + 2000;
  await env.WAKE_ADMISSION.get().reserve(handle);
  storage(env).values.set('registration', {
    version: 1, handle, record: initial, revision: 1, expiresAt: deadline,
  });
  const registration = (time) => new WakeRegistrationStore(
    { storage: storage(env) }, env, { now: () => time },
  );
  assert.equal(await registration(now).reconcileExpiry(handle), 204);
  assert.equal(env.admissionStorage.values.get(`handle:${handle}`).expiresAt,
    deadline + 60000);
  await registration(deadline + 1).alarm();
  assert.equal(storedRecord(env).token, null);
  const next = new WakeAdmissionStore({ storage: env.admissionStorage }, env,
    { now: () => deadline + 60001 });
  assert.equal(await next.admit(secret, 'C'.repeat(43), true), true);
  assert.equal(env.admissionStorage.values.has(`handle:${handle}`), false);
});

test('private reconciliation rolls back failures and preserves concurrent renewal and deletion', async () => {
  const f = admissionFixture();
  await f.put();
  const db = storage(f.env);
  db.alarmAt = null;
  const original = structuredClone(db.values);
  for (const failure of ['failTransactionRead', 'failCommit']) {
    db[failure] = true;
    assert.equal(await f.reconcile(), 503);
    assert.equal(db.alarmAt, null);
    assert.deepEqual(db.values, original);
    db[failure] = false;
  }
  assert.equal(await f.reconcile(), 204);
  f.advance(30 * 86400000);
  const results = await Promise.all([f.reconcile(), f.put()]);
  assert.equal(results[0], 204);
  assert.equal(results[1].status, 204);
  assert.equal(storedRecord(f.env).token, token);
  assert.equal(db.alarmAt, db.values.get('registration').expiresAt);
  await Promise.all([f.reconcile(), f.remove()]);
  assert.equal(storedRecord(f.env), null);
  assert.equal(db.alarmAt, null);
});

test('expiry is checked again after delayed OAuth', async () => {
  let advance;
  const f = admissionFixture({ accessToken: async () => { advance(); return 'access'; } });
  advance = () => f.advance(30 * 86400000);
  await f.put();
  await f.wake();
  assert.equal(f.calls.provider, 0);
});

test('failed admission or expiry persistence performs no OAuth and retains ownership', async () => {
  for (const expired of [false, true]) {
    const f = admissionFixture();
    await f.put();
    if (expired) f.advance(30 * 86400000);
    const before = structuredClone(storage(f.env).values);
    storage(f.env).failCommit = true;
    await f.wake();
    assert.deepEqual(storage(f.env).values, before);
    assert.equal(f.calls.oauth, 0);
    storage(f.env).failCommit = false;
    await f.wake();
    assert.equal(storedRecord(f.env).token, expired ? null : token);
  }
});

test('malformed admission and backward clocks fail closed without replacing evidence', async () => {
  for (const prior of [null, {}, Array(61).fill(1), [1800000000001], [2, 1], ['1']]) {
    const f = admissionFixture();
    await f.put();
    storage(f.env).values.set('wake-admission', prior);
    const before = structuredClone(storage(f.env).values);
    await f.wake();
    assert.deepEqual(storage(f.env).values, before);
    assert.equal(f.calls.oauth, 0);
  }
});

async function oauthFixture(fetchImpl) {
  const { generateKeyPairSync } = await import('node:crypto');
  const env = environment();
  env.FIREBASE_PRIVATE_KEY = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    publicKeyEncoding: { type: 'spki', format: 'pem' },
  }).privateKey;
  const worker = createWorker({ fetchImpl });
  const put = (name) => worker.fetch(request(`/v1/registrations/${name}`, {
    method: 'PUT', bearer: secret, body: { token },
  }), env);
  await put(handle);
  const second = 'D'.repeat(43);
  await put(second);
  return {
    env, second,
    wake: (name = handle) => worker.fetch(request(`/v1/wakes/${name}`, { method: 'POST' }), env),
  };
}

test('real OAuth signing and parsing are single-flight across handles', async () => {
  let oauthCalls = 0;
  let providerCalls = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const f = await oauthFixture(async (url, options) => {
    if (String(url).includes('oauth2')) {
      oauthCalls += 1;
      await gate;
      return Response.json({ access_token: 'synthetic-token-1234567890', expires_in: 3000 });
    }
    assert.equal(options.headers.authorization, 'Bearer synthetic-token-1234567890');
    providerCalls += 1;
    return new Response();
  });
  const first = f.wake();
  const second = f.wake(f.second);
  release();
  await Promise.all([first, second]);
  assert.equal(oauthCalls, 1);
  assert.equal(providerCalls, 2);
});

test('OAuth rejects oversized and malformed responses before FCM submission', async (t) => {
  for (const [name, response] of [
    ['oversized', () => new Response(' '.repeat(8193))],
    ['invalid JSON', () => new Response('{')],
    ['invalid UTF-8', () => new Response(new Uint8Array([0xff]))],
    ['oversized token', () => Response.json({ access_token: 'a'.repeat(4097) })],
    ['header injection', () => Response.json({ access_token: 'a'.repeat(20) + '\r\n' })],
    ['credential-bearing failure', () => { throw new Error('PRIVATE-SENTINEL'); }],
  ]) {
    await t.test(name, async () => {
      let providerCalls = 0;
      const f = await oauthFixture(async (url) => {
        if (String(url).includes('oauth2')) return response();
        providerCalls += 1;
        return new Response();
      });
      const result = await f.wake();
      assert.equal(result.status, 202);
      assert.equal(await result.text(), '');
      assert.equal(providerCalls, 0);
      assert.equal(storedRecord(f.env).token, token);
    });
  }
});

test('OAuth stalled response body is cancelled at its deadline without provider submission', async (t) => {
  let entered;
  const bodyEntered = new Promise((resolve) => { entered = resolve; });
  let cancelled = false;
  let providerCalls = 0;
  const f = await oauthFixture(async (url) => {
    if (String(url).includes('oauth2')) return new Response(new ReadableStream({
      pull() { entered(); return new Promise(() => {}); },
      cancel() { cancelled = true; },
    }, { highWaterMark: 0 }));
    providerCalls += 1;
    return new Response();
  });
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const pending = f.wake();
  await bodyEntered;
  t.mock.timers.tick(10000);
  assert.equal((await pending).status, 202);
  assert.equal(cancelled, true);
  assert.equal(providerCalls, 0);
});

test('delayed OAuth cannot bunch actual submissions from separately admitted wakes', async () => {
  let release;
  let entered;
  const gate = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { entered = resolve; });
  let authorizations = 0;
  const f = admissionFixture({ accessToken: async () => {
    if (++authorizations === 1) { entered(); await gate; }
    return 'access';
  } });
  await f.put();
  const first = f.wake();
  await started;
  f.advance(10000);
  await f.wake();
  assert.equal(f.calls.provider, 1);
  release();
  await first;
  assert.equal(f.calls.provider, 1);
  assert.equal(storage(f.env).values.get('wake-submissions').length, 1);
});
