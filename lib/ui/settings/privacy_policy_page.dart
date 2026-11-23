import "package:flutter/material.dart";

import "package:entoli_chat/ui/chat/widgets/markdown_text.dart";
import "../../data/privacy_policy_data.dart";
import "package:entoli_chat/ui/widgets/page_bar.dart";

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
