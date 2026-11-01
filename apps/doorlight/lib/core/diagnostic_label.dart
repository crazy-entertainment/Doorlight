/// Diagnostics retain fixed operation categories, never interpolated values.
/// Errors can contain paths, peer IDs, message contents or bearer credentials.
String diagnosticLabel(String message) {
  const operations = {
    'settings',
    'capture',
    'Android',
    'event',
    'startup',
    'boot',
    'backup',
    'restore',
    'discard',
    'app',
    'window',
    'remote',
    'audioOutputs',
    'audioInputs',
    'setAudioOutput',
    'setAudioInput',
    'setAppearOffline',
    'appearOffline',
    'setConnectionProfile',
    'connectionProfile',
    'updateDisplayName',
    'updateProfileAvatar',
    'backupIdentity',
    'setPresenceSubscriptions',
    'loadDmTopicState',
    'dmTopicStatePage',
    'setMessageNotificationPreview',
    'setReliableBackgroundNotifications',
    'setPresenceMetadata',
    'setIdentityColor',
    'acceptConnect',
    'setPeer',
    'declineConnect',
    'savePendingRemovals',
    'removePeer',
    'removeFriend',
    'leaveGroupCall',
    'setGroupMicMuted',
    'protect',
    'setGroupDeafened',
    'setGroupSpeaker',
    'setGroupVideoSource',
    'restoreGroupVideoSource',
    'placeCall',
    'placement',
    'glare',
    'notifyCallRequest',
    'answerCall',
    'refuse',
    'hangUp',
    'setMicMuted',
    'setAudioMeterEnabled',
    'setAudioTransmissionMode',
    'setSpeaker',
    'listScreenSources',
    'setOutgoingVideoSource',
    'openReceivedFile',
    'archive',
    'stressCommand',
    'refresh',
    'probe',
    'connectivitySweep',
    'acceptFile',
    'sendFileDeclined',
    'folderSnapshot',
    'fileInfo',
    'sendFile',
    'cancelFile',
    'Composer',
    'Replaced',
    'registrationState',
    'deviceAnnounced',
    'friendsChanged',
    'friendProfile',
    'incomingCall',
    'callState',
    'callMediaState',
    'callAudioState',
    'callVideoState',
    'callAudioMeter',
    'incomingFile',
    'fileProgress',
    'conversationReady',
    'conversationRemoved',
    'conversationRequest',
    'conversationError',
    'messageStatusChanged',
    'backgroundWakeReady',
    'wakeCapability',
    'audioOutputsChanged',
    'audioInputsChanged',
    'groupConferenceCreated',
    'groupConferenceChanged',
    'groupConferenceRemoved',
    'groupConferenceInfo',
    'groupCallState',
    'screenCaptureStopped',
    'captureProtectionChanged',
  };
  final action = message.startsWith('→ ');
  final event = message.startsWith('· ');
  final start = action || event ? 2 : 0;
  final operation = RegExp(
    r'^[A-Za-z][A-Za-z0-9]*',
  ).firstMatch(message.substring(start))?.group(0);
  if (!operations.contains(operation)) return 'Diagnostic event';
  var status = '';
  if (message.contains('failed') || message.contains('error')) {
    status = ' failed';
  } else if (message.contains('rejected') || message.contains('refusal')) {
    status = ' rejected';
  }
  var prefix = '';
  if (action) {
    prefix = '→ ';
  } else if (event) {
    prefix = '· ';
  }
  return '$prefix$operation$status';
}
