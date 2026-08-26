// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'types.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$AuthOutcome {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthOutcome);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AuthOutcome()';
}


}

/// @nodoc
class $AuthOutcomeCopyWith<$Res>  {
$AuthOutcomeCopyWith(AuthOutcome _, $Res Function(AuthOutcome) __);
}


/// Adds pattern-matching-related methods to [AuthOutcome].
extension AuthOutcomePatterns on AuthOutcome {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( AuthOutcome_Sasl value)?  sasl,TResult Function( AuthOutcome_NickServFallback value)?  nickServFallback,TResult Function( AuthOutcome_Anonymous value)?  anonymous,required TResult orElse(),}){
final _that = this;
switch (_that) {
case AuthOutcome_Sasl() when sasl != null:
return sasl(_that);case AuthOutcome_NickServFallback() when nickServFallback != null:
return nickServFallback(_that);case AuthOutcome_Anonymous() when anonymous != null:
return anonymous(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( AuthOutcome_Sasl value)  sasl,required TResult Function( AuthOutcome_NickServFallback value)  nickServFallback,required TResult Function( AuthOutcome_Anonymous value)  anonymous,}){
final _that = this;
switch (_that) {
case AuthOutcome_Sasl():
return sasl(_that);case AuthOutcome_NickServFallback():
return nickServFallback(_that);case AuthOutcome_Anonymous():
return anonymous(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( AuthOutcome_Sasl value)?  sasl,TResult? Function( AuthOutcome_NickServFallback value)?  nickServFallback,TResult? Function( AuthOutcome_Anonymous value)?  anonymous,}){
final _that = this;
switch (_that) {
case AuthOutcome_Sasl() when sasl != null:
return sasl(_that);case AuthOutcome_NickServFallback() when nickServFallback != null:
return nickServFallback(_that);case AuthOutcome_Anonymous() when anonymous != null:
return anonymous(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  sasl,TResult Function( String reason)?  nickServFallback,TResult Function()?  anonymous,required TResult orElse(),}) {final _that = this;
switch (_that) {
case AuthOutcome_Sasl() when sasl != null:
return sasl();case AuthOutcome_NickServFallback() when nickServFallback != null:
return nickServFallback(_that.reason);case AuthOutcome_Anonymous() when anonymous != null:
return anonymous();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  sasl,required TResult Function( String reason)  nickServFallback,required TResult Function()  anonymous,}) {final _that = this;
switch (_that) {
case AuthOutcome_Sasl():
return sasl();case AuthOutcome_NickServFallback():
return nickServFallback(_that.reason);case AuthOutcome_Anonymous():
return anonymous();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  sasl,TResult? Function( String reason)?  nickServFallback,TResult? Function()?  anonymous,}) {final _that = this;
switch (_that) {
case AuthOutcome_Sasl() when sasl != null:
return sasl();case AuthOutcome_NickServFallback() when nickServFallback != null:
return nickServFallback(_that.reason);case AuthOutcome_Anonymous() when anonymous != null:
return anonymous();case _:
  return null;

}
}

}

/// @nodoc


class AuthOutcome_Sasl extends AuthOutcome {
  const AuthOutcome_Sasl(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthOutcome_Sasl);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AuthOutcome.sasl()';
}


}




/// @nodoc


class AuthOutcome_NickServFallback extends AuthOutcome {
  const AuthOutcome_NickServFallback({required this.reason}): super._();
  

 final  String reason;

/// Create a copy of AuthOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$AuthOutcome_NickServFallbackCopyWith<AuthOutcome_NickServFallback> get copyWith => _$AuthOutcome_NickServFallbackCopyWithImpl<AuthOutcome_NickServFallback>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthOutcome_NickServFallback&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,reason);

@override
String toString() {
  return 'AuthOutcome.nickServFallback(reason: $reason)';
}


}

/// @nodoc
abstract mixin class $AuthOutcome_NickServFallbackCopyWith<$Res> implements $AuthOutcomeCopyWith<$Res> {
  factory $AuthOutcome_NickServFallbackCopyWith(AuthOutcome_NickServFallback value, $Res Function(AuthOutcome_NickServFallback) _then) = _$AuthOutcome_NickServFallbackCopyWithImpl;
@useResult
$Res call({
 String reason
});




}
/// @nodoc
class _$AuthOutcome_NickServFallbackCopyWithImpl<$Res>
    implements $AuthOutcome_NickServFallbackCopyWith<$Res> {
  _$AuthOutcome_NickServFallbackCopyWithImpl(this._self, this._then);

  final AuthOutcome_NickServFallback _self;
  final $Res Function(AuthOutcome_NickServFallback) _then;

/// Create a copy of AuthOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,}) {
  return _then(AuthOutcome_NickServFallback(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class AuthOutcome_Anonymous extends AuthOutcome {
  const AuthOutcome_Anonymous(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AuthOutcome_Anonymous);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'AuthOutcome.anonymous()';
}


}




/// @nodoc
mixin _$CleanOutcome {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CleanOutcome);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'CleanOutcome()';
}


}

/// @nodoc
class $CleanOutcomeCopyWith<$Res>  {
$CleanOutcomeCopyWith(CleanOutcome _, $Res Function(CleanOutcome) __);
}


/// Adds pattern-matching-related methods to [CleanOutcome].
extension CleanOutcomePatterns on CleanOutcome {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( CleanOutcome_Cleaned value)?  cleaned,TResult Function( CleanOutcome_AlreadyClean value)?  alreadyClean,TResult Function( CleanOutcome_NotAnImage value)?  notAnImage,TResult Function( CleanOutcome_Malformed value)?  malformed,required TResult orElse(),}){
final _that = this;
switch (_that) {
case CleanOutcome_Cleaned() when cleaned != null:
return cleaned(_that);case CleanOutcome_AlreadyClean() when alreadyClean != null:
return alreadyClean(_that);case CleanOutcome_NotAnImage() when notAnImage != null:
return notAnImage(_that);case CleanOutcome_Malformed() when malformed != null:
return malformed(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( CleanOutcome_Cleaned value)  cleaned,required TResult Function( CleanOutcome_AlreadyClean value)  alreadyClean,required TResult Function( CleanOutcome_NotAnImage value)  notAnImage,required TResult Function( CleanOutcome_Malformed value)  malformed,}){
final _that = this;
switch (_that) {
case CleanOutcome_Cleaned():
return cleaned(_that);case CleanOutcome_AlreadyClean():
return alreadyClean(_that);case CleanOutcome_NotAnImage():
return notAnImage(_that);case CleanOutcome_Malformed():
return malformed(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( CleanOutcome_Cleaned value)?  cleaned,TResult? Function( CleanOutcome_AlreadyClean value)?  alreadyClean,TResult? Function( CleanOutcome_NotAnImage value)?  notAnImage,TResult? Function( CleanOutcome_Malformed value)?  malformed,}){
final _that = this;
switch (_that) {
case CleanOutcome_Cleaned() when cleaned != null:
return cleaned(_that);case CleanOutcome_AlreadyClean() when alreadyClean != null:
return alreadyClean(_that);case CleanOutcome_NotAnImage() when notAnImage != null:
return notAnImage(_that);case CleanOutcome_Malformed() when malformed != null:
return malformed(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( Uint8List bytes,  String kind,  List<RemovedItem> removed)?  cleaned,TResult Function( String kind)?  alreadyClean,TResult Function()?  notAnImage,TResult Function( String detail)?  malformed,required TResult orElse(),}) {final _that = this;
switch (_that) {
case CleanOutcome_Cleaned() when cleaned != null:
return cleaned(_that.bytes,_that.kind,_that.removed);case CleanOutcome_AlreadyClean() when alreadyClean != null:
return alreadyClean(_that.kind);case CleanOutcome_NotAnImage() when notAnImage != null:
return notAnImage();case CleanOutcome_Malformed() when malformed != null:
return malformed(_that.detail);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( Uint8List bytes,  String kind,  List<RemovedItem> removed)  cleaned,required TResult Function( String kind)  alreadyClean,required TResult Function()  notAnImage,required TResult Function( String detail)  malformed,}) {final _that = this;
switch (_that) {
case CleanOutcome_Cleaned():
return cleaned(_that.bytes,_that.kind,_that.removed);case CleanOutcome_AlreadyClean():
return alreadyClean(_that.kind);case CleanOutcome_NotAnImage():
return notAnImage();case CleanOutcome_Malformed():
return malformed(_that.detail);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( Uint8List bytes,  String kind,  List<RemovedItem> removed)?  cleaned,TResult? Function( String kind)?  alreadyClean,TResult? Function()?  notAnImage,TResult? Function( String detail)?  malformed,}) {final _that = this;
switch (_that) {
case CleanOutcome_Cleaned() when cleaned != null:
return cleaned(_that.bytes,_that.kind,_that.removed);case CleanOutcome_AlreadyClean() when alreadyClean != null:
return alreadyClean(_that.kind);case CleanOutcome_NotAnImage() when notAnImage != null:
return notAnImage();case CleanOutcome_Malformed() when malformed != null:
return malformed(_that.detail);case _:
  return null;

}
}

}

/// @nodoc


class CleanOutcome_Cleaned extends CleanOutcome {
  const CleanOutcome_Cleaned({required this.bytes, required this.kind, required final  List<RemovedItem> removed}): _removed = removed,super._();
  

 final  Uint8List bytes;
/// `"JPEG"`, `"PNG"`, `"GIF"` or `"WebP"`.
 final  String kind;
 final  List<RemovedItem> _removed;
 List<RemovedItem> get removed {
  if (_removed is EqualUnmodifiableListView) return _removed;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_removed);
}


/// Create a copy of CleanOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CleanOutcome_CleanedCopyWith<CleanOutcome_Cleaned> get copyWith => _$CleanOutcome_CleanedCopyWithImpl<CleanOutcome_Cleaned>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CleanOutcome_Cleaned&&const DeepCollectionEquality().equals(other.bytes, bytes)&&(identical(other.kind, kind) || other.kind == kind)&&const DeepCollectionEquality().equals(other._removed, _removed));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(bytes),kind,const DeepCollectionEquality().hash(_removed));

@override
String toString() {
  return 'CleanOutcome.cleaned(bytes: $bytes, kind: $kind, removed: $removed)';
}


}

/// @nodoc
abstract mixin class $CleanOutcome_CleanedCopyWith<$Res> implements $CleanOutcomeCopyWith<$Res> {
  factory $CleanOutcome_CleanedCopyWith(CleanOutcome_Cleaned value, $Res Function(CleanOutcome_Cleaned) _then) = _$CleanOutcome_CleanedCopyWithImpl;
@useResult
$Res call({
 Uint8List bytes, String kind, List<RemovedItem> removed
});




}
/// @nodoc
class _$CleanOutcome_CleanedCopyWithImpl<$Res>
    implements $CleanOutcome_CleanedCopyWith<$Res> {
  _$CleanOutcome_CleanedCopyWithImpl(this._self, this._then);

  final CleanOutcome_Cleaned _self;
  final $Res Function(CleanOutcome_Cleaned) _then;

/// Create a copy of CleanOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? bytes = null,Object? kind = null,Object? removed = null,}) {
  return _then(CleanOutcome_Cleaned(
bytes: null == bytes ? _self.bytes : bytes // ignore: cast_nullable_to_non_nullable
as Uint8List,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,removed: null == removed ? _self._removed : removed // ignore: cast_nullable_to_non_nullable
as List<RemovedItem>,
  ));
}


}

/// @nodoc


class CleanOutcome_AlreadyClean extends CleanOutcome {
  const CleanOutcome_AlreadyClean({required this.kind}): super._();
  

 final  String kind;

/// Create a copy of CleanOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CleanOutcome_AlreadyCleanCopyWith<CleanOutcome_AlreadyClean> get copyWith => _$CleanOutcome_AlreadyCleanCopyWithImpl<CleanOutcome_AlreadyClean>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CleanOutcome_AlreadyClean&&(identical(other.kind, kind) || other.kind == kind));
}


@override
int get hashCode => Object.hash(runtimeType,kind);

@override
String toString() {
  return 'CleanOutcome.alreadyClean(kind: $kind)';
}


}

/// @nodoc
abstract mixin class $CleanOutcome_AlreadyCleanCopyWith<$Res> implements $CleanOutcomeCopyWith<$Res> {
  factory $CleanOutcome_AlreadyCleanCopyWith(CleanOutcome_AlreadyClean value, $Res Function(CleanOutcome_AlreadyClean) _then) = _$CleanOutcome_AlreadyCleanCopyWithImpl;
@useResult
$Res call({
 String kind
});




}
/// @nodoc
class _$CleanOutcome_AlreadyCleanCopyWithImpl<$Res>
    implements $CleanOutcome_AlreadyCleanCopyWith<$Res> {
  _$CleanOutcome_AlreadyCleanCopyWithImpl(this._self, this._then);

  final CleanOutcome_AlreadyClean _self;
  final $Res Function(CleanOutcome_AlreadyClean) _then;

/// Create a copy of CleanOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? kind = null,}) {
  return _then(CleanOutcome_AlreadyClean(
kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class CleanOutcome_NotAnImage extends CleanOutcome {
  const CleanOutcome_NotAnImage(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CleanOutcome_NotAnImage);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'CleanOutcome.notAnImage()';
}


}




/// @nodoc


class CleanOutcome_Malformed extends CleanOutcome {
  const CleanOutcome_Malformed({required this.detail}): super._();
  

 final  String detail;

/// Create a copy of CleanOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CleanOutcome_MalformedCopyWith<CleanOutcome_Malformed> get copyWith => _$CleanOutcome_MalformedCopyWithImpl<CleanOutcome_Malformed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CleanOutcome_Malformed&&(identical(other.detail, detail) || other.detail == detail));
}


@override
int get hashCode => Object.hash(runtimeType,detail);

@override
String toString() {
  return 'CleanOutcome.malformed(detail: $detail)';
}


}

/// @nodoc
abstract mixin class $CleanOutcome_MalformedCopyWith<$Res> implements $CleanOutcomeCopyWith<$Res> {
  factory $CleanOutcome_MalformedCopyWith(CleanOutcome_Malformed value, $Res Function(CleanOutcome_Malformed) _then) = _$CleanOutcome_MalformedCopyWithImpl;
@useResult
$Res call({
 String detail
});




}
/// @nodoc
class _$CleanOutcome_MalformedCopyWithImpl<$Res>
    implements $CleanOutcome_MalformedCopyWith<$Res> {
  _$CleanOutcome_MalformedCopyWithImpl(this._self, this._then);

  final CleanOutcome_Malformed _self;
  final $Res Function(CleanOutcome_Malformed) _then;

/// Create a copy of CleanOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? detail = null,}) {
  return _then(CleanOutcome_Malformed(
detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$ConnectionStatus {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionStatus);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionStatus()';
}


}

/// @nodoc
class $ConnectionStatusCopyWith<$Res>  {
$ConnectionStatusCopyWith(ConnectionStatus _, $Res Function(ConnectionStatus) __);
}


/// Adds pattern-matching-related methods to [ConnectionStatus].
extension ConnectionStatusPatterns on ConnectionStatus {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ConnectionStatus_Disconnected value)?  disconnected,TResult Function( ConnectionStatus_Connecting value)?  connecting,TResult Function( ConnectionStatus_Registering value)?  registering,TResult Function( ConnectionStatus_Connected value)?  connected,TResult Function( ConnectionStatus_Reconnecting value)?  reconnecting,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ConnectionStatus_Disconnected() when disconnected != null:
return disconnected(_that);case ConnectionStatus_Connecting() when connecting != null:
return connecting(_that);case ConnectionStatus_Registering() when registering != null:
return registering(_that);case ConnectionStatus_Connected() when connected != null:
return connected(_that);case ConnectionStatus_Reconnecting() when reconnecting != null:
return reconnecting(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ConnectionStatus_Disconnected value)  disconnected,required TResult Function( ConnectionStatus_Connecting value)  connecting,required TResult Function( ConnectionStatus_Registering value)  registering,required TResult Function( ConnectionStatus_Connected value)  connected,required TResult Function( ConnectionStatus_Reconnecting value)  reconnecting,}){
final _that = this;
switch (_that) {
case ConnectionStatus_Disconnected():
return disconnected(_that);case ConnectionStatus_Connecting():
return connecting(_that);case ConnectionStatus_Registering():
return registering(_that);case ConnectionStatus_Connected():
return connected(_that);case ConnectionStatus_Reconnecting():
return reconnecting(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ConnectionStatus_Disconnected value)?  disconnected,TResult? Function( ConnectionStatus_Connecting value)?  connecting,TResult? Function( ConnectionStatus_Registering value)?  registering,TResult? Function( ConnectionStatus_Connected value)?  connected,TResult? Function( ConnectionStatus_Reconnecting value)?  reconnecting,}){
final _that = this;
switch (_that) {
case ConnectionStatus_Disconnected() when disconnected != null:
return disconnected(_that);case ConnectionStatus_Connecting() when connecting != null:
return connecting(_that);case ConnectionStatus_Registering() when registering != null:
return registering(_that);case ConnectionStatus_Connected() when connected != null:
return connected(_that);case ConnectionStatus_Reconnecting() when reconnecting != null:
return reconnecting(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  disconnected,TResult Function()?  connecting,TResult Function()?  registering,TResult Function()?  connected,TResult Function( BigInt retryInSecs,  int attempt)?  reconnecting,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ConnectionStatus_Disconnected() when disconnected != null:
return disconnected();case ConnectionStatus_Connecting() when connecting != null:
return connecting();case ConnectionStatus_Registering() when registering != null:
return registering();case ConnectionStatus_Connected() when connected != null:
return connected();case ConnectionStatus_Reconnecting() when reconnecting != null:
return reconnecting(_that.retryInSecs,_that.attempt);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  disconnected,required TResult Function()  connecting,required TResult Function()  registering,required TResult Function()  connected,required TResult Function( BigInt retryInSecs,  int attempt)  reconnecting,}) {final _that = this;
switch (_that) {
case ConnectionStatus_Disconnected():
return disconnected();case ConnectionStatus_Connecting():
return connecting();case ConnectionStatus_Registering():
return registering();case ConnectionStatus_Connected():
return connected();case ConnectionStatus_Reconnecting():
return reconnecting(_that.retryInSecs,_that.attempt);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  disconnected,TResult? Function()?  connecting,TResult? Function()?  registering,TResult? Function()?  connected,TResult? Function( BigInt retryInSecs,  int attempt)?  reconnecting,}) {final _that = this;
switch (_that) {
case ConnectionStatus_Disconnected() when disconnected != null:
return disconnected();case ConnectionStatus_Connecting() when connecting != null:
return connecting();case ConnectionStatus_Registering() when registering != null:
return registering();case ConnectionStatus_Connected() when connected != null:
return connected();case ConnectionStatus_Reconnecting() when reconnecting != null:
return reconnecting(_that.retryInSecs,_that.attempt);case _:
  return null;

}
}

}

/// @nodoc


class ConnectionStatus_Disconnected extends ConnectionStatus {
  const ConnectionStatus_Disconnected(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionStatus_Disconnected);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionStatus.disconnected()';
}


}




/// @nodoc


class ConnectionStatus_Connecting extends ConnectionStatus {
  const ConnectionStatus_Connecting(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionStatus_Connecting);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionStatus.connecting()';
}


}




/// @nodoc


class ConnectionStatus_Registering extends ConnectionStatus {
  const ConnectionStatus_Registering(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionStatus_Registering);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionStatus.registering()';
}


}




/// @nodoc


class ConnectionStatus_Connected extends ConnectionStatus {
  const ConnectionStatus_Connected(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionStatus_Connected);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionStatus.connected()';
}


}




/// @nodoc


class ConnectionStatus_Reconnecting extends ConnectionStatus {
  const ConnectionStatus_Reconnecting({required this.retryInSecs, required this.attempt}): super._();
  

 final  BigInt retryInSecs;
 final  int attempt;

/// Create a copy of ConnectionStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectionStatus_ReconnectingCopyWith<ConnectionStatus_Reconnecting> get copyWith => _$ConnectionStatus_ReconnectingCopyWithImpl<ConnectionStatus_Reconnecting>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionStatus_Reconnecting&&(identical(other.retryInSecs, retryInSecs) || other.retryInSecs == retryInSecs)&&(identical(other.attempt, attempt) || other.attempt == attempt));
}


@override
int get hashCode => Object.hash(runtimeType,retryInSecs,attempt);

@override
String toString() {
  return 'ConnectionStatus.reconnecting(retryInSecs: $retryInSecs, attempt: $attempt)';
}


}

/// @nodoc
abstract mixin class $ConnectionStatus_ReconnectingCopyWith<$Res> implements $ConnectionStatusCopyWith<$Res> {
  factory $ConnectionStatus_ReconnectingCopyWith(ConnectionStatus_Reconnecting value, $Res Function(ConnectionStatus_Reconnecting) _then) = _$ConnectionStatus_ReconnectingCopyWithImpl;
@useResult
$Res call({
 BigInt retryInSecs, int attempt
});




}
/// @nodoc
class _$ConnectionStatus_ReconnectingCopyWithImpl<$Res>
    implements $ConnectionStatus_ReconnectingCopyWith<$Res> {
  _$ConnectionStatus_ReconnectingCopyWithImpl(this._self, this._then);

  final ConnectionStatus_Reconnecting _self;
  final $Res Function(ConnectionStatus_Reconnecting) _then;

/// Create a copy of ConnectionStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? retryInSecs = null,Object? attempt = null,}) {
  return _then(ConnectionStatus_Reconnecting(
retryInSecs: null == retryInSecs ? _self.retryInSecs : retryInSecs // ignore: cast_nullable_to_non_nullable
as BigInt,attempt: null == attempt ? _self.attempt : attempt // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc
mixin _$IrcEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'IrcEvent()';
}


}

/// @nodoc
class $IrcEventCopyWith<$Res>  {
$IrcEventCopyWith(IrcEvent _, $Res Function(IrcEvent) __);
}


/// Adds pattern-matching-related methods to [IrcEvent].
extension IrcEventPatterns on IrcEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( IrcEvent_Status value)?  status,TResult Function( IrcEvent_Registered value)?  registered,TResult Function( IrcEvent_NetworkNamed value)?  networkNamed,TResult Function( IrcEvent_Message value)?  message,TResult Function( IrcEvent_Joined value)?  joined,TResult Function( IrcEvent_Parted value)?  parted,TResult Function( IrcEvent_Quit value)?  quit,TResult Function( IrcEvent_NickChanged value)?  nickChanged,TResult Function( IrcEvent_TopicChanged value)?  topicChanged,TResult Function( IrcEvent_MemberList value)?  memberList,TResult Function( IrcEvent_ModeChanged value)?  modeChanged,TResult Function( IrcEvent_MessagesDropped value)?  messagesDropped,TResult Function( IrcEvent_FileOffered value)?  fileOffered,TResult Function( IrcEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case IrcEvent_Status() when status != null:
return status(_that);case IrcEvent_Registered() when registered != null:
return registered(_that);case IrcEvent_NetworkNamed() when networkNamed != null:
return networkNamed(_that);case IrcEvent_Message() when message != null:
return message(_that);case IrcEvent_Joined() when joined != null:
return joined(_that);case IrcEvent_Parted() when parted != null:
return parted(_that);case IrcEvent_Quit() when quit != null:
return quit(_that);case IrcEvent_NickChanged() when nickChanged != null:
return nickChanged(_that);case IrcEvent_TopicChanged() when topicChanged != null:
return topicChanged(_that);case IrcEvent_MemberList() when memberList != null:
return memberList(_that);case IrcEvent_ModeChanged() when modeChanged != null:
return modeChanged(_that);case IrcEvent_MessagesDropped() when messagesDropped != null:
return messagesDropped(_that);case IrcEvent_FileOffered() when fileOffered != null:
return fileOffered(_that);case IrcEvent_Error() when error != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( IrcEvent_Status value)  status,required TResult Function( IrcEvent_Registered value)  registered,required TResult Function( IrcEvent_NetworkNamed value)  networkNamed,required TResult Function( IrcEvent_Message value)  message,required TResult Function( IrcEvent_Joined value)  joined,required TResult Function( IrcEvent_Parted value)  parted,required TResult Function( IrcEvent_Quit value)  quit,required TResult Function( IrcEvent_NickChanged value)  nickChanged,required TResult Function( IrcEvent_TopicChanged value)  topicChanged,required TResult Function( IrcEvent_MemberList value)  memberList,required TResult Function( IrcEvent_ModeChanged value)  modeChanged,required TResult Function( IrcEvent_MessagesDropped value)  messagesDropped,required TResult Function( IrcEvent_FileOffered value)  fileOffered,required TResult Function( IrcEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case IrcEvent_Status():
return status(_that);case IrcEvent_Registered():
return registered(_that);case IrcEvent_NetworkNamed():
return networkNamed(_that);case IrcEvent_Message():
return message(_that);case IrcEvent_Joined():
return joined(_that);case IrcEvent_Parted():
return parted(_that);case IrcEvent_Quit():
return quit(_that);case IrcEvent_NickChanged():
return nickChanged(_that);case IrcEvent_TopicChanged():
return topicChanged(_that);case IrcEvent_MemberList():
return memberList(_that);case IrcEvent_ModeChanged():
return modeChanged(_that);case IrcEvent_MessagesDropped():
return messagesDropped(_that);case IrcEvent_FileOffered():
return fileOffered(_that);case IrcEvent_Error():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( IrcEvent_Status value)?  status,TResult? Function( IrcEvent_Registered value)?  registered,TResult? Function( IrcEvent_NetworkNamed value)?  networkNamed,TResult? Function( IrcEvent_Message value)?  message,TResult? Function( IrcEvent_Joined value)?  joined,TResult? Function( IrcEvent_Parted value)?  parted,TResult? Function( IrcEvent_Quit value)?  quit,TResult? Function( IrcEvent_NickChanged value)?  nickChanged,TResult? Function( IrcEvent_TopicChanged value)?  topicChanged,TResult? Function( IrcEvent_MemberList value)?  memberList,TResult? Function( IrcEvent_ModeChanged value)?  modeChanged,TResult? Function( IrcEvent_MessagesDropped value)?  messagesDropped,TResult? Function( IrcEvent_FileOffered value)?  fileOffered,TResult? Function( IrcEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case IrcEvent_Status() when status != null:
return status(_that);case IrcEvent_Registered() when registered != null:
return registered(_that);case IrcEvent_NetworkNamed() when networkNamed != null:
return networkNamed(_that);case IrcEvent_Message() when message != null:
return message(_that);case IrcEvent_Joined() when joined != null:
return joined(_that);case IrcEvent_Parted() when parted != null:
return parted(_that);case IrcEvent_Quit() when quit != null:
return quit(_that);case IrcEvent_NickChanged() when nickChanged != null:
return nickChanged(_that);case IrcEvent_TopicChanged() when topicChanged != null:
return topicChanged(_that);case IrcEvent_MemberList() when memberList != null:
return memberList(_that);case IrcEvent_ModeChanged() when modeChanged != null:
return modeChanged(_that);case IrcEvent_MessagesDropped() when messagesDropped != null:
return messagesDropped(_that);case IrcEvent_FileOffered() when fileOffered != null:
return fileOffered(_that);case IrcEvent_Error() when error != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( ConnectionStatus status,  String? detail)?  status,TResult Function( String nick,  String? network,  AuthOutcome auth)?  registered,TResult Function( String network)?  networkNamed,TResult Function( ChatMessage message)?  message,TResult Function( String channel,  String nick,  bool isSelf)?  joined,TResult Function( String channel,  String nick,  bool isSelf,  String? reason)?  parted,TResult Function( String channel,  String nick,  String? reason)?  quit,TResult Function( String channel,  String old,  String new_,  bool isSelf)?  nickChanged,TResult Function( String channel,  String topic,  String? setBy)?  topicChanged,TResult Function( String channel,  List<MemberView> members)?  memberList,TResult Function( String channel,  String? by,  List<String> affected)?  modeChanged,TResult Function( String? channel,  BigInt count)?  messagesDropped,TResult Function( String channel,  String from,  DccOffer offer)?  fileOffered,TResult Function( String message,  bool fatal)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case IrcEvent_Status() when status != null:
return status(_that.status,_that.detail);case IrcEvent_Registered() when registered != null:
return registered(_that.nick,_that.network,_that.auth);case IrcEvent_NetworkNamed() when networkNamed != null:
return networkNamed(_that.network);case IrcEvent_Message() when message != null:
return message(_that.message);case IrcEvent_Joined() when joined != null:
return joined(_that.channel,_that.nick,_that.isSelf);case IrcEvent_Parted() when parted != null:
return parted(_that.channel,_that.nick,_that.isSelf,_that.reason);case IrcEvent_Quit() when quit != null:
return quit(_that.channel,_that.nick,_that.reason);case IrcEvent_NickChanged() when nickChanged != null:
return nickChanged(_that.channel,_that.old,_that.new_,_that.isSelf);case IrcEvent_TopicChanged() when topicChanged != null:
return topicChanged(_that.channel,_that.topic,_that.setBy);case IrcEvent_MemberList() when memberList != null:
return memberList(_that.channel,_that.members);case IrcEvent_ModeChanged() when modeChanged != null:
return modeChanged(_that.channel,_that.by,_that.affected);case IrcEvent_MessagesDropped() when messagesDropped != null:
return messagesDropped(_that.channel,_that.count);case IrcEvent_FileOffered() when fileOffered != null:
return fileOffered(_that.channel,_that.from,_that.offer);case IrcEvent_Error() when error != null:
return error(_that.message,_that.fatal);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( ConnectionStatus status,  String? detail)  status,required TResult Function( String nick,  String? network,  AuthOutcome auth)  registered,required TResult Function( String network)  networkNamed,required TResult Function( ChatMessage message)  message,required TResult Function( String channel,  String nick,  bool isSelf)  joined,required TResult Function( String channel,  String nick,  bool isSelf,  String? reason)  parted,required TResult Function( String channel,  String nick,  String? reason)  quit,required TResult Function( String channel,  String old,  String new_,  bool isSelf)  nickChanged,required TResult Function( String channel,  String topic,  String? setBy)  topicChanged,required TResult Function( String channel,  List<MemberView> members)  memberList,required TResult Function( String channel,  String? by,  List<String> affected)  modeChanged,required TResult Function( String? channel,  BigInt count)  messagesDropped,required TResult Function( String channel,  String from,  DccOffer offer)  fileOffered,required TResult Function( String message,  bool fatal)  error,}) {final _that = this;
switch (_that) {
case IrcEvent_Status():
return status(_that.status,_that.detail);case IrcEvent_Registered():
return registered(_that.nick,_that.network,_that.auth);case IrcEvent_NetworkNamed():
return networkNamed(_that.network);case IrcEvent_Message():
return message(_that.message);case IrcEvent_Joined():
return joined(_that.channel,_that.nick,_that.isSelf);case IrcEvent_Parted():
return parted(_that.channel,_that.nick,_that.isSelf,_that.reason);case IrcEvent_Quit():
return quit(_that.channel,_that.nick,_that.reason);case IrcEvent_NickChanged():
return nickChanged(_that.channel,_that.old,_that.new_,_that.isSelf);case IrcEvent_TopicChanged():
return topicChanged(_that.channel,_that.topic,_that.setBy);case IrcEvent_MemberList():
return memberList(_that.channel,_that.members);case IrcEvent_ModeChanged():
return modeChanged(_that.channel,_that.by,_that.affected);case IrcEvent_MessagesDropped():
return messagesDropped(_that.channel,_that.count);case IrcEvent_FileOffered():
return fileOffered(_that.channel,_that.from,_that.offer);case IrcEvent_Error():
return error(_that.message,_that.fatal);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( ConnectionStatus status,  String? detail)?  status,TResult? Function( String nick,  String? network,  AuthOutcome auth)?  registered,TResult? Function( String network)?  networkNamed,TResult? Function( ChatMessage message)?  message,TResult? Function( String channel,  String nick,  bool isSelf)?  joined,TResult? Function( String channel,  String nick,  bool isSelf,  String? reason)?  parted,TResult? Function( String channel,  String nick,  String? reason)?  quit,TResult? Function( String channel,  String old,  String new_,  bool isSelf)?  nickChanged,TResult? Function( String channel,  String topic,  String? setBy)?  topicChanged,TResult? Function( String channel,  List<MemberView> members)?  memberList,TResult? Function( String channel,  String? by,  List<String> affected)?  modeChanged,TResult? Function( String? channel,  BigInt count)?  messagesDropped,TResult? Function( String channel,  String from,  DccOffer offer)?  fileOffered,TResult? Function( String message,  bool fatal)?  error,}) {final _that = this;
switch (_that) {
case IrcEvent_Status() when status != null:
return status(_that.status,_that.detail);case IrcEvent_Registered() when registered != null:
return registered(_that.nick,_that.network,_that.auth);case IrcEvent_NetworkNamed() when networkNamed != null:
return networkNamed(_that.network);case IrcEvent_Message() when message != null:
return message(_that.message);case IrcEvent_Joined() when joined != null:
return joined(_that.channel,_that.nick,_that.isSelf);case IrcEvent_Parted() when parted != null:
return parted(_that.channel,_that.nick,_that.isSelf,_that.reason);case IrcEvent_Quit() when quit != null:
return quit(_that.channel,_that.nick,_that.reason);case IrcEvent_NickChanged() when nickChanged != null:
return nickChanged(_that.channel,_that.old,_that.new_,_that.isSelf);case IrcEvent_TopicChanged() when topicChanged != null:
return topicChanged(_that.channel,_that.topic,_that.setBy);case IrcEvent_MemberList() when memberList != null:
return memberList(_that.channel,_that.members);case IrcEvent_ModeChanged() when modeChanged != null:
return modeChanged(_that.channel,_that.by,_that.affected);case IrcEvent_MessagesDropped() when messagesDropped != null:
return messagesDropped(_that.channel,_that.count);case IrcEvent_FileOffered() when fileOffered != null:
return fileOffered(_that.channel,_that.from,_that.offer);case IrcEvent_Error() when error != null:
return error(_that.message,_that.fatal);case _:
  return null;

}
}

}

/// @nodoc


class IrcEvent_Status extends IrcEvent {
  const IrcEvent_Status({required this.status, this.detail}): super._();
  

 final  ConnectionStatus status;
 final  String? detail;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_StatusCopyWith<IrcEvent_Status> get copyWith => _$IrcEvent_StatusCopyWithImpl<IrcEvent_Status>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Status&&(identical(other.status, status) || other.status == status)&&(identical(other.detail, detail) || other.detail == detail));
}


@override
int get hashCode => Object.hash(runtimeType,status,detail);

@override
String toString() {
  return 'IrcEvent.status(status: $status, detail: $detail)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_StatusCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_StatusCopyWith(IrcEvent_Status value, $Res Function(IrcEvent_Status) _then) = _$IrcEvent_StatusCopyWithImpl;
@useResult
$Res call({
 ConnectionStatus status, String? detail
});


$ConnectionStatusCopyWith<$Res> get status;

}
/// @nodoc
class _$IrcEvent_StatusCopyWithImpl<$Res>
    implements $IrcEvent_StatusCopyWith<$Res> {
  _$IrcEvent_StatusCopyWithImpl(this._self, this._then);

  final IrcEvent_Status _self;
  final $Res Function(IrcEvent_Status) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? status = null,Object? detail = freezed,}) {
  return _then(IrcEvent_Status(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ConnectionStatus,detail: freezed == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConnectionStatusCopyWith<$Res> get status {
  
  return $ConnectionStatusCopyWith<$Res>(_self.status, (value) {
    return _then(_self.copyWith(status: value));
  });
}
}

/// @nodoc


class IrcEvent_Registered extends IrcEvent {
  const IrcEvent_Registered({required this.nick, this.network, required this.auth}): super._();
  

 final  String nick;
 final  String? network;
 final  AuthOutcome auth;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_RegisteredCopyWith<IrcEvent_Registered> get copyWith => _$IrcEvent_RegisteredCopyWithImpl<IrcEvent_Registered>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Registered&&(identical(other.nick, nick) || other.nick == nick)&&(identical(other.network, network) || other.network == network)&&(identical(other.auth, auth) || other.auth == auth));
}


@override
int get hashCode => Object.hash(runtimeType,nick,network,auth);

@override
String toString() {
  return 'IrcEvent.registered(nick: $nick, network: $network, auth: $auth)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_RegisteredCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_RegisteredCopyWith(IrcEvent_Registered value, $Res Function(IrcEvent_Registered) _then) = _$IrcEvent_RegisteredCopyWithImpl;
@useResult
$Res call({
 String nick, String? network, AuthOutcome auth
});


$AuthOutcomeCopyWith<$Res> get auth;

}
/// @nodoc
class _$IrcEvent_RegisteredCopyWithImpl<$Res>
    implements $IrcEvent_RegisteredCopyWith<$Res> {
  _$IrcEvent_RegisteredCopyWithImpl(this._self, this._then);

  final IrcEvent_Registered _self;
  final $Res Function(IrcEvent_Registered) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nick = null,Object? network = freezed,Object? auth = null,}) {
  return _then(IrcEvent_Registered(
nick: null == nick ? _self.nick : nick // ignore: cast_nullable_to_non_nullable
as String,network: freezed == network ? _self.network : network // ignore: cast_nullable_to_non_nullable
as String?,auth: null == auth ? _self.auth : auth // ignore: cast_nullable_to_non_nullable
as AuthOutcome,
  ));
}

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$AuthOutcomeCopyWith<$Res> get auth {
  
  return $AuthOutcomeCopyWith<$Res>(_self.auth, (value) {
    return _then(_self.copyWith(auth: value));
  });
}
}

/// @nodoc


class IrcEvent_NetworkNamed extends IrcEvent {
  const IrcEvent_NetworkNamed({required this.network}): super._();
  

 final  String network;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_NetworkNamedCopyWith<IrcEvent_NetworkNamed> get copyWith => _$IrcEvent_NetworkNamedCopyWithImpl<IrcEvent_NetworkNamed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_NetworkNamed&&(identical(other.network, network) || other.network == network));
}


@override
int get hashCode => Object.hash(runtimeType,network);

@override
String toString() {
  return 'IrcEvent.networkNamed(network: $network)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_NetworkNamedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_NetworkNamedCopyWith(IrcEvent_NetworkNamed value, $Res Function(IrcEvent_NetworkNamed) _then) = _$IrcEvent_NetworkNamedCopyWithImpl;
@useResult
$Res call({
 String network
});




}
/// @nodoc
class _$IrcEvent_NetworkNamedCopyWithImpl<$Res>
    implements $IrcEvent_NetworkNamedCopyWith<$Res> {
  _$IrcEvent_NetworkNamedCopyWithImpl(this._self, this._then);

  final IrcEvent_NetworkNamed _self;
  final $Res Function(IrcEvent_NetworkNamed) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? network = null,}) {
  return _then(IrcEvent_NetworkNamed(
network: null == network ? _self.network : network // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class IrcEvent_Message extends IrcEvent {
  const IrcEvent_Message({required this.message}): super._();
  

 final  ChatMessage message;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_MessageCopyWith<IrcEvent_Message> get copyWith => _$IrcEvent_MessageCopyWithImpl<IrcEvent_Message>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Message&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'IrcEvent.message(message: $message)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_MessageCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_MessageCopyWith(IrcEvent_Message value, $Res Function(IrcEvent_Message) _then) = _$IrcEvent_MessageCopyWithImpl;
@useResult
$Res call({
 ChatMessage message
});




}
/// @nodoc
class _$IrcEvent_MessageCopyWithImpl<$Res>
    implements $IrcEvent_MessageCopyWith<$Res> {
  _$IrcEvent_MessageCopyWithImpl(this._self, this._then);

  final IrcEvent_Message _self;
  final $Res Function(IrcEvent_Message) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(IrcEvent_Message(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as ChatMessage,
  ));
}


}

/// @nodoc


class IrcEvent_Joined extends IrcEvent {
  const IrcEvent_Joined({required this.channel, required this.nick, required this.isSelf}): super._();
  

 final  String channel;
 final  String nick;
 final  bool isSelf;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_JoinedCopyWith<IrcEvent_Joined> get copyWith => _$IrcEvent_JoinedCopyWithImpl<IrcEvent_Joined>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Joined&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.nick, nick) || other.nick == nick)&&(identical(other.isSelf, isSelf) || other.isSelf == isSelf));
}


@override
int get hashCode => Object.hash(runtimeType,channel,nick,isSelf);

@override
String toString() {
  return 'IrcEvent.joined(channel: $channel, nick: $nick, isSelf: $isSelf)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_JoinedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_JoinedCopyWith(IrcEvent_Joined value, $Res Function(IrcEvent_Joined) _then) = _$IrcEvent_JoinedCopyWithImpl;
@useResult
$Res call({
 String channel, String nick, bool isSelf
});




}
/// @nodoc
class _$IrcEvent_JoinedCopyWithImpl<$Res>
    implements $IrcEvent_JoinedCopyWith<$Res> {
  _$IrcEvent_JoinedCopyWithImpl(this._self, this._then);

  final IrcEvent_Joined _self;
  final $Res Function(IrcEvent_Joined) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? nick = null,Object? isSelf = null,}) {
  return _then(IrcEvent_Joined(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,nick: null == nick ? _self.nick : nick // ignore: cast_nullable_to_non_nullable
as String,isSelf: null == isSelf ? _self.isSelf : isSelf // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class IrcEvent_Parted extends IrcEvent {
  const IrcEvent_Parted({required this.channel, required this.nick, required this.isSelf, this.reason}): super._();
  

 final  String channel;
 final  String nick;
 final  bool isSelf;
 final  String? reason;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_PartedCopyWith<IrcEvent_Parted> get copyWith => _$IrcEvent_PartedCopyWithImpl<IrcEvent_Parted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Parted&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.nick, nick) || other.nick == nick)&&(identical(other.isSelf, isSelf) || other.isSelf == isSelf)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,channel,nick,isSelf,reason);

@override
String toString() {
  return 'IrcEvent.parted(channel: $channel, nick: $nick, isSelf: $isSelf, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_PartedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_PartedCopyWith(IrcEvent_Parted value, $Res Function(IrcEvent_Parted) _then) = _$IrcEvent_PartedCopyWithImpl;
@useResult
$Res call({
 String channel, String nick, bool isSelf, String? reason
});




}
/// @nodoc
class _$IrcEvent_PartedCopyWithImpl<$Res>
    implements $IrcEvent_PartedCopyWith<$Res> {
  _$IrcEvent_PartedCopyWithImpl(this._self, this._then);

  final IrcEvent_Parted _self;
  final $Res Function(IrcEvent_Parted) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? nick = null,Object? isSelf = null,Object? reason = freezed,}) {
  return _then(IrcEvent_Parted(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,nick: null == nick ? _self.nick : nick // ignore: cast_nullable_to_non_nullable
as String,isSelf: null == isSelf ? _self.isSelf : isSelf // ignore: cast_nullable_to_non_nullable
as bool,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class IrcEvent_Quit extends IrcEvent {
  const IrcEvent_Quit({required this.channel, required this.nick, this.reason}): super._();
  

 final  String channel;
 final  String nick;
 final  String? reason;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_QuitCopyWith<IrcEvent_Quit> get copyWith => _$IrcEvent_QuitCopyWithImpl<IrcEvent_Quit>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Quit&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.nick, nick) || other.nick == nick)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,channel,nick,reason);

@override
String toString() {
  return 'IrcEvent.quit(channel: $channel, nick: $nick, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_QuitCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_QuitCopyWith(IrcEvent_Quit value, $Res Function(IrcEvent_Quit) _then) = _$IrcEvent_QuitCopyWithImpl;
@useResult
$Res call({
 String channel, String nick, String? reason
});




}
/// @nodoc
class _$IrcEvent_QuitCopyWithImpl<$Res>
    implements $IrcEvent_QuitCopyWith<$Res> {
  _$IrcEvent_QuitCopyWithImpl(this._self, this._then);

  final IrcEvent_Quit _self;
  final $Res Function(IrcEvent_Quit) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? nick = null,Object? reason = freezed,}) {
  return _then(IrcEvent_Quit(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,nick: null == nick ? _self.nick : nick // ignore: cast_nullable_to_non_nullable
as String,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class IrcEvent_NickChanged extends IrcEvent {
  const IrcEvent_NickChanged({required this.channel, required this.old, required this.new_, required this.isSelf}): super._();
  

 final  String channel;
 final  String old;
 final  String new_;
 final  bool isSelf;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_NickChangedCopyWith<IrcEvent_NickChanged> get copyWith => _$IrcEvent_NickChangedCopyWithImpl<IrcEvent_NickChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_NickChanged&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.old, old) || other.old == old)&&(identical(other.new_, new_) || other.new_ == new_)&&(identical(other.isSelf, isSelf) || other.isSelf == isSelf));
}


@override
int get hashCode => Object.hash(runtimeType,channel,old,new_,isSelf);

@override
String toString() {
  return 'IrcEvent.nickChanged(channel: $channel, old: $old, new_: $new_, isSelf: $isSelf)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_NickChangedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_NickChangedCopyWith(IrcEvent_NickChanged value, $Res Function(IrcEvent_NickChanged) _then) = _$IrcEvent_NickChangedCopyWithImpl;
@useResult
$Res call({
 String channel, String old, String new_, bool isSelf
});




}
/// @nodoc
class _$IrcEvent_NickChangedCopyWithImpl<$Res>
    implements $IrcEvent_NickChangedCopyWith<$Res> {
  _$IrcEvent_NickChangedCopyWithImpl(this._self, this._then);

  final IrcEvent_NickChanged _self;
  final $Res Function(IrcEvent_NickChanged) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? old = null,Object? new_ = null,Object? isSelf = null,}) {
  return _then(IrcEvent_NickChanged(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,old: null == old ? _self.old : old // ignore: cast_nullable_to_non_nullable
as String,new_: null == new_ ? _self.new_ : new_ // ignore: cast_nullable_to_non_nullable
as String,isSelf: null == isSelf ? _self.isSelf : isSelf // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class IrcEvent_TopicChanged extends IrcEvent {
  const IrcEvent_TopicChanged({required this.channel, required this.topic, this.setBy}): super._();
  

 final  String channel;
 final  String topic;
 final  String? setBy;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_TopicChangedCopyWith<IrcEvent_TopicChanged> get copyWith => _$IrcEvent_TopicChangedCopyWithImpl<IrcEvent_TopicChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_TopicChanged&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.topic, topic) || other.topic == topic)&&(identical(other.setBy, setBy) || other.setBy == setBy));
}


@override
int get hashCode => Object.hash(runtimeType,channel,topic,setBy);

@override
String toString() {
  return 'IrcEvent.topicChanged(channel: $channel, topic: $topic, setBy: $setBy)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_TopicChangedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_TopicChangedCopyWith(IrcEvent_TopicChanged value, $Res Function(IrcEvent_TopicChanged) _then) = _$IrcEvent_TopicChangedCopyWithImpl;
@useResult
$Res call({
 String channel, String topic, String? setBy
});




}
/// @nodoc
class _$IrcEvent_TopicChangedCopyWithImpl<$Res>
    implements $IrcEvent_TopicChangedCopyWith<$Res> {
  _$IrcEvent_TopicChangedCopyWithImpl(this._self, this._then);

  final IrcEvent_TopicChanged _self;
  final $Res Function(IrcEvent_TopicChanged) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? topic = null,Object? setBy = freezed,}) {
  return _then(IrcEvent_TopicChanged(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,topic: null == topic ? _self.topic : topic // ignore: cast_nullable_to_non_nullable
as String,setBy: freezed == setBy ? _self.setBy : setBy // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class IrcEvent_MemberList extends IrcEvent {
  const IrcEvent_MemberList({required this.channel, required final  List<MemberView> members}): _members = members,super._();
  

 final  String channel;
 final  List<MemberView> _members;
 List<MemberView> get members {
  if (_members is EqualUnmodifiableListView) return _members;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_members);
}


/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_MemberListCopyWith<IrcEvent_MemberList> get copyWith => _$IrcEvent_MemberListCopyWithImpl<IrcEvent_MemberList>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_MemberList&&(identical(other.channel, channel) || other.channel == channel)&&const DeepCollectionEquality().equals(other._members, _members));
}


@override
int get hashCode => Object.hash(runtimeType,channel,const DeepCollectionEquality().hash(_members));

@override
String toString() {
  return 'IrcEvent.memberList(channel: $channel, members: $members)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_MemberListCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_MemberListCopyWith(IrcEvent_MemberList value, $Res Function(IrcEvent_MemberList) _then) = _$IrcEvent_MemberListCopyWithImpl;
@useResult
$Res call({
 String channel, List<MemberView> members
});




}
/// @nodoc
class _$IrcEvent_MemberListCopyWithImpl<$Res>
    implements $IrcEvent_MemberListCopyWith<$Res> {
  _$IrcEvent_MemberListCopyWithImpl(this._self, this._then);

  final IrcEvent_MemberList _self;
  final $Res Function(IrcEvent_MemberList) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? members = null,}) {
  return _then(IrcEvent_MemberList(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,members: null == members ? _self._members : members // ignore: cast_nullable_to_non_nullable
as List<MemberView>,
  ));
}


}

/// @nodoc


class IrcEvent_ModeChanged extends IrcEvent {
  const IrcEvent_ModeChanged({required this.channel, this.by, required final  List<String> affected}): _affected = affected,super._();
  

 final  String channel;
 final  String? by;
 final  List<String> _affected;
 List<String> get affected {
  if (_affected is EqualUnmodifiableListView) return _affected;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_affected);
}


/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_ModeChangedCopyWith<IrcEvent_ModeChanged> get copyWith => _$IrcEvent_ModeChangedCopyWithImpl<IrcEvent_ModeChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_ModeChanged&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.by, by) || other.by == by)&&const DeepCollectionEquality().equals(other._affected, _affected));
}


@override
int get hashCode => Object.hash(runtimeType,channel,by,const DeepCollectionEquality().hash(_affected));

@override
String toString() {
  return 'IrcEvent.modeChanged(channel: $channel, by: $by, affected: $affected)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_ModeChangedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_ModeChangedCopyWith(IrcEvent_ModeChanged value, $Res Function(IrcEvent_ModeChanged) _then) = _$IrcEvent_ModeChangedCopyWithImpl;
@useResult
$Res call({
 String channel, String? by, List<String> affected
});




}
/// @nodoc
class _$IrcEvent_ModeChangedCopyWithImpl<$Res>
    implements $IrcEvent_ModeChangedCopyWith<$Res> {
  _$IrcEvent_ModeChangedCopyWithImpl(this._self, this._then);

  final IrcEvent_ModeChanged _self;
  final $Res Function(IrcEvent_ModeChanged) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? by = freezed,Object? affected = null,}) {
  return _then(IrcEvent_ModeChanged(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,by: freezed == by ? _self.by : by // ignore: cast_nullable_to_non_nullable
as String?,affected: null == affected ? _self._affected : affected // ignore: cast_nullable_to_non_nullable
as List<String>,
  ));
}


}

/// @nodoc


class IrcEvent_MessagesDropped extends IrcEvent {
  const IrcEvent_MessagesDropped({this.channel, required this.count}): super._();
  

 final  String? channel;
 final  BigInt count;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_MessagesDroppedCopyWith<IrcEvent_MessagesDropped> get copyWith => _$IrcEvent_MessagesDroppedCopyWithImpl<IrcEvent_MessagesDropped>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_MessagesDropped&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.count, count) || other.count == count));
}


@override
int get hashCode => Object.hash(runtimeType,channel,count);

@override
String toString() {
  return 'IrcEvent.messagesDropped(channel: $channel, count: $count)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_MessagesDroppedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_MessagesDroppedCopyWith(IrcEvent_MessagesDropped value, $Res Function(IrcEvent_MessagesDropped) _then) = _$IrcEvent_MessagesDroppedCopyWithImpl;
@useResult
$Res call({
 String? channel, BigInt count
});




}
/// @nodoc
class _$IrcEvent_MessagesDroppedCopyWithImpl<$Res>
    implements $IrcEvent_MessagesDroppedCopyWith<$Res> {
  _$IrcEvent_MessagesDroppedCopyWithImpl(this._self, this._then);

  final IrcEvent_MessagesDropped _self;
  final $Res Function(IrcEvent_MessagesDropped) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = freezed,Object? count = null,}) {
  return _then(IrcEvent_MessagesDropped(
channel: freezed == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String?,count: null == count ? _self.count : count // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class IrcEvent_FileOffered extends IrcEvent {
  const IrcEvent_FileOffered({required this.channel, required this.from, required this.offer}): super._();
  

/// Where it arrived: a channel, or the sender's nick for a direct
/// message.
 final  String channel;
 final  String from;
 final  DccOffer offer;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_FileOfferedCopyWith<IrcEvent_FileOffered> get copyWith => _$IrcEvent_FileOfferedCopyWithImpl<IrcEvent_FileOffered>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_FileOffered&&(identical(other.channel, channel) || other.channel == channel)&&(identical(other.from, from) || other.from == from)&&(identical(other.offer, offer) || other.offer == offer));
}


@override
int get hashCode => Object.hash(runtimeType,channel,from,offer);

@override
String toString() {
  return 'IrcEvent.fileOffered(channel: $channel, from: $from, offer: $offer)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_FileOfferedCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_FileOfferedCopyWith(IrcEvent_FileOffered value, $Res Function(IrcEvent_FileOffered) _then) = _$IrcEvent_FileOfferedCopyWithImpl;
@useResult
$Res call({
 String channel, String from, DccOffer offer
});




}
/// @nodoc
class _$IrcEvent_FileOfferedCopyWithImpl<$Res>
    implements $IrcEvent_FileOfferedCopyWith<$Res> {
  _$IrcEvent_FileOfferedCopyWithImpl(this._self, this._then);

  final IrcEvent_FileOffered _self;
  final $Res Function(IrcEvent_FileOffered) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? channel = null,Object? from = null,Object? offer = null,}) {
  return _then(IrcEvent_FileOffered(
channel: null == channel ? _self.channel : channel // ignore: cast_nullable_to_non_nullable
as String,from: null == from ? _self.from : from // ignore: cast_nullable_to_non_nullable
as String,offer: null == offer ? _self.offer : offer // ignore: cast_nullable_to_non_nullable
as DccOffer,
  ));
}


}

/// @nodoc


class IrcEvent_Error extends IrcEvent {
  const IrcEvent_Error({required this.message, required this.fatal}): super._();
  

 final  String message;
 final  bool fatal;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IrcEvent_ErrorCopyWith<IrcEvent_Error> get copyWith => _$IrcEvent_ErrorCopyWithImpl<IrcEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is IrcEvent_Error&&(identical(other.message, message) || other.message == message)&&(identical(other.fatal, fatal) || other.fatal == fatal));
}


@override
int get hashCode => Object.hash(runtimeType,message,fatal);

@override
String toString() {
  return 'IrcEvent.error(message: $message, fatal: $fatal)';
}


}

/// @nodoc
abstract mixin class $IrcEvent_ErrorCopyWith<$Res> implements $IrcEventCopyWith<$Res> {
  factory $IrcEvent_ErrorCopyWith(IrcEvent_Error value, $Res Function(IrcEvent_Error) _then) = _$IrcEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message, bool fatal
});




}
/// @nodoc
class _$IrcEvent_ErrorCopyWithImpl<$Res>
    implements $IrcEvent_ErrorCopyWith<$Res> {
  _$IrcEvent_ErrorCopyWithImpl(this._self, this._then);

  final IrcEvent_Error _self;
  final $Res Function(IrcEvent_Error) _then;

/// Create a copy of IrcEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,Object? fatal = null,}) {
  return _then(IrcEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,fatal: null == fatal ? _self.fatal : fatal // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc
mixin _$Target {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Target);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'Target()';
}


}

/// @nodoc
class $TargetCopyWith<$Res>  {
$TargetCopyWith(Target _, $Res Function(Target) __);
}


/// Adds pattern-matching-related methods to [Target].
extension TargetPatterns on Target {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Target_Channel value)?  channel,TResult Function( Target_Direct value)?  direct,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Target_Channel() when channel != null:
return channel(_that);case Target_Direct() when direct != null:
return direct(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Target_Channel value)  channel,required TResult Function( Target_Direct value)  direct,}){
final _that = this;
switch (_that) {
case Target_Channel():
return channel(_that);case Target_Direct():
return direct(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Target_Channel value)?  channel,TResult? Function( Target_Direct value)?  direct,}){
final _that = this;
switch (_that) {
case Target_Channel() when channel != null:
return channel(_that);case Target_Direct() when direct != null:
return direct(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String name)?  channel,TResult Function( String nick)?  direct,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Target_Channel() when channel != null:
return channel(_that.name);case Target_Direct() when direct != null:
return direct(_that.nick);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String name)  channel,required TResult Function( String nick)  direct,}) {final _that = this;
switch (_that) {
case Target_Channel():
return channel(_that.name);case Target_Direct():
return direct(_that.nick);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String name)?  channel,TResult? Function( String nick)?  direct,}) {final _that = this;
switch (_that) {
case Target_Channel() when channel != null:
return channel(_that.name);case Target_Direct() when direct != null:
return direct(_that.nick);case _:
  return null;

}
}

}

/// @nodoc


class Target_Channel extends Target {
  const Target_Channel({required this.name}): super._();
  

 final  String name;

/// Create a copy of Target
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Target_ChannelCopyWith<Target_Channel> get copyWith => _$Target_ChannelCopyWithImpl<Target_Channel>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Target_Channel&&(identical(other.name, name) || other.name == name));
}


@override
int get hashCode => Object.hash(runtimeType,name);

@override
String toString() {
  return 'Target.channel(name: $name)';
}


}

/// @nodoc
abstract mixin class $Target_ChannelCopyWith<$Res> implements $TargetCopyWith<$Res> {
  factory $Target_ChannelCopyWith(Target_Channel value, $Res Function(Target_Channel) _then) = _$Target_ChannelCopyWithImpl;
@useResult
$Res call({
 String name
});




}
/// @nodoc
class _$Target_ChannelCopyWithImpl<$Res>
    implements $Target_ChannelCopyWith<$Res> {
  _$Target_ChannelCopyWithImpl(this._self, this._then);

  final Target_Channel _self;
  final $Res Function(Target_Channel) _then;

/// Create a copy of Target
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,}) {
  return _then(Target_Channel(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class Target_Direct extends Target {
  const Target_Direct({required this.nick}): super._();
  

 final  String nick;

/// Create a copy of Target
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$Target_DirectCopyWith<Target_Direct> get copyWith => _$Target_DirectCopyWithImpl<Target_Direct>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Target_Direct&&(identical(other.nick, nick) || other.nick == nick));
}


@override
int get hashCode => Object.hash(runtimeType,nick);

@override
String toString() {
  return 'Target.direct(nick: $nick)';
}


}

/// @nodoc
abstract mixin class $Target_DirectCopyWith<$Res> implements $TargetCopyWith<$Res> {
  factory $Target_DirectCopyWith(Target_Direct value, $Res Function(Target_Direct) _then) = _$Target_DirectCopyWithImpl;
@useResult
$Res call({
 String nick
});




}
/// @nodoc
class _$Target_DirectCopyWithImpl<$Res>
    implements $Target_DirectCopyWith<$Res> {
  _$Target_DirectCopyWithImpl(this._self, this._then);

  final Target_Direct _self;
  final $Res Function(Target_Direct) _then;

/// Create a copy of Target
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? nick = null,}) {
  return _then(Target_Direct(
nick: null == nick ? _self.nick : nick // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
