import 'package:budget/colors.dart';
import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/shareBudget.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/noResults.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class SharedBudgetRequestsPage extends StatefulWidget {
  const SharedBudgetRequestsPage({Key? key}) : super(key: key);

  @override
  State<SharedBudgetRequestsPage> createState() =>
      _SharedBudgetRequestsPageState();
}

class _SharedBudgetRequestsPageState extends State<SharedBudgetRequestsPage> {
  late Future<List<SharedBudgetInvite>?> _invitesFuture;

  @override
  void initState() {
    super.initState();
    _invitesFuture = getPendingSharedBudgetInvites();
  }

  void _refresh() {
    setState(() {
      _invitesFuture = getPendingSharedBudgetInvites();
    });
  }

  Future<void> _accept(SharedBudgetInvite invite) async {
    openLoadingPopup(context);
    final accepted = await acceptSharedBudgetInvite(invite);
    popRoute(context);
    if (accepted) {
      openSnackbar(
        SnackbarMessage(
          title: "Shared budget accepted",
          description: invite.budgetName,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.check_circle_outline_outlined
              : Icons.check_circle_rounded,
        ),
      );
      _refresh();
      return;
    }
    openSnackbar(
      SnackbarMessage(
        title: "Could not accept invite",
        description: "Please check your connection and try again.",
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_outlined
            : Icons.warning_rounded,
      ),
    );
  }

  Future<void> _reject(SharedBudgetInvite invite) async {
    final confirmed = await openPopup(
      context,
      title: "Reject invite?",
      description: "You will not be added to ${invite.budgetName}.",
      icon: appStateSettings["outlinedIcons"]
          ? Icons.close_outlined
          : Icons.close_rounded,
      onSubmitLabel: "Reject",
      onSubmit: () {
        popRoute(context, true);
      },
      onCancelLabel: "cancel".tr(),
      onCancel: () {
        popRoute(context, false);
      },
    );
    if (confirmed != true) return;

    openLoadingPopup(context);
    final rejected = await rejectSharedBudgetInvite(invite);
    popRoute(context);
    if (rejected) {
      openSnackbar(
        SnackbarMessage(
          title: "Shared budget rejected",
          description: invite.budgetName,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.close_outlined
              : Icons.close_rounded,
        ),
      );
      _refresh();
      return;
    }
    openSnackbar(
      SnackbarMessage(
        title: "Could not reject invite",
        description: "Please check your connection and try again.",
        icon: appStateSettings["outlinedIcons"]
            ? Icons.warning_outlined
            : Icons.warning_rounded,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: "Shared Requests",
      dragDownToDismiss: true,
      horizontalPaddingConstrained: true,
      actions: [
        IconButton(
          padding: EdgeInsetsDirectional.all(15),
          tooltip: "refresh".tr(),
          onPressed: _refresh,
          icon: Icon(
            appStateSettings["outlinedIcons"]
                ? Icons.refresh_outlined
                : Icons.refresh_rounded,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
      ],
      slivers: [
        FutureBuilder<List<SharedBudgetInvite>?>(
          future: _invitesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsetsDirectional.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }

            if (snapshot.hasError) {
              return SliverToBoxAdapter(
                child: NoResults(message: "Connection error"),
              );
            }

            final invites = snapshot.data;
            if (invites == null) {
              return SliverToBoxAdapter(
                child: NoResults(message: "Connection error"),
              );
            }
            if (invites.isEmpty) {
              return SliverToBoxAdapter(
                child: NoResults(message: "No shared budget requests"),
              );
            }

            return SliverPadding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 13,
                vertical: 7,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final invite = invites[index];
                  return _SharedBudgetRequestCard(
                    invite: invite,
                    onAccept: () => _accept(invite),
                    onReject: () => _reject(invite),
                  );
                }, childCount: invites.length),
              ),
            );
          },
        ),
        SliverToBoxAdapter(child: SizedBox(height: 50)),
      ],
    );
  }
}

class _SharedBudgetRequestCard extends StatelessWidget {
  const _SharedBudgetRequestCard({
    required this.invite,
    required this.onAccept,
    required this.onReject,
  });

  final SharedBudgetInvite invite;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 12),
      child: Tappable(
        onTap: () {},
        borderRadius: 15,
        color: getColor(context, "lightDarkAccent"),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFont(
                text: invite.budgetName,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                maxLines: 2,
              ),
              SizedBox(height: 6),
              TextFont(
                text: "From " + getMemberNickname(invite.ownerEmail),
                fontSize: 15,
                textColor: getColor(context, "textLight"),
              ),
              SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Button(
                      label: "Accept",
                      icon: appStateSettings["outlinedIcons"]
                          ? Icons.check_outlined
                          : Icons.check_rounded,
                      onTap: onAccept,
                      borderRadius: 14,
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Button(
                      label: "Reject",
                      icon: appStateSettings["outlinedIcons"]
                          ? Icons.close_outlined
                          : Icons.close_rounded,
                      onTap: onReject,
                      borderRadius: 14,
                      color: Theme.of(context).colorScheme.errorContainer,
                      textColor: Theme.of(context).colorScheme.onErrorContainer,
                      iconColor: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
