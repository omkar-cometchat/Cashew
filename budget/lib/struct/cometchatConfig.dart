import 'package:budget/struct/cometchatSecrets.dart';

class CashewCometChatConfig {
  static const String appId = cashewCometChatAppId;
  static const String region = cashewCometChatRegion;
  static const String authKey = cashewCometChatAuthKey;
  static const String uid = cashewCometChatUid;

  static bool get hasRequiredValues =>
      appId.trim().isNotEmpty &&
      region.trim().isNotEmpty &&
      authKey.trim().isNotEmpty &&
      uid.trim().isNotEmpty;
}
