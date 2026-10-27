# SPDX-License-Identifier: MIT
# Copyright (c) 2026 ChromVoid LLC

LOCAL_PATH := $(call my-dir)
WAYVEIL_HEV_JNI := $(LOCAL_PATH)/hev-jni.c

include $(HEV_SOURCE_DIR)/third-part/yaml/Android.mk
include $(HEV_SOURCE_DIR)/third-part/lwip/Android.mk
ENABLE_MEMALLOC_SLICE := 0
include $(HEV_SOURCE_DIR)/third-part/hev-task-system/Android.mk

LOCAL_PATH := $(HEV_SOURCE_DIR)
SRCDIR := $(LOCAL_PATH)/src
include $(LOCAL_PATH)/build.mk
WAYVEIL_HEV_SOURCES := $(filter-out src/hev-jni.c,$(patsubst $(SRCDIR)/%,src/%,$(SRCFILES)))

include $(CLEAR_VARS)
LOCAL_MODULE := wayveilhev
LOCAL_SRC_FILES := $(WAYVEIL_HEV_SOURCES) $(WAYVEIL_HEV_JNI)
LOCAL_C_INCLUDES := \
    $(HEV_SOURCE_DIR)/src \
    $(HEV_SOURCE_DIR)/src/misc \
    $(HEV_SOURCE_DIR)/src/core/include \
    $(HEV_SOURCE_DIR)/third-part/yaml/include \
    $(HEV_SOURCE_DIR)/third-part/lwip/src/include \
    $(HEV_SOURCE_DIR)/third-part/lwip/src/ports/include \
    $(HEV_SOURCE_DIR)/third-part/hev-task-system/include
LOCAL_CFLAGS := -O3 -DFD_SET_DEFINED -DSOCKLEN_T_DEFINED -DENABLE_LIBRARY \
    -fno-stack-clash-protection $(VERSION_CFLAGS)
LOCAL_STATIC_LIBRARIES := yaml lwip libhev-task-system
LOCAL_LDFLAGS := -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384
include $(BUILD_SHARED_LIBRARY)
