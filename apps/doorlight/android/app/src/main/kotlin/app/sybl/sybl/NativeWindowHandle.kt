package app.sybl.sybl

/**
 * JNI returns an ANativeWindow pointer as a signed jlong. A valid arm64 address may compare negative after that
 * bit-preserving cast, so null is the only invalid handle value.
 */
internal fun hasNativeWindow(handle: Long): Boolean = handle != 0L
