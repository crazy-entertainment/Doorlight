const HANDLE = /^[A-Za-z0-9_-]{43}$/;
const TOKEN_MIN = 20;
const TOKEN_MAX = 4096;
// Each UTF-16 unit can use a six-byte JSON escape, including the "token" key.
const REGISTRATION_BODY_MAX = (TOKEN_MAX + 'token'.length) * 6 + '{"":""}'.length;
const FCM_ERROR_BODY_MAX = 8192;
const OAUTH_URL = 'https://oauth2.googleapis.com/token';
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const tokenCache = new Map();
const OAUTH_BODY_MAX = 8192;
const OAUTH_TIMEOUT_MS = 10000;
const REGISTRATION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const PROVISIONAL_TTL_MS = 5 * 60 * 1000;
const ACTIVE_LEASE_SLACK_MS = 60 * 1000;
const WAKE_WINDOW_MS = 60 * 60 * 1000;
const WAKE_GAP_MS = 10 * 1000;
const WAKE_LIMIT = 60;

const empty = (status) => new Response(null, {
  status,
  headers: { 'cache-control': 'no-store' },
});

const base64Url = (bytes) => {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
};

const encodedJson = (value) => base64Url(
  new TextEncoder().encode(JSON.stringify(value)),
);

const sha256 = async (value) => base64Url(new Uint8Array(
  await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)),
));

const sameSecretHash = (left, right) => {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
};

const privateKeyBytes = (pem) => {
  const compact = pem
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replaceAll(/\s/g, '');
  const binary = atob(compact);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
};

async function firebaseAccessToken(env, fetchImpl) {
  if (typeof env.FIREBASE_PRIVATE_KEY !== 'string' || env.FIREBASE_PRIVATE_KEY.length > 16384 ||
      typeof env.FIREBASE_CLIENT_EMAIL !== 'string' || env.FIREBASE_CLIENT_EMAIL.length > 512 ||
      typeof env.FIREBASE_PROJECT_ID !== 'string' || env.FIREBASE_PROJECT_ID.length > 256) {
    throw new Error('Invalid FCM configuration');
  }
  // Different DO instances may receive different env objects. Bind cached and
  // in-flight authorization to the exact credential configuration, never just
  // a project ID. Only its digest is retained as the bounded cache key.
  const cacheKey = await sha256(JSON.stringify([
    env.FIREBASE_PROJECT_ID, env.FIREBASE_CLIENT_EMAIL, env.FIREBASE_PRIVATE_KEY,
  ]));
  const cached = tokenCache.get(cacheKey);
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.expiresAt > now + 60) return cached.value;
  if (cached?.pending) return cached.pending;
  for (const [key, entry] of tokenCache) {
    if (!entry.pending && entry.expiresAt <= now + 60) tokenCache.delete(key);
  }
  if (!cached && tokenCache.size >= 8) throw new Error('FCM authorization busy');
  const controller = new AbortController();
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error('FCM authorization timeout'));
    }, OAUTH_TIMEOUT_MS);
  });
  const work = Promise.race([
    requestFirebaseAccessToken(env, fetchImpl, now, controller.signal), deadline,
  ]);
  // Joiners receive the access-token string, not the internal cache record.
  const pending = work.then((result) => result.value);
  tokenCache.set(cacheKey, { pending });
  try {
    const result = await work;
    tokenCache.set(cacheKey, result);
    return result.value;
  } catch {
    // The derived promise also needs a rejection observer when no joiner exists.
    await pending.catch(() => {});
    tokenCache.delete(cacheKey);
    throw new Error('FCM authorization failed');
  } finally {
    clearTimeout(timer);
  }
}

async function requestFirebaseAccessToken(env, fetchImpl, now, signal) {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    privateKeyBytes(env.FIREBASE_PRIVATE_KEY),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const header = encodedJson({ alg: 'RS256', typ: 'JWT' });
  const claim = encodedJson({
    iss: env.FIREBASE_CLIENT_EMAIL,
    scope: FCM_SCOPE,
    aud: OAUTH_URL,
    iat: now,
    exp: now + 3300,
  });
  const unsigned = `${header}.${claim}`;
  const signature = base64Url(new Uint8Array(await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned),
  )));
  if (signal.aborted) throw new Error('FCM authorization cancelled');
  const response = await fetchImpl(OAUTH_URL, {
    signal,
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${signature}`,
    }),
  });
  if (!response.ok) throw new Error('FCM authorization failed');
  const text = await readBody(response, OAUTH_BODY_MAX, true, signal);
  if (text === null) throw new Error('FCM authorization response too large');
  const body = JSON.parse(text);
  if (typeof body.access_token !== 'string' || body.access_token.length < 20 ||
      body.access_token.length > 4096 || !/^[\x21-\x7e]+$/.test(body.access_token)) {
    throw new Error('FCM authorization returned no token');
  }
  const expiresIn = Number.isFinite(body.expires_in) ? body.expires_in : 3000;
  return {
    value: body.access_token,
    expiresAt: now + Math.max(60, Math.min(expiresIn, 3600)),
  };
}

const bearer = (request) => {
  const value = request.headers.get('authorization') ?? '';
  return value.startsWith('Bearer ') ? value.slice(7) : '';
};

const validToken = (value) => typeof value === 'string' &&
  value.length >= TOKEN_MIN && value.length <= TOKEN_MAX;

const validRecord = (value, allowRetiredToken = false) => {
  const tokenValid = validToken(value?.token) || (allowRetiredToken && value?.token === null);
  if (!tokenValid || typeof value?.secretHash !== 'string' ||
      !HANDLE.test(value.secretHash)) throw new Error('Invalid wake registration');
  return { token: value.token, secretHash: value.secretHash };
};

const authority = (env, handle) => {
  const namespace = env.WAKE_REGISTRATION_AUTHORITY;
  return namespace.get(namespace.idFromName(handle));
};

const admission = (env) => {
  const namespace = env.WAKE_ADMISSION;
  // Exactly one provider-wide authority; neither handles nor sources select objects.
  return namespace.get(namespace.idFromName('provider-wide-v1'));
};

const admissionLimits = (env) => {
  const limits = ['WAKE_REQUESTS_PER_MINUTE', 'WAKE_SOURCE_REQUESTS_PER_MINUTE',
    'WAKE_SOURCE_CAPACITY', 'WAKE_HANDLE_CAPACITY'].map((name) => Number(env[name]));
  // These are operator inputs, not default quotas. Bound the representation too.
  if (limits.some((value) => !Number.isSafeInteger(value) || value < 1 || value > 100000)) {
    throw new Error('Wake admission configuration required');
  }
  return limits;
};

/** Fixed-object admission and bounded existence index. Unknown wakes never write a handle. */
export class WakeAdmissionStore {
  constructor(state, env, { now = Date.now } = {}) {
    this.storage = state.storage;
    this.env = env;
    this.now = now;
  }

  async reserve(handle) {
    if (!HANDLE.test(handle)) return false;
    const [, , , capacity] = admissionLimits(this.env);
    return this.storage.transaction(async (tx) => {
      const existing = await tx.get(`handle:${handle}`);
      if (existing === true || this.validLease(existing)) return true;
      if (existing !== undefined) return false;
      const count = await tx.get('handle-count') ?? 0;
      if (!Number.isSafeInteger(count) || count < 0 || count >= capacity) return false;
      await tx.put(`handle:${handle}`, true);
      await tx.put('handle-count', count + 1);
      return true;
    });
  }

  async activate(handle, registrationExpiresAt) {
    if (!HANDLE.test(handle)) return false;
    admissionLimits(this.env);
    return this.storage.transaction(async (tx) => {
      const slot = await tx.get(`handle:${handle}`);
      const now = this.now();
      if ((slot !== true && !this.validLease(slot, now)) ||
          !Number.isSafeInteger(now) || now < 0) return false;
      const deadline = registrationExpiresAt ?? now + REGISTRATION_TTL_MS;
      if (!Number.isSafeInteger(deadline) || deadline <= now ||
          deadline > now + REGISTRATION_TTL_MS ||
          !Number.isSafeInteger(deadline + ACTIVE_LEASE_SLACK_MS)) return false;
      // A stale private reconciliation must not shorten a concurrent renewal.
      const expiresAt = Math.max(slot === true ? 0 : slot.expiresAt,
        deadline + ACTIVE_LEASE_SLACK_MS);
      await tx.put(`handle:${handle}`, { expiresAt });
      return true;
    });
  }

  async retireLegacy(handle) {
    if (!HANDLE.test(handle)) return false;
    admissionLimits(this.env);
    return this.storage.transaction(async (tx) => {
      const key = `handle:${handle}`;
      const slot = await tx.get(key);
      if (slot === undefined || this.validLease(slot)) return true;
      if (slot !== true) return false;
      const now = this.now();
      if (!Number.isSafeInteger(now) || now < 0 ||
          !Number.isSafeInteger(now + PROVISIONAL_TTL_MS)) return false;
      // Only imported, non-expiring reservations are touched. An active
      // renewal has already converted its slot to a dated lease.
      await tx.put(key, { expiresAt: now + PROVISIONAL_TTL_MS });
      return true;
    });
  }

  async release(handle) {
    if (!HANDLE.test(handle)) return false;
    admissionLimits(this.env);
    return this.storage.transaction(async (tx) => {
      const slot = await tx.get(`handle:${handle}`);
      if (slot === undefined) return true;
      if (slot !== true && !this.validLease(slot)) return false;
      const count = await tx.get('handle-count');
      if (!Number.isSafeInteger(count) || count < 1) return false;
      await tx.delete(`handle:${handle}`);
      await tx.put('handle-count', count - 1);
      return true;
    });
  }

  validLease(value, now) {
    return value !== null && typeof value === 'object' &&
      Object.keys(value).length === 1 && Number.isSafeInteger(value.expiresAt) &&
      value.expiresAt >= 0 && (now === undefined || value.expiresAt > now);
  }

  // A full index is scanned at most once per minute. Pages keep the read
  // bounded; corrupt counts or leases fail closed instead of guessing absence.
  async reclaimExpired(tx, count, now) {
    const last = await tx.get('last-full-scan');
    if (Number.isSafeInteger(last) && last >= 0 && now - last < 60000) return count;
    let cursor;
    let seen = 0;
    let expired = 0;
    while (true) {
      const options = { prefix: 'handle:', limit: 128 };
      if (cursor !== undefined) options.startAfter = cursor;
      const page = await tx.list(options);
      if (!(page instanceof Map) || page.size > 128) return null;
      if (page.size === 0) break;
      for (const [key, slot] of page) {
        if (!key.startsWith('handle:') ||
            (slot !== true && !this.validLease(slot))) return null;
        seen += 1;
        if (seen > count) return null;
        if (slot !== true && slot.expiresAt <= now) {
          await tx.delete(key);
          expired += 1;
        }
        cursor = key;
      }
    }
    if (seen !== count) return null;
    await tx.put('last-full-scan', now);
    if (expired > 0) await tx.put('handle-count', count - expired);
    return count - expired;
  }

  async admit(source, handle, create = false) {
    if (!HANDLE.test(source) || !HANDLE.test(handle)) return false;
    const [globalLimit, sourceLimit, sourceCapacity, handleCapacity] = admissionLimits(this.env);
    return this.storage.transaction(async (tx) => {
      const now = this.now();
      if (!Number.isSafeInteger(now) || now < 0) return false;
      const prior = await tx.get('requests') ?? { times: [], sources: [] };
      if (!Array.isArray(prior.times) || prior.times.length > 100000 ||
          !Array.isArray(prior.sources) || prior.sources.length > 100000 ||
          prior.times.some((time) => !Number.isSafeInteger(time) || time < 0 || time > now) ||
          prior.sources.some((entry) => !HANDLE.test(entry?.source) ||
            !Array.isArray(entry.times) || entry.times.length > 100000 ||
            entry.times.some((time) => !Number.isSafeInteger(time) || time < 0 || time > now))) return false;
      const times = prior.times.filter((time) => now - time < 60000);
      const sources = prior.sources.map((entry) => ({
        source: entry.source, times: entry.times.filter((time) => now - time < 60000),
      })).filter((entry) => entry.times.length > 0);
      if (times.length >= globalLimit) return false;
      let entry = sources.find((value) => value.source === source);
      if (!entry) {
        if (sources.length >= sourceCapacity) return false;
        entry = { source, times: [] };
        sources.push(entry);
      }
      if (entry.times.length >= sourceLimit) return false;
      times.push(now);
      entry.times.push(now);
      await tx.put('requests', { times, sources });
      const key = `handle:${handle}`;
      const slot = await tx.get(key);
      if (slot === true || this.validLease(slot, now)) return true;
      if (slot !== undefined && !this.validLease(slot)) {
        if (!this.validLease(slot, undefined)) return false;
        const count = await tx.get('handle-count');
        if (!Number.isSafeInteger(count) || count < 1) return false;
        await tx.delete(key);
        await tx.put('handle-count', count - 1);
      }
      if (!create) return 'unknown';
      if (this.env.WAKE_REGISTRATION_MIGRATION !== 'complete') return false;
      let count = await tx.get('handle-count') ?? 0;
      if (count >= handleCapacity) count = await this.reclaimExpired(tx, count, now);
      if (!Number.isSafeInteger(count) || count < 0 || count >= handleCapacity) return false;
      await tx.put(key, { expiresAt: now + PROVISIONAL_TTL_MS });
      await tx.put('handle-count', count + 1);
      return true;
    });
  }
}

async function admitRequest(request, env, handle, create = false) {
  // Cloudflare overwrites this header at the public edge. Never fall back to
  // caller-controlled forwarding headers or allocate a source-derived object.
  const source = request.headers.get('cf-connecting-ip');
  if (!source || source.length > 64 || !/^[0-9a-fA-F:.]+$/.test(source)) return false;
  try {
    admissionLimits(env);
    return await admission(env).admit(await sha256(source), handle, create);
  } catch {
    return false;
  }
}

async function readBody(request, maximumBytes, strictUtf8 = false, signal) {
  if (!request.body) return '';
  const reader = request.body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: strictUtf8 });
  let size = 0;
  let text = '';
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal?.addEventListener('abort', abort, { once: true });
  try {
    for (;;) {
      if (signal?.aborted) throw new Error('Response read cancelled');
      const { done, value } = await reader.read();
      if (signal?.aborted) throw new Error('Response read cancelled');
      if (done) return text + decoder.decode();
      size += value.byteLength;
      if (size > maximumBytes) {
        void reader.cancel().catch(() => {});
        return null;
      }
      text += decoder.decode(value, { stream: true });
    }
  } finally {
    signal?.removeEventListener('abort', abort);
    reader.releaseLock();
  }
}

async function isUnregisteredToken(response) {
  if (response.status !== 404) return false;
  const text = await readBody(response, FCM_ERROR_BODY_MAX, true);
  if (text === null) return false;
  const error = JSON.parse(text)?.error;
  if (error?.code !== 404 || error.status !== 'NOT_FOUND' || !Array.isArray(error.details)) return false;
  const details = error.details.filter((detail) =>
    detail?.['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError');
  // INVALID_ARGUMENT can describe a payload fault. Only the explicit FCM
  // UNREGISTERED detail authorizes token retirement, never free-text messages.
  return details.length === 1 && details[0].errorCode === 'UNREGISTERED';
}

async function register(request, store, handle) {
  const secret = bearer(request);
  if (!HANDLE.test(secret)) return empty(401);
  let body;
  try {
    const text = await readBody(request, REGISTRATION_BODY_MAX);
    if (text === null) return empty(413);
    body = JSON.parse(text);
  } catch {
    return empty(400);
  }
  const token = body?.token;
  if (!validToken(token)) return empty(400);
  const secretHash = await sha256(secret);
  return empty(await store.change(handle, secretHash, { token, secretHash }));
}

async function unregister(request, store, handle) {
  const secret = bearer(request);
  if (!HANDLE.test(secret)) return empty(401);
  return empty(await store.change(handle, await sha256(secret), null));
}

const REGISTRATION_KEY = 'registration';

/** One durable, transactional authority per handle. No process-local ownership lock or cache. */
export class WakeRegistrationStore {
  constructor(state, env, { fetchImpl = fetch, accessToken = firebaseAccessToken, now = Date.now } = {}) {
    this.storage = state.storage;
    this.env = env;
    this.fetchImpl = fetchImpl;
    this.accessToken = accessToken;
    this.now = now;
  }

  decode(value, handle) {
    if (value?.version !== 1 || value.handle !== handle || !Object.hasOwn(value, 'record')) {
      throw new Error('Invalid durable registration');
    }
    // Existing v1 rows predate the wake revision and start at zero. All new
    // writes, including tombstones, advance it within the same transaction.
    if (value.revision !== undefined &&
        (!Number.isSafeInteger(value.revision) || value.revision < 1)) {
      throw new Error('Invalid durable registration revision');
    }
    // A null record is explicit owner deletion. A null token retains its owner
    // after FCM invalidation; only that owner can refresh or delete the handle.
    return value.record === null ? null : validRecord(value.record, true);
  }

  // Private bound-object RPC only. The approved operator supplies a record from
  // the validated live snapshot. Runtime requests never read legacy KV to seed it.
  async bootstrap(handle, record) {
    if (typeof handle !== 'string' || !HANDLE.test(handle)) return 400;
    if (this.env.WAKE_REGISTRATION_MIGRATION !== 'importing') return 503;
    let initial;
    try {
      initial = validRecord(record);
    } catch {
      return 400;
    }
    try {
      // A stale migration snapshot must not reoccupy a slot after the owner
      // deleted the handle. The durable tombstone remains the authority.
      const prior = await this.storage.get(REGISTRATION_KEY);
      if (prior !== undefined) {
        const current = this.decode(prior, handle);
        if (current === null || current.token !== initial.token ||
            !sameSecretHash(current.secretHash, initial.secretHash)) return 409;
      }
      if (!await admission(this.env).reserve(handle)) return 503;
      const result = await this.storage.transaction(async (transaction) => {
        const stored = await transaction.get(REGISTRATION_KEY);
        if (stored !== undefined) {
          const current = this.decode(stored, handle);
          return current !== null && current.token === initial.token &&
            sameSecretHash(current.secretHash, initial.secretHash) ? 204 : 409;
        }
        await transaction.put(REGISTRATION_KEY, { version: 1, handle, record: initial, revision: 1 });
        // Legacy imports have no proven renewal deadline. Preserve snapshot
        // idempotency; dormant legacy token cleanup remains a migration gate.
        return 204;
      });
      if (result === 409) {
        const stored = await this.storage.get(REGISTRATION_KEY);
        if (stored !== undefined && this.decode(stored, handle) === null) {
          if (!await admission(this.env).release(handle)) return 503;
        }
      }
      return result;
    } catch {
      return 503;
    }
  }

  async transaction(handle, operation) {
    const previous = await this.storage.get(REGISTRATION_KEY);
    if (previous !== undefined) this.decode(previous, handle);
    return this.storage.transaction(async (transaction) => {
      // Re-read inside the transaction: another request may have committed since the first read.
      const stored = await transaction.get(REGISTRATION_KEY);
      // These phases are operator assertions, not timers. Even a positive legacy
      // read can be stale; only completed snapshot import establishes cold absence.
      if (stored === undefined && this.env.WAKE_REGISTRATION_MIGRATION !== 'complete') {
        throw new Error('Wake registration migration is blocked');
      }
      const current = stored === undefined ? null : this.decode(stored, handle);
      const { result, next = current, renew = false } =
        operation(current, stored?.revision ?? 0, stored !== undefined);
      // Keep deletion tombstones so stale legacy values can never revive a retired registration.
      // An unknown wake or repeated deletion of an unknown handle does not allocate a stored row.
      if (next !== current) {
        const revision = (stored?.revision ?? 0) + 1;
        if (!Number.isSafeInteger(revision)) throw new Error('Wake revision exhausted');
        const expiresAt = renew ? this.now() + REGISTRATION_TTL_MS : stored?.expiresAt ?? null;
        await transaction.put(REGISTRATION_KEY, {
          version: 1, handle, record: next, revision,
          expiresAt,
        });
        if (next?.token !== null && next !== null) {
          await transaction.setAlarm(Number.isSafeInteger(expiresAt) ? expiresAt : this.now() + 1);
        } else {
          await transaction.deleteAlarm();
        }
      }
      return result;
    });
  }

  read(handle) {
    return this.transaction(handle, (current) => ({ result: current }));
  }

  // Private operator RPC for known snapshot handles, after import verification.
  // No new deadline is assigned to legacy data and no namespace is enumerated.
  async reconcileExpiry(handle) {
    if (typeof handle !== 'string' || !HANDLE.test(handle)) return 400;
    if (this.env.WAKE_REGISTRATION_MIGRATION !== 'complete') return 503;
    try {
      await this.reconcileAlarm(handle);
      const stored = await this.storage.get(REGISTRATION_KEY);
      const record = stored === undefined ? null : this.decode(stored, handle);
      const indexed = record?.token === null || record === null
        ? await admission(this.env).retireLegacy(handle)
        : await admission(this.env).activate(handle, stored.expiresAt);
      if (!indexed) return 503;
      return 204;
    } catch {
      return 503;
    }
  }

  async alarm() {
    await this.reconcileAlarm();
  }

  async reconcileAlarm(expectedHandle) {
    // Delivery is at least once. Re-read renewal/deletion state transactionally;
    // a delayed old alarm must never erase a freshly renewed token.
    await this.storage.transaction(async (transaction) => {
      const stored = await transaction.get(REGISTRATION_KEY);
      if (stored === undefined) {
        await transaction.deleteAlarm();
        return;
      }
      const record = this.decode(stored, expectedHandle ?? stored.handle);
      if (record === null || record.token === null) {
        await transaction.deleteAlarm();
        return;
      }
      const now = this.now();
      if (!Number.isSafeInteger(now) || now < 0) throw new Error('Invalid clock');
      if (Number.isSafeInteger(stored.expiresAt) && stored.expiresAt > now &&
          stored.expiresAt <= now + REGISTRATION_TTL_MS) {
        await transaction.setAlarm(stored.expiresAt);
        return;
      }
      const revision = (stored.revision ?? 0) + 1;
      if (!Number.isSafeInteger(revision)) throw new Error('Wake revision exhausted');
      await transaction.put(REGISTRATION_KEY, {
        ...stored, revision, record: { token: null, secretHash: record.secretHash },
      });
      await transaction.deleteAlarm();
    });
  }

  change(handle, secretHash, next) {
    return this.transaction(handle, (current, _revision, exists) => {
      // A deleted handle is retired forever. Recreating it would let an old
      // capability regain the same wake address after the owner revoked it.
      if (current === null && exists) return { result: next === null ? 204 : 410 };
      if (current && !sameSecretHash(current.secretHash, secretHash)) return { result: 401 };
      return { result: 204, next, renew: next !== null };
    });
  }

  // Reserve admission durably before any OAuth/provider work. The rolling
  // window survives handler reconstruction, renewal and deletion/recreation.
  async admitWake(handle) {
    return this.storage.transaction(async (transaction) => {
      const stored = await transaction.get(REGISTRATION_KEY);
      if (stored === undefined) return null;
      const record = this.decode(stored, handle);
      if (record === null || record.token === null) return null;
      const now = this.now();
      if (!Number.isSafeInteger(now) || now < 0) return null;
      if (!Number.isSafeInteger(stored.expiresAt) || stored.expiresAt <= now ||
          stored.expiresAt > now + REGISTRATION_TTL_MS) {
        const revision = (stored.revision ?? 0) + 1;
        if (!Number.isSafeInteger(revision)) return null;
        await transaction.put(REGISTRATION_KEY, {
          ...stored, revision, record: { token: null, secretHash: record.secretHash },
        });
        return null;
      }
      const prior = await transaction.get('wake-admission');
      if (prior !== undefined && (!Array.isArray(prior) || prior.length > WAKE_LIMIT ||
          prior.some((time, index) => !Number.isSafeInteger(time) || time < 0 ||
            time > now || (index > 0 && time < prior[index - 1])))) return null;
      const recent = (prior ?? []).filter((time) => now - time < WAKE_WINDOW_MS);
      if (recent.length >= WAKE_LIMIT ||
          (recent.length > 0 && now - recent.at(-1) < WAKE_GAP_MS)) return null;
      recent.push(now);
      await transaction.put('wake-admission', recent);
      return stored;
    });
  }

  async wake(handle) {
    try {
      if (typeof handle !== 'string' || !HANDLE.test(handle)) return;
      const original = await this.admitWake(handle);
      if (original === null) return;
      const originalRecord = this.decode(original, handle);
      if (originalRecord === null || originalRecord.token === null) return;
      // Native fetch requires its global/free-function receiver, not this store.
      const { fetchImpl, accessToken: authorize } = this;
      const accessToken = await authorize(this.env, fetchImpl);

      // SQLite's synchronous KV read and fetch submission run in one DO turn.
      // No awaited RPC/read can let DELETE complete between this check and
      // submission. A missing synchronous API fails closed in the catch below.
      const latest = this.storage.kv.get(REGISTRATION_KEY);
      if (latest === undefined) return;
      const current = this.decode(latest, handle);
      if (current === null || (latest.revision ?? 0) !== (original.revision ?? 0) ||
          !Number.isSafeInteger(latest.expiresAt) || latest.expiresAt <= this.now() ||
          current.token !== originalRecord.token ||
          !sameSecretHash(current.secretHash, originalRecord.secretHash)) return;
      // OAuth can reorder otherwise valid admissions. Reserve the actual
      // submission in this same synchronous DO turn as the authority check and
      // fetch call. Admission alone cannot enforce spacing after delayed OAuth.
      const submissionTime = this.now();
      const storedSubmissions = this.storage.kv.get('wake-submissions');
      const submissions = storedSubmissions === undefined ? [] : storedSubmissions;
      if (!Number.isSafeInteger(submissionTime) || submissionTime < 0 ||
          !Array.isArray(submissions) || submissions.length > WAKE_LIMIT ||
          submissions.some((time, index) => !Number.isSafeInteger(time) || time < 0 ||
            time > submissionTime || (index > 0 && time < submissions[index - 1]))) return;
      const recentSubmissions = submissions.filter((time) => submissionTime - time < WAKE_WINDOW_MS);
      if (recentSubmissions.length >= WAKE_LIMIT || (recentSubmissions.length > 0 &&
          submissionTime - recentSubmissions.at(-1) < WAKE_GAP_MS)) return;
      this.storage.kv.put('wake-submissions', [...recentSubmissions, submissionTime]);
      // External work must not run in a retryable storage transaction. Deletion
      // cannot recall a request already submitted to fetch before it completes.
      const response = await fetchImpl(
        `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.env.FIREBASE_PROJECT_ID)}/messages:send`,
        {
          method: 'POST',
          headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' },
          body: JSON.stringify({
            message: {
              token: current.token,
              data: { w: '1' },
              android: { priority: 'high', ttl: '60s' },
            },
          }),
        },
      );
      if (await isUnregisteredToken(response)) {
        await this.transaction(handle, (record, revision) => {
          if (record === null || revision !== (latest.revision ?? 0) ||
              record.token !== current.token || !sameSecretHash(record.secretHash, current.secretHash)) {
            return { result: false };
          }
          return { result: true, next: { token: null, secretHash: record.secretHash } };
        });
      }
    } catch {
      // A wake is best effort. Do not expose a registration or credential.
    }
  }

  async fetch(request) {
    const url = new URL(request.url);
    const match = /^\/v1\/registrations\/([A-Za-z0-9_-]{43})$/.exec(url.pathname);
    if (!match || url.search) return empty(404);
    const handle = match[1];
    try {
      if (request.method === 'PUT') return await register(request, this, handle);
      if (request.method === 'DELETE') return await unregister(request, this, handle);
      // Only a bound Worker can reach this read-only path; the public Worker rejects GET.
      if (request.method === 'GET') {
        const current = await this.read(handle);
        return current === null ? empty(404) : new Response(JSON.stringify(current), {
          headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
        });
      }
      return empty(405);
    } catch {
      return empty(503);
    }
  }
}

async function sendWake(env, handle) {
  try {
    await authority(env, handle).wake(handle);
  } catch {
    // A wake is best effort. Do not leak a registration or credential in a response or log.
  }
}

export function createWorker() {
  return {
    async fetch(request, env, context = {}) {
      const url = new URL(request.url);
      const match = /^\/v1\/(registrations|wakes)\/([A-Za-z0-9_-]{43})$/.exec(url.pathname);
      if (!match || url.search) return empty(404);
      const [, resource, handle] = match;
      if (resource === 'registrations') {
        try {
          if (request.method === 'PUT' || request.method === 'DELETE') {
            if (!HANDLE.test(bearer(request))) return empty(401);
            // Validate a new registration before reserving any handle capacity.
            if (request.method === 'PUT') {
              const text = await readBody(request, REGISTRATION_BODY_MAX);
              if (text === null) return empty(413);
              let body;
              try { body = JSON.parse(text); } catch { return empty(400); }
              if (!validToken(body?.token)) return empty(400);
              request = new Request(request.url, { method: 'PUT', headers: request.headers, body: text });
            }
            const admitted = await admitRequest(request, env, handle, request.method === 'PUT');
            if (admitted === 'unknown' && request.method === 'DELETE' &&
                env.WAKE_REGISTRATION_MIGRATION === 'complete') return empty(204);
            if (admitted !== true) return empty(503);
            const response = await authority(env, handle).fetch(request);
            if (request.method === 'PUT' && response.status === 204) {
              if (!await admission(env).activate(handle)) return empty(503);
            } else if ((request.method === 'DELETE' && response.status === 204) ||
                       (request.method === 'PUT' && response.status === 410)) {
              if (!await admission(env).release(handle)) return empty(503);
            }
            return response;
          }
        } catch {
          return empty(503);
        }
      }
      if (resource === 'wakes' && request.method === 'POST') {
        try {
          if (await readBody(request, 0) !== '') return empty(400);
        } catch {
          return empty(400);
        }
        const pending = (async () => {
          if (await admitRequest(request, env, handle) === true) await sendWake(env, handle);
        })();
        if (typeof context.waitUntil === 'function') context.waitUntil(pending);
        else await pending;
        return empty(202);
      }
      return empty(405);
    },
  };
}

export default createWorker();
