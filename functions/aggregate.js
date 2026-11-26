// Pure aggregation logic for the log aggregator (no Firebase), so it can be
// unit-tested. Turns raw log documents into the totals the app reads:
//
//   projects/{pid}/issueStats/{fingerprint}   one error issue, all time
//   projects/{pid}/statsHourly/{YYYYMMDDHH}   per-hour issue + endpoint totals
//   projects/{pid}/statsDaily/{YYYYMMDD}      per-day  issue + endpoint totals
//
// Fingerprints, patterns and endpoint fields MUST match the Dart code in
// lib/core/patterns.dart and lib/data/endpoints.dart (checked by the shared
// fixture test/fixtures/fingerprints.json in both test suites).

// ------------------------------------------------------------------ severity

const SEVERITIES = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'];
const ERROR_RANK = SEVERITIES.indexOf('error');

/** Same rules as Severity.parse in lib/core/severity.dart. */
function parseSeverity(value) {
  const v = String(value ?? '').toLowerCase();
  if (SEVERITIES.includes(v)) return v;
  if (v === 'warning') return 'warn';
  if (v === 'critical') return 'fatal';
  return 'info';
}

const severityRank = (s) => SEVERITIES.indexOf(s);

// ------------------------------------------------------------------ patterns

// Same order and expressions as _rules in lib/core/patterns.dart.
const PATTERN_RULES = [
  [/https?:\/\/\S+/g, '<url>'],
  [/[\w.+-]+@[\w-]+\.[\w.-]+/g, '<email>'],
  [/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/g, '<uuid>'],
  [/\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b/g, '<ip>'],
  [/\b\d{4}-\d{2}-\d{2}[T ][\d:.]+Z?\b/g, '<time>'],
  [/\b0x[0-9a-fA-F]+\b/g, '<hex>'],
  [/\b[0-9a-fA-F]{16,}\b/g, '<hex>'],
  [/"[^"]{0,200}"/g, '"<str>"'],
  [/'[^']{0,200}'/g, "'<str>'"],
  [/\b(?=[A-Za-z_]*\d)(?=\d*[A-Za-z_])[A-Za-z0-9_-]{8,}\b/g, '<id>'],
  [/-?\b\d+(?:\.\d+)?(?:ms|s|kb|mb|gb|%)?\b/gi, '<num>'],
];

function patternOf(message) {
  let s = message.length > 500 ? message.substring(0, 500) : message;
  s = s.split('\n')[0];
  for (const [re, rep] of PATTERN_RULES) s = s.replace(re, () => rep);
  return s.replace(/\s+/g, ' ').trim();
}

/** Two 32-bit FNV-1a halves, as stableHash in lib/core/patterns.dart. */
function stableHash(input) {
  let h1 = 0x811c9dc5;
  let h2 = 0x050c5d1f;
  for (let i = 0; i < input.length; i++) {
    const unit = input.charCodeAt(i);
    h1 = Math.imul((h1 ^ unit) >>> 0, 0x01000193) >>> 0;
    h2 = Math.imul((h2 ^ unit) >>> 0, 0x01000193) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}

function issueFingerprint(service, message, exceptionType) {
  return stableHash(`${service}|${exceptionType ?? ''}|${patternOf(message)}`);
}

// ------------------------------------------------------------------- fields

const str = (v) => (typeof v === 'string' ? v : '');
const nonEmpty = (v) => (typeof v === 'string' && v.length > 0 ? v : null);

/** Attribute lookup like LogEntry.field: exact key first, then a dot path. */
function attr(attributes, key) {
  if (!attributes || typeof attributes !== 'object') return null;
  if (Object.prototype.hasOwnProperty.call(attributes, key)) return attributes[key] ?? null;
  let cur = attributes;
  for (const part of key.split('.')) {
    if (cur && typeof cur === 'object' && !Array.isArray(cur) && Object.prototype.hasOwnProperty.call(cur, part)) {
      cur = cur[part];
    } else {
      return null;
    }
  }
  return cur ?? null;
}

/** The exception type used in fingerprints (error.type, else exception.type). */
function exceptionTypeOf(d) {
  const fromError = d.error && typeof d.error === 'object' ? nonEmpty(d.error.type) : null;
  if (fromError) return fromError;
  // A plain key, not a dot path (LogEntry.fingerprint reads attributes['exception.type']).
  const a = d.attributes && typeof d.attributes === 'object' ? d.attributes['exception.type'] : null;
  return a == null ? null : String(a);
}

// ---------------------------------------------------------------- endpoints

const REQUEST_TOKEN = 'http_request';
const METHOD_KEYS = ['http.method', 'http.request.method', 'method'];
const ROUTE_KEYS = ['http.route', 'url.path', 'http.target', 'http.path', 'route', 'path'];
const STATUS_KEYS = ['http.status_code', 'http.response.status_code', 'status_code', 'status'];
const DURATION_KEYS = ['duration_ms', 'http.duration_ms', 'latency_ms', 'elapsed_ms'];

/** Upper bounds (ms) of the latency histogram; one more bucket holds the rest.
 *  Must match latencyBounds in lib/data/stats.dart. */
const LATENCY_BOUNDS = [1, 2, 5, 10, 20, 50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000, 30000];

function firstAttr(attributes, keys) {
  for (const k of keys) {
    const v = attr(attributes, k);
    if (v != null) return [k, v];
  }
  return [null, null];
}

function toNum(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v !== 'string' || v.trim() === '') return null;
  const n = Number(v.trim());
  return Number.isFinite(n) ? n : null;
}

function latencyBucket(ms) {
  for (let i = 0; i < LATENCY_BOUNDS.length; i++) if (ms <= LATENCY_BOUNDS[i]) return i;
  return LATENCY_BOUNDS.length;
}

/** Endpoint facts for a request log (as endpointStats in endpoints.dart), or null. */
function endpointOf(d, severity) {
  const tokens = Array.isArray(d.tokens) ? d.tokens : [];
  if (!tokens.includes(REQUEST_TOKEN)) return null;
  const [routeKey, rawRoute] = firstAttr(d.attributes, ROUTE_KEYS);
  if (rawRoute == null) return null;
  const route = String(rawRoute).trim().substring(0, 300);
  if (!route) return null;
  const [, rawMethod] = firstAttr(d.attributes, METHOD_KEYS);
  const method = (rawMethod == null ? '' : String(rawMethod).trim().toUpperCase()) || '—';
  const status = toNum(firstAttr(d.attributes, STATUS_KEYS)[1]);
  let e5 = 0;
  let e4 = 0;
  if (status != null) {
    const s = Math.trunc(status);
    if (s >= 500) e5 = 1;
    if (s >= 400 && s < 500) e4 = 1;
  } else if (severityRank(severity) >= ERROR_RANK) {
    e5 = 1;
  }
  const dur = toNum(firstAttr(d.attributes, DURATION_KEYS)[1]);
  const service = str(d.service);
  return {
    key: stableHash(`${service}|${method}|${route}`),
    service,
    method,
    route,
    routeKey,
    e5,
    e4,
    duration: dur != null && dur >= 0 ? dur : null,
  };
}

// ------------------------------------------------------------------ buckets

const pad = (n, w = 2) => String(n).padStart(w, '0');
const hourId = (t) => `${t.getUTCFullYear()}${pad(t.getUTCMonth() + 1)}${pad(t.getUTCDate())}${pad(t.getUTCHours())}`;
const dayId = (t) => `${t.getUTCFullYear()}${pad(t.getUTCMonth() + 1)}${pad(t.getUTCDate())}`;
const hourStart = (t) => new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate(), t.getUTCHours()));
const dayStart = (t) => new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate()));

// ------------------------------------------------------------------- deltas

/**
 * Totals to add for a batch of logs. Each log is `{ pid, id, data }` with
 * data.ts / data.receivedAt as Dates. Returns
 * `{ issues: Map<"pid/fp", issueDelta>, stats: Map<"pid/coll/id", statsDelta> }`.
 * Logs that are neither errors nor request logs add nothing.
 */
function computeDeltas(logs) {
  const issues = new Map();
  const stats = new Map();

  const statsFor = (pid, coll, id, start) => {
    const k = `${pid}/${coll}/${id}`;
    let s = stats.get(k);
    if (!s) {
      s = { pid, coll, id, t: start, issues: {}, endpoints: {} };
      stats.set(k, s);
    }
    return s;
  };

  for (const { pid, id, data: d } of logs) {
    const ts = d.ts instanceof Date ? d.ts : null;
    if (!ts) continue;
    const severity = parseSeverity(d.severity);
    const service = str(d.service);
    const isError = severityRank(severity) >= ERROR_RANK;
    const ep = endpointOf(d, severity);
    if (!isError && !ep) continue;

    const buckets = [
      statsFor(pid, 'statsHourly', hourId(ts), hourStart(ts)),
      statsFor(pid, 'statsDaily', dayId(ts), dayStart(ts)),
    ];

    if (isError) {
      const message = str(d.message);
      const errorType = exceptionTypeOf(d);
      const fp = issueFingerprint(service, message, errorType);
      const k = `${pid}/${fp}`;
      let iss = issues.get(k);
      if (!iss) {
        iss = { pid, fp, service, pattern: patternOf(message), errorType, count: 0, firstSeen: ts, lastSeen: ts, latest: null, users: new Set() };
        issues.set(k, iss);
      }
      iss.count++;
      if (ts < iss.firstSeen) iss.firstSeen = ts;
      if (!iss.latest || ts >= iss.lastSeen) {
        iss.lastSeen = ts;
        iss.errorType = errorType;
        iss.latest = { logId: id, message: message.substring(0, 500), severity, ts };
      }
      const user = nonEmpty(d.userId);
      if (user) iss.users.add(user);
      for (const b of buckets) b.issues[fp] = (b.issues[fp] || 0) + 1;
    }

    if (ep) {
      for (const b of buckets) {
        let e = b.endpoints[ep.key];
        if (!e) {
          e = { s: ep.service, m: ep.method, r: ep.route, k: ep.routeKey, c: 0, e5: 0, e4: 0, dn: 0, ds: 0, h: new Array(LATENCY_BOUNDS.length + 1).fill(0), l: 0 };
          b.endpoints[ep.key] = e;
        }
        e.c++;
        e.e5 += ep.e5;
        e.e4 += ep.e4;
        if (ep.duration != null) {
          e.dn++;
          e.ds += ep.duration;
          e.h[latencyBucket(ep.duration)]++;
        }
        e.l = Math.max(e.l, ts.getTime());
      }
    }
  }
  return { issues, stats };
}

// -------------------------------------------------------------------- merge

const MAX_USERS = 100;
const MAX_ENDPOINTS_PER_DOC = 2000;

const toDate = (v) => (v == null ? null : v instanceof Date ? v : typeof v.toDate === 'function' ? v.toDate() : null);

/** Merges an issue delta into the stored issueStats doc (or null). Returns the new doc. */
function mergeIssue(existing, delta) {
  const prev = existing || {};
  const prevFirst = toDate(prev.firstSeen);
  const prevLast = toDate(prev.lastSeen);
  const users = new Set(Array.isArray(prev.users) ? prev.users : []);
  let capped = Boolean(prev.usersCapped);
  for (const u of delta.users) {
    if (users.has(u)) continue;
    if (users.size >= MAX_USERS) {
      capped = true;
      break;
    }
    users.add(u);
  }
  const newer = !prevLast || delta.lastSeen >= prevLast;
  return {
    service: delta.service,
    pattern: delta.pattern,
    errorType: newer ? delta.errorType ?? null : prev.errorType ?? null,
    count: (prev.count || 0) + delta.count,
    firstSeen: prevFirst && prevFirst < delta.firstSeen ? prevFirst : delta.firstSeen,
    lastSeen: newer ? delta.lastSeen : prevLast,
    latest: newer ? delta.latest : prev.latest ?? null,
    users: [...users],
    usersCapped: capped,
  };
}

/** Merges a stats delta into the stored stats doc (or null). Returns the new doc. */
function mergeStats(existing, delta) {
  const prev = existing || {};
  const issues = { ...(prev.issues || {}) };
  for (const [fp, n] of Object.entries(delta.issues)) issues[fp] = (issues[fp] || 0) + n;

  const endpoints = { ...(prev.endpoints || {}) };
  let dropped = prev.droppedEndpoints || 0;
  for (const [key, e] of Object.entries(delta.endpoints)) {
    const old = endpoints[key];
    if (!old) {
      if (Object.keys(endpoints).length >= MAX_ENDPOINTS_PER_DOC) {
        dropped += e.c;
        continue;
      }
      endpoints[key] = e;
      continue;
    }
    const h = (old.h || []).slice();
    for (let i = 0; i < e.h.length; i++) h[i] = (h[i] || 0) + e.h[i];
    endpoints[key] = {
      ...old,
      c: (old.c || 0) + e.c,
      e5: (old.e5 || 0) + e.e5,
      e4: (old.e4 || 0) + e.e4,
      dn: (old.dn || 0) + e.dn,
      ds: (old.ds || 0) + e.ds,
      h,
      l: Math.max(old.l || 0, e.l),
    };
  }
  const out = { t: delta.t, issues, endpoints };
  if (dropped) out.droppedEndpoints = dropped;
  return out;
}

module.exports = {
  parseSeverity,
  patternOf,
  stableHash,
  issueFingerprint,
  exceptionTypeOf,
  endpointOf,
  latencyBucket,
  computeDeltas,
  mergeIssue,
  mergeStats,
  hourId,
  dayId,
  LATENCY_BOUNDS,
  MAX_USERS,
};
