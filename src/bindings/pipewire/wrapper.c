// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of vergebar.
//
// Copyright (c) 2026 lumexren
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

// PipeWire native C API wrapper for zero-subprocess audio volume control.

#define _GNU_SOURCE
#include <locale.h>
#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/pod/parser.h>
#include <spa/pod/iter.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

struct NodeInfo {
    uint32_t id;
    char name[128];
    char desc[128];
    struct pw_node *proxy;
    struct spa_hook listener;
    float volume; // linear volume
    bool muted;
    uint32_t n_channels;
    float channel_volumes[8];
};

struct ActiveStream {
    uint32_t id;
    bool is_audio_in;
    bool is_video_in;
};

#define MAX_ACTIVE_STREAMS 64
static struct ActiveStream g_active_streams[MAX_ACTIVE_STREAMS];
static size_t g_active_stream_count = 0;

static struct pw_thread_loop *g_loop = NULL;
static struct pw_context *g_context = NULL;
static struct pw_core *g_core = NULL;
static struct pw_registry *g_registry = NULL;
static struct spa_hook g_registry_listener;
static struct pw_metadata *g_metadata = NULL;
static struct spa_hook g_metadata_listener;

static char g_target_sink_name[128] = "";
static struct NodeInfo g_current_sink = {0};
static bool g_initialized = false;

static void node_param(void *data, int seq, uint32_t id,
                       uint32_t index, uint32_t next,
                       const struct spa_pod *param) {
    (void)seq; (void)index; (void)next;
    struct NodeInfo *node = (struct NodeInfo *)data;
    if (!param || id != SPA_PARAM_Props) return;

    const struct spa_pod_prop *prop;
    const struct spa_pod_object *obj = (const struct spa_pod_object *)param;

    SPA_POD_OBJECT_FOREACH(obj, prop) {
        if (prop->key == SPA_PROP_mute) {
            bool mute_val = false;
            if (spa_pod_get_bool(&prop->value, &mute_val) == 0) {
                node->muted = mute_val;
            }
        } else if (prop->key == SPA_PROP_channelVolumes) {
            uint32_t n_vals = 0;
            float *vals = spa_pod_get_array(&prop->value, &n_vals);
            if (vals && n_vals > 0) {
                node->n_channels = n_vals > 8 ? 8 : n_vals;
                for (uint32_t i = 0; i < node->n_channels; i++) {
                    node->channel_volumes[i] = vals[i];
                }
                node->volume = vals[0];
            }
        } else if (prop->key == SPA_PROP_volume) {
            float vol_val = 0.0f;
            if (spa_pod_get_float(&prop->value, &vol_val) == 0) {
                node->volume = vol_val;
            }
        }
    }
}

static const struct pw_node_events g_node_events = {
    PW_VERSION_NODE_EVENTS,
    .param = node_param,
};

static void check_bind_sink(struct NodeInfo *node) {
    if (node->id == 0 || node->name[0] == '\0') return;
    if (g_target_sink_name[0] != '\0' && strstr(g_target_sink_name, node->name) != NULL) {
        if (!node->proxy && g_registry) {
            node->proxy = pw_registry_bind(g_registry, node->id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
            if (node->proxy) {
                pw_node_add_listener(node->proxy, &node->listener, &g_node_events, node);
                uint32_t ids[] = { SPA_PARAM_Props };
                pw_node_subscribe_params(node->proxy, ids, 1);
            }
        }
    }
}

static int metadata_property(void *data, uint32_t subject, const char *key,
                             const char *type, const char *value) {
    (void)data; (void)subject; (void)type;
    if (key && strcmp(key, "default.audio.sink") == 0 && value) {
        snprintf(g_target_sink_name, sizeof(g_target_sink_name), "%s", value);
        check_bind_sink(&g_current_sink);
    }
    return 0;
}

static const struct pw_metadata_events g_metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = metadata_property,
};

static void registry_global(void *data, uint32_t id, uint32_t permissions,
                            const char *type, uint32_t version,
                            const struct spa_dict *props) {
    (void)data; (void)permissions; (void)version;
    if (props && strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
        const char *name = spa_dict_lookup(props, "metadata.name");
        if (name && strcmp(name, "default") == 0 && g_registry) {
            g_metadata = pw_registry_bind(g_registry, id, type, PW_VERSION_METADATA, 0);
            if (g_metadata) {
                pw_metadata_add_listener(g_metadata, &g_metadata_listener, &g_metadata_events, NULL);
            }
        }
    } else if (props && strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
        const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
        const char *node_name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
        const char *node_desc = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);

        if (media_class && strcmp(media_class, "Audio/Sink") == 0) {
            g_current_sink.id = id;
            if (node_name) snprintf(g_current_sink.name, sizeof(g_current_sink.name), "%s", node_name);
            if (node_desc) snprintf(g_current_sink.desc, sizeof(g_current_sink.desc), "%s", node_desc);
            check_bind_sink(&g_current_sink);
        } else if (media_class) {
            bool is_audio_in = (strcmp(media_class, "Stream/Input/Audio") == 0);
            bool is_video_in = (strcmp(media_class, "Stream/Input/Video") == 0) ||
                               (node_name && strstr(node_name, "portal") != NULL) ||
                               (node_desc && strstr(node_desc, "portal") != NULL);
            if ((is_audio_in || is_video_in) && g_active_stream_count < MAX_ACTIVE_STREAMS) {
                bool found = false;
                for (size_t i = 0; i < g_active_stream_count; i++) {
                    if (g_active_streams[i].id == id) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    g_active_streams[g_active_stream_count].id = id;
                    g_active_streams[g_active_stream_count].is_audio_in = is_audio_in;
                    g_active_streams[g_active_stream_count].is_video_in = is_video_in;
                    g_active_stream_count++;
                }
            }
        }
    }
}

static void registry_global_remove(void *data, uint32_t id) {
    (void)data;
    for (size_t i = 0; i < g_active_stream_count; i++) {
        if (g_active_streams[i].id == id) {
            g_active_streams[i] = g_active_streams[g_active_stream_count - 1];
            g_active_stream_count--;
            break;
        }
    }
}

static const struct pw_registry_events g_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_global,
    .global_remove = registry_global_remove,
};

int verge_pw_init(void) {
    if (g_initialized) return 0;
    pw_init(NULL, NULL);

    g_loop = pw_thread_loop_new("vergebar-pipewire", NULL);
    if (!g_loop) return -1;

    pw_thread_loop_start(g_loop);

    pw_thread_loop_lock(g_loop);
    g_context = pw_context_new(pw_thread_loop_get_loop(g_loop), NULL, 0);
    if (!g_context) {
        pw_thread_loop_unlock(g_loop);
        pw_thread_loop_stop(g_loop);
        pw_thread_loop_destroy(g_loop);
        g_loop = NULL;
        return -2;
    }

    g_core = pw_context_connect(g_context, NULL, 0);
    if (!g_core) {
        pw_context_destroy(g_context);
        g_context = NULL;
        pw_thread_loop_unlock(g_loop);
        pw_thread_loop_stop(g_loop);
        pw_thread_loop_destroy(g_loop);
        g_loop = NULL;
        return -3;
    }

    g_registry = pw_core_get_registry(g_core, PW_VERSION_REGISTRY, 0);
    if (!g_registry) {
        pw_core_disconnect(g_core);
        g_core = NULL;
        pw_context_destroy(g_context);
        g_context = NULL;
        pw_thread_loop_unlock(g_loop);
        pw_thread_loop_stop(g_loop);
        pw_thread_loop_destroy(g_loop);
        g_loop = NULL;
        return -4;
    }

    pw_registry_add_listener(g_registry, &g_registry_listener, &g_registry_events, NULL);
    pw_thread_loop_unlock(g_loop);

    g_initialized = true;
    return 0;
}

void verge_pw_deinit(void) {
    if (!g_initialized || !g_loop) return;

    pw_thread_loop_lock(g_loop);
    if (g_current_sink.proxy) {
        spa_hook_remove(&g_current_sink.listener);
        pw_proxy_destroy((struct pw_proxy *)g_current_sink.proxy);
        g_current_sink.proxy = NULL;
    }
    if (g_metadata) {
        spa_hook_remove(&g_metadata_listener);
        pw_proxy_destroy((struct pw_proxy *)g_metadata);
        g_metadata = NULL;
    }
    if (g_registry) {
        spa_hook_remove(&g_registry_listener);
        pw_proxy_destroy((struct pw_proxy *)g_registry);
        g_registry = NULL;
    }
    if (g_core) {
        pw_core_disconnect(g_core);
        g_core = NULL;
    }
    if (g_context) {
        pw_context_destroy(g_context);
        g_context = NULL;
    }
    pw_thread_loop_unlock(g_loop);

    pw_thread_loop_stop(g_loop);
    pw_thread_loop_destroy(g_loop);
    g_loop = NULL;

    pw_deinit();
    g_initialized = false;
}

bool verge_pw_get_audio_info(float *out_volume, bool *out_muted, char *name_buf, size_t name_buf_len) {
    if (!g_initialized || !g_loop) return false;

    pw_thread_loop_lock(g_loop);
    if (out_volume) {
        // Cubic root mapping for perceived volume percentage (standard in PipeWire / wpctl)
        *out_volume = cbrtf(g_current_sink.volume) * 100.0f;
    }
    if (out_muted) {
        *out_muted = g_current_sink.muted;
    }
    if (name_buf && name_buf_len > 0) {
        if (g_current_sink.desc[0] != '\0') {
            snprintf(name_buf, name_buf_len, "%s", g_current_sink.desc);
        } else if (g_current_sink.name[0] != '\0') {
            snprintf(name_buf, name_buf_len, "%s", g_current_sink.name);
        } else {
            snprintf(name_buf, name_buf_len, "Default Audio Sink");
        }
    }
    pw_thread_loop_unlock(g_loop);
    return true;
}

int verge_pw_set_volume(float new_percent) {
    if (!g_initialized || !g_loop) return -1;
    if (new_percent < 0.0f) new_percent = 0.0f;
    if (new_percent > 150.0f) new_percent = 150.0f;

    pw_thread_loop_lock(g_loop);
    if (!g_current_sink.proxy) {
        pw_thread_loop_unlock(g_loop);
        return -2;
    }

    float linear_vol = powf(new_percent / 100.0f, 3.0f);
    g_current_sink.volume = linear_vol;

    uint32_t n = g_current_sink.n_channels > 0 ? g_current_sink.n_channels : 2;
    if (n > 8) n = 8;
    float volumes[8];
    for (uint32_t i = 0; i < n; i++) volumes[i] = linear_vol;

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_pod *param = (struct spa_pod *)spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
        SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, n, volumes));

    int res = pw_node_set_param(g_current_sink.proxy, SPA_PARAM_Props, 0, param);
    pw_thread_loop_unlock(g_loop);
    return res;
}

int verge_pw_set_mute(bool mute) {
    if (!g_initialized || !g_loop) return -1;

    pw_thread_loop_lock(g_loop);
    if (!g_current_sink.proxy) {
        pw_thread_loop_unlock(g_loop);
        return -2;
    }

    g_current_sink.muted = mute;

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_pod *param = (struct spa_pod *)spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
        SPA_PROP_mute, SPA_POD_Bool(mute));

    int res = pw_node_set_param(g_current_sink.proxy, SPA_PARAM_Props, 0, param);
    pw_thread_loop_unlock(g_loop);
    return res;
}

bool verge_pw_get_privacy_info(bool *out_audio_in, bool *out_screenshare) {
    if (!g_initialized || !g_loop) return false;

    pw_thread_loop_lock(g_loop);
    bool audio_in = false;
    bool video_in = false;
    for (size_t i = 0; i < g_active_stream_count; i++) {
        if (g_active_streams[i].is_audio_in) audio_in = true;
        if (g_active_streams[i].is_video_in) video_in = true;
    }
    pw_thread_loop_unlock(g_loop);

    if (out_audio_in) *out_audio_in = audio_in;
    if (out_screenshare) *out_screenshare = video_in;
    return true;
}
