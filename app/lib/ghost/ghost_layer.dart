import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:maia_app/ghost/ghost_store.dart';
import 'package:material_ui/material_ui.dart';

/// Drives the running app the way a person would: a cursor moves, a click
/// lands, typing appears in the field. Each click and each typed line is
/// stored as a frame so the tape can be played back.
class Ghost {
  static _GhostLayerState? _stage;

  /// Tests click on the next frame, with no glide. The running app animates.
  static bool instant = false;

  /// Move onto the widget with this key and click it.
  static Future<void> tapKey(String name) {
    final stage = _stage;
    if (stage == null) throw StateError('Ghost is not on screen');
    return stage.tapKey(name);
  }

  /// Click [key], then type [text] into the field inside it.
  static Future<void> type(String text, {String key = 'chat_composer'}) {
    final stage = _stage;
    if (stage == null) throw StateError('Ghost is not on screen');
    return stage.type(text, key: key);
  }

  /// Play the latest tape: each saved frame, in order.
  static Future<void> play() {
    final stage = _stage;
    if (stage == null) throw StateError('Ghost is not on screen');
    return stage.play();
  }

  /// Folder holding `tape.json` and the frames.
  static String? get directory => tapeDirectory();
}

/// Draws the cursor above [child] in debug builds. Release builds are
/// the child alone.
class GhostLayer extends StatelessWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return child;
    return _GhostStage(child: child);
  }
}

var _extensionReady = false;

class _GhostStage extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_GhostStage> createState() => _GhostLayerState();
}

class _GhostLayerState extends State<_GhostStage>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundary = GlobalKey();
  final List<Map<String, Object?>> _events = [];
  final DateTime _started = DateTime.now();
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  Offset _cursor = Offset.zero;
  var _shown = false;
  var _flash = false;
  Uint8List? _frame;
  var _pointer = 1;

  @override
  void initState() {
    super.initState();
    Ghost._stage = this;
    _register();
  }

  @override
  void dispose() {
    if (Ghost._stage == this) Ghost._stage = null;
    _clock.dispose();
    super.dispose();
  }

  void _register() {
    if (_extensionReady) return;
    final binding = WidgetsBinding.instance.runtimeType.toString();
    if (binding.contains('Test')) return;
    _extensionReady = true;
    developer.registerExtension('ext.maia.ghost', (method, params) async {
      try {
        final op = params['op'] ?? '';
        switch (op) {
          case 'tap':
            await Ghost.tapKey(params['key'] ?? '');
          case 'type':
            await Ghost.type(
              params['text'] ?? '',
              key: params['key'] ?? 'chat_composer',
            );
          case 'play':
            await Ghost.play();
          case 'where':
            break;
          default:
            return developer.ServiceExtensionResponse.error(
              developer.ServiceExtensionResponse.extensionError,
              'op is tap, type, play, or where',
            );
        }
        return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true, 'tape': tapeDirectory()}),
        );
      } on Object catch (err) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          '$err',
        );
      }
    });
  }

  Future<void> tapKey(String name) async {
    final box = _box(Key(name));
    if (box == null) throw StateError('No widget keyed $name');
    final target = box.localToGlobal(box.size.center(Offset.zero));
    await _glide(target);
    await _click(target);
    _note({'kind': 'tap', 'key': name, 'x': target.dx, 'y': target.dy});
    await _shot(name);
  }

  Future<void> type(String text, {required String key}) async {
    await tapKey(key);
    final field = _field(Key(key));
    final controller = field?.controller;
    if (controller == null) throw StateError('No field inside $key');
    field!.focusNode?.requestFocus();
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final next = controller.text + char;
      controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
      _note({'kind': 'type', 'key': key, 'text': char});
      await _hold(const Duration(milliseconds: 28));
    }
    await _shot('typed');
  }

  Future<void> play() async {
    final raw = await readTape();
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final events = decoded['events'];
    if (events is! List) return;
    for (final event in events) {
      if (event is! Map || event['file'] is! String) continue;
      final bytes = await readShot(event['file'] as String);
      if (!mounted || bytes == null) continue;
      setState(() => _frame = Uint8List.fromList(bytes));
      await _hold(const Duration(milliseconds: 700));
    }
    if (mounted) setState(() => _frame = null);
  }

  Future<void> _glide(Offset target) {
    if (Ghost.instant) {
      _shown = true;
      _cursor = target;
      return Future<void>.value();
    }
    final from = _shown ? _cursor : const Offset(28, 28);
    final done = Completer<void>();
    void tick() {
      if (!mounted) return;
      setState(() {
        _shown = true;
        _cursor = Offset.lerp(
          from,
          target,
          Curves.easeInOutCubic.transform(_clock.value),
        )!;
      });
    }

    _clock.addListener(tick);
    unawaited(
      _clock.forward(from: 0).whenComplete(() {
        _clock.removeListener(tick);
        if (!done.isCompleted) done.complete();
      }),
    );
    return done.future;
  }

  Future<void> _click(Offset target) {
    if (Ghost.instant) {
      _down(target);
      _up(target);
      return Future<void>.value();
    }
    if (mounted) setState(() => _flash = true);
    final done = Completer<void>();
    Future<void>.delayed(Duration.zero, () {
      _down(target);
      _up(target);
      if (mounted) setState(() => _flash = false);
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  Future<void> _hold(Duration duration) {
    if (Ghost.instant) return Future<void>.value();
    _clock.duration = duration;
    final done = Completer<void>();
    unawaited(
      _clock.forward(from: 0).whenComplete(() {
        _clock.duration = const Duration(milliseconds: 320);
        if (!done.isCompleted) done.complete();
      }),
    );
    return done.future;
  }

  void _down(Offset global) {
    WidgetsBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: _pointer,
        kind: PointerDeviceKind.mouse,
        position: global,
      ),
    );
  }

  void _up(Offset global) {
    WidgetsBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: _pointer,
        kind: PointerDeviceKind.mouse,
        position: global,
      ),
    );
    _pointer += 1;
  }

  void _note(Map<String, Object?> event) {
    event['ms'] = DateTime.now().difference(_started).inMilliseconds;
    _events.add(event);
    unawaited(saveTape(jsonEncode({'events': _events})));
  }

  Future<void> _shot(String label) async {
    final binding = WidgetsBinding.instance.runtimeType.toString();
    if (binding.contains('Test')) {
      _note({'kind': 'shot', 'label': label});
      return;
    }
    final object = _boundary.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) return;
    try {
      final image = await object.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final name = await saveShot(data.buffer.asUint8List());
      _note({'kind': 'shot', 'label': label, 'file': ?name});
    } on Object {
      return;
    }
  }

  Element? _element(Key key) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  RenderBox? _box(Key key) {
    final object = _element(key)?.renderObject;
    if (object is RenderBox && object.attached && object.hasSize) {
      return object;
    }
    return null;
  }

  TextField? _field(Key key) {
    final root = _element(key);
    if (root == null) return null;
    TextField? field;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is TextField &&
          widget.enabled != false &&
          widget.controller != null) {
        field = widget;
      }
      element.visitChildren(visit);
    }

    visit(root);
    return field;
  }

  Offset _local() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return _cursor;
    return box.globalToLocal(_cursor);
  }

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return RepaintBoundary(
      key: _boundary,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_shown && _frame == null)
            IgnorePointer(
              child: CustomPaint(
                painter: _CursorPainter(at: _local(), flash: _flash, ink: ink),
                child: const SizedBox.expand(),
              ),
            ),
          if (_frame != null)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xFF08040E),
                child: Image.memory(_frame!, fit: BoxFit.contain),
              ),
            ),
        ],
      ),
    );
  }
}

class _CursorPainter extends CustomPainter {
  const new({required this.at, required this.flash, required this.ink});

  final Offset at;
  final bool flash;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = ink
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas
      ..drawLine(at + const Offset(-8, 0), at + const Offset(8, 0), line)
      ..drawLine(at + const Offset(0, -8), at + const Offset(0, 8), line);
    if (!flash) return;
    canvas.drawCircle(
      at,
      6,
      Paint()
        ..color = const Color(0xFFFFBA40)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_CursorPainter old) =>
      old.at != at || old.flash != flash || old.ink != ink;
}
