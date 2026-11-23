import "package:flutter/material.dart";
import "package:entoli_core/view/chat/widgets/markdown_text.dart";
import "package:entoli_core/view/widgets/page_bar.dart";

import "../../data/privacy_policy_data.dart";

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
