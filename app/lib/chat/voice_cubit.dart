import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_models/maia_models.dart';
import 'package:maia_app/chat/parts/chat_part.dart';
import 'package:maia_app/chat/quote.dart';
import 'package:maia_app/ui/fault.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Why the microphone is open. Talk sends the words. Transcribe types them.
enum VoiceCapture { talk, transcribe }

class VoiceState extends Equatable {
  const new({
    this.enabled = false,
    this.listening = false,
    this.speaking = false,
    this.sttAvailable = false,
    this.ttsAvailable = false,
    this.sidecarLive = false,
    this.sidecarLoaded = false,
    this.sidecarLoading = false,
    this.sidecarStarting = false,
    this.sidecarTried = false,
    this.sidecarModel,
    this.keepUntil,
    this.capture,
    this.partial = '',
    this.liveLine = '',
    this.lastHeard,
    this.heardSeq = 0,
    this.transcript,
    this.transcriptSeq = 0,
    this.spokenMessageId,
    this.error,
  });

  /// User wants replies spoken and the mic offered.
  final bool enabled;
  final bool listening;
  final bool speaking;
  final bool sttAvailable;
  final bool ttsAvailable;
  final bool sidecarLive;
  final bool sidecarLoaded;
  final bool sidecarLoading;
  final bool sidecarStarting;
  final bool sidecarTried;
  final String? sidecarModel;
  final DateTime? keepUntil;
  final VoiceCapture? capture;
  final String partial;

  /// Words heard so far in this transcribe session. Grows with each partial.
  final String liveLine;
  final String? lastHeard;
  final int heardSeq;
  final String? transcript;
  final int transcriptSeq;
  final String? spokenMessageId;
  final String? error;

  VoiceState copyWith({
    bool? enabled,
    bool? listening,
    bool? speaking,
    bool? sttAvailable,
    bool? ttsAvailable,
    bool? sidecarLive,
    bool? sidecarLoaded,
    bool? sidecarLoading,
    bool? sidecarStarting,
    bool? sidecarTried,
    String? sidecarModel,
    DateTime? keepUntil,
    VoiceCapture? capture,
    String? partial,
    String? liveLine,
    String? lastHeard,
    int? heardSeq,
    String? transcript,
    int? transcriptSeq,
    String? spokenMessageId,
    String? error,
    bool clearHeard = false,
    bool clearError = false,
    bool clearCapture = false,
    bool clearSidecarModel = false,
  }) {
    return VoiceState(
      enabled: enabled ?? this.enabled,
      listening: listening ?? this.listening,
      speaking: speaking ?? this.speaking,
      sttAvailable: sttAvailable ?? this.sttAvailable,
      ttsAvailable: ttsAvailable ?? this.ttsAvailable,
      sidecarLive: sidecarLive ?? this.sidecarLive,
      sidecarLoaded: sidecarLoaded ?? this.sidecarLoaded,
      sidecarLoading: sidecarLoading ?? this.sidecarLoading,
      sidecarStarting: sidecarStarting ?? this.sidecarStarting,
      sidecarTried: sidecarTried ?? this.sidecarTried,
      sidecarModel: clearSidecarModel
          ? null
          : sidecarModel ?? this.sidecarModel,
      keepUntil: keepUntil ?? this.keepUntil,
      capture: clearCapture ? null : capture ?? this.capture,
      partial: partial ?? this.partial,
      liveLine: liveLine ?? this.liveLine,
      lastHeard: clearHeard ? null : lastHeard ?? this.lastHeard,
      heardSeq: heardSeq ?? this.heardSeq,
      transcript: transcript ?? this.transcript,
      transcriptSeq: transcriptSeq ?? this.transcriptSeq,
      spokenMessageId: spokenMessageId ?? this.spokenMessageId,
      error: clearError ? null : error ?? this.error,
    );
  }

  @override
  List<Object?> get props => [
    enabled,
    listening,
    speaking,
    sttAvailable,
    ttsAvailable,
    sidecarLive,
    sidecarLoaded,
    sidecarLoading,
    sidecarStarting,
    sidecarTried,
    sidecarModel,
    keepUntil,
    capture,
    partial,
    liveLine,
    lastHeard,
    heardSeq,
    transcript,
    transcriptSeq,
    spokenMessageId,
    error,
  ];
}

/// Local mouth and ears for chat. Thinking stays on Parasail through the API.
class VoiceCubit extends Cubit<VoiceState> {
  VoiceCubit({required MaiaApiClient api, SharedPreferences? prefs})
    : _api = api,
      _prefs = prefs,
      super(VoiceState(enabled: prefs?.getBool(_enabledKey) ?? false));

  static const _enabledKey = 'maia.voice.enabled';

  final MaiaApiClient _api;
  final SharedPreferences? _prefs;
  bool _wantListen = false;
  int _pendingSpeech = 0;
  bool _relistening = false;
  String _said = '';
  String _lastFinal = '';
  String _hypothesis = '';
  DateTime? _lastWordsAt;
  bool _breakBefore = false;
  SpeechToText? _stt;
  FlutterTts? _tts;
  Future<bool>? _boot;
  Future<void> _speech = Future<void>.value();
  int _speechGen = 0;
  String _queuedSpeech = '';

  void _note(String action, Object detail) {
    unawaited(_api.reportFault(action: action, detail: '$detail'));
  }

  Future<void> setEnabled({required bool on}) async {
    emit(state.copyWith(enabled: on, clearError: true));
    await _prefs?.setBool(_enabledKey, on);
    if (on) {
      await prepareSpeak();
      unawaited(startSidecar());
    } else {
      await stopListen();
      interruptSpeech();
      emit(state.copyWith(speaking: false));
    }
  }

  /// Talk stays on until it is pressed again. Off means nothing is read aloud.
  Future<void> setTalk({required bool on}) async {
    if (!on) {
      await setEnabled(on: false);
      return;
    }
    if (!state.enabled) await setEnabled(on: true);
    if (isClosed) return;
    if (state.listening && state.capture == VoiceCapture.talk) return;
    await begin(VoiceCapture.talk);
  }

  void applyStatus(VoiceStatus status) {
    emit(
      state.copyWith(
        sidecarLive: status.available && (status.live || status.loaded),
        sidecarLoaded: status.loaded,
        sidecarLoading: status.loading,
        sidecarModel: status.model ?? status.provider,
        keepUntil: status.keepUntil,
        clearSidecarModel: status.model == null && status.provider == null,
        clearError: true,
      ),
    );
  }

  Future<void> refreshSidecar() async {
    try {
      applyStatus(await _api.voiceStatus());
    } on Object {
      emit(
        state.copyWith(
          sidecarLive: false,
          sidecarLoaded: false,
          sidecarLoading: false,
          clearSidecarModel: true,
        ),
      );
    }
  }

  /// Start or warm PersonaPlex. One press shares one boot. Returns when
  /// the engine is loaded, or when the start fails. First load can take
  /// a couple of minutes.
  Future<bool> startSidecar() {
    final inflight = _boot;
    if (inflight != null) return inflight;
    final run = _bootSidecar();
    _boot = run;
    return run.whenComplete(() {
      if (identical(_boot, run)) _boot = null;
    });
  }

  Future<bool> _bootSidecar() async {
    emit(
      state.copyWith(
        sidecarStarting: true,
        sidecarTried: true,
        clearError: true,
      ),
    );
    try {
      final status = await _api.voiceStart();
      applyStatus(status);
      if (!status.available) {
        emit(
          state.copyWith(
            sidecarStarting: false,
            sidecarLive: false,
            sidecarLoaded: false,
            sidecarLoading: false,
            sidecarTried: true,
            error: 'PersonaVoice did not start.',
          ),
        );
        return false;
      }
      for (
        var i = 0;
        i < 90 && !state.sidecarLoaded && !state.sidecarLive;
        i++
      ) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (isClosed) return false;
        applyStatus(await _api.voiceStatus());
      }
    } on Object catch (e) {
      _note('talk', e);
      emit(
        state.copyWith(
          sidecarStarting: false,
          sidecarLive: false,
          sidecarLoaded: false,
          sidecarLoading: false,
          sidecarTried: true,
          error: shownFault(e),
        ),
      );
      return false;
    }
    final up = state.sidecarLoaded || state.sidecarLive;
    emit(
      state.copyWith(
        sidecarStarting: false,
        error: up ? null : 'PersonaVoice did not finish loading.',
        clearError: up,
      ),
    );
    return up;
  }

  static bool _benignListenError(String msg) {
    final m = msg.toLowerCase();
    return m.contains('no_match') ||
        m.contains('no match') ||
        m.contains('timeout') ||
        m.contains('cancelled') ||
        m.contains('retry') ||
        m.contains('interrupted');
  }

  Future<bool> prepareSpeak() async {
    if (state.ttsAvailable) return true;
    try {
      final tts = FlutterTts();
      await tts.setSpeechRate(0.48);
      await tts.awaitSpeakCompletion(true);
      _tts = tts;
      emit(state.copyWith(ttsAvailable: true, clearError: true));
      return true;
    } on Object catch (e) {
      _note('talk', e);
      emit(state.copyWith(ttsAvailable: false, error: shownFault(e)));
      return false;
    }
  }

  Future<bool> prepareListen() async {
    if (state.sttAvailable) return true;
    try {
      final stt = SpeechToText();
      final ok = await stt.initialize(
        onError: (e) {
          if (_holdTranscribe && _benignListenError(e.errorMsg)) {
            unawaited(_relisten());
            return;
          }
          if (_benignListenError(e.errorMsg)) {
            emit(state.copyWith(listening: false, clearError: true));
            return;
          }
          _note('transcribe', e.errorMsg);
          emit(
            state.copyWith(
              listening: false,
              error: 'Speech recognition stopped.',
            ),
          );
        },
        onStatus: (status) {
          if (status != 'done' && status != 'notListening') return;
          if (_holdTranscribe) {
            unawaited(_relisten());
            return;
          }
          emit(state.copyWith(listening: false));
        },
      );
      if (!ok) {
        emit(
          state.copyWith(
            sttAvailable: false,
            error: 'Microphone is not available on this device.',
          ),
        );
        _note('transcribe', 'microphone unavailable');
        return false;
      }
      _stt = stt;
      emit(state.copyWith(sttAvailable: true, clearError: true));
      return true;
    } on Object catch (e) {
      _note('transcribe', e);
      emit(state.copyWith(sttAvailable: false, error: shownFault(e)));
      return false;
    }
  }

  bool get _holdTranscribe =>
      _wantListen && state.capture == VoiceCapture.transcribe;

  /// Opens the microphone for [next]. The same button again stops it.
  /// Talk sends one phrase. Transcribe keeps the recognizer open and
  /// writes each word into the chat as it arrives.
  Future<void> begin(VoiceCapture next) async {
    if (state.listening || _wantListen) {
      final same = state.capture == next;
      await stopListen();
      if (same) return;
    }
    if (next == VoiceCapture.talk) await prepareSpeak();
    if (!await prepareListen()) return;
    _wantListen = true;
    _said = '';
    _lastFinal = '';
    _hypothesis = '';
    _lastWordsAt = null;
    _breakBefore = false;
    emit(
      state.copyWith(
        listening: true,
        capture: next,
        partial: '',
        liveLine: '',
        clearError: true,
      ),
    );
    try {
      await _listen(next);
    } on Object catch (e) {
      _wantListen = false;
      _note('transcribe', e);
      emit(state.copyWith(listening: false, error: shownFault(e)));
    }
  }

  Future<void> _listen(VoiceCapture next) {
    final holding = next == VoiceCapture.transcribe;
    return _stt!.listen(
      onResult: (result) {
        final words = result.recognizedWords.trim();
        if (holding) {
          _showLive(words, finalResult: result.finalResult);
          return;
        }
        if (!result.finalResult) {
          emit(state.copyWith(partial: words, liveLine: words));
          return;
        }
        _keepWords(words);
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenMode: holding ? ListenMode.dictation : ListenMode.confirmation,
        pauseFor: holding ? null : const Duration(seconds: 3),
        listenFor: holding ? null : const Duration(seconds: 20),
      ),
    );
  }

  /// A platform listen ends on its own. Open another so transcribe stays up
  /// until the button is pressed again.
  Future<void> _relisten() async {
    if (!_holdTranscribe || _relistening) return;
    _relistening = true;
    try {
      await Future<void>.delayed(Duration.zero);
      if (!_holdTranscribe) return;
      if (_stt?.isListening ?? false) return;
      await _listen(VoiceCapture.transcribe);
      emit(state.copyWith(listening: true, capture: VoiceCapture.transcribe));
    } on Object catch (e) {
      _note('transcribe', e);
    } finally {
      _relistening = false;
    }
  }

  void _showLive(String words, {required bool finalResult}) {
    _noticeThought(words);
    if (finalResult) {
      if (words.isNotEmpty && words != _lastFinal) {
        _said = joinThought(_said, words, newLine: _breakBefore);
        _lastFinal = words;
        _breakBefore = false;
      }
      emit(
        state.copyWith(
          partial: '',
          liveLine: _said,
          listening: true,
          capture: VoiceCapture.transcribe,
        ),
      );
      return;
    }
    final line = joinThought(_said, words, newLine: _breakBefore);
    emit(
      state.copyWith(
        partial: words,
        liveLine: line,
        listening: true,
        capture: VoiceCapture.transcribe,
      ),
    );
  }

  /// A pause before words that do not continue the last phrase is a new line.
  /// Words that keep extending the same phrase stay on that line.
  void _noticeThought(String words) {
    final now = DateTime.now();
    final gap = _lastWordsAt == null
        ? Duration.zero
        : now.difference(_lastWordsAt!);
    if (newThought(previous: _hypothesis, next: words, gap: gap)) {
      _breakBefore = true;
    }
    if (words.isNotEmpty) {
      _hypothesis = words;
      _lastWordsAt = now;
    }
  }

  void _keepWords(String text) {
    if (text.isEmpty) {
      emit(state.copyWith(listening: false, partial: '', clearCapture: true));
      return;
    }
    if (state.capture == VoiceCapture.transcribe) {
      emit(
        state.copyWith(
          listening: false,
          transcript: text,
          transcriptSeq: state.transcriptSeq + 1,
          partial: '',
          clearCapture: true,
        ),
      );
      return;
    }
    emit(
      state.copyWith(
        listening: false,
        lastHeard: text,
        heardSeq: state.heardSeq + 1,
        partial: '',
        liveLine: '',
        clearCapture: true,
      ),
    );
  }

  Future<void> stopListen() async {
    final transcribing = state.capture == VoiceCapture.transcribe;
    final line = state.liveLine.trim().isNotEmpty
        ? state.liveLine.trim()
        : state.partial.trim();
    _wantListen = false;
    try {
      await _stt?.stop();
    } on Object {
      // Plugin already idle.
    }
    if (transcribing) {
      _said = '';
      _lastFinal = '';
      _hypothesis = '';
      _lastWordsAt = null;
      _breakBefore = false;
      emit(
        state.copyWith(
          listening: false,
          partial: '',
          liveLine: '',
          transcript: line.isEmpty ? state.transcript : line,
          transcriptSeq: line.isEmpty
              ? state.transcriptSeq
              : state.transcriptSeq + 1,
          clearCapture: true,
        ),
      );
      return;
    }
    if (line.isEmpty) {
      emit(
        state.copyWith(
          listening: false,
          partial: '',
          liveLine: '',
          clearCapture: true,
        ),
      );
      return;
    }
    _keepWords(line);
  }

  Future<void> speak(String text) async {
    if (!state.enabled) return;
    final line = text.trim();
    if (line.isEmpty) return;
    if (!await prepareSpeak()) return;
    emit(state.copyWith(speaking: true, clearError: true));
    try {
      await _tts?.stop();
      await _tts?.speak(line);
    } on Object catch (e) {
      _note('talk', e);
      emit(state.copyWith(speaking: false, error: shownFault(e)));
      return;
    }
    emit(state.copyWith(speaking: false));
  }

  /// Speak sentences that have already closed in the streaming draft.
  /// The open tail waits for the next delta or [speakReply].
  void followDraft(String draft) {
    if (!state.enabled || draft.isEmpty) return;
    final ready = finishedSpeech(draft);
    if (ready.isEmpty) return;
    if (_queuedSpeech.isNotEmpty && !ready.startsWith(_queuedSpeech)) {
      _queuedSpeech = '';
    }
    if (ready.length <= _queuedSpeech.length) return;
    final next = ready.substring(_queuedSpeech.length).trim();
    _queuedSpeech = ready;
    if (next.isEmpty) return;
    _enqueueSpeech(next);
  }

  /// Drop anything still waiting to be spoken. A new question barges in.
  void interruptSpeech() {
    _speechGen++;
    _pendingSpeech = 0;
    _queuedSpeech = '';
    unawaited(_tts?.stop());
    if (!isClosed && state.speaking) {
      emit(state.copyWith(speaking: false));
    }
  }

  /// Speak a finished assistant message. Sentences already read from the
  /// draft are not repeated. PersonaPlex gets the same line when it is up.
  Future<void> speakReply(String messageId, String content) async {
    if (!state.enabled) return;
    if (state.spokenMessageId == messageId) return;
    emit(state.copyWith(spokenMessageId: messageId));
    final full = spokenLinesOf(content).join(' ').trim();
    final already = _queuedSpeech.trim();
    _queuedSpeech = '';
    final rest = _unspoken(full, already);
    if (rest.isEmpty) return;
    _enqueueSpeech(rest);
  }

  void _enqueueSpeech(String text) {
    final gen = _speechGen;
    _pendingSpeech++;
    _speech = _speech
        .then((_) async {
          if (gen != _speechGen || isClosed) return;
          await _speakChunk(text);
        })
        .whenComplete(() {
          if (gen != _speechGen || isClosed) return;
          if (_pendingSpeech > 0) _pendingSpeech--;
          if (_pendingSpeech == 0 && state.speaking) {
            emit(state.copyWith(speaking: false));
          }
        });
  }

  Future<void> _speakChunk(String text) async {
    final line = text.trim();
    if (line.isEmpty) return;
    if (state.sidecarLive) {
      unawaited(_sayRemote(line));
    }
    if (!await prepareSpeak()) return;
    emit(state.copyWith(speaking: true, clearError: true));
    try {
      await _tts?.speak(line);
    } on Object catch (e) {
      _note('talk', e);
      if (!isClosed) {
        emit(state.copyWith(speaking: false, error: shownFault(e)));
      }
    }
  }

  Future<void> _sayRemote(String line) async {
    try {
      await _api.voiceSay(line);
    } on Object {
      // The phone is already speaking this sentence.
    }
  }

  static String _unspoken(String full, String already) {
    if (full.isEmpty) return '';
    if (already.isEmpty) return full;
    if (full.startsWith(already)) {
      return full.substring(already.length).trim();
    }
    if (full == already || already.contains(full)) return '';
    return full;
  }
}
