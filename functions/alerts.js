// Pure alert logic (no Firebase), so it can be unit-tested.

const ERROR_LEVELS = ['error', 'fatal'];

/** Whether a rule fires for the counted value. */
function isFiring(rule, value) {
  if (rule.type === 'service_silent') return value === 0;
  return value >= (rule.threshold ?? 1);
}

/** Which logs a rule counts: severities (null = all) and service (null = all). */
function countSpec(rule) {
  return {
    severities: rule.type === 'error_spike' ? ERROR_LEVELS : null,
    service: rule.service || null,
    windowMinutes: Math.min(Math.max(rule.windowMinutes ?? 15, 5), 1440),
  };
}

function describe(rule, value) {
  const scope = rule.service || 'all services';
  const win = rule.windowMinutes >= 60 ? `${rule.windowMinutes / 60} h` : `${rule.windowMinutes} min`;
  switch (rule.type) {
    case 'service_silent':
      return `No logs from ${scope} in the last ${win}`;
    case 'log_volume':
      return `${value} logs from ${scope} in the last ${win} (threshold ${rule.threshold})`;
    default:
      return `${value} errors from ${scope} in the last ${win} (threshold ${rule.threshold})`;
  }
}

/** Webhook body: Slack and Discord get chat text; anything else gets JSON. */
function webhookBody(url, { rule, state, value, projectName, projectId, at }) {
  const icon = state === 'firing' ? '🔴' : '✅';
  const verb = state === 'firing' ? 'firing' : 'resolved';
  const text = `${icon} LogSight alert ${verb}: *${rule.name}*, ${describe(rule, value)} · project ${projectName}`;
  const host = (() => {
    try {
      return new URL(url).hostname;
    } catch {
      return '';
    }
  })();
  if (host === 'hooks.slack.com') return { text };
  if (host.endsWith('discord.com') || host.endsWith('discordapp.com')) return { content: text.replaceAll('*', '**') };
  return {
    source: 'logsight',
    state,
    alert: { id: rule.id, name: rule.name, type: rule.type, service: rule.service || null,
      threshold: rule.threshold, windowMinutes: rule.windowMinutes },
    value,
    project: { id: projectId, name: projectName },
    message: describe(rule, value),
    at: at.toISOString(),
  };
}

/** Only https URLs to public hosts (no localhost / private IPs / metadata). */
function safeWebhookUrl(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  if (u.protocol !== 'https:') return false;
  const h = u.hostname.toLowerCase();
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h === 'metadata.google.internal') return false;
  if (/^(127\.|10\.|192\.168\.|169\.254\.|0\.)/.test(h)) return false;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(h)) return false;
  if (h.startsWith('[')) return false; // IPv6 literal
  return true;
}

module.exports = { isFiring, countSpec, describe, webhookBody, safeWebhookUrl, ERROR_LEVELS };
