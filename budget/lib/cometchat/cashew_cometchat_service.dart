import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/cometchatSecrets.dart';
import 'package:cometchat_chat_uikit/cometchat_chat_uikit.dart';
import 'package:drift/drift.dart' show Value;
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

class CashewCometChatService {
  CashewCometChatService._();

  static final CashewCometChatService instance = CashewCometChatService._();

  Future<void>? _initFuture;
  Future<User?>? _loginFuture;

  /// Resolved auth key: compile-time constant first, then JSON asset fallback.
  static String? _resolvedAuthKey;

  /// Resolves the CometChat auth key. Prefers the compile-time
  /// `--dart-define=COMETCHAT_AUTH_KEY` value. When that is empty (the common
  /// local-dev case), falls back to reading
  /// `assets/secrets/cometchat_local.json`.
  static Future<String> _resolveAuthKey() async {
    if (_resolvedAuthKey != null) return _resolvedAuthKey!;

    // 1. Compile-time constant (--dart-define takes priority).
    if (cashewCometChatAuthKey.trim().isNotEmpty) {
      _resolvedAuthKey = cashewCometChatAuthKey.trim();
      return _resolvedAuthKey!;
    }

    // 2. Bundled JSON asset fallback (gitignored, local-only).
    try {
      final jsonStr = await rootBundle
          .loadString('assets/secrets/cometchat_local.json');
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final key = (data['authKey'] as String?)?.trim() ?? '';
      if (key.isNotEmpty) {
        _resolvedAuthKey = key;
        return _resolvedAuthKey!;
      }
    } catch (_) {
      // Asset not bundled or malformed — fall through.
    }

    _resolvedAuthKey = '';
    return _resolvedAuthKey!;
  }

  bool get hasDevAuthKey =>
      _resolvedAuthKey != null && _resolvedAuthKey!.isNotEmpty;

  String groupGuidForSharedBudget(String sharedKey) {
    final safeSharedKey = sharedKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final guid = 'cashew_shared_budget_$safeSharedKey';
    return guid.length <= 100 ? guid : guid.substring(0, 100);
  }

  String currentUserUid() {
    final currentUser = firebase_auth.FirebaseAuth.instance.currentUser;
    final email = currentUser?.email;
    if (email != null && email.trim().isNotEmpty) {
      return uidForEmail(email);
    }

    final firebaseUid = currentUser?.uid;
    if (firebaseUid != null && firebaseUid.trim().isNotEmpty) {
      return _safeUid('cashew_firebase_$firebaseUid');
    }

    return cashewCometChatUid;
  }

  String currentUserName() {
    final currentUser = firebase_auth.FirebaseAuth.instance.currentUser;
    final displayName = currentUser?.displayName;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    final email = currentUser?.email;
    if (email != null && email.trim().isNotEmpty) {
      return email.trim();
    }

    return 'Cashew User';
  }

  String uidForEmail(String email) {
    final normalized = email.trim().toLowerCase();
    final encoded = base64Url
        .encode(utf8.encode(normalized))
        .replaceAll('=', '');
    return 'cashew_email_$encoded';
  }

  Future<void> ensureInitialized() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    if (cashewCometChatAppId.trim().isEmpty ||
        cashewCometChatRegion.trim().isEmpty) {
      throw StateError('CometChat app id and region are required.');
    }

    final authKey = await _resolveAuthKey();

    final settingsBuilder = UIKitSettingsBuilder()
      ..appId = cashewCometChatAppId.trim()
      ..region = cashewCometChatRegion.trim().toLowerCase()
      ..subscriptionType = CometChatSubscriptionType.allUsers
      ..authKey = authKey.isNotEmpty ? authKey : null;

    await CometChatUIKit.init(
      uiKitSettings: settingsBuilder.build(),
      onError: (error) {
        throw error;
      },
    );
  }

  Future<User?> ensureCurrentUser() {
    _loginFuture ??= _ensureCurrentUser();
    return _loginFuture!;
  }

  Future<User?> _ensureCurrentUser() async {
    await _resolveAuthKey();
    if (!hasDevAuthKey) {
      throw StateError(
        'Provide a CometChat auth key via --dart-define=COMETCHAT_AUTH_KEY=... '
        'or place it in assets/secrets/cometchat_local.json.',
      );
    }

    await ensureInitialized();

    final uid = currentUserUid();
    final loggedInUser = await CometChat.getLoggedInUser();
    if (loggedInUser?.uid == uid) return loggedInUser;

    if (loggedInUser != null && loggedInUser.uid != uid) {
      await CometChatUIKit.logout();
    }

    await ensureUser(uid: uid, name: currentUserName());
    return CometChatUIKit.login(uid);
  }

  Future<User?> ensureUser({required String uid, required String name}) async {
    await ensureInitialized();

    CometChatException? sdkError;
    final user = await CometChatUIKit.createUser(
      User(uid: uid, name: name.trim().isEmpty ? uid : name.trim()),
      onError: (error) {
        sdkError = error;
      },
    );

    if (user != null || _isAlreadyExistsError(sdkError)) return user;
    if (sdkError != null) throw sdkError!;
    return user;
  }

  Future<Group> ensureSharedBudgetChat(Budget budget) async {
    final sharedKey = budget.sharedKey;
    if (sharedKey == null || sharedKey.trim().isEmpty) {
      throw StateError('Budget must be shared before opening chat.');
    }

    await ensureCurrentUser();

    final guid = groupGuidForSharedBudget(sharedKey);
    final canManageChat = _canManageSharedBudgetChat(budget);
    Group? group = await _getGroup(guid);
    if (group == null) {
      if (canManageChat) {
        final groupName =
            budget.name.trim().isEmpty ? 'Shared Budget' : budget.name.trim();
        group = await _createGroup(
          guid: guid,
          name: groupName,
        );
      } else {
        group = await _joinSharedBudgetChat(guid);
      }
    } else if (!group.hasJoined && !canManageChat) {
      group = await _joinSharedBudgetChat(guid);
    }

    if (canManageChat) {
      await syncSharedBudgetMembers(budget);
      return await _getGroup(guid) ?? group;
    }

    return group;
  }

  Future<void> syncSharedBudgetMembers(Budget budget) async {
    final sharedKey = budget.sharedKey;
    if (sharedKey == null || sharedKey.trim().isEmpty) return;
    if (!_canManageSharedBudgetChat(budget)) return;

    final emails = <String>{
      ...?budget.sharedMembers,
      firebase_auth.FirebaseAuth.instance.currentUser?.email ?? '',
    }..removeWhere((email) => email.trim().isEmpty);

    if (emails.isEmpty) return;

    final members = <GroupMember>[];
    for (final email in emails) {
      final uid = uidForEmail(email);
      await ensureUser(uid: uid, name: email);
      if (uid != currentUserUid()) {
        members.add(
          GroupMember.fromUid(uid: uid, name: email, scope: 'participant'),
        );
      }
    }

    if (members.isEmpty) return;

    CometChatException? sdkError;
    await CometChat.addMembersToGroup(
      guid: groupGuidForSharedBudget(sharedKey),
      groupMembers: members,
      onSuccess: null,
      onError: (error) {
        sdkError = error;
      },
    );

    if (sdkError != null && !_isAlreadyExistsError(sdkError)) {
      debugPrint('CometChat member sync failed: ${sdkError!.message}');
    }
  }

  Future<void> addMemberToSharedBudgetChat({
    required String sharedKey,
    required String memberEmail,
    required Budget budget,
  }) async {
    final uid = uidForEmail(memberEmail);
    final currentUid = currentUserUid();

    if (!_canManageSharedBudgetChat(budget)) {
      await ensureCurrentUser();
      if (uid == currentUid) {
        await _joinSharedBudgetChat(groupGuidForSharedBudget(sharedKey));
      }
      return;
    }

    await ensureSharedBudgetChat(budget.copyWith(sharedKey: Value(sharedKey)));
    await ensureUser(uid: uid, name: memberEmail);

    await CometChat.addMembersToGroup(
      guid: groupGuidForSharedBudget(sharedKey),
      groupMembers: [
        GroupMember.fromUid(uid: uid, name: memberEmail, scope: 'participant'),
      ],
      onSuccess: null,
      onError: (error) {
        if (!_isAlreadyExistsError(error)) {
          debugPrint('CometChat add member failed: ${error.message}');
        }
      },
    );
  }

  Future<void> removeMemberFromSharedBudgetChat({
    required String sharedKey,
    required String memberEmail,
  }) async {
    await ensureCurrentUser();
    final uid = uidForEmail(memberEmail);

    await CometChat.kickGroupMember(
      guid: groupGuidForSharedBudget(sharedKey),
      uid: uid,
      onSuccess: null,
      onError: (error) {
        if (!_isAlreadyRemovedError(error)) {
          debugPrint('CometChat remove member failed: ${error.message}');
        }
      },
    );
  }

  Future<void> leaveSharedBudgetChat(String sharedKey) async {
    await ensureCurrentUser();

    await CometChat.leaveGroup(
      groupGuidForSharedBudget(sharedKey),
      onSuccess: null,
      onError: (error) {
        if (!_isAlreadyRemovedError(error)) {
          debugPrint('CometChat leave group failed: ${error.message}');
        }
      },
    );
  }

  Future<void> deleteSharedBudgetChat(String sharedKey) async {
    await ensureCurrentUser();

    await CometChat.deleteGroup(
      groupGuidForSharedBudget(sharedKey),
      onSuccess: null,
      onError: (error) {
        if (!_isAlreadyRemovedError(error)) {
          debugPrint('CometChat delete group failed: ${error.message}');
        }
      },
    );
  }

  Future<Group?> _getGroup(String guid) async {
    return CometChat.getGroup(guid, onSuccess: null, onError: (_) {});
  }

  Future<Group> _joinSharedBudgetChat(String guid) async {
    CometChatException? sdkError;
    final joinedGroup = await CometChat.joinGroup(
      guid,
      'private',
      onSuccess: null,
      onError: (error) {
        sdkError = error;
      },
    );

    if (joinedGroup != null) return joinedGroup;

    final existingGroup = await _getGroup(guid);
    if (existingGroup != null && existingGroup.hasJoined) return existingGroup;

    if (sdkError != null) throw sdkError!;
    throw StateError('Shared budget chat is not available yet.');
  }

  Future<Group> _createGroup({
    required String guid,
    required String name,
  }) async {
    CometChatException? sdkError;
    final group = await CometChat.createGroup(
      group: Group(guid: guid, name: name, type: 'private'),
      onSuccess: null,
      onError: (error) {
        sdkError = error;
      },
    );

    if (group != null) return group;
    if (_isAlreadyExistsError(sdkError)) {
      final existingGroup = await _getGroup(guid);
      if (existingGroup != null) return existingGroup;
    }

    if (sdkError != null) throw sdkError!;
    throw StateError('Unable to create CometChat group for $name.');
  }

  String _safeUid(String rawUid) {
    final safe = rawUid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.length <= 100 ? safe : safe.substring(0, 100);
  }

  bool _canManageSharedBudgetChat(Budget budget) {
    return budget.sharedOwnerMember == SharedOwnerMember.owner;
  }

  bool _isAlreadyExistsError(Object? error) {
    if (error == null) return false;
    final text = error is CometChatException
        ? '${error.code} ${error.details} ${error.message}'.toLowerCase()
        : error.toString().toLowerCase();
    return text.contains('already') || text.contains('exists');
  }

  bool _isAlreadyRemovedError(Object? error) {
    if (error == null) return false;
    final text = error is CometChatException
        ? '${error.code} ${error.details} ${error.message}'.toLowerCase()
        : error.toString().toLowerCase();
    return text.contains('not found') ||
        text.contains('not a member') ||
        text.contains('does not exist') ||
        text.contains('not joined') ||
        text.contains('not part');
  }
}
