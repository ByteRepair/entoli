import "../../../domain/tool_arg.dart";
import "../../../domain/web_search.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

/// A `websearch` or `webfetch` call: the query or URL read out of the call's
/// arguments, and what came back behind it.
abstract class WebActivity extends ToolActivity {
  const WebActivity();

  /// The argument the call names its target by.
  String get targetArg;

  /// "Searching" and "Searched", "Fetching" and "Fetched".
  (String, String) get verbs;

  TranscriptGlyph get glyph;

  String get detailTitle;

  (String, String) get sectionLabels;

  String _target(Run run) =>
      stringArg(run.call?.argumentsJson, targetArg) ?? "";

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final result = run.result;
    return LabelNode(
      this,
      run,
      glyph: glyph,
      text: "${result == null ? verbs.$1 : verbs.$2}: ${_target(run)}",
      isError: run.failed,
      busy: run.going && result == null,
    );
  }

  @override
  ActivityDetail detail(SettingReader reader, Run run) => ActivityDetail(
    title: detailTitle,
    glyph: glyph,
    mono: true,
    sections: [
      DetailSection(label: sectionLabels.$1, body: _target(run)),
      DetailSection(label: sectionLabels.$2, body: run.result?.output),
      DetailSection(
        label: "Error",
        body: run.result?.exceptionInfo,
        isError: true,
      ),
    ],
  );
}

final class WebSearchActivity extends WebActivity {
  const WebSearchActivity();

  @override
  String get tool => websearchToolName;

  @override
  String get spoken => "Searched the web";

  @override
  String get targetArg => "query";

  @override
  (String, String) get verbs => ("Searching", "Searched");

  @override
  TranscriptGlyph get glyph => TranscriptGlyph.search;

  @override
  String get detailTitle => "Web search";

  @override
  (String, String) get sectionLabels => ("Query", "Results");
}

final class WebFetchActivity extends WebActivity {
  const WebFetchActivity();

  @override
  String get tool => webfetchToolName;

  @override
  String get spoken => "Read a page";

  @override
  (TranscriptGlyph, String) get approval =>
      (TranscriptGlyph.web, "Fetch this page?");

  @override
  String get targetArg => "url";

  @override
  (String, String) get verbs => ("Fetching", "Fetched");

  @override
  TranscriptGlyph get glyph => TranscriptGlyph.web;

  @override
  String get detailTitle => "Web fetch";

  @override
  (String, String) get sectionLabels => ("URL", "Content");
}
