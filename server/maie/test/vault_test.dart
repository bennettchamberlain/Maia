import 'dart:io';

import 'package:maie_api/src/vault/vault.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late VaultStore vault;
  const person = 'f2260050-d36b-11f1-97fe-d71ec3ee2d0a';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('maie-vault');
    vault = VaultStore(root: root, secret: 's' * 32);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('a secret becomes a handle and stays out of the file', () async {
    final handle = await vault.put(person, 'gmail', 'super-secret-token');
    expect(handle.dummy, startsWith('cred_'));
    expect(handle.dummy, hasLength(13));
    final listed = await vault.list(person);
    expect(listed.single.name, 'gmail');
    expect(listed.single.dummy, handle.dummy);
    final raw = await File('${root.path}/$person/gmail.json').readAsString();
    expect(raw, isNot(contains('super-secret-token')));
    expect(
      await vault.scrub(person, 'login with super-secret-token now'),
      'login with ${handle.dummy} now',
    );
  });

  test('the handle stays when the secret changes', () async {
    final first = await vault.put(person, 'gmail', 'super-secret-token');
    final second = await vault.put(person, 'gmail', 'rotated-secret-value');
    expect(second.dummy, first.dummy);
    expect(await vault.scrub(person, 'rotated-secret-value'), first.dummy);
  });

  test('a mentioned handle is the only one injected', () async {
    final gmail = await vault.put(person, 'gmail', 'super-secret-token');
    await vault.put(person, 'instabox', 'ibk-not-for-the-model');
    final files = await vault.filesFor(
      person,
      'use ${gmail.dummy} on the form',
    );
    expect(files, {gmail.dummy: 'super-secret-token'});
    expect(await vault.instaboxKey(person), 'ibk-not-for-the-model');
  });

  test('a bad name is refused', () async {
    expect(
      () => vault.put(person, 'Gmail Password', 'super-secret-token'),
      throwsA(isA<VaultException>()),
    );
  });
}
