import 'dart:async';

import 'package:budget/colors.dart';
import 'package:budget/struct/cometchatConfig.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:cometchat_chat_uikit/cometchat_chat_uikit.dart';
import 'package:flutter/material.dart';

class CometChatPage extends StatefulWidget {
  const CometChatPage({super.key});

  @override
  State<CometChatPage> createState() => _CometChatPageState();
}

class _CometChatPageState extends State<CometChatPage> {
  late final Future<void> _ready = _initializeAndLogin();

  Future<void> _initializeAndLogin() async {
    if (!CashewCometChatConfig.hasRequiredValues) {
      throw CometChatSetupException();
    }

    final settings = (UIKitSettingsBuilder()
          ..appId = CashewCometChatConfig.appId
          ..region = CashewCometChatConfig.region.toLowerCase()
          ..authKey = CashewCometChatConfig.authKey
          ..subscriptionType = CometChatSubscriptionType.allUsers
          ..autoEstablishSocketConnection = true
          ..extensions = CometChatUIKitChatExtensions.getDefaultExtensions())
        .build();

    await _init(settings);
    if (CometChatUIKit.loggedInUser?.uid == CashewCometChatConfig.uid) {
      return;
    }
    await _login(CashewCometChatConfig.uid);
  }

  Future<void> _init(UIKitSettings settings) {
    final completer = Completer<void>();
    CometChatUIKit.init(
      uiKitSettings: settings,
      onSuccess: (_) => completer.complete(),
      onError: (error) => completer.completeError(error),
    );
    return completer.future;
  }

  Future<void> _login(String uid) {
    final completer = Completer<void>();
    CometChatUIKit.login(
      uid,
      onSuccess: (_) => completer.complete(),
      onError: (error) => completer.completeError(error),
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return PageFramework(
            title: "Chat",
            listWidgets: [
              SizedBox(height: 80),
              Center(child: CircularProgressIndicator()),
            ],
          );
        }

        if (snapshot.hasError) {
          return _CometChatSetupState(error: snapshot.error);
        }

        return Scaffold(
          appBar: AppBar(
            title: Text("Chat"),
            backgroundColor: Theme.of(context).colorScheme.surface,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            elevation: 0,
          ),
          body: CometChatConversations(
            title: "Chats",
            showBackButton: false,
            onItemTap: (conversation) {
              User? user;
              Group? group;
              if (conversation.conversationWith is User) {
                user = conversation.conversationWith as User;
              } else if (conversation.conversationWith is Group) {
                group = conversation.conversationWith as Group;
              }
              if (user == null && group == null) return;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _CometChatMessagesPage(
                    user: user,
                    group: group,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _CometChatMessagesPage extends StatelessWidget {
  const _CometChatMessagesPage({this.user, this.group});

  final User? user;
  final Group? group;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CometChatMessageHeader(
        user: user,
        group: group,
        onBack: () => Navigator.pop(context),
        hideVoiceCallButton: true,
        hideVideoCallButton: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: CometChatMessageList(user: user, group: group),
          ),
          CometChatMessageComposer(
            user: user,
            group: group,
            hideVoiceRecordingButton: true,
          ),
        ],
      ),
    );
  }
}

class _CometChatSetupState extends StatelessWidget {
  const _CometChatSetupState({this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    final bool missingCredentials = error is CometChatSetupException;
    return PageFramework(
      title: "Chat",
      listWidgets: [
        Padding(
          padding:
              EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 40),
          child: Column(
            children: [
              Icon(
                appStateSettings["outlinedIcons"]
                    ? Icons.chat_bubble_outline
                    : Icons.chat_bubble_rounded,
                size: 54,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(height: 18),
              TextFont(
                text: missingCredentials
                    ? "CometChat credentials are not configured."
                    : "CometChat could not start.",
                fontSize: 22,
                fontWeight: FontWeight.bold,
                textAlign: TextAlign.center,
                maxLines: 3,
              ),
              SizedBox(height: 10),
              TextFont(
                text: missingCredentials
                    ? "Start the app with COMETCHAT_AUTH_KEY as a dart-define to enable chat."
                    : error.toString(),
                fontSize: 15,
                textAlign: TextAlign.center,
                maxLines: 8,
                textColor: getColor(context, "textLight"),
              ),
              SizedBox(height: 18),
              Button(
                label: "Back",
                onTap: () => Navigator.maybePop(context),
                padding: EdgeInsetsDirectional.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class CometChatSetupException implements Exception {
  @override
  String toString() {
    return "Missing CometChat dart-define values.";
  }
}
