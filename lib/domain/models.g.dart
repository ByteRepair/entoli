// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ChatState _$ChatStateFromJson(Map<String, dynamic> json) => _ChatState(
  id: json['id'] as String,
  title: json['title'] as String,
  createdAt: DateTime.parse(json['createdAt'] as String),
  updatedAt: DateTime.parse(json['updatedAt'] as String),
  backend: $enumDecode(_$BackendKindEnumMap, json['backend']),
  model: json['model'] as String?,
  provider: json['provider'] as String?,
);

Map<String, dynamic> _$ChatStateToJson(_ChatState instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
      'backend': _$BackendKindEnumMap[instance.backend]!,
      'model': instance.model,
      'provider': instance.provider,
    };

const _$BackendKindEnumMap = {
  BackendKind.opencode: 'opencode',
  BackendKind.miniswe: 'miniswe',
};

_Chat _$ChatFromJson(Map<String, dynamic> json) => _Chat(
  state: ChatState.fromJson(json['state'] as Map<String, dynamic>),
  messages:
      (json['messages'] as List<dynamic>?)
          ?.map((e) => Message.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

Map<String, dynamic> _$ChatToJson(_Chat instance) => <String, dynamic>{
  'state': instance.state,
  'messages': instance.messages,
};

_Message _$MessageFromJson(Map<String, dynamic> json) => _Message(
  id: json['id'] as String,
  role: $enumDecode(_$MessageRoleEnumMap, json['role']),
  createdAt: DateTime.parse(json['createdAt'] as String),
  parts:
      (json['parts'] as List<dynamic>?)
          ?.map((e) => MessagePart.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  parentId: json['parentId'] as String?,
);

Map<String, dynamic> _$MessageToJson(_Message instance) => <String, dynamic>{
  'id': instance.id,
  'role': _$MessageRoleEnumMap[instance.role]!,
  'createdAt': instance.createdAt.toIso8601String(),
  'parts': instance.parts,
  'parentId': instance.parentId,
};

const _$MessageRoleEnumMap = {
  MessageRole.system: 'system',
  MessageRole.user: 'user',
  MessageRole.assistant: 'assistant',
  MessageRole.tool: 'tool',
};

TextPart _$TextPartFromJson(Map<String, dynamic> json) => TextPart(
  text: json['text'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$TextPartToJson(TextPart instance) => <String, dynamic>{
  'text': instance.text,
  'runtimeType': instance.$type,
};

ReasoningPart _$ReasoningPartFromJson(Map<String, dynamic> json) =>
    ReasoningPart(
      text: json['text'] as String,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$ReasoningPartToJson(ReasoningPart instance) =>
    <String, dynamic>{
      'text': instance.text,
      'durationMs': instance.durationMs,
      'runtimeType': instance.$type,
    };

ToolCallPart _$ToolCallPartFromJson(Map<String, dynamic> json) => ToolCallPart(
  toolCall: ToolCall.fromJson(json['toolCall'] as Map<String, dynamic>),
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$ToolCallPartToJson(ToolCallPart instance) =>
    <String, dynamic>{
      'toolCall': instance.toolCall,
      'runtimeType': instance.$type,
    };

ToolResultPart _$ToolResultPartFromJson(Map<String, dynamic> json) =>
    ToolResultPart(
      result: ToolResult.fromJson(json['result'] as Map<String, dynamic>),
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$ToolResultPartToJson(ToolResultPart instance) =>
    <String, dynamic>{'result': instance.result, 'runtimeType': instance.$type};

FilePart _$FilePartFromJson(Map<String, dynamic> json) => FilePart(
  resource: json['resource'] as String,
  filename: json['filename'] as String,
  mimeType: json['mimeType'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$FilePartToJson(FilePart instance) => <String, dynamic>{
  'resource': instance.resource,
  'filename': instance.filename,
  'mimeType': instance.mimeType,
  'runtimeType': instance.$type,
};

ErrorPart _$ErrorPartFromJson(Map<String, dynamic> json) => ErrorPart(
  message: json['message'] as String,
  $type: json['runtimeType'] as String?,
);

Map<String, dynamic> _$ErrorPartToJson(ErrorPart instance) => <String, dynamic>{
  'message': instance.message,
  'runtimeType': instance.$type,
};

_ToolCall _$ToolCallFromJson(Map<String, dynamic> json) => _ToolCall(
  id: json['id'] as String,
  name: json['name'] as String,
  argumentsJson: json['argumentsJson'] as String?,
  argumentsText: json['argumentsText'] as String?,
);

Map<String, dynamic> _$ToolCallToJson(_ToolCall instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'argumentsJson': instance.argumentsJson,
  'argumentsText': instance.argumentsText,
};

_ToolResult _$ToolResultFromJson(Map<String, dynamic> json) => _ToolResult(
  callId: json['callId'] as String,
  returnCode: (json['returnCode'] as num).toInt(),
  output: json['output'] as String,
  exceptionInfo: json['exceptionInfo'] as String?,
);

Map<String, dynamic> _$ToolResultToJson(_ToolResult instance) =>
    <String, dynamic>{
      'callId': instance.callId,
      'returnCode': instance.returnCode,
      'output': instance.output,
      'exceptionInfo': instance.exceptionInfo,
    };

_ToolApproval _$ToolApprovalFromJson(Map<String, dynamic> json) =>
    _ToolApproval(
      id: json['id'] as String,
      toolName: json['toolName'] as String,
      argumentsJson: json['argumentsJson'] as String?,
    );

Map<String, dynamic> _$ToolApprovalToJson(_ToolApproval instance) =>
    <String, dynamic>{
      'id': instance.id,
      'toolName': instance.toolName,
      'argumentsJson': instance.argumentsJson,
    };

_ModelOption _$ModelOptionFromJson(Map<String, dynamic> json) => _ModelOption(
  providerId: json['providerId'] as String,
  modelId: json['modelId'] as String,
  label: json['label'] as String?,
);

Map<String, dynamic> _$ModelOptionToJson(_ModelOption instance) =>
    <String, dynamic>{
      'providerId': instance.providerId,
      'modelId': instance.modelId,
      'label': instance.label,
    };

_CompletionOption _$CompletionOptionFromJson(Map<String, dynamic> json) =>
    _CompletionOption(
      name: json['name'] as String,
      description: json['description'] as String?,
    );

Map<String, dynamic> _$CompletionOptionToJson(_CompletionOption instance) =>
    <String, dynamic>{
      'name': instance.name,
      'description': instance.description,
    };
