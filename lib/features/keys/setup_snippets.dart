/// Code samples that show how an app sends logs to LogSight.
///
/// Logs go straight to Firestore's REST API, so apps don't need the
/// Firebase SDK or their own Firebase project.
class SetupSnippets {
  const SetupSnippets({required this.firebaseProjectId, required this.projectId, required this.ingestKey});

  final String firebaseProjectId;
  final String projectId;
  final String ingestKey;

  String get endpoint =>
      'https://firestore.googleapis.com/v1/projects/$firebaseProjectId/databases/(default)/documents:commit';

  String get dart =>
      '''
// pubspec.yaml
// dependencies:
//   apptrack_logger:
//     path: ../apptrack/packages/apptrack_logger   # or a git dependency

import 'package:apptrack_logger/apptrack_logger.dart';

final appTrack = AppTrackLogger(
  firebaseProjectId: '$firebaseProjectId',
  projectId: '$projectId',
  ingestKey: '$ingestKey',
  service: 'my_flutter_app',            // shown as service_name
  defaultAttributes: {'app.version': '1.0.0'},
  // Optional: keep unsent logs on disk so they survive crashes and restarts,
  // e.g. '\${(await getApplicationSupportDirectory()).path}/apptrack_queue.jsonl'
  // queueFilePath: '/path/to/apptrack_queue.jsonl',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Send crashes to LogSight (type, message, stack trace).
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    appTrack.recordFlutterError(details);
  };
  PlatformDispatcher.instance.onError = appTrack.recordUncaughtError;

  // Activity: product events and people (like PostHog capture/identify).
  // Save appTrack.distinctId and pass it back as distinctId: next launch.
  appTrack.sessionId = 'session-id';          // groups events into sessions
  appTrack.screen('Home');
  appTrack.capture('purchase_completed', properties: {'plan': 'pro', 'amount': 9.99});
  appTrack.identify('user-123', properties: {'email': 'ana@example.com', 'plan': 'pro'});
  // On sign-out: appTrack.reset();

  // Logs
  appTrack.info('App started');
  appTrack.warn('Slow response', attributes: {'endpoint': '/orders', 'ms': 2300});
  // Logs are batched and sent every few seconds; call flush() before exit.
}''';

  String get swift =>
      '''
import Foundation

/// Minimal LogSight client for iOS / macOS (URLSession, no dependencies).
final class LogSight {
    static let shared = LogSight(service: "my_ios_app")

    private let endpoint = URL(string:
      "$endpoint")!
    private let docBase =
      "projects/$firebaseProjectId/databases/(default)/documents/projects/$projectId/logs/"
    private let key = "$ingestKey"
    private let service: String

    init(service: String) { self.service = service }

    func log(_ severity: String, _ message: String, attributes: [String: String] = [:]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tokens = Set(message.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "_")).inverted)
            .filter { \$0.count >= 2 && \$0.count <= 40 }).prefix(64)
        var fields: [String: Any] = [
            "ts": ["timestampValue": iso.string(from: Date())],
            "severity": ["stringValue": severity],
            "message": ["stringValue": message],
            "service": ["stringValue": service],
            "key": ["stringValue": key],
            "tokens": ["arrayValue": ["values": tokens.map { ["stringValue": \$0] }]],
        ]
        if !attributes.isEmpty {
            fields["attributes"] = ["mapValue": ["fields":
                attributes.mapValues { ["stringValue": \$0] }]]
        }
        let body: [String: Any] = ["writes": [[
            "update": ["name": docBase + UUID().uuidString, "fields": fields],
            "currentDocument": ["exists": false],
            "updateTransforms": [["fieldPath": "receivedAt",
                                  "setToServerValue": "REQUEST_TIME"]],
        ]]]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    func info(_ m: String, _ a: [String: String] = [:])  { log("info", m, attributes: a) }
    func warn(_ m: String, _ a: [String: String] = [:])  { log("warn", m, attributes: a) }
    func error(_ m: String, _ a: [String: String] = [:]) { log("error", m, attributes: a) }
}

// Usage:
// LogSight.shared.info("User signed in", ["user.plan": "pro"])''';

  String get curl =>
      '''
curl -X POST \\
  '$endpoint' \\
  -H 'Content-Type: application/json' \\
  -d '{
  "writes": [{
    "update": {
      "name": "projects/$firebaseProjectId/databases/(default)/documents/projects/$projectId/logs/'"\$(uuidgen)"'",
      "fields": {
        "ts":       {"timestampValue": "'"\$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"},
        "severity": {"stringValue": "info"},
        "message":  {"stringValue": "Hello from curl"},
        "service":  {"stringValue": "my_service"},
        "key":      {"stringValue": "$ingestKey"},
        "tokens":   {"arrayValue": {"values": [
          {"stringValue": "hello"}, {"stringValue": "from"}, {"stringValue": "curl"}]}},
        "attributes": {"mapValue": {"fields": {"env": {"stringValue": "dev"}}}}
      }
    },
    "currentDocument": {"exists": false},
    "updateTransforms": [{"fieldPath": "receivedAt", "setToServerValue": "REQUEST_TIME"}]
  }]
}\'''';

  String get schema =>
      '''
Each log is a document in projects/$projectId/logs with these fields:

  ts          timestamp  required  when the event happened (within the last 7 days)
  severity    string     required  trace | debug | info | warn | error | fatal
  message     string     required  up to 10,000 characters
  service     string     required  app or service name (shown as service_name)
  key         string     required  your ingest key
  receivedAt  server     required  set with the REQUEST_TIME transform
  tokens      string[]   optional  lowercase words of the message, for search
  attributes  map        optional  up to 64 custom fields (nested maps are OK)
  userId, sessionId, traceId   string, optional

Send up to 500 logs per request by putting several writes in one commit.''';
}
