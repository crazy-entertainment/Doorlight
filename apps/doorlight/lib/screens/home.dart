import '../ui/notification_bell.dart';
import '../ui/capture_sensitive_scope.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../state/app_lock.dart';
import '../theme.dart';
import '../ui/onboarding_surface.dart';
import '../ui/account_share.dart';
import '../ui/add_friend_pane.dart';
import '../ui/chat_stage.dart';
import '../ui/friend_rail.dart';
import '../ui/group_call_dock.dart';
import '../ui/group_dialogs.dart';
import '../ui/gravity.dart';
import '../ui/group_stage.dart';
import '../ui/history_search_dialog.dart';
import '../ui/settings_pane.dart';
import '../ui/google_wake_choice.dart';
import '../ui/sybl_ui.dart';
import '../ui/window_presentation.dart';
import '../ui/windows_chrome.dart';
import '../ui/windows_pane_layout.dart';
import '../ui/pane_reveal_switcher.dart';
import 'debug.dart';
import 'group_call.dart';
import 'in_call.dart';
import 'incoming.dart';

enum _CompactPane { people, conversation, call, settings, addFriend }

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _SearchHistoryIntent extends Intent {
  const _SearchHistoryIntent();
}

class _GoBackIntent extends Intent {
  const _GoBackIntent();
}

class HomeScreen extends StatefulWidget {
  final AppState state;
  final AppLockController? appLockController;

  const HomeScreen({super.key, required this.state, this.appLockController});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _railProfileStart = GlobalKey();
  final _railProfileEnd = GlobalKey();
  _CompactPane _compactPane = _CompactPane.people;
  _CompactPane _compactPaneBeforeSettings = _CompactPane.people;
  _CompactPane _compactPaneBeforeAddFriend = _CompactPane.people;
  bool _desktopSettingsOpen = false;
  bool _desktopCallOpen = false;
  bool _addingFriend = false;
  // The notification bell asks for Sonar: the next add-friend pane opens it
  // once, and each request remounts the pane.
  int _sonarRequest = 0;
  bool _sonarPending = false;
  String? _visibleGroupTopicId;
  String? _reportedVisiblePeerId;
  String? _reportedVisibleGroupTopicId;
  String? _reportedVisibleDmTopicId;
  String? _presentedCallId;
  bool _microphoneReviewPresented = false;
  bool _historySearchOpen = false;
  bool _windowWasCompact = false;
  int _windowLayoutRevision = 0;
  final _chatHeaderLinks = <String, LayerLink>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = WindowPresentationScope.maybeOf(context);
    final compact =
        window?.compact == true ||
        (window != null &&
            !window.animating &&
            MediaQuery.sizeOf(context).width < SyblLayout.desktopBreakpoint);
    if (compact && !_windowWasCompact) {
      _compactPane = _desktopSettingsOpen
          ? _CompactPane.settings
          : _desktopCallOpen
          ? _CompactPane.call
          : _addingFriend
          ? _CompactPane.addFriend
          : widget.state.selectedFriend != null ||
                widget.state.selectedGroup != null
          ? _CompactPane.conversation
          : _CompactPane.people;
    }
    _windowWasCompact = compact;
  }

  ({String conversationId, String topicId, Object token})? _historyGroupTarget;

  @override
  void initState() {
    super.initState();
    sonarOpenRequests.addListener(_openSonar);
    _presentNewCall();
    _presentRestoreSettings();
    // Android asks for microphone and notification access once a profile
    // exists, not over the first onboarding screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || Theme.of(context).platform != TargetPlatform.android) {
        return;
      }
      unawaited(_prepareAndroidAlerts());
    });
  }

  Future<void> _prepareAndroidAlerts() async {
    final state = widget.state;
    await state.jami.requestRuntimePermissions().catchError((_) {});
    if (!mounted ||
        !identical(widget.state, state) ||
        state.googleWakeChoiceMade ||
        !state.backgroundWakeAvailable ||
        state.connectionProfile != 'jami' ||
        !state.canManageFriendPreferences ||
        !state.settingsControlsEnabled ||
        state.call != null ||
        state.groupCall != null) {
      return;
    }
    await showGoogleWakeChoice(context, state);
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _presentNewCall();
    _presentRestoreSettings();
  }

  void _presentRestoreSettings() {
    final notice = widget.state.takeRestoreSettingsNotice();
    final microphone = widget.state.appSettings.microphoneReviewRequired;
    if (!notice && (!microphone || _microphoneReviewPresented)) return;
    _microphoneReviewPresented = microphone;
    _desktopSettingsOpen = true;
    _desktopCallOpen = false;
    _compactPane = _CompactPane.settings;
  }

  void _presentNewCall() {
    final callId =
        widget.state.call?.callId ?? widget.state.groupCall?.conferenceId;
    if (callId == null) {
      if (_compactPane == _CompactPane.call) {
        _compactPane = _CompactPane.people;
      }
      _desktopCallOpen = false;
      _presentedCallId = null;
      return;
    }
    if (_presentedCallId == callId) return;
    _presentedCallId = callId;
  }

  void _reportVisibleConversation(
    String? peerId, {
    String? groupTopicId,
    String? dmTopicId,
  }) {
    if (_reportedVisiblePeerId == peerId &&
        _reportedVisibleGroupTopicId == groupTopicId &&
        _reportedVisibleDmTopicId == dmTopicId &&
        widget.state.visibleConversationPeerId == peerId &&
        widget.state.visibleGroupTopicId == groupTopicId &&
        widget.state.visibleDmTopicId == dmTopicId) {
      return;
    }
    _reportedVisiblePeerId = peerId;
    _reportedVisibleGroupTopicId = groupTopicId;
    _reportedVisibleDmTopicId = dmTopicId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _reportedVisiblePeerId != peerId ||
          _reportedVisibleGroupTopicId != groupTopicId ||
          _reportedVisibleDmTopicId != dmTopicId) {
        return;
      }
      widget.state.setConversationVisible(
        peerId,
        groupTopicId: groupTopicId,
        dmTopicId: dmTopicId,
      );
    });
  }

  void _leaveCallSurface() {
    if (_desktopCallOpen || _compactPane == _CompactPane.call) {
      unawaited(widget.state.stopRemoteControl());
    }
  }

  Future<void> _openHistorySearch() async {
    final state = widget.state;
    if (_historySearchOpen ||
        state.historySearchOwner == null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() => _historySearchOpen = true);
    final action = state.captureConversationAction(
      isCurrent: () =>
          mounted && identical(widget.state, state) && _historySearchOpen,
    );
    try {
      final hit = await showHistorySearchDialog(context, state: state);
      if (hit == null || !state.ownsConversationAction(action)) return;
      // Retire before the navigation lifetime is captured. Dialog disposal
      // follows its closing animation and must not invalidate an in-flight
      // conversation selection by retiring the same search a second time.
      state.retireHistorySearch();
      await state.openHistorySearchConversation(
        hit,
        action: action,
        onConversationOpened: () {
          if (!state.ownsConversationAction(action)) return;
          _leaveCallSurface();
          setState(() {
            _addingFriend = false;
            _desktopSettingsOpen = false;
            _desktopCallOpen = false;
            _compactPane = _CompactPane.conversation;
            _historyGroupTarget = hit.scope.isGroup
                ? (
                    conversationId: hit.scope.conversationId,
                    topicId: hit.channelId,
                    token: Object(),
                  )
                : null;
          });
        },
      );
    } finally {
      if (mounted) setState(() => _historySearchOpen = false);
    }
  }

  Future<void> _openFriend(FriendState friend) async {
    _leaveCallSurface();
    await widget.state.selectFriend(friend.peerId);
    if (!mounted) return;
    setState(() {
      _addingFriend = false;
      _desktopSettingsOpen = false;
      _desktopCallOpen = false;
      _visibleGroupTopicId = null;
      _compactPane = _CompactPane.conversation;
    });
  }

  Future<void> _openGroup(GroupState group) async {
    _historyGroupTarget = null;
    _leaveCallSurface();
    await widget.state.selectGroup(group.conversationId);
    if (!mounted) return;
    setState(() {
      _addingFriend = false;
      _desktopSettingsOpen = false;
      _desktopCallOpen = false;
      _visibleGroupTopicId = null;
      _compactPane = _CompactPane.conversation;
    });
  }

  Future<void> _openPeopleHome() async {
    _leaveCallSurface();
    final first = widget.state.friends.values.firstOrNull;
    if (first != null) await widget.state.selectFriend(first.peerId);
    if (!mounted) return;
    setState(() {
      _addingFriend = false;
      _desktopSettingsOpen = false;
      _desktopCallOpen = false;
      _compactPane = _CompactPane.people;
    });
  }

  void _openSonar() {
    if (mounted) unawaited(_addFriend(sonar: true));
  }

  Future<void> _addFriend({bool sonar = false}) async {
    _leaveCallSurface();
    setState(() {
      if (!_addingFriend) _compactPaneBeforeAddFriend = _pane;
      if (sonar) _sonarRequest++;
      _sonarPending = sonar;
      _addingFriend = true;
      _desktopSettingsOpen = false;
      _desktopCallOpen = false;
      _compactPane = _CompactPane.addFriend;
    });
  }

  void _closeAddFriend() => setState(() {
    _addingFriend = false;
    _sonarPending = false;
    _compactPane = _compactPaneBeforeAddFriend;
  });

  Widget _addFriendPane({bool underTitleBar = false}) => AddFriendPane(
    // A new bell request remounts the pane so it opens Sonar again.
    key: ValueKey((
      'add-friend-pane',
      widget.state.linkedDeviceOwner,
      _sonarRequest,
    )),
    state: widget.state,
    openSonar: _sonarPending,
    onClose: _closeAddFriend,
    isCurrent: () =>
        _addingFriend && !_desktopSettingsOpen && !_desktopCallOpen,
    titleBarHeight: underTitleBar ? WindowsChrome.height : 0,
  );

  Future<void> _createGroup() async {
    final created = await showCreateGroupDialog(context, state: widget.state);
    if (!created || !mounted) return;
    setState(() {
      _addingFriend = false;
      _desktopSettingsOpen = false;
      _desktopCallOpen = false;
      _visibleGroupTopicId = null;
      _compactPane = widget.state.selectedGroup != null
          ? _CompactPane.conversation
          : _CompactPane.people;
    });
  }

  Future<void> _inviteFriend() => showAccountShareDialog(
    context,
    jamiId: widget.state.jamiId,
    displayName: widget.state.displayName,
  );

  void _openSettings() {
    _leaveCallSurface();
    setState(() {
      if (_compactPane != _CompactPane.settings) {
        _compactPaneBeforeSettings = _compactPane;
      }
      _desktopSettingsOpen = true;
      _desktopCallOpen = false;
      _compactPane = _CompactPane.settings;
    });
  }

  void _closeSettings() {
    setState(() {
      _desktopSettingsOpen = false;
      _compactPane = _compactPaneBeforeSettings;
    });
  }

  void _openCall() {
    if (widget.state.call == null && widget.state.groupCall == null) return;
    setState(() {
      _addingFriend = false;
      _desktopSettingsOpen = false;
      _desktopCallOpen = true;
      _compactPane = _CompactPane.call;
    });
  }

  void _minimizeCall() {
    final peer = widget.state.call?.peerId;
    final friend = peer == null ? null : widget.state.friends[peer];
    if (friend != null) {
      _openFriend(friend);
      return;
    }
    final group = widget.state.groupCall == null
        ? null
        : widget.state.groups[widget.state.groupCall!.conversationId];
    if (group != null) {
      _openGroup(group);
      return;
    }
    _leaveCallSurface();
    setState(() {
      _desktopCallOpen = false;
      _compactPane = _CompactPane.people;
    });
  }

  /// The pane actually on screen â€” a selection or a call can vanish underneath
  /// the stored one, and back has to agree with what the user is looking at.
  _CompactPane get _pane =>
      _compactPane == _CompactPane.conversation &&
          widget.state.selectedFriend == null &&
          widget.state.selectedGroup == null
      ? _CompactPane.people
      : _compactPane == _CompactPane.call &&
            widget.state.call == null &&
            widget.state.groupCall == null
      ? _CompactPane.people
      : _compactPane;

  bool get _canGoBack =>
      _desktopSettingsOpen || _addingFriend || _pane != _CompactPane.people;

  void _goBack() {
    if (_desktopSettingsOpen) {
      _closeSettings();
      return;
    }
    if (_addingFriend) {
      _closeAddFriend();
      return;
    }
    if (_pane != _CompactPane.people) {
      _leaveCallSurface();
      setState(() {
        _compactPane = _CompactPane.people;
        _desktopCallOpen = false;
      });
    }
  }

  void _openDiagnostics() {
    _leaveCallSurface();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => WindowsChromeContent(
          onboarding: true,
          child: DebugScreen(state: widget.state),
        ),
      ),
    );
  }

  @override
  void dispose() {
    sonarOpenRequests.removeListener(_openSonar);
    unawaited(widget.state.stopRemoteControl());
    widget.state.setConversationVisible(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Panes swap inside this single route, so the Android back gesture would
      // otherwise close the app from a conversation, a call or settings instead
      // of stepping back to the people list.
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.comma, control: true):
              _OpenSettingsIntent(),
          SingleActivator(LogicalKeyboardKey.escape): _GoBackIntent(),
          SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _SearchHistoryIntent(),
        },
        child: Actions(
          actions: {
            _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
              onInvoke: (_) {
                _openSettings();
                return null;
              },
            ),
            _SearchHistoryIntent: CallbackAction<_SearchHistoryIntent>(
              onInvoke: (_) {
                _openHistorySearch();
                return null;
              },
            ),
            _GoBackIntent: CallbackAction<_GoBackIntent>(
              onInvoke: (_) {
                _goBack();
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: OnboardingSurface(
                active: false,
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final window = WindowPresentationScope.maybeOf(context);
                      final compact =
                          window?.compact == true ||
                          (window?.animating != true &&
                              constraints.maxWidth <
                                  SyblLayout.desktopBreakpoint);
                      final call = widget.state.call;
                      final groupCall = widget.state.groupCall;
                      final compactPane = _pane;
                      final selectedOwner =
                          widget.state.selectedGroup?.ownerKey ??
                          widget.state.peerId;
                      final selectedGroup = widget.state.selectedGroup;
                      final visibleConversationOwner =
                          selectedGroup == null || _visibleGroupTopicId != null
                          ? selectedOwner
                          : null;
                      final visiblePeerId = _historySearchOpen || _addingFriend
                          ? null
                          : compact
                          ? (compactPane == _CompactPane.conversation
                                ? visibleConversationOwner
                                : null)
                          : (!_desktopSettingsOpen && !_desktopCallOpen
                                ? visibleConversationOwner
                                : null);
                      _reportVisibleConversation(
                        visiblePeerId,
                        groupTopicId: visiblePeerId == selectedGroup?.ownerKey
                            ? _visibleGroupTopicId
                            : null,
                        dmTopicId:
                            visiblePeerId != null &&
                                selectedGroup == null &&
                                widget.state.dmTopicRowVisible
                            ? widget.state.selectedDmTopicId
                            : null,
                      );
                      final content = window != null
                          ? _buildDesktop(context, compact: compact)
                          : compact
                          ? _buildCompact(context)
                          : _buildDesktop(context);
                      final ringing =
                          call?.dir == CallDir.incoming &&
                          call?.state == 'RINGING';
                      final showingCall = compact
                          ? compactPane == _CompactPane.call
                          : _desktopCallOpen;
                      final bannerBelowChatHeader =
                          compact &&
                          window?.compact != true &&
                          compactPane == _CompactPane.conversation &&
                          selectedGroup == null &&
                          widget.state.selectedFriend != null;
                      final windowLayoutRevision = ++_windowLayoutRevision;
                      if (window?.compact == true) {
                        final surface =
                            showingCall &&
                                call != null &&
                                !ringing &&
                                !call.hasVideo
                            ? CompactSurface.directAudio
                            : showingCall &&
                                  groupCall != null &&
                                  !groupCall.hasVideo
                            ? CompactSurface.groupAudio
                            : CompactSurface.conversation;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted ||
                              windowLayoutRevision != _windowLayoutRevision) {
                            return;
                          }
                          if (showingCall &&
                              (call?.hasVideo == true ||
                                  groupCall?.hasVideo == true)) {
                            unawaited(window!.setCompact(false));
                          } else {
                            unawaited(window!.fit(surface));
                          }
                        });
                      }
                      return Stack(
                        children: [
                          Positioned.fill(child: content),
                          if (ringing &&
                              (!showingCall || window?.compact == true))
                            Positioned(
                              top: window?.compact == true
                                  ? (selectedGroup != null ? 76 : 43)
                                  : 10,
                              right: window?.compact == true ? 8 : 10,
                              child: CompositedTransformFollower(
                                link: bannerBelowChatHeader
                                    ? _chatHeaderLinks[widget
                                          .state
                                          .selectedFriend!
                                          .peerId]!
                                    : LayerLink(),
                                showWhenUnlinked: !bannerBelowChatHeader,
                                targetAnchor: Alignment.bottomRight,
                                followerAnchor: Alignment.topRight,
                                offset: const Offset(-10, 10),
                                child: _callSurface(
                                  _IncomingCallBanner(
                                    state: widget.state,
                                    onOpen: window?.compact == true
                                        ? () {}
                                        : _openCall,
                                    onAnswer: () {
                                      _openCall();
                                      if (call != null) {
                                        widget.state.answer(call);
                                      }
                                    },
                                    onDecline: () {
                                      if (call != null) {
                                        widget.state.decline(call);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                          if (!showingCall &&
                              !_desktopSettingsOpen &&
                              groupCall?.connected == true &&
                              groupCall!.hasVideo)
                            Positioned(
                              top:
                                  compact &&
                                      selectedGroup != null &&
                                      widget.state.mobileGroupNavigation ==
                                          MobileGroupNavigation.inline
                                  ? GroupStage.mobileHeaderHeight +
                                        GroupStage.inlineTopicRowHeight +
                                        1 +
                                        8
                                  : compact
                                  ? 70
                                  : kToolbarHeight + 12,
                              right: 10,
                              child: _callSurface(
                                _GroupCallPreview(
                                  key: const ValueKey('group-call-preview'),
                                  call: groupCall,
                                  onOpen: _openCall,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktop(BuildContext context, {bool compact = false}) {
    final window = WindowPresentationScope.maybeOf(context);
    final railTitleInset =
        window != null &&
            !window.compact &&
            WindowsChrome.normalTitleBarLeft(
                  MediaQuery.sizeOf(context).width,
                ) ==
                0
        ? WindowsChrome.height
        : 0.0;
    final inGroup =
        !_desktopSettingsOpen &&
        widget.state.selectedGroup != null &&
        !(compact && _pane == _CompactPane.people);
    final emptyPane =
        !_desktopSettingsOpen &&
        !_desktopCallOpen &&
        !_addingFriend &&
        widget.state.selectedGroup == null &&
        widget.state.selectedFriend == null;
    final rail = AnimatedContainer(
      duration: SyblMotion.duration(context, const Duration(milliseconds: 280)),
      curve: Curves.easeOutCubic,
      width: window == null ? (inGroup ? 58 : SyblLayout.railWidth) : null,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: context.syblColors.desk),
      child: AnimatedPadding(
        duration: SyblMotion.duration(
          context,
          WindowPresentation.animationDuration,
        ),
        curve: WindowPresentation.animationCurve,
        padding: EdgeInsets.only(top: railTitleInset),
        child: GestureDetector(
          key: const ValueKey('desktop-sidebar-dismiss-settings'),
          behavior: HitTestBehavior.translucent,
          onTap: _desktopSettingsOpen ? _closeSettings : null,
          child: _desktopRail(
            context,
            inGroup: inGroup,
            compact: compact,
            expandPeople: window != null,
          ),
        ),
      ),
    );
    final divider = GravityWall(
      child: VerticalDivider(
        key: const ValueKey('desktop-rail-divider'),
        width: 1,
        color: inGroup ? context.syblColors.surface : null,
      ),
    );
    final pane = AnimatedContainer(
      duration: SyblMotion.duration(context, const Duration(milliseconds: 220)),
      color: Colors.transparent,
      padding: EdgeInsets.only(
        // Empty content centers in the full pane; pages reserve control space.
        top:
            window == null ||
                window.compact ||
                emptyPane ||
                (_addingFriend && !_desktopSettingsOpen && !_desktopCallOpen)
            ? 0
            : WindowsChrome.height,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: PaneRevealSwitcher(
              child: _desktopSettingsOpen
                  ? SettingsPane(
                      key: const ValueKey('desktop-settings'),
                      state: widget.state,
                      appLockController: widget.appLockController,
                      onClose: _closeSettings,
                      onOpenDiagnostics: _openDiagnostics,
                      onAddFriend: () => _addFriend(),
                      focusMicrophoneOnOpen:
                          widget.state.appSettings.microphoneReviewRequired,
                    )
                  : _desktopCallOpen &&
                        (widget.state.call != null ||
                            widget.state.groupCall != null)
                  ? (compact &&
                            widget.state.call?.dir == CallDir.incoming &&
                            widget.state.call?.state == 'RINGING'
                        ? _desktopConversation(compact: true)
                        : _desktopCallStage())
                  : _addingFriend
                  ? _addFriendPane(underTitleBar: window != null && !compact)
                  : _desktopConversation(compact: compact),
            ),
          ),
          // Live video/share keeps a corner presence while the call
          // screen is minimized; hovering grows it, clicking opens it.
          if (!compact &&
              !_desktopCallOpen &&
              !_desktopSettingsOpen &&
              widget.state.call?.connected == true &&
              widget.state.call!.hasVideo)
            Positioned(
              top: kToolbarHeight + 12,
              right: 10,
              child: _callSurface(
                _DesktopCallPreview(
                  key: const ValueKey('desktop-call-preview'),
                  call: widget.state.call!,
                  onOpen: _openCall,
                ),
              ),
            ),
        ],
      ),
    );
    if (window != null) {
      return WindowsPaneLayout(
        compact: compact,
        showPeople: _pane == _CompactPane.people,
        railWidth: inGroup ? 58 : SyblLayout.railWidth,
        adaptiveResize: !window.compact && !window.animating,
        rail: rail,
        pane: pane,
        divider: divider,
      );
    }
    return Row(
      children: [
        rail,
        divider,
        Expanded(child: pane),
      ],
    );
  }

  Widget _desktopConversation({required bool compact}) => Column(
    key: ValueKey((
      'conversation-pane',
      widget.state.accountId,
      widget.state.selectedGroup?.ownerKey ?? widget.state.peerId,
    )),
    children: [
      Expanded(child: _conversationOrEmpty(onBack: compact ? _goBack : null)),
      if (compact &&
          widget.state.groupCall != null &&
          widget.state.selectedGroup == null)
        GroupCallDock(
          state: widget.state,
          onOpenCall: _openCall,
          onOpenSettings: _openSettings,
        ),
    ],
  );

  Widget _desktopCallStage() {
    final call = widget.state.call;
    if (call == null) {
      return _callSurface(
        GroupCallScreen(
          key: const ValueKey('desktop-group-call-stage'),
          state: widget.state,
          onMinimize: _minimizeCall,
        ),
      );
    }
    final ringingIn = call.dir == CallDir.incoming && call.state == 'RINGING';
    final stage = ringingIn
        ? IncomingScreen(state: widget.state, onMinimize: _minimizeCall)
        : InCallScreen(state: widget.state, onMinimize: _minimizeCall);
    return KeyedSubtree(
      key: const ValueKey('desktop-call-stage'),
      child: _callSurface(stage),
    );
  }

  // The scope takes a key derived from its child's, so switchers still see a
  // chat-to-chat change as a new child and animate it.
  Widget _sensitive(Widget child) => CaptureSensitiveScope(
    key: child.key == null ? null : ValueKey(('sensitive', child.key)),
    protection: widget.state.surfaceProtection,
    child: child,
  );

  // Calls are protected but never gated: privacy must not interfere with
  // placing, answering or ending a call.
  Widget _callSurface(Widget child) => CaptureSensitiveScope(
    key: child.key == null ? null : ValueKey(('sensitive', child.key)),
    protection: widget.state.surfaceProtection,
    gate: false,
    child: child,
  );

  Widget _buildCompact(BuildContext context) {
    final pane = _pane;
    return AnimatedSwitcher(
      duration: SyblMotion.duration(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(.055, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: switch (pane) {
        _CompactPane.addFriend => _addFriendPane(),
        _CompactPane.people => FriendRail(
          key: const ValueKey('compact-people-pane'),
          state: widget.state,
          onOpenFriend: _openFriend,
          onOpenGroup: _openGroup,
          onOpenCall: _openCall,
          onAddFriend: _addFriend,
          onCreateGroup: _createGroup,
          onInviteFriend: _inviteFriend,
          onSearch: _openHistorySearch,
          onOpenSettings: _openSettings,
          compact: true,
        ),
        _CompactPane.conversation => KeyedSubtree(
          key: const ValueKey('compact-conversation-pane'),
          child: _compactConversation(),
        ),
        _CompactPane.call => _compactCallStage(),
        _CompactPane.settings => SettingsPane(
          key: const ValueKey('compact-settings-pane'),
          state: widget.state,
          appLockController: widget.appLockController,
          onClose: _closeSettings,
          onOpenDiagnostics: _openDiagnostics,
          onAddFriend: () => _addFriend(),
          focusMicrophoneOnOpen:
              widget.state.appSettings.microphoneReviewRequired,
        ),
      },
    );
  }

  Widget _desktopRail(
    BuildContext context, {
    required bool inGroup,
    bool compact = false,
    bool expandPeople = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use the width being laid out, so portraits, chrome and clipping share
        // the same timeline even when a resize or reversal interrupts it.
        final progress =
            ((SyblLayout.railWidth - constraints.maxWidth) /
                    (SyblLayout.railWidth - 58))
                .clamp(0.0, 1.0);
        // The opaque people rail remains underneath the incoming mini rail.
        // Fading both layers separately creates a blank frame at the handoff.
        const peopleOpacity = 1.0;
        final miniOpacity = progress;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              key: const ValueKey('desktop-people-rail-position'),
              left: 0,
              top: 0,
              bottom: 0,
              width: expandPeople
                  ? constraints.maxWidth.clamp(
                      SyblLayout.railWidth,
                      double.infinity,
                    )
                  : SyblLayout.railWidth,
              child: IgnorePointer(
                ignoring: inGroup,
                child: ExcludeSemantics(
                  excluding: inGroup,
                  child: Opacity(
                    key: const ValueKey('desktop-people-rail-layer'),
                    opacity: peopleOpacity,
                    child: FriendRail(
                      key: const ValueKey('desktop-people-rail'),
                      compact: compact && !expandPeople,
                      profileAvatarAnchor: _railProfileStart,
                      state: widget.state,
                      highlightedPeerId: compact && _pane == _CompactPane.people
                          ? null
                          : widget.state.peerId,
                      onOpenFriend: _openFriend,
                      onOpenGroup: _openGroup,
                      onOpenCall: _openCall,
                      onAddFriend: _addFriend,
                      onCreateGroup: _createGroup,
                      onInviteFriend: _inviteFriend,
                      onSearch: _openHistorySearch,
                      onOpenSettings: _openSettings,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              key: const ValueKey('desktop-mini-rail-position'),
              left: 0,
              top: 0,
              bottom: 0,
              width: constraints.maxWidth,
              child: IgnorePointer(
                ignoring: !inGroup,
                child: TickerMode(
                  enabled: progress > 0,
                  child: Offstage(
                    offstage: progress == 0,
                    child: ExcludeSemantics(
                      excluding: !inGroup,
                      child: Opacity(
                        key: const ValueKey('desktop-mini-rail-layer'),
                        opacity: miniOpacity,
                        child: GroupMiniRail(
                          key: const ValueKey('desktop-group-mini-rail'),
                          onSearch: _openHistorySearch,
                          state: widget.state,
                          profileAvatarAnchor: _railProfileEnd,
                          onOpenPeople: _openPeopleHome,
                          onOpenFriend: _openFriend,
                          onOpenGroup: _openGroup,
                          onOpenSettings: _openSettings,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: RailProfileAvatar(
                key: const ValueKey('desktop-shared-profile'),
                state: widget.state,
                start: _railProfileStart,
                end: _railProfileEnd,
                progress: progress,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _compactCallStage() {
    final call = widget.state.call;
    if (call == null) {
      return _callSurface(
        GroupCallScreen(
          key: const ValueKey('compact-group-call-stage'),
          state: widget.state,
          onMinimize: _minimizeCall,
        ),
      );
    }
    final ringingIn = call.dir == CallDir.incoming && call.state == 'RINGING';
    if (ringingIn && WindowPresentationScope.isCompact(context)) {
      return _compactConversation();
    }

    return KeyedSubtree(
      key: const ValueKey('compact-call-stage'),
      child: _callSurface(
        ringingIn
            ? IncomingScreen(state: widget.state, onMinimize: _minimizeCall)
            : InCallScreen(state: widget.state, onMinimize: _minimizeCall),
      ),
    );
  }

  Widget _compactConversation() {
    final groupOwnsDock = widget.state.selectedGroup != null;
    return Column(
      children: [
        Expanded(child: _conversationOrEmpty(onBack: _goBack)),
        if (widget.state.groupCall != null && !groupOwnsDock)
          GroupCallDock(
            state: widget.state,
            onOpenCall: _openCall,
            onOpenSettings: _openSettings,
          ),
      ],
    );
  }

  Widget _conversationOrEmpty({required VoidCallback? onBack}) {
    final group = widget.state.selectedGroup;
    if (group != null) {
      return _sensitive(
        GroupStage(
          key: ValueKey((
            accountId: widget.state.accountId ?? '',
            conversationId: group.conversationId,
          )),
          state: widget.state,
          group: group,
          onBack: onBack,
          onOpenCall: _openCall,
          onOpenSettings: _openSettings,
          requestedTopicId:
              _historyGroupTarget?.conversationId == group.conversationId
              ? _historyGroupTarget?.topicId
              : null,
          navigationToken:
              _historyGroupTarget?.conversationId == group.conversationId
              ? _historyGroupTarget?.token
              : null,
          onConversationVisibilityChanged: (topicId) {
            if (_visibleGroupTopicId == topicId) return;
            setState(() => _visibleGroupTopicId = topicId);
          },
        ),
      );
    }
    final friend = widget.state.selectedFriend;
    if (friend != null) {
      return _sensitive(
        ChatStage(
          key: ValueKey((
            accountId: widget.state.accountId ?? '',
            peerId: friend.peerId,
            conversationId: friend.conversationId,
          )),
          state: widget.state,
          friend: friend,
          onBack: onBack,
          onOpenCall: _openCall,
          headerLayerLink:
              onBack != null && !WindowPresentationScope.isCompact(context)
              ? _chatHeaderLinks.putIfAbsent(friend.peerId, LayerLink.new)
              : null,
        ),
      );
    }
    return SyblStatusPanel(
      key: const ValueKey('no-selected-friend'),
      kind: SyblStatusKind.empty,
      title: 'Your chats will be here',
      message: '',
    );
  }
}

/// Minimized call with live video: a corner tile over the chat. Hover grows
/// it for a closer look; clicking opens the full call screen.
class _DesktopCallPreview extends StatefulWidget {
  const _DesktopCallPreview({
    super.key,
    required this.call,
    required this.onOpen,
  });

  final CallSession call;
  final VoidCallback onOpen;

  @override
  State<_DesktopCallPreview> createState() => _DesktopCallPreviewState();
}

class _DesktopCallPreviewState extends State<_DesktopCallPreview> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    // Prefer what they are showing us; fall back to our own outgoing video.
    final remote = call.remoteActive && call.remoteTextureId != null;
    final textureId = remote ? call.remoteTextureId : call.selfTextureId;
    final aspectRatio = remote && call.remoteWidth > 0 && call.remoteHeight > 0
        ? call.remoteWidth / call.remoteHeight
        : call.outgoingVideo.geometry?.aspectRatio ??
              (call.selfWidth > 0 && call.selfHeight > 0
                  ? call.selfWidth / call.selfHeight
                  : 16 / 9);
    final boundedRatio = aspectRatio.clamp(.35, 2.4).toDouble();
    final previewSize = boundedRatio >= 1
        ? Size(200, 200 / boundedRatio)
        : Size(180 * boundedRatio, 180);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedScale(
          duration: SyblMotion.duration(context),
          curve: Curves.easeOutCubic,
          scale: _hovered ? 1.6 : 1,
          alignment: Alignment.topRight,
          child: Tooltip(
            message: 'Open call screen',
            waitDuration: const Duration(milliseconds: 600),
            child: Container(
              width: previewSize.width,
              height: previewSize.height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.syblColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _hovered
                      ? context.syblColors.amber
                      : context.syblColors.lineStrong,
                ),
                boxShadow: const [
                  BoxShadow(color: Color(0x59000000), blurRadius: 14),
                ],
              ),
              child: textureId == null
                  ? Center(
                      child: Gravity(
                        child: Icon(
                          Icons.screen_share_outlined,
                          color: context.syblColors.muted,
                          size: 26,
                        ),
                      ),
                    )
                  : Center(
                      child: AspectRatio(
                        aspectRatio: boundedRatio,
                        child: Texture(textureId: textureId),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupCallPreview extends StatefulWidget {
  const _GroupCallPreview({
    super.key,
    required this.call,
    required this.onOpen,
  });

  final GroupCallSession call;
  final VoidCallback onOpen;

  @override
  State<_GroupCallPreview> createState() => _GroupCallPreviewState();
}

class _GroupCallPreviewState extends State<_GroupCallPreview> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ratio = widget.call.videoAspectRatio.clamp(.35, 2.4).toDouble();
    final compact = SyblLayout.isCompact(context);
    final width = compact ? 148.0 : 200.0;
    final height = (width / ratio).clamp(84.0, compact ? 190.0 : 220.0);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedScale(
          duration: SyblMotion.duration(context),
          curve: Curves.easeOutCubic,
          scale: !compact && _hovered ? 1.45 : 1,
          alignment: Alignment.topRight,
          child: Container(
            width: width,
            height: height,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: context.syblColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _hovered
                    ? context.syblColors.amber
                    : context.syblColors.lineStrong,
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x59000000), blurRadius: 14),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.call.videoTextureId case final textureId?)
                  Center(
                    child: AspectRatio(
                      aspectRatio: ratio,
                      child: Texture(textureId: textureId),
                    ),
                  )
                else
                  Center(
                    child: Gravity(
                      child: Icon(
                        Icons.video_call_outlined,
                        color: context.syblColors.muted,
                        size: 28,
                      ),
                    ),
                  ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Gravity(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .65),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Text(
                          '${widget.call.conference.videoStreams.length.clamp(1, 99)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IncomingCallBanner extends StatelessWidget {
  const _IncomingCallBanner({
    required this.state,
    required this.onOpen,
    required this.onAnswer,
    required this.onDecline,
  });

  final AppState state;
  final VoidCallback onOpen;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final call = state.call;
    if (call == null) return const SizedBox.shrink();
    final name = state.peerDisplayName(call.peerId);
    final compact = WindowPresentationScope.isCompact(context);
    return TweenAnimationBuilder<double>(
      key: ValueKey('incoming-call-banner-${call.callId}'),
      tween: Tween(begin: 0, end: 1),
      duration: SyblMotion.duration(context, const Duration(milliseconds: 320)),
      curve: Curves.easeOutCubic,
      builder: (context, progress, child) => IgnorePointer(
        ignoring: progress < 1,
        child: Transform.translate(
          offset: Offset((1 - progress) * 48, 0),
          child: Opacity(
            opacity: progress,
            child: ImageFiltered(
              enabled: progress < 1,
              imageFilter: ui.ImageFilter.blur(
                sigmaX: (1 - progress) * 2,
                sigmaY: (1 - progress) * 2,
              ),
              child: child,
            ),
          ),
        ),
      ),
      child: Material(
        color: context.syblColors.surfaceTop.withValues(
          alpha: compact ? .94 : 1,
        ),
        elevation: compact ? 3 : 12,
        shadowColor: Colors.black.withValues(alpha: .55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 10 : 18),
          side: BorderSide(
            color: compact
                ? context.syblColors.lineStrong
                : context.syblColors.amber.withValues(alpha: .7),
            width: compact ? 1 : 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: BackdropFilter(
          enabled: compact,
          filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: compact ? MediaQuery.sizeOf(context).width - 16 : 360,
            ),
            child: Padding(
              padding: compact
                  ? const EdgeInsets.fromLTRB(11, 7, 8, 7)
                  : const EdgeInsets.all(10),
              child: WindowPresentationScope.isCompact(context)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 110),
                            child: Gravity(
                              child: InkWell(
                                onTap: onOpen,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: context.syblColors.ink,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      'Incoming call',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: context.syblColors.muted,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Gravity(
                          child: TextButton.icon(
                            key: const ValueKey('answer-incoming-call-banner'),
                            onPressed: onAnswer,
                            icon: const Icon(Icons.call, size: 15),
                            label: const Text(
                              'Answer',
                              style: TextStyle(fontSize: 11),
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: context.syblColors.online,
                              backgroundColor: context.syblColors.online
                                  .withValues(alpha: .10),
                              minimumSize: const Size(0, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Gravity(
                          child: IconButton(
                            key: const ValueKey('decline-incoming-call-banner'),
                            tooltip: 'Decline',
                            icon: const Icon(Icons.call_end, size: 15),
                            onPressed: onDecline,
                            style: IconButton.styleFrom(
                              foregroundColor: context.syblColors.danger,
                              backgroundColor: context.syblColors.danger
                                  .withValues(alpha: .12),
                              minimumSize: const Size(28, 28),
                              maximumSize: const Size(28, 28),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          key: const ValueKey('open-incoming-call'),
                          onTap: onOpen,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SyblAvatar(
                                  label: name,
                                  imageBase64:
                                      state.friends[call.peerId]?.avatarBase64,
                                  size: 40,
                                  color: context.syblColors.sage,
                                ),
                                const SizedBox(width: 9),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 140,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Gravity(
                                        child: Text(
                                          name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: context.syblColors.ink,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      Gravity(
                                        child: Text(
                                          call.peerVideo
                                              ? 'Incoming video call'
                                              : 'Incoming call',
                                          style: TextStyle(
                                            color: context.syblColors.faint,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Gravity(
                          child: IconButton.filled(
                            key: const ValueKey('decline-incoming-call-banner'),
                            tooltip: 'Decline',
                            onPressed: onDecline,
                            style: IconButton.styleFrom(
                              backgroundColor: context.syblColors.dangerFill,
                              foregroundColor: context.syblColors.foregroundFor(
                                context.syblColors.dangerFill,
                              ),
                            ),
                            icon: const Icon(Icons.call_end_rounded),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Gravity(
                          child: IconButton.filled(
                            key: const ValueKey('answer-incoming-call-banner'),
                            tooltip: 'Accept',
                            onPressed: onAnswer,
                            style: IconButton.styleFrom(
                              backgroundColor: context.syblColors.onlineFill,
                              foregroundColor: context.syblColors.foregroundFor(
                                context.syblColors.onlineFill,
                              ),
                            ),
                            icon: Icon(
                              call.peerVideo
                                  ? Icons.videocam_rounded
                                  : Icons.call_rounded,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
