import "package:flutter/material.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "../../data/privacy_policy_data.dart";
import "../chat/widgets/code_block.dart";
import "../chat/widgets/reply_style.dart";

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text("Privacy policy")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MarkdownBody(
            data: bundledPrivacyPolicy,
            styleSheet: replyStyleSheet(theme),
            builders: codeBlockBuilders,
          ),
        ],
      ),
    );
  }
}