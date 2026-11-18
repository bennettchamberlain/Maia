import 'dart:convert';

import 'package:maia_api/src/config.dart';
import 'package:maia_api/src/voice/polargrid.dart';
import 'package:maia_api/src/voice/supervisor.dart';
import 'package:test/test.dart';

const _secret = 'a-very-long-secret-at-least-32-chars!!';

void main() {
  group('PolarGrid voice', () {
    test('reads the key under either name', () {
      final named = Config.fromEnv({
        'MAIA_SESSION_SECRET': _secret,
        'POLARGRID_API_KEY': 'pg_test',
        'POLARGRID_REGION': 'yto-01',
        'POLARGRID_VOICE': 'NATF2',
      });
      final hyphen = Config.fromEnv({
        'MAIA_SESSION_SECRET': _secret,
        'polargrid-api-key': 'pg_hyphen',
      });
      expect(named.polargridApiKey, 'pg_test');
      expect(named.polargridVoice, 'NATF2');
      expect(hyphen.polargridApiKey, 'pg_hyphen');
      expect(hyphen.polargridRegion, 'yto-01');
    });

    test('start reports a loaded engine and hides the key', () async {
      const key = 'pg_secret_value';
      final voice = PolarGridVoice(
        Config.fromEnv({
          'MAIA_SESSION_SECRET': _secret,
          'POLARGRID_API_KEY': key,
          'POLARGRID_PERSONA': 'Maia',
        }),
      );
      final status = await VoiceSupervisor(voice.config).start();
      final encoded = jsonEncode(status);
      expect(status['provider'], 'polargrid');
      expect(status['engine'], containsPair('loaded', true));
      expect(encoded.contains(key), isFalse);
      expect(voice.endpoint.queryParameters['token'], isNull);
      expect(voice.endpoint.queryParameters['voice'], 'NATF0');
      expect(voice.endpoint.queryParameters['persona'], 'Maia');
      expect(voice.say('hello'), isFalse);
    });
  });
}
