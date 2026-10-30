import "package:flutter/material.dart";

import "../chat/widgets/markdown_text.dart";
import "../../data/privacy_policy_data.dart";

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Privacy policy")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [const MarkdownText(bundledPrivacyPolicy)],
      ),
    );
  }
}
