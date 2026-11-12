import "package:flutter/foundation.dart" show LicenseEntryWithLineBreaks;
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../data/licence_data.dart";
import "../../domain/chat_log.dart";
import "../../domain/local_model.dart" show isShortAskModel;
import "../../domain/models.dart";
import "../../domain/project.dart";
import "../../providers.dart";
import "../selection.dart";
import "../settings/controller.dart";
import "../settings/forms/provider.dart";
import "../settings/hand_off.dart";
import "../settings/pages/providers.dart" show providerForm, saveProvider;
import "../settings/scope.dart";
import "../settings/settings.dart";
import "../settings/spec.dart";
import "app_page.dart";
import "cli_sign_in.dart";
import "marketplace.dart";
import "setup.dart";
import "../first_run.dart";

/// Opens what a first launch shows before the app: the device's setup
/// where a step of it is not done, then the welcome tour, until the tour is
/// finished. Both frontends ask it as they start.
void openFirstRun(SettingReader app) {
  if (app.read(appSettingsProvider).licenceAccepted) return;
  final pages = app.read(appPagesProvider.notifier);
  final plan = app.read(setupPlanProvider);
  void welcome() => pages.open(WelcomeAppPage());
  if (plan.steps.every((s) => s.done(app))) return welcome();
  pages.open(
    SetupAppPage(
      plan,
      onFinished: () {
        pages.close("first-run-setup");
        welcome();
      },
    ),
  );
}

/// The welcome tour: what Entoli is, a model to answer with, what else
/// there is to set up, and the licence to agree to. On a first launch it is
/// the way into the app and cannot be left but by Done; replayed from
/// Settings it is a page like any other.
class WelcomeAppPage extends AppPage {
  WelcomeAppPage({this.replay = false});

  final bool replay;

  int _step = 0;
  static const _steps = 4;

  @override
  String get address => "welcome";

  @override
  SettingConfirm? leaving(SettingReader reader) => replay
      ? null
      : const SettingConfirm.note("Finish the tour to start using Entoli.");

  @override
  String title(SettingReader reader) => switch (_step) {
    0 => "Welcome to Entoli",
    1 => "Connect a Model",
    2 => "More to Set Up",
    _ => "Check Its Work",
  };

  @override
  String? subtitle(SettingReader reader) => "${_step + 1} of $_steps";

  /// What answers a chat: a short-ask model, which an Apple device lists
  /// before anything is set up, does not count.
  int _models(SettingReader reader) =>
      (reader.watch(availableModelsProvider).value ?? const [])
          .where((m) => !isShortAskModel(m.providerId, m.modelId))
          .length;

  /// The model step holds the tour until some model is reachable and new
  /// chats have one to answer them.
  bool _gated(SettingReader reader) =>
      _step == 1 &&
      !(_models(reader) > 0 &&
          reader.watch(appSettingsProvider).defaultProviderId != null);

  @override
  List<PageSection> sections(SettingReader reader) => switch (_step) {
    0 => _intro(),
    1 => _model(reader),
    2 => _extras(reader),
    _ => _responsibility(reader),
  };

  List<PageSection> _intro() => [
    PageSection("intro", "", [
      InfoController(
        part("features", "Entoli", hint: UiHint.info),
        rows: const [
          InfoRow(
            "Bring your own model",
            subtitle:
                "A provider you choose, or one running right on this "
                "device.",
            glyph: SettingGlyph.cloud,
          ),
          InfoRow(
            "It works on your machine",
            subtitle: "Commands run in a workspace here, with your approval.",
            glyph: SettingGlyph.terminal,
          ),
          InfoRow(
            "Made of your files",
            subtitle: "Skills, agents and memories are plain files you own.",
            glyph: SettingGlyph.folder,
          ),
          InfoRow(
            "Works on schedule",
            subtitle: "A task at a time you pick, or when a file changes.",
            glyph: SettingGlyph.schedule,
          ),
          InfoRow(
            "On all your devices",
            subtitle: "Pair them and pick up a chat where you left it.",
            glyph: SettingGlyph.computer,
          ),
          InfoRow(
            "Yours alone",
            subtitle:
                "Nothing leaves without your say-so, and nothing is "
                "watermarked.",
            glyph: SettingGlyph.privacy,
          ),
        ],
      ),
    ], detail: "An assistant that runs on your machine and answers to you."),
  ];

  /// A row that opens Settings at [page], where the platform offers it.
  SettingController? _settingsRow(
    SettingReader reader,
    String id,
    String title,
    String detail,
    SettingsPageId page,
  ) {
    if (!pageOffered(reader, page)) return null;
    return ActionController(
      part(id, title, hint: UiHint.open, description: detail),
      label: "",
      run: () async {
        await app.read(settingsHandOffProvider).openSettings?.call(page);
        return null;
      },
    );
  }

  /// Where the model runs: a service by the name its user knows it by,
  /// connected with its recommended models, or the settings that hold the
  /// rest. A service chosen here answers new chats at its own defaults, so
  /// nothing is picked, unless models are reachable with nothing answering.
  List<PageSection> _model(SettingReader reader) {
    final count = _models(reader);
    final unanswered =
        reader.watch(appSettingsProvider).defaultProviderId == null;
    final scope = scopeAt(reader, const AppAddress());
    return [
      PageSection("services", "", [
        for (final service in welcomeProviders)
          if (service.supported) _service(service),
        ?_settingsRow(
          reader,
          "local",
          "Local Model",
          "Download a model. No key, no network.",
          SettingsPageId.onDevice,
        ),
        ?_settingsRow(
          reader,
          "advanced",
          "Advanced",
          "Other providers, and endpoints by URL.",
          SettingsPageId.providers,
        ),
      ], detail: "Choose a service. Entoli uses its recommended model."),
      PageSection("ready", "", [
        NoticeController(
          part("ready", ""),
          tone: count > 0 ? NoticeTone.good : NoticeTone.plain,
          lines: [
            NoticeLine(
              count == 0
                  ? "Set one up to continue."
                  : count == 1
                  ? "1 model ready"
                  : "$count models ready",
            ),
          ],
        ),
        if (count > 0 && unanswered) ...[
          shared(reader, scope, "defaultModel"),
          shared(reader, scope, "titleModel"),
        ],
      ]),
    ];
  }

  /// [service], connected as its kind is: a program installed and signed
  /// in, an API through its preset's form.
  SettingController _service(OfferedByName service) => switch (service) {
    final CliProvider cli => ActionController(
      part(
        service.serviceName,
        service.serviceName,
        hint: UiHint.open,
        description: service.connectHint,
        glyph: SettingGlyph.cloud,
      ),
      label: "",
      run: () async {
        await connectCli(app, pages, cli);
        return null;
      },
    ),
    _ => _connectApi(service as LlmProvider),
  };

  SettingController _connectApi(LlmProvider service) {
    final name = (service as OfferedByName).serviceName;
    late final ProviderForm form = providerForm(app, null, preset: service);
    return CollectionController<ProviderDraft>(
      part(name, name, hint: UiHint.row, description: service.connectHint),
      items: const [],
      removable: false,
      addLabel: "Connect $name…",
      form: (_) => form,
      submit: (answers, _) => saveProvider(app, form, answers, adopt: true),
      describe: (_) => const CollectionItem(""),
    );
  }

  List<PageSection> _extras(SettingReader reader) => [
    PageSection("extras", "", [
      ActionController(
        part(
          "marketplace",
          "Marketplace",
          hint: UiHint.open,
          description: "Install skills and agents others have shared.",
          glyph: SettingGlyph.skill,
        ),
        label: "",
        run: () async {
          pages.open(MarketplaceAppPage());
          return null;
        },
      ),
      ?_settingsRow(
        reader,
        "byteRepair",
        "Byte Repair",
        "Code proved correct, not merely plausible.",
        SettingsPageId.byteRepair,
      ),
      ?_settingsRow(
        reader,
        "triggers",
        "Triggers",
        "A prompt sent on a schedule or when a file changes.",
        SettingsPageId.triggers,
      ),
      ?_settingsRow(
        reader,
        "voice",
        "Voice",
        "Talk to the agent and hear it answer.",
        SettingsPageId.voice,
      ),
      ?_settingsRow(
        reader,
        "images",
        "Image generation",
        "Let the agent make images, shown in the chat.",
        SettingsPageId.images,
      ),
    ], detail: "Optional, and all here later."),
  ];

  static final _licence = LicenseEntryWithLineBreaks(const [
    "Entoli",
  ], bundledLicence).paragraphs.toList();

  bool _accepted = false;

  List<PageSection> _responsibility(SettingReader reader) {
    final agreed = reader.watch(appSettingsProvider).licenceAccepted;
    return [
      PageSection(
        "licence",
        "",
        [
          NoticeController(
            part("licence", ""),
            lines: [for (final p in _licence) NoticeLine(p.text)],
          ),
        ],
        detail:
            "AI can make mistakes. Review what it does, and the commands you "
            "approve, before you rely on them. Entoli comes under the licence "
            "below, with no warranty.",
      ),
      PageSection("agree", "", [
        if (agreed)
          ActionController(
            part("withdraw", "Untick the Licence…", hint: UiHint.button),
            label: "Untick the Licence…",
            destructive: true,
            confirm: () async => const SettingConfirm(
              title: "Untick the licence?",
              message: "By unticking, the app will restart.",
              confirmLabel: "Restart",
              destructive: true,
            ),
            run: () async {
              final restart = app.read(appRestartProvider);
              await app
                  .read(appSettingsProvider.notifier)
                  .setLicenceAccepted(false);
              await restart.restart();
              return null;
            },
          )
        else
          ToggleController(
            part(
              "accept",
              "I have read the licence, and I take full responsibility for "
                  "how I use Entoli and what I let it do.",
              hint: UiHint.toggle,
            ),
            value: _accepted,
            effective: _accepted,
            onSet: (on) async {
              _accepted = on ?? false;
              changed();
              return null;
            },
          ),
      ]),
    ];
  }

  @override
  List<ActionController> toolbar(SettingReader reader) {
    final last = _step == _steps - 1;
    final agreed =
        _accepted || reader.watch(appSettingsProvider).licenceAccepted;
    return [
      if (last)
        ActionController(
          part("done", "Done"),
          label: "Done",
          enabled: agreed,
          run: _done,
        )
      else
        ActionController(
          part("next", "Next"),
          label: "Next",
          enabled: !_gated(reader),
          run: () async {
            _step++;
            changed();
            return null;
          },
        ),
      if (_step > 0)
        ActionController(
          part("back", "Back"),
          label: "Back",
          secondary: true,
          run: () async {
            _step--;
            changed();
            return null;
          },
        ),
    ];
  }

  /// Opens the welcome chat: the `/entoli-welcome-party` skill as its first
  /// message, so its instructions reach every turn the way any skill
  /// message's do, and its greeting under that. The default project's,
  /// whose library holds the skill.
  Future<SettingNotice?> _done() async {
    final repo = app.read(chatRepositoryProvider);
    try {
      final chat = await repo.createChat(title: "Welcome to Entoli");
      final greeting = Message(
        id: const Uuid().v4(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        parts: const [MessagePart.text(text: _greeting)],
      );
      await repo.append(chat.state.id, [
        ...recordsOf([
          repo.composeUserPrompt("/entoli-welcome-party"),
          greeting,
        ]),
        ChatRecord.turnEnd(messageId: greeting.id, reason: TurnEnd.done),
      ]);
      app.read(selectedProjectProvider.notifier).select(localProject(null));
      app.read(selectedChatIdProvider.notifier).select(chat.state.id);
      app.invalidate(chatListProvider);
    } catch (e) {
      logFailure("welcome", "could not start the welcome chat", e);
    }
    await app.read(appSettingsProvider.notifier).setLicenceAccepted(true);
    pages.closeAll();
    return null;
  }

  static const _greeting =
      "Hello! Welcome to Entoli. I'm here to welcome you "
      "and help you customize the experience.\n\n"
      "By the way, if you ever want to talk to me again, just type "
      "/entoli-welcome-party and I'll respond.\n\n"
      "I have a few brief questions for you. What's your name?";
}

/// Connects [service], Entoli's own copy of its program installed and
/// signed in where it is not yet, and added once it is; where an entry for
/// it is already configured, that one adopted rather than a second added.
Future<void> connectCli(
  SettingReader app,
  AppPages pages,
  CliProvider service,
) async {
  final notifier = app.read(appSettingsProvider.notifier);
  final programs = app.read(cliProgramsProvider);
  final existing = app
      .read(appSettingsProvider)
      .llmProviders
      .where((p) => p.api == service.config.api && p.command == null)
      .firstOrNull;
  // A new entry's id first: its account is kept in a folder named by it.
  final config = existing ?? service.config.copyWith(id: const Uuid().v4());
  final page = CliSignInAppPage(config);
  pages.open(page);
  if (!await page.done) {
    // A new entry given up on: its folders under every program go.
    if (existing == null) {
      for (final cli in programs) {
        await cli.withConfig(cli.config.copyWith(id: config.id)).forget();
      }
    }
    return;
  }
  await notifier.upsertProvider(config, adopt: true);
}
