package io.github.yiannis128.agent_chat

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

// The Android-system voice engines: `TextToSpeech` for the speaking half and
// `SpeechRecognizer` for the listening half, behind the `agent_chat/voice`
// method channel. One channel for both, the way `ForegroundWork` is one channel
// for three services, and registered on the cached engine against the
// application context for the same reason the others are — the engine outlives
// the activity.
//
// Dart builds a `Listener`/`Speaker` pair per session and routes the
// `android-recognition`/`android-speech` sentinels here; see
// `android_voice.dart` for the Dart side and "What listens and what speaks" in
// CLAUDE.md for the design. No new permissions: `RECORD_AUDIO` is already
// declared and Dart asks for the grant before starting a session, the way the
// sherpa path does.
object VoiceChannel {
    private var channel: MethodChannel? = null
    private var tts: TextToSpeech? = null
    private var recognizer: SpeechRecognizer? = null

    // What the session has asked for, which is not what the recognizer is
    // doing. `SpeechRecognizer` hears one utterance and stops, so continuous
    // listening is this flag plus a restart from `onResults`/`onError` — see
    // [restart].
    private var wantListening = false

    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        channel = MethodChannel(messenger, "agent_chat/voice").apply {
            setMethodCallHandler { call, result -> handle(appContext, call, result) }
        }
    }

    // `TextToSpeech`'s progress callbacks arrive on a binder thread and a
    // `MethodChannel` may only be used from the main one, so everything Dart
    // hears goes through here rather than being invoked where it happens.
    //
    // `RecognitionListener`'s callbacks are already on the main thread, and
    // `onRmsChanged` is on it many times a second for as long as voice mode
    // listens — posting those would be a Handler round trip per audio frame to
    // arrive where they already are.
    private fun send(method: String, argument: Any?) {
        if (Looper.myLooper() == main.looper) channel?.invokeMethod(method, argument)
        else main.post { channel?.invokeMethod(method, argument) }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engines" -> result.success(engines(context))
            "initSpeech" -> { ensureTts(context); result.success(null) }
            "speak" -> {
                val text = call.argument<String>("text") ?: ""
                val generation = call.argument<Int>("generation") ?: 0
                speak(text, generation)
                result.success(null)
            }
            "stopSpeech" -> { tts?.stop(); result.success(null) }
            "disposeSpeech" -> { disposeTts(); result.success(null) }
            "startRecognition" -> { startRecognition(context); result.success(null) }
            "setRecognitionListening" -> {
                setRecognitionListening(context, call.arguments as? Boolean ?: true)
                result.success(null)
            }
            "stopRecognition" -> { stopRecognition(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    // Whether this device has either engine at all. A phone with no Google
    // apps on it may have neither, and the sentinels are only worth offering —
    // or defaulting to — where the thing behind them exists.
    //
    // Both answers need the `<queries>` block in the manifest: from Android 11
    // an app sees only the packages it declares an interest in, and without it
    // both of these report nothing on every modern phone rather than only on
    // the ones that genuinely have nothing.
    private fun engines(context: Context): Map<String, Boolean> {
        val speech = context.packageManager
            .queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
            .isNotEmpty()
        return mapOf(
            "recognition" to SpeechRecognizer.isRecognitionAvailable(context),
            "speech" to speech,
        )
    }

    // --- Speech synthesis ---

    private fun ensureTts(context: Context) {
        if (tts != null) return
        tts = TextToSpeech(context) { status ->
            if (status != TextToSpeech.SUCCESS) {
                send("speechError", "Text-to-speech is not available.")
                return@TextToSpeech
            }
            tts?.language = Locale.getDefault()
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}

                override fun onDone(utteranceId: String?) {
                    send("speechDone", utteranceId?.toIntOrNull() ?: 0)
                }

                @Deprecated("Kept for the platforms that still call it.")
                override fun onError(utteranceId: String?) {
                    send("speechError", "Speech playback failed.")
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    send("speechError", "Speech playback failed.")
                }
            })
        }
    }

    private fun speak(text: String, generation: Int) {
        val engine = tts ?: run {
            send("speechError", "Text-to-speech is not ready.")
            return
        }
        // The generation rides as the utterance id, so `onDone` names the batch
        // it belongs to and one arriving after a barge-in is ignored rather
        // than counted against the batch that replaced it.
        engine.speak(text, TextToSpeech.QUEUE_ADD, null, generation.toString())
    }

    private fun disposeTts() {
        tts?.stop()
        tts?.shutdown()
        tts = null
    }

    // --- Speech recognition ---

    private fun startRecognition(context: Context) {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            send("recognitionError", "Speech recognition is not available on this device.")
            return
        }
        if (recognizer == null) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(context)
            recognizer?.setRecognitionListener(recognitionListener)
        }
        wantListening = true
        listen()
    }

    private fun listen() {
        if (!wantListening) return
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            // Prefer the on-device recognizer where the platform offers one
            // (Android 13+), matching the "on the device" framing of voice
            // mode. Falls back to the network recognizer where it does not.
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        try {
            recognizer?.startListening(intent)
        } catch (e: Exception) {
            send("recognitionError", e.message ?: "Recognition could not start.")
        }
    }

    // A recognizer that has just finished an utterance is asked for the next
    // one. Posted rather than called straight from the callback: it is still
    // inside the old recognition when `onResults` runs, and starting a new one
    // there is what `ERROR_RECOGNIZER_BUSY` is.
    private fun restart() {
        if (!wantListening) return
        main.post { listen() }
    }

    private fun setRecognitionListening(context: Context, on: Boolean) {
        if (on) {
            startRecognition(context)
        } else {
            wantListening = false
            recognizer?.cancel()
        }
    }

    private fun stopRecognition() {
        wantListening = false
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}

        override fun onBeginningOfSpeech() {
            send("interrupted", null)
        }

        override fun onRmsChanged(rmsdB: Float) {
            send("rms", rmsdB.toDouble())
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {}

        override fun onError(error: Int) {
            // Silence is not a fault while listening continuously: a room with
            // nobody talking in it produces one of these every few seconds, and
            // reporting them would put voice mode in the failed state for the
            // ordinary case of waiting to be spoken to.
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> restart()

                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    wantListening = false
                    send("recognitionError", "Entoli was not allowed to use the microphone.")
                }

                else -> {
                    send("recognitionError", "Recognition failed (error $error).")
                    restart()
                }
            }
        }

        override fun onResults(results: Bundle?) {
            val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val text = matches?.firstOrNull()?.trim()
            if (!text.isNullOrEmpty()) send("heard", text)
            restart()
        }

        override fun onPartialResults(partialResults: Bundle?) {}

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}
