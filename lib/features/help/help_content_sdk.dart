import 'package:flutter/material.dart';

import 'help_model.dart';

/// "Get started" and "Send data (SDK)" topics.
final sdkTopics = <HelpTopic>[
  // ------------------------------------------------------------ quick start
  HelpTopic(
    id: 'start',
    title: 'Quick start',
    icon: Icons.rocket_launch_outlined,
    category: HelpCategory.start,
    summary: 'From zero to your first log in five minutes.',
    related: ['logger-setup', 'logs-sdk', 'errors', 'keys'],
    blocks: const [
      HText(
        'LogSight collects **logs**, **errors**, **product events** and **API requests** from your apps, '
        'and lets you search them, group errors into issues, build dashboards and ship feature flags.',
      ),
      HSteps([
        'Open **Ingest keys** and create a key for your app (e.g. “iOS production”). Only owners and admins can do this.',
        'Add the `apptrack_logger` package to your Flutter/Dart app (code below).',
        'Create one `AppTrackLogger` when the app starts, with your project ID, the ingest key and a `service` name such as `keyo_ios`.',
        'Call `appTrack.info(...)`, `appTrack.error(...)` and so on anywhere in the app.',
        'Open **Logs**. New logs arrive within about 5 seconds (they are sent in batches).',
      ]),
      HCode(
        r'''# pubspec.yaml
dependencies:
  apptrack_logger:
    git:
      url: https://github.com/MuhammadAhmad2555/logsight.git
      path: packages/apptrack_logger''',
        title: 'pubspec.yaml',
      ),
      HCode(
        r'''import 'package:apptrack_logger/apptrack_logger.dart';

final appTrack = AppTrackLogger(
  firebaseProjectId: '{{FIREBASE_PROJECT_ID}}',
  projectId: '{{PROJECT_ID}}',
  ingestKey: 'YOUR_INGEST_KEY',          // from Ingest keys
  service: 'keyo_ios',                   // shown as service.name
  defaultAttributes: {'app.version': '2.4.0', 'env': 'production'},
);

void main() {
  appTrack.info('App started');
  runApp(const MyApp());
}''',
        title: 'main.dart',
      ),
      HTip(
        'Use one `service` name per app and platform (`keyo_ios`, `keyo_android`, `keyo_api`). '
        'It becomes the service switcher, the “Logs per service.name” chart and a filter everywhere.',
      ),
      HTip(
        'Not using Flutter? Any language can send logs over plain HTTPS. See **Other platforms & HTTP**.',
      ),
    ],
  ),

  // ---------------------------------------------------------- logger setup
  HelpTopic(
    id: 'logger-setup',
    title: 'Logger setup & options',
    icon: Icons.tune_rounded,
    category: HelpCategory.sdk,
    summary: 'Every constructor option, property and lifecycle method of AppTrackLogger.',
    related: ['logs-sdk', 'attributes', 'limits'],
    blocks: const [
      HText('Create the logger once (e.g. a top-level `final` or in your DI container) and reuse it everywhere.'),
      HFields(title: 'Constructor options', [
        HField('firebaseProjectId', 'String', 'The Firebase project LogSight runs on. Shown on the Ingest keys page.', required: true),
        HField('projectId', 'String', 'Your LogSight project ID (Settings → Project ID).', required: true),
        HField('ingestKey', 'String', 'An active key from Ingest keys. It can only add data, never read it.', required: true),
        HField(
          'service',
          'String',
          'Your app or service name, shown as `service.name`. Use letters, numbers, `.`, `_`, `-` so it appears in the service switcher automatically.',
          required: true,
          limit: '100 chars',
        ),
        HField('defaultAttributes', 'Map', 'Attributes added to **every log** (not events), e.g. app version, environment, device model.', defaultValue: '{}'),
        HField('minLevel', 'LogLevel', 'Logs below this level are dropped in the app, e.g. `LogLevel.info` in production.', defaultValue: 'trace'),
        HField('batchSize', 'int', 'Logs sent per request. A full batch is sent at once.', defaultValue: '50', limit: '1–500'),
        HField('flushInterval', 'Duration', 'How often queued logs are sent.', defaultValue: '5 seconds'),
        HField('maxQueue', 'int', 'Most logs kept while offline. When full, the oldest are dropped (counted in `dropped`).', defaultValue: '5000'),
        HField('printToConsole', 'bool', 'Also print each log to the debug console.', defaultValue: 'false'),
        HField('logFilePath', 'String?', 'Also append every log to this text file (one line per log). Ignored on the web.', defaultValue: 'null'),
        HField('maxLogFileBytes', 'int', 'When the file is bigger, it is renamed to `logs.1.txt` and a new one starts.', defaultValue: '5 MB'),
        HField('distinctId', 'String?', 'Restore the person ID saved from the last launch (see Product events).', defaultValue: 'random anon_…'),
        HField('client', 'http.Client?', 'Custom HTTP client (proxies, tests).', defaultValue: 'new client'),
      ]),
      HFields(title: 'Properties you can set or read', [
        HField('userId', 'String?', 'Attached to every following log. Links logs to a person on the People page. `identify()` sets it.', limit: '128 chars'),
        HField('sessionId', 'String?', 'Attached to every following log and event. Groups them into sessions.', limit: '128 chars'),
        HField('distinctId', 'String (read)', 'Who events belong to. Save it and pass it back next launch.'),
        HField('pending', 'int (read)', 'Logs and events queued but not delivered yet.'),
        HField('dropped', 'int (read)', 'Logs dropped because the queue was full or the server rejected them.'),
      ]),
      HFields(title: 'Lifecycle', [
        HField('flush()', 'Future<void>', 'Sends everything queued now. Safe to call often.'),
        HField('close()', 'Future<void>', 'Flushes and stops the logger. Call before the app or script exits.'),
      ]),
      HCode(r'''final appTrack = AppTrackLogger(
  firebaseProjectId: '{{FIREBASE_PROJECT_ID}}',
  projectId: '{{PROJECT_ID}}',
  ingestKey: 'YOUR_INGEST_KEY',
  service: 'keyo_ios',
  minLevel: kReleaseMode ? LogLevel.info : LogLevel.trace,
  printToConsole: !kReleaseMode,
  logFilePath: '${docsDir.path}/logs.txt',   // optional local copy
  defaultAttributes: {
    'app.version': packageInfo.version,
    'app.build': packageInfo.buildNumber,
    'os.name': Platform.operatingSystem,
    'os.version': Platform.operatingSystemVersion,
    'device.model': deviceModel,
    'env': kReleaseMode ? 'production' : 'debug',
  },
);

// When the app goes to the background:
await appTrack.flush();''', title: 'A production setup'),
      HTip(
        'Logs are queued and sent in the background, so logging never blocks or throws. '
        'If the network is down they are retried with back-off (up to 5 minutes between tries).',
      ),
    ],
  ),

  // ------------------------------------------------------------------ logs
  HelpTopic(
    id: 'logs-sdk',
    title: 'Sending logs',
    icon: Icons.receipt_long_outlined,
    category: HelpCategory.sdk,
    summary: 'Levels, messages, attributes, user/session/trace IDs and custom timestamps.',
    related: ['attributes', 'errors', 'logs-page', 'limits'],
    blocks: const [
      HFields(title: 'Levels (lowest to highest)', [
        HField('trace', 'appTrack.trace()', 'Very detailed step-by-step output. Usually off in production.'),
        HField('debug', 'appTrack.debug()', 'Information useful while developing.'),
        HField('info', 'appTrack.info()', 'Normal events: app started, user signed in, order placed.'),
        HField('warn', 'appTrack.warn()', 'Something unexpected that the app recovered from (slow response, retry).'),
        HField('error', 'appTrack.error()', 'An operation failed. Counted as an error and grouped into Issues.'),
        HField('fatal', 'appTrack.fatal()', 'A crash or unrecoverable failure. Also an error.'),
      ]),
      HFields(title: 'Parameters of trace/debug/info/warn', [
        HField('message', 'String', 'What happened. Keep the variable parts in attributes so similar logs group together.', required: true, limit: '10,000 chars'),
        HField('attributes', 'Map<String, Object?>', 'Any extra fields you want to filter or group by. See Attributes.', limit: '64 keys'),
        HField('traceId', 'String?', 'Links logs of one operation or request across services.', limit: '128 chars'),
      ]),
      HCode(r'''appTrack.info('User signed in', attributes: {'method': 'apple', 'user.plan': 'pro'});

appTrack.warn('Slow response', attributes: {
  'endpoint': '/orders',
  'duration_ms': 2300,
  'retry': 1,
});

appTrack.debug('Cart updated', attributes: {
  'cart': {'items': 3, 'total': 42.5},   // nested → cart.items, cart.total
});''', title: 'Examples'),
      HHeading('Link logs to people, sessions and traces'),
      HCode(r'''appTrack.userId = 'user-123';        // or call identify()
appTrack.sessionId = 'sess_8f2c';     // e.g. a new ID each app launch

final traceId = 'checkout-${DateTime.now().millisecondsSinceEpoch}';
appTrack.info('Checkout started', traceId: traceId);
appTrack.info('Payment authorised', traceId: traceId);
appTrack.info('Order created', traceId: traceId, attributes: {'order_id': 9812});''', title: 'IDs'),
      HText(
        'In a log’s details you can then jump to **all logs of that session** or **that trace**, '
        'and the People page lists every log of the user.',
      ),
      HHeading('Custom level or time'),
      HCode(r'''appTrack.log(
  LogLevel.info,
  'Imported offline note',
  timestamp: note.createdAt,            // must be within the last 7 days
  attributes: {'note_id': note.id},
);''', title: 'log()'),
      HTip(
        'Timestamps must be within the last 7 days and at most 1 hour in the future. '
        'The server rejects a whole batch if one log breaks a rule, so keep timestamps sensible.',
        kind: TipKind.warning,
      ),
      HTip(
        'Write messages as templates and put values in attributes: `Payment failed` + `{order_id: 42}` '
        'instead of `Payment failed for order 42`. LogSight still groups both styles (numbers and IDs are '
        'replaced by placeholders), but attributes are easier to filter and chart.',
      ),
    ],
  ),

  // ---------------------------------------------------------------- errors
  HelpTopic(
    id: 'errors',
    title: 'Errors & crashes',
    icon: Icons.error_outline_rounded,
    category: HelpCategory.sdk,
    summary: 'error() and fatal() with exception, stack trace and reason, plus catching every crash.',
    related: ['issues', 'logs-sdk', 'attributes'],
    blocks: const [
      HText(
        '`error()` and `fatal()` take the same parameters as `info()` plus three optional error details. '
        'They appear in the log’s details, can be copied in one tap, and decide how errors are grouped into **Issues**.',
      ),
      HFields(title: 'Error details (all optional)', [
        HField('error', 'Object?', 'The caught exception. Its **type** (e.g. `SocketException`) and **message** (`toString()`) are recorded.', limit: 'type 200, message 4,000 chars'),
        HField('stackTrace', 'StackTrace?', 'Where it happened.', limit: '16,000 chars'),
        HField('reason', 'String?', 'Your own explanation: what the app was doing or why it failed.', limit: '4,000 chars'),
        HField('attributes', 'Map', 'Context such as order ID or screen, as with any log.', limit: '64 keys'),
        HField('traceId', 'String?', 'Links the error to the other logs of the operation.'),
      ]),
      HCode(r'''try {
  await purchase(product);
} catch (e, st) {
  appTrack.error(
    'Purchase failed',
    error: e,
    stackTrace: st,
    reason: 'Store returned no receipt after payment',
    attributes: {'product_id': product.id, 'price': product.price, 'screen': 'paywall'},
  );
}''', title: 'A caught error'),
      HHeading('Catch every crash in Flutter'),
      HCode(r'''void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    // Errors inside Flutter (build, layout, gestures).
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      appTrack.fatal(
        details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
        reason: details.context?.toDescription(),
        attributes: {'library': details.library},
      );
    };

    // Errors outside Flutter (platform channels, isolates).
    PlatformDispatcher.instance.onError = (error, stack) {
      appTrack.fatal('Uncaught platform error', error: error, stackTrace: stack);
      return true;
    };

    runApp(const MyApp());
  }, (error, stack) {
    // Errors in async code that nobody awaited.
    appTrack.fatal('Uncaught async error', error: error, stackTrace: stack);
  });
}''', title: 'main.dart'),
      HHeading('How errors become issues'),
      HText(
        'Errors are grouped by **service + error type + message pattern**. The pattern is the message with '
        'variable parts (numbers, IDs, emails, URLs…) replaced, so `Payment failed for order 42` and '
        '`… order 97` are one issue. Without an `error:` object you can set the type yourself with the '
        '`exception.type` attribute.',
      ),
      HTip('Error details are only kept on `error` and `fatal` logs; on other levels they are ignored.'),
    ],
  ),

  // ------------------------------------------------------------ attributes
  HelpTopic(
    id: 'attributes',
    title: 'Attributes (custom fields)',
    icon: Icons.data_object_rounded,
    category: HelpCategory.sdk,
    summary: 'What you can send in attributes, naming tips and the names LogSight understands.',
    related: ['filters', 'logs-sdk', 'endpoints-sdk'],
    blocks: const [
      HText(
        'Attributes are your own fields on a log. Every attribute you send becomes filterable on the Logs page '
        '(**Add filter → Field**), usable in **Group by**, in dashboards and in alerts — no setup needed.',
      ),
      HFields(title: 'Allowed values', [
        HField('String', '"pro"', 'Text. Filter with equals / contains.'),
        HField('int, double', '42, 9.99', 'Numbers. Filter with = and > / < (e.g. `duration_ms > 500`).'),
        HField('bool', 'true', 'Filter with `= true` (case doesn’t matter).'),
        HField('DateTime', 'DateTime.now()', 'Stored as a timestamp.'),
        HField('List', "['beta', 'ios']", 'Filter `tags = beta` matches if any item equals beta.'),
        HField('Map (nested)', "{'model': 'iPhone 17'}", 'Becomes dot paths: `device.model`. Up to 3 levels are offered in pickers.'),
        HField('null', 'null', 'Shown as empty; “is not set” matches missing keys.'),
      ]),
      HCode(r'''appTrack.info('Screen loaded', attributes: {
  'screen': 'checkout',
  'duration_ms': 840,
  'cached': false,
  'tags': ['beta', 'experiment-b'],
  'device': {'model': 'iPhone 17', 'battery': 0.42},
});
// Filter examples on the Logs page:
//   screen = checkout        duration_ms > 500
//   tags = beta              device.model contains iphone
//   cached = false           device.battery < 0.2''', title: 'Example'),
      HFields(title: 'Recommended names', [
        HField('app.version / app.build', 'String', 'Find which release introduced an error.'),
        HField('env', 'String', '`production`, `staging`, `debug`.'),
        HField('os.name / os.version', 'String', 'Platform and version.'),
        HField('device.model', 'String', 'Device model.'),
        HField('locale / country', 'String', 'Language or region.'),
        HField('network', 'String', '`wifi`, `cellular`, `offline`.'),
        HField('screen', 'String', 'Where the user was.'),
        HField('duration_ms', 'number', 'How long something took. Also used by Endpoints.'),
        HField('exception.type', 'String', 'Error type when you don’t pass an `error:` object (Issues grouping).'),
        HField('http.method / http.route / http.status_code', '—', 'Set for you by `request()`. Endpoints also reads `url.path`, `http.request.method`, `http.response.status_code`.'),
      ]),
      HTip(
        'Keep names stable and lowercase with dots or underscores. `userId`, `sessionId`, `traceId`, '
        '`severity`, `message` and `service.name` are built-in fields — don’t send them as attributes.',
      ),
      HTip(
        'Up to 64 attributes per log (defaults included). Extra keys are dropped in the app before sending.',
        kind: TipKind.warning,
      ),
    ],
  ),

  // ---------------------------------------------------------------- events
  HelpTopic(
    id: 'events-sdk',
    title: 'Product events & people',
    icon: Icons.bolt_outlined,
    category: HelpCategory.sdk,
    summary: 'capture(), screen(), identify(), setPersonProperties() and reset() — like PostHog.',
    related: ['activity', 'people', 'flags-sdk'],
    blocks: const [
      HText(
        'Events describe what people do (sign up, purchase, open a screen). They appear on **Activity**, '
        'build **People** profiles and can be counted on dashboards.',
      ),
      HFields(title: 'Methods', [
        HField('capture(event, {properties, timestamp})', 'void', 'Records an event. Name up to 200 chars; up to 128 properties.'),
        HField('screen(name, {properties})', 'void', 'Records a `\$screen` event with `\$screen_name`.'),
        HField('identify(userId, {properties})', 'void', 'Switches from the anonymous ID to your user ID, links the two, sets `userId` on logs and sets person properties.'),
        HField('setPersonProperties(map)', 'void', 'Merges properties into the current person (e.g. plan changed). Up to 200 per person.'),
        HField('reset()', 'void', 'On sign-out: starts a new anonymous person and clears `userId` (and the properties used for feature flags).'),
        HField('distinctId', 'String', 'The current person ID. Save it and pass `distinctId:` to the constructor next launch.'),
        HField('sessionId', 'String?', 'Set it to group events (and logs) into sessions.'),
      ]),
      HCode(r'''// App start: restore the saved person ID.
final prefs = await SharedPreferences.getInstance();
final appTrack = AppTrackLogger(
  firebaseProjectId: '{{FIREBASE_PROJECT_ID}}',
  projectId: '{{PROJECT_ID}}',
  ingestKey: 'YOUR_INGEST_KEY',
  service: 'keyo_ios',
  distinctId: prefs.getString('distinct_id'),
);
await prefs.setString('distinct_id', appTrack.distinctId);
appTrack.sessionId = const Uuid().v4();

appTrack.screen('Paywall', properties: {'variant': 'b'});
appTrack.capture('purchase_completed', properties: {
  'plan': 'pro',
  'amount': 9.99,
  'currency': 'USD',
});

// After sign-in:
appTrack.identify('user-123', properties: {
  'email': 'ana@example.com',
  'name': 'Ana',
  'plan': 'pro',
});
await prefs.setString('distinct_id', appTrack.distinctId);

// Later:
appTrack.setPersonProperties({'plan': 'business'});

// Sign-out:
appTrack.reset();
await prefs.setString('distinct_id', appTrack.distinctId);''', title: 'A typical flow'),
      HTip('Name events as `object_action` in past tense: `order_placed`, `video_played`, `signup_completed`.'),
      HTip(
        'Events don’t get `defaultAttributes` — pass what you need in `properties`. '
        'Descriptions and a “verified” badge can be added in **Data management**.',
      ),
    ],
  ),

  // -------------------------------------------------------------- endpoints
  HelpTopic(
    id: 'endpoints-sdk',
    title: 'API requests (Endpoints)',
    icon: Icons.alt_route_outlined,
    category: HelpCategory.sdk,
    summary: 'request(): one call per API request gives calls, errors and latency per route.',
    related: ['endpoints', 'attributes'],
    blocks: const [
      HFields(title: 'request(method, route, {…})', [
        HField('method', 'String', '`GET`, `POST`, … (upper-cased for you).', required: true),
        HField('route', 'String', 'The route **pattern**, e.g. `/api/orders/:id`, not the full URL, so calls group together.', required: true),
        HField('statusCode', 'int?', 'HTTP status. 5xx → error log, 4xx → warn, others → info.'),
        HField('duration', 'Duration?', 'How long the request took. Used for p50/p95.'),
        HField('attributes', 'Map?', 'Extra context (region, cache hit…).'),
        HField('traceId', 'String?', 'Link to the other logs of the operation.'),
        HField('error / stackTrace', 'Object? / StackTrace?', 'For failures without a response (timeouts, no network). Logged as an error.'),
      ]),
      HText(
        'It writes a log like `GET /api/orders/:id 503 (1234 ms)` with the attributes `http.method`, `http.route`, '
        '`http.status_code` and `duration_ms`, plus a search token so the Endpoints page loads only requests.',
      ),
      HCode(r'''Future<http.Response> tracked(String method, String route, Future<http.Response> Function() send) async {
  final sw = Stopwatch()..start();
  try {
    final res = await send();
    appTrack.request(method, route, statusCode: res.statusCode, duration: sw.elapsed);
    return res;
  } catch (e, st) {
    appTrack.request(method, route, duration: sw.elapsed, error: e, stackTrace: st);
    rethrow;
  }
}

final res = await tracked('GET', '/api/orders/:id', () => http.get(Uri.parse('$api/orders/$id')));''', title: 'A small wrapper for package:http'),
      HCode(r'''dio.interceptors.add(InterceptorsWrapper(
  onRequest: (o, h) { o.extra['sw'] = Stopwatch()..start(); h.next(o); },
  onResponse: (r, h) {
    appTrack.request(r.requestOptions.method, routeOf(r.requestOptions.path),
        statusCode: r.statusCode, duration: (r.requestOptions.extra['sw'] as Stopwatch).elapsed);
    h.next(r);
  },
  onError: (e, h) {
    appTrack.request(e.requestOptions.method, routeOf(e.requestOptions.path),
        statusCode: e.response?.statusCode,
        duration: (e.requestOptions.extra['sw'] as Stopwatch).elapsed,
        error: e.response == null ? e : null);
    h.next(e);
  },
));
// routeOf('/api/orders/9812') → '/api/orders/:id' (replace IDs with placeholders)''', title: 'Dio interceptor'),
      HTip(
        'Logs from other tools work too if they have a route attribute: `http.route`, `url.path`, `http.target` '
        'or `path`. Without the search token they won’t be picked up automatically, so prefer `request()`.',
      ),
    ],
  ),

  // ------------------------------------------------------------ flags (sdk)
  HelpTopic(
    id: 'flags-sdk',
    title: 'Feature flags in your app',
    icon: Icons.toggle_on_outlined,
    category: HelpCategory.sdk,
    summary: 'reloadFeatureFlags(), isFeatureEnabled() and how rollout and conditions are evaluated.',
    related: ['flags', 'events-sdk'],
    blocks: const [
      HFields(title: 'Methods', [
        HField('reloadFeatureFlags()', 'Future<bool>', 'Loads all flags (one request). Returns false on failure and keeps the old ones.'),
        HField('isFeatureEnabled(key, {fallback, properties})', 'bool', 'Whether the flag is on for the current person. Unknown or not-loaded flags return `fallback` (default false).'),
        HField('featureFlags', 'Map<String, bool>', 'Every loaded flag and its value for the current person.'),
        HField('featureFlagsLoadedAt', 'DateTime?', 'When flags were last loaded.'),
      ]),
      HCode(r'''// At startup (and when the app resumes):
await appTrack.reloadFeatureFlags();

if (appTrack.isFeatureEnabled('new-checkout')) {
  return const NewCheckout();
}

// Safe default when offline or before loading:
final showBanner = appTrack.isFeatureEnabled('promo-banner', fallback: false);

// Check extra properties just for this call:
final enabled = appTrack.isFeatureEnabled('big-cart-upsell', properties: {'cart_total': cart.total});''', title: 'Usage'),
      HHeading('How a flag is decided'),
      HSteps([
        'If the flag is **off**, it is off for everyone.',
        'Every **condition** must match the person’s properties (from `identify()` / `setPersonProperties()` plus `properties:`).',
        'The person’s **rollout bucket** (0–99, a stable hash of `flagKey.distinctId`) must be below the rollout %. '
            'Raising 20% → 50% keeps the first 20% in.',
      ]),
      HTip('Call `identify()` before checking flags that target signed-in users, so their properties are known.'),
      HTip(
        'Apps read flags without signing in (like PostHog’s public flag API). Never put secrets in flag names or conditions.',
        kind: TipKind.warning,
      ),
    ],
  ),

  // --------------------------------------------------------- other platforms
  HelpTopic(
    id: 'http',
    title: 'Other platforms & HTTP',
    icon: Icons.http_rounded,
    category: HelpCategory.sdk,
    summary: 'Send logs and events from Swift, Kotlin, a server or curl with one HTTPS request.',
    related: ['reference-log', 'reference-event', 'keys'],
    blocks: const [
      HText(
        'There is no special server: apps write documents straight to Firestore’s REST API with the ingest key. '
        'Ready-to-copy Dart, Swift and curl code (with your key filled in) is on **Ingest keys**: select a key to see it.',
      ),
      HCode(r'''POST https://firestore.googleapis.com/v1/projects/{{FIREBASE_PROJECT_ID}}/databases/(default)/documents:commit
Content-Type: application/json''', title: 'Endpoint'),
      HCode(r'''{
  "writes": [{
    "update": {
      "name": "projects/{{FIREBASE_PROJECT_ID}}/databases/(default)/documents/projects/{{PROJECT_ID}}/logs/<random-id>",
      "fields": {
        "ts":       {"timestampValue": "2026-11-26T08:00:00Z"},
        "severity": {"stringValue": "error"},
        "message":  {"stringValue": "Payment failed"},
        "service":  {"stringValue": "keyo_api"},
        "key":      {"stringValue": "YOUR_INGEST_KEY"},
        "tokens":   {"arrayValue": {"values": [{"stringValue": "payment"}, {"stringValue": "failed"}]}},
        "userId":   {"stringValue": "user-123"},
        "attributes": {"mapValue": {"fields": {
          "order_id": {"integerValue": "9812"},
          "region":   {"stringValue": "eu"}
        }}},
        "error": {"mapValue": {"fields": {
          "type":   {"stringValue": "StripeError"},
          "reason": {"stringValue": "Card declined by issuer"}
        }}}
      }
    },
    "currentDocument": {"exists": false},
    "updateTransforms": [{"fieldPath": "receivedAt", "setToServerValue": "REQUEST_TIME"}]
  }]
}''', title: 'Body: one log'),
      HBullets([
        'Put up to 500 writes in one request to send a batch.',
        'Events go to `…/projects/{{PROJECT_ID}}/events/<id>` with the fields in **Event fields**.',
        '`tokens` are the lowercase words (2–40 letters, digits or `_`) of the message; without them search won’t find the log.',
        'A 400/403 answer means a field broke a rule or the key is disabled; retrying won’t help.',
      ]),
    ],
  ),
];
