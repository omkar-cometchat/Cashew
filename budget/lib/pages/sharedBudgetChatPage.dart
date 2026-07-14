import 'package:budget/cometchat/cashew_cometchat_service.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:cometchat_chat_uikit/cometchat_chat_uikit.dart';
import 'package:flutter/material.dart';

class SharedBudgetChatPage extends StatefulWidget {
  const SharedBudgetChatPage({super.key, required this.budget});

  final Budget budget;

  @override
  State<SharedBudgetChatPage> createState() => _SharedBudgetChatPageState();
}

class _SharedBudgetChatPageState extends State<SharedBudgetChatPage> {
  late Future<Group> _chatFuture;

  @override
  void initState() {
    super.initState();
    _chatFuture = CashewCometChatService.instance.ensureSharedBudgetChat(
      widget.budget,
    );
  }

  void _retry() {
    setState(() {
      _chatFuture = CashewCometChatService.instance.ensureSharedBudgetChat(
        widget.budget,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Group>(
      future: _chatFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return _SharedBudgetCometChatScreen(group: snapshot.data!);
        }

        return Scaffold(
          appBar: AppBar(title: Text(widget.budget.name)),
          body: SafeArea(
            child: Center(
              child: snapshot.hasError
                  ? Padding(
                      padding: const EdgeInsetsDirectional.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            appStateSettings["outlinedIcons"]
                                ? Icons.chat_bubble_outline_outlined
                                : Icons.chat_bubble_rounded,
                            size: 42,
                          ),
                          const SizedBox(height: 16),
                          TextFont(
                            text: 'Chat is not ready',
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          TextFont(
                            text: snapshot.error.toString(),
                            fontSize: 15,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 18),
                          Button(label: 'Try Again', onTap: _retry),
                        ],
                      ),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
        );
      },
    );
  }
}

class _SharedBudgetCometChatScreen extends StatelessWidget {
  const _SharedBudgetCometChatScreen({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: SafeArea(
          bottom: false,
          child: CometChatMessageHeader(
            group: group,
            showBackButton: true,
            hideVideoCallButton: true,
            hideVoiceCallButton: true,
            onBack: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: CometChatMessageList(
                group: group,
                hideReplyInThreadOption: true,
              ),
            ),
            CometChatMessageComposer(group: group),
          ],
        ),
      ),
    );
  }
}
