import 'package:flutter/material.dart';

import 'help_model.dart';

/// "Using the dashboard" and "Reference" topics.
final appTopics = <HelpTopic>[
  HelpTopic(
    id: 'overview',
    title: 'Overview',
    icon: Icons.space_dashboard_outlined,
    category: HelpCategory.app,
    summary: 'Health at a glance: logs, errors, error rate, services and top issues.',
    related: ['issues', 'logs-page', 'dashboards'],
    blocks: const [
      HBullets([
        'Pick **24h / 7d / 30d** at the top; pull down (or tap ↻) to refresh.',
        '**Logs**, **Errors** (error + fatal), **Error rate** and **Active services** (services that sent logs in the range / all services).',
        '**Log volume**: logs over time. **Logs per service.name**: which app is the noisiest; tap one to open its logs.',
        '**Top issues** and **Recent errors**: tap to open them. “All issues” opens the Issues page.',
      ]),
      HTip('Want your own numbers here? Build a dashboard (Dashboards) and star it for one-tap access.'),
    ],
  ),
  HelpTopic(
    id: 'logs-page',
    title: 'Logs explorer',
    icon: Icons.receipt_long_outlined,
    category: HelpCategory.app,
    summary: 'Search, filter, group, follow live, save views and export.',
    related: ['filters', 'search', 'log-detail', 'dashboards'],
    blocks: const [
      HSteps([
        '**Time range**: presets from 15 minutes to 90 days, or *Custom range…* for exact dates and times.',
        '**Service**: pick one or more apps, or exclude one.',
        '**Levels**: show only some severities; each shows how many logs it has in the range.',
        '**Search**: whole words in the message (see Search).',
        '**Add filter**: any built-in field or custom attribute with =, ≠, contains, >, <, is set… (see Filters).',
      ]),
      HBullets([
        '**Live**: with a relative range, new logs appear automatically. Tap to pause.',
        '**Chart**: tap a bar to zoom into that time window. Hide it from the ⋯ menu.',
        '**Group by**: count logs per value of any field (e.g. `app.version`), then tap a value to filter.',
        '**Saved views** (⋯ menu): save the current filters with a name; everyone in the project can open them. They also appear in Recents.',
        '**Add to dashboard** (⋯ menu): turn the current view into a count or chart tile.',
        '**Export** (⋯ menu): download the loaded logs as `.txt` or `.csv`.',
        'Every filter is in the URL, so you can bookmark or share a view.',
      ]),
      HTip('Tap a log to open its details (attributes, error, related logs).'),
    ],
  ),
  HelpTopic(
    id: 'log-detail',
    title: 'Log details',
    icon: Icons.article_outlined,
    category: HelpCategory.app,
    summary: 'Attributes, error details, include/exclude values and related logs.',
    related: ['logs-page', 'errors'],
    blocks: const [
      HBullets([
        '**Resource attributes**: service, severity, user, session, trace.',
        '**Log attributes**: everything you sent. Tap a value to **Include** (=) or **Exclude** (≠) it as a filter, or copy it.',
        '**Error** (error/fatal logs): type, message, your reason and the stack trace, with **Copy error**.',
        '**Related**: all logs of the same session or trace, and **Same pattern** to find similar messages.',
        '**Value breakdown**: how a field’s values are spread across the loaded logs.',
        '**Copy as JSON**: the whole log, e.g. to paste into a ticket.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'search',
    title: 'Search',
    icon: Icons.search_rounded,
    category: HelpCategory.app,
    summary: 'How the search box matches words, and when to use a filter instead.',
    related: ['filters', 'logs-page'],
    blocks: const [
      HBullets([
        'Search matches **whole words** of the message, case-insensitive: `payment failed` finds logs containing both words.',
        'Words are 2–40 letters, digits or `_`; punctuation splits words (`order#42` → `order`, `42`).',
        'Partial words don’t match: `pay` won’t find `payment`. Use a filter **message contains pay** for that.',
        'Attributes aren’t searched; filter them instead.',
      ]),
      HTip('The longest word is searched on the server; the rest is checked in the app, so put a distinctive word in your search.'),
    ],
  ),
  HelpTopic(
    id: 'filters',
    title: 'Filters & operators',
    icon: Icons.filter_alt_outlined,
    category: HelpCategory.app,
    summary: 'Filter on any field: every built-in field and every custom attribute.',
    related: ['attributes', 'search'],
    blocks: const [
      HText(
        'Tap **Add filter**, open **Field** and pick from *Built-in fields* or *Custom attributes* (every attribute your '
        'apps have sent, remembered per project), or type any name — even one not seen yet. Nested values use dots: `device.model`.',
      ),
      HFields(title: 'Operators', [
        HField('equals', '=', 'Exact text, or the same number (`9.5 = 9.50`), or true/false. For lists: any item equals.'),
        HField('does not equal', '≠', 'Anything else, including logs without the field.'),
        HField('contains', '~', 'Text contains the value, case-insensitive.'),
        HField('does not contain', '!~', 'The opposite.'),
        HField('greater than', '>', 'Numbers (`duration_ms > 500`); falls back to text order.'),
        HField('less than', '<', 'Numbers (`battery < 0.2`).'),
        HField('is set', '∃', 'The field exists.'),
        HField('is not set', '∄', 'The field is missing.'),
      ]),
      HFields(title: 'Built-in log fields', [
        HField('service.name', 'String', 'The logger’s service.'),
        HField('severity', 'String', 'trace, debug, info, warn, error, fatal.'),
        HField('message', 'String', 'The log text.'),
        HField('pattern', 'String', 'The message with numbers/IDs replaced, used for issues.'),
        HField('userId / sessionId / traceId', 'String', 'IDs set on the logger.'),
        HField('error.type / error.message / error.reason', 'String', 'Error details of error/fatal logs.'),
      ]),
      HTip('Activity has its own built-ins: `event`, `distinctId`, `sessionId`, `service.name`, plus every event property.'),
      HTip(
        'Service, level, time and one search word run on the server. Other filters are applied in the app while '
        'scanning (up to 1,000 logs per page), so very rare matches in a huge range may need a shorter range.',
        kind: TipKind.warning,
      ),
    ],
  ),
  HelpTopic(
    id: 'activity',
    title: 'Activity',
    icon: Icons.bolt_outlined,
    category: HelpCategory.app,
    summary: 'Every product event, live, with filters, columns and charts.',
    related: ['events-sdk', 'people', 'dashboards'],
    blocks: const [
      HBullets([
        'Choose a **time range** and which **events** to show (all by default).',
        '**Filter** on `event`, `distinctId`, `sessionId`, `service.name` or any event property.',
        '**Columns**: add event properties as table columns.',
        '**Live** shows new events as they arrive.',
        'The dashboard icon adds the current view to a dashboard as a count or chart.',
        'Tap an event to see its properties and jump to the person or session.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'funnels',
    title: 'Funnels & retention',
    icon: Icons.filter_alt_outlined,
    category: HelpCategory.app,
    summary: 'How many people get through a series of events, and how many come back.',
    related: ['activity', 'events-sdk', 'people'],
    blocks: const [
      HHeading('Funnel'),
      HBullets([
        'Add 2–10 **steps** (event names). A person counts at a step if they did every step before it, **in order**, '
            'all within the **conversion window** of step 1.',
        'Each step shows how many people reached it, the share of everyone who started, how many dropped off, and the '
            'median time from the previous step.',
        'People are counted once, from their attempt that got furthest.',
      ]),
      HHeading('Retention'),
      HBullets([
        'People join the cohort of the day (or week, starting Monday) when they first did the **start event**.',
        '**Day N / Week N** shows the share who did the **return event** in that later period. Periods that haven’t '
            'finished are left empty; **Average** weighs cohorts by size.',
      ]),
      HTip(
        'Both are worked out in the app from up to 5,000 events of the chosen names (one Firestore read each). '
        'If a range has more, the newest 5,000 are used and the page says so; pick a shorter range for exact results. '
        'Your last setup is remembered on this device.',
      ),
    ],
  ),
  HelpTopic(
    id: 'issues',
    title: 'Issues (error tracking)',
    icon: Icons.bug_report_outlined,
    category: HelpCategory.app,
    summary: 'Errors grouped into issues you can resolve, ignore and assign.',
    related: ['errors', 'alerts'],
    blocks: const [
      HText(
        'Every error and fatal log in the range is grouped by **service + error type + message pattern**. '
        'Each issue shows how often it happened, when it was first and last seen, and which services are affected.',
      ),
      HFields(title: 'Statuses', [
        HField('Open', '—', 'Needs attention (default).'),
        HField('Resolved', '—', 'Fixed. If the error happens again afterwards, the issue is marked **regressed** and moves to the top.'),
        HField('Ignored', '—', 'Hidden from Overview; still listed on Issues.'),
      ]),
      HBullets([
        'Admins and owners can change the status and **assign** an issue to a member.',
        'Open an issue to see its logs on the Logs page (filtered by pattern).',
        'Issues are computed from the error logs in the selected range (up to the latest 1,000).',
      ]),
    ],
  ),
  HelpTopic(
    id: 'dashboards',
    title: 'Dashboards',
    icon: Icons.dashboard_customize_outlined,
    category: HelpCategory.app,
    summary: 'Build your own boards of numbers and charts from logs and events.',
    related: ['logs-page', 'activity', 'recents'],
    blocks: const [
      HSteps([
        'Open **Dashboards → New dashboard** and give it a name.',
        'Tap **Add tile**: choose **Logs** or **Events**, show it as a **Number** or **Bar chart**, then pick a service, levels, search words or an event.',
        'Or build the exact view on Logs/Activity first and use **Add to dashboard** — every filter is kept.',
        'Pick the dashboard’s time range (1h … 90d); all tiles use it.',
      ]),
      HBullets([
        'Tap a tile to open it in Logs or Activity. The tile menu can edit, move or remove it.',
        'Up to 30 tiles per dashboard. Any member can create and edit dashboards; the creator or an admin can delete them.',
        'Star a dashboard to keep it in Starred.',
      ]),
      HTip('Number tiles with attribute filters count by scanning logs (up to 5,000, shown as “5,000+”).'),
    ],
  ),
  HelpTopic(
    id: 'endpoints',
    title: 'Endpoints page',
    icon: Icons.alt_route_outlined,
    category: HelpCategory.app,
    summary: 'Calls, error rate and p50/p95 latency per API route.',
    related: ['endpoints-sdk'],
    blocks: const [
      HBullets([
        'Shows request logs sent with `request()`, grouped by **method + route**.',
        '**Errors**: 5xx responses (or failed requests without a response). 4xx are shown separately.',
        '**p50 / p95**: half / 95% of requests were faster than this.',
        'Sort by most calls, most errors, highest error rate or slowest.',
        'Tap a route to open its logs; the red icon opens only the failed ones.',
        'Based on the latest 3,000 requests in the range.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'people',
    title: 'People',
    icon: Icons.people_outline,
    category: HelpCategory.app,
    summary: 'Everyone who used your app: properties, events, sessions and logs.',
    related: ['events-sdk'],
    blocks: const [
      HBullets([
        'People are created by events. `identify()` merges the anonymous person with your user ID.',
        'A person page shows **Properties** (from identify / setPersonProperties), **Activity**, **Sessions** and **Logs** (logs need `userId`, which identify sets).',
        'Turn on **Show anonymous** to include people who never signed in.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'alerts',
    title: 'Alerts',
    icon: Icons.notifications_outlined,
    category: HelpCategory.app,
    summary: 'Slack, Discord or webhook messages when errors spike or a service goes quiet.',
    related: ['issues'],
    blocks: const [
      HFields(title: 'Alert types', [
        HField('Error spike', 'threshold', 'Errors (error + fatal) in the window reach the threshold.'),
        HField('Log volume', 'threshold', 'Logs of any level in the window reach the threshold.'),
        HField('Service went quiet', '—', 'No logs at all from the service during the window.'),
      ]),
      HBullets([
        'Window: 5 minutes to 24 hours. Service: one or all.',
        'Webhook: any HTTPS URL, e.g. a Slack or Discord incoming webhook. You get a message when it fires and when it recovers.',
        'Rules are checked every 5 minutes by a Cloud Function (needs the Firebase Blaze plan). History lists every firing.',
        'Admins and owners create and edit alerts.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'flags',
    title: 'Feature flags page',
    icon: Icons.toggle_off_outlined,
    category: HelpCategory.app,
    summary: 'Create flags, roll out gradually, target by property and test a person.',
    related: ['flags-sdk'],
    blocks: const [
      HSteps([
        'Tap **New flag** and enter a key such as `new-checkout` (lowercase letters, numbers, `-`, `_`). The key can’t change later.',
        'Set the **rollout** (0–100%) and optional **conditions** (e.g. `plan equals pro`, `app.version greater than 2`). All conditions must match.',
        'Use **Test a person**: enter an ID and properties to see whether they’d get the flag.',
        'Use the switch on the list to turn a flag on or off instantly.',
      ]),
      HTip('Apps see changes after their next `reloadFeatureFlags()` — call it on startup and when the app resumes.'),
      HTip('Admins and owners can edit flags; everyone in the project can see them.'),
    ],
  ),
  HelpTopic(
    id: 'data',
    title: 'Data management',
    icon: Icons.dataset_outlined,
    category: HelpCategory.app,
    summary: 'Every event your apps send, with its properties, description and verified badge.',
    related: ['events-sdk'],
    blocks: const [
      HBullets([
        'Events and their property names are registered automatically the first time they’re sent.',
        'Admins can add a **description** and mark events **verified**, so the team knows which ones to trust.',
        'Each event shows how often it happened in the last 7 days.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'keys',
    title: 'Ingest keys',
    icon: Icons.key_outlined,
    category: HelpCategory.app,
    summary: 'Keys your apps use to send data, with ready-made setup code.',
    related: ['start', 'http'],
    blocks: const [
      HBullets([
        'Create one key per app or environment (e.g. “iOS production”, “Android staging”).',
        'A key can only **add** logs and events (and read feature flags). It can’t read or delete anything, so it is safe to ship inside an app.',
        '**Disable** a key to stop an app immediately; data already sent is kept. Delete removes it for good.',
        'Select a key to see the setup guide: Dart, Swift and curl examples with that key filled in.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'members',
    title: 'Members & roles',
    icon: Icons.group_outlined,
    category: HelpCategory.app,
    summary: 'Invite teammates and what owners, admins and viewers can do.',
    blocks: const [
      HFields(title: 'Roles', [
        HField('Owner', '1 per project', 'Everything: invite/remove members, rename or delete the project, plus all admin rights.'),
        HField('Admin', '—', 'Ingest keys, alerts, feature flags, issue status/assignment, event descriptions, deleting logs.'),
        HField('Viewer', '—', 'Read everything; create saved views and dashboards.'),
      ]),
      HBullets([
        'Invite by email; the person accepts after signing in with that (verified) email.',
        'Members other than the owner can leave a project themselves.',
      ]),
    ],
  ),
  HelpTopic(
    id: 'settings',
    title: 'Project settings',
    icon: Icons.settings_outlined,
    category: HelpCategory.app,
    summary: 'Rename, project ID, deleting old logs, auto-save to files, deleting all data and deleting the project.',
    blocks: const [
      HBullets([
        '**Project ID**: needed in the logger setup.',
        '**Delete old logs**: remove every log older than N days (admins).',
        '**Auto-save logs as text**: on desktop and mobile, loaded logs are also written to text files in the app folder. In the browser use Export on the Logs page.',
        '**Delete all data** (owner): permanently deletes every log, event, person profile, event definition, issue '
            'status and alert history, plus this device’s saved text logs. The project, members, ingest keys, services, '
            'flags, dashboards, alerts and saved views stay. Apps still sending add new data at once; disable their ingest keys first to stop them.',
        '**Delete project** (owner): permanently deletes the project with all its data, keys and settings.',
      ]),
      HHeading('Automatic deletion (TTL)'),
      HText(
        'The SDKs give every log an `expireAt` time (by default 90 days after the log; set `retention` in the logger). '
        'Turn on a Firestore TTL policy for collection group `logs`, field `expireAt`, in the Google Cloud console '
        '(Firestore → Time-to-live) and old logs are deleted automatically, with nothing to run. Logs from older SDK '
        'versions have no `expireAt` and stay until deleted here.',
      ),
      HTip('Theme (light / dark / system) and the clock (12- or 24-hour times) are under Account → Appearance.'),
    ],
  ),
  HelpTopic(
    id: 'recents',
    title: 'Recents & Starred',
    icon: Icons.star_outline_rounded,
    category: HelpCategory.app,
    summary: 'Jump back to pages, dashboards and saved views you use often.',
    blocks: const [
      HBullets([
        '**Recents**: the last pages, dashboards and saved views you opened in this project.',
        '**Starred**: tap ☆ in the top bar (phone), hover a sidebar item (desktop) or star a dashboard.',
        'On phones they’re at the top of **More**; on desktop at the top of the sidebar.',
        'Kept on this device, per project.',
      ]),
    ],
  ),

  // ============================================================== reference
  HelpTopic(
    id: 'reference-log',
    title: 'Log fields',
    icon: Icons.table_rows_outlined,
    category: HelpCategory.reference,
    summary: 'Every field a log can have, with types and limits.',
    related: ['logs-sdk', 'errors', 'http'],
    blocks: const [
      HFields([
        HField('ts', 'timestamp', 'When it happened. Within the last 7 days, at most 1 hour ahead.', required: true),
        HField('severity', 'string', 'trace | debug | info | warn | error | fatal', required: true),
        HField('message', 'string', 'The log text.', required: true, limit: '10,000 chars'),
        HField('service', 'string', 'App or service name (service.name).', required: true, limit: '100 chars'),
        HField('key', 'string', 'Your ingest key.', required: true),
        HField('receivedAt', 'server time', 'Set by the server (REQUEST_TIME transform).', required: true),
        HField('tokens', 'string[]', 'Lowercase words of the message, for search.', limit: '64'),
        HField('attributes', 'map', 'Your custom fields (nested maps allowed).', limit: '64 keys'),
        HField('userId', 'string', 'The signed-in user.', limit: '128 chars'),
        HField('sessionId', 'string', 'Session.', limit: '128 chars'),
        HField('traceId', 'string', 'Operation or request.', limit: '128 chars'),
        HField('error.type', 'string', 'Exception type (error/fatal only).', limit: '200 chars'),
        HField('error.message', 'string', 'Exception message.', limit: '4,000 chars'),
        HField('error.reason', 'string', 'Your explanation.', limit: '4,000 chars'),
        HField('error.stack', 'string', 'Stack trace.', limit: '16,000 chars'),
      ]),
    ],
  ),
  HelpTopic(
    id: 'reference-event',
    title: 'Event & person fields',
    icon: Icons.table_chart_outlined,
    category: HelpCategory.reference,
    summary: 'Fields of events and people, with limits.',
    related: ['events-sdk', 'http'],
    blocks: const [
      HFields(title: 'Event', [
        HField('event', 'string', 'Event name.', required: true, limit: '200 chars'),
        HField('distinctId', 'string', 'Who did it.', required: true, limit: '200 chars'),
        HField('ts', 'timestamp', 'When. Within the last 7 days.', required: true),
        HField('key', 'string', 'Ingest key.', required: true),
        HField('receivedAt', 'server time', 'Set by the server.', required: true),
        HField('properties', 'map', 'Event properties.', limit: '128'),
        HField('sessionId', 'string', 'Session.', limit: '128 chars'),
        HField('service', 'string', 'App or service.', limit: '100 chars'),
      ]),
      HFields(title: 'Person', [
        HField('properties', 'map', 'Merged with each identify / setPersonProperties.', limit: '200'),
        HField('aliases', 'string[]', 'Earlier anonymous IDs linked by identify.', limit: '50'),
        HField('firstSeen / lastSeen', 'time', 'Kept up to date automatically.'),
      ]),
    ],
  ),
  HelpTopic(
    id: 'limits',
    title: 'Limits & defaults',
    icon: Icons.rule_rounded,
    category: HelpCategory.reference,
    summary: 'All limits in one place.',
    blocks: const [
      HFields([
        HField('Logs per request', '500', 'batchSize, default 50.'),
        HField('Queue while offline', '5,000', 'maxQueue; oldest dropped first.'),
        HField('Send interval', '5 s', 'flushInterval.'),
        HField('Retry back-off', 'up to 5 min', 'Doubles after each failure.'),
        HField('Log timestamp', '7 days back, 1 h ahead', 'Older/newer logs are rejected.'),
        HField('Attributes per log', '64', 'Including defaultAttributes.'),
        HField('Event properties', '128', 'Person properties: 200.'),
        HField('Message', '10,000 chars', 'Error stack 16,000; reason and error message 4,000.'),
        HField('Dashboard tiles', '30', 'Per dashboard.'),
        HField('Flag conditions', '10', 'Per flag; rollout 0–100%.'),
        HField('Logs page scan', '1,000', 'Logs read per page when filters run in the app.'),
      ]),
    ],
  ),
];
