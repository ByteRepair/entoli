import "package:flutter/material.dart";

import "../chat/widgets/markdown_text.dart";
import "../../data/privacy_policy_data.dart";
import "../widgets/page_bar.dart";

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PageBar(title: "Privacy policy"),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [const MarkdownText(bundledPrivacyPolicy)],
      ),
    );
  }
}
