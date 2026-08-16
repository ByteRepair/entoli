// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'chat_log.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
ChatRecord _$ChatRecordFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'message':
          return MessageRecord.fromJson(
            json
          );
                case 'part':
          return PartRecord.fromJson(
            json
          );
                case 'append':
          return AppendRecord.fromJson(
            json
          );
                case 'turnEnd':
          return TurnEndRecord.fromJson(
            json
          );
                case 'rewind':
          return RewindRecord.fromJson(
            json
          );
        
          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'ChatRecord',
  'Invalid union type "${json['runtimeType']}"!'
);
        }
      
}

/// @nodoc
mixin _$ChatRecord {



  /// Serializes this ChatRecord to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatRecord);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ChatRecord()';
}


}

/// @nodoc
class $ChatRecordCopyWith<$Res>  {
$ChatRecordCopyWith(ChatRecord _, $Res Function(ChatRecord) __);
}


/// Adds pattern-matching-related methods to [ChatRecord].
extension ChatRecordPatterns on ChatRecord {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( MessageRecord value)?  message,TResult Function( PartRecord value)?  part,TResult Function( AppendRecord value)?  append,TResult Function( TurnEndRecord value)?  turnEnd,TResult Function( RewindRecord value)?  rewind,required TResult orElse(),}){
final _that = this;
switch (_that) {
case MessageRecord() when message != null:
return message(_that);case PartRecord() when part != null:
return part(_that);case AppendRecord() when append != null:
return append(_that);case TurnEndRecord() when turnEnd != null:
return turnEnd(_that);case RewindRecord() when rewind != null:
return rewind(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( MessageRecord value)  message,required TResult Function( PartRecord value)  part,required TResult Function( AppendRecord value)  append,required TResult Function( TurnEndRecord value)  turnEnd,required TResult Function( RewindRecord value)  rewind,}){
final _that = this;
switch (_that) {
case MessageRecord():
return message(_that);case PartRecord():
return part(_that);case AppendRecord():
return append(_that);case TurnEndRecord():
return turnEnd(_that);case RewindRecord():
return rewind(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( MessageRecord value)?  message,TResult? Function( PartRecord value)?  part,TResult? Function( AppendRecord value)?  append,TResult? Function( TurnEndRecord value)?  turnEnd,TResult? Function( RewindRecord value)?  rewind,}){
final _that = this;
switch (_that) {
case MessageRecord() when message != null:
return message(_that);case PartRecord() when part != null:
return part(_that);case AppendRecord() when append != null:
return append(_that);case TurnEndRecord() when turnEnd != null:
return turnEnd(_that);case RewindRecord() when rewind != null:
return rewind(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String id,  MessageRole role,  DateTime createdAt,  String? parentId)?  message,TResult Function( String messageId,  int index,  MessagePart part)?  part,TResult Function( String messageId,  int index,  String text)?  append,TResult Function( String messageId,  TurnEnd reason)?  turnEnd,TResult Function( String messageId)?  rewind,required TResult orElse(),}) {final _that = this;
switch (_that) {
case MessageRecord() when message != null:
return message(_that.id,_that.role,_that.createdAt,_that.parentId);case PartRecord() when part != null:
return part(_that.messageId,_that.index,_that.part);case AppendRecord() when append != null:
return append(_that.messageId,_that.index,_that.text);case TurnEndRecord() when turnEnd != null:
return turnEnd(_that.messageId,_that.reason);case RewindRecord() when rewind != null:
return rewind(_that.messageId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String id,  MessageRole role,  DateTime createdAt,  String? parentId)  message,required TResult Function( String messageId,  int index,  MessagePart part)  part,required TResult Function( String messageId,  int index,  String text)  append,required TResult Function( String messageId,  TurnEnd reason)  turnEnd,required TResult Function( String messageId)  rewind,}) {final _that = this;
switch (_that) {
case MessageRecord():
return message(_that.id,_that.role,_that.createdAt,_that.parentId);case PartRecord():
return part(_that.messageId,_that.index,_that.part);case AppendRecord():
return append(_that.messageId,_that.index,_that.text);case TurnEndRecord():
return turnEnd(_that.messageId,_that.reason);case RewindRecord():
return rewind(_that.messageId);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String id,  MessageRole role,  DateTime createdAt,  String? parentId)?  message,TResult? Function( String messageId,  int index,  MessagePart part)?  part,TResult? Function( String messageId,  int index,  String text)?  append,TResult? Function( String messageId,  TurnEnd reason)?  turnEnd,TResult? Function( String messageId)?  rewind,}) {final _that = this;
switch (_that) {
case MessageRecord() when message != null:
return message(_that.id,_that.role,_that.createdAt,_that.parentId);case PartRecord() when part != null:
return part(_that.messageId,_that.index,_that.part);case AppendRecord() when append != null:
return append(_that.messageId,_that.index,_that.text);case TurnEndRecord() when turnEnd != null:
return turnEnd(_that.messageId,_that.reason);case RewindRecord() when rewind != null:
return rewind(_that.messageId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class MessageRecord implements ChatRecord {
  const MessageRecord({required this.id, required this.role, required this.createdAt, this.parentId, final  String? $type}): $type = $type ?? 'message';
  factory MessageRecord.fromJson(Map<String, dynamic> json) => _$MessageRecordFromJson(json);

 final  String id;
 final  MessageRole role;
 final  DateTime createdAt;
 final  String? parentId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MessageRecordCopyWith<MessageRecord> get copyWith => _$MessageRecordCopyWithImpl<MessageRecord>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MessageRecordToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MessageRecord&&(identical(other.id, id) || other.id == id)&&(identical(other.role, role) || other.role == role)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.parentId, parentId) || other.parentId == parentId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,role,createdAt,parentId);

@override
String toString() {
  return 'ChatRecord.message(id: $id, role: $role, createdAt: $createdAt, parentId: $parentId)';
}


}

/// @nodoc
abstract mixin class $MessageRecordCopyWith<$Res> implements $ChatRecordCopyWith<$Res> {
  factory $MessageRecordCopyWith(MessageRecord value, $Res Function(MessageRecord) _then) = _$MessageRecordCopyWithImpl;
@useResult
$Res call({
 String id, MessageRole role, DateTime createdAt, String? parentId
});




}
/// @nodoc
class _$MessageRecordCopyWithImpl<$Res>
    implements $MessageRecordCopyWith<$Res> {
  _$MessageRecordCopyWithImpl(this._self, this._then);

  final MessageRecord _self;
  final $Res Function(MessageRecord) _then;

/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,Object? role = null,Object? createdAt = null,Object? parentId = freezed,}) {
  return _then(MessageRecord(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as MessageRole,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,parentId: freezed == parentId ? _self.parentId : parentId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class PartRecord implements ChatRecord {
  const PartRecord({required this.messageId, required this.index, required this.part, final  String? $type}): $type = $type ?? 'part';
  factory PartRecord.fromJson(Map<String, dynamic> json) => _$PartRecordFromJson(json);

 final  String messageId;
 final  int index;
 final  MessagePart part;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$PartRecordCopyWith<PartRecord> get copyWith => _$PartRecordCopyWithImpl<PartRecord>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$PartRecordToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is PartRecord&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.index, index) || other.index == index)&&(identical(other.part, part) || other.part == part));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,messageId,index,part);

@override
String toString() {
  return 'ChatRecord.part(messageId: $messageId, index: $index, part: $part)';
}


}

/// @nodoc
abstract mixin class $PartRecordCopyWith<$Res> implements $ChatRecordCopyWith<$Res> {
  factory $PartRecordCopyWith(PartRecord value, $Res Function(PartRecord) _then) = _$PartRecordCopyWithImpl;
@useResult
$Res call({
 String messageId, int index, MessagePart part
});


$MessagePartCopyWith<$Res> get part;

}
/// @nodoc
class _$PartRecordCopyWithImpl<$Res>
    implements $PartRecordCopyWith<$Res> {
  _$PartRecordCopyWithImpl(this._self, this._then);

  final PartRecord _self;
  final $Res Function(PartRecord) _then;

/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? messageId = null,Object? index = null,Object? part = null,}) {
  return _then(PartRecord(
messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,part: null == part ? _self.part : part // ignore: cast_nullable_to_non_nullable
as MessagePart,
  ));
}

/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$MessagePartCopyWith<$Res> get part {
  
  return $MessagePartCopyWith<$Res>(_self.part, (value) {
    return _then(_self.copyWith(part: value));
  });
}
}

/// @nodoc
@JsonSerializable()

class AppendRecord implements ChatRecord {
  const AppendRecord({required this.messageId, required this.index, required this.text, final  String? $type}): $type = $type ?? 'append';
  factory AppendRecord.fromJson(Map<String, dynamic> json) => _$AppendRecordFromJson(json);

 final  String messageId;
 final  int index;
 final  String text;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AppendRecordCopyWith<AppendRecord> get copyWith => _$AppendRecordCopyWithImpl<AppendRecord>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$AppendRecordToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AppendRecord&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.index, index) || other.index == index)&&(identical(other.text, text) || other.text == text));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,messageId,index,text);

@override
String toString() {
  return 'ChatRecord.append(messageId: $messageId, index: $index, text: $text)';
}


}

/// @nodoc
abstract mixin class $AppendRecordCopyWith<$Res> implements $ChatRecordCopyWith<$Res> {
  factory $AppendRecordCopyWith(AppendRecord value, $Res Function(AppendRecord) _then) = _$AppendRecordCopyWithImpl;
@useResult
$Res call({
 String messageId, int index, String text
});




}
/// @nodoc
class _$AppendRecordCopyWithImpl<$Res>
    implements $AppendRecordCopyWith<$Res> {
  _$AppendRecordCopyWithImpl(this._self, this._then);

  final AppendRecord _self;
  final $Res Function(AppendRecord) _then;

/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? messageId = null,Object? index = null,Object? text = null,}) {
  return _then(AppendRecord(
messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class TurnEndRecord implements ChatRecord {
  const TurnEndRecord({required this.messageId, required this.reason, final  String? $type}): $type = $type ?? 'turnEnd';
  factory TurnEndRecord.fromJson(Map<String, dynamic> json) => _$TurnEndRecordFromJson(json);

 final  String messageId;
 final  TurnEnd reason;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TurnEndRecordCopyWith<TurnEndRecord> get copyWith => _$TurnEndRecordCopyWithImpl<TurnEndRecord>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TurnEndRecordToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TurnEndRecord&&(identical(other.messageId, messageId) || other.messageId == messageId)&&(identical(other.reason, reason) || other.reason == reason));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,messageId,reason);

@override
String toString() {
  return 'ChatRecord.turnEnd(messageId: $messageId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $TurnEndRecordCopyWith<$Res> implements $ChatRecordCopyWith<$Res> {
  factory $TurnEndRecordCopyWith(TurnEndRecord value, $Res Function(TurnEndRecord) _then) = _$TurnEndRecordCopyWithImpl;
@useResult
$Res call({
 String messageId, TurnEnd reason
});




}
/// @nodoc
class _$TurnEndRecordCopyWithImpl<$Res>
    implements $TurnEndRecordCopyWith<$Res> {
  _$TurnEndRecordCopyWithImpl(this._self, this._then);

  final TurnEndRecord _self;
  final $Res Function(TurnEndRecord) _then;

/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? messageId = null,Object? reason = null,}) {
  return _then(TurnEndRecord(
messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as TurnEnd,
  ));
}


}

/// @nodoc
@JsonSerializable()

class RewindRecord implements ChatRecord {
  const RewindRecord({required this.messageId, final  String? $type}): $type = $type ?? 'rewind';
  factory RewindRecord.fromJson(Map<String, dynamic> json) => _$RewindRecordFromJson(json);

 final  String messageId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$RewindRecordCopyWith<RewindRecord> get copyWith => _$RewindRecordCopyWithImpl<RewindRecord>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$RewindRecordToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is RewindRecord&&(identical(other.messageId, messageId) || other.messageId == messageId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,messageId);

@override
String toString() {
  return 'ChatRecord.rewind(messageId: $messageId)';
}


}

/// @nodoc
abstract mixin class $RewindRecordCopyWith<$Res> implements $ChatRecordCopyWith<$Res> {
  factory $RewindRecordCopyWith(RewindRecord value, $Res Function(RewindRecord) _then) = _$RewindRecordCopyWithImpl;
@useResult
$Res call({
 String messageId
});




}
/// @nodoc
class _$RewindRecordCopyWithImpl<$Res>
    implements $RewindRecordCopyWith<$Res> {
  _$RewindRecordCopyWithImpl(this._self, this._then);

  final RewindRecord _self;
  final $Res Function(RewindRecord) _then;

/// Create a copy of ChatRecord
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? messageId = null,}) {
  return _then(RewindRecord(
messageId: null == messageId ? _self.messageId : messageId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
