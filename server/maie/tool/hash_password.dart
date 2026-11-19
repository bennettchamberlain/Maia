import 'dart:io';

import 'package:maie_api/src/auth/password.dart';

void main(List<String> args) {
  stdout.writeln(const Password().hash(args.first));
}
