#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern int32_t clay_android_preview(int32_t, const uint8_t *, int32_t, const uint8_t *, int32_t,
                                    int32_t, uint8_t *, int32_t);
extern int32_t clay_android_config(const uint8_t *, int32_t, const uint8_t *, int32_t, uint8_t *, int32_t);

JNIEXPORT jbyteArray JNICALL Java_org_clayrelay_preview_NativePreview_00024Library_config(
        JNIEnv *env, jclass cls, jbyteArray source, jbyteArray request) {
    (void)cls;
    const jsize length = (*env)->GetArrayLength(env, source);
    const jsize request_length = (*env)->GetArrayLength(env, request);
    const int32_t limit = 2 * 1024 * 1024;
    if (length <= 0 || length > limit || request_length <= 0 || request_length > 16384) return NULL;
    jbyte *input = (*env)->GetByteArrayElements(env, source, NULL);
    if (!input) return NULL;
    jbyte *options = (*env)->GetByteArrayElements(env, request, NULL);
    uint8_t *output = options ? malloc(limit) : NULL;
    int32_t count = output ? clay_android_config((const uint8_t *)input, length, (const uint8_t *)options,
                                                  request_length, output, limit) : -1;
    if (options) (*env)->ReleaseByteArrayElements(env, request, options, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, source, input, JNI_ABORT);
    jbyteArray result = count > 0 ? (*env)->NewByteArray(env, count) : NULL;
    if (result) (*env)->SetByteArrayRegion(env, result, 0, count, (const jbyte *)output);
    if (count > 0) {
        volatile uint8_t *bytes = output;
        for (int32_t i = 0; i < count; i++) bytes[i] = 0;
    }
    free(output);
    return result;
}

JNIEXPORT jbyteArray JNICALL Java_org_clayrelay_preview_NativePreview_00024Library_call(
        JNIEnv *env, jclass cls, jint operation, jbyteArray source, jbyteArray target, jint options) {
    (void)cls;
    const jsize source_size = (*env)->GetArrayLength(env, source);
    const jsize target_size = (*env)->GetArrayLength(env, target);
    uint8_t output[32768];
    const int32_t capacity = operation == 2 ? sizeof(output) : 16384;
    int32_t length = -1;
    if (source_size <= 2 * 1024 * 1024 && target_size <= 16384) {
        jbyte *source_bytes = source_size ? (*env)->GetByteArrayElements(env, source, NULL) : NULL;
        if ((*env)->ExceptionCheck(env)) return NULL;
        jbyte *target_bytes = target_size ? (*env)->GetByteArrayElements(env, target, NULL) : NULL;
        if (!(*env)->ExceptionCheck(env)) {
            length = clay_android_preview(operation, (const uint8_t *)source_bytes, source_size,
                    (const uint8_t *)target_bytes, target_size, options, output, capacity);
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
    if (operation == 2) {
        volatile uint8_t *bytes = output;
        for (int32_t i = 0; i < length; i++) bytes[i] = 0;
    }
    return result;
}
