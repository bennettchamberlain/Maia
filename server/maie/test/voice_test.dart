import 'dart:convert';

import 'package:maie_api/src/config.dart';
import 'package:maie_api/src/voice/polargrid.dart';
import 'package:maie_api/src/voice/supervisor.dart';
import 'package:test/test.dart';

const _secret = 'a-very-long-secret-at-least-32-chars!!';

Config _cfg(Map<String, String> extra) => Config.fromEnv({
  'MAIE_SESSION_SECRET': _secret,
  'VOICE_BIN': '/no/such/maie-voice',
  ...extra,
});

void main() {
  group('PolarGrid voice', () {
    test('reads the key under either name', () {
      final named = _cfg({
        'POLARGRID_API_KEY': 'pg_test',
        'POLARGRID_REGION': 'yto-01',
        'POLARGRID_VOICE': 'NATF2',
      });
      final hyphen = _cfg({'polargrid-api-key': 'pg_hyphen'});
      expect(named.polargridApiKey, 'pg_test');
      expect(named.polargridVoice, 'NATF2');
      expect(hyphen.polargridApiKey, 'pg_hyphen');
      expect(hyphen.polargridRegion, 'yto-01');
    });

    test('start reports a loaded engine and hides the key', () async {
      const key = 'pg_secret_value';
      final voice = PolarGridVoice(
        _cfg({'POLARGRID_API_KEY': key, 'POLARGRID_PERSONA': 'Maie'}),
      );
      final status = await VoiceSupervisor(
        voice.config,
        polarCheck: () async => true,
      ).start();
      final encoded = jsonEncode(status);
      expect(status['provider'], 'polargrid');
      expect(status['engine'], containsPair('loaded', true));
      expect(encoded.contains(key), isFalse);
      expect(voice.endpoint.queryParameters['token'], isNull);
      expect(voice.endpoint.queryParameters['voice'], 'NATF0');
      expect(voice.endpoint.queryParameters['persona'], 'Maie');
      expect(voice.say('hello'), isFalse);
    });

    test('a dead PolarGrid edge falls back without throwing', () async {
      final status = await VoiceSupervisor(
        _cfg({'POLARGRID_API_KEY': 'pg_dead'}),
        polarCheck: () async => false,
      ).start();
      expect(status['available'], isFalse);
      expect(status['provider'], isNull);
      expect(status['reason'], contains('PolarGrid'));
      expect(jsonEncode(status).contains('pg_dead'), isFalse);
    });

    test('no PolarGrid key and no sidecar is still not a crash', () async {
      final status = await VoiceSupervisor(
        _cfg(const {}),
        polarCheck: () async => false,
      ).start();
      expect(status['available'], isFalse);
      expect(status['engine'], containsPair('loaded', false));
    });
  });
}
