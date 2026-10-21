/*
 * Perpendicular experimental RDP display probe.
 * SPDX-License-Identifier: Apache-2.0
 *
 * GDI lifecycle and event-loop structure adapted from FreeRDP 3.32.2
 * client/Sample/tf_freerdp.c (Apache-2.0):
 * Copyright 2011 Marc-Andre Moreau <marcandre.moreau@gmail.com>
 * Copyright 2016,2018 Armin Novak <armin.novak@thincast.com>
 * Copyright 2016,2018 Thincast Technologies GmbH
 * http://www.apache.org/licenses/LICENSE-2.0
 * Distributed WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
 *
 * Invocation: display-probe PORT WIDTH HEIGHT SCALE
 * stdin must be a pipe containing three newline-terminated UTF-8 records:
 * username, password, then exactly 64 hexadecimal SHA256 certificate digits.
 * Feed that pipe from an in-memory credential source, never shell arguments,
 * environment variables, command literals, files or a terminal prompt.
 * --self-check configures the context only; it opens no socket.
 */
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <openssl/crypto.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/wlog.h>

typedef struct {
    rdpContext context;
    UINT32 port, width, height, scale;
    BYTE pin[32];
    BOOL pin_ready, pinned, gdi_ready, subscribed;
    pthread_mutex_t lock;
    DispClientContext* disp;
    UINT32 max_monitors, area_a, area_b;
    BOOL caps_ready, layout_attempted, layout_sent;
    HANDLE stop;
    atomic_bool timed_out;
} Probe;

static Probe* state(freerdp* instance) { return (Probe*)instance->context; }

static BOOL deny_redirect(freerdp* instance) {
    (void)instance;
    puts("state=server-redirection-rejected");
    return FALSE;
}

static BOOL deny_auth_retry(freerdp* instance, char** username, char** password,
                            char** domain, rdp_auth_reason reason) {
    (void)instance; (void)username; (void)password; (void)domain; (void)reason;
    puts("state=credential-retry-rejected");
    return FALSE;
}

static int verify_certificate(freerdp* instance, const BYTE* pem, size_t length,
                              const char* host, UINT16 port, DWORD flags) {
    Probe* p = state(instance);
    BYTE digest[EVP_MAX_MD_SIZE] = {0};
    unsigned int size = 0;
    int accepted = 0;
    if (!p->pin_ready || !host || strcmp(host, "127.0.0.1") || port != p->port ||
        flags != VERIFY_CERT_FLAG_NONE || !pem || length > INT_MAX)
        goto done;
    BIO* bio = BIO_new_mem_buf(pem, (int)length);
    X509* cert = bio ? PEM_read_bio_X509(bio, NULL, NULL, NULL) : NULL;
    if (cert && X509_digest(cert, EVP_sha256(), digest, &size) == 1 && size == 32 &&
        CRYPTO_memcmp(digest, p->pin, 32) == 0)
        accepted = 1;
    X509_free(cert);
    BIO_free(bio);
done:
    OPENSSL_cleanse(digest, sizeof(digest));
    p->pinned = accepted != 0;
    puts(accepted ? "state=certificate-pin-verified" : "state=certificate-pin-rejected");
    return accepted ? 2 : 0; /* session-only; external management writes no trust record */
}

static UINT display_caps(DispClientContext* disp, UINT32 count, UINT32 a, UINT32 b) {
    Probe* p = (Probe*)disp->custom;
    if (!p) return ERROR_INVALID_DATA;
    pthread_mutex_lock(&p->lock);
    if (!p->caps_ready) {
        p->max_monitors = count; p->area_a = a; p->area_b = b;
        p->caps_ready = TRUE;
        printf("state=display-caps monitors=%" PRIu32 " area-factors=%" PRIu32 "x%" PRIu32 "\n", count, a, b);
    }
    pthread_mutex_unlock(&p->lock);
    return CHANNEL_RC_OK;
}

static void channel_connected(void* context, const ChannelConnectedEventArgs* e) {
    Probe* p = (Probe*)context;
    if (!e->name || strcmp(e->name, DISP_DVC_CHANNEL_NAME)) return;
    pthread_mutex_lock(&p->lock);
    p->disp = (DispClientContext*)e->pInterface;
    if (p->disp) { p->disp->custom = p; p->disp->DisplayControlCaps = display_caps; }
    pthread_mutex_unlock(&p->lock);
    puts("state=display-channel-connected");
}

static void channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e) {
    Probe* p = (Probe*)context;
    if (!e->name || strcmp(e->name, DISP_DVC_CHANNEL_NAME)) return;
    pthread_mutex_lock(&p->lock);
    if (p->disp) { p->disp->custom = NULL; p->disp->DisplayControlCaps = NULL; }
    p->disp = NULL;
    pthread_mutex_unlock(&p->lock);
    puts("state=display-channel-disconnected");
}

static BOOL pre_connect(freerdp* instance) {
    Probe* p = state(instance);
    const char* host = freerdp_settings_get_string(p->context.settings, FreeRDP_ServerHostname);
    if (!p->pin_ready || !host || strcmp(host, "127.0.0.1")) return FALSE;
    if (PubSub_SubscribeChannelConnected(p->context.pubSub, channel_connected) < 0) return FALSE;
    if (PubSub_SubscribeChannelDisconnected(p->context.pubSub, channel_disconnected) < 0) {
        PubSub_UnsubscribeChannelConnected(p->context.pubSub, channel_connected);
        return FALSE;
    }
    p->subscribed = TRUE;
    return TRUE;
}

static BOOL resize_observed(rdpContext* context) {
    UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    printf("state=server-resize width=%" PRIu32 " height=%" PRIu32 "\n", width, height);
    return context->gdi && gdi_resize(context->gdi, width, height);
}

static BOOL post_connect(freerdp* instance) {
    Probe* p = state(instance);
    UINT32 protocol = freerdp_settings_get_uint32(p->context.settings, FreeRDP_SelectedProtocol);
    /* MS-RDPBCGR selectedProtocol: HYBRID=2, HYBRID_EX=8, both require NLA. */
    if (!p->pinned || (protocol != 2 && protocol != 8)) return FALSE;
    if (!gdi_init(instance, PIXEL_FORMAT_XRGB32)) return FALSE;
    p->gdi_ready = TRUE;
    p->context.update->DesktopResize = resize_observed;
    puts("state=connected-nla-verified");
    return TRUE;
}

static void post_disconnect(freerdp* instance) {
    Probe* p = state(instance);
    if (p->subscribed) {
        PubSub_UnsubscribeChannelConnected(p->context.pubSub, channel_connected);
        PubSub_UnsubscribeChannelDisconnected(p->context.pubSub, channel_disconnected);
        p->subscribed = FALSE;
    }
    if (p->gdi_ready) { gdi_free(instance); p->gdi_ready = FALSE; }
}

static BOOL load_channels(freerdp* instance) {
    return freerdp_client_load_addins(instance->context->channels, instance->context->settings);
}

static BOOL configure(freerdp* instance) {
    Probe* p = state(instance);
    rdpSettings* s = p->context.settings;
    const FreeRDP_Settings_Keys_Bool disabled[] = {
        FreeRDP_TlsSecurity, FreeRDP_RdpSecurity, FreeRDP_ExtSecurity, FreeRDP_RdstlsSecurity,
        FreeRDP_AadSecurity, FreeRDP_IgnoreCertificate, FreeRDP_AutoAcceptCertificate,
        FreeRDP_AutoReconnectionEnabled, FreeRDP_GatewayEnabled,
        FreeRDP_DeviceRedirection, FreeRDP_RedirectDrives, FreeRDP_RedirectHomeDrive,
        FreeRDP_RedirectSmartCards, FreeRDP_RedirectWebAuthN, FreeRDP_RedirectPrinters,
        FreeRDP_RedirectSerialPorts, FreeRDP_RedirectParallelPorts, FreeRDP_RedirectClipboard,
        FreeRDP_AudioPlayback, FreeRDP_AudioCapture, FreeRDP_SupportGraphicsPipeline,
        FreeRDP_GfxH264, FreeRDP_RemoteApplicationMode, FreeRDP_SuppressOutput,
        FreeRDP_DumpRemoteFx, FreeRDP_TransportDump, FreeRDP_TransportDumpReplay
    };
    const FreeRDP_Settings_Keys_Bool enabled[] = {
        FreeRDP_NlaSecurity, FreeRDP_Authentication, FreeRDP_NegotiateSecurityLayer,
        FreeRDP_ExternalCertificateManagement, FreeRDP_DeactivateClientDecoding,
        FreeRDP_SupportDisplayControl, FreeRDP_DynamicResolutionUpdate
    };
    for (size_t i=0; i<sizeof(disabled)/sizeof(disabled[0]); i++)
        if (!freerdp_settings_set_bool(s, disabled[i], FALSE)) return FALSE;
    for (size_t i=0; i<sizeof(enabled)/sizeof(enabled[0]); i++)
        if (!freerdp_settings_set_bool(s, enabled[i], TRUE)) return FALSE;
    if (!freerdp_settings_set_string(s, FreeRDP_ServerHostname, "127.0.0.1") ||
        !freerdp_settings_set_string(s, FreeRDP_Domain, "") ||
        !freerdp_settings_set_uint32(s, FreeRDP_ServerPort, p->port) ||
        !freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, 1024) ||
        !freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, 768) ||
        !freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, 100) ||
        !freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, 100) ||
        !freerdp_settings_set_uint32(s, FreeRDP_ProxyType, PROXY_TYPE_IGNORE) ||
        !freerdp_settings_set_uint32(s, FreeRDP_TcpConnectTimeout, 3000) ||
        !freerdp_settings_set_uint32(s, FreeRDP_AuthenticationLevel, 2)) return FALSE;
    instance->PreConnect = pre_connect; instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect; instance->LoadChannels = load_channels;
    instance->Redirect = deny_redirect; instance->AuthenticateEx = deny_auth_retry;
    instance->VerifyX509Certificate = verify_certificate;
    return TRUE;
}

static BOOL send_layout(Probe* p) {
    BOOL ok = TRUE;
    pthread_mutex_lock(&p->lock);
    if (!p->layout_attempted && p->caps_ready && p->disp) {
        p->layout_attempted = TRUE;
        uint64_t area = (uint64_t)p->area_a * p->area_b;
        uint64_t limit = p->max_monitors && area <= UINT64_MAX/p->max_monitors ?
                         area*p->max_monitors : UINT64_MAX;
        if (!p->max_monitors || !area || (uint64_t)p->width*p->height > limit) {
            puts("state=request-exceeds-server-caps"); ok = FALSE;
        } else {
            DISPLAY_CONTROL_MONITOR_LAYOUT layout = {0};
            layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
            layout.Width = p->width; layout.Height = p->height;
            layout.DesktopScaleFactor = p->scale; layout.DeviceScaleFactor = 100;
            UINT rc = p->disp->SendMonitorLayout(p->disp, 1, &layout);
            p->layout_sent = rc == CHANNEL_RC_OK;
            ok = p->layout_sent;
            printf("state=%s width=%" PRIu32 " height=%" PRIu32 " scale=%" PRIu32 "\n",
                   ok ? "layout-sent" : "layout-send-failed", p->width, p->height, p->scale);
        }
    }
    pthread_mutex_unlock(&p->lock);
    return ok;
}

static void* deadline_worker(void* arg) {
    Probe* p = arg;
    if (WaitForSingleObject(p->stop, 60000) == WAIT_TIMEOUT) {
        atomic_store(&p->timed_out, true);
        (void)freerdp_abort_connect_context(&p->context);
    }
    return NULL;
}

static BOOL pipe_line(char* out, size_t size, UINT64 deadline) {
    size_t used = 0;
    while (used+1 < size) {
        UINT64 now = GetTickCount64();
        if (now >= deadline) return FALSE;
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        int rc = poll(&input, 1, (int)(deadline-now));
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) return FALSE;
        unsigned char ch = 0;
        ssize_t n = read(STDIN_FILENO, &ch, 1);
        if (n < 0 && errno == EINTR) continue;
        if (n != 1 || !ch || ch == '\r') return FALSE;
        if (ch == '\n') { out[used] = 0; return used != 0; }
        out[used++] = (char)ch;
    }
    return FALSE;
}

static BOOL read_secrets(Probe* p) {
    char user[512] = {0}, password[4096] = {0}, hex[66] = {0};
    char* parsed_user = NULL;
    char* parsed_domain = NULL;
    struct stat st;
    BOOL ok = FALSE;
    if (isatty(STDIN_FILENO) || fstat(STDIN_FILENO, &st) || !S_ISFIFO(st.st_mode)) {
        puts("state=stdin-pipe-required"); goto done;
    }
    UINT64 deadline = GetTickCount64()+5000;
    if (!pipe_line(user, sizeof(user), deadline) || !pipe_line(password, sizeof(password), deadline) ||
        !pipe_line(hex, sizeof(hex), deadline) || strlen(hex) != 64) goto done;
    for (size_t i=0; i<32; i++) {
        int digits[2];
        for (int j=0; j<2; j++) {
            unsigned char c = (unsigned char)hex[2*i+j];
            digits[j] = c >= '0' && c <= '9' ? c-'0' : c >= 'a' && c <= 'f' ? c-'a'+10 :
                        c >= 'A' && c <= 'F' ? c-'A'+10 : -1;
            if (digits[j] < 0) goto done;
        }
        p->pin[i] = (BYTE)(digits[0]*16+digits[1]);
    }
    if (!freerdp_parse_username(user, &parsed_user, &parsed_domain)) goto done;
    ok = freerdp_settings_set_string(p->context.settings, FreeRDP_Username, parsed_user) &&
         freerdp_settings_set_string(p->context.settings, FreeRDP_Domain, parsed_domain ? parsed_domain : "") &&
         freerdp_settings_set_string(p->context.settings, FreeRDP_Password, password);
    p->pin_ready = ok;
done:
    if (parsed_user) { OPENSSL_cleanse(parsed_user, strlen(parsed_user)); free(parsed_user); }
    if (parsed_domain) { OPENSSL_cleanse(parsed_domain, strlen(parsed_domain)); free(parsed_domain); }
    OPENSSL_cleanse(user, sizeof(user)); OPENSSL_cleanse(password, sizeof(password));
    OPENSSL_cleanse(hex, sizeof(hex));
    if (!ok) puts("state=credential-input-rejected");
    return ok;
}

static BOOL number(const char* s, UINT32 min, UINT32 max, UINT32* out) {
    if (!s || !*s) return FALSE;
    for (const char* c=s; *c; c++) if (*c < '0' || *c > '9') return FALSE;
    errno = 0;
    unsigned long value = strtoul(s, NULL, 10);
    if (errno || value < min || value > max) return FALSE;
    *out = (UINT32)value;
    return TRUE;
}

int main(int argc, char** argv) {
    const BOOL self_check = argc == 2 && !strcmp(argv[1], "--self-check");
    UINT32 port=13389, width=1920, height=1080, scale=200;
    if (!self_check && (argc != 5 || !number(argv[1], 1, 65535, &port) ||
        !number(argv[2], 200, 8192, &width) || width%2 ||
        !number(argv[3], 200, 8192, &height) || !number(argv[4], 100, 500, &scale))) {
        fputs("Usage: display-probe --self-check | PORT WIDTH HEIGHT SCALE\n", stderr); return 2;
    }
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core)) return 2;
    if (setenv("WLOG_LEVEL", "OFF", 1) || setenv("WLOG_FILTER", "*:OFF", 1) ||
        setenv("WLOG_APPENDER", "CONSOLE", 1)) return 2;
    if (!WLog_SetLogLevel(WLog_GetRoot(), WLOG_OFF) || !WLog_AddStringLogFilters("*:OFF")) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    freerdp* instance = freerdp_new();
    if (!instance) return 1;
    instance->ContextSize = sizeof(Probe);
    if (!freerdp_context_new(instance)) { freerdp_free(instance); return 1; }
    Probe* p = state(instance);
    p->port=port; p->width=width; p->height=height; p->scale=scale;
    atomic_init(&p->timed_out, false);
    if (pthread_mutex_init(&p->lock, NULL)) { freerdp_context_free(instance); freerdp_free(instance); return 1; }
    int result = 1;
    BOOL attempted = FALSE, worker_started = FALSE;
    pthread_t worker;
    if (!configure(instance)) goto done;
    if (self_check) {
        puts("state=self-check-ok context=configured transport=none"); result=0; goto done;
    }
    if (!read_secrets(p)) goto done;
    if (freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) != 0) goto done;
    p->stop = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!p->stop || pthread_create(&worker, NULL, deadline_worker, p)) goto done;
    worker_started = TRUE;
    puts("state=connecting-loopback-nla");
    attempted = TRUE;
    if (!freerdp_connect(instance)) { puts("state=connection-failed"); goto done; }
    while (!atomic_load(&p->timed_out) && !freerdp_shall_disconnect_context(&p->context)) {
        if (!send_layout(p)) goto done;
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD count = freerdp_get_event_handles(&p->context, handles, MAXIMUM_WAIT_OBJECTS);
        if (!count || WaitForMultipleObjects(count, handles, FALSE, 100) == WAIT_FAILED ||
            !freerdp_check_event_handles(&p->context)) break;
    }
    result = p->layout_sent ? 0 : 1;
    puts(p->layout_sent ? "state=probe-complete-layout-sent" : "state=probe-incomplete-no-layout");
done:
    if (worker_started) { SetEvent(p->stop); pthread_join(worker, NULL); }
    if (attempted) { (void)freerdp_disconnect(instance); post_disconnect(instance); puts("state=disconnected"); }
    if (p->stop) CloseHandle(p->stop);
    const char* secret = freerdp_settings_get_string(p->context.settings, FreeRDP_Password);
    if (secret) OPENSSL_cleanse((void*)secret, strlen(secret));
    secret = freerdp_settings_get_string(p->context.settings, FreeRDP_Username);
    if (secret) OPENSSL_cleanse((void*)secret, strlen(secret));
    OPENSSL_cleanse(p->pin, sizeof(p->pin));
    pthread_mutex_destroy(&p->lock);
    freerdp_context_free(instance); freerdp_free(instance);
    return result;
}
