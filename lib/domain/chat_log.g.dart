// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_log.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MessageRecord _$MessageRecordFromJson(Map<String, dynamic> json) =>
    MessageRecord(
      id: json['id'] as String,
      role: $enumDecode(_$MessageRoleEnumMap, json['role']),
      createdAt: DateTime.parse(json['createdAt'] as String),
      parentId: json['parentId'] as String?,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$MessageRecordToJson(MessageRecord instance) =>
    <String, dynamic>{
      'id': instance.id,
      'role': _$MessageRoleEnumMap[instance.role]!,
      'createdAt': instance.createdAt.toIso8601String(),
      'parentId': instance.parentId,
      'runtimeType': instance.$type,
    };

const _$MessageRoleEnumMap = {
  MessageRole.system: 'system',
  MessageRole.user: 'user',
  MessageRole.assistant: 'assistant',
  MessageRole.tool: 'tool',
};

PartRecord _$PartRecordFromJson(Map<String, dynamic> json) => PartRecord(
  messageId: json['messageId'] as String,
  index: (json['index'] as num).toInt(),
  part: MessagePart.fromJson(json['part'] as Map<String, dynamic>),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$PartRecordToJson(PartRecord instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'index': instance.index,
      'part': instance.part,
      'runtimeType': instance.$type,
    };

AppendRecord _$AppendRecordFromJson(Map<String, dynamic> json) => AppendRecord(
  messageId: json['messageId'] as String,
  index: (json['index'] as num).toInt(),
  text: json['text'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$AppendRecordToJson(AppendRecord instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'index': instance.index,
      'text': instance.text,
      'runtimeType': instance.$type,
    };

TurnEndRecord _$TurnEndRecordFromJson(Map<String, dynamic> json) =>
    TurnEndRecord(
      messageId: json['messageId'] as String,
      reason: $enumDecode(_$TurnEndEnumMap, json['reason']),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$TurnEndRecordToJson(TurnEndRecord instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'reason': _$TurnEndEnumMap[instance.reason]!,
      'runtimeType': instance.$type,
    };

const _$TurnEndEnumMap = {
  TurnEnd.done: 'done',
  TurnEnd.aborted: 'aborted',
  TurnEnd.error: 'error',
};

BranchRecord _$BranchRecordFromJson(Map<String, dynamic> json) => BranchRecord(
  messageId: json['messageId'] as String,
  siblingOf: json['siblingOf'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$BranchRecordToJson(BranchRecord instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'siblingOf': instance.siblingOf,
      'runtimeType': instance.$type,
    };

SelectRecord _$SelectRecordFromJson(Map<String, dynamic> json) => SelectRecord(
  messageId: json['messageId'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$SelectRecordToJson(SelectRecord instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'runtimeType': instance.$type,
    };

RewindRecord _$RewindRecordFromJson(Map<String, dynamic> json) => RewindRecord(
  messageId: json['messageId'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$RewindRecordToJson(RewindRecord instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'runtimeType': instance.$type,
    };
