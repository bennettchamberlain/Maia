import 'dart:async';

import 'package:flutter/services.dart';
import 'package:maie_app/ui/glass.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The logo shader, full bleed, behind the glass. Pointers pass through.
class FieldBackdrop extends StatefulWidget {
  const new({super.key});

  @override
  State<FieldBackdrop> createState() => _FieldBackdropState();
}

class _FieldBackdropState extends State<FieldBackdrop> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final html = await rootBundle.loadString('assets/field/index.html');
    const query = '?bg=1&speed=0.35&relief=0.72&grain=1.2&mud=0.18&yaw=0.03';
    final patched = html.replaceFirst(
      'const params = new URLSearchParams(location.search);',
      'const params = new URLSearchParams(location.search.length > 1 '
          '? location.search : "$query");',
    );
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(bone);
    await controller.loadHtmlString(patched, baseUrl: 'https://maie.field');
    if (!mounted) return;
    setState(() => _controller = controller);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const ColoredBox(color: bone);
    return WebViewWidget(controller: controller);
  }
}
