import 'dart:io';

import 'package:maia_api/src/auth/password.dart';

void main(List<String> args) {
  stdout.writeln(const Password().hash(args.first));
}
