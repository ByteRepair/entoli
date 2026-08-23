// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'protocol.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
SyncMessage _$SyncMessageFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'welcome':
          return SyncWelcome.fromJson(
            json
          );
                case 'chatsChanged':
          return SyncChatsChanged.fromJson(
            json
          );
                case 'chatOpen':
          return SyncChatOpen.fromJson(
            json
          );
                case 'chatSnapshot':
          return SyncChatSnapshot.fromJson(
            json
          );
                case 'recordAppend':
          return SyncRecordAppend.fromJson(
            json
          );
                case 'stateDiff':
          return SyncStateDiff.fromJson(
            json
          );
                case 'metaPatch':
          return SyncMetaPatch.fromJson(
            json
          );
                case 'chatDeleted':
          return SyncChatDeleted.fromJson(
            json
          );
                case 'chatMoved':
          return SyncChatMoved.fromJson(
            json
          );
                case 'resourceRequest':
          return SyncResourceRequest.fromJson(
            json
          );
                case 'resourceChunk':
          return SyncResourceChunk.fromJson(
            json
          );
                case 'ping':
          return SyncPing.fromJson(
            json
          );
                case 'pong':
          return SyncPong.fromJson(
            json
          );
                case 'controlState':
          return SyncControlState.fromJson(
            json
          );
                case 'controlRequest':
          return SyncControlRequest.fromJson(
            json
          );
                case 'controlGrant':
          return SyncControlGrant.fromJson(
            json
          );
                case 'controlRelease':
          return SyncControlRelease.fromJson(
            json
          );
                case 'turnState':
          return SyncTurnState.fromJson(
            json
          );
                case 'promptSend':
          return SyncPromptSend.fromJson(
            json
          );
                case 'approvalRespond':
          return SyncApprovalRespond.fromJson(
            json
          );
                case 'questionsRespond':
          return SyncQuestionsRespond.fromJson(
            json
          );
                case 'turnAbort':
          return SyncTurnAbort.fromJson(
            json
          );
                case 'turnResume':
          return SyncTurnResume.fromJson(
            json
          );
        
          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'SyncMessage',
  'Invalid union type "${json['runtimeType']}"!'
);
        }
      
}

/// @nodoc
mixin _$SyncMessage {



  /// Serializes this SyncMessage to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncMessage);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncMessage()';
}


}

/// @nodoc
class $SyncMessageCopyWith<$Res>  {
$SyncMessageCopyWith(SyncMessage _, $Res Function(SyncMessage) __);
}


/// Adds pattern-matching-related methods to [SyncMessage].
extension SyncMessagePatterns on SyncMessage {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SyncWelcome value)?  welcome,TResult Function( SyncChatsChanged value)?  chatsChanged,TResult Function( SyncChatOpen value)?  chatOpen,TResult Function( SyncChatSnapshot value)?  chatSnapshot,TResult Function( SyncRecordAppend value)?  recordAppend,TResult Function( SyncStateDiff value)?  stateDiff,TResult Function( SyncMetaPatch value)?  metaPatch,TResult Function( SyncChatDeleted value)?  chatDeleted,TResult Function( SyncChatMoved value)?  chatMoved,TResult Function( SyncResourceRequest value)?  resourceRequest,TResult Function( SyncResourceChunk value)?  resourceChunk,TResult Function( SyncPing value)?  ping,TResult Function( SyncPong value)?  pong,TResult Function( SyncControlState value)?  controlState,TResult Function( SyncControlRequest value)?  controlRequest,TResult Function( SyncControlGrant value)?  controlGrant,TResult Function( SyncControlRelease value)?  controlRelease,TResult Function( SyncTurnState value)?  turnState,TResult Function( SyncPromptSend value)?  promptSend,TResult Function( SyncApprovalRespond value)?  approvalRespond,TResult Function( SyncQuestionsRespond value)?  questionsRespond,TResult Function( SyncTurnAbort value)?  turnAbort,TResult Function( SyncTurnResume value)?  turnResume,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SyncWelcome() when welcome != null:
return welcome(_that);case SyncChatsChanged() when chatsChanged != null:
return chatsChanged(_that);case SyncChatOpen() when chatOpen != null:
return chatOpen(_that);case SyncChatSnapshot() when chatSnapshot != null:
return chatSnapshot(_that);case SyncRecordAppend() when recordAppend != null:
return recordAppend(_that);case SyncStateDiff() when stateDiff != null:
return stateDiff(_that);case SyncMetaPatch() when metaPatch != null:
return metaPatch(_that);case SyncChatDeleted() when chatDeleted != null:
return chatDeleted(_that);case SyncChatMoved() when chatMoved != null:
return chatMoved(_that);case SyncResourceRequest() when resourceRequest != null:
return resourceRequest(_that);case SyncResourceChunk() when resourceChunk != null:
return resourceChunk(_that);case SyncPing() when ping != null:
return ping(_that);case SyncPong() when pong != null:
return pong(_that);case SyncControlState() when controlState != null:
return controlState(_that);case SyncControlRequest() when controlRequest != null:
return controlRequest(_that);case SyncControlGrant() when controlGrant != null:
return controlGrant(_that);case SyncControlRelease() when controlRelease != null:
return controlRelease(_that);case SyncTurnState() when turnState != null:
return turnState(_that);case SyncPromptSend() when promptSend != null:
return promptSend(_that);case SyncApprovalRespond() when approvalRespond != null:
return approvalRespond(_that);case SyncQuestionsRespond() when questionsRespond != null:
return questionsRespond(_that);case SyncTurnAbort() when turnAbort != null:
return turnAbort(_that);case SyncTurnResume() when turnResume != null:
return turnResume(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SyncWelcome value)  welcome,required TResult Function( SyncChatsChanged value)  chatsChanged,required TResult Function( SyncChatOpen value)  chatOpen,required TResult Function( SyncChatSnapshot value)  chatSnapshot,required TResult Function( SyncRecordAppend value)  recordAppend,required TResult Function( SyncStateDiff value)  stateDiff,required TResult Function( SyncMetaPatch value)  metaPatch,required TResult Function( SyncChatDeleted value)  chatDeleted,required TResult Function( SyncChatMoved value)  chatMoved,required TResult Function( SyncResourceRequest value)  resourceRequest,required TResult Function( SyncResourceChunk value)  resourceChunk,required TResult Function( SyncPing value)  ping,required TResult Function( SyncPong value)  pong,required TResult Function( SyncControlState value)  controlState,required TResult Function( SyncControlRequest value)  controlRequest,required TResult Function( SyncControlGrant value)  controlGrant,required TResult Function( SyncControlRelease value)  controlRelease,required TResult Function( SyncTurnState value)  turnState,required TResult Function( SyncPromptSend value)  promptSend,required TResult Function( SyncApprovalRespond value)  approvalRespond,required TResult Function( SyncQuestionsRespond value)  questionsRespond,required TResult Function( SyncTurnAbort value)  turnAbort,required TResult Function( SyncTurnResume value)  turnResume,}){
final _that = this;
switch (_that) {
case SyncWelcome():
return welcome(_that);case SyncChatsChanged():
return chatsChanged(_that);case SyncChatOpen():
return chatOpen(_that);case SyncChatSnapshot():
return chatSnapshot(_that);case SyncRecordAppend():
return recordAppend(_that);case SyncStateDiff():
return stateDiff(_that);case SyncMetaPatch():
return metaPatch(_that);case SyncChatDeleted():
return chatDeleted(_that);case SyncChatMoved():
return chatMoved(_that);case SyncResourceRequest():
return resourceRequest(_that);case SyncResourceChunk():
return resourceChunk(_that);case SyncPing():
return ping(_that);case SyncPong():
return pong(_that);case SyncControlState():
return controlState(_that);case SyncControlRequest():
return controlRequest(_that);case SyncControlGrant():
return controlGrant(_that);case SyncControlRelease():
return controlRelease(_that);case SyncTurnState():
return turnState(_that);case SyncPromptSend():
return promptSend(_that);case SyncApprovalRespond():
return approvalRespond(_that);case SyncQuestionsRespond():
return questionsRespond(_that);case SyncTurnAbort():
return turnAbort(_that);case SyncTurnResume():
return turnResume(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SyncWelcome value)?  welcome,TResult? Function( SyncChatsChanged value)?  chatsChanged,TResult? Function( SyncChatOpen value)?  chatOpen,TResult? Function( SyncChatSnapshot value)?  chatSnapshot,TResult? Function( SyncRecordAppend value)?  recordAppend,TResult? Function( SyncStateDiff value)?  stateDiff,TResult? Function( SyncMetaPatch value)?  metaPatch,TResult? Function( SyncChatDeleted value)?  chatDeleted,TResult? Function( SyncChatMoved value)?  chatMoved,TResult? Function( SyncResourceRequest value)?  resourceRequest,TResult? Function( SyncResourceChunk value)?  resourceChunk,TResult? Function( SyncPing value)?  ping,TResult? Function( SyncPong value)?  pong,TResult? Function( SyncControlState value)?  controlState,TResult? Function( SyncControlRequest value)?  controlRequest,TResult? Function( SyncControlGrant value)?  controlGrant,TResult? Function( SyncControlRelease value)?  controlRelease,TResult? Function( SyncTurnState value)?  turnState,TResult? Function( SyncPromptSend value)?  promptSend,TResult? Function( SyncApprovalRespond value)?  approvalRespond,TResult? Function( SyncQuestionsRespond value)?  questionsRespond,TResult? Function( SyncTurnAbort value)?  turnAbort,TResult? Function( SyncTurnResume value)?  turnResume,}){
final _that = this;
switch (_that) {
case SyncWelcome() when welcome != null:
return welcome(_that);case SyncChatsChanged() when chatsChanged != null:
return chatsChanged(_that);case SyncChatOpen() when chatOpen != null:
return chatOpen(_that);case SyncChatSnapshot() when chatSnapshot != null:
return chatSnapshot(_that);case SyncRecordAppend() when recordAppend != null:
return recordAppend(_that);case SyncStateDiff() when stateDiff != null:
return stateDiff(_that);case SyncMetaPatch() when metaPatch != null:
return metaPatch(_that);case SyncChatDeleted() when chatDeleted != null:
return chatDeleted(_that);case SyncChatMoved() when chatMoved != null:
return chatMoved(_that);case SyncResourceRequest() when resourceRequest != null:
return resourceRequest(_that);case SyncResourceChunk() when resourceChunk != null:
return resourceChunk(_that);case SyncPing() when ping != null:
return ping(_that);case SyncPong() when pong != null:
return pong(_that);case SyncControlState() when controlState != null:
return controlState(_that);case SyncControlRequest() when controlRequest != null:
return controlRequest(_that);case SyncControlGrant() when controlGrant != null:
return controlGrant(_that);case SyncControlRelease() when controlRelease != null:
return controlRelease(_that);case SyncTurnState() when turnState != null:
return turnState(_that);case SyncPromptSend() when promptSend != null:
return promptSend(_that);case SyncApprovalRespond() when approvalRespond != null:
return approvalRespond(_that);case SyncQuestionsRespond() when questionsRespond != null:
return questionsRespond(_that);case SyncTurnAbort() when turnAbort != null:
return turnAbort(_that);case SyncTurnResume() when turnResume != null:
return turnResume(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( List<ChatState> chats,  int proto)?  welcome,TResult Function( List<ChatState> chats)?  chatsChanged,TResult Function( String chatId,  int fromLine)?  chatOpen,TResult Function( String chatId,  ChatState state,  ChatMeta meta,  int totalLines)?  chatSnapshot,TResult Function( String chatId,  List<ChatRecord> records)?  recordAppend,TResult Function( String chatId,  ChatState state)?  stateDiff,TResult Function( String chatId,  ChatMeta meta)?  metaPatch,TResult Function( String chatId)?  chatDeleted,TResult Function( String chatId,  String? project)?  chatMoved,TResult Function( String id,  String chatId,  String resource)?  resourceRequest,TResult Function( String id,  String bytesB64,  bool done)?  resourceChunk,TResult Function()?  ping,TResult Function()?  pong,TResult Function( String chatId,  String? holder)?  controlState,TResult Function( String chatId)?  controlRequest,TResult Function( String chatId,  bool granted)?  controlGrant,TResult Function( String chatId)?  controlRelease,TResult Function( String chatId,  bool running,  List<ToolApproval> approvals,  List<SyncAsk> asks,  String? status,  String? retry)?  turnState,TResult Function( String chatId,  String text)?  promptSend,TResult Function( String chatId,  String approvalId,  bool allow)?  approvalRespond,TResult Function( String chatId,  String requestId,  List<String?> answers)?  questionsRespond,TResult Function( String chatId)?  turnAbort,TResult Function( String chatId)?  turnResume,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SyncWelcome() when welcome != null:
return welcome(_that.chats,_that.proto);case SyncChatsChanged() when chatsChanged != null:
return chatsChanged(_that.chats);case SyncChatOpen() when chatOpen != null:
return chatOpen(_that.chatId,_that.fromLine);case SyncChatSnapshot() when chatSnapshot != null:
return chatSnapshot(_that.chatId,_that.state,_that.meta,_that.totalLines);case SyncRecordAppend() when recordAppend != null:
return recordAppend(_that.chatId,_that.records);case SyncStateDiff() when stateDiff != null:
return stateDiff(_that.chatId,_that.state);case SyncMetaPatch() when metaPatch != null:
return metaPatch(_that.chatId,_that.meta);case SyncChatDeleted() when chatDeleted != null:
return chatDeleted(_that.chatId);case SyncChatMoved() when chatMoved != null:
return chatMoved(_that.chatId,_that.project);case SyncResourceRequest() when resourceRequest != null:
return resourceRequest(_that.id,_that.chatId,_that.resource);case SyncResourceChunk() when resourceChunk != null:
return resourceChunk(_that.id,_that.bytesB64,_that.done);case SyncPing() when ping != null:
return ping();case SyncPong() when pong != null:
return pong();case SyncControlState() when controlState != null:
return controlState(_that.chatId,_that.holder);case SyncControlRequest() when controlRequest != null:
return controlRequest(_that.chatId);case SyncControlGrant() when controlGrant != null:
return controlGrant(_that.chatId,_that.granted);case SyncControlRelease() when controlRelease != null:
return controlRelease(_that.chatId);case SyncTurnState() when turnState != null:
return turnState(_that.chatId,_that.running,_that.approvals,_that.asks,_that.status,_that.retry);case SyncPromptSend() when promptSend != null:
return promptSend(_that.chatId,_that.text);case SyncApprovalRespond() when approvalRespond != null:
return approvalRespond(_that.chatId,_that.approvalId,_that.allow);case SyncQuestionsRespond() when questionsRespond != null:
return questionsRespond(_that.chatId,_that.requestId,_that.answers);case SyncTurnAbort() when turnAbort != null:
return turnAbort(_that.chatId);case SyncTurnResume() when turnResume != null:
return turnResume(_that.chatId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( List<ChatState> chats,  int proto)  welcome,required TResult Function( List<ChatState> chats)  chatsChanged,required TResult Function( String chatId,  int fromLine)  chatOpen,required TResult Function( String chatId,  ChatState state,  ChatMeta meta,  int totalLines)  chatSnapshot,required TResult Function( String chatId,  List<ChatRecord> records)  recordAppend,required TResult Function( String chatId,  ChatState state)  stateDiff,required TResult Function( String chatId,  ChatMeta meta)  metaPatch,required TResult Function( String chatId)  chatDeleted,required TResult Function( String chatId,  String? project)  chatMoved,required TResult Function( String id,  String chatId,  String resource)  resourceRequest,required TResult Function( String id,  String bytesB64,  bool done)  resourceChunk,required TResult Function()  ping,required TResult Function()  pong,required TResult Function( String chatId,  String? holder)  controlState,required TResult Function( String chatId)  controlRequest,required TResult Function( String chatId,  bool granted)  controlGrant,required TResult Function( String chatId)  controlRelease,required TResult Function( String chatId,  bool running,  List<ToolApproval> approvals,  List<SyncAsk> asks,  String? status,  String? retry)  turnState,required TResult Function( String chatId,  String text)  promptSend,required TResult Function( String chatId,  String approvalId,  bool allow)  approvalRespond,required TResult Function( String chatId,  String requestId,  List<String?> answers)  questionsRespond,required TResult Function( String chatId)  turnAbort,required TResult Function( String chatId)  turnResume,}) {final _that = this;
switch (_that) {
case SyncWelcome():
return welcome(_that.chats,_that.proto);case SyncChatsChanged():
return chatsChanged(_that.chats);case SyncChatOpen():
return chatOpen(_that.chatId,_that.fromLine);case SyncChatSnapshot():
return chatSnapshot(_that.chatId,_that.state,_that.meta,_that.totalLines);case SyncRecordAppend():
return recordAppend(_that.chatId,_that.records);case SyncStateDiff():
return stateDiff(_that.chatId,_that.state);case SyncMetaPatch():
return metaPatch(_that.chatId,_that.meta);case SyncChatDeleted():
return chatDeleted(_that.chatId);case SyncChatMoved():
return chatMoved(_that.chatId,_that.project);case SyncResourceRequest():
return resourceRequest(_that.id,_that.chatId,_that.resource);case SyncResourceChunk():
return resourceChunk(_that.id,_that.bytesB64,_that.done);case SyncPing():
return ping();case SyncPong():
return pong();case SyncControlState():
return controlState(_that.chatId,_that.holder);case SyncControlRequest():
return controlRequest(_that.chatId);case SyncControlGrant():
return controlGrant(_that.chatId,_that.granted);case SyncControlRelease():
return controlRelease(_that.chatId);case SyncTurnState():
return turnState(_that.chatId,_that.running,_that.approvals,_that.asks,_that.status,_that.retry);case SyncPromptSend():
return promptSend(_that.chatId,_that.text);case SyncApprovalRespond():
return approvalRespond(_that.chatId,_that.approvalId,_that.allow);case SyncQuestionsRespond():
return questionsRespond(_that.chatId,_that.requestId,_that.answers);case SyncTurnAbort():
return turnAbort(_that.chatId);case SyncTurnResume():
return turnResume(_that.chatId);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( List<ChatState> chats,  int proto)?  welcome,TResult? Function( List<ChatState> chats)?  chatsChanged,TResult? Function( String chatId,  int fromLine)?  chatOpen,TResult? Function( String chatId,  ChatState state,  ChatMeta meta,  int totalLines)?  chatSnapshot,TResult? Function( String chatId,  List<ChatRecord> records)?  recordAppend,TResult? Function( String chatId,  ChatState state)?  stateDiff,TResult? Function( String chatId,  ChatMeta meta)?  metaPatch,TResult? Function( String chatId)?  chatDeleted,TResult? Function( String chatId,  String? project)?  chatMoved,TResult? Function( String id,  String chatId,  String resource)?  resourceRequest,TResult? Function( String id,  String bytesB64,  bool done)?  resourceChunk,TResult? Function()?  ping,TResult? Function()?  pong,TResult? Function( String chatId,  String? holder)?  controlState,TResult? Function( String chatId)?  controlRequest,TResult? Function( String chatId,  bool granted)?  controlGrant,TResult? Function( String chatId)?  controlRelease,TResult? Function( String chatId,  bool running,  List<ToolApproval> approvals,  List<SyncAsk> asks,  String? status,  String? retry)?  turnState,TResult? Function( String chatId,  String text)?  promptSend,TResult? Function( String chatId,  String approvalId,  bool allow)?  approvalRespond,TResult? Function( String chatId,  String requestId,  List<String?> answers)?  questionsRespond,TResult? Function( String chatId)?  turnAbort,TResult? Function( String chatId)?  turnResume,}) {final _that = this;
switch (_that) {
case SyncWelcome() when welcome != null:
return welcome(_that.chats,_that.proto);case SyncChatsChanged() when chatsChanged != null:
return chatsChanged(_that.chats);case SyncChatOpen() when chatOpen != null:
return chatOpen(_that.chatId,_that.fromLine);case SyncChatSnapshot() when chatSnapshot != null:
return chatSnapshot(_that.chatId,_that.state,_that.meta,_that.totalLines);case SyncRecordAppend() when recordAppend != null:
return recordAppend(_that.chatId,_that.records);case SyncStateDiff() when stateDiff != null:
return stateDiff(_that.chatId,_that.state);case SyncMetaPatch() when metaPatch != null:
return metaPatch(_that.chatId,_that.meta);case SyncChatDeleted() when chatDeleted != null:
return chatDeleted(_that.chatId);case SyncChatMoved() when chatMoved != null:
return chatMoved(_that.chatId,_that.project);case SyncResourceRequest() when resourceRequest != null:
return resourceRequest(_that.id,_that.chatId,_that.resource);case SyncResourceChunk() when resourceChunk != null:
return resourceChunk(_that.id,_that.bytesB64,_that.done);case SyncPing() when ping != null:
return ping();case SyncPong() when pong != null:
return pong();case SyncControlState() when controlState != null:
return controlState(_that.chatId,_that.holder);case SyncControlRequest() when controlRequest != null:
return controlRequest(_that.chatId);case SyncControlGrant() when controlGrant != null:
return controlGrant(_that.chatId,_that.granted);case SyncControlRelease() when controlRelease != null:
return controlRelease(_that.chatId);case SyncTurnState() when turnState != null:
return turnState(_that.chatId,_that.running,_that.approvals,_that.asks,_that.status,_that.retry);case SyncPromptSend() when promptSend != null:
return promptSend(_that.chatId,_that.text);case SyncApprovalRespond() when approvalRespond != null:
return approvalRespond(_that.chatId,_that.approvalId,_that.allow);case SyncQuestionsRespond() when questionsRespond != null:
return questionsRespond(_that.chatId,_that.requestId,_that.answers);case SyncTurnAbort() when turnAbort != null:
return turnAbort(_that.chatId);case SyncTurnResume() when turnResume != null:
return turnResume(_that.chatId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class SyncWelcome implements SyncMessage {
  const SyncWelcome({required final  List<ChatState> chats, this.proto = SyncIdentity.protocolVersion, final  String? $type}): _chats = chats,$type = $type ?? 'welcome';
  factory SyncWelcome.fromJson(Map<String, dynamic> json) => _$SyncWelcomeFromJson(json);

 final  List<ChatState> _chats;
 List<ChatState> get chats {
  if (_chats is EqualUnmodifiableListView) return _chats;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_chats);
}

@JsonKey() final  int proto;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncWelcomeCopyWith<SyncWelcome> get copyWith => _$SyncWelcomeCopyWithImpl<SyncWelcome>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncWelcomeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncWelcome&&const DeepCollectionEquality().equals(other._chats, _chats)&&(identical(other.proto, proto) || other.proto == proto));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_chats),proto);

@override
String toString() {
  return 'SyncMessage.welcome(chats: $chats, proto: $proto)';
}


}

/// @nodoc
abstract mixin class $SyncWelcomeCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncWelcomeCopyWith(SyncWelcome value, $Res Function(SyncWelcome) _then) = _$SyncWelcomeCopyWithImpl;
@useResult
$Res call({
 List<ChatState> chats, int proto
});




}
/// @nodoc
class _$SyncWelcomeCopyWithImpl<$Res>
    implements $SyncWelcomeCopyWith<$Res> {
  _$SyncWelcomeCopyWithImpl(this._self, this._then);

  final SyncWelcome _self;
  final $Res Function(SyncWelcome) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chats = null,Object? proto = null,}) {
  return _then(SyncWelcome(
chats: null == chats ? _self._chats : chats // ignore: cast_nullable_to_non_nullable
as List<ChatState>,proto: null == proto ? _self.proto : proto // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncChatsChanged implements SyncMessage {
  const SyncChatsChanged({required final  List<ChatState> chats, final  String? $type}): _chats = chats,$type = $type ?? 'chatsChanged';
  factory SyncChatsChanged.fromJson(Map<String, dynamic> json) => _$SyncChatsChangedFromJson(json);

 final  List<ChatState> _chats;
 List<ChatState> get chats {
  if (_chats is EqualUnmodifiableListView) return _chats;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_chats);
}


@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncChatsChangedCopyWith<SyncChatsChanged> get copyWith => _$SyncChatsChangedCopyWithImpl<SyncChatsChanged>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncChatsChangedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncChatsChanged&&const DeepCollectionEquality().equals(other._chats, _chats));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(_chats));

@override
String toString() {
  return 'SyncMessage.chatsChanged(chats: $chats)';
}


}

/// @nodoc
abstract mixin class $SyncChatsChangedCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncChatsChangedCopyWith(SyncChatsChanged value, $Res Function(SyncChatsChanged) _then) = _$SyncChatsChangedCopyWithImpl;
@useResult
$Res call({
 List<ChatState> chats
});




}
/// @nodoc
class _$SyncChatsChangedCopyWithImpl<$Res>
    implements $SyncChatsChangedCopyWith<$Res> {
  _$SyncChatsChangedCopyWithImpl(this._self, this._then);

  final SyncChatsChanged _self;
  final $Res Function(SyncChatsChanged) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chats = null,}) {
  return _then(SyncChatsChanged(
chats: null == chats ? _self._chats : chats // ignore: cast_nullable_to_non_nullable
as List<ChatState>,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncChatOpen implements SyncMessage {
  const SyncChatOpen({required this.chatId, this.fromLine = 0, final  String? $type}): $type = $type ?? 'chatOpen';
  factory SyncChatOpen.fromJson(Map<String, dynamic> json) => _$SyncChatOpenFromJson(json);

 final  String chatId;
@JsonKey() final  int fromLine;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncChatOpenCopyWith<SyncChatOpen> get copyWith => _$SyncChatOpenCopyWithImpl<SyncChatOpen>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncChatOpenToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncChatOpen&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.fromLine, fromLine) || other.fromLine == fromLine));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,fromLine);

@override
String toString() {
  return 'SyncMessage.chatOpen(chatId: $chatId, fromLine: $fromLine)';
}


}

/// @nodoc
abstract mixin class $SyncChatOpenCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncChatOpenCopyWith(SyncChatOpen value, $Res Function(SyncChatOpen) _then) = _$SyncChatOpenCopyWithImpl;
@useResult
$Res call({
 String chatId, int fromLine
});




}
/// @nodoc
class _$SyncChatOpenCopyWithImpl<$Res>
    implements $SyncChatOpenCopyWith<$Res> {
  _$SyncChatOpenCopyWithImpl(this._self, this._then);

  final SyncChatOpen _self;
  final $Res Function(SyncChatOpen) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? fromLine = null,}) {
  return _then(SyncChatOpen(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,fromLine: null == fromLine ? _self.fromLine : fromLine // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncChatSnapshot implements SyncMessage {
  const SyncChatSnapshot({required this.chatId, required this.state, required this.meta, required this.totalLines, final  String? $type}): $type = $type ?? 'chatSnapshot';
  factory SyncChatSnapshot.fromJson(Map<String, dynamic> json) => _$SyncChatSnapshotFromJson(json);

 final  String chatId;
 final  ChatState state;
 final  ChatMeta meta;
 final  int totalLines;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncChatSnapshotCopyWith<SyncChatSnapshot> get copyWith => _$SyncChatSnapshotCopyWithImpl<SyncChatSnapshot>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncChatSnapshotToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncChatSnapshot&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.state, state) || other.state == state)&&(identical(other.meta, meta) || other.meta == meta)&&(identical(other.totalLines, totalLines) || other.totalLines == totalLines));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,state,meta,totalLines);

@override
String toString() {
  return 'SyncMessage.chatSnapshot(chatId: $chatId, state: $state, meta: $meta, totalLines: $totalLines)';
}


}

/// @nodoc
abstract mixin class $SyncChatSnapshotCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncChatSnapshotCopyWith(SyncChatSnapshot value, $Res Function(SyncChatSnapshot) _then) = _$SyncChatSnapshotCopyWithImpl;
@useResult
$Res call({
 String chatId, ChatState state, ChatMeta meta, int totalLines
});


$ChatStateCopyWith<$Res> get state;

}
/// @nodoc
class _$SyncChatSnapshotCopyWithImpl<$Res>
    implements $SyncChatSnapshotCopyWith<$Res> {
  _$SyncChatSnapshotCopyWithImpl(this._self, this._then);

  final SyncChatSnapshot _self;
  final $Res Function(SyncChatSnapshot) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? state = null,Object? meta = null,Object? totalLines = null,}) {
  return _then(SyncChatSnapshot(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as ChatState,meta: null == meta ? _self.meta : meta // ignore: cast_nullable_to_non_nullable
as ChatMeta,totalLines: null == totalLines ? _self.totalLines : totalLines // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ChatStateCopyWith<$Res> get state {
  
  return $ChatStateCopyWith<$Res>(_self.state, (value) {
    return _then(_self.copyWith(state: value));
  });
}
}

/// @nodoc
@JsonSerializable()

class SyncRecordAppend implements SyncMessage {
  const SyncRecordAppend({required this.chatId, required final  List<ChatRecord> records, final  String? $type}): _records = records,$type = $type ?? 'recordAppend';
  factory SyncRecordAppend.fromJson(Map<String, dynamic> json) => _$SyncRecordAppendFromJson(json);

 final  String chatId;
 final  List<ChatRecord> _records;
 List<ChatRecord> get records {
  if (_records is EqualUnmodifiableListView) return _records;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_records);
}


@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncRecordAppendCopyWith<SyncRecordAppend> get copyWith => _$SyncRecordAppendCopyWithImpl<SyncRecordAppend>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncRecordAppendToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncRecordAppend&&(identical(other.chatId, chatId) || other.chatId == chatId)&&const DeepCollectionEquality().equals(other._records, _records));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,const DeepCollectionEquality().hash(_records));

@override
String toString() {
  return 'SyncMessage.recordAppend(chatId: $chatId, records: $records)';
}


}

/// @nodoc
abstract mixin class $SyncRecordAppendCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncRecordAppendCopyWith(SyncRecordAppend value, $Res Function(SyncRecordAppend) _then) = _$SyncRecordAppendCopyWithImpl;
@useResult
$Res call({
 String chatId, List<ChatRecord> records
});




}
/// @nodoc
class _$SyncRecordAppendCopyWithImpl<$Res>
    implements $SyncRecordAppendCopyWith<$Res> {
  _$SyncRecordAppendCopyWithImpl(this._self, this._then);

  final SyncRecordAppend _self;
  final $Res Function(SyncRecordAppend) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? records = null,}) {
  return _then(SyncRecordAppend(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,records: null == records ? _self._records : records // ignore: cast_nullable_to_non_nullable
as List<ChatRecord>,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncStateDiff implements SyncMessage {
  const SyncStateDiff({required this.chatId, required this.state, final  String? $type}): $type = $type ?? 'stateDiff';
  factory SyncStateDiff.fromJson(Map<String, dynamic> json) => _$SyncStateDiffFromJson(json);

 final  String chatId;
 final  ChatState state;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncStateDiffCopyWith<SyncStateDiff> get copyWith => _$SyncStateDiffCopyWithImpl<SyncStateDiff>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncStateDiffToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncStateDiff&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.state, state) || other.state == state));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,state);

@override
String toString() {
  return 'SyncMessage.stateDiff(chatId: $chatId, state: $state)';
}


}

/// @nodoc
abstract mixin class $SyncStateDiffCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncStateDiffCopyWith(SyncStateDiff value, $Res Function(SyncStateDiff) _then) = _$SyncStateDiffCopyWithImpl;
@useResult
$Res call({
 String chatId, ChatState state
});


$ChatStateCopyWith<$Res> get state;

}
/// @nodoc
class _$SyncStateDiffCopyWithImpl<$Res>
    implements $SyncStateDiffCopyWith<$Res> {
  _$SyncStateDiffCopyWithImpl(this._self, this._then);

  final SyncStateDiff _self;
  final $Res Function(SyncStateDiff) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? state = null,}) {
  return _then(SyncStateDiff(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as ChatState,
  ));
}

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ChatStateCopyWith<$Res> get state {
  
  return $ChatStateCopyWith<$Res>(_self.state, (value) {
    return _then(_self.copyWith(state: value));
  });
}
}

/// @nodoc
@JsonSerializable()

class SyncMetaPatch implements SyncMessage {
  const SyncMetaPatch({required this.chatId, required this.meta, final  String? $type}): $type = $type ?? 'metaPatch';
  factory SyncMetaPatch.fromJson(Map<String, dynamic> json) => _$SyncMetaPatchFromJson(json);

 final  String chatId;
 final  ChatMeta meta;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncMetaPatchCopyWith<SyncMetaPatch> get copyWith => _$SyncMetaPatchCopyWithImpl<SyncMetaPatch>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncMetaPatchToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncMetaPatch&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.meta, meta) || other.meta == meta));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,meta);

@override
String toString() {
  return 'SyncMessage.metaPatch(chatId: $chatId, meta: $meta)';
}


}

/// @nodoc
abstract mixin class $SyncMetaPatchCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncMetaPatchCopyWith(SyncMetaPatch value, $Res Function(SyncMetaPatch) _then) = _$SyncMetaPatchCopyWithImpl;
@useResult
$Res call({
 String chatId, ChatMeta meta
});




}
/// @nodoc
class _$SyncMetaPatchCopyWithImpl<$Res>
    implements $SyncMetaPatchCopyWith<$Res> {
  _$SyncMetaPatchCopyWithImpl(this._self, this._then);

  final SyncMetaPatch _self;
  final $Res Function(SyncMetaPatch) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? meta = null,}) {
  return _then(SyncMetaPatch(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,meta: null == meta ? _self.meta : meta // ignore: cast_nullable_to_non_nullable
as ChatMeta,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncChatDeleted implements SyncMessage {
  const SyncChatDeleted({required this.chatId, final  String? $type}): $type = $type ?? 'chatDeleted';
  factory SyncChatDeleted.fromJson(Map<String, dynamic> json) => _$SyncChatDeletedFromJson(json);

 final  String chatId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncChatDeletedCopyWith<SyncChatDeleted> get copyWith => _$SyncChatDeletedCopyWithImpl<SyncChatDeleted>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncChatDeletedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncChatDeleted&&(identical(other.chatId, chatId) || other.chatId == chatId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId);

@override
String toString() {
  return 'SyncMessage.chatDeleted(chatId: $chatId)';
}


}

/// @nodoc
abstract mixin class $SyncChatDeletedCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncChatDeletedCopyWith(SyncChatDeleted value, $Res Function(SyncChatDeleted) _then) = _$SyncChatDeletedCopyWithImpl;
@useResult
$Res call({
 String chatId
});




}
/// @nodoc
class _$SyncChatDeletedCopyWithImpl<$Res>
    implements $SyncChatDeletedCopyWith<$Res> {
  _$SyncChatDeletedCopyWithImpl(this._self, this._then);

  final SyncChatDeleted _self;
  final $Res Function(SyncChatDeleted) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,}) {
  return _then(SyncChatDeleted(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncChatMoved implements SyncMessage {
  const SyncChatMoved({required this.chatId, this.project, final  String? $type}): $type = $type ?? 'chatMoved';
  factory SyncChatMoved.fromJson(Map<String, dynamic> json) => _$SyncChatMovedFromJson(json);

 final  String chatId;
 final  String? project;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncChatMovedCopyWith<SyncChatMoved> get copyWith => _$SyncChatMovedCopyWithImpl<SyncChatMoved>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncChatMovedToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncChatMoved&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.project, project) || other.project == project));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,project);

@override
String toString() {
  return 'SyncMessage.chatMoved(chatId: $chatId, project: $project)';
}


}

/// @nodoc
abstract mixin class $SyncChatMovedCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncChatMovedCopyWith(SyncChatMoved value, $Res Function(SyncChatMoved) _then) = _$SyncChatMovedCopyWithImpl;
@useResult
$Res call({
 String chatId, String? project
});




}
/// @nodoc
class _$SyncChatMovedCopyWithImpl<$Res>
    implements $SyncChatMovedCopyWith<$Res> {
  _$SyncChatMovedCopyWithImpl(this._self, this._then);

  final SyncChatMoved _self;
  final $Res Function(SyncChatMoved) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? project = freezed,}) {
  return _then(SyncChatMoved(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncResourceRequest implements SyncMessage {
  const SyncResourceRequest({required this.id, required this.chatId, required this.resource, final  String? $type}): $type = $type ?? 'resourceRequest';
  factory SyncResourceRequest.fromJson(Map<String, dynamic> json) => _$SyncResourceRequestFromJson(json);

 final  String id;
 final  String chatId;
 final  String resource;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncResourceRequestCopyWith<SyncResourceRequest> get copyWith => _$SyncResourceRequestCopyWithImpl<SyncResourceRequest>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncResourceRequestToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncResourceRequest&&(identical(other.id, id) || other.id == id)&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.resource, resource) || other.resource == resource));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,chatId,resource);

@override
String toString() {
  return 'SyncMessage.resourceRequest(id: $id, chatId: $chatId, resource: $resource)';
}


}

/// @nodoc
abstract mixin class $SyncResourceRequestCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncResourceRequestCopyWith(SyncResourceRequest value, $Res Function(SyncResourceRequest) _then) = _$SyncResourceRequestCopyWithImpl;
@useResult
$Res call({
 String id, String chatId, String resource
});




}
/// @nodoc
class _$SyncResourceRequestCopyWithImpl<$Res>
    implements $SyncResourceRequestCopyWith<$Res> {
  _$SyncResourceRequestCopyWithImpl(this._self, this._then);

  final SyncResourceRequest _self;
  final $Res Function(SyncResourceRequest) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? chatId = null,Object? resource = null,}) {
  return _then(SyncResourceRequest(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,resource: null == resource ? _self.resource : resource // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncResourceChunk implements SyncMessage {
  const SyncResourceChunk({required this.id, required this.bytesB64, this.done = false, final  String? $type}): $type = $type ?? 'resourceChunk';
  factory SyncResourceChunk.fromJson(Map<String, dynamic> json) => _$SyncResourceChunkFromJson(json);

 final  String id;
 final  String bytesB64;
@JsonKey() final  bool done;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncResourceChunkCopyWith<SyncResourceChunk> get copyWith => _$SyncResourceChunkCopyWithImpl<SyncResourceChunk>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncResourceChunkToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncResourceChunk&&(identical(other.id, id) || other.id == id)&&(identical(other.bytesB64, bytesB64) || other.bytesB64 == bytesB64)&&(identical(other.done, done) || other.done == done));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,bytesB64,done);

@override
String toString() {
  return 'SyncMessage.resourceChunk(id: $id, bytesB64: $bytesB64, done: $done)';
}


}

/// @nodoc
abstract mixin class $SyncResourceChunkCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncResourceChunkCopyWith(SyncResourceChunk value, $Res Function(SyncResourceChunk) _then) = _$SyncResourceChunkCopyWithImpl;
@useResult
$Res call({
 String id, String bytesB64, bool done
});




}
/// @nodoc
class _$SyncResourceChunkCopyWithImpl<$Res>
    implements $SyncResourceChunkCopyWith<$Res> {
  _$SyncResourceChunkCopyWithImpl(this._self, this._then);

  final SyncResourceChunk _self;
  final $Res Function(SyncResourceChunk) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? bytesB64 = null,Object? done = null,}) {
  return _then(SyncResourceChunk(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,bytesB64: null == bytesB64 ? _self.bytesB64 : bytesB64 // ignore: cast_nullable_to_non_nullable
as String,done: null == done ? _self.done : done // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncPing implements SyncMessage {
  const SyncPing({final  String? $type}): $type = $type ?? 'ping';
  factory SyncPing.fromJson(Map<String, dynamic> json) => _$SyncPingFromJson(json);



@JsonKey(name: 'runtimeType')
final String $type;



@override
Map<String, dynamic> toJson() {
  return _$SyncPingToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncPing);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncMessage.ping()';
}


}




/// @nodoc
@JsonSerializable()

class SyncPong implements SyncMessage {
  const SyncPong({final  String? $type}): $type = $type ?? 'pong';
  factory SyncPong.fromJson(Map<String, dynamic> json) => _$SyncPongFromJson(json);



@JsonKey(name: 'runtimeType')
final String $type;



@override
Map<String, dynamic> toJson() {
  return _$SyncPongToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncPong);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncMessage.pong()';
}


}




/// @nodoc
@JsonSerializable()

class SyncControlState implements SyncMessage {
  const SyncControlState({required this.chatId, this.holder, final  String? $type}): $type = $type ?? 'controlState';
  factory SyncControlState.fromJson(Map<String, dynamic> json) => _$SyncControlStateFromJson(json);

 final  String chatId;
 final  String? holder;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncControlStateCopyWith<SyncControlState> get copyWith => _$SyncControlStateCopyWithImpl<SyncControlState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncControlStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncControlState&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.holder, holder) || other.holder == holder));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,holder);

@override
String toString() {
  return 'SyncMessage.controlState(chatId: $chatId, holder: $holder)';
}


}

/// @nodoc
abstract mixin class $SyncControlStateCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncControlStateCopyWith(SyncControlState value, $Res Function(SyncControlState) _then) = _$SyncControlStateCopyWithImpl;
@useResult
$Res call({
 String chatId, String? holder
});




}
/// @nodoc
class _$SyncControlStateCopyWithImpl<$Res>
    implements $SyncControlStateCopyWith<$Res> {
  _$SyncControlStateCopyWithImpl(this._self, this._then);

  final SyncControlState _self;
  final $Res Function(SyncControlState) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? holder = freezed,}) {
  return _then(SyncControlState(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,holder: freezed == holder ? _self.holder : holder // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncControlRequest implements SyncMessage {
  const SyncControlRequest({required this.chatId, final  String? $type}): $type = $type ?? 'controlRequest';
  factory SyncControlRequest.fromJson(Map<String, dynamic> json) => _$SyncControlRequestFromJson(json);

 final  String chatId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncControlRequestCopyWith<SyncControlRequest> get copyWith => _$SyncControlRequestCopyWithImpl<SyncControlRequest>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncControlRequestToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncControlRequest&&(identical(other.chatId, chatId) || other.chatId == chatId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId);

@override
String toString() {
  return 'SyncMessage.controlRequest(chatId: $chatId)';
}


}

/// @nodoc
abstract mixin class $SyncControlRequestCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncControlRequestCopyWith(SyncControlRequest value, $Res Function(SyncControlRequest) _then) = _$SyncControlRequestCopyWithImpl;
@useResult
$Res call({
 String chatId
});




}
/// @nodoc
class _$SyncControlRequestCopyWithImpl<$Res>
    implements $SyncControlRequestCopyWith<$Res> {
  _$SyncControlRequestCopyWithImpl(this._self, this._then);

  final SyncControlRequest _self;
  final $Res Function(SyncControlRequest) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,}) {
  return _then(SyncControlRequest(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncControlGrant implements SyncMessage {
  const SyncControlGrant({required this.chatId, required this.granted, final  String? $type}): $type = $type ?? 'controlGrant';
  factory SyncControlGrant.fromJson(Map<String, dynamic> json) => _$SyncControlGrantFromJson(json);

 final  String chatId;
 final  bool granted;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncControlGrantCopyWith<SyncControlGrant> get copyWith => _$SyncControlGrantCopyWithImpl<SyncControlGrant>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncControlGrantToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncControlGrant&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.granted, granted) || other.granted == granted));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,granted);

@override
String toString() {
  return 'SyncMessage.controlGrant(chatId: $chatId, granted: $granted)';
}


}

/// @nodoc
abstract mixin class $SyncControlGrantCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncControlGrantCopyWith(SyncControlGrant value, $Res Function(SyncControlGrant) _then) = _$SyncControlGrantCopyWithImpl;
@useResult
$Res call({
 String chatId, bool granted
});




}
/// @nodoc
class _$SyncControlGrantCopyWithImpl<$Res>
    implements $SyncControlGrantCopyWith<$Res> {
  _$SyncControlGrantCopyWithImpl(this._self, this._then);

  final SyncControlGrant _self;
  final $Res Function(SyncControlGrant) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? granted = null,}) {
  return _then(SyncControlGrant(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,granted: null == granted ? _self.granted : granted // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncControlRelease implements SyncMessage {
  const SyncControlRelease({required this.chatId, final  String? $type}): $type = $type ?? 'controlRelease';
  factory SyncControlRelease.fromJson(Map<String, dynamic> json) => _$SyncControlReleaseFromJson(json);

 final  String chatId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncControlReleaseCopyWith<SyncControlRelease> get copyWith => _$SyncControlReleaseCopyWithImpl<SyncControlRelease>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncControlReleaseToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncControlRelease&&(identical(other.chatId, chatId) || other.chatId == chatId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId);

@override
String toString() {
  return 'SyncMessage.controlRelease(chatId: $chatId)';
}


}

/// @nodoc
abstract mixin class $SyncControlReleaseCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncControlReleaseCopyWith(SyncControlRelease value, $Res Function(SyncControlRelease) _then) = _$SyncControlReleaseCopyWithImpl;
@useResult
$Res call({
 String chatId
});




}
/// @nodoc
class _$SyncControlReleaseCopyWithImpl<$Res>
    implements $SyncControlReleaseCopyWith<$Res> {
  _$SyncControlReleaseCopyWithImpl(this._self, this._then);

  final SyncControlRelease _self;
  final $Res Function(SyncControlRelease) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,}) {
  return _then(SyncControlRelease(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncTurnState implements SyncMessage {
  const SyncTurnState({required this.chatId, this.running = false, final  List<ToolApproval> approvals = const <ToolApproval>[], final  List<SyncAsk> asks = const <SyncAsk>[], this.status, this.retry, final  String? $type}): _approvals = approvals,_asks = asks,$type = $type ?? 'turnState';
  factory SyncTurnState.fromJson(Map<String, dynamic> json) => _$SyncTurnStateFromJson(json);

 final  String chatId;
@JsonKey() final  bool running;
 final  List<ToolApproval> _approvals;
@JsonKey() List<ToolApproval> get approvals {
  if (_approvals is EqualUnmodifiableListView) return _approvals;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_approvals);
}

 final  List<SyncAsk> _asks;
@JsonKey() List<SyncAsk> get asks {
  if (_asks is EqualUnmodifiableListView) return _asks;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_asks);
}

 final  String? status;
 final  String? retry;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncTurnStateCopyWith<SyncTurnState> get copyWith => _$SyncTurnStateCopyWithImpl<SyncTurnState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncTurnStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncTurnState&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.running, running) || other.running == running)&&const DeepCollectionEquality().equals(other._approvals, _approvals)&&const DeepCollectionEquality().equals(other._asks, _asks)&&(identical(other.status, status) || other.status == status)&&(identical(other.retry, retry) || other.retry == retry));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,running,const DeepCollectionEquality().hash(_approvals),const DeepCollectionEquality().hash(_asks),status,retry);

@override
String toString() {
  return 'SyncMessage.turnState(chatId: $chatId, running: $running, approvals: $approvals, asks: $asks, status: $status, retry: $retry)';
}


}

/// @nodoc
abstract mixin class $SyncTurnStateCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncTurnStateCopyWith(SyncTurnState value, $Res Function(SyncTurnState) _then) = _$SyncTurnStateCopyWithImpl;
@useResult
$Res call({
 String chatId, bool running, List<ToolApproval> approvals, List<SyncAsk> asks, String? status, String? retry
});




}
/// @nodoc
class _$SyncTurnStateCopyWithImpl<$Res>
    implements $SyncTurnStateCopyWith<$Res> {
  _$SyncTurnStateCopyWithImpl(this._self, this._then);

  final SyncTurnState _self;
  final $Res Function(SyncTurnState) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? running = null,Object? approvals = null,Object? asks = null,Object? status = freezed,Object? retry = freezed,}) {
  return _then(SyncTurnState(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,running: null == running ? _self.running : running // ignore: cast_nullable_to_non_nullable
as bool,approvals: null == approvals ? _self._approvals : approvals // ignore: cast_nullable_to_non_nullable
as List<ToolApproval>,asks: null == asks ? _self._asks : asks // ignore: cast_nullable_to_non_nullable
as List<SyncAsk>,status: freezed == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String?,retry: freezed == retry ? _self.retry : retry // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncPromptSend implements SyncMessage {
  const SyncPromptSend({required this.chatId, required this.text, final  String? $type}): $type = $type ?? 'promptSend';
  factory SyncPromptSend.fromJson(Map<String, dynamic> json) => _$SyncPromptSendFromJson(json);

 final  String chatId;
 final  String text;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncPromptSendCopyWith<SyncPromptSend> get copyWith => _$SyncPromptSendCopyWithImpl<SyncPromptSend>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncPromptSendToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncPromptSend&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.text, text) || other.text == text));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,text);

@override
String toString() {
  return 'SyncMessage.promptSend(chatId: $chatId, text: $text)';
}


}

/// @nodoc
abstract mixin class $SyncPromptSendCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncPromptSendCopyWith(SyncPromptSend value, $Res Function(SyncPromptSend) _then) = _$SyncPromptSendCopyWithImpl;
@useResult
$Res call({
 String chatId, String text
});




}
/// @nodoc
class _$SyncPromptSendCopyWithImpl<$Res>
    implements $SyncPromptSendCopyWith<$Res> {
  _$SyncPromptSendCopyWithImpl(this._self, this._then);

  final SyncPromptSend _self;
  final $Res Function(SyncPromptSend) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? text = null,}) {
  return _then(SyncPromptSend(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncApprovalRespond implements SyncMessage {
  const SyncApprovalRespond({required this.chatId, required this.approvalId, required this.allow, final  String? $type}): $type = $type ?? 'approvalRespond';
  factory SyncApprovalRespond.fromJson(Map<String, dynamic> json) => _$SyncApprovalRespondFromJson(json);

 final  String chatId;
 final  String approvalId;
 final  bool allow;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncApprovalRespondCopyWith<SyncApprovalRespond> get copyWith => _$SyncApprovalRespondCopyWithImpl<SyncApprovalRespond>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncApprovalRespondToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncApprovalRespond&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.approvalId, approvalId) || other.approvalId == approvalId)&&(identical(other.allow, allow) || other.allow == allow));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,approvalId,allow);

@override
String toString() {
  return 'SyncMessage.approvalRespond(chatId: $chatId, approvalId: $approvalId, allow: $allow)';
}


}

/// @nodoc
abstract mixin class $SyncApprovalRespondCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncApprovalRespondCopyWith(SyncApprovalRespond value, $Res Function(SyncApprovalRespond) _then) = _$SyncApprovalRespondCopyWithImpl;
@useResult
$Res call({
 String chatId, String approvalId, bool allow
});




}
/// @nodoc
class _$SyncApprovalRespondCopyWithImpl<$Res>
    implements $SyncApprovalRespondCopyWith<$Res> {
  _$SyncApprovalRespondCopyWithImpl(this._self, this._then);

  final SyncApprovalRespond _self;
  final $Res Function(SyncApprovalRespond) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? approvalId = null,Object? allow = null,}) {
  return _then(SyncApprovalRespond(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,approvalId: null == approvalId ? _self.approvalId : approvalId // ignore: cast_nullable_to_non_nullable
as String,allow: null == allow ? _self.allow : allow // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncQuestionsRespond implements SyncMessage {
  const SyncQuestionsRespond({required this.chatId, required this.requestId, required final  List<String?> answers, final  String? $type}): _answers = answers,$type = $type ?? 'questionsRespond';
  factory SyncQuestionsRespond.fromJson(Map<String, dynamic> json) => _$SyncQuestionsRespondFromJson(json);

 final  String chatId;
 final  String requestId;
 final  List<String?> _answers;
 List<String?> get answers {
  if (_answers is EqualUnmodifiableListView) return _answers;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_answers);
}


@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncQuestionsRespondCopyWith<SyncQuestionsRespond> get copyWith => _$SyncQuestionsRespondCopyWithImpl<SyncQuestionsRespond>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncQuestionsRespondToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncQuestionsRespond&&(identical(other.chatId, chatId) || other.chatId == chatId)&&(identical(other.requestId, requestId) || other.requestId == requestId)&&const DeepCollectionEquality().equals(other._answers, _answers));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId,requestId,const DeepCollectionEquality().hash(_answers));

@override
String toString() {
  return 'SyncMessage.questionsRespond(chatId: $chatId, requestId: $requestId, answers: $answers)';
}


}

/// @nodoc
abstract mixin class $SyncQuestionsRespondCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncQuestionsRespondCopyWith(SyncQuestionsRespond value, $Res Function(SyncQuestionsRespond) _then) = _$SyncQuestionsRespondCopyWithImpl;
@useResult
$Res call({
 String chatId, String requestId, List<String?> answers
});




}
/// @nodoc
class _$SyncQuestionsRespondCopyWithImpl<$Res>
    implements $SyncQuestionsRespondCopyWith<$Res> {
  _$SyncQuestionsRespondCopyWithImpl(this._self, this._then);

  final SyncQuestionsRespond _self;
  final $Res Function(SyncQuestionsRespond) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,Object? requestId = null,Object? answers = null,}) {
  return _then(SyncQuestionsRespond(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,requestId: null == requestId ? _self.requestId : requestId // ignore: cast_nullable_to_non_nullable
as String,answers: null == answers ? _self._answers : answers // ignore: cast_nullable_to_non_nullable
as List<String?>,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncTurnAbort implements SyncMessage {
  const SyncTurnAbort({required this.chatId, final  String? $type}): $type = $type ?? 'turnAbort';
  factory SyncTurnAbort.fromJson(Map<String, dynamic> json) => _$SyncTurnAbortFromJson(json);

 final  String chatId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncTurnAbortCopyWith<SyncTurnAbort> get copyWith => _$SyncTurnAbortCopyWithImpl<SyncTurnAbort>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncTurnAbortToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncTurnAbort&&(identical(other.chatId, chatId) || other.chatId == chatId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId);

@override
String toString() {
  return 'SyncMessage.turnAbort(chatId: $chatId)';
}


}

/// @nodoc
abstract mixin class $SyncTurnAbortCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncTurnAbortCopyWith(SyncTurnAbort value, $Res Function(SyncTurnAbort) _then) = _$SyncTurnAbortCopyWithImpl;
@useResult
$Res call({
 String chatId
});




}
/// @nodoc
class _$SyncTurnAbortCopyWithImpl<$Res>
    implements $SyncTurnAbortCopyWith<$Res> {
  _$SyncTurnAbortCopyWithImpl(this._self, this._then);

  final SyncTurnAbort _self;
  final $Res Function(SyncTurnAbort) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,}) {
  return _then(SyncTurnAbort(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class SyncTurnResume implements SyncMessage {
  const SyncTurnResume({required this.chatId, final  String? $type}): $type = $type ?? 'turnResume';
  factory SyncTurnResume.fromJson(Map<String, dynamic> json) => _$SyncTurnResumeFromJson(json);

 final  String chatId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncTurnResumeCopyWith<SyncTurnResume> get copyWith => _$SyncTurnResumeCopyWithImpl<SyncTurnResume>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncTurnResumeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncTurnResume&&(identical(other.chatId, chatId) || other.chatId == chatId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,chatId);

@override
String toString() {
  return 'SyncMessage.turnResume(chatId: $chatId)';
}


}

/// @nodoc
abstract mixin class $SyncTurnResumeCopyWith<$Res> implements $SyncMessageCopyWith<$Res> {
  factory $SyncTurnResumeCopyWith(SyncTurnResume value, $Res Function(SyncTurnResume) _then) = _$SyncTurnResumeCopyWithImpl;
@useResult
$Res call({
 String chatId
});




}
/// @nodoc
class _$SyncTurnResumeCopyWithImpl<$Res>
    implements $SyncTurnResumeCopyWith<$Res> {
  _$SyncTurnResumeCopyWithImpl(this._self, this._then);

  final SyncTurnResume _self;
  final $Res Function(SyncTurnResume) _then;

/// Create a copy of SyncMessage
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? chatId = null,}) {
  return _then(SyncTurnResume(
chatId: null == chatId ? _self.chatId : chatId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$SyncAsk {

 String get id; String? get argumentsJson;
/// Create a copy of SyncAsk
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncAskCopyWith<SyncAsk> get copyWith => _$SyncAskCopyWithImpl<SyncAsk>(this as SyncAsk, _$identity);

  /// Serializes this SyncAsk to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncAsk&&(identical(other.id, id) || other.id == id)&&(identical(other.argumentsJson, argumentsJson) || other.argumentsJson == argumentsJson));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,argumentsJson);

@override
String toString() {
  return 'SyncAsk(id: $id, argumentsJson: $argumentsJson)';
}


}

/// @nodoc
abstract mixin class $SyncAskCopyWith<$Res>  {
  factory $SyncAskCopyWith(SyncAsk value, $Res Function(SyncAsk) _then) = _$SyncAskCopyWithImpl;
@useResult
$Res call({
 String id, String? argumentsJson
});




}
/// @nodoc
class _$SyncAskCopyWithImpl<$Res>
    implements $SyncAskCopyWith<$Res> {
  _$SyncAskCopyWithImpl(this._self, this._then);

  final SyncAsk _self;
  final $Res Function(SyncAsk) _then;

/// Create a copy of SyncAsk
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? argumentsJson = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,argumentsJson: freezed == argumentsJson ? _self.argumentsJson : argumentsJson // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [SyncAsk].
extension SyncAskPatterns on SyncAsk {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SyncAsk value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SyncAsk() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SyncAsk value)  $default,){
final _that = this;
switch (_that) {
case _SyncAsk():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SyncAsk value)?  $default,){
final _that = this;
switch (_that) {
case _SyncAsk() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String? argumentsJson)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SyncAsk() when $default != null:
return $default(_that.id,_that.argumentsJson);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String? argumentsJson)  $default,) {final _that = this;
switch (_that) {
case _SyncAsk():
return $default(_that.id,_that.argumentsJson);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String? argumentsJson)?  $default,) {final _that = this;
switch (_that) {
case _SyncAsk() when $default != null:
return $default(_that.id,_that.argumentsJson);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SyncAsk implements SyncAsk {
  const _SyncAsk({required this.id, this.argumentsJson});
  factory _SyncAsk.fromJson(Map<String, dynamic> json) => _$SyncAskFromJson(json);

@override final  String id;
@override final  String? argumentsJson;

/// Create a copy of SyncAsk
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SyncAskCopyWith<_SyncAsk> get copyWith => __$SyncAskCopyWithImpl<_SyncAsk>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncAskToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SyncAsk&&(identical(other.id, id) || other.id == id)&&(identical(other.argumentsJson, argumentsJson) || other.argumentsJson == argumentsJson));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,argumentsJson);

@override
String toString() {
  return 'SyncAsk(id: $id, argumentsJson: $argumentsJson)';
}


}

/// @nodoc
abstract mixin class _$SyncAskCopyWith<$Res> implements $SyncAskCopyWith<$Res> {
  factory _$SyncAskCopyWith(_SyncAsk value, $Res Function(_SyncAsk) _then) = __$SyncAskCopyWithImpl;
@override @useResult
$Res call({
 String id, String? argumentsJson
});




}
/// @nodoc
class __$SyncAskCopyWithImpl<$Res>
    implements _$SyncAskCopyWith<$Res> {
  __$SyncAskCopyWithImpl(this._self, this._then);

  final _SyncAsk _self;
  final $Res Function(_SyncAsk) _then;

/// Create a copy of SyncAsk
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? argumentsJson = freezed,}) {
  return _then(_SyncAsk(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,argumentsJson: freezed == argumentsJson ? _self.argumentsJson : argumentsJson // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
