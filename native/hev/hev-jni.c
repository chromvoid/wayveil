/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 ChromVoid LLC */

#include <jni.h>
#include <pthread.h>
#include <stddef.h>
#include <unistd.h>

#include "hev-main.h"

static pthread_mutex_t lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static int scheduled;
static int running;
static int canceled;

JNIEXPORT void JNICALL
Java_app_wayveil_HevTunnel_prepare(JNIEnv *env, jclass cls)
{
    (void)cls;
    pthread_mutex_lock(&lifecycle_lock);
    if (scheduled || running) {
        pthread_mutex_unlock(&lifecycle_lock);
        jclass exception = (*env)->FindClass(env, "java/lang/IllegalStateException");
        if (exception)
            (*env)->ThrowNew(env, exception, "The previous tunnel worker has not stopped.");
        return;
    }
    hev_socks5_tunnel_reset();
    scheduled = 1;
    canceled = 0;
    pthread_mutex_unlock(&lifecycle_lock);
}

JNIEXPORT jint JNICALL
Java_app_wayveil_HevTunnel_run(JNIEnv *env, jclass cls, jstring config, jint fd)
{
    (void)cls;
    const char *text = NULL;
    int result = -1;
    if (config && fd >= 0)
        text = (*env)->GetStringUTFChars(env, config, NULL);

    pthread_mutex_lock(&lifecycle_lock);
    if (!scheduled || running) {
        pthread_mutex_unlock(&lifecycle_lock);
        goto done;
    }
    scheduled = 0;
    if (canceled || !text) {
        canceled = 0;
        pthread_mutex_unlock(&lifecycle_lock);
        result = text ? 0 : -1;
        goto done;
    }
    running = 1;
    pthread_mutex_unlock(&lifecycle_lock);

    result = hev_socks5_tunnel_main_from_str(
        (const unsigned char *)text,
        (unsigned int)(*env)->GetStringUTFLength(env, config), fd);

    pthread_mutex_lock(&lifecycle_lock);
    running = 0;
    canceled = 0;
    pthread_mutex_unlock(&lifecycle_lock);
done:
    if (text)
        (*env)->ReleaseStringUTFChars(env, config, text);
    if (fd >= 0)
        close(fd);
    return result;
}

JNIEXPORT void JNICALL
Java_app_wayveil_HevTunnel_stop(JNIEnv *env, jclass cls)
{
    (void)env;
    (void)cls;
    pthread_mutex_lock(&lifecycle_lock);
    canceled = scheduled || running;
    if (running)
        hev_socks5_tunnel_quit();
    pthread_mutex_unlock(&lifecycle_lock);
}

JNIEXPORT jlongArray JNICALL
Java_app_wayveil_HevTunnel_stats(JNIEnv *env, jclass cls)
{
    (void)cls;
    size_t tx_packets = 0, tx_bytes = 0, rx_packets = 0, rx_bytes = 0;
    hev_socks5_tunnel_stats(&tx_packets, &tx_bytes, &rx_packets, &rx_bytes);
    const jlong values[] = {(jlong)tx_packets, (jlong)tx_bytes,
                           (jlong)rx_packets, (jlong)rx_bytes};
    jlongArray result = (*env)->NewLongArray(env, 4);
    if (result)
        (*env)->SetLongArrayRegion(env, result, 0, 4, values);
    return result;
}
