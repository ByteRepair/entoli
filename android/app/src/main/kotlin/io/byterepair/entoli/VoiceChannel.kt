package io.byterepair.entoli

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.annotation.RequiresApi
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
// AGENTS.md for the design. No new permissions: `RECORD_AUDIO` is already
// declared and Dart asks for the grant before starting a session, the way the
// sherpa path does.
object VoiceChannel {
    // Failures and the arms nothing draws: a service walked past, an utterance
    // the recogniser would not end, a rung of the request ladder refused. Every
    // one of them is a turn that silently does not happen and none of them
    // reaches the screen, so all of them are worth a line in a release build.
    // No per-transition chatter, and never what was heard — the Dart side draws
    // the same line, as `voiceFailed` against `voiceLog`.
    private const val TAG = "VoiceChannel"

    private var channel: MethodChannel? = null
    private var tts: TextToSpeech? = null

    // Whether [tts] has said it is ready. The object outlives the isolate that
    // asked, so a second `initSpeech` must be answered from this.
    private var ttsReady = false
    private var recognizer: SpeechRecognizer? = null

    // What Settings picked, or null for whatever the device is set to. One
    // field for both engines: the two halves are built separately in Dart but
    // land in this one object, and a language each would be two answers to a
    // question the user was asked once. Set by whichever half starts first —
    // see "Which language it is asked in".
    private var language: String? = null

    // The locale the engines are asked for. Null being the device's is settled
    // here rather than at each call site.
    private fun asked(): Locale =
        language?.let { Locale.forLanguageTag(it) } ?: Locale.getDefault()

    // Held rather than captured in the handler's closure the way the other
    // channels do it: the recognition listener binds a service from inside a
    // callback nothing hands a context to.
    private lateinit var appContext: Context

    // What the session has asked for, which is not what the recognizer is
    // doing. `SpeechRecognizer` hears one utterance and stops, so continuous
    // listening is this flag plus a restart from `onResults`/`onError` — see
    // [restart].
    private var wantListening = false

    // Whether a session has opened since the recognizer was started. What
    // tells the two meanings of ERROR_CLIENT apart — see [onError].
    private var sessionOpened = false

    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        channel = MethodChannel(messenger, "agent_chat/voice").apply {
            setMethodCallHandler { call, result -> handle(call, result) }
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

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engines" -> result.success(engines(appContext))
            "languages" -> languages(appContext, result)
            "initSpeech" -> {
                language = call.argument<String>("language")
                ensureTts(appContext)
                result.success(null)
            }
            "speak" -> {
                val text = call.argument<String>("text") ?: ""
                val generation = call.argument<Int>("generation") ?: 0
                speak(text, generation)
                result.success(null)
            }
            "stopSpeech" -> { tts?.stop(); result.success(null) }
            "disposeSpeech" -> { disposeTts(); result.success(null) }
            "setRecognitionListening" -> {
                setRecognitionListening(
                    call.argument<Boolean>("on") ?: true,
                    call.argument<Boolean>("finish") ?: false,
                    call.argument<String>("language"),
                )
                result.success(null)
            }
            "stopRecognition" -> { stopRecognition(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    // Whether this device has either engine at all. A phone with no Google
    // apps on it may have neither, and the sentinels are only worth offering —
    // or defaulting to — where the thing behind them exists. Recognition
    // follows the system's pick rather than mere installation — see
    // "The probe's answer" in AGENTS.md.
    //
    // Both answers need the `<queries>` block in the manifest: from Android 11
    // an app sees only the packages it declares an interest in, and without it
    // both of these report nothing on every modern phone rather than only on
    // the ones that genuinely have nothing.
    private fun engines(context: Context): Map<String, Boolean> {
        val speech = context.packageManager
            .queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
            .isNotEmpty()
        // Set, and to something installed — a stale pick is no pick, the same
        // rule [recognitionServices] applies to its own list.
        val chosen = chosenRecognizer(context)
        val recognition =
            chosen != null && installedRecognitionServices(context).any { it == chosen }
        return mapOf(
            "recognition" to recognition,
            "speech" to speech,
        )
    }

    // What the settings page offers as a language, and the device's own where
    // it offers nothing. The synthesiser is the one engine that will simply
    // list them — see `systemLanguages` in `android_voice.dart` for why the
    // recogniser is not the one asked.
    //
    // The answer is deferred rather than returned: `getAvailableLanguages` is
    // nothing until the engine says it is ready. A throwaway is shut down
    // again — a settings page that leaves a synthesiser bound is one the
    // notification shade shows as speaking.
    private fun languages(context: Context, result: MethodChannel.Result) {
        tts?.let { return result.success(languagesOf(it)) }
        var engine: TextToSpeech? = null
        engine = TextToSpeech(context) { status ->
            if (status != TextToSpeech.SUCCESS) {
                Log.w(TAG, "no synthesiser to ask what this device can speak")
            }
            val answer = engine?.takeIf { status == TextToSpeech.SUCCESS }
                ?.let { languagesOf(it) } ?: emptyList()
            main.post {
                result.success(answer)
                engine?.shutdown()
            }
        }
    }

    // Tag and display name, the name being what this device calls the language
    // in its own — `getDisplayName` with no argument, so a phone set to Greek
    // reads a list in Greek. Sorted by it, since that is what is read.
    private fun languagesOf(engine: TextToSpeech): List<Map<String, String>> =
        runCatching { engine.availableLanguages ?: emptySet<Locale>() }
            .getOrDefault(emptySet())
            .sortedBy { it.displayName }
            .map { mapOf("tag" to it.toLanguageTag(), "name" to it.displayName) }

    // The recognition services a session may connect to, best first, and empty
    // where there are none. Named rather than left to the one-argument
    // `createSpeechRecognizer`, which resolves
    // `Settings.Secure.VOICE_RECOGNITION_SERVICE` and answers an unset one
    // with ERROR_CLIENT as the session opens. See "The Android system engines"
    // in AGENTS.md.
    private fun recognitionServices(context: Context): List<ComponentName> {
        val installed = installedRecognitionServices(context)
        // Their pick and nothing else where they made one — walking past it
        // would hand the microphone to another vendor without saying so. Where
        // they made none, every installed service is a candidate, since the
        // platform has not been told which either. One that is not installed
        // is stale.
        val chosen = chosenRecognizer(context)
        return installed.firstOrNull { it == chosen }?.let { listOf(it) } ?: installed
    }

    // The services answering the recognition intent, as components. One query,
    // two readers: [recognitionServices] binds from the list and [engines]
    // checks the system's pick against it.
    private fun installedRecognitionServices(context: Context): List<ComponentName> =
        context.packageManager
            .queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
            .map { ComponentName(it.serviceInfo.packageName, it.serviceInfo.name) }

    // The system's pick of recognizer, as a component, and null where none is
    // set — stale or not: what is set and what is installed are checked by the
    // readers, against the list [installedRecognitionServices] answers. No
    // public API for the constant — the key is read as a string.
    private fun chosenRecognizer(context: Context): ComponentName? =
        Settings.Secure
            .getString(context.contentResolver, "voice_recognition_service")
            ?.let { ComponentName.unflattenFromString(it) }

    // --- Speech synthesis ---

    // `TextToSpeech` may be constructed long before it can speak: a `speak` in
    // that window returns an error code and nothing else — no callback, so
    // nothing above would ever learn the utterance never happened. Dart holds
    // its queue until `speechReady` says otherwise.
    private fun ensureTts(context: Context) {
        tts?.let {
            if (ttsReady) {
                speakIn(it)
                send("speechReady", null)
            }
            return
        }
        tts = TextToSpeech(context) { status ->
            if (status != TextToSpeech.SUCCESS) {
                send("speechError", "Text-to-speech is not available.")
                return@TextToSpeech
            }
            ttsReady = true
            send("speechReady", null)
            tts?.let { speakIn(it) }
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}

                override fun onDone(utteranceId: String?) {
                    send("speechDone", utteranceId?.toIntOrNull() ?: 0)
                }

                // One utterance failing is not the engine failing: named by its
                // batch, dropped by Dart, and only repeated failure is reported
                // up. Init failure alone comes through as `speechError`.
                @Deprecated("Kept for the platforms that still call it.")
                override fun onError(utteranceId: String?) {
                    onError(utteranceId, -1)
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    send("speechUtteranceError", utteranceId?.toIntOrNull() ?: -1)
                }
            })
        }
    }

    // `setLanguage` refuses by return code rather than by throwing, and an
    // ignored one leaves the engine speaking whatever it spoke last — a reply
    // read out in the wrong language with nothing anywhere saying why.
    private fun speakIn(engine: TextToSpeech) {
        val locale = asked()
        val set = runCatching { engine.setLanguage(locale) }
            .getOrDefault(TextToSpeech.LANG_NOT_SUPPORTED)
        if (set >= TextToSpeech.LANG_AVAILABLE) return
        Log.w(TAG, "the synthesiser cannot speak ${locale.toLanguageTag()}")
        engine.language = Locale.getDefault()
    }

    private fun speak(text: String, generation: Int) {
        val engine = tts ?: run {
            send("speechError", "Text-to-speech is not ready.")
            return
        }
        // The generation rides as the utterance id, so `onDone` names the batch
        // it belongs to and one arriving after a `stop` is ignored rather than
        // counted against the batch that replaced it.
        engine.speak(text, TextToSpeech.QUEUE_ADD, null, generation.toString())
    }

    private fun disposeTts() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
    }

    // --- Speech recognition ---

    // The shapes the request is tried in, declared in the order they are tried.
    // See "What is asked, and what to do when it is refused" in AGENTS.md.
    private enum class Ask { OnDevice, Network, NetworkAnyLanguage }

    private var ask = Ask.OnDevice
    private var services: List<ComponentName> = emptyList()
    private var service = 0

    // Transient faults since anything was last heard — see [retry].
    private var faults = 0

    // When the current request went out, and how many silences have come back
    // almost instantly. A room with nobody in it answers after the service's
    // own timeout; a rung that cannot work at all refuses within a fraction of
    // a second. Two fast ones in a row is a refusal dressed as silence, and is
    // asked again — see [onError]. Speech resets it: a working rung never
    // descends.
    private var listenedAt = 0L
    private var fastRefusals = 0

    // The services already asked for a model. A fetch rather than a retry, so
    // once each, and it outlives the session that discovered the gap.
    private val downloadAsked = mutableSetOf<ComponentName>()

    private fun startRecognition() {
        sessionOpened = false
        wantListening = true
        listen()
    }

    // How quickly a silence has to come back to count as a refusal rather
    // than as a room with nobody in it — see [onError].
    private const val FAST_REFUSAL_MS = 1500L

    // How long a refused session's tear-down is waited out before the next
    // `startListening`: one inside that window is answered with a session
    // that opens and then reports nothing at all — see [askDifferently].
    private const val TEARDOWN_MS = 200L

    // --- Ending the utterance ---
    //
    // **A session that never ends is a turn that is never sent**, and it is the
    // ordinary way for this to fail in a room with anything happening in it.
    // `SpeechRecognizer` decides for itself when someone has stopped talking,
    // and its own detector is generous: a fan, a television, a conversation
    // elsewhere all read as speech continuing, so `onResults` never arrives,
    // the turn is never handed over, and voice mode sits there listening and
    // apparently deaf. Nothing above can see this — from Dart it looks exactly
    // like a microphone that is not working.
    //
    // So the utterance is ended here when the service will not end it. What
    // says the person has stopped is the *transcription* rather than the sound:
    // partial results stop changing while the room goes on making noise. After
    // [QUIET_MS] of a partial that has not moved, `stopListening` asks the
    // service for what it has, which is the same call the Talk button's release
    // makes.
    private const val QUIET_MS = 1500L

    // The partial transcription as it was last seen to move.
    private var lastPartial = ""

    // One timer and one call, and it stays that way — see "Ending the
    // utterance" for what a second and a third cost. A service that ignores
    // `stopListening` is left where it was before any of this.
    private val endpoint: Runnable = Runnable {
        if (!wantListening) return@Runnable
        Log.i(TAG, "ending the utterance: the service did not")
        runCatching { recognizer?.stopListening() }
    }

    // Re-armed every time the transcription moves, and never before there is a
    // session to end.
    private fun armEndpoint() {
        if (!sessionOpened) return
        main.removeCallbacks(endpoint)
        main.postDelayed(endpoint, QUIET_MS)
    }

    private fun disarmEndpoint() {
        main.removeCallbacks(endpoint)
        lastPartial = ""
    }

    // An error voice mode will show. The recognizer goes with it: the Dart side
    // is in its failed state from here, and one left bound is one the next
    // unpause drives on rather than resolving a service again.
    private fun fail(message: String) {
        Log.w(TAG, "recognition failed: $message")
        stopRecognition()
        send("recognitionError", message)
    }

    private fun listen() {
        if (!wantListening) return
        main.removeCallbacks(relisten)
        disarmEndpoint()
        val recognizer = ensureRecognizer() ?: return
        try {
            recognizer.startListening(recognizerIntent(ask))
            listenedAt = SystemClock.elapsedRealtime()
        } catch (e: Exception) {
            fail(e.message ?: "Recognition could not start.")
        }
    }

    // Null where there is no service left to bind, which [fail] has reported by
    // the time this returns.
    private fun ensureRecognizer(): SpeechRecognizer? {
        recognizer?.let { return it }
        if (services.isEmpty()) services = recognitionServices(appContext)
        val component = services.getOrNull(service) ?: run {
            fail("Speech recognition is not available on this device.")
            return null
        }
        val fresh = SpeechRecognizer.createSpeechRecognizer(appContext, component)
        fresh.setRecognitionListener(recognitionListener)
        recognizer = fresh
        return fresh
    }

    private fun recognizerIntent(ask: Ask): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            // Nothing fills this in for a `SpeechRecognizer` session, and a
            // service that wants to know who is asking answers a request
            // without it as ERROR_CLIENT.
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, appContext.packageName)
            // Asked for so there is something to tell a person who has stopped
            // talking from a room that has not — see [armEndpoint]. A service
            // that ignores this leaves the fallback below doing the work.
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // How long a silence ends the utterance. Every one of these is
            // documented as a hint the service may ignore, which is why none of
            // them is the answer on its own.
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                QUIET_MS,
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                QUIET_MS,
            )
            if (ask == Ask.OnDevice) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            if (ask != Ask.NetworkAnyLanguage) {
                languageTag()?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
            }
        }

    // Stripped of the `u-` extension the locale may have been set with, which
    // is a calendar or a numbering system rather than a language — and a tag a
    // service cannot parse is a language it does not support. The script is
    // left on, since for `sr-Latn` and `zh-Hant` it is the language.
    private fun languageTag(): String? =
        asked().stripExtensions().takeIf { it.language.isNotEmpty() }?.toLanguageTag()

    // A recognizer that has just finished an utterance is asked for the next
    // one. Posted rather than called straight from the callback: it is still
    // inside the old recognition when `onResults` runs, and starting a new one
    // there is what `ERROR_RECOGNIZER_BUSY` is. [after] is for the cases where
    // a turn of the looper is not enough — see [onError].
    private val relisten: Runnable = Runnable { listen() }

    private fun restart(after: Long = 0) {
        if (!wantListening) return
        main.removeCallbacks(relisten)
        main.postDelayed(relisten, after)
    }

    // The service cannot hear in the language it was asked for, or has no model
    // downloaded for it.
    private fun askDifferently() {
        if (ask == Ask.OnDevice) offerDownload()
        val next = Ask.entries.getOrNull(ask.ordinal + 1)
        if (next != null) {
            Log.i(TAG, "asking again as $next")
            ask = next
            rebind()
            restart(after = TEARDOWN_MS)
        } else {
            nextService(
                "This device has no speech recognition for ${asked().displayLanguage}.")
        }
    }

    // [message] is what to say when this was the last service.
    private fun nextService(message: String) {
        if (service + 1 >= services.size) return fail(message)
        Log.i(TAG, "walking past a recognition service that would not answer")
        service++
        ask = Ask.OnDevice
        rebind()
        restart()
    }

    private fun rebind() {
        recognizer?.destroy()
        recognizer = null
        sessionOpened = false
    }

    // A fault worth one more try: the service dropped, the network blinked, one
    // request too many. Three in a row with nothing heard in between is not a
    // blink. Backed off rather than retried straight away, since every one of
    // these is something happening elsewhere.
    private fun retry(message: String) {
        faults++
        Log.i(TAG, "retrying after a transient fault ($faults)")
        if (faults > 3) return fail(message)
        restart(after = 500L * faults)
    }

    // Ask for the on-device model when the device language turns out to be one
    // the service could hold and does not, so a session that fell back to the
    // network is heard on the device next time. The platform decides whether to
    // prompt and whether to wait for wifi; nothing here waits or hears how it
    // went.
    private fun offerDownload() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val recognizer = this.recognizer ?: return
        val component = services.getOrNull(service) ?: return
        val tag = languageTag() ?: return
        if (downloadAsked.add(component)) requestModel(recognizer, tag)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun requestModel(recognizer: SpeechRecognizer, tag: String) {
        val intent = recognizerIntent(Ask.OnDevice)
        val callback = object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
                // A destroyed recognizer throws.
                if (this@VoiceChannel.recognizer !== recognizer) return
                val has = { l: List<String> -> l.any { it.equals(tag, ignoreCase = true) } }
                if (!has(support.supportedOnDeviceLanguages)) return
                if (has(support.pendingOnDeviceLanguages)) return
                runCatching { recognizer.triggerModelDownload(intent) }
            }

            override fun onError(error: Int) {}
        }
        runCatching {
            recognizer.checkRecognitionSupport(intent, appContext.mainExecutor, callback)
        }
    }

    // [finish] ends the utterance in progress rather than dropping it, which is
    // what releasing a touch-to-speak button means: `stopListening` is the one
    // way to shut the microphone and still be told what went into it. Whether
    // the result that comes back is wanted is not decided here — a closed
    // session flushes results nobody asked for too, and `ComposedVoiceSession`
    // is where the one rule about those lives.
    private fun setRecognitionListening(on: Boolean, finish: Boolean, language: String?) {
        if (on) {
            this.language = language
            startRecognition()
        } else {
            wantListening = false
            disarmEndpoint()
            if (finish) recognizer?.stopListening() else recognizer?.cancel()
        }
    }

    // The walk is reset here rather than in [startRecognition], so pausing for
    // a reply and unpausing keeps what it learned and a new session does not.
    private fun stopRecognition() {
        wantListening = false
        disarmEndpoint()
        recognizer?.cancel()
        rebind()
        services = emptyList()
        service = 0
        ask = Ask.OnDevice
        faults = 0
        fastRefusals = 0
    }

    private val recognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            sessionOpened = true
            faults = 0
        }

        // Both of these are guarded to save the traffic rather than to decide
        // anything: `onRmsChanged` is a codec encode and a main-thread hop many
        // times a second, and in touch-to-speak mode the microphone is shut
        // almost all of the time. What a shut microphone is allowed to say is
        // `ComposedVoiceSession`'s, in one place for both engines.
        override fun onBeginningOfSpeech() {
            // The service is hearing something. Whatever comes back now is a
            // real cycle, not a rung refusing to listen — see [onError].
            fastRefusals = 0
            lastPartial = ""
            // Not armed here: a service that streams no partials — Google's on
            // the network rung streams none — gives the transcription nothing
            // to judge, and an endpoint armed at the start of speech fires
            // QUIET_MS in, mid-sentence. The only clock such a service has is
            // its own detector, so it ends the utterance itself.
        }

        override fun onRmsChanged(rmsdB: Float) {
            if (wantListening) send("rms", rmsdB.toDouble())
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        // The service thinks the utterance is over, which is not the same as
        // having said what was in it. Results normally follow; where they do
        // not, the endpoint armed here is what asks.
        override fun onEndOfSpeech() {
            armEndpoint()
        }

        override fun onError(error: Int) {
            disarmEndpoint()
            // Silence is not a fault while listening continuously: a room with
            // nobody talking in it produces one of these every few seconds, and
            // reporting them would put voice mode in the failed state for the
            // ordinary case of waiting to be spoken to. But a rung that cannot
            // hear at all — offline preferred where no model is downloaded,
            // say — refuses within a fraction of a second rather than after
            // the timeout window, and some services answer that way instead of
            // with a language error. Two near-instant silences in a row is a
            // refusal dressed as silence, and is asked again like one.
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                    val elapsed = SystemClock.elapsedRealtime() - listenedAt
                    fastRefusals = if (elapsed < FAST_REFUSAL_MS) fastRefusals + 1 else 0
                    if (fastRefusals >= 2) {
                        fastRefusals = 0
                        askDifferently()
                    } else restart()
                }

                // What the service answers while it still has the previous
                // session open. Cancelled and retried on the fault budget:
                // retrying into a busy recognizer immediately, forever, was a
                // silent spin.
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> {
                    recognizer?.cancel()
                    retry("Speech recognition did not answer.")
                }

                // What the service answers a restart that landed while it still
                // had the last session open, and also a session that never
                // connected. Retried once, far enough out for a tear-down to
                // finish; a second with nothing opened in between is the other
                // kind, and is not going to clear.
                SpeechRecognizer.ERROR_CLIENT -> if (sessionOpened) {
                    sessionOpened = false
                    restart(after = TEARDOWN_MS)
                } else {
                    nextService("Speech recognition could not start.")
                }

                // The request named a language this service cannot hear in, or
                // one it could hear in and has not downloaded. Both are asked
                // again rather than reported: this is what "Recognition failed
                // (error 12)" was, on a phone that hears perfectly well over
                // the network.
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> askDifferently()

                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                    fail("Entoli was not allowed to use the microphone.")

                SpeechRecognizer.ERROR_AUDIO ->
                    fail("The microphone could not be read.")

                SpeechRecognizer.ERROR_NETWORK,
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                    retry("Speech recognition could not reach the network.")

                SpeechRecognizer.ERROR_SERVER,
                SpeechRecognizer.ERROR_TOO_MANY_REQUESTS ->
                    retry("The speech recognition service is not answering.")

                // The binding is gone with it, so the retry needs a new one.
                SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> {
                    rebind()
                    retry("The speech recognition service stopped.")
                }

                else -> fail("Recognition failed (error $error).")
            }
        }

        override fun onResults(results: Bundle?) {
            // Read before [disarmEndpoint] clears it: whether the partial held
            // the transcript an empty final dropped is the arm nothing draws —
            // never the words themselves.
            val partialHeld = lastPartial.isNotEmpty()
            disarmEndpoint()
            val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val text = matches?.firstOrNull()?.trim()
            if (!text.isNullOrEmpty()) {
                send("heard", text)
            } else {
                // The arm nothing draws for a turn that never happens.
                Log.w(
                    TAG,
                    "empty final result (matches=${matches?.size ?: 0}, " +
                        "partial=${if (partialHeld) "held" else "empty"})",
                )
            }
            restart()
        }

        // What the service has so far. The text rather than the sound is what
        // says whether anyone is still talking: in a room with a television in
        // it the sound never stops and the transcription does.
        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text == lastPartial) return
            lastPartial = text
            armEndpoint()
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}
