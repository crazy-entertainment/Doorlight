const idPattern = /^[a-fA-F0-9]{40}$/;
const invalidUrlBytes = /[\u0000-\u0020\u007f]|%(?![0-9a-fA-F]{2})/;

export function configuredOrigin(value) {
  if (typeof value !== 'string' || !value || value.length > 300) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.port ||
        url.search || url.hash || !['', '/'].includes(url.pathname) ||
        (value !== url.origin && value !== `${url.origin}/`) ||
        url.hostname.length > 253 || url.hostname.split('.').some(label =>
          label.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))) return null;
    return url.origin;
  } catch { return null; }
}

function fieldsFromFragment(fragment) {
  const fields = new Map();
  for (const entry of fragment.split('&')) {
    const separator = entry.indexOf('=');
    if (separator < 0) return null;
    // URLSearchParams replaces invalid UTF-8; strict decoding must reject it.
    const decode = value => decodeURIComponent(value.replaceAll('+', ' '));
    const key = decode(entry.slice(0, separator));
    const value = decode(entry.slice(separator + 1));
    if (fields.has(key) || !['v', 'id', 'name'].includes(key)) return null;
    fields.set(key, value);
  }
  return fields;
}

export function parseInvitation(value, origin) {
  if (typeof value !== 'string' || !value || value.length > 1024 || invalidUrlBytes.test(value)) return null;
  const allowed = configuredOrigin(origin);
  if (!allowed) return null;
  try {
    const url = new URL(value);
    if (url.origin !== allowed || url.username || url.password || url.port ||
        url.pathname !== '/invite/' || url.search || value.split('#')[0].includes('?') || !url.hash) return null;
    const fields = fieldsFromFragment(url.hash.slice(1));
    if (!fields || fields.get('v') !== '1' || !idPattern.test(fields.get('id') ?? '')) return null;
    let name = fields.get('name') ?? '';
    if (/[\u0000-\u001f\u007f]/.test(name)) name = '';
    name = name.trim();
    if (new TextEncoder().encode(name).length > 64) name = '';
    return Object.freeze({ id: fields.get('id').toLowerCase(), name });
  } catch { return null; }
}

export function applicationLink(invite) {
  const query = invite.name ? `?${new URLSearchParams({ name: invite.name })}` : '';
  // Existing installations may only have the legacy handler registered.
  return `sybl://add/${invite.id}${query}`;
}
