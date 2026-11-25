const test = require('node:test');
const assert = require('node:assert');
const { isFiring, countSpec, webhookBody, safeWebhookUrl } = require('../alerts');

const rule = { id: 'a1', name: 'keyo errors', type: 'error_spike', service: 'keyo_ios', threshold: 10, windowMinutes: 15 };
const at = new Date('2026-11-26T10:00:00Z');

test('error spike fires at the threshold', () => {
  assert.equal(isFiring(rule, 9), false);
  assert.equal(isFiring(rule, 10), true);
});

test('service silent fires only on zero', () => {
  const r = { ...rule, type: 'service_silent' };
  assert.equal(isFiring(r, 0), true);
  assert.equal(isFiring(r, 1), false);
});

test('count spec: errors only for error_spike, window clamped', () => {
  assert.deepEqual(countSpec(rule), { severities: ['error', 'fatal'], service: 'keyo_ios', windowMinutes: 15 });
  assert.deepEqual(countSpec({ ...rule, type: 'log_volume', service: null, windowMinutes: 1 }),
    { severities: null, service: null, windowMinutes: 5 });
});

test('webhook body per destination', () => {
  const info = { rule, state: 'firing', value: 23, projectName: 'Keyo', projectId: 'p1', at };
  assert.match(webhookBody('https://hooks.slack.com/services/X', info).text, /firing: \*keyo errors\*, 23 errors from keyo_ios/);
  assert.match(webhookBody('https://discord.com/api/webhooks/1/x', info).content, /\*\*keyo errors\*\*/);
  const json = webhookBody('https://example.com/hook', info);
  assert.equal(json.state, 'firing');
  assert.equal(json.value, 23);
  assert.equal(json.project.name, 'Keyo');
});

test('webhook URLs must be public https', () => {
  assert.equal(safeWebhookUrl('https://hooks.slack.com/services/X'), true);
  for (const bad of ['http://example.com', 'https://localhost/x', 'https://127.0.0.1/x', 'https://10.0.0.5/x',
    'https://169.254.169.254/x', 'https://metadata.google.internal/x', 'https://172.20.1.1/x', 'not a url']) {
    assert.equal(safeWebhookUrl(bad), false, bad);
  }
});
