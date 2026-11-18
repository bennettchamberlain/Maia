import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maia_api_client/maia_api_client.dart';
import 'package:maia_models/maia_models.dart';
import 'package:maia_app/chat/parts/chat_part.dart';
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
  SpeechToText? _stt;
  FlutterTts? _tts;

  Future<void> setEnabled({required bool on}) async {
    emit(state.copyWith(enabled: on, clearError: true));
    await _prefs?.setBool(_enabledKey, on);
    if (on) {
      await prepareSpeak();
      unawaited(startSidecar());
    } else {
      await stopListen();
      await _tts?.stop();
      emit(state.copyWith(speaking: false));
    }
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

  /// Start or warm the GPU sidecar. Returns when it is loaded or the
  /// poll budget runs out. First start can take a couple of minutes.
  Future<void> startSidecar() async {
    if (state.sidecarStarting) return;
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
            clearError: true,
          ),
        );
        return;
      }
      for (var i = 0; i < 90 && !state.sidecarLoaded; i++) {
        if (!state.sidecarLoading && i > 2) break;
        await Future<void>.delayed(const Duration(seconds: 2));
        applyStatus(await _api.voiceStatus());
      }
    } on Object {
      emit(
        state.copyWith(
          sidecarStarting: false,
          sidecarLive: false,
          sidecarLoaded: false,
          sidecarLoading: false,
          sidecarTried: true,
          clearError: true,
        ),
      );
      return;
    }
    emit(state.copyWith(sidecarStarting: false, clearError: true));
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
      emit(state.copyWith(ttsAvailable: false, error: '$e'));
      return false;
    }
  }

  Future<bool> prepareListen() async {
    if (state.sttAvailable) return true;
    try {
      final stt = SpeechToText();
      final ok = await stt.initialize(
        onError: (e) {
          if (_benignListenError(e.errorMsg)) {
            emit(state.copyWith(listening: false, clearError: true));
            return;
          }
          emit(state.copyWith(listening: false, error: e.errorMsg));
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            emit(state.copyWith(listening: false));
          }
        },
      );
      if (!ok) {
        emit(
          state.copyWith(
            sttAvailable: false,
            error: 'Microphone is not available on this device.',
          ),
        );
        return false;
      }
      _stt = stt;
      emit(state.copyWith(sttAvailable: true, clearError: true));
      return true;
    } on Object catch (e) {
      emit(state.copyWith(sttAvailable: false, error: '$e'));
      return false;
    }
  }

  /// Opens the microphone for [next]. The same button again stops it.
  /// Talk turns spoken replies on. Transcribe only fills the composer.
  Future<void> begin(VoiceCapture next) async {
    if (state.listening) {
      final same = state.capture == next;
      await stopListen();
      if (same) return;
    }
    if (next == VoiceCapture.talk && !state.enabled) {
      await setEnabled(on: true);
    }
    if (!await prepareListen()) return;
    emit(
      state.copyWith(
        listening: true,
        capture: next,
        partial: '',
        clearError: true,
      ),
    );
    try {
      await _stt!.listen(
        onResult: (result) {
          final words = result.recognizedWords;
          if (!result.finalResult) {
            emit(state.copyWith(partial: words));
            return;
          }
          _keepWords(words.trim());
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 3),
          cancelOnError: false,
          partialResults: true,
        ),
      );
    } on Object catch (e) {
      emit(state.copyWith(listening: false, error: '$e'));
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
        clearCapture: true,
      ),
    );
  }

  Future<void> stopListen() async {
    try {
      await _stt?.stop();
    } on Object {
      // Plugin already idle.
    }
    final leftover = state.partial.trim();
    if (leftover.isEmpty) {
      emit(state.copyWith(listening: false, partial: '', clearCapture: true));
      return;
    }
    _keepWords(leftover);
  }

  Future<void> speak(String text) async {
    final line = text.trim();
    if (line.isEmpty) return;
    if (!await prepareSpeak()) return;
    emit(state.copyWith(speaking: true, clearError: true));
    try {
      await _tts?.stop();
      await _tts?.speak(line);
    } on Object catch (e) {
      emit(state.copyWith(speaking: false, error: '$e'));
      return;
    }
    emit(state.copyWith(speaking: false));
  }

  /// Speak a finished assistant message on this device. If PersonaPlex is
  /// live on the voice box, also force those words there — thinking already
  /// happened on Parasail in the chat turn.
  Future<void> speakReply(String messageId, String content) async {
    if (!state.enabled) return;
    if (state.spokenMessageId == messageId) return;
    emit(state.copyWith(spokenMessageId: messageId));
    final lines = spokenLinesOf(content);
    if (lines.isEmpty) return;
    final spoken = lines.join(' ');
    await speak(spoken);
    if (!state.sidecarLive) return;
    try {
      await _api.voiceSay(spoken);
    } on Object {
      // Chat already spoke locally.
    }
  }
}
