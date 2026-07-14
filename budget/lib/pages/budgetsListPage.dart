import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addBudgetPage.dart';
import 'package:budget/pages/editBudgetPage.dart';
import 'package:budget/pages/sharedBudgetRequestsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/shareBudget.dart';
import 'package:budget/widgets/budgetContainer.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart'
    hide SliverReorderableList, ReorderableDelayedDragStartListener;
import 'addButton.dart';

class BudgetsListPage extends StatefulWidget {
  const BudgetsListPage({required this.enableBackButton, Key? key})
    : super(key: key);
  final bool enableBackButton;

  @override
  State<BudgetsListPage> createState() => BudgetsListPageState();
}

class BudgetsListPageState extends State<BudgetsListPage> {
  GlobalKey<PageFrameworkState> pageState = GlobalKey();

  void refreshState() {
    setState(() {});
  }

  void scrollToTop() {
    pageState.currentState?.scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      key: pageState,
      title: "budgets".tr(),
      backButton: widget.enableBackButton,
      dragDownToDismiss: widget.enableBackButton,
      horizontalPaddingConstrained: enableDoubleColumn(context) == false,
      actions: [
        if (appStateSettings["sharedBudgets"] == true)
          FutureBuilder<int>(
            future: getPendingSharedBudgetInvitesCount(),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              return Stack(
                alignment: AlignmentDirectional.topEnd,
                children: [
                  IconButton(
                    padding: EdgeInsetsDirectional.all(15),
                    tooltip: "Shared Requests",
                    onPressed: () {
                      pushRoute(context, SharedBudgetRequestsPage());
                    },
                    icon: Icon(
                      appStateSettings["outlinedIcons"]
                          ? Icons.group_add_outlined
                          : Icons.group_add_rounded,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                  if (count > 0)
                    PositionedDirectional(
                      end: 8,
                      top: 8,
                      child: Container(
                        padding: EdgeInsetsDirectional.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          borderRadius: BorderRadiusDirectional.circular(10),
                        ),
                        child: Text(
                          count > 9 ? "9+" : count.toString(),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onError,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        IconButton(
          padding: EdgeInsetsDirectional.all(15),
          tooltip: "edit-budgets".tr(),
          onPressed: () {
            pushRoute(context, EditBudgetPage());
          },
          icon: Icon(
            appStateSettings["outlinedIcons"]
                ? Icons.edit_outlined
                : Icons.edit_rounded,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
        if (getIsFullScreen(context))
          IconButton(
            padding: EdgeInsetsDirectional.all(15),
            tooltip: "add-budget".tr(),
            onPressed: () {
              pushRoute(
                context,
                AddBudgetPage(
                  routesToPopAfterDelete: RoutesToPopAfterDelete.None,
                ),
              );
            },
            icon: Icon(
              appStateSettings["outlinedIcons"]
                  ? Icons.add_outlined
                  : Icons.add_rounded,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
      ],
      slivers: [
        StreamBuilder<List<Budget>>(
          stream: database.watchAllBudgets(hideArchived: true),
          builder: (context, snapshot) {
            if (snapshot.hasData && (snapshot.data ?? []).length <= 0) {
              return SliverPadding(
                padding: EdgeInsetsDirectional.symmetric(
                  vertical: 7,
                  horizontal: 13,
                ),
                sliver: SliverToBoxAdapter(
                  child: AddButton(
                    onTap: () {},
                    openPage: AddBudgetPage(
                      routesToPopAfterDelete:
                          RoutesToPopAfterDelete.PreventDelete,
                    ),
                    height: 180,
                  ),
                ),
              );
            }
            if (snapshot.hasData) {
              return SliverPadding(
                padding: EdgeInsetsDirectional.symmetric(
                  vertical: 7,
                  horizontal: 13,
                ),
                sliver: enableDoubleColumn(context)
                    ? SliverGrid(
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 600.0,
                          mainAxisExtent: 190,
                          mainAxisSpacing: 15.0,
                          crossAxisSpacing: 15.0,
                          childAspectRatio: 5,
                        ),
                        delegate: SliverChildBuilderDelegate((
                          BuildContext context,
                          int index,
                        ) {
                          if (index == snapshot.data?.length) {
                            return AddButton(
                              onTap: () {},
                              openPage: AddBudgetPage(
                                routesToPopAfterDelete:
                                    RoutesToPopAfterDelete.PreventDelete,
                              ),
                            );
                          } else {
                            return BudgetContainer(
                              budget: snapshot.data![index],
                            );
                          }
                        }, childCount: (snapshot.data?.length ?? 0) + 1),
                      )
                    : SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (BuildContext context, int index) {
                            if (index == snapshot.data?.length) {
                              return AddButton(
                                onTap: () {},
                                openPage: AddBudgetPage(
                                  routesToPopAfterDelete:
                                      RoutesToPopAfterDelete.PreventDelete,
                                ),
                                height: 180,
                              );
                            } else {
                              return Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  bottom: 16.0,
                                ),
                                child: BudgetContainer(
                                  budget: snapshot.data![index],
                                  squishInactiveBudgetContainerHeight: true,
                                ),
                              );
                            }
                          },
                          childCount:
                              (snapshot.data?.length ?? 0) +
                              1, //snapshot.data?.length
                        ),
                      ),
              );
            } else {
              return SliverToBoxAdapter();
            }
          },
        ),
        SliverToBoxAdapter(child: SizedBox(height: 50)),
      ],
    );
  }
}
