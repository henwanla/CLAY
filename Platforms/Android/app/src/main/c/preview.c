#include <jni.h>
#include <stdint.h>
#include <string.h>

extern int32_t clay_android_preview(int32_t, const uint8_t *, int32_t, const uint8_t *, int32_t,
                                    int32_t, uint8_t *, int32_t);

JNIEXPORT jbyteArray JNICALL Java_org_clayrelay_preview_NativePreview_00024Library_call(
        JNIEnv *env, jclass cls, jint operation, jbyteArray source, jbyteArray target, jint options) {
    (void)cls;
    const jsize source_size = (*env)->GetArrayLength(env, source);
    const jsize target_size = (*env)->GetArrayLength(env, target);
    uint8_t output[16384];
    int32_t length = -1;
    if (source_size <= 2 * 1024 * 1024 && target_size <= 16384) {
        jbyte *source_bytes = source_size ? (*env)->GetByteArrayElements(env, source, NULL) : NULL;
        if ((*env)->ExceptionCheck(env)) return NULL;
        jbyte *target_bytes = target_size ? (*env)->GetByteArrayElements(env, target, NULL) : NULL;
        if (!(*env)->ExceptionCheck(env)) {
            length = clay_android_preview(operation, (const uint8_t *)source_bytes, source_size,
                    (const uint8_t *)target_bytes, target_size, options, output, sizeof(output));
        }
        if (target_bytes) (*env)->ReleaseByteArrayElements(env, target, target_bytes, JNI_ABORT);
        if (source_bytes) (*env)->ReleaseByteArrayElements(env, source, source_bytes, JNI_ABORT);
        if ((*env)->ExceptionCheck(env)) return NULL;
    } else {
        const char *error = source_size > 2 * 1024 * 1024 ?
                "{\"error\":\"inputTooLarge\"}" : "{\"error\":\"invalidHost\"}";
        length = (int32_t)strlen(error);
        memcpy(output, error, (size_t)length);
    }
    if (length < 0) {
        const char error[] = "{\"error\":\"previewFailed\"}";
        length = sizeof(error) - 1;
        memcpy(output, error, (size_t)length);
    }
    jbyteArray result = (*env)->NewByteArray(env, length);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, length, (const jbyte *)output);
    return result;
}
