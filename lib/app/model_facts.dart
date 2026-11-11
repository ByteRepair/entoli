import "../core/formatting.dart";
import "../domain/installable.dart";

/// Which fact a tag tells, for a frontend to give it a picture.
enum ModelFact {
  parameters,
  languages,
  size,
  quantisation,
  context,
  voices,
  licence,
}

/// [facts] as tags, as many as are known, in one order for every catalog.
List<(ModelFact, String)> modelFactTags(ModelFacts facts) => [
  if (facts.parameters case final p?) (ModelFact.parameters, "$p params"),
  if (facts.languages case final l?) (ModelFact.languages, l),
  if (facts.bytes case final b?) (ModelFact.size, formatSize(b)),
  if (facts.quantisation case final q?) (ModelFact.quantisation, q),
  if (facts.context case final n?)
    (ModelFact.context, "${tokenCount(n)} context"),
  if (facts.voices case final v?) (ModelFact.voices, plural(v, "voice")),
  if (facts.licence case final l?) (ModelFact.licence, l),
];

/// The hue a provider's monogram wears, 0 to 359, from its name's characters
/// rather than `hashCode`, which is not the same from one run to the next:
/// so a provider wears one colour on every frontend.
int providerHue(String name) =>
    name.codeUnits.fold(0, (a, c) => a * 31 + c) % 360;
