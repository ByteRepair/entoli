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

  test("a model holds its weights and its KV budget", () {
    final model = mlxCatalog.first;
    expect(ModelBudget.footprintOf(model), model.bytes! + kvBudgetBytes);
  });

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
    expect(offered(small, mlxCatalog), [mlxCatalog[0].id, mlxCatalog[1].id]);
  });

  test("a phone is held to a share of what its app may still grow by", () {
    // An 8 GB iPhone whose app may grow by about six: the 2B, and no larger.
    final phone = ModelBudget.phone(workingSet: 5 * gib, available: 6 * gib);
    expect(offered(phone, mlxCatalog), [mlxCatalog.first.id]);
    // However much Metal could keep resident, the app's own limit binds.
    final limited = ModelBudget.phone(workingSet: 12 * gib, available: 5 * gib);
    expect(offered(limited, mlxCatalog), [mlxCatalog.first.id]);
  });

  test("llama.cpp is held to three fifths of the RAM", () {
    // What Android reports for 8 and 12 GB phones, a little under the box.
    final eight = ModelBudget.memory(7 * gib + gib ~/ 2);
    final twelve = ModelBudget.memory(11 * gib + gib ~/ 2);

    expect(offered(eight, ggufCatalog), [ggufCatalog[0].id, ggufCatalog[1].id]);
    expect(offered(twelve, ggufCatalog), ggufCatalog.map((m) => m.id));
  });
}
