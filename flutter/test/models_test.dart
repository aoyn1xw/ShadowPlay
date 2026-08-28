import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('pairing payload accepts the protocol v1 desktop QR shape', () {
    final payload = PairingPayload.fromJson({
      'v': 1,
      'serverId': 'server-1',
      'computerName': 'GAMING-PC',
      'lanAddress': '192.168.1.20',
      'port': 5177,
      'pairingCode': 'ABCD-1234',
    });

    expect(payload.computerName, 'GAMING-PC');
    expect(payload.address, '192.168.1.20');
    expect(payload.port, 5177);
  });

  test('connection persistence remains compatible without lastSeenUtc', () {
    final connection = Connection.fromJson({
      'serverId': 'server-1',
      'computerName': 'PC 1',
      'address': '192.168.1.20',
      'port': 5177,
    });

    expect(connection.lastSeenUtc, isNull);
    expect(connection.toJson()['serverId'], 'server-1');
  });

  test('onboarding stays complete only while at least one PC remains paired',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final connection = Connection(
      serverId: 'server-1',
      computerName: 'PC 1',
      address: '192.168.1.20',
      port: 5177,
    );
    final paired = AppState.forTesting(
      preferences,
      connections: [connection],
      activeServerId: connection.serverId,
    );

    expect(paired.needsOnboarding, isTrue);
    await paired.completeOnboarding();
    expect(paired.needsOnboarding, isFalse);

    final unpaired = AppState.forTesting(
      preferences,
      onboardingCompleted: true,
    );
    expect(unpaired.needsOnboarding, isTrue);
  });

  test('a downloaded clip leaves the new-clips queue', () async {
    final preferences = await SharedPreferences.getInstance();
    final clip = Clip(
      id: List.filled(64, 'a').join(),
      fileName: 'Ace.mp4',
      sizeBytes: 1000,
      lastWriteTimeUtc: DateTime.utc(2026, 8, 28),
    );
    final state = AppState.forTesting(
      preferences,
      remoteClips: [clip],
      downloadedClips: [
        DownloadedClip(
          id: clip.id,
          fileName: clip.fileName,
          sizeBytes: clip.sizeBytes,
          lastWriteTimeUtc: clip.lastWriteTimeUtc,
          localPath: 'unused-in-this-test.mp4',
        ),
      ],
    );

    expect(state.newClips, isEmpty);
    expect(state.newClipCount, 0);
  });
}
