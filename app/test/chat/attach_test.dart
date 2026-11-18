import 'package:flutter_test/flutter_test.dart';
import 'package:maia_app/chat/attach.dart';

void main() {
  test('text files are quoted, binary files are only named', () {
    expect(
      attachmentNote(name: 'note.txt', length: 5, bytes: 'hello'.codeUnits),
      '[file: note.txt]\nhello',
    );
    expect(
      attachmentNote(name: 'pic.png', length: 4, bytes: [0, 1, 2, 255]),
      '[file: pic.png, 4 bytes]',
    );
    expect(
      attachmentNote(name: 'big.bin', length: 90000),
      '[file: big.bin, 90000 bytes]',
    );
    expect(fileLabel('[file: note.txt]\nhello'), 'note.txt');
    expect(fileLabel('[file: pic.png, 4 bytes]'), 'pic.png');
  });
}
