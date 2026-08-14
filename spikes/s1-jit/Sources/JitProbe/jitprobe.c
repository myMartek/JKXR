#include "jitprobe.h"

#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/mman.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#include <mach/vm_statistics.h>
// Hinweis: <mach/mach_vm.h> ist im XROS-SDK als "unsupported" markiert und
// lässt sich nicht einbinden. vm_map()/vm_deallocate() sind die auf
// iOS-Familie-SDKs verfügbaren Entsprechungen mit identischer Semantik.

#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <TargetConditionals.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// MAP_JIT ist auf dem visionOS-SDK nicht garantiert deklariert.
#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

// csops() ist in den öffentlichen SDK-Headern nicht deklariert, existiert aber.
// Rein diagnostisch — muss raus, bevor irgendetwas davon in einen Release-Build
// wandert.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0

// Flag-Werte aus xnu/osfmk/kern/cs_blobs.h.
//
// Es gibt hier bewusst kein "CS_DYNAMIC_CODESIGNING": die JIT-Fähigkeit hängt
// am Entitlement `dynamic-codesigning`, nicht an einem Statusflag. Wer 0x02000000
// dafür hält, liest CS_DYLD_PLATFORM.
//
// Das im Kontext dieses Spikes interessanteste Flag ist CS_KILL: ist es gesetzt,
// beendet der Kernel den Prozess, sobald dessen Signatur ungültig wird — was
// beim Ausführen ungesignierter Seiten passiert. Das erklärt, warum manche
// Proben nicht mit einem Fehler zurückkehren, sondern den Prozess mitnehmen.
static const struct { uint32_t bit; const char *name; } kCSFlags[] = {
    { 0x00000001, "VALID" },
    { 0x00000002, "ADHOC" },
    { 0x00000004, "GET_TASK_ALLOW" },
    { 0x00000008, "INSTALLER" },
    { 0x00000010, "FORCED_LV" },
    { 0x00000020, "INVALID_ALLOWED" },
    { 0x00000100, "HARD" },
    { 0x00000200, "KILL" },
    { 0x00000400, "CHECK_EXPIRATION" },
    { 0x00000800, "RESTRICT" },
    { 0x00001000, "ENFORCEMENT" },
    { 0x00002000, "REQUIRE_LV" },
    { 0x00004000, "ENTITLEMENTS_VALIDATED" },
    { 0x00010000, "RUNTIME" },
    { 0x00020000, "LINKER_SIGNED" },
    { 0x01000000, "KILLED" },
    { 0x02000000, "DYLD_PLATFORM" },
    { 0x04000000, "PLATFORM_BINARY" },
    { 0x10000000, "DEBUGGED" },
    { 0x20000000, "SIGNED" },
    { 0x40000000, "DEV_CODE" },
};

// ---------------------------------------------------------------------------
// Der generierte Code: mov w0, #42 ; ret
// ---------------------------------------------------------------------------

static const uint32_t kStub[] = {
    0x52800540u, // movz w0, #42
    0xD65F03C0u, // ret
};

typedef int (*jit_fn)(void);

// ---------------------------------------------------------------------------
// Absturzsicherer Aufruf
//
// Ein Sprung in nicht-ausführbaren Speicher killt den Prozess. Da wir genau das
// provozieren wollen, fangen wir die Signale ab und springen zurück.
//
// Achtung beim Testen mit angehängtem Xcode: der Debugger greift EXC_BAD_ACCESS
// vor der Signalzustellung ab und hält an, statt hier zu landen. Der
// Ohne-Debugger-Lauf ist deshalb der aussagekräftige.
// ---------------------------------------------------------------------------

static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_faulted;

static void fault_handler(int sig) {
    (void)sig;
    g_faulted = 1;
    siglongjmp(g_jmp, 1);
}

static const int kTrapSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP };
static const size_t kTrapCount = sizeof(kTrapSignals) / sizeof(kTrapSignals[0]);

/// Ruft `addr` auf und überlebt es, wenn der Kernel das verweigert.
/// Gibt 1 zurück, wenn der Aufruf durchlief; 0 bei Fault.
static int call_guarded(void *addr, int *out_value) {
    struct sigaction old[4];
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;

    for (size_t i = 0; i < kTrapCount; i++) {
        sigaction(kTrapSignals[i], &sa, &old[i]);
    }

    g_faulted = 0;
    int ok = 0;

    if (sigsetjmp(g_jmp, 1) == 0) {
        jit_fn fn;
#if __has_feature(ptrauth_calls)
        // Auf arm64e muss ein roher Zeiger vor dem Aufruf signiert werden.
        fn = (jit_fn)ptrauth_sign_unauthenticated(addr, ptrauth_key_function_pointer, 0);
#else
        fn = (jit_fn)addr;
#endif
        *out_value = fn();
        ok = 1;
    }

    for (size_t i = 0; i < kTrapCount; i++) {
        sigaction(kTrapSignals[i], &old[i], NULL);
    }
    return ok;
}

// ---------------------------------------------------------------------------
// Hilfsfunktionen
// ---------------------------------------------------------------------------

static size_t page_size(void) {
    long ps = sysconf(_SC_PAGESIZE);
    return ps > 0 ? (size_t)ps : 16384;
}

static void result_init(JitProbeResult *r, const char *name) {
    memset(r, 0, sizeof(*r));
    snprintf(r->name, sizeof(r->name), "%s", name);
    r->stage = JIT_STAGE_NONE;
    r->returned = -1;
}

static void detail(JitProbeResult *r, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(r->detail, sizeof(r->detail), fmt, ap);
    va_end(ap);
}

static jitprobe_checkpoint_fn g_checkpoint = NULL;

void jitprobe_set_checkpoint(jitprobe_checkpoint_fn cb) {
    g_checkpoint = cb;
}

/// Gemeinsamer Abschluss: Cache invalidieren, aufrufen, Ergebnis bewerten.
static void finish(JitProbeResult *r, void *exec_addr, size_t len) {
    // Letzter Moment, in dem dieser Prozess garantiert noch lebt: der Sprung
    // unten kann ihn ohne abfangbares Signal beenden. Was bis hierher galt,
    // muss deshalb jetzt festgeschrieben werden.
    if (g_checkpoint) g_checkpoint(r);

    sys_icache_invalidate(exec_addr, len);

    int value = -1;
    int ran = call_guarded(exec_addr, &value);
    r->faulted = !ran;
    r->returned = value;

    if (!ran) {
        size_t used = strlen(r->detail);
        snprintf(r->detail + used, sizeof(r->detail) - used,
                 " | Sprung nach %p löste ein Signal aus", exec_addr);
        return;
    }

    r->stage = JIT_STAGE_EXECUTED;
    if (value != JITPROBE_MAGIC) {
        size_t used = strlen(r->detail);
        snprintf(r->detail + used, sizeof(r->detail) - used,
                 " | lief, lieferte aber %d statt %d", value, JITPROBE_MAGIC);
    }
}

static const char *prot_str(vm_prot_t p, char out[4]) {
    out[0] = (p & VM_PROT_READ)    ? 'r' : '-';
    out[1] = (p & VM_PROT_WRITE)   ? 'w' : '-';
    out[2] = (p & VM_PROT_EXECUTE) ? 'x' : '-';
    out[3] = '\0';
    return out;
}

/// Fragt die tatsächliche Current- und Max-Protection einer Region ab.
///
/// Entscheidend für die Dual-Mapping-Proben: Max-Protection wird bei der
/// Allokation festgelegt und lässt sich danach nur noch senken, nie anheben.
/// Enthält sie kein EXECUTE, ist jeder Versuch, die Region ausführbar zu machen,
/// von vornherein aussichtslos — und das ist eine ganz andere Aussage als eine
/// Policy-Ablehnung durch visionOS.
static int region_prot(vm_address_t addr, vm_prot_t *cur, vm_prot_t *max) {
    vm_address_t a = addr;
    vm_size_t sz = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(mach_task_self(), &a, &sz,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) return 0;
    *cur = info.protection;
    *max = info.max_protection;
    return 1;
}

/// pthread_jit_write_protect_np existiert auf visionOS möglicherweise nicht.
static void jit_write_protect(int enable) {
    static void (*fn)(int) = NULL;
    static int resolved = 0;
    if (!resolved) {
        fn = (void (*)(int))dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
        resolved = 1;
    }
    if (fn) fn(enable);
}

// ---------------------------------------------------------------------------
// Probe 1 — MAP_JIT (der von Apple vorgesehene Weg auf macOS)
// ---------------------------------------------------------------------------

static void probe_map_jit(JitProbeResult *r) {
    const size_t sz = page_size();

    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) {
        detail(r, "mmap(MAP_JIT) schlug fehl: %s (errno %d) — das ist die "
                  "erwartete Antwort ohne dynamic-codesigning-Entitlement",
               strerror(errno), errno);
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    jit_write_protect(0);
    memcpy(p, kStub, sizeof(kStub));
    jit_write_protect(1);
    r->stage = JIT_STAGE_WRITTEN;
    r->stage = JIT_STAGE_EXECUTABLE; // PROT_EXEC war schon beim mmap dabei

    detail(r, "mmap(MAP_JIT) lieferte %p", p);
    finish(r, p, sizeof(kStub));
    munmap(p, sz);
}

// ---------------------------------------------------------------------------
// Probe 2 — direkt RWX anfordern
// ---------------------------------------------------------------------------

static void probe_rwx_anon(JitProbeResult *r) {
    const size_t sz = page_size();

    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        detail(r, "mmap(RWX) schlug fehl: %s (errno %d)", strerror(errno), errno);
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    memcpy(p, kStub, sizeof(kStub));
    r->stage = JIT_STAGE_WRITTEN;
    r->stage = JIT_STAGE_EXECUTABLE;

    detail(r, "mmap(RWX) lieferte %p", p);
    finish(r, p, sizeof(kStub));
    munmap(p, sz);
}

// ---------------------------------------------------------------------------
// Probe 3 — RW schreiben, dann per mprotect auf RX umschalten
// ---------------------------------------------------------------------------

static void probe_mprotect(JitProbeResult *r) {
    const size_t sz = page_size();

    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        detail(r, "mmap(RW) schlug fehl: %s (errno %d)", strerror(errno), errno);
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    memcpy(p, kStub, sizeof(kStub));
    r->stage = JIT_STAGE_WRITTEN;

    if (mprotect(p, sz, PROT_READ | PROT_EXEC) != 0) {
        detail(r, "mprotect(RX) schlug fehl: %s (errno %d)", strerror(errno), errno);
        munmap(p, sz);
        return;
    }
    r->stage = JIT_STAGE_EXECUTABLE;

    detail(r, "mprotect(RX) auf %p akzeptiert", p);
    finish(r, p, sizeof(kStub));
    munmap(p, sz);
}

// ---------------------------------------------------------------------------
// Probe 4 — Dual-Mapping über vm_remap
//
// Der klassische Workaround aus iOS-Emulatoren: dieselbe physische Seite
// zweimal einblenden, einmal beschreibbar, einmal ausführbar. Umgeht W^X,
// ohne je eine Seite gleichzeitig W und X zu haben.
// ---------------------------------------------------------------------------

static void probe_vm_remap(JitProbeResult *r) {
    const size_t sz = page_size();
    mach_port_t task = mach_task_self();

    vm_address_t rw = 0;
    kern_return_t kr = vm_allocate(task, &rw, sz, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        detail(r, "vm_allocate schlug fehl: %s", mach_error_string(kr));
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    memcpy((void *)rw, kStub, sizeof(kStub));
    r->stage = JIT_STAGE_WRITTEN;

    char a[4], b[4], c[4], d[4];
    vm_prot_t src_cur = VM_PROT_NONE, src_max = VM_PROT_NONE;
    region_prot(rw, &src_cur, &src_max);

    vm_address_t rx = 0;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kr = vm_remap(task, &rx, sz, /*mask=*/0, VM_FLAGS_ANYWHERE,
                  task, rw, /*copy=*/FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        detail(r, "Quelle cur=%s max=%s; vm_remap schlug fehl: %s",
               prot_str(src_cur, a), prot_str(src_max, b), mach_error_string(kr));
        vm_deallocate(task, rw, sz);
        return;
    }

    // Max-Protection wird bei der Allokation festgelegt und kann danach nur
    // noch gesenkt werden. Fehlt EXECUTE bereits hier, liegt es nicht an einer
    // visionOS-Policy, sondern daran, dass die Region nie ausführbar sein durfte.
    if (!(max & VM_PROT_EXECUTE)) {
        detail(r, "Quelle cur=%s max=%s, Alias cur=%s max=%s — Alias-Max enthält "
                  "kein EXECUTE, Dual-Mapping über vm_remap scheidet damit aus",
               prot_str(src_cur, a), prot_str(src_max, b),
               prot_str(cur, c), prot_str(max, d));
        vm_deallocate(task, rx, sz);
        vm_deallocate(task, rw, sz);
        return;
    }

    kr = vm_protect(task, rx, sz, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        detail(r, "Alias steht (cur=%s max=%s), aber vm_protect(RX) schlug fehl: %s",
               prot_str(cur, c), prot_str(max, d), mach_error_string(kr));
        vm_deallocate(task, rx, sz);
        vm_deallocate(task, rw, sz);
        return;
    }
    r->stage = JIT_STAGE_EXECUTABLE;

    detail(r, "RW-Alias %p, RX-Alias %p (Alias cur=%s max=%s)",
           (void *)rw, (void *)rx, prot_str(cur, c), prot_str(max, d));
    finish(r, (void *)rx, sizeof(kStub));

    vm_deallocate(task, rx, sz);
    vm_deallocate(task, rw, sz);
}

// ---------------------------------------------------------------------------
// Probe 5 — Dual-Mapping über Shared Memory
//
// Variante von Probe 4 über POSIX-SHM. Auf iOS-Familie-OSen verlangt die
// Sandbox meist ein App-Group-Präfix im Namen; wir probieren es trotzdem,
// weil das Fehlerbild informativ ist.
// ---------------------------------------------------------------------------

static void probe_shm_dual(JitProbeResult *r) {
    const size_t sz = page_size();

    char name[32];
    snprintf(name, sizeof(name), "/jitspike.%d", (int)getpid());

    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        detail(r, "shm_open schlug fehl: %s (errno %d) — auf iOS-Familie-OSen "
                  "verlangt die Sandbox oft ein App-Group-Präfix",
               strerror(errno), errno);
        return;
    }
    shm_unlink(name);

    if (ftruncate(fd, (off_t)sz) != 0) {
        detail(r, "ftruncate schlug fehl: %s (errno %d)", strerror(errno), errno);
        close(fd);
        return;
    }

    void *rw = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (rw == MAP_FAILED) {
        detail(r, "mmap(RW, MAP_SHARED) schlug fehl: %s (errno %d)",
               strerror(errno), errno);
        close(fd);
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    memcpy(rw, kStub, sizeof(kStub));
    r->stage = JIT_STAGE_WRITTEN;

    void *rx = mmap(NULL, sz, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
    if (rx == MAP_FAILED) {
        detail(r, "RW-Alias %p steht, aber mmap(RX, MAP_SHARED) schlug fehl: "
                  "%s (errno %d)", rw, strerror(errno), errno);
        munmap(rw, sz);
        close(fd);
        return;
    }
    r->stage = JIT_STAGE_EXECUTABLE;

    detail(r, "RW-Alias %p, RX-Alias %p", rw, rx);
    finish(r, rx, sizeof(kStub));

    munmap(rx, sz);
    munmap(rw, sz);
    close(fd);
}

// ---------------------------------------------------------------------------
// Probe 6 — VM_PROT_COPY
//
// vm_protect mit VM_PROT_COPY erzwingt eine private Kopie und kann dabei
// Schutzrechte anheben, die mprotect direkt verweigert.
// ---------------------------------------------------------------------------

static void probe_vm_prot_copy(JitProbeResult *r) {
    const size_t sz = page_size();
    mach_port_t task = mach_task_self();

    vm_address_t p = 0;
    kern_return_t kr = vm_allocate(task, &p, sz, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        detail(r, "vm_allocate schlug fehl: %s", mach_error_string(kr));
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    memcpy((void *)p, kStub, sizeof(kStub));
    r->stage = JIT_STAGE_WRITTEN;

    char a[4], b[4];
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    region_prot(p, &cur, &max);

    kr = vm_protect(task, p, sz, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        detail(r, "Region cur=%s max=%s; vm_protect(RX|COPY) schlug fehl: %s%s",
               prot_str(cur, a), prot_str(max, b), mach_error_string(kr),
               (max & VM_PROT_EXECUTE)
                   ? " — Max erlaubt EXECUTE, das ist also eine Policy-Ablehnung"
                   : " — Max enthält kein EXECUTE, der Weg ist strukturell zu");
        vm_deallocate(task, p, sz);
        return;
    }
    r->stage = JIT_STAGE_EXECUTABLE;

    detail(r, "vm_protect(RX|COPY) auf %p akzeptiert (vorher cur=%s max=%s)",
           (void *)p, prot_str(cur, a), prot_str(max, b));
    finish(r, (void *)p, sizeof(kStub));
    vm_deallocate(task, p, sz);
}

// ---------------------------------------------------------------------------
// Probe 7 — mach_vm_map mit explizit angeforderter Max-Protection
//
// Die stärkste verbleibende Karte. Max-Protection lässt sich nachträglich nicht
// anheben — also fordert man sie direkt bei der Allokation an: current = RW,
// maximum = RWX. Genau so gehen JIT-Bibliotheken auf iOS vor. Danach reicht ein
// gewöhnliches vm_protect auf RX, ohne je eine Seite W und X zugleich zu haben.
// ---------------------------------------------------------------------------

static void probe_vm_map_maxprot(JitProbeResult *r) {
    const size_t sz = page_size();
    mach_port_t task = mach_task_self();

    char a[4], b[4];
    vm_address_t p = 0;
    kern_return_t kr = vm_map(task, &p, sz, /*mask=*/0, VM_FLAGS_ANYWHERE,
                              MEMORY_OBJECT_NULL, /*offset=*/0, /*copy=*/FALSE,
                              /*cur=*/VM_PROT_READ | VM_PROT_WRITE,
                              /*max=*/VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,
                              VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        detail(r, "vm_map(max=rwx) schlug fehl: %s — visionOS verweigert schon "
                  "die Allokation mit ausführbarer Max-Protection",
               mach_error_string(kr));
        return;
    }
    r->stage = JIT_STAGE_ALLOCATED;

    memcpy((void *)p, kStub, sizeof(kStub));
    r->stage = JIT_STAGE_WRITTEN;

    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    region_prot(p, &cur, &max);

    kr = vm_protect(task, p, sz, /*set_maximum=*/FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        detail(r, "Allokation gelang (cur=%s max=%s), aber vm_protect(RX) "
                  "schlug fehl: %s", prot_str(cur, a), prot_str(max, b),
               mach_error_string(kr));
        vm_deallocate(task, p, sz);
        return;
    }
    r->stage = JIT_STAGE_EXECUTABLE;

    detail(r, "vm_map lieferte %p mit cur=%s max=%s, vm_protect(RX) akzeptiert",
           (void *)p, prot_str(cur, a), prot_str(max, b));
    finish(r, (void *)p, sizeof(kStub));
    vm_deallocate(task, p, sz);
}

// ---------------------------------------------------------------------------
// Öffentliche API
// ---------------------------------------------------------------------------

typedef void (*probe_fn)(JitProbeResult *);

static const probe_fn kProbes[] = {
    probe_map_jit,
    probe_rwx_anon,
    probe_mprotect,
    probe_vm_remap,
    probe_shm_dual,
    probe_vm_prot_copy,
    probe_vm_map_maxprot,
};

/// Namen liegen bewusst hier statt in den Proben selbst: der Aufrufer muss eine
/// Probe auch dann benennen können, wenn sie den Prozess beendet, bevor sie ein
/// Ergebnis zurückgeben konnte.
static const char *const kProbeNames[] = {
    "1. mmap MAP_JIT + pthread_jit_write_protect_np",
    "2. mmap PROT_READ|WRITE|EXEC (ohne MAP_JIT)",
    "3. mmap RW -> mprotect RX",
    "4. vm_remap Dual-Mapping (RW-Alias + RX-Alias)",
    "5. shm_open Dual-Mapping",
    "6. vm_protect mit VM_PROT_COPY",
    "7. vm_map mit max=RWX, dann vm_protect RX",
};

size_t jitprobe_count(void) {
    return sizeof(kProbes) / sizeof(kProbes[0]);
}

void jitprobe_name(size_t index, char *out, size_t cap) {
    if (index >= jitprobe_count()) {
        snprintf(out, cap, "<ungültiger Index %zu>", index);
        return;
    }
    snprintf(out, cap, "%s", kProbeNames[index]);
}

void jitprobe_run_one(size_t index, JitProbeResult *out) {
    if (index >= jitprobe_count()) {
        result_init(out, "<ungültiger Index>");
        return;
    }
    result_init(out, kProbeNames[index]);
    kProbes[index](out);
}

size_t jitprobe_run_all(JitProbeResult *out, size_t cap) {
    size_t count = jitprobe_count();
    size_t n = count < cap ? count : cap;
    for (size_t i = 0; i < n; i++) {
        jitprobe_run_one(i, &out[i]);
    }
    return n;
}

static int debugger_attached(void) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return -1;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

void jitprobe_environment(char *buf, size_t cap) {
    uint32_t cs = 0;
    int cs_ok = csops(getpid(), CS_OPS_STATUS, &cs, sizeof(cs)) == 0;
    int traced = debugger_attached();

#if TARGET_OS_SIMULATOR
    const char *host = "SIMULATOR — Ergebnisse sind NICHT aussagekräftig, "
                       "der Simulator erbt die macOS-Rechte des Hosts";
#elif TARGET_OS_OSX
    const char *host = "macOS — Kontrollgruppe. Hier funktioniert JIT "
                       "nachweislich; die Proben zeigen also, wie ein Erfolg "
                       "aussieht";
#elif defined(TARGET_OS_VISION) && TARGET_OS_VISION
    const char *host = "visionOS auf echter Hardware — der Lauf, der zählt";
#else
    const char *host = "echtes Gerät";
#endif

    char cs_desc[512];
    if (cs_ok) {
        int n = snprintf(cs_desc, sizeof(cs_desc), "0x%08x [", cs);
        for (size_t i = 0; i < sizeof(kCSFlags) / sizeof(kCSFlags[0]); i++) {
            if (!(cs & kCSFlags[i].bit)) continue;
            n += snprintf(cs_desc + n, sizeof(cs_desc) - (size_t)n, "%s%s",
                          cs_desc[n - 1] == '[' ? "" : " ", kCSFlags[i].name);
        }
        snprintf(cs_desc + n, sizeof(cs_desc) - (size_t)n, "]");
    } else {
        snprintf(cs_desc, sizeof(cs_desc), "csops() nicht verfügbar (errno %d)", errno);
    }

    snprintf(buf, cap,
             "Host:          %s\n"
             "Seitengröße:   %zu Bytes\n"
             "Debugger:      %s\n"
             "CodeSign:      %s\n"
             "Architektur:   %s\n",
             host,
             page_size(),
             traced < 0 ? "unbekannt" : (traced ? "ANGEHÄNGT" : "nicht angehängt"),
             cs_desc,
#if __has_feature(ptrauth_calls)
             "arm64e (Pointer Authentication aktiv)"
#else
             "arm64"
#endif
    );
}
