import 'package:maia_api/src/chat/graphs.dart';
import 'package:test/test.dart';

void main() {
  test('a sync request is not an account graph', () {
    expect(playbookFor('Sync GitHub now'), isNull);
    expect(
      playbookFor('In one sentence, what is a directed acyclic graph?'),
      isNull,
    );
  });

  test('github and gmail wait on memory and not on each other', () {
    final book = playbookFor(
      'What is my GitHub login, and who sent my latest Gmail?',
    );
    expect(book, isNotNull);
    final memoryDone = readyNodes(book!.nodes, {});
    expect(memoryDone.map((node) => node.id), ['memory']);
    final reads = readyNodes(book.nodes, {'memory'});
    expect(reads.map((node) => node.id), ['read-github', 'read-gmail']);
  });

  test('a failed read stays failed in the checkpoint', () async {
    final book = playbookFor('What is my GitHub login?');
    final checkpoint = await runGraph(
      book: book!,
      ask: 'What is my GitHub login?',
      call: (tool, arguments) async {
        if (tool == 'memory_search') {
          return '{"type":"text","text":"no memories"}';
        }
        return '{"type":"text","text":"One could not read github (failed)."}';
      },
    );
    expect(checkpoint.calls.map((call) => call.tool), [
      'memory_search',
      'connector',
    ]);
    expect(checkpoint.calls.last.failed, isTrue);
    expect(checkpoint.note, contains('did not return'));
    expect(checkpoint.note, contains('do not have'));
    expect(checkpoint.waves, hasLength(2));
  });

  test('memory that already names the account skips the connector', () async {
    final book = playbookFor('What is in my GitHub account?');
    final checkpoint = await runGraph(
      book: book!,
      ask: 'What is in my GitHub account?',
      call: (tool, arguments) async =>
          '{"type":"text","text":"github repo maia"}',
    );
    expect(checkpoint.calls.single.tool, 'memory_search');
    expect(checkpoint.calls.single.failed, isFalse);
  });
}
