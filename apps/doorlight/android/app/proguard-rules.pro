# jami-core's SWIG JNI_OnLoad registers this whole generated API by exact class, method, and signature.
# Keep the binding surface intact even when a Java overload has no direct application call site.
-keep class net.jami.daemon.** { *; }
