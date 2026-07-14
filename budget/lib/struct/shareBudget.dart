import 'dart:async';
import 'package:budget/cometchat/cashew_cometchat_service.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:drift/drift.dart' hide Query, Column;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:budget/struct/firebaseAuthGlobal.dart';

const String sharedBudgetInvitesCollection = "sharedBudgetInvites";

String normalizeSharedBudgetEmail(String email) {
  return email.trim().toLowerCase();
}

DateTime? _dateTimeFromFirestore(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

class SharedBudgetInvite {
  SharedBudgetInvite({
    required this.inviteId,
    required this.budgetId,
    required this.budgetName,
    required this.ownerUid,
    required this.ownerEmail,
    required this.invitedEmail,
    required this.status,
    required this.createdAt,
    this.respondedAt,
  });

  final String inviteId;
  final String budgetId;
  final String budgetName;
  final String ownerUid;
  final String ownerEmail;
  final String invitedEmail;
  final String status;
  final DateTime createdAt;
  final DateTime? respondedAt;

  bool get isPending => status == "pending";

  factory SharedBudgetInvite.fromSnapshot(DocumentSnapshot snapshot) {
    final data = (snapshot.data() as Map<dynamic, dynamic>?) ?? {};
    return SharedBudgetInvite(
      inviteId: snapshot.id,
      budgetId: (data["budgetId"] ?? "").toString(),
      budgetName: (data["budgetName"] ?? "Shared Budget").toString(),
      ownerUid: (data["ownerUid"] ?? "").toString(),
      ownerEmail: (data["ownerEmail"] ?? "").toString(),
      invitedEmail: normalizeSharedBudgetEmail(
        (data["invitedEmail"] ?? "").toString(),
      ),
      status: (data["status"] ?? "pending").toString(),
      createdAt: _dateTimeFromFirestore(data["createdAt"]) ?? DateTime.now(),
      respondedAt: _dateTimeFromFirestore(data["respondedAt"]),
    );
  }
}

String _inviteDocumentId(String sharedKey, String memberEmail) {
  final safeEmail = normalizeSharedBudgetEmail(
    memberEmail,
  ).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return "${sharedKey}_$safeEmail";
}

Future<bool> shareBudget(Budget? budgetToShare, context) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (budgetToShare == null) {
    return false;
  }
  print(budgetToShare.budgetPk);
  // Share budget information
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    return false;
  }
  print(budgetToShare.reoccurrence);
  print(enumRecurrence[budgetToShare.reoccurrence]);
  Map<String, dynamic> budgetEntry = {
    "name": budgetToShare.name,
    "amount": budgetToShare.amount,
    "colour": budgetToShare.colour,
    "startDate": budgetToShare.startDate,
    "endDate": budgetToShare.endDate,
    "periodLength": budgetToShare.periodLength,
    "reoccurrence": enumRecurrence[budgetToShare.reoccurrence],
    "members": [
      normalizeSharedBudgetEmail(FirebaseAuth.instance.currentUser!.email ?? ""),
    ],
    "pendingMembers": [],
    "dateShared": DateTime.now(),
    "owner": FirebaseAuth.instance.currentUser!.uid,
    "ownerEmail": normalizeSharedBudgetEmail(
      FirebaseAuth.instance.currentUser!.email ?? "",
    ),
    "dateUpdated": DateTime.now(),
  };

  DocumentReference budgetCreatedOnCloud = await db
      .collection("budgets")
      .add(budgetEntry);

  final sharedBudget = budgetToShare.copyWith(
    sharedKey: Value(budgetCreatedOnCloud.id),
    sharedOwnerMember: Value(SharedOwnerMember.owner),
    sharedDateUpdated: Value(DateTime.now()),
    sharedMembers: Value([
      normalizeSharedBudgetEmail(FirebaseAuth.instance.currentUser!.email ?? ""),
    ]),
    sharedAllMembersEver: Value([
      normalizeSharedBudgetEmail(FirebaseAuth.instance.currentUser!.email ?? ""),
    ]),
    categoryFks: Value(null),
    budgetTransactionFilters: Value(null),
    memberTransactionFilters: Value(null),
  );

  await database.createOrUpdateBudget(sharedBudget, updateSharedEntry: false);
  unawaited(_ensureCometChatSharedBudget(sharedBudget));

  openSnackbar(SnackbarMessage(title: "Shared Budget"));
  loadingProgressKey.currentState?.setProgressPercentage(0);
  return true;
}

Future<bool> removedSharedFromBudget(
  Budget sharedBudget, {
  bool removeFromServer = true,
}) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (removeFromServer)
    try {
      FirebaseFirestore? db = await firebaseGetDBInstance();
      if (db == null) {
        return false;
      }
      unawaited(_deleteCometChatSharedBudget(sharedBudget.sharedKey));
      DocumentReference collectionRef = db
          .collection('budgets')
          .doc(sharedBudget.sharedKey);
      CollectionReference transactionSubCollection = db
          .collection('budgets')
          .doc(sharedBudget.sharedKey)
          .collection("transactions");

      WriteBatch batch = db.batch();
      final QuerySnapshot transactionsOnCloud = await transactionSubCollection
          .get();
      // print(transactionsOnCloud);
      for (DocumentSnapshot transaction in transactionsOnCloud.docs) {
        print(transaction);
        DocumentReference transactionSubCollectionDoc = transactionSubCollection
            .doc(transaction.id);
        batch.delete(transactionSubCollectionDoc);
      }
      final QuerySnapshot pendingInvites = await db
          .collection(sharedBudgetInvitesCollection)
          .where("budgetId", isEqualTo: sharedBudget.sharedKey)
          .get();
      for (DocumentSnapshot invite in pendingInvites.docs) {
        batch.delete(invite.reference);
      }
      await batch.commit();
      await collectionRef.delete();
    } catch (e) {
      print(e.toString());
    }

  List<Transaction> transactionsFromBudget = await database
      .getAllTransactionsBelongingToSharedBudget(sharedBudget.budgetPk);
  List<Transaction> allTransactionsToUpdate = [];
  for (Transaction transactionFromBudget in transactionsFromBudget) {
    allTransactionsToUpdate.add(
      transactionFromBudget.copyWith(
        sharedKey: Value(null),
        sharedDateUpdated: Value(null),
        sharedStatus: Value(null),
      ),
    );
  }
  await database.updateBatchTransactionsOnly(allTransactionsToUpdate);
  await database.createOrUpdateBudget(
    sharedBudget.copyWith(
      sharedDateUpdated: Value(null),
      sharedKey: Value(null),
      sharedOwnerMember: Value(null),
      sharedMembers: Value(null),
      sharedAllMembersEver: Value(null),
      budgetTransactionFilters: Value(null),
      memberTransactionFilters: Value(null),
    ),
    updateSharedEntry: false,
  );
  return true;
}

Future<bool> leaveSharedBudget(Budget sharedBudget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    return false;
  }
  final currentEmail = FirebaseAuth.instance.currentUser!.email;
  if (currentEmail != null && currentEmail.trim().isNotEmpty) {
    final normalizedCurrentEmail = normalizeSharedBudgetEmail(currentEmail);
    await db.collection('budgets').doc(sharedBudget.sharedKey).update({
      "members": FieldValue.arrayRemove([
        normalizedCurrentEmail,
        currentEmail,
      ]),
      "dateUpdated": DateTime.now(),
    });
  }
  unawaited(_leaveCometChatSharedBudget(sharedBudget.sharedKey));
  await removedSharedFromBudget(sharedBudget, removeFromServer: false);
  return true;
}

Future<bool> inviteMemberToBudget(
  String sharedKey,
  String member,
  Budget budget,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    return false;
  }
  final normalizedMember = normalizeSharedBudgetEmail(member);
  if (normalizedMember.isEmpty) return false;

  final budgetFromDB = await database.getBudgetInstance(budget.budgetPk);
  if ((budgetFromDB.sharedMembers ?? [])
      .map(normalizeSharedBudgetEmail)
      .contains(normalizedMember)) {
    return false;
  }

  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return false;

  final inviteRef = db
      .collection(sharedBudgetInvitesCollection)
      .doc(_inviteDocumentId(sharedKey, normalizedMember));
  await inviteRef.set({
    "budgetId": sharedKey,
    "budgetName": budgetFromDB.name,
    "ownerUid": currentUser.uid,
    "ownerEmail": normalizeSharedBudgetEmail(currentUser.email ?? ""),
    "invitedEmail": normalizedMember,
    "status": "pending",
    "createdAt": DateTime.now(),
    "respondedAt": null,
  }, SetOptions(merge: true));

  await db.collection('budgets').doc(sharedKey).update({
    "pendingMembers": FieldValue.arrayUnion([normalizedMember]),
    "dateUpdated": DateTime.now(),
  });
  return true;
}

Future<bool> addMemberToBudget(
  String sharedKey,
  String member,
  Budget budget, {
  bool syncCometChat = true,
}) async {
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    return false;
  }
  member = normalizeSharedBudgetEmail(member);
  DocumentReference budgetCreatedOnCloud = db
      .collection('budgets')
      .doc(sharedKey);
  budgetCreatedOnCloud.update({
    "members": FieldValue.arrayUnion([member]),
    "pendingMembers": FieldValue.arrayRemove([member]),
    "dateUpdated": DateTime.now(),
  });
  Budget budgetFromDB = await database.getBudgetInstance(budget.budgetPk);
  Set<String> memberList = (budgetFromDB.sharedMembers ?? [])
      .map(normalizeSharedBudgetEmail)
      .toSet();
  memberList.add(member);
  Set<String> allMembersEver = (budgetFromDB.sharedAllMembersEver ?? [])
      .map(normalizeSharedBudgetEmail)
      .toSet();
  allMembersEver.add(member);
  final updatedBudget = budgetFromDB.copyWith(
    sharedMembers: Value(memberList.toList()),
    sharedAllMembersEver: Value(allMembersEver.toList()),
  );
  await database.createOrUpdateBudget(updatedBudget, updateSharedEntry: false);
  if (syncCometChat) {
    unawaited(
      _addCometChatSharedBudgetMember(
        sharedKey: sharedKey,
        member: member,
        budget: updatedBudget,
      ),
    );
  }
  return true;
}

Future<void> _ensureCometChatSharedBudget(Budget budget) async {
  try {
    await CashewCometChatService.instance.ensureSharedBudgetChat(budget);
  } catch (error) {
    debugPrint('CometChat shared budget setup skipped: $error');
  }
}

Future<void> _addCometChatSharedBudgetMember({
  required String sharedKey,
  required String member,
  required Budget budget,
}) async {
  try {
    await CashewCometChatService.instance.addMemberToSharedBudgetChat(
      sharedKey: sharedKey,
      memberEmail: member,
      budget: budget,
    );
  } catch (error) {
    debugPrint('CometChat shared budget member setup skipped: $error');
  }
}

Future<void> _removeCometChatSharedBudgetMember({
  required String sharedKey,
  required String member,
}) async {
  try {
    await CashewCometChatService.instance.removeMemberFromSharedBudgetChat(
      sharedKey: sharedKey,
      memberEmail: member,
    );
  } catch (error) {
    debugPrint('CometChat shared budget member removal skipped: $error');
  }
}

Future<void> _leaveCometChatSharedBudget(String? sharedKey) async {
  if (sharedKey == null || sharedKey.trim().isEmpty) return;
  try {
    await CashewCometChatService.instance.leaveSharedBudgetChat(sharedKey);
  } catch (error) {
    debugPrint('CometChat shared budget leave skipped: $error');
  }
}

Future<void> _deleteCometChatSharedBudget(String? sharedKey) async {
  if (sharedKey == null || sharedKey.trim().isEmpty) return;
  try {
    await CashewCometChatService.instance.deleteSharedBudgetChat(sharedKey);
  } catch (error) {
    debugPrint('CometChat shared budget delete skipped: $error');
  }
}

Future<bool> removeMemberFromBudget(
  String sharedKey,
  String member,
  Budget budget,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    return false;
  }
  member = normalizeSharedBudgetEmail(member);
  DocumentReference budgetCreatedOnCloud = db
      .collection('budgets')
      .doc(sharedKey);
  budgetCreatedOnCloud.update({
    "members": FieldValue.arrayRemove([member]),
    "dateUpdated": DateTime.now(),
  });
  Budget budgetFromDB = await database.getBudgetInstance(budget.budgetPk);
  List<String> memberList = (budgetFromDB.sharedMembers ?? [])
      .map(normalizeSharedBudgetEmail)
      .toList();
  memberList.remove(member);
  await database.createOrUpdateBudget(
    budgetFromDB.copyWith(sharedMembers: Value(memberList)),
    updateSharedEntry: false,
  );
  unawaited(
    _removeCometChatSharedBudgetMember(sharedKey: sharedKey, member: member),
  );
  return true;
}

Future<List<SharedBudgetInvite>?> getPendingSharedBudgetInvites() async {
  if (appStateSettings["sharedBudgets"] == false) return [];
  if (appStateSettings["hasSignedIn"] == false) return [];
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) return null;
  final currentEmail = FirebaseAuth.instance.currentUser?.email;
  if (currentEmail == null || currentEmail.trim().isEmpty) return [];

  try {
    final snapshot = await db
        .collection(sharedBudgetInvitesCollection)
        .where(
          "invitedEmail",
          isEqualTo: normalizeSharedBudgetEmail(currentEmail),
        )
        .where("status", isEqualTo: "pending")
        .get()
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException("Pending invites query timed out");
          },
        );
    debugPrint(
      "[SharedBudgets] pending invites returned ${snapshot.docs.length}",
    );
    final invites = snapshot.docs
        .map((snapshot) => SharedBudgetInvite.fromSnapshot(snapshot))
        .toList();
    invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return invites;
  } on FirebaseException catch (error) {
    debugPrint(
      "[SharedBudgets] pending invites failed: ${error.code} ${error.message}",
    );
    return [];
  } catch (error) {
    debugPrint("[SharedBudgets] pending invites failed: $error");
    return [];
  }
}

Future<int> getPendingSharedBudgetInvitesCount() async {
  final invites = await getPendingSharedBudgetInvites();
  return invites?.length ?? 0;
}

Future<List<SharedBudgetInvite>?> getInvitesForSharedBudget(
  String sharedKey,
) async {
  if (appStateSettings["hasSignedIn"] == false) return [];
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) return null;

  try {
    final snapshot = await db
        .collection(sharedBudgetInvitesCollection)
        .where("budgetId", isEqualTo: sharedKey)
        .where("status", isEqualTo: "pending")
        .get()
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw TimeoutException("Shared budget invite query timed out");
          },
        );
    debugPrint(
      "[SharedBudgets] pending invites for $sharedKey returned "
      "${snapshot.docs.length}",
    );
    final invites = snapshot.docs
        .map((snapshot) => SharedBudgetInvite.fromSnapshot(snapshot))
        .toList();
    invites.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return invites;
  } on FirebaseException catch (error) {
    debugPrint(
      "[SharedBudgets] pending invites for $sharedKey failed: "
      "${error.code} ${error.message}",
    );
    return [];
  } catch (error) {
    debugPrint("[SharedBudgets] pending invites for $sharedKey failed: $error");
    return [];
  }
}

Future<bool> cancelSharedBudgetInvite(SharedBudgetInvite invite) async {
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) return false;

  await db
      .collection(sharedBudgetInvitesCollection)
      .doc(invite.inviteId)
      .update({"status": "cancelled", "respondedAt": DateTime.now()});
  await db.collection('budgets').doc(invite.budgetId).update({
    "pendingMembers": FieldValue.arrayRemove([invite.invitedEmail]),
    "dateUpdated": DateTime.now(),
  });
  return true;
}

Future<bool> acceptSharedBudgetInvite(SharedBudgetInvite invite) async {
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) return false;

  final inviteRef = db
      .collection(sharedBudgetInvitesCollection)
      .doc(invite.inviteId);
  final budgetRef = db.collection('budgets').doc(invite.budgetId);

  await db.runTransaction((transaction) async {
    final inviteSnapshot = await transaction.get(inviteRef);
    final inviteData = inviteSnapshot.data() as Map<dynamic, dynamic>?;
    if (inviteData == null || inviteData["status"] != "pending") {
      throw StateError("Invite is no longer pending.");
    }
    transaction.update(inviteRef, {
      "status": "accepted",
      "respondedAt": DateTime.now(),
    });
    transaction.update(budgetRef, {
      "members": FieldValue.arrayUnion([invite.invitedEmail]),
      "pendingMembers": FieldValue.arrayRemove([invite.invitedEmail]),
      "dateUpdated": DateTime.now(),
    });
  });

  await getCloudBudgets();
  try {
    final budget = await database.getSharedBudget(invite.budgetId);
    unawaited(
      _addCometChatSharedBudgetMember(
        sharedKey: invite.budgetId,
        member: invite.invitedEmail,
        budget: budget,
      ),
    );
  } catch (error) {
    debugPrint('CometChat accept invite sync skipped: $error');
  }
  return true;
}

Future<bool> rejectSharedBudgetInvite(SharedBudgetInvite invite) async {
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) return false;

  await db
      .collection(sharedBudgetInvitesCollection)
      .doc(invite.inviteId)
      .update({"status": "rejected", "respondedAt": DateTime.now()});
  await db.collection('budgets').doc(invite.budgetId).update({
    "pendingMembers": FieldValue.arrayRemove([invite.invitedEmail]),
    "dateUpdated": DateTime.now(),
  });
  return true;
}

// the owner is always the first entry!
Future<dynamic> getMembersFromBudget(String sharedKey, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    return null;
  }
  DocumentReference budgetCreatedOnCloud = db
      .collection('budgets')
      .doc(sharedKey);
  DocumentSnapshot budgetSnapshot;
  try {
    budgetSnapshot = await budgetCreatedOnCloud.get().timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        throw TimeoutException("Shared budget members query timed out");
      },
    );
  } on FirebaseException catch (error) {
    debugPrint(
      "[SharedBudgets] members for $sharedKey failed: "
      "${error.code} ${error.message}",
    );
    return null;
  } catch (error) {
    debugPrint("[SharedBudgets] members for $sharedKey failed: $error");
    return null;
  }
  final budgetData = budgetSnapshot.data();
  if (budgetData == null) {
    debugPrint("[SharedBudgets] members for $sharedKey: budget not found");
    return [];
  }
  Map<dynamic, dynamic> budgetDecoded = budgetData as Map;
  print([
    budgetDecoded["ownerEmail"].toString(),
    ...List<String>.from(budgetDecoded["members"]),
  ]);
  List<String> memberList = [
    budgetDecoded["ownerEmail"].toString(),
    ...List<String>.from(budgetDecoded["members"]),
  ];
  final updatedBudget = budget.copyWith(sharedMembers: Value(memberList));
  await database.createOrUpdateBudget(updatedBudget, updateSharedEntry: false);
  if (updatedBudget.sharedOwnerMember == SharedOwnerMember.owner) {
    unawaited(_ensureCometChatSharedBudget(updatedBudget));
  }
  return memberList;
}

Future<bool> compareSharedToCurrentBudgets(
  List<DocumentSnapshot> budgetSnapshot,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  List<Budget> budgets = await database.getAllBudgets();
  for (Budget budget in budgets) {
    if (budget.sharedKey != null) {
      bool found = false;
      for (DocumentSnapshot budgetCloud in budgetSnapshot) {
        if (budgetCloud.id == budget.sharedKey) {
          print("Found a matching budget!");
          found = true;
          break;
        }
      }
      if (found == false) {
        openSnackbar(
          SnackbarMessage(
            icon: appStateSettings["outlinedIcons"]
                ? Icons.remove_circle_outline_outlined
                : Icons.remove_circle_outline_rounded,
            title: budget.name,
            description: "Is no longer shared with you",
          ),
        );
        print("You have lost permission to this budget: " + budget.name);
        removedSharedFromBudget(budget);
      }
    }
  }
  for (DocumentSnapshot budgetCloud in budgetSnapshot) {
    bool found = false;
    for (Budget budget in budgets) {
      if (budget.sharedKey != null && budgetCloud.id == budget.sharedKey) {
        found = true;
        break;
      }
    }
    if (found == false) {
      Map<dynamic, dynamic> budgetDecoded = budgetCloud.data() as Map;
      openSnackbar(
        SnackbarMessage(
          title: budgetCloud["name"] + " was shared with you",
          description: "From " + getMemberNickname(budgetDecoded["ownerEmail"]),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.share_outlined
              : Icons.share_rounded,
        ),
      );
    }
  }
  return true;
}

Timer? cloudTimeoutTimer;
Future<bool> getCloudBudgets() async {
  debugPrint("[SharedBudgets] getCloudBudgets requested");
  if (appStateSettings["hasSignedIn"] == false) return false;
  if (errorSigningInDuringCloud == true) return false;
  if (kIsWeb &&
      !entireAppLoaded &&
      appStateSettings["webForceLoginPopupOnLaunch"] != true)
    return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (cloudTimeoutTimer?.isActive == true) {
    // openSnackbar(SnackbarMessage(title: "Please wait..."));
    return false;
  } else {
    cloudTimeoutTimer = Timer(Duration(milliseconds: 5000), () {
      cloudTimeoutTimer!.cancel();
    });
  }
  if (db == null) {
    debugPrint("[SharedBudgets] Firestore unavailable; auth failed");
    return false;
  }

  final currentUser = FirebaseAuth.instance.currentUser;
  final currentEmail = currentUser?.email;
  final currentUid = currentUser?.uid;
  final normalizedCurrentEmail = currentEmail == null
      ? null
      : normalizeSharedBudgetEmail(currentEmail);
  debugPrint(
    "[SharedBudgets] Fetching for uid=$currentUid email=$currentEmail",
  );

  Future<QuerySnapshot?> runSharedBudgetQuery(String label, Query query) async {
    try {
      final snapshot = await query.get().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException("Shared budget query timed out: $label");
        },
      );
      debugPrint(
        "[SharedBudgets] $label returned ${snapshot.docs.length} budgets: "
        "${snapshot.docs.map((doc) => doc.id).join(', ')}",
      );
      return snapshot;
    } on FirebaseException catch (error) {
      debugPrint(
        "[SharedBudgets] $label failed: ${error.code} ${error.message}",
      );
      return null;
    } catch (error) {
      debugPrint("[SharedBudgets] $label failed: $error");
      return null;
    }
  }

  final snapshotBudgetMembersOf =
      normalizedCurrentEmail == null || normalizedCurrentEmail.trim().isEmpty
      ? null
      : await runSharedBudgetQuery(
          "members arrayContains email",
          db
              .collection('budgets')
              .where('members', arrayContains: normalizedCurrentEmail),
        );
  final snapshotBudgetMembersOfLower =
      currentEmail == null || currentEmail == normalizedCurrentEmail
      ? null
      : await runSharedBudgetQuery(
          "members arrayContains lower email",
          db
              .collection('budgets')
              .where(
                'members',
                arrayContains: normalizedCurrentEmail,
              ),
        );
  final snapshotOwnedByUid = currentUid == null || currentUid.trim().isEmpty
      ? null
      : await runSharedBudgetQuery(
          "owner uid",
          db.collection('budgets').where('owner', isEqualTo: currentUid),
        );
  final snapshotOwnedByEmail =
      normalizedCurrentEmail == null || normalizedCurrentEmail.trim().isEmpty
      ? null
      : await runSharedBudgetQuery(
          "owner email",
          db.collection('budgets').where(
                'ownerEmail',
                isEqualTo: normalizedCurrentEmail,
              ),
        );
  final snapshotOwnedByLowerEmail =
      currentEmail == null || currentEmail == normalizedCurrentEmail
      ? null
      : await runSharedBudgetQuery(
          "owner lower email",
          db
              .collection('budgets')
              .where(
                'ownerEmail',
                isEqualTo: normalizedCurrentEmail,
              ),
        );

  final Map<String, DocumentSnapshot> budgetsById = {
    for (final budget in [
      ...?snapshotBudgetMembersOf?.docs,
      ...?snapshotBudgetMembersOfLower?.docs,
      ...?snapshotOwnedByUid?.docs,
      ...?snapshotOwnedByEmail?.docs,
      ...?snapshotOwnedByLowerEmail?.docs,
    ])
      budget.id: budget,
  };
  final List<DocumentSnapshot> sharedBudgetDocs = budgetsById.values.toList();
  int amountSynced = sharedBudgetDocs.length;
  debugPrint("[SharedBudgets] Total unique budgets fetched: $amountSynced");
  if (amountSynced > 0 && appStateSettings["sharedBudgets"] == false) {
    await updateSettings(
      "sharedBudgets",
      true,
      updateGlobalState: true,
      pagesNeedingRefresh: [0, 1, 2, 3],
    );
  }
  await compareSharedToCurrentBudgets(sharedBudgetDocs);

  int totalTransactionsUpdated = 0;
  totalTransactionsUpdated =
      totalTransactionsUpdated +
      await downloadTransactionsFromBudgets(db, sharedBudgetDocs);
  if (amountSynced > 0 && totalTransactionsUpdated > 0)
    openSnackbar(
      SnackbarMessage(
        icon: appStateSettings["outlinedIcons"]
            ? Icons.cloud_sync_outlined
            : Icons.cloud_sync_rounded,
        title:
            "synced".tr() +
            " " +
            totalTransactionsUpdated.toString() +
            " " +
            pluralString(totalTransactionsUpdated == 1, "change"),
        description:
            "From " +
            amountSynced.toString() +
            " shared " +
            pluralString(amountSynced == 1, "budget"),
      ),
    );
  // else if (amountSynced > 0 && totalTransactionsUpdated == 0) {
  //   openSnackbar(SnackbarMessage(
  //     title: "No updates",
  //   ));
  // }
  return true;
}

Future<int> downloadTransactionsFromBudgets(
  FirebaseFirestore db,
  List<DocumentSnapshot> snapshots,
) async {
  if (appStateSettings["sharedBudgets"] == false) return 0;
  int totalUpdated = 0;
  for (DocumentSnapshot budget in snapshots) {
    Set<String> allMembersEver = {};
    Map<dynamic, dynamic> budgetDecoded = budget.data() as Map;
    await database.createOrUpdateFromSharedBudget(
      insert: true,
      Budget(
        budgetPk: "-1",
        name: budgetDecoded["name"],
        amount: budgetDecoded["amount"].toDouble(),
        colour: budgetDecoded["colour"],
        startDate: budgetDecoded["startDate"].toDate(),
        endDate: budgetDecoded["endDate"].toDate(),
        categoryFks: null,
        addedTransactionsOnly: true,
        periodLength: budgetDecoded["periodLength"],
        reoccurrence: mapRecurrence(budgetDecoded["reoccurrence"]),
        dateCreated: DateTime.now(),
        dateTimeModified: null,
        pinned: true,
        order: 0,
        walletFk: "0",
        sharedKey: budget.id,
        sharedOwnerMember:
            normalizeSharedBudgetEmail(
                  FirebaseAuth.instance.currentUser!.email ?? "",
                ) ==
                normalizeSharedBudgetEmail(
                  budgetDecoded["ownerEmail"]?.toString() ?? "",
                )
            ? SharedOwnerMember.owner
            : SharedOwnerMember.member,
        sharedMembers: [
          normalizeSharedBudgetEmail(
            budgetDecoded["ownerEmail"]?.toString() ?? "",
          ),
          ...List<String>.from(budgetDecoded["members"])
              .map(normalizeSharedBudgetEmail),
        ],
        budgetTransactionFilters: [],
        memberTransactionFilters: null,
        isAbsoluteSpendingLimit: false,
        income: false,
        archived: false,
      ),
    );

    // Get transactions from the server
    Budget sharedBudget = await database.getSharedBudget(budget.id);
    Query transactionsFromServer;
    if (sharedBudget.sharedDateUpdated == null) {
      print("Download all transactions");
      transactionsFromServer = db
          .collection('budgets')
          .doc(budget.id)
          .collection('transactions');
    } else {
      print(sharedBudget.sharedDateUpdated);
      transactionsFromServer = db
          .collection('budgets')
          .doc(budget.id)
          .collection('transactions')
          .where(
            FieldPath.fromString("dateUpdated"),
            isGreaterThan: sharedBudget.sharedDateUpdated,
          );
    }
    final QuerySnapshot snapshotTransactionsFromServer =
        await transactionsFromServer.get();
    totalUpdated = totalUpdated + snapshotTransactionsFromServer.docs.length;
    for (DocumentSnapshot transaction in snapshotTransactionsFromServer.docs) {
      Map<dynamic, dynamic> transactionDecoded = transaction.data() as Map;
      if (transaction["logType"] == "create" ||
          transaction["logType"] == "update") {
        TransactionCategory selectedCategory;
        try {
          selectedCategory = await database.getCategoryInstanceGivenName(
            transactionDecoded["categoryName"],
          );
        } catch (_) {
          int numberOfCategories =
              (await database.getTotalCountOfCategories())[0] ?? 0;
          await database.createOrUpdateCategory(
            insert: true,
            TransactionCategory(
              categoryPk: "-1",
              name: transactionDecoded["categoryName"],
              dateCreated: DateTime.now(),
              dateTimeModified: null,
              order: numberOfCategories,
              income: false,
              iconName: transactionDecoded["categoryIcon"],
              colour: transactionDecoded["categoryColour"],
              methodAdded: MethodAdded.shared,
            ),
          );
          selectedCategory = await database.getCategoryInstanceGivenName(
            transactionDecoded["categoryName"],
          );
        }

        await database.createOrUpdateFromSharedTransaction(
          insert: true,
          Transaction(
            transactionPk: "-1",
            name: transactionDecoded["name"],
            amount: transactionDecoded["amount"].toDouble(),
            note: transactionDecoded["note"],
            categoryFk: selectedCategory.categoryPk,
            walletFk: "0",
            dateCreated: transactionDecoded["dateTimeCreated"].toDate(),
            dateTimeModified: null,
            income: transactionDecoded["income"],
            paid: true,
            skipPaid: false,
            sharedKey: transaction.id,
            sharedOldKey: transaction.id,
            transactionOwnerEmail: transactionDecoded["ownerEmail"],
            transactionOriginalOwnerEmail:
                transactionDecoded["originalCreatorEmail"],
            methodAdded: MethodAdded.shared,
            sharedDateUpdated: DateTime.now(),
            sharedStatus: SharedStatus.shared,
            sharedReferenceBudgetPk: sharedBudget.budgetPk,
          ),
        );
        if (transactionDecoded["ownerEmail"] != null)
          allMembersEver.add(transactionDecoded["ownerEmail"]);
        if (transactionDecoded["name"] != null &&
            transactionDecoded["name"] != "")
          await addAssociatedTitles(
            transactionDecoded["name"],
            selectedCategory,
          );
      } else if (transaction["logType"] == "delete") {
        print("DELETING");
        try {
          await database.deleteFromSharedTransaction(
            transactionDecoded["deleteSharedKey"],
          );
        } catch (e) {
          print("This shared transaction already deleted" + e.toString());
        }
      }

      print(transaction.id);
      print(transaction.data().toString());
    }
    Budget budgetAlreadyStored = (await database.getSharedBudget(budget.id));
    allMembersEver.addAll((budgetAlreadyStored.sharedMembers ?? []).toSet());
    allMembersEver.addAll(
      (budgetAlreadyStored.sharedAllMembersEver ?? []).toSet(),
    );
    final updatedSharedBudget = sharedBudget.copyWith(
      sharedDateUpdated: Value(DateTime.now()),
      sharedAllMembersEver: Value(allMembersEver.toList()),
    );
    await database.createOrUpdateFromSharedBudget(updatedSharedBudget);
    if (updatedSharedBudget.sharedOwnerMember == SharedOwnerMember.owner) {
      unawaited(_ensureCometChatSharedBudget(updatedSharedBudget));
    }

    print("DOWNLOADED FROM THIS BUDGET " + budget.data().toString());
  }

  return totalUpdated;
}

Future<bool> sendTransactionSet(Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  print("SETTING UP TRANSACTION TO BE SET: " + transaction.toString());
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    Map<dynamic, dynamic> currentSendTransactionsToServerQueue =
        appStateSettings["sendTransactionsToServerQueue"];
    currentSendTransactionsToServerQueue[transaction.transactionPk
        .toString()] = {
      "action": "sendTransactionSet",
      "transactionPk": transaction.transactionPk.toString(),
      "budgetPk": budget.budgetPk.toString(),
    };
    print(currentSendTransactionsToServerQueue);
    updateSettings(
      "sendTransactionsToServerQueue",
      currentSendTransactionsToServerQueue,
      pagesNeedingRefresh: [],
      updateGlobalState: false,
    );
    return false;
  }
  await setOnServer(db, transaction, budget);
  return true;
}

// update the entry on the server
Future<bool> setOnServer(
  FirebaseFirestore db,
  Transaction transaction,
  Budget budget,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  TransactionCategory transactionCategory = await database.getCategoryInstance(
    transaction.categoryFk,
  );
  CollectionReference subCollectionRef = db
      .collection('budgets')
      .doc(budget.sharedKey)
      .collection("transactions");
  await subCollectionRef.doc(transaction.sharedKey).set({
    "logType": "update", // create, delete, update
    "name": transaction.name,
    "amount": transaction.amount,
    "note": transaction.note,
    "dateTimeCreated": transaction.dateCreated,
    "dateUpdated": DateTime.now(),
    "income": transaction.income,
    "ownerEmail": transaction.transactionOwnerEmail, //ownerEmail is the payer
    "categoryName": transactionCategory.name,
    "categoryIcon": transactionCategory.iconName, //emoji icons not supported
    "categoryColour": transactionCategory.colour,
  }, SetOptions(merge: true));
  transaction = transaction.copyWith(
    sharedStatus: Value(SharedStatus.shared),
    sharedDateUpdated: Value(DateTime.now()),
    sharedOldKey: Value(transaction.sharedKey),
  );
  print("Transaction updated on server: " + transaction.toString());
  await database.createOrUpdateTransaction(
    transaction,
    updateSharedEntry: false,
  );
  return true;
}

Future<bool> sendTransactionAdd(Transaction transaction, Budget budget) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    Map<dynamic, dynamic> currentSendTransactionsToServerQueue =
        appStateSettings["sendTransactionsToServerQueue"];
    currentSendTransactionsToServerQueue[transaction.transactionPk
        .toString()] = {
      "action": "sendTransactionAdd",
      "transactionPk": transaction.transactionPk.toString(),
      "budgetPk": budget.budgetPk.toString(),
    };
    updateSettings(
      "sendTransactionsToServerQueue",
      currentSendTransactionsToServerQueue,
      pagesNeedingRefresh: [],
      updateGlobalState: false,
    );
    print(currentSendTransactionsToServerQueue);
    return false;
  }
  await addOnServer(db, transaction, budget);
  return true;
}

Future<bool> addOnServer(
  FirebaseFirestore db,
  Transaction transaction,
  Budget budget,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  TransactionCategory transactionCategory = await database.getCategoryInstance(
    transaction.categoryFk,
  );
  CollectionReference subCollectionRef = db
      .collection('budgets')
      .doc(budget.sharedKey)
      .collection("transactions");
  DocumentReference addedDocument = await subCollectionRef.add({
    "logType": "create", // create, delete, update
    "name": transaction.name,
    "amount": transaction.amount,
    "note": transaction.note,
    "dateTimeCreated": transaction.dateCreated,
    "dateUpdated": DateTime.now(),
    "income": transaction.income,
    "ownerEmail": transaction.transactionOwnerEmail, //ownerEmail is the payer
    "originalCreatorEmail": FirebaseAuth.instance.currentUser!.email,
    "categoryName": transactionCategory.name,
    "categoryIcon": transactionCategory.iconName, //emoji icons not supported
    "categoryColour": transactionCategory.colour,
  });
  transaction = transaction.copyWith(
    sharedKey: Value(addedDocument.id),
    sharedOldKey: Value(addedDocument.id),
    transactionOwnerEmail: Value(transaction.transactionOwnerEmail),
    transactionOriginalOwnerEmail: Value(
      FirebaseAuth.instance.currentUser!.email,
    ),
    sharedStatus: Value(SharedStatus.shared),
    sharedDateUpdated: Value(DateTime.now()),
  );
  await database.createOrUpdateTransaction(
    transaction,
    updateSharedEntry: false,
  );
  return true;
}

Future<bool> sendTransactionDelete(
  Transaction transaction,
  Budget budget,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  FirebaseFirestore? db = await firebaseGetDBInstance();
  if (db == null) {
    Map<dynamic, dynamic> currentSendTransactionsToServerQueue =
        appStateSettings["sendTransactionsToServerQueue"];
    currentSendTransactionsToServerQueue[transaction.transactionPk
        .toString()] = {
      "action": "sendTransactionDelete",
      "transactionSharedKey": transaction.sharedKey.toString(),
      "budgetPk": budget.budgetPk.toString(),
    };
    print(currentSendTransactionsToServerQueue);
    updateSettings(
      "sendTransactionsToServerQueue",
      currentSendTransactionsToServerQueue,
      pagesNeedingRefresh: [],
      updateGlobalState: false,
    );
    return false;
  }
  await deleteOnServer(db, transaction.sharedKey, budget);
  return true;
}

Future<bool> deleteOnServer(
  FirebaseFirestore db,
  String? transactionSharedKey,
  Budget budget,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (transactionSharedKey != null && transactionSharedKey != "null") {
    CollectionReference subCollectionRef = db
        .collection('budgets')
        .doc(budget.sharedKey)
        .collection("transactions");
    subCollectionRef.add({
      "logType": "delete", // create, delete, update
      "deleteSharedKey": transactionSharedKey,
      "dateUpdated": DateTime.now(),
    });
    subCollectionRef.doc(transactionSharedKey).delete();
  }
  return true;
}

Future<bool> syncPendingQueueOnServer() async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  if (appStateSettings["hasSignedIn"] == false) return false;
  if (errorSigningInDuringCloud == true) return false;
  if (kIsWeb && !entireAppLoaded) return false;
  print("syncing pending queue");
  Map<dynamic, dynamic> currentSendTransactionsToServerQueue =
      appStateSettings["sendTransactionsToServerQueue"];
  for (String key in currentSendTransactionsToServerQueue.keys) {
    FirebaseFirestore? db = await firebaseGetDBInstance();
    if (db == null) {
      return false;
    }
    try {
      print("CURRENT:");
      print(currentSendTransactionsToServerQueue[key]);

      Budget budget;
      try {
        budget = await database.getBudgetInstance(
          currentSendTransactionsToServerQueue[key]["budgetPk"].toString(),
        );
      } catch (e) {
        print(e.toString());
        // budget was probably deleted, we don't need to sync anything...
        continue;
      }

      if (currentSendTransactionsToServerQueue[key]["action"] ==
          "sendTransactionDelete") {
        await deleteOnServer(
          db,
          currentSendTransactionsToServerQueue[key]["transactionSharedKey"],
          budget,
        );
      }

      Transaction transaction = await database.getTransactionFromPk(
        currentSendTransactionsToServerQueue[key]["transactionPk"].toString(),
      );
      print("UPLOADING THIS TRANSACTION");
      print(transaction);
      if (currentSendTransactionsToServerQueue[key]["action"] ==
          "sendTransactionSet") {
        await setOnServer(db, transaction, budget);
      } else if (currentSendTransactionsToServerQueue[key]["action"] ==
          "sendTransactionAdd") {
        await addOnServer(db, transaction, budget);
      }
    } catch (e) {
      print(e.toString());
      print("skipping syncing this transaction...");
    }
  }
  updateSettings(
    "sendTransactionsToServerQueue",
    {},
    pagesNeedingRefresh: [],
    updateGlobalState: false,
  );
  return true;
}

Future<bool> updateTransactionOnServerAfterChangingCategoryInformation(
  TransactionCategory category,
) async {
  if (appStateSettings["sharedBudgets"] == false) return false;
  loadingIndeterminateKey.currentState?.setVisibility(true);
  List<Transaction> sharedTransactionsInCategory = await database
      .getAllTransactionsSharedInCategory(category.categoryPk);

  List<Future> asyncCalls = [];
  for (Transaction transaction in sharedTransactionsInCategory) {
    // update all shared transactions one by one, need to update the server
    if (transaction.sharedReferenceBudgetPk != null) {
      Budget budget = await database.getBudgetInstance(
        transaction.sharedReferenceBudgetPk!,
      );
      asyncCalls.add(sendTransactionSet(transaction, budget));
    }
  }
  await Future.wait(asyncCalls);
  loadingIndeterminateKey.currentState?.setVisibility(false);
  return true;
}
