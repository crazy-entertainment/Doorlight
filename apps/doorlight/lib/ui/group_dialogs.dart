import 'package:flutter/material.dart';

import '../core/jami.dart';
import '../state/app_state.dart';
import '../state/group_topics.dart';
import '../theme.dart';
import 'friend_rail.dart';
import 'gravity.dart';
import 'sybl_ui.dart';

// The UI route and the account/visit have separate lifetimes: closing a dialog
// stops its callbacks, but an already-issued command may still reconcile the
// same authoritative account after its initiating dialog has gone away.
class _GroupDialogOwner {
  _GroupDialogOwner(this.state) : action = state.captureConversationAction();

  final AppState state;
  final ConversationAction action;
  bool _closed = false;

  bool get alive => !_closed && state.ownsConversationAction(action);

  bool isCurrent(BuildContext context) =>
      alive && context.mounted && ModalRoute.of(context)?.isCurrent == true;

  bool canManage(BuildContext context, String conversationId) =>
      isCurrent(context) &&
      state.groups[conversationId]?.canManageMembers == true;

  void close<T>(BuildContext context, [T? result]) {
    if (_closed ||
        !context.mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _closed = true;
    Navigator.of(context).pop<T>(result);
  }

  void retire() => _closed = true;
}

Future<bool> showCreateGroupDialog(
  BuildContext context, {
  required AppState state,
}) async {
  final owner = _GroupDialogOwner(state);
  final title = TextEditingController();
  final selected = <String>{};
  var busy = false;
  String? error;
  final created = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        title: Gravity(
          child: Text(
            'Create a group',
            style: context.syblColors.display.copyWith(fontSize: 20),
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Gravity(
                child: TextField(
                  key: const ValueKey('group-title-field'),
                  controller: title,
                  autofocus: SyblLayout.autofocusTextInput(context),
                  enabled: !busy,
                  maxLength: 128,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Group name',
                    hintText: 'The Crew',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Gravity(
                child: Text(
                  'INVITE FRIENDS',
                  style: TextStyle(
                    color: context.syblColors.faint,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: state.friends.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Gravity(
                          child: Text(
                            'Add a friend before creating a group.',
                            style: TextStyle(color: context.syblColors.muted),
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final friend in state.friends.values)
                              CheckboxListTile(
                                value: selected.contains(friend.peerId),
                                enabled: !busy && friend.confirmed,
                                onChanged: (value) => setState(() {
                                  if (value == true) {
                                    selected.add(friend.peerId);
                                  } else {
                                    selected.remove(friend.peerId);
                                  }
                                  error = null;
                                }),
                                title: Text(friendLabel(friend)),
                                subtitle: friend.confirmed
                                    ? null
                                    : const Text('Request not accepted yet'),
                                secondary: SyblAvatar(
                                  label: friendLabel(friend),
                                  imageBase64: friend.avatarBase64,
                                  size: 34,
                                  color: context.syblColors.sage,
                                ),
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                              ),
                          ],
                        ),
                      ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Gravity(
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: context.syblColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          Gravity(
            child: TextButton(
              onPressed: busy ? null : () => owner.close(dialogContext, false),
              child: const Text('Cancel'),
            ),
          ),
          Gravity(
            child: FilledButton(
              key: const ValueKey('confirm-create-group'),
              onPressed: busy
                  ? null
                  : () async {
                      if (busy || !owner.isCurrent(dialogContext)) return;
                      final name = title.text.trim();
                      if (name.isEmpty || selected.isEmpty) {
                        setState(() {
                          error = name.isEmpty
                              ? 'Give the group a name.'
                              : 'Choose at least one friend.';
                        });
                        return;
                      }
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      var ok = false;
                      try {
                        ok = await state.createGroup(
                          name,
                          selected,
                          action: owner.action,
                        );
                      } catch (_) {
                        // A rejected native request must release this dialog for retry.
                      }
                      if (!dialogContext.mounted ||
                          !owner.isCurrent(dialogContext)) {
                        return;
                      }
                      if (ok) {
                        owner.close(dialogContext, true);
                      } else {
                        setState(() {
                          busy = false;
                          error = 'The group could not be created.';
                        });
                      }
                    },
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create group'),
            ),
          ),
        ],
      ),
    ),
  );
  owner.retire();
  title.dispose();
  return created == true;
}

Future<void> showGroupSettingsDialog(
  BuildContext context, {
  required AppState state,
  required GroupState group,
}) async {
  final owner = _GroupDialogOwner(state);
  var layout = group.layout;
  var layoutChanged = false;
  var busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final live = state.groups[group.conversationId];
          if (!owner.alive || live == null) {
            return AlertDialog(
              title: Gravity(child: const Text('Group settings')),
              content: Gravity(
                child: const Text(
                  'This group is no longer available in this view.',
                ),
              ),
              actions: [
                Gravity(
                  child: TextButton(
                    onPressed: () => owner.close(dialogContext),
                    child: const Text('Close'),
                  ),
                ),
              ],
            );
          }
          Future<void> applyLayout(GroupLayout next) async {
            if (busy || !owner.canManage(dialogContext, group.conversationId)) {
              return;
            }
            if (GroupLayoutCodec.encode(next) ==
                GroupLayoutCodec.encode(layout)) {
              return;
            }
            setState(() {
              layout = next;
              layoutChanged = true;
              error = null;
            });
          }

          Future<void> addCollection() async {
            if (busy || !owner.canManage(dialogContext, group.conversationId)) {
              return;
            }
            final name = await _promptName(
              dialogContext,
              title: 'New collection',
              label: 'Collection name',
            );
            if (name != null) await applyLayout(layout.addCollection(name));
          }

          Future<void> renameCollection(GroupCollection collection) async {
            if (busy || !owner.canManage(dialogContext, group.conversationId)) {
              return;
            }
            final name = await _promptName(
              dialogContext,
              title: 'Rename collection',
              label: 'Collection name',
              initial: collection.name,
            );
            if (name != null) {
              await applyLayout(layout.renameCollection(collection.id, name));
            }
          }

          Future<void> addRoom(
            GroupRoomKind kind, {
            String? collectionId,
          }) async {
            if (busy || !owner.canManage(dialogContext, group.conversationId)) {
              return;
            }
            final name = await _promptName(
              dialogContext,
              title: kind == GroupRoomKind.text
                  ? 'New text topic'
                  : 'New voice room',
              label: kind == GroupRoomKind.text ? 'Topic name' : 'Room name',
            );
            if (name != null) {
              await applyLayout(
                layout.addRoom(name, kind, collectionId: collectionId),
              );
            }
          }

          Future<void> renameRoom(GroupRoom room) async {
            if (busy || !owner.canManage(dialogContext, group.conversationId)) {
              return;
            }
            final name = await _promptName(
              dialogContext,
              title: room.kind == GroupRoomKind.text
                  ? 'Rename topic'
                  : 'Rename voice room',
              label: 'Name',
              initial: room.name,
            );
            if (name != null) {
              await applyLayout(layout.renameRoom(room.id, name));
            }
          }

          final shortWindow = MediaQuery.sizeOf(context).height < 480;
          return Dialog(
            insetPadding: shortWindow
                ? const EdgeInsets.all(8)
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: shortWindow
                    ? MediaQuery.sizeOf(context).height - 16
                    : MediaQuery.sizeOf(context).height * .88,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: shortWindow
                        ? const EdgeInsets.fromLTRB(12, 6, 6, 6)
                        : const EdgeInsets.fromLTRB(20, 16, 12, 14),
                    child: Row(
                      children: [
                        GroupAvatar(
                          state: state,
                          group: live,
                          size: shortWindow ? 32 : 42,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Gravity(
                                      child: Text(
                                        live.displayTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.syblColors.display
                                            .copyWith(fontSize: 20),
                                      ),
                                    ),
                                  ),
                                  if (live.canManageMembers)
                                    Gravity(
                                      child: IconButton(
                                        key: const ValueKey(
                                          'edit-group-identity-button',
                                        ),
                                        tooltip: 'Rename group',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: busy
                                            ? null
                                            : () =>
                                                  owner.canManage(
                                                    dialogContext,
                                                    group.conversationId,
                                                  )
                                                  ? showRenameGroupDialog(
                                                      dialogContext,
                                                      state: state,
                                                      group: live,
                                                    )
                                                  : null,
                                        icon: const Icon(
                                          Icons.edit_rounded,
                                          size: 16,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Gravity(
                                child: Text(
                                  live.canManageMembers
                                      ? 'Group settings · You are an admin'
                                      : 'Group settings · Member',
                                  style: TextStyle(
                                    color: context.syblColors.faint,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Gravity(
                          child: IconButton(
                            tooltip: 'Close',
                            onPressed: busy
                                ? null
                                : () => owner.close(dialogContext),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: shortWindow
                          ? const EdgeInsets.all(12)
                          : const EdgeInsets.fromLTRB(20, 18, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _SectionHeading(label: 'Members'),
                          const SizedBox(height: 8),
                          _MemberManagementRow(
                            state: state,
                            group: live,
                            memberId: state.jamiId,
                            role: live.localRole,
                            self: true,
                            busy: busy,
                          ),
                          for (final memberId in live.memberIds)
                            _MemberManagementRow(
                              state: state,
                              group: live,
                              memberId: memberId,
                              role:
                                  live.memberRoles[memberId] ??
                                  JamiGroupMemberRole.unknown,
                              busy: busy,
                              onRemove: () async {
                                if (busy ||
                                    !owner.canManage(
                                      dialogContext,
                                      live.conversationId,
                                    )) {
                                  return;
                                }
                                final confirmed = await _confirmGroupAction(
                                  dialogContext,
                                  title: 'Remove this member?',
                                  message:
                                      'They will need a new invitation to return to this group.',
                                  actionLabel: 'Remove',
                                );
                                if (!dialogContext.mounted ||
                                    !confirmed ||
                                    busy ||
                                    !owner.canManage(
                                      dialogContext,
                                      live.conversationId,
                                    ) ||
                                    state.groups[live.conversationId]?.memberIds
                                            .contains(memberId) !=
                                        true) {
                                  return;
                                }
                                setState(() {
                                  busy = true;
                                  error = null;
                                });
                                var ok = false;
                                try {
                                  ok = await state.removeGroupMember(
                                    live.conversationId,
                                    memberId,
                                    action: owner.action,
                                  );
                                } catch (_) {
                                  // Keep the current dialog retryable on rejection.
                                }
                                if (!dialogContext.mounted ||
                                    !owner.isCurrent(dialogContext)) {
                                  return;
                                }
                                setState(() {
                                  busy = false;
                                  if (!ok) {
                                    error = 'That member could not be removed.';
                                  }
                                });
                              },
                            ),
                          if (live.canManageMembers) ...[
                            const SizedBox(height: 8),
                            Gravity(
                              child: OutlinedButton.icon(
                                key: const ValueKey('add-group-member-button'),
                                onPressed: busy
                                    ? null
                                    : () =>
                                          owner.canManage(
                                            dialogContext,
                                            group.conversationId,
                                          )
                                          ? showInviteGroupMembersDialog(
                                              dialogContext,
                                              state: state,
                                              group: live,
                                            )
                                          : null,
                                icon: const Icon(
                                  Icons.person_add_alt_1_rounded,
                                  size: 17,
                                ),
                                label: const Text('Add people'),
                              ),
                            ),
                          ],
                          const SizedBox(height: 22),
                          const _SectionHeading(
                            label: 'Collections & conversations',
                          ),
                          const SizedBox(height: 10),
                          _GroupLayoutEditor(
                            layout: layout,
                            enabled: live.canManageMembers && !busy,
                            onAddRoom: addRoom,
                            onRenameRoom: renameRoom,
                            onRenameCollection: renameCollection,
                            onRemoveCollection: (collection) => applyLayout(
                              layout.removeCollection(collection.id),
                            ),
                          ),
                          if (live.canManageMembers) ...[
                            const SizedBox(height: 1),
                            Gravity(
                              child: OutlinedButton.icon(
                                key: const ValueKey('add-group-collection'),
                                onPressed: busy ? null : addCollection,
                                icon: const Icon(
                                  Icons.create_new_folder_outlined,
                                  size: 18,
                                ),
                                label: const Text('New collection'),
                              ),
                            ),
                          ],
                          if (error != null) ...[
                            const SizedBox(height: 12),
                            Gravity(
                              child: Text(
                                error!,
                                style: TextStyle(
                                  color: context.syblColors.danger,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.spaceBetween,
                      overflowAlignment: OverflowBarAlignment.end,
                      overflowSpacing: 8,
                      children: [
                        Gravity(
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => _leaveGroup(
                                    dialogContext,
                                    state: state,
                                    group: live,
                                    owner: owner,
                                    setBusy: (value, message) => setState(() {
                                      busy = value;
                                      error = message;
                                    }),
                                  ),
                            style: TextButton.styleFrom(
                              foregroundColor: context.syblColors.danger,
                            ),
                            child: const Text('Leave group'),
                          ),
                        ),
                        if (live.canManageMembers && layoutChanged)
                          Gravity(
                            child: FilledButton(
                              key: const ValueKey('save-group-layout'),
                              onPressed: busy
                                  ? null
                                  : () async {
                                      if (busy ||
                                          !owner.canManage(
                                            dialogContext,
                                            live.conversationId,
                                          )) {
                                        return;
                                      }
                                      setState(() {
                                        busy = true;
                                        error = null;
                                      });
                                      var ok = false;
                                      try {
                                        ok = await state.updateGroupLayout(
                                          live.conversationId,
                                          layout,
                                          action: owner.action,
                                        );
                                      } catch (_) {
                                        // Keep this draft; a failed command is not a save.
                                      }
                                      if (!dialogContext.mounted ||
                                          !owner.isCurrent(dialogContext)) {
                                        return;
                                      }
                                      if (ok) {
                                        owner.close(dialogContext);
                                      } else {
                                        setState(() {
                                          busy = false;
                                          error =
                                              'The group layout could not be saved.';
                                        });
                                      }
                                    },
                              child: busy
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Save changes'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
  owner.retire();
}

Future<void> showRenameGroupDialog(
  BuildContext context, {
  required AppState state,
  required GroupState group,
}) async {
  if (state.groups[group.conversationId]?.canManageMembers != true) return;
  final owner = _GroupDialogOwner(state);
  var value = group.displayTitle;
  var busy = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> saveName() => _saveGroupName(
          dialogContext,
          state: state,
          group: group,
          value: value,
          owner: owner,
          isBusy: () => busy,
          setBusy: (value, message) => setState(() {
            busy = value;
            error = message;
          }),
        );
        return AlertDialog(
          title: Gravity(child: const Text('Rename group')),
          content: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Gravity(
              child: TextFormField(
                key: const ValueKey('rename-group-field'),
                initialValue: value,
                autofocus: SyblLayout.autofocusTextInput(context),
                enabled: !busy,
                maxLength: 128,
                textInputAction: TextInputAction.done,
                onChanged: (next) => value = next,
                onFieldSubmitted: (_) => saveName(),
                decoration: InputDecoration(
                  labelText: 'Group name',
                  errorText: error,
                ),
              ),
            ),
          ),
          actions: [
            Gravity(
              child: TextButton(
                onPressed: busy ? null : () => owner.close(dialogContext),
                child: const Text('Cancel'),
              ),
            ),
            Gravity(
              child: FilledButton(
                onPressed: busy ? null : saveName,
                child: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ),
          ],
        );
      },
    ),
  );
  owner.retire();
}

Future<void> _saveGroupName(
  BuildContext context, {
  required AppState state,
  required GroupState group,
  required String value,
  required _GroupDialogOwner owner,
  required bool Function() isBusy,
  required void Function(bool busy, String? error) setBusy,
}) async {
  if (isBusy() || !owner.canManage(context, group.conversationId)) return;
  value = value.trim();
  if (value.isEmpty) {
    setBusy(false, 'Give the group a name.');
    return;
  }
  if (value == group.displayTitle) {
    owner.close(context);
    return;
  }
  setBusy(true, null);
  var ok = false;
  try {
    ok = await state.renameGroup(
      group.conversationId,
      value,
      action: owner.action,
    );
  } catch (_) {
    // A rejected request does not leave the dialog permanently busy.
  }
  if (!context.mounted || !owner.isCurrent(context)) return;
  if (ok) {
    Navigator.of(context).pop();
  } else {
    setBusy(false, 'The group name could not be changed.');
  }
}

Future<void> showInviteGroupMembersDialog(
  BuildContext context, {
  required AppState state,
  required GroupState group,
}) async {
  final owner = _GroupDialogOwner(state);
  String? busyPeer;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final live = state.groups[group.conversationId];
          if (!owner.alive || live?.canManageMembers != true) {
            return AlertDialog(
              title: Gravity(child: const Text('Add people')),
              content: Gravity(
                child: const Text(
                  'This group is no longer available to manage in this view.',
                ),
              ),
              actions: [
                Gravity(
                  child: TextButton(
                    onPressed: () => owner.close(dialogContext),
                    child: const Text('Done'),
                  ),
                ),
              ],
            );
          }
          final available = state.friends.values
              .where(
                (friend) =>
                    friend.confirmed &&
                    !live!.memberIds.contains(friend.peerId),
              )
              .toList(growable: false);
          return AlertDialog(
            scrollable: true,
            title: Gravity(child: const Text('Add people')),
            content: SizedBox(
              width: 420,
              child: available.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Gravity(
                        child: Text(
                          'All of your friends are already here or invited.',
                          style: TextStyle(color: context.syblColors.muted),
                        ),
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final friend in available)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SyblAvatar(
                              label: friendLabel(friend),
                              imageBase64: friend.avatarBase64,
                              size: 38,
                              statusColor: friendPresenceColor(
                                context,
                                state,
                                friend,
                              ),
                              statusIcon: friendPresenceIcon(friend),
                              statusLabel: friendPresenceLabel(state, friend),
                            ),
                            title: Gravity(child: Text(friendLabel(friend))),
                            subtitle: Gravity(
                              child: Text(friendPresenceLabel(state, friend)),
                            ),
                            trailing: Gravity(
                              child: FilledButton.icon(
                                key: ValueKey(
                                  'invite-group-member-${friend.peerId}',
                                ),
                                onPressed: busyPeer == null
                                    ? () async {
                                        if (busyPeer != null ||
                                            !owner.canManage(
                                              dialogContext,
                                              group.conversationId,
                                            )) {
                                          return;
                                        }
                                        setState(() {
                                          busyPeer = friend.peerId;
                                          error = null;
                                        });
                                        var ok = false;
                                        try {
                                          ok = await state.addGroupMembers(
                                            group.conversationId,
                                            [friend.peerId],
                                            action: owner.action,
                                          );
                                        } catch (_) {
                                          // The user can retry a rejected invite in this same view.
                                        }
                                        if (!dialogContext.mounted ||
                                            !owner.isCurrent(dialogContext)) {
                                          return;
                                        }
                                        setState(() {
                                          busyPeer = null;
                                          if (!ok) {
                                            error =
                                                '${friendLabel(friend)} could not be invited.';
                                          }
                                        });
                                      }
                                    : null,
                                icon: busyPeer == friend.peerId
                                    ? const SizedBox.square(
                                        dimension: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.person_add_alt_1_rounded,
                                        size: 17,
                                      ),
                                label: const Text('Invite'),
                              ),
                            ),
                          ),
                        if (error != null)
                          Gravity(
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: context.syblColors.danger,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              Gravity(
                child: TextButton(
                  onPressed: busyPeer == null
                      ? () => owner.close(dialogContext)
                      : null,
                  child: const Text('Done'),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  owner.retire();
}

class _MemberManagementRow extends StatelessWidget {
  const _MemberManagementRow({
    required this.state,
    required this.group,
    required this.memberId,
    required this.role,
    required this.busy,
    this.self = false,
    this.onRemove,
  });

  final AppState state;
  final GroupState group;
  final String memberId;
  final JamiGroupMemberRole role;
  final bool busy;
  final bool self;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final friend = state.friends[memberId];
    final label = self
        ? (state.displayName.trim().isEmpty ? 'You' : state.displayName)
        : friend == null
        ? 'Group member'
        : friendLabel(friend);
    final roleLabel = switch (role) {
      JamiGroupMemberRole.admin => 'Admin',
      JamiGroupMemberRole.member => 'Member',
      JamiGroupMemberRole.invited => 'Invitation pending',
      JamiGroupMemberRole.unknown => 'Member',
    };
    return Container(
      key: const ValueKey('group-member-card'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.syblColors.surfaceHi.withValues(alpha: .52),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SyblAvatar(
            label: label,
            imageBase64: self
                ? state.profileAvatarBase64
                : friend?.avatarBase64 ?? '',
            size: 34,
            color: context.syblColors.sage,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Gravity(
                  child: Text(
                    self && label != 'You' ? '$label · You' : label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 4),
                Gravity(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.syblColors.bg.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      roleLabel,
                      style: TextStyle(
                        color: context.syblColors.muted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (group.canManageMembers && !self && onRemove != null) ...[
            const SizedBox(width: 4),
            Gravity(
              child: IconButton(
                tooltip: 'Remove member',
                onPressed: busy ? null : onRemove,
                icon: const Icon(Icons.person_remove_outlined, size: 19),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Gravity(
    child: Text(
      label.toUpperCase(),
      style: TextStyle(
        color: context.syblColors.faint,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    ),
  );
}

class _GroupLayoutEditor extends StatelessWidget {
  const _GroupLayoutEditor({
    required this.layout,
    required this.enabled,
    required this.onAddRoom,
    required this.onRenameRoom,
    required this.onRenameCollection,
    required this.onRemoveCollection,
  });

  final GroupLayout layout;
  final bool enabled;
  final Future<void> Function(GroupRoomKind kind, {String? collectionId})
  onAddRoom;
  final Future<void> Function(GroupRoom room) onRenameRoom;
  final Future<void> Function(GroupCollection collection) onRenameCollection;
  final Future<void> Function(GroupCollection collection) onRemoveCollection;

  @override
  Widget build(BuildContext context) {
    final outside = layout.rooms
        .where((room) => room.collectionId == null)
        .toList(growable: false);
    return Column(
      children: [
        _CollectionCard(
          title: 'Outside collections',
          rooms: outside,
          enabled: enabled,
          onAddRoom: (kind) => onAddRoom(kind),
          onRenameRoom: onRenameRoom,
        ),
        for (final collection in layout.collections)
          _CollectionCard(
            title: collection.name,
            rooms: layout.rooms
                .where((room) => room.collectionId == collection.id)
                .toList(growable: false),
            enabled: enabled,
            onTitlePressed: () => onRenameCollection(collection),
            onRemove: () => onRemoveCollection(collection),
            onAddRoom: (kind) => onAddRoom(kind, collectionId: collection.id),
            onRenameRoom: onRenameRoom,
          ),
      ],
    );
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.title,
    required this.rooms,
    required this.enabled,
    required this.onAddRoom,
    required this.onRenameRoom,
    this.onTitlePressed,
    this.onRemove,
  });

  final String title;
  final List<GroupRoom> rooms;
  final bool enabled;
  final Future<void> Function(GroupRoomKind kind) onAddRoom;
  final Future<void> Function(GroupRoom room) onRenameRoom;
  final VoidCallback? onTitlePressed;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 9),
    elevation: 0,
    color: context.syblColors.surfaceHi,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 9),
      child: Column(
        children: [
          OverflowBar(
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.start,
            overflowSpacing: 4,
            children: [
              Gravity(
                child: InkWell(
                  onTap: enabled ? onTitlePressed : null,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Text(
                      title,
                      style: TextStyle(
                        color: context.syblColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              if (enabled)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Gravity(
                      child: PopupMenuButton<GroupRoomKind>(
                        key: ValueKey('add-conversation-$title'),
                        tooltip: 'Add conversation',
                        onSelected: onAddRoom,
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: GroupRoomKind.text,
                            child: ListTile(
                              leading: Icon(Icons.tag_rounded),
                              title: Text('Text topic'),
                            ),
                          ),
                          PopupMenuItem(
                            value: GroupRoomKind.voice,
                            child: ListTile(
                              leading: Icon(Icons.volume_up_rounded),
                              title: Text('Voice room'),
                            ),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.add_rounded, size: 18),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  'Add conversation',
                                  style: TextStyle(
                                    color: context.syblColors.amber,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (onRemove != null)
                      Gravity(
                        child: IconButton(
                          tooltip: 'Remove collection',
                          onPressed: onRemove,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 19,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          if (rooms.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Gravity(
                child: Text(
                  'No conversations',
                  style: TextStyle(
                    color: context.syblColors.faint,
                    fontSize: 12,
                  ),
                ),
              ),
            )
          else
            for (final room in rooms)
              Gravity(
                child: ListTile(
                  key: ValueKey('group-layout-room-${room.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    room.kind == GroupRoomKind.voice
                        ? Icons.volume_up_rounded
                        : Icons.tag_rounded,
                    size: 18,
                    color: context.syblColors.faint,
                  ),
                  title: Text(room.name),
                  trailing: enabled
                      ? const Icon(Icons.edit_outlined, size: 17)
                      : null,
                  onTap: enabled ? () => onRenameRoom(room) : null,
                ),
              ),
        ],
      ),
    ),
  );
}

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) async {
  var entered = initial;
  var finished = false;
  void finish(BuildContext dialogContext, String? result) {
    if (finished ||
        !dialogContext.mounted ||
        ModalRoute.of(dialogContext)?.isCurrent != true) {
      return;
    }
    finished = true;
    Navigator.of(dialogContext).pop(result);
  }

  final value = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Gravity(child: Text(title)),
      content: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Gravity(
          child: TextFormField(
            initialValue: initial,
            autofocus: SyblLayout.autofocusTextInput(context),
            maxLength: 64,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: label),
            onChanged: (value) => entered = value,
            onFieldSubmitted: (value) {
              final normalized = GroupLayoutCodec.normalizeName(value);
              if (normalized != null) {
                finish(dialogContext, normalized);
              }
            },
          ),
        ),
      ),
      actions: [
        Gravity(
          child: TextButton(
            onPressed: () => finish(dialogContext, null),
            child: const Text('Cancel'),
          ),
        ),
        Gravity(
          child: FilledButton(
            onPressed: () {
              final normalized = GroupLayoutCodec.normalizeName(entered);
              if (normalized != null) {
                finish(dialogContext, normalized);
              }
            },
            child: const Text('Save'),
          ),
        ),
      ],
    ),
  );
  return value;
}

Future<bool> _confirmGroupAction(
  BuildContext context, {
  required String title,
  required String message,
  required String actionLabel,
}) async {
  var finished = false;
  void finish(BuildContext dialogContext, bool confirmed) {
    if (finished ||
        !dialogContext.mounted ||
        ModalRoute.of(dialogContext)?.isCurrent != true) {
      return;
    }
    finished = true;
    Navigator.of(dialogContext).pop(confirmed);
  }

  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Gravity(child: Text(title)),
          content: Gravity(child: Text(message)),
          actions: [
            Gravity(
              child: TextButton(
                onPressed: () => finish(dialogContext, false),
                child: const Text('Cancel'),
              ),
            ),
            Gravity(
              child: FilledButton(
                onPressed: () => finish(dialogContext, true),
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      ) ==
      true;
}

Future<void> _leaveGroup(
  BuildContext context, {
  required AppState state,
  required GroupState group,
  required _GroupDialogOwner owner,
  required void Function(bool busy, String? error) setBusy,
}) async {
  if (!context.mounted || !owner.isCurrent(context)) return;
  final leave = await _confirmGroupAction(
    context,
    title: 'Leave this group?',
    message:
        'The group disappears from this device. You need a new invitation to return.',
    actionLabel: 'Leave',
  );
  if (!context.mounted ||
      !leave ||
      !owner.isCurrent(context) ||
      !state.groups.containsKey(group.conversationId)) {
    return;
  }
  setBusy(true, null);
  var ok = false;
  try {
    ok = await state.leaveGroup(group.conversationId, action: owner.action);
  } catch (_) {
    // Keep the original draft and let this current view retry a rejection.
  }
  if (!context.mounted || !owner.isCurrent(context)) return;
  if (ok) {
    owner.close(context);
  } else {
    setBusy(false, 'Could not leave the group. Try again.');
  }
}
