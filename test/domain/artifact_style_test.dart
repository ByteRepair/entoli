import "package:agent_chat/domain/artifact_style.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("injectBaseStyles", () {
    test("inserts fonts and style into an existing <head>", () {
      final html = "<!DOCTYPE html><html><head><title>x</title></head><body><p>hi</p></body></html>";
      final out = injectBaseStyles(html);

      expect(out, contains("<!-- entoli-base-css -->"));
      expect(out, contains("fonts.googleapis.com"));
      expect(out, contains("--accent: #8b1a1a;"));
      // Original head content survives.
      expect(out, contains("<title>x</title>"));
      expect(out, contains("<p>hi</p>"));
    });

    test("opens a <head> when the html has one but no head", () {
      final html = "<!DOCTYPE html><html><body><h1>hi</h1></body></html>";
      final out = injectBaseStyles(html);

      expect(out, contains("<head>"));
      expect(out, contains("<!-- entoli-base-css -->"));
      expect(out, contains("<h1>hi</h1>"));
      expect(out.indexOf("<head>"), lessThan(out.indexOf("<body>")));
    });

    test("wraps a bare fragment in a full document", () {
      final html = "<h1>Just a heading</h1>";
      final out = injectBaseStyles(html);

      expect(out, startsWith("<!DOCTYPE html>"));
      expect(out, contains("<head>"));
      expect(out, contains("<!-- entoli-base-css -->"));
      expect(out, contains("<h1>Just a heading</h1>"));
    });

    test("does not inject twice when the marker is already present", () {
      const html =
          "<!DOCTYPE html><html><head><!-- entoli-base-css --><style>x{}</style></head><body></body></html>";
      final out = injectBaseStyles(html);

      // Exactly one occurrence of the marker.
      expect("<!-- entoli-base-css -->".allMatches(out).length, 1);
      // The pre-existing style is preserved.
      expect(out, contains("x{}"));
      // The fonts link is not added on a second pass.
      expect(out, isNot(contains("fonts.googleapis.com")));
    });

    test("preserves the model's own <style> block after the base style", () {
      const withModel =
          '<!DOCTYPE html><html><head><style>h1 { color: rebeccapurple; }</style></head><body><h1>x</h1></body></html>';
      final out = injectBaseStyles(withModel);

      // Both the base marker and the model's own style are present.
      expect(out, contains("<!-- entoli-base-css -->"));
      expect(out, contains("rebeccapurple"));
      // The base injection lands before the model's style, so the model wins
      // on equal specificity.
      expect(out.indexOf("<!-- entoli-base-css -->"),
          lessThan(out.indexOf("rebeccapurple")));
    });
  });
}