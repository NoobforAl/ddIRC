# Release builds are shrunk and renamed by R8. Most of the app never notices;
# the code that finds things *by name* does.
#
# shared_preferences_android (2.5) is called from Dart through JNI: each Kotlin
# method is looked up by its name and its descriptor, written out in the Dart
# bindings as, for example,
#   getAll(Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;
# and the suspend-function plumbing around it looks up a few more Kotlin classes
# by name. R8 renames or removes whatever nothing visible refers to - it turned
# kotlin.coroutines.Continuation into something like g6.c, and dropped
# kotlin.coroutines.intrinsics.CoroutineSingletons - so the lookup fails, with
# NoSuchMethodError or ClassNotFoundException, in a release build only. That is
# why nothing caught it.
#
# The app reads every preference at start and, by design, treats a preference it
# cannot read as "not set": with this missing, a release build started with no
# saved networks, default settings, the app lock off, the built-in Tor off and
# the first-run screen showing, however much was saved.
#
# So the classes those bindings name keep their names and their members: the
# plugin's own, and the Kotlin ones its descriptors and Class.forName calls reach
# (the list is the output of `grep kotlin lib/` over the bindings and the jni
# packages). android/check-release-apk.sh checks the result.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.enums.EnumEntries { *; }
-keepnames class kotlin.jvm.internal.DefaultConstructorMarker
