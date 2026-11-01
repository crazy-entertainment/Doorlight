import 'capture_sensitive_scope.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/conversation_scope.dart';
import '../state/conversation_search.dart';
import '../state/conversation_timeline.dart';
import '../state/search_message_selection.dart';
import '../theme.dart';
import 'gravity.dart';
import 'sybl_ui.dart';

/// Returns a navigation target only after its current folded message was read.
/// The caller still revalidates membership and its account/route owner.
Future<HistorySearchHit?> showHistorySearchDialog(
  BuildContext context, {
  required AppState state,
  ConversationScope? initialScope,
}) => showDialog<HistorySearchHit>(
  context: context,
  builder: (_) => CaptureSensitiveScope(
    protection: state.surfaceProtection,
    child: HistorySearchDialog(state: state, initialScope: initialScope),
  ),
);

class HistorySearchDialog extends StatefulWidget {
  const HistorySearchDialog({
    super.key,
    required this.state,
    this.initialScope,
  });
  final AppState state;
  final ConversationScope? initialScope;

  @override
  State<HistorySearchDialog> createState() => _HistorySearchDialogState();
}

class _HistorySearchDialogState extends State<HistorySearchDialog> {
  final _query = TextEditingController();
  late final ConversationSearch _search;
  late final SearchMessageSelection _selection;
  late final HistorySearchOwner? _owner;
  ConversationScope? _scope;
  bool _retired = false;
  bool _detail = false;

  @override
  void initState() {
    super.initState();
    _owner = widget.state.historySearchOwner;
    _search = widget.state.historySearch;
    _selection = widget.state.searchMessageSelection;
    _scope = widget.initialScope;
    _retired = _owner == null;
    widget.state.addListener(_stateChanged);
    _search.addListener(_stateChanged);
    _selection.addListener(_stateChanged);
  }

  void _stateChanged() {
    if (!mounted || _retired || _owner == widget.state.historySearchOwner) {
      return;
    }
    _query.clear();
    setState(() {
      _retired = true;
      _detail = false;
    });
  }

  void _queryChanged(String value) {
    _selection.retire();
    setState(() => _detail = false);
    _search.setQuery(value, scope: _scope);
  }

  Future<void> _select(HistorySearchHit hit) async {
    if (_retired || _search.busy || !_selection.canSelect) return;
    setState(() => _detail = true);
    await _selection.select(hit);
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    _search.removeListener(_stateChanged);
    _selection.removeListener(_stateChanged);
    widget.state.retireHistorySearch();
    _query.dispose();
    super.dispose();
  }

  String _scopeName(ConversationScope scope) => scope.isGroup
      ? widget.state.groups[scope.conversationId]?.displayTitle ?? 'Group'
      : widget.state.peerDisplayName(scope.peerId);

  String _when(DateTime value) {
    final local = value.toLocal();
    final labels = MaterialLocalizations.of(context);
    return '${labels.formatCompactDate(local)} · ${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_search, _selection, widget.state]),
    builder: (context, _) => Dialog(
      child: SizedBox(
        width: 640,
        height: 620,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Gravity(
                      child: Text(
                        _detail ? 'Message from history' : 'Search history',
                        style: context.syblColors.display.copyWith(
                          fontSize: 21,
                        ),
                      ),
                    ),
                  ),
                  Gravity(
                    child: IconButton(
                      key: const ValueKey('history-search-close'),
                      tooltip: 'Close search',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('history-search-scroll'),
                padding: const EdgeInsets.all(20),
                child: _retired
                    ? const Gravity(
                        child: Text(
                          'Search was closed when the identity or privacy state changed. Close this dialog and search again.',
                        ),
                      )
                    : _detail
                    ? _messageDetail()
                    : _results(),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _results() {
    final scopes = widget.state.historySearchScopes;
    final scope = scopes.contains(_scope) ? _scope : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Gravity(
          child: TextField(
            key: const ValueKey('history-search-query'),
            controller: _query,
            autofocus: SyblLayout.autofocusTextInput(context),
            maxLength: HistorySearchWire.maximumQueryCodeUnits,
            textInputAction: TextInputAction.search,
            onChanged: _queryChanged,
            onSubmitted: _queryChanged,
            decoration: InputDecoration(
              labelText: 'Words or a file name',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                tooltip: 'Clear query',
                onPressed: () {
                  _query.clear();
                  _queryChanged('');
                },
                icon: const Icon(Icons.clear_rounded),
              ),
            ),
          ),
        ),
        Gravity(
          child: DropdownButton<ConversationScope?>(
            key: const ValueKey('history-search-scope'),
            value: scope,
            isExpanded: true,
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('All conversations'),
              ),
              for (final candidate in scopes)
                DropdownMenuItem(
                  value: candidate,
                  child: Text(
                    _scopeName(candidate),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              setState(() => _scope = value);
              _queryChanged(_query.text);
            },
          ),
        ),
        const SizedBox(height: 12),
        if (_search.busy) ...[
          const LinearProgressIndicator(
            key: ValueKey('history-search-progress'),
          ),
          const SizedBox(height: 10),
          const Gravity(child: Text('Searching local history…')),
        ],
        if (_search.problem != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Gravity(
              child: Text(
                _search.problem == HistorySearchProblem.invalidQuery
                    ? 'Enter a single line of up to 256 characters.'
                    : 'Some history could not be searched. Results below may be incomplete.',
                key: const ValueKey('history-search-error'),
                style: TextStyle(color: context.syblColors.danger),
              ),
            ),
          ),
        if (_query.text.trim().isNotEmpty &&
            !_search.busy &&
            _search.problem == null &&
            _search.results.isEmpty)
          const Gravity(
            child: Text(
              'No matching messages in the searched history.',
              key: ValueKey('history-search-empty'),
            ),
          ),
        for (final hit in _search.results)
          Gravity(
            child: ListTile(
              key: ValueKey(('history-search-hit', hit.scope, hit.messageId)),
              contentPadding: EdgeInsets.zero,
              enabled: !_search.busy && _selection.canSelect,
              leading: Icon(
                hit.isFile
                    ? Icons.insert_drive_file_outlined
                    : Icons.chat_bubble_outline_rounded,
              ),
              title: Text(
                hit.snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_scopeName(hit.scope)} · ${_when(hit.createdAt)}',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _select(hit),
            ),
          ),
        if (_search.hasMore)
          Gravity(
            child: TextButton(
              key: const ValueKey('history-search-more'),
              onPressed: _search.showMore,
              child: Text('Show more (${_search.resultCount} found)'),
            ),
          ),
        if (_search.limited && _search.problem == null)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Gravity(
              child: Text(
                'Showing a bounded set of matches. Narrow the words or choose one conversation to find more.',
              ),
            ),
          ),
      ],
    );
  }

  Widget _messageDetail() {
    final hit = _selection.hit;
    final item = _selection.item;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Gravity(
            child: TextButton.icon(
              key: const ValueKey('history-search-back'),
              onPressed: () {
                _selection.retire();
                setState(() => _detail = false);
              },
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Back to results'),
            ),
          ),
        ),
        if (_selection.busy) ...[
          const LinearProgressIndicator(
            key: ValueKey('history-message-progress'),
          ),
          const SizedBox(height: 16),
          const Gravity(child: Text('Loading the current message…')),
        ] else if (item == null || hit == null) ...[
          const Gravity(
            child: Text(
              'This message is deleted, missing, or no longer available on this device.',
              key: ValueKey('history-message-unavailable'),
            ),
          ),
          if (hit != null)
            Gravity(
              child: TextButton(
                key: const ValueKey('history-message-reload'),
                onPressed: _selection.canSelect
                    ? () => _selection.select(hit)
                    : null,
                child: const Text('Check again'),
              ),
            ),
        ] else ...[
          Gravity(
            child: Text(
              _scopeName(hit.scope),
              style: context.syblColors.display.copyWith(fontSize: 19),
            ),
          ),
          const SizedBox(height: 6),
          Gravity(
            child: Text(
              '${item.authorId == widget.state.jamiId ? 'You' : widget.state.peerDisplayName(item.authorId)} · ${_when(item.createdAt)}',
              style: TextStyle(color: context.syblColors.muted),
            ),
          ),
          if (item.versionId != item.daemonId)
            const Gravity(child: Text('Edited')),
          const SizedBox(height: 20),
          if (item is TimelineTextItem)
            Gravity(
              child: SelectableText(
                item.text,
                key: const ValueKey('history-message-text'),
              ),
            )
          else if (item is TimelineFileItem) ...[
            const Gravity(
              child: Icon(Icons.insert_drive_file_outlined, size: 36),
            ),
            const SizedBox(height: 10),
            Gravity(
              child: SelectableText(
                item.displayName,
                key: const ValueKey('history-message-file'),
              ),
            ),
            if (item.totalBytes case final bytes?)
              Gravity(child: Text('$bytes bytes')),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              Gravity(
                child: TextButton.icon(
                  key: const ValueKey('history-message-reload'),
                  onPressed: _selection.canSelect
                      ? () => _selection.select(hit)
                      : null,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reload message'),
                ),
              ),
              Gravity(
                child: FilledButton.icon(
                  key: const ValueKey('history-message-open-conversation'),
                  onPressed: () {
                    if (!_retired &&
                        _owner == widget.state.historySearchOwner &&
                        _selection.item == item &&
                        ModalRoute.of(context)?.isCurrent == true) {
                      Navigator.of(context).pop(hit);
                    }
                  },
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Open conversation'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Gravity(child: Text('Unseen messages stay unread.')),
        ],
      ],
    );
  }
}
