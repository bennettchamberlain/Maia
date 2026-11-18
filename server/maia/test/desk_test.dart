import 'package:maia_api/src/desk/desk.dart';
import 'package:test/test.dart';

void main() {
  const person = 'f2260050-d36b-11f1-97fe-d71ec3ee2d0a';

  test('a missing desktop is created, and the secret stays on stdin', () async {
    final calls = <DeskCommand>[];
    final desk = ComputerDesk(
      call: (command) async {
        calls.add(command);
        if (command.args.contains('get')) {
          return const DeskOutput(4, '{"error":{"code":"not_found"}}', '');
        }
        if (command.args.contains('create')) {
          return const DeskOutput(0, '{"status":"running"}', '');
        }
        if (command.args.contains('agent')) {
          return const DeskOutput(0, '{"text":"opened the page"}', '');
        }
        return const DeskOutput(0, '', '');
      },
    );
    final text = await desk.run(
      personId: person,
      task: 'sign in with cred_ab12cd34',
      apiKey: 'ibk-owner',
      files: const {'cred_ab12cd34': 'super-secret-token'},
    );
    expect(text, contains('Started maiaf2260050d36b'));
    expect(text, contains('Their instabox account pays'));
    expect(text, contains('opened the page'));
    expect(text, isNot(contains('super-secret-token')));
    expect(text, isNot(contains('ibk-owner')));
    final create = calls.firstWhere((c) => c.args.contains('create'));
    expect(create.args, contains('agent-browser'));
    expect(create.args.join(' '), contains('maia_person=$person'));
    final write = calls.firstWhere((c) => c.stdin != null);
    expect(write.stdin, 'super-secret-token');
    expect(write.args.join(' '), isNot(contains('super-secret-token')));
    final agent = calls.firstWhere((c) => c.args.contains('agent'));
    expect(agent.args.join(' '), contains('.maia/vault/cred_ab12cd34'));
    expect(agent.args.join(' '), isNot(contains('super-secret-token')));
    expect(agent.env?['INSTABOX_API_KEY'], 'ibk-owner');
  });

  test('a sleeping desktop is woken, not created again', () async {
    final calls = <List<String>>[];
    final desk = ComputerDesk(
      call: (command) async {
        calls.add(command.args);
        if (command.args.contains('get')) {
          return const DeskOutput(0, '{"status":"suspended"}', '');
        }
        if (command.args.contains('wake')) {
          return const DeskOutput(0, '', '');
        }
        return const DeskOutput(0, '{"text":"done"}', '');
      },
    );
    final text = await desk.run(personId: person, task: 'open the inbox');
    expect(text, contains('Woke maiaf2260050d36b'));
    expect(text, contains('same desktop'));
    expect(text, contains('configured for this server'));
    expect(calls.any((args) => args.contains('create')), isFalse);
    expect(calls.any((args) => args.contains('wake')), isTrue);
  });
}
