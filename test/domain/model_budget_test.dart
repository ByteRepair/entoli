import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/domain/model_budget.dart";

/// Which catalog models a device is offered, from what it measured. The
/// numbers are the shapes real devices answer with, so a change to the shares
/// shows here as a model appearing or disappearing.
void main() {
  const gib = 1024 * 1024 * 1024;

  List<String> offered(ModelBudget budget, List<LocalModel> catalog) => [
    for (final model in catalog)
      if (budget.fits(model)) model.id,
  ];

  test("nothing measured offers everything", () {
    expect(
      offered(const ModelBudget.unknown(), mlxCatalog),
      mlxCatalog.map((m) => m.id),
    );
  });

  test("a 16 GB Mac is offered every MLX model, an 8 GB one not the 9B", () {
    // Metal's working set is about two thirds of a Mac's memory.
    final big = ModelBudget.mac(10 * gib + gib ~/ 2);
    final small = ModelBudget.mac(5 * gib + gib ~/ 3);

    expect(offered(big, mlxCatalog), mlxCatalog.map((m) => m.id));
    expect(offered(small, mlxCatalog), [mlxCatalog.first.id]);
  });

  test("a phone is held to a share of what its app may still grow by", () {
    // An 8 GB iPhone whose app may grow by about six: short of the 4B.
    final phone = ModelBudget.phone(workingSet: 5 * gib, available: 6 * gib);
    expect(offered(phone, mlxCatalog), isEmpty);
    // A 12 GB one has room for the 4B, and no larger.
    final roomy = ModelBudget.phone(workingSet: 9 * gib, available: 8 * gib);
    expect(offered(roomy, mlxCatalog), [mlxCatalog.first.id]);
    // However much Metal could keep resident, the app's own limit binds.
    final limited = ModelBudget.phone(workingSet: 12 * gib, available: 5 * gib);
    expect(offered(limited, mlxCatalog), isEmpty);
  });

  test("an Android phone is held to half its RAM", () {
    // What Android reports for 6, 8, 12 and 16 GB phones, a little under the
    // box. A Pixel 8 Pro is the 12: the 4B, and not the 9B.
    final six = ModelBudget.android(5 * gib + gib ~/ 2);
    final eight = ModelBudget.android(7 * gib + gib ~/ 2);
    final twelve = ModelBudget.android(11 * gib + gib ~/ 2);
    final sixteen = ModelBudget.android(15 * gib);

    expect(offered(six, ggufCatalog), [ggufCatalog[0].id]);
    expect(offered(eight, ggufCatalog), [ggufCatalog[0].id, ggufCatalog[1].id]);
    expect(offered(twelve, ggufCatalog), [
      ggufCatalog[0].id,
      ggufCatalog[1].id,
    ]);
    expect(offered(sixteen, ggufCatalog), ggufCatalog.map((m) => m.id));
  });

  test("a Linux machine is held to three fifths of its RAM", () {
    final twelve = ModelBudget.linux(11 * gib + gib ~/ 2);
    expect(offered(twelve, ggufCatalog), ggufCatalog.map((m) => m.id));
  });
}
