// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ChatState {

 String get id; String get title; DateTime get createdAt; DateTime get updatedAt;/// Which project's `chats/` this lives in. Null is the default project —
/// the data directory itself, where every chat was before there were any.
/// The directory a chat is found in wins over this: a chat moved by hand
/// is in the project it was moved to.
 String? get project;
/// Create a copy of ChatState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChatStateCopyWith<ChatState> get copyWith => _$ChatStateCopyWithImpl<ChatState>(this as ChatState, _$identity);

  /// Serializes this ChatState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ChatState&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.project, project) || other.project == project));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,title,createdAt,updatedAt,project);

@override
String toString() {
  return 'ChatState(id: $id, title: $title, createdAt: $createdAt, updatedAt: $updatedAt, project: $project)';
}


}

/// @nodoc
abstract mixin class $ChatStateCopyWith<$Res>  {
  factory $ChatStateCopyWith(ChatState value, $Res Function(ChatState) _then) = _$ChatStateCopyWithImpl;
@useResult
$Res call({
 String id, String title, DateTime createdAt, DateTime updatedAt, String? project
});




}
/// @nodoc
class _$ChatStateCopyWithImpl<$Res>
    implements $ChatStateCopyWith<$Res> {
  _$ChatStateCopyWithImpl(this._self, this._then);

  final ChatState _self;
  final $Res Function(ChatState) _then;

/// Create a copy of ChatState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? title = null,Object? createdAt = null,Object? updatedAt = null,Object? project = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ChatState].
extension ChatStatePatterns on ChatState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ChatState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ChatState() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ChatState value)  $default,){
final _that = this;
switch (_that) {
case _ChatState():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ChatState value)?  $default,){
final _that = this;
switch (_that) {
case _ChatState() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String title,  DateTime createdAt,  DateTime updatedAt,  String? project)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ChatState() when $default != null:
return $default(_that.id,_that.title,_that.createdAt,_that.updatedAt,_that.project);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String title,  DateTime createdAt,  DateTime updatedAt,  String? project)  $default,) {final _that = this;
switch (_that) {
case _ChatState():
return $default(_that.id,_that.title,_that.createdAt,_that.updatedAt,_that.project);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String title,  DateTime createdAt,  DateTime updatedAt,  String? project)?  $default,) {final _that = this;
switch (_that) {
case _ChatState() when $default != null:
return $default(_that.id,_that.title,_that.createdAt,_that.updatedAt,_that.project);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ChatState implements ChatState {
  const _ChatState({required this.id, required this.title, required this.createdAt, required this.updatedAt, this.project});
  factory _ChatState.fromJson(Map<String, dynamic> json) => _$ChatStateFromJson(json);

@override final  String id;
@override final  String title;
@override final  DateTime createdAt;
@override final  DateTime updatedAt;
/// Which project's `chats/` this lives in. Null is the default project —
/// the data directory itself, where every chat was before there were any.
/// The directory a chat is found in wins over this: a chat moved by hand
/// is in the project it was moved to.
@override final  String? project;

/// Create a copy of ChatState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ChatStateCopyWith<_ChatState> get copyWith => __$ChatStateCopyWithImpl<_ChatState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ChatStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ChatState&&(identical(other.id, id) || other.id == id)&&(identical(other.title, title) || other.title == title)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.project, project) || other.project == project));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,title,createdAt,updatedAt,project);

@override
String toString() {
  return 'ChatState(id: $id, title: $title, createdAt: $createdAt, updatedAt: $updatedAt, project: $project)';
}


}

/// @nodoc
abstract mixin class _$ChatStateCopyWith<$Res> implements $ChatStateCopyWith<$Res> {
  factory _$ChatStateCopyWith(_ChatState value, $Res Function(_ChatState) _then) = __$ChatStateCopyWithImpl;
@override @useResult
$Res call({
 String id, String title, DateTime createdAt, DateTime updatedAt, String? project
});




}
/// @nodoc
class __$ChatStateCopyWithImpl<$Res>
    implements _$ChatStateCopyWith<$Res> {
  __$ChatStateCopyWithImpl(this._self, this._then);

  final _ChatState _self;
  final $Res Function(_ChatState) _then;

/// Create a copy of ChatState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? title = null,Object? createdAt = null,Object? updatedAt = null,Object? project = freezed,}) {
  return _then(_ChatState(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,project: freezed == project ? _self.project : project // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$Chat {

 ChatState get state; List<Message> get messages;/// The last message is a reply whose turn never finished — the process was
/// killed, or the turn gave up — and so is one to offer to carry on. Read
/// off the log by `endsUnfinished` when the chat is loaded; nothing writes
/// it down, since the absence of a closing record is the whole of it.
 bool get unfinished;
/// Create a copy of Chat
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ChatCopyWith<Chat> get copyWith => _$ChatCopyWithImpl<Chat>(this as Chat, _$identity);

  /// Serializes this Chat to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Chat&&(identical(other.state, state) || other.state == state)&&const DeepCollectionEquality().equals(other.messages, messages)&&(identical(other.unfinished, unfinished) || other.unfinished == unfinished));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,state,const DeepCollectionEquality().hash(messages),unfinished);

@override
String toString() {
  return 'Chat(state: $state, messages: $messages, unfinished: $unfinished)';
}


}

/// @nodoc
abstract mixin class $ChatCopyWith<$Res>  {
  factory $ChatCopyWith(Chat value, $Res Function(Chat) _then) = _$ChatCopyWithImpl;
@useResult
$Res call({
 ChatState state, List<Message> messages, bool unfinished
});


$ChatStateCopyWith<$Res> get state;

}
/// @nodoc
class _$ChatCopyWithImpl<$Res>
    implements $ChatCopyWith<$Res> {
  _$ChatCopyWithImpl(this._self, this._then);

  final Chat _self;
  final $Res Function(Chat) _then;

/// Create a copy of Chat
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? state = null,Object? messages = null,Object? unfinished = null,}) {
  return _then(_self.copyWith(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as ChatState,messages: null == messages ? _self.messages : messages // ignore: cast_nullable_to_non_nullable
as List<Message>,unfinished: null == unfinished ? _self.unfinished : unfinished // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}
/// Create a copy of Chat
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ChatStateCopyWith<$Res> get state {
  
  return $ChatStateCopyWith<$Res>(_self.state, (value) {
    return _then(_self.copyWith(state: value));
  });
}
}


/// Adds pattern-matching-related methods to [Chat].
extension ChatPatterns on Chat {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Chat value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Chat() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Chat value)  $default,){
final _that = this;
switch (_that) {
case _Chat():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Chat value)?  $default,){
final _that = this;
switch (_that) {
case _Chat() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( ChatState state,  List<Message> messages,  bool unfinished)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Chat() when $default != null:
return $default(_that.state,_that.messages,_that.unfinished);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( ChatState state,  List<Message> messages,  bool unfinished)  $default,) {final _that = this;
switch (_that) {
case _Chat():
return $default(_that.state,_that.messages,_that.unfinished);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( ChatState state,  List<Message> messages,  bool unfinished)?  $default,) {final _that = this;
switch (_that) {
case _Chat() when $default != null:
return $default(_that.state,_that.messages,_that.unfinished);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Chat implements Chat {
  const _Chat({required this.state, final  List<Message> messages = const [], this.unfinished = false}): _messages = messages;
  factory _Chat.fromJson(Map<String, dynamic> json) => _$ChatFromJson(json);

@override final  ChatState state;
 final  List<Message> _messages;
@override@JsonKey() List<Message> get messages {
  if (_messages is EqualUnmodifiableListView) return _messages;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_messages);
}

/// The last message is a reply whose turn never finished — the process was
/// killed, or the turn gave up — and so is one to offer to carry on. Read
/// off the log by `endsUnfinished` when the chat is loaded; nothing writes
/// it down, since the absence of a closing record is the whole of it.
@override@JsonKey() final  bool unfinished;

/// Create a copy of Chat
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ChatCopyWith<_Chat> get copyWith => __$ChatCopyWithImpl<_Chat>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ChatToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Chat&&(identical(other.state, state) || other.state == state)&&const DeepCollectionEquality().equals(other._messages, _messages)&&(identical(other.unfinished, unfinished) || other.unfinished == unfinished));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,state,const DeepCollectionEquality().hash(_messages),unfinished);

@override
String toString() {
  return 'Chat(state: $state, messages: $messages, unfinished: $unfinished)';
}


}

/// @nodoc
abstract mixin class _$ChatCopyWith<$Res> implements $ChatCopyWith<$Res> {
  factory _$ChatCopyWith(_Chat value, $Res Function(_Chat) _then) = __$ChatCopyWithImpl;
@override @useResult
$Res call({
 ChatState state, List<Message> messages, bool unfinished
});


@override $ChatStateCopyWith<$Res> get state;

}
/// @nodoc
class __$ChatCopyWithImpl<$Res>
    implements _$ChatCopyWith<$Res> {
  __$ChatCopyWithImpl(this._self, this._then);

  final _Chat _self;
  final $Res Function(_Chat) _then;

/// Create a copy of Chat
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? state = null,Object? messages = null,Object? unfinished = null,}) {
  return _then(_Chat(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as ChatState,messages: null == messages ? _self._messages : messages // ignore: cast_nullable_to_non_nullable
as List<Message>,unfinished: null == unfinished ? _self.unfinished : unfinished // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

/// Create a copy of Chat
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
mixin _$Message {

 String get id; MessageRole get role; DateTime get createdAt; List<MessagePart> get parts; String? get parentId;
/// Create a copy of Message
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$MessageCopyWith<Message> get copyWith => _$MessageCopyWithImpl<Message>(this as Message, _$identity);

  /// Serializes this Message to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Message&&(identical(other.id, id) || other.id == id)&&(identical(other.role, role) || other.role == role)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&const DeepCollectionEquality().equals(other.parts, parts)&&(identical(other.parentId, parentId) || other.parentId == parentId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,role,createdAt,const DeepCollectionEquality().hash(parts),parentId);

@override
String toString() {
  return 'Message(id: $id, role: $role, createdAt: $createdAt, parts: $parts, parentId: $parentId)';
}


}

/// @nodoc
abstract mixin class $MessageCopyWith<$Res>  {
  factory $MessageCopyWith(Message value, $Res Function(Message) _then) = _$MessageCopyWithImpl;
@useResult
$Res call({
 String id, MessageRole role, DateTime createdAt, List<MessagePart> parts, String? parentId
});




}
/// @nodoc
class _$MessageCopyWithImpl<$Res>
    implements $MessageCopyWith<$Res> {
  _$MessageCopyWithImpl(this._self, this._then);

  final Message _self;
  final $Res Function(Message) _then;

/// Create a copy of Message
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? role = null,Object? createdAt = null,Object? parts = null,Object? parentId = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as MessageRole,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,parts: null == parts ? _self.parts : parts // ignore: cast_nullable_to_non_nullable
as List<MessagePart>,parentId: freezed == parentId ? _self.parentId : parentId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [Message].
extension MessagePatterns on Message {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Message value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Message() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Message value)  $default,){
final _that = this;
switch (_that) {
case _Message():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Message value)?  $default,){
final _that = this;
switch (_that) {
case _Message() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  MessageRole role,  DateTime createdAt,  List<MessagePart> parts,  String? parentId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Message() when $default != null:
return $default(_that.id,_that.role,_that.createdAt,_that.parts,_that.parentId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  MessageRole role,  DateTime createdAt,  List<MessagePart> parts,  String? parentId)  $default,) {final _that = this;
switch (_that) {
case _Message():
return $default(_that.id,_that.role,_that.createdAt,_that.parts,_that.parentId);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  MessageRole role,  DateTime createdAt,  List<MessagePart> parts,  String? parentId)?  $default,) {final _that = this;
switch (_that) {
case _Message() when $default != null:
return $default(_that.id,_that.role,_that.createdAt,_that.parts,_that.parentId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Message implements Message {
  const _Message({required this.id, required this.role, required this.createdAt, final  List<MessagePart> parts = const [], this.parentId}): _parts = parts;
  factory _Message.fromJson(Map<String, dynamic> json) => _$MessageFromJson(json);

@override final  String id;
@override final  MessageRole role;
@override final  DateTime createdAt;
 final  List<MessagePart> _parts;
@override@JsonKey() List<MessagePart> get parts {
  if (_parts is EqualUnmodifiableListView) return _parts;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_parts);
}

@override final  String? parentId;

/// Create a copy of Message
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$MessageCopyWith<_Message> get copyWith => __$MessageCopyWithImpl<_Message>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$MessageToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Message&&(identical(other.id, id) || other.id == id)&&(identical(other.role, role) || other.role == role)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&const DeepCollectionEquality().equals(other._parts, _parts)&&(identical(other.parentId, parentId) || other.parentId == parentId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,role,createdAt,const DeepCollectionEquality().hash(_parts),parentId);

@override
String toString() {
  return 'Message(id: $id, role: $role, createdAt: $createdAt, parts: $parts, parentId: $parentId)';
}


}

/// @nodoc
abstract mixin class _$MessageCopyWith<$Res> implements $MessageCopyWith<$Res> {
  factory _$MessageCopyWith(_Message value, $Res Function(_Message) _then) = __$MessageCopyWithImpl;
@override @useResult
$Res call({
 String id, MessageRole role, DateTime createdAt, List<MessagePart> parts, String? parentId
});




}
/// @nodoc
class __$MessageCopyWithImpl<$Res>
    implements _$MessageCopyWith<$Res> {
  __$MessageCopyWithImpl(this._self, this._then);

  final _Message _self;
  final $Res Function(_Message) _then;

/// Create a copy of Message
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? role = null,Object? createdAt = null,Object? parts = null,Object? parentId = freezed,}) {
  return _then(_Message(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as MessageRole,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,parts: null == parts ? _self._parts : parts // ignore: cast_nullable_to_non_nullable
as List<MessagePart>,parentId: freezed == parentId ? _self.parentId : parentId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

MessagePart _$MessagePartFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'text':
          return TextPart.fromJson(
            json
          );
                case 'reasoning':
          return ReasoningPart.fromJson(
            json
          );
                case 'toolCall':
          return ToolCallPart.fromJson(
            json
          );
                case 'toolResult':
          return ToolResultPart.fromJson(
            json
          );
                case 'file':
          return FilePart.fromJson(
            json
          );
                case 'error':
          return ErrorPart.fromJson(
            json
          );
        
          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'MessagePart',
  'Invalid union type "${json['runtimeType']}"!'
);
        }
      
}

/// @nodoc
mixin _$MessagePart {



  /// Serializes this MessagePart to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is MessagePart);
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'MessagePart()';
}


}

/// @nodoc
class $MessagePartCopyWith<$Res>  {
$MessagePartCopyWith(MessagePart _, $Res Function(MessagePart) __);
}


/// Adds pattern-matching-related methods to [MessagePart].
extension MessagePartPatterns on MessagePart {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TextPart value)?  text,TResult Function( ReasoningPart value)?  reasoning,TResult Function( ToolCallPart value)?  toolCall,TResult Function( ToolResultPart value)?  toolResult,TResult Function( FilePart value)?  file,TResult Function( ErrorPart value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that);case ReasoningPart() when reasoning != null:
return reasoning(_that);case ToolCallPart() when toolCall != null:
return toolCall(_that);case ToolResultPart() when toolResult != null:
return toolResult(_that);case FilePart() when file != null:
return file(_that);case ErrorPart() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TextPart value)  text,required TResult Function( ReasoningPart value)  reasoning,required TResult Function( ToolCallPart value)  toolCall,required TResult Function( ToolResultPart value)  toolResult,required TResult Function( FilePart value)  file,required TResult Function( ErrorPart value)  error,}){
final _that = this;
switch (_that) {
case TextPart():
return text(_that);case ReasoningPart():
return reasoning(_that);case ToolCallPart():
return toolCall(_that);case ToolResultPart():
return toolResult(_that);case FilePart():
return file(_that);case ErrorPart():
return error(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TextPart value)?  text,TResult? Function( ReasoningPart value)?  reasoning,TResult? Function( ToolCallPart value)?  toolCall,TResult? Function( ToolResultPart value)?  toolResult,TResult? Function( FilePart value)?  file,TResult? Function( ErrorPart value)?  error,}){
final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that);case ReasoningPart() when reasoning != null:
return reasoning(_that);case ToolCallPart() when toolCall != null:
return toolCall(_that);case ToolResultPart() when toolResult != null:
return toolResult(_that);case FilePart() when file != null:
return file(_that);case ErrorPart() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String text,  String? responseId)?  text,TResult Function( String text,  int? durationMs,  String? signature,  String? responseId)?  reasoning,TResult Function( ToolCall toolCall,  String? responseId)?  toolCall,TResult Function( ToolResult result)?  toolResult,TResult Function( String resource,  String filename,  String mimeType)?  file,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that.text,_that.responseId);case ReasoningPart() when reasoning != null:
return reasoning(_that.text,_that.durationMs,_that.signature,_that.responseId);case ToolCallPart() when toolCall != null:
return toolCall(_that.toolCall,_that.responseId);case ToolResultPart() when toolResult != null:
return toolResult(_that.result);case FilePart() when file != null:
return file(_that.resource,_that.filename,_that.mimeType);case ErrorPart() when error != null:
return error(_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String text,  String? responseId)  text,required TResult Function( String text,  int? durationMs,  String? signature,  String? responseId)  reasoning,required TResult Function( ToolCall toolCall,  String? responseId)  toolCall,required TResult Function( ToolResult result)  toolResult,required TResult Function( String resource,  String filename,  String mimeType)  file,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case TextPart():
return text(_that.text,_that.responseId);case ReasoningPart():
return reasoning(_that.text,_that.durationMs,_that.signature,_that.responseId);case ToolCallPart():
return toolCall(_that.toolCall,_that.responseId);case ToolResultPart():
return toolResult(_that.result);case FilePart():
return file(_that.resource,_that.filename,_that.mimeType);case ErrorPart():
return error(_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String text,  String? responseId)?  text,TResult? Function( String text,  int? durationMs,  String? signature,  String? responseId)?  reasoning,TResult? Function( ToolCall toolCall,  String? responseId)?  toolCall,TResult? Function( ToolResult result)?  toolResult,TResult? Function( String resource,  String filename,  String mimeType)?  file,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that.text,_that.responseId);case ReasoningPart() when reasoning != null:
return reasoning(_that.text,_that.durationMs,_that.signature,_that.responseId);case ToolCallPart() when toolCall != null:
return toolCall(_that.toolCall,_that.responseId);case ToolResultPart() when toolResult != null:
return toolResult(_that.result);case FilePart() when file != null:
return file(_that.resource,_that.filename,_that.mimeType);case ErrorPart() when error != null:
return error(_that.message);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class TextPart implements MessagePart {
  const TextPart({required this.text, this.responseId, final  String? $type}): $type = $type ?? 'text';
  factory TextPart.fromJson(Map<String, dynamic> json) => _$TextPartFromJson(json);

 final  String text;
 final  String? responseId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TextPartCopyWith<TextPart> get copyWith => _$TextPartCopyWithImpl<TextPart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$TextPartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TextPart&&(identical(other.text, text) || other.text == text)&&(identical(other.responseId, responseId) || other.responseId == responseId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,text,responseId);

@override
String toString() {
  return 'MessagePart.text(text: $text, responseId: $responseId)';
}


}

/// @nodoc
abstract mixin class $TextPartCopyWith<$Res> implements $MessagePartCopyWith<$Res> {
  factory $TextPartCopyWith(TextPart value, $Res Function(TextPart) _then) = _$TextPartCopyWithImpl;
@useResult
$Res call({
 String text, String? responseId
});




}
/// @nodoc
class _$TextPartCopyWithImpl<$Res>
    implements $TextPartCopyWith<$Res> {
  _$TextPartCopyWithImpl(this._self, this._then);

  final TextPart _self;
  final $Res Function(TextPart) _then;

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,Object? responseId = freezed,}) {
  return _then(TextPart(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,responseId: freezed == responseId ? _self.responseId : responseId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class ReasoningPart implements MessagePart {
  const ReasoningPart({required this.text, this.durationMs, this.signature, this.responseId, final  String? $type}): $type = $type ?? 'reasoning';
  factory ReasoningPart.fromJson(Map<String, dynamic> json) => _$ReasoningPartFromJson(json);

 final  String text;
 final  int? durationMs;
 final  String? signature;
 final  String? responseId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ReasoningPartCopyWith<ReasoningPart> get copyWith => _$ReasoningPartCopyWithImpl<ReasoningPart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ReasoningPartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ReasoningPart&&(identical(other.text, text) || other.text == text)&&(identical(other.durationMs, durationMs) || other.durationMs == durationMs)&&(identical(other.signature, signature) || other.signature == signature)&&(identical(other.responseId, responseId) || other.responseId == responseId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,text,durationMs,signature,responseId);

@override
String toString() {
  return 'MessagePart.reasoning(text: $text, durationMs: $durationMs, signature: $signature, responseId: $responseId)';
}


}

/// @nodoc
abstract mixin class $ReasoningPartCopyWith<$Res> implements $MessagePartCopyWith<$Res> {
  factory $ReasoningPartCopyWith(ReasoningPart value, $Res Function(ReasoningPart) _then) = _$ReasoningPartCopyWithImpl;
@useResult
$Res call({
 String text, int? durationMs, String? signature, String? responseId
});




}
/// @nodoc
class _$ReasoningPartCopyWithImpl<$Res>
    implements $ReasoningPartCopyWith<$Res> {
  _$ReasoningPartCopyWithImpl(this._self, this._then);

  final ReasoningPart _self;
  final $Res Function(ReasoningPart) _then;

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,Object? durationMs = freezed,Object? signature = freezed,Object? responseId = freezed,}) {
  return _then(ReasoningPart(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,durationMs: freezed == durationMs ? _self.durationMs : durationMs // ignore: cast_nullable_to_non_nullable
as int?,signature: freezed == signature ? _self.signature : signature // ignore: cast_nullable_to_non_nullable
as String?,responseId: freezed == responseId ? _self.responseId : responseId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class ToolCallPart implements MessagePart {
  const ToolCallPart({required this.toolCall, this.responseId, final  String? $type}): $type = $type ?? 'toolCall';
  factory ToolCallPart.fromJson(Map<String, dynamic> json) => _$ToolCallPartFromJson(json);

 final  ToolCall toolCall;
 final  String? responseId;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolCallPartCopyWith<ToolCallPart> get copyWith => _$ToolCallPartCopyWithImpl<ToolCallPart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolCallPartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolCallPart&&(identical(other.toolCall, toolCall) || other.toolCall == toolCall)&&(identical(other.responseId, responseId) || other.responseId == responseId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,toolCall,responseId);

@override
String toString() {
  return 'MessagePart.toolCall(toolCall: $toolCall, responseId: $responseId)';
}


}

/// @nodoc
abstract mixin class $ToolCallPartCopyWith<$Res> implements $MessagePartCopyWith<$Res> {
  factory $ToolCallPartCopyWith(ToolCallPart value, $Res Function(ToolCallPart) _then) = _$ToolCallPartCopyWithImpl;
@useResult
$Res call({
 ToolCall toolCall, String? responseId
});


$ToolCallCopyWith<$Res> get toolCall;

}
/// @nodoc
class _$ToolCallPartCopyWithImpl<$Res>
    implements $ToolCallPartCopyWith<$Res> {
  _$ToolCallPartCopyWithImpl(this._self, this._then);

  final ToolCallPart _self;
  final $Res Function(ToolCallPart) _then;

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? toolCall = null,Object? responseId = freezed,}) {
  return _then(ToolCallPart(
toolCall: null == toolCall ? _self.toolCall : toolCall // ignore: cast_nullable_to_non_nullable
as ToolCall,responseId: freezed == responseId ? _self.responseId : responseId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolCallCopyWith<$Res> get toolCall {
  
  return $ToolCallCopyWith<$Res>(_self.toolCall, (value) {
    return _then(_self.copyWith(toolCall: value));
  });
}
}

/// @nodoc
@JsonSerializable()

class ToolResultPart implements MessagePart {
  const ToolResultPart({required this.result, final  String? $type}): $type = $type ?? 'toolResult';
  factory ToolResultPart.fromJson(Map<String, dynamic> json) => _$ToolResultPartFromJson(json);

 final  ToolResult result;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolResultPartCopyWith<ToolResultPart> get copyWith => _$ToolResultPartCopyWithImpl<ToolResultPart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolResultPartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolResultPart&&(identical(other.result, result) || other.result == result));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,result);

@override
String toString() {
  return 'MessagePart.toolResult(result: $result)';
}


}

/// @nodoc
abstract mixin class $ToolResultPartCopyWith<$Res> implements $MessagePartCopyWith<$Res> {
  factory $ToolResultPartCopyWith(ToolResultPart value, $Res Function(ToolResultPart) _then) = _$ToolResultPartCopyWithImpl;
@useResult
$Res call({
 ToolResult result
});


$ToolResultCopyWith<$Res> get result;

}
/// @nodoc
class _$ToolResultPartCopyWithImpl<$Res>
    implements $ToolResultPartCopyWith<$Res> {
  _$ToolResultPartCopyWithImpl(this._self, this._then);

  final ToolResultPart _self;
  final $Res Function(ToolResultPart) _then;

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? result = null,}) {
  return _then(ToolResultPart(
result: null == result ? _self.result : result // ignore: cast_nullable_to_non_nullable
as ToolResult,
  ));
}

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ToolResultCopyWith<$Res> get result {
  
  return $ToolResultCopyWith<$Res>(_self.result, (value) {
    return _then(_self.copyWith(result: value));
  });
}
}

/// @nodoc
@JsonSerializable()

class FilePart implements MessagePart {
  const FilePart({required this.resource, required this.filename, required this.mimeType, final  String? $type}): $type = $type ?? 'file';
  factory FilePart.fromJson(Map<String, dynamic> json) => _$FilePartFromJson(json);

 final  String resource;
 final  String filename;
 final  String mimeType;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FilePartCopyWith<FilePart> get copyWith => _$FilePartCopyWithImpl<FilePart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$FilePartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FilePart&&(identical(other.resource, resource) || other.resource == resource)&&(identical(other.filename, filename) || other.filename == filename)&&(identical(other.mimeType, mimeType) || other.mimeType == mimeType));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,resource,filename,mimeType);

@override
String toString() {
  return 'MessagePart.file(resource: $resource, filename: $filename, mimeType: $mimeType)';
}


}

/// @nodoc
abstract mixin class $FilePartCopyWith<$Res> implements $MessagePartCopyWith<$Res> {
  factory $FilePartCopyWith(FilePart value, $Res Function(FilePart) _then) = _$FilePartCopyWithImpl;
@useResult
$Res call({
 String resource, String filename, String mimeType
});




}
/// @nodoc
class _$FilePartCopyWithImpl<$Res>
    implements $FilePartCopyWith<$Res> {
  _$FilePartCopyWithImpl(this._self, this._then);

  final FilePart _self;
  final $Res Function(FilePart) _then;

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? resource = null,Object? filename = null,Object? mimeType = null,}) {
  return _then(FilePart(
resource: null == resource ? _self.resource : resource // ignore: cast_nullable_to_non_nullable
as String,filename: null == filename ? _self.filename : filename // ignore: cast_nullable_to_non_nullable
as String,mimeType: null == mimeType ? _self.mimeType : mimeType // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
@JsonSerializable()

class ErrorPart implements MessagePart {
  const ErrorPart({required this.message, final  String? $type}): $type = $type ?? 'error';
  factory ErrorPart.fromJson(Map<String, dynamic> json) => _$ErrorPartFromJson(json);

 final  String message;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ErrorPartCopyWith<ErrorPart> get copyWith => _$ErrorPartCopyWithImpl<ErrorPart>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ErrorPartToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ErrorPart&&(identical(other.message, message) || other.message == message));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'MessagePart.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $ErrorPartCopyWith<$Res> implements $MessagePartCopyWith<$Res> {
  factory $ErrorPartCopyWith(ErrorPart value, $Res Function(ErrorPart) _then) = _$ErrorPartCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$ErrorPartCopyWithImpl<$Res>
    implements $ErrorPartCopyWith<$Res> {
  _$ErrorPartCopyWithImpl(this._self, this._then);

  final ErrorPart _self;
  final $Res Function(ErrorPart) _then;

/// Create a copy of MessagePart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(ErrorPart(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}


/// @nodoc
mixin _$ToolCall {

 String get id; String get name; String? get argumentsJson; String? get argumentsText;
/// Create a copy of ToolCall
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolCallCopyWith<ToolCall> get copyWith => _$ToolCallCopyWithImpl<ToolCall>(this as ToolCall, _$identity);

  /// Serializes this ToolCall to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolCall&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.argumentsJson, argumentsJson) || other.argumentsJson == argumentsJson)&&(identical(other.argumentsText, argumentsText) || other.argumentsText == argumentsText));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,argumentsJson,argumentsText);

@override
String toString() {
  return 'ToolCall(id: $id, name: $name, argumentsJson: $argumentsJson, argumentsText: $argumentsText)';
}


}

/// @nodoc
abstract mixin class $ToolCallCopyWith<$Res>  {
  factory $ToolCallCopyWith(ToolCall value, $Res Function(ToolCall) _then) = _$ToolCallCopyWithImpl;
@useResult
$Res call({
 String id, String name, String? argumentsJson, String? argumentsText
});




}
/// @nodoc
class _$ToolCallCopyWithImpl<$Res>
    implements $ToolCallCopyWith<$Res> {
  _$ToolCallCopyWithImpl(this._self, this._then);

  final ToolCall _self;
  final $Res Function(ToolCall) _then;

/// Create a copy of ToolCall
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? argumentsJson = freezed,Object? argumentsText = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,argumentsJson: freezed == argumentsJson ? _self.argumentsJson : argumentsJson // ignore: cast_nullable_to_non_nullable
as String?,argumentsText: freezed == argumentsText ? _self.argumentsText : argumentsText // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ToolCall].
extension ToolCallPatterns on ToolCall {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolCall value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolCall() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolCall value)  $default,){
final _that = this;
switch (_that) {
case _ToolCall():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolCall value)?  $default,){
final _that = this;
switch (_that) {
case _ToolCall() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String? argumentsJson,  String? argumentsText)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolCall() when $default != null:
return $default(_that.id,_that.name,_that.argumentsJson,_that.argumentsText);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String? argumentsJson,  String? argumentsText)  $default,) {final _that = this;
switch (_that) {
case _ToolCall():
return $default(_that.id,_that.name,_that.argumentsJson,_that.argumentsText);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String? argumentsJson,  String? argumentsText)?  $default,) {final _that = this;
switch (_that) {
case _ToolCall() when $default != null:
return $default(_that.id,_that.name,_that.argumentsJson,_that.argumentsText);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolCall implements ToolCall {
  const _ToolCall({required this.id, required this.name, this.argumentsJson, this.argumentsText});
  factory _ToolCall.fromJson(Map<String, dynamic> json) => _$ToolCallFromJson(json);

@override final  String id;
@override final  String name;
@override final  String? argumentsJson;
@override final  String? argumentsText;

/// Create a copy of ToolCall
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolCallCopyWith<_ToolCall> get copyWith => __$ToolCallCopyWithImpl<_ToolCall>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolCallToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolCall&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.argumentsJson, argumentsJson) || other.argumentsJson == argumentsJson)&&(identical(other.argumentsText, argumentsText) || other.argumentsText == argumentsText));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,argumentsJson,argumentsText);

@override
String toString() {
  return 'ToolCall(id: $id, name: $name, argumentsJson: $argumentsJson, argumentsText: $argumentsText)';
}


}

/// @nodoc
abstract mixin class _$ToolCallCopyWith<$Res> implements $ToolCallCopyWith<$Res> {
  factory _$ToolCallCopyWith(_ToolCall value, $Res Function(_ToolCall) _then) = __$ToolCallCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String? argumentsJson, String? argumentsText
});




}
/// @nodoc
class __$ToolCallCopyWithImpl<$Res>
    implements _$ToolCallCopyWith<$Res> {
  __$ToolCallCopyWithImpl(this._self, this._then);

  final _ToolCall _self;
  final $Res Function(_ToolCall) _then;

/// Create a copy of ToolCall
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? argumentsJson = freezed,Object? argumentsText = freezed,}) {
  return _then(_ToolCall(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,argumentsJson: freezed == argumentsJson ? _self.argumentsJson : argumentsJson // ignore: cast_nullable_to_non_nullable
as String?,argumentsText: freezed == argumentsText ? _self.argumentsText : argumentsText // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ToolResult {

 String get callId; int get returnCode; String get output; String? get exceptionInfo;
/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolResultCopyWith<ToolResult> get copyWith => _$ToolResultCopyWithImpl<ToolResult>(this as ToolResult, _$identity);

  /// Serializes this ToolResult to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolResult&&(identical(other.callId, callId) || other.callId == callId)&&(identical(other.returnCode, returnCode) || other.returnCode == returnCode)&&(identical(other.output, output) || other.output == output)&&(identical(other.exceptionInfo, exceptionInfo) || other.exceptionInfo == exceptionInfo));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,callId,returnCode,output,exceptionInfo);

@override
String toString() {
  return 'ToolResult(callId: $callId, returnCode: $returnCode, output: $output, exceptionInfo: $exceptionInfo)';
}


}

/// @nodoc
abstract mixin class $ToolResultCopyWith<$Res>  {
  factory $ToolResultCopyWith(ToolResult value, $Res Function(ToolResult) _then) = _$ToolResultCopyWithImpl;
@useResult
$Res call({
 String callId, int returnCode, String output, String? exceptionInfo
});




}
/// @nodoc
class _$ToolResultCopyWithImpl<$Res>
    implements $ToolResultCopyWith<$Res> {
  _$ToolResultCopyWithImpl(this._self, this._then);

  final ToolResult _self;
  final $Res Function(ToolResult) _then;

/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? callId = null,Object? returnCode = null,Object? output = null,Object? exceptionInfo = freezed,}) {
  return _then(_self.copyWith(
callId: null == callId ? _self.callId : callId // ignore: cast_nullable_to_non_nullable
as String,returnCode: null == returnCode ? _self.returnCode : returnCode // ignore: cast_nullable_to_non_nullable
as int,output: null == output ? _self.output : output // ignore: cast_nullable_to_non_nullable
as String,exceptionInfo: freezed == exceptionInfo ? _self.exceptionInfo : exceptionInfo // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ToolResult].
extension ToolResultPatterns on ToolResult {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolResult value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolResult value)  $default,){
final _that = this;
switch (_that) {
case _ToolResult():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolResult value)?  $default,){
final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String callId,  int returnCode,  String output,  String? exceptionInfo)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
return $default(_that.callId,_that.returnCode,_that.output,_that.exceptionInfo);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String callId,  int returnCode,  String output,  String? exceptionInfo)  $default,) {final _that = this;
switch (_that) {
case _ToolResult():
return $default(_that.callId,_that.returnCode,_that.output,_that.exceptionInfo);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String callId,  int returnCode,  String output,  String? exceptionInfo)?  $default,) {final _that = this;
switch (_that) {
case _ToolResult() when $default != null:
return $default(_that.callId,_that.returnCode,_that.output,_that.exceptionInfo);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolResult implements ToolResult {
  const _ToolResult({required this.callId, required this.returnCode, required this.output, this.exceptionInfo});
  factory _ToolResult.fromJson(Map<String, dynamic> json) => _$ToolResultFromJson(json);

@override final  String callId;
@override final  int returnCode;
@override final  String output;
@override final  String? exceptionInfo;

/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolResultCopyWith<_ToolResult> get copyWith => __$ToolResultCopyWithImpl<_ToolResult>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolResultToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolResult&&(identical(other.callId, callId) || other.callId == callId)&&(identical(other.returnCode, returnCode) || other.returnCode == returnCode)&&(identical(other.output, output) || other.output == output)&&(identical(other.exceptionInfo, exceptionInfo) || other.exceptionInfo == exceptionInfo));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,callId,returnCode,output,exceptionInfo);

@override
String toString() {
  return 'ToolResult(callId: $callId, returnCode: $returnCode, output: $output, exceptionInfo: $exceptionInfo)';
}


}

/// @nodoc
abstract mixin class _$ToolResultCopyWith<$Res> implements $ToolResultCopyWith<$Res> {
  factory _$ToolResultCopyWith(_ToolResult value, $Res Function(_ToolResult) _then) = __$ToolResultCopyWithImpl;
@override @useResult
$Res call({
 String callId, int returnCode, String output, String? exceptionInfo
});




}
/// @nodoc
class __$ToolResultCopyWithImpl<$Res>
    implements _$ToolResultCopyWith<$Res> {
  __$ToolResultCopyWithImpl(this._self, this._then);

  final _ToolResult _self;
  final $Res Function(_ToolResult) _then;

/// Create a copy of ToolResult
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? callId = null,Object? returnCode = null,Object? output = null,Object? exceptionInfo = freezed,}) {
  return _then(_ToolResult(
callId: null == callId ? _self.callId : callId // ignore: cast_nullable_to_non_nullable
as String,returnCode: null == returnCode ? _self.returnCode : returnCode // ignore: cast_nullable_to_non_nullable
as int,output: null == output ? _self.output : output // ignore: cast_nullable_to_non_nullable
as String,exceptionInfo: freezed == exceptionInfo ? _self.exceptionInfo : exceptionInfo // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ToolApproval {

 String get id; String get toolName; String? get argumentsJson;
/// Create a copy of ToolApproval
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolApprovalCopyWith<ToolApproval> get copyWith => _$ToolApprovalCopyWithImpl<ToolApproval>(this as ToolApproval, _$identity);

  /// Serializes this ToolApproval to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolApproval&&(identical(other.id, id) || other.id == id)&&(identical(other.toolName, toolName) || other.toolName == toolName)&&(identical(other.argumentsJson, argumentsJson) || other.argumentsJson == argumentsJson));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,toolName,argumentsJson);

@override
String toString() {
  return 'ToolApproval(id: $id, toolName: $toolName, argumentsJson: $argumentsJson)';
}


}

/// @nodoc
abstract mixin class $ToolApprovalCopyWith<$Res>  {
  factory $ToolApprovalCopyWith(ToolApproval value, $Res Function(ToolApproval) _then) = _$ToolApprovalCopyWithImpl;
@useResult
$Res call({
 String id, String toolName, String? argumentsJson
});




}
/// @nodoc
class _$ToolApprovalCopyWithImpl<$Res>
    implements $ToolApprovalCopyWith<$Res> {
  _$ToolApprovalCopyWithImpl(this._self, this._then);

  final ToolApproval _self;
  final $Res Function(ToolApproval) _then;

/// Create a copy of ToolApproval
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? toolName = null,Object? argumentsJson = freezed,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,toolName: null == toolName ? _self.toolName : toolName // ignore: cast_nullable_to_non_nullable
as String,argumentsJson: freezed == argumentsJson ? _self.argumentsJson : argumentsJson // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ToolApproval].
extension ToolApprovalPatterns on ToolApproval {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ToolApproval value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ToolApproval() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ToolApproval value)  $default,){
final _that = this;
switch (_that) {
case _ToolApproval():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ToolApproval value)?  $default,){
final _that = this;
switch (_that) {
case _ToolApproval() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String toolName,  String? argumentsJson)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ToolApproval() when $default != null:
return $default(_that.id,_that.toolName,_that.argumentsJson);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String toolName,  String? argumentsJson)  $default,) {final _that = this;
switch (_that) {
case _ToolApproval():
return $default(_that.id,_that.toolName,_that.argumentsJson);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String toolName,  String? argumentsJson)?  $default,) {final _that = this;
switch (_that) {
case _ToolApproval() when $default != null:
return $default(_that.id,_that.toolName,_that.argumentsJson);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ToolApproval implements ToolApproval {
  const _ToolApproval({required this.id, required this.toolName, this.argumentsJson});
  factory _ToolApproval.fromJson(Map<String, dynamic> json) => _$ToolApprovalFromJson(json);

@override final  String id;
@override final  String toolName;
@override final  String? argumentsJson;

/// Create a copy of ToolApproval
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ToolApprovalCopyWith<_ToolApproval> get copyWith => __$ToolApprovalCopyWithImpl<_ToolApproval>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ToolApprovalToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ToolApproval&&(identical(other.id, id) || other.id == id)&&(identical(other.toolName, toolName) || other.toolName == toolName)&&(identical(other.argumentsJson, argumentsJson) || other.argumentsJson == argumentsJson));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,toolName,argumentsJson);

@override
String toString() {
  return 'ToolApproval(id: $id, toolName: $toolName, argumentsJson: $argumentsJson)';
}


}

/// @nodoc
abstract mixin class _$ToolApprovalCopyWith<$Res> implements $ToolApprovalCopyWith<$Res> {
  factory _$ToolApprovalCopyWith(_ToolApproval value, $Res Function(_ToolApproval) _then) = __$ToolApprovalCopyWithImpl;
@override @useResult
$Res call({
 String id, String toolName, String? argumentsJson
});




}
/// @nodoc
class __$ToolApprovalCopyWithImpl<$Res>
    implements _$ToolApprovalCopyWith<$Res> {
  __$ToolApprovalCopyWithImpl(this._self, this._then);

  final _ToolApproval _self;
  final $Res Function(_ToolApproval) _then;

/// Create a copy of ToolApproval
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? toolName = null,Object? argumentsJson = freezed,}) {
  return _then(_ToolApproval(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,toolName: null == toolName ? _self.toolName : toolName // ignore: cast_nullable_to_non_nullable
as String,argumentsJson: freezed == argumentsJson ? _self.argumentsJson : argumentsJson // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}


/// @nodoc
mixin _$ModelOption {

 String get providerId; String get modelId; String? get label;
/// Create a copy of ModelOption
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ModelOptionCopyWith<ModelOption> get copyWith => _$ModelOptionCopyWithImpl<ModelOption>(this as ModelOption, _$identity);

  /// Serializes this ModelOption to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ModelOption&&(identical(other.providerId, providerId) || other.providerId == providerId)&&(identical(other.modelId, modelId) || other.modelId == modelId)&&(identical(other.label, label) || other.label == label));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,providerId,modelId,label);

@override
String toString() {
  return 'ModelOption(providerId: $providerId, modelId: $modelId, label: $label)';
}


}

/// @nodoc
abstract mixin class $ModelOptionCopyWith<$Res>  {
  factory $ModelOptionCopyWith(ModelOption value, $Res Function(ModelOption) _then) = _$ModelOptionCopyWithImpl;
@useResult
$Res call({
 String providerId, String modelId, String? label
});




}
/// @nodoc
class _$ModelOptionCopyWithImpl<$Res>
    implements $ModelOptionCopyWith<$Res> {
  _$ModelOptionCopyWithImpl(this._self, this._then);

  final ModelOption _self;
  final $Res Function(ModelOption) _then;

/// Create a copy of ModelOption
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? providerId = null,Object? modelId = null,Object? label = freezed,}) {
  return _then(_self.copyWith(
providerId: null == providerId ? _self.providerId : providerId // ignore: cast_nullable_to_non_nullable
as String,modelId: null == modelId ? _self.modelId : modelId // ignore: cast_nullable_to_non_nullable
as String,label: freezed == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [ModelOption].
extension ModelOptionPatterns on ModelOption {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ModelOption value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ModelOption() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ModelOption value)  $default,){
final _that = this;
switch (_that) {
case _ModelOption():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ModelOption value)?  $default,){
final _that = this;
switch (_that) {
case _ModelOption() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String providerId,  String modelId,  String? label)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ModelOption() when $default != null:
return $default(_that.providerId,_that.modelId,_that.label);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String providerId,  String modelId,  String? label)  $default,) {final _that = this;
switch (_that) {
case _ModelOption():
return $default(_that.providerId,_that.modelId,_that.label);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String providerId,  String modelId,  String? label)?  $default,) {final _that = this;
switch (_that) {
case _ModelOption() when $default != null:
return $default(_that.providerId,_that.modelId,_that.label);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ModelOption implements ModelOption {
  const _ModelOption({required this.providerId, required this.modelId, this.label});
  factory _ModelOption.fromJson(Map<String, dynamic> json) => _$ModelOptionFromJson(json);

@override final  String providerId;
@override final  String modelId;
@override final  String? label;

/// Create a copy of ModelOption
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ModelOptionCopyWith<_ModelOption> get copyWith => __$ModelOptionCopyWithImpl<_ModelOption>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ModelOptionToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ModelOption&&(identical(other.providerId, providerId) || other.providerId == providerId)&&(identical(other.modelId, modelId) || other.modelId == modelId)&&(identical(other.label, label) || other.label == label));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,providerId,modelId,label);

@override
String toString() {
  return 'ModelOption(providerId: $providerId, modelId: $modelId, label: $label)';
}


}

/// @nodoc
abstract mixin class _$ModelOptionCopyWith<$Res> implements $ModelOptionCopyWith<$Res> {
  factory _$ModelOptionCopyWith(_ModelOption value, $Res Function(_ModelOption) _then) = __$ModelOptionCopyWithImpl;
@override @useResult
$Res call({
 String providerId, String modelId, String? label
});




}
/// @nodoc
class __$ModelOptionCopyWithImpl<$Res>
    implements _$ModelOptionCopyWith<$Res> {
  __$ModelOptionCopyWithImpl(this._self, this._then);

  final _ModelOption _self;
  final $Res Function(_ModelOption) _then;

/// Create a copy of ModelOption
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? providerId = null,Object? modelId = null,Object? label = freezed,}) {
  return _then(_ModelOption(
providerId: null == providerId ? _self.providerId : providerId // ignore: cast_nullable_to_non_nullable
as String,modelId: null == modelId ? _self.modelId : modelId // ignore: cast_nullable_to_non_nullable
as String,label: freezed == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
mixin _$CompletionOption {

 String get name; String? get description;
/// Create a copy of CompletionOption
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CompletionOptionCopyWith<CompletionOption> get copyWith => _$CompletionOptionCopyWithImpl<CompletionOption>(this as CompletionOption, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CompletionOption&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description));
}


@override
int get hashCode => Object.hash(runtimeType,name,description);

@override
String toString() {
  return 'CompletionOption(name: $name, description: $description)';
}


}

/// @nodoc
abstract mixin class $CompletionOptionCopyWith<$Res>  {
  factory $CompletionOptionCopyWith(CompletionOption value, $Res Function(CompletionOption) _then) = _$CompletionOptionCopyWithImpl;
@useResult
$Res call({
 String name, String? description
});




}
/// @nodoc
class _$CompletionOptionCopyWithImpl<$Res>
    implements $CompletionOptionCopyWith<$Res> {
  _$CompletionOptionCopyWithImpl(this._self, this._then);

  final CompletionOption _self;
  final $Res Function(CompletionOption) _then;

/// Create a copy of CompletionOption
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? description = freezed,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [CompletionOption].
extension CompletionOptionPatterns on CompletionOption {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CompletionOption value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CompletionOption() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CompletionOption value)  $default,){
final _that = this;
switch (_that) {
case _CompletionOption():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CompletionOption value)?  $default,){
final _that = this;
switch (_that) {
case _CompletionOption() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String? description)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CompletionOption() when $default != null:
return $default(_that.name,_that.description);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String? description)  $default,) {final _that = this;
switch (_that) {
case _CompletionOption():
return $default(_that.name,_that.description);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String? description)?  $default,) {final _that = this;
switch (_that) {
case _CompletionOption() when $default != null:
return $default(_that.name,_that.description);case _:
  return null;

}
}

}

/// @nodoc


class _CompletionOption implements CompletionOption {
  const _CompletionOption({required this.name, this.description});
  

@override final  String name;
@override final  String? description;

/// Create a copy of CompletionOption
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CompletionOptionCopyWith<_CompletionOption> get copyWith => __$CompletionOptionCopyWithImpl<_CompletionOption>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CompletionOption&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description));
}


@override
int get hashCode => Object.hash(runtimeType,name,description);

@override
String toString() {
  return 'CompletionOption(name: $name, description: $description)';
}


}

/// @nodoc
abstract mixin class _$CompletionOptionCopyWith<$Res> implements $CompletionOptionCopyWith<$Res> {
  factory _$CompletionOptionCopyWith(_CompletionOption value, $Res Function(_CompletionOption) _then) = __$CompletionOptionCopyWithImpl;
@override @useResult
$Res call({
 String name, String? description
});




}
/// @nodoc
class __$CompletionOptionCopyWithImpl<$Res>
    implements _$CompletionOptionCopyWith<$Res> {
  __$CompletionOptionCopyWithImpl(this._self, this._then);

  final _CompletionOption _self;
  final $Res Function(_CompletionOption) _then;

/// Create a copy of CompletionOption
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? description = freezed,}) {
  return _then(_CompletionOption(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
