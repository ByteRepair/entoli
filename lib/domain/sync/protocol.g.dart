// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'protocol.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

SyncWelcome _$SyncWelcomeFromJson(Map<String, dynamic> json) => SyncWelcome(
  chats: (json['chats'] as List<dynamic>)
      .map((e) => ChatState.fromJson(e as Map<String, dynamic>))
      .toList(),
  proto: (json['proto'] as num?)?.toInt() ?? SyncIdentity.protocolVersion,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$SyncWelcomeToJson(SyncWelcome instance) =>
    <String, dynamic>{
      'chats': instance.chats.map((e) => e.toJson()).toList(),
      'proto': instance.proto,
      'runtimeType': instance.$type,
    };

SyncChatsChanged _$SyncChatsChangedFromJson(Map<String, dynamic> json) =>
    SyncChatsChanged(
      chats: (json['chats'] as List<dynamic>)
          .map((e) => ChatState.fromJson(e as Map<String, dynamic>))
          .toList(),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncChatsChangedToJson(SyncChatsChanged instance) =>
    <String, dynamic>{
      'chats': instance.chats.map((e) => e.toJson()).toList(),
      'runtimeType': instance.$type,
    };

SyncChatOpen _$SyncChatOpenFromJson(Map<String, dynamic> json) => SyncChatOpen(
  chatId: json['chatId'] as String,
  fromLine: (json['fromLine'] as num?)?.toInt() ?? 0,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$SyncChatOpenToJson(SyncChatOpen instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'fromLine': instance.fromLine,
      'runtimeType': instance.$type,
    };

SyncChatSnapshot _$SyncChatSnapshotFromJson(Map<String, dynamic> json) =>
    SyncChatSnapshot(
      chatId: json['chatId'] as String,
      state: ChatState.fromJson(json['state'] as Map<String, dynamic>),
      meta: ChatMeta.fromJson(json['meta'] as Map<String, dynamic>),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncChatSnapshotToJson(SyncChatSnapshot instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'state': instance.state.toJson(),
      'meta': instance.meta.toJson(),
      'runtimeType': instance.$type,
    };

SyncRecordAppend _$SyncRecordAppendFromJson(Map<String, dynamic> json) =>
    SyncRecordAppend(
      chatId: json['chatId'] as String,
      records: (json['records'] as List<dynamic>)
          .map((e) => ChatRecord.fromJson(e as Map<String, dynamic>))
          .toList(),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncRecordAppendToJson(SyncRecordAppend instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'records': instance.records.map((e) => e.toJson()).toList(),
      'runtimeType': instance.$type,
    };

SyncStateDiff _$SyncStateDiffFromJson(Map<String, dynamic> json) =>
    SyncStateDiff(
      chatId: json['chatId'] as String,
      state: ChatState.fromJson(json['state'] as Map<String, dynamic>),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncStateDiffToJson(SyncStateDiff instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'state': instance.state.toJson(),
      'runtimeType': instance.$type,
    };

SyncMetaPatch _$SyncMetaPatchFromJson(Map<String, dynamic> json) =>
    SyncMetaPatch(
      chatId: json['chatId'] as String,
      meta: ChatMeta.fromJson(json['meta'] as Map<String, dynamic>),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncMetaPatchToJson(SyncMetaPatch instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'meta': instance.meta.toJson(),
      'runtimeType': instance.$type,
    };

SyncChatDeleted _$SyncChatDeletedFromJson(Map<String, dynamic> json) =>
    SyncChatDeleted(
      chatId: json['chatId'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncChatDeletedToJson(SyncChatDeleted instance) =>
    <String, dynamic>{'chatId': instance.chatId, 'runtimeType': instance.$type};

SyncChatMoved _$SyncChatMovedFromJson(Map<String, dynamic> json) =>
    SyncChatMoved(
      chatId: json['chatId'] as String,
      project: json['project'] as String?,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncChatMovedToJson(SyncChatMoved instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'project': instance.project,
      'runtimeType': instance.$type,
    };

SyncResourceRequest _$SyncResourceRequestFromJson(Map<String, dynamic> json) =>
    SyncResourceRequest(
      id: json['id'] as String,
      chatId: json['chatId'] as String,
      resource: json['resource'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncResourceRequestToJson(
  SyncResourceRequest instance,
) => <String, dynamic>{
  'id': instance.id,
  'chatId': instance.chatId,
  'resource': instance.resource,
  'runtimeType': instance.$type,
};

SyncResourceChunk _$SyncResourceChunkFromJson(Map<String, dynamic> json) =>
    SyncResourceChunk(
      id: json['id'] as String,
      bytesB64: json['bytesB64'] as String,
      done: json['done'] as bool? ?? false,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncResourceChunkToJson(SyncResourceChunk instance) =>
    <String, dynamic>{
      'id': instance.id,
      'bytesB64': instance.bytesB64,
      'done': instance.done,
      'runtimeType': instance.$type,
    };

SyncPing _$SyncPingFromJson(Map<String, dynamic> json) =>
    SyncPing($type: json['runtimeType'] as String?);

Map<String, dynamic> _$SyncPingToJson(SyncPing instance) => <String, dynamic>{
  'runtimeType': instance.$type,
};

SyncPong _$SyncPongFromJson(Map<String, dynamic> json) =>
    SyncPong($type: json['runtimeType'] as String?);

Map<String, dynamic> _$SyncPongToJson(SyncPong instance) => <String, dynamic>{
  'runtimeType': instance.$type,
};

SyncControlState _$SyncControlStateFromJson(Map<String, dynamic> json) =>
    SyncControlState(
      chatId: json['chatId'] as String,
      holder: json['holder'] as String?,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncControlStateToJson(SyncControlState instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'holder': instance.holder,
      'runtimeType': instance.$type,
    };

SyncControlRequest _$SyncControlRequestFromJson(Map<String, dynamic> json) =>
    SyncControlRequest(
      chatId: json['chatId'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncControlRequestToJson(SyncControlRequest instance) =>
    <String, dynamic>{'chatId': instance.chatId, 'runtimeType': instance.$type};

SyncControlGrant _$SyncControlGrantFromJson(Map<String, dynamic> json) =>
    SyncControlGrant(
      chatId: json['chatId'] as String,
      granted: json['granted'] as bool,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncControlGrantToJson(SyncControlGrant instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'granted': instance.granted,
      'runtimeType': instance.$type,
    };

SyncControlRelease _$SyncControlReleaseFromJson(Map<String, dynamic> json) =>
    SyncControlRelease(
      chatId: json['chatId'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncControlReleaseToJson(SyncControlRelease instance) =>
    <String, dynamic>{'chatId': instance.chatId, 'runtimeType': instance.$type};

SyncTurnState _$SyncTurnStateFromJson(Map<String, dynamic> json) =>
    SyncTurnState(
      chatId: json['chatId'] as String,
      running: json['running'] as bool? ?? false,
      approvals:
          (json['approvals'] as List<dynamic>?)
              ?.map((e) => ToolApproval.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <ToolApproval>[],
      asks:
          (json['asks'] as List<dynamic>?)
              ?.map((e) => SyncAsk.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const <SyncAsk>[],
      status: json['status'] as String?,
      retry: json['retry'] as String?,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncTurnStateToJson(SyncTurnState instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'running': instance.running,
      'approvals': instance.approvals.map((e) => e.toJson()).toList(),
      'asks': instance.asks.map((e) => e.toJson()).toList(),
      'status': instance.status,
      'retry': instance.retry,
      'runtimeType': instance.$type,
    };

SyncPromptSend _$SyncPromptSendFromJson(Map<String, dynamic> json) =>
    SyncPromptSend(
      chatId: json['chatId'] as String,
      text: json['text'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncPromptSendToJson(SyncPromptSend instance) =>
    <String, dynamic>{
      'chatId': instance.chatId,
      'text': instance.text,
      'runtimeType': instance.$type,
    };

SyncApprovalRespond _$SyncApprovalRespondFromJson(Map<String, dynamic> json) =>
    SyncApprovalRespond(
      chatId: json['chatId'] as String,
      approvalId: json['approvalId'] as String,
      allow: json['allow'] as bool,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncApprovalRespondToJson(
  SyncApprovalRespond instance,
) => <String, dynamic>{
  'chatId': instance.chatId,
  'approvalId': instance.approvalId,
  'allow': instance.allow,
  'runtimeType': instance.$type,
};

SyncQuestionsRespond _$SyncQuestionsRespondFromJson(
  Map<String, dynamic> json,
) => SyncQuestionsRespond(
  chatId: json['chatId'] as String,
  requestId: json['requestId'] as String,
  answers: (json['answers'] as List<dynamic>).map((e) => e as String?).toList(),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$SyncQuestionsRespondToJson(
  SyncQuestionsRespond instance,
) => <String, dynamic>{
  'chatId': instance.chatId,
  'requestId': instance.requestId,
  'answers': instance.answers,
  'runtimeType': instance.$type,
};

SyncTurnAbort _$SyncTurnAbortFromJson(Map<String, dynamic> json) =>
    SyncTurnAbort(
      chatId: json['chatId'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncTurnAbortToJson(SyncTurnAbort instance) =>
    <String, dynamic>{'chatId': instance.chatId, 'runtimeType': instance.$type};

SyncTurnResume _$SyncTurnResumeFromJson(Map<String, dynamic> json) =>
    SyncTurnResume(
      chatId: json['chatId'] as String,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$SyncTurnResumeToJson(SyncTurnResume instance) =>
    <String, dynamic>{'chatId': instance.chatId, 'runtimeType': instance.$type};

_SyncAsk _$SyncAskFromJson(Map<String, dynamic> json) => _SyncAsk(
  id: json['id'] as String,
  argumentsJson: json['argumentsJson'] as String?,
);

Map<String, dynamic> _$SyncAskToJson(_SyncAsk instance) => <String, dynamic>{
  'id': instance.id,
  'argumentsJson': instance.argumentsJson,
};
