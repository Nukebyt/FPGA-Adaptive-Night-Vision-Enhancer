/* nv_streamer.c -- video streaming daemon for the night-vision engine, run on the DE10-Standard's HPS (roadmap 3b.7).
 *
 * Structure and lessons carried over from the CFAR project's cfar_server.c: the HPS image has no usable Python, so this C
 * daemon owns /dev/mem and the laptop talks to it over TCP (docs/streaming.md). Single connection at a time (there is one
 * FPGA). SIGPIPE ignored, TCP_NODELAY, magic/version header, error codes. Build with -std=gnu99 (the board's gcc defaults to
 * gnu89). Needs root for /dev/mem.
 *
 *   laptop --FRAME_IN--> daemon --memcpy--> DDR3 input ring --FPGA dma_rd--> engine --dma_wr--> DDR3 output ring
 *   laptop <-FRAME_OUT-- daemon <-memcpy--- (telemetry from the CSR block)
 *
 * Memory: the engine's rings live in a region of DDR3 that Linux must NOT use. Boot the kernel with a reduced memory size
 * (e.g. mem=768M in the u-boot bootargs), then pass the first reserved physical address with --ddr-base (default 0x30000000).
 * Input ring at ddr-base, output ring at ddr-base + 0x200000, 4 slots of 512 KiB each. The mapping is /dev/mem with O_SYNC
 * (uncached): the FPGA writes DDR3 behind the CPU caches, so a cacheable mapping would return stale lines.
 *
 * Build:   gcc -std=gnu99 -O2 -Wall -Wextra -o nv_streamer nv_streamer.c
 * ARM:     arm-linux-gnueabihf-gcc -std=gnu99 -O2 -Wall -Wextra -o nv_streamer nv_streamer.c
 * Test without hardware (passthrough emulator instead of /dev/mem):  gcc -std=gnu99 -O2 -DNV_SIM -o nv_streamer_sim nv_streamer.c
 * Run:     sudo ./nv_streamer [--port 5002] [--ddr-base 0x30000000]
 */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

/* ---------------------------------------------------------------- hardware map (keep in sync with rtl/nv_csr.v and the Qsys address) */
#define HPS_LW_BRIDGE_BASE 0xFF200000UL
#define HPS_LW_BRIDGE_SPAN 0x00200000UL
#ifndef NV_CSR_OFFSET
#define NV_CSR_OFFSET      0x00010000UL          /* nv_engine_0.csr base inside the lightweight bridge (quartus/soc/make_system.tcl) */
#endif
#define NV_EXPECTED_BUILD  0x4E560001u
#define SLOT_STRIDE        0x80000UL
#define N_SLOTS            4
#define OUT_RING_OFFSET    0x200000UL
#define DDR_REGION_SPAN    0x400000UL

#define R_VERSION   0
#define R_CONTROL   1
#define R_STATUS    2
#define R_STATUS_CLR 3
#define R_IN_BASE   4
#define R_OUT_BASE  5
#define R_IN_WR_SEQ 6
#define R_IN_RD_SEQ 7
#define R_OUT_SEQ   8
#define R_SCRATCH   11
#define R_TEL_LG    16
#define R_TEL_SIGMA 17
#define R_TEL_B     18
#define R_TEL_A     19
#define R_TEL_LAM   20
#define R_TEL_SHARP 21
#define R_TEL_CORE  22
#define R_TEL_P1    25
#define R_TEL_P50   26
#define R_TEL_P99   27
#define R_TEL_MEAN  28
#define R_HIST      64

#define CTL_ENABLE  (1u << 0)
#define CTL_RESET   (1u << 1)
#define CTL_STAGES  ((1u << 2) | (1u << 3) | (1u << 4))
#define ST_READY    (1u << 0)

/* ---------------------------------------------------------------- protocol (docs/streaming.md) */
#define NV_MAGIC   0x4449564Eu            /* 'N','V','I','D' little-endian */
#define NV_VERSION 1u
#define T_HELLO 1
#define T_HELLO_ACK 2
#define T_FRAME_IN 3
#define T_FRAME_OUT 4
#define T_CSR_WRITE 5
#define T_CSR_READ 6
#define T_CSR_REPLY 7
#define T_ERROR 8
#define E_BAD_MAGIC 1u
#define E_BAD_VERSION 2u
#define E_BAD_SIZE 3u
#define E_SHORT_READ 4u
#define E_NOMEM 5u
#define E_BUSY 6u
#define E_FPGA_TIMEOUT 7u
#define FRAME_W 640
#define FRAME_H 480
#define NPIX (FRAME_W * FRAME_H)
#define TELEMETRY_BYTES 176
#define MAX_IN_FLIGHT 3

static volatile uint32_t *csr;            /* NV CSR block, 32-bit words */
static volatile uint8_t  *ddr;            /* mapped reserved DDR3 region */
static uint32_t ddr_phys = 0x30000000u;

#ifdef NV_SIM
/* ---------------------------------------------------------------- passthrough "FPGA" so the daemon can be tested on a PC */
static uint32_t sim_regs[256];
static void sim_on_write(unsigned w, uint32_t v)
{
    if (w == R_IN_WR_SEQ) {
        while (sim_regs[R_IN_RD_SEQ] < v) {                         /* process every queued frame immediately */
            unsigned s = sim_regs[R_IN_RD_SEQ] % N_SLOTS, o = sim_regs[R_OUT_SEQ] % N_SLOTS;
            memcpy((void *)(ddr + OUT_RING_OFFSET + o * SLOT_STRIDE), (const void *)(ddr + s * SLOT_STRIDE), NPIX);
            sim_regs[R_IN_RD_SEQ]++;
            sim_regs[R_OUT_SEQ]++;
            sim_regs[R_TEL_LG] = 8192; sim_regs[R_TEL_SIGMA] = 300; sim_regs[R_TEL_A] = 64; sim_regs[R_TEL_MEAN] = 2048;
            for (int k = 0; k < 64; k++) sim_regs[R_HIST + k] = (uint32_t)k;
        }
    } else if (w == R_CONTROL && (v & CTL_RESET)) {
        sim_regs[R_IN_RD_SEQ] = sim_regs[R_OUT_SEQ] = sim_regs[R_IN_WR_SEQ] = 0;
        sim_regs[R_STATUS] = ST_READY;
    }
}
static inline uint32_t csr_rd(unsigned w) { (void)csr; return sim_regs[w]; }
static inline void csr_wr(unsigned w, uint32_t v)
{
    if (w != R_IN_RD_SEQ && w != R_OUT_SEQ && w != R_VERSION && w != R_STATUS) sim_regs[w] = v;
    sim_on_write(w, v);
}
#else
static inline uint32_t csr_rd(unsigned w) { return csr[w]; }
static inline void csr_wr(unsigned w, uint32_t v) { csr[w] = v; }
#endif

/* ---------------------------------------------------------------- io helpers (as in cfar_server.c) */
static int read_exact(int fd, void *buf, size_t n)
{
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r == 0) return -1;
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)r;
    }
    return 0;
}
static int write_exact(int fd, const void *buf, size_t n)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, p + sent, n - sent);
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; return -1; }
        sent += (size_t)w;
    }
    return 0;
}
static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, v); put16(p + 2, v >> 16); }
static uint32_t get32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint32_t get16(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }

static int send_msg(int fd, uint16_t type, uint32_t seq, const void *payload, uint32_t len)
{
    uint8_t h[16];
    put32(h, NV_MAGIC); put16(h + 4, NV_VERSION); put16(h + 6, type); put32(h + 8, seq); put32(h + 12, len);
    if (write_exact(fd, h, 16) != 0) return -1;
    return len ? write_exact(fd, payload, len) : 0;
}
static void send_error(int fd, uint32_t code)
{
    uint8_t p[4];
    put32(p, code);
    (void)send_msg(fd, T_ERROR, 0, p, 4);
}

/* ---------------------------------------------------------------- DDR3 ring access (64-bit loads/stores, uncached mapping) */
static void ddr_write(unsigned slot, const uint8_t *src)
{
    volatile uint64_t *d = (volatile uint64_t *)(ddr + (size_t)slot * SLOT_STRIDE);
    const uint64_t *s = (const uint64_t *)src;
    for (size_t i = 0; i < NPIX / 8; i++) d[i] = s[i];
}
static void ddr_read(unsigned slot, uint8_t *dst)
{
    const volatile uint64_t *s = (const volatile uint64_t *)(ddr + OUT_RING_OFFSET + (size_t)slot * SLOT_STRIDE);
    uint64_t *d = (uint64_t *)dst;
    for (size_t i = 0; i < NPIX / 8; i++) d[i] = s[i];
}

/* ---------------------------------------------------------------- engine control */
static int engine_start(void)
{
    csr_wr(R_CONTROL, CTL_RESET | CTL_STAGES);          /* frame_reset pulse, engine disabled */
    long t0 = now_ms();
    while (!(csr_rd(R_STATUS) & ST_READY)) {
        if (now_ms() - t0 > 2000) return -1;
        usleep(1000);
    }
    csr_wr(R_STATUS_CLR, 1);
    csr_wr(R_IN_BASE, ddr_phys);
    csr_wr(R_OUT_BASE, ddr_phys + (uint32_t)OUT_RING_OFFSET);
    csr_wr(R_CONTROL, CTL_ENABLE | CTL_STAGES);
    return 0;
}
static void engine_stop(void) { csr_wr(R_CONTROL, CTL_STAGES); }

static void build_telemetry(uint8_t *t, uint32_t out_count)
{
    memset(t, 0, TELEMETRY_BYTES);
    uint32_t st = csr_rd(R_STATUS);
    put32(t + 0, out_count);
    put32(t + 4, csr_rd(R_TEL_LG));
    put32(t + 8, csr_rd(R_TEL_SIGMA));
    put32(t + 12, csr_rd(R_TEL_MEAN));
    put16(t + 16, csr_rd(R_TEL_A));
    t[18] = (uint8_t)csr_rd(R_TEL_LAM);
    t[19] = (uint8_t)csr_rd(R_TEL_SHARP);
    put16(t + 20, csr_rd(R_TEL_CORE));
    t[22] = (uint8_t)csr_rd(R_TEL_B);
    t[23] = (uint8_t)(((st >> 10) & 1u) | (((st >> 8) & 1u) << 1) | (((csr_rd(R_CONTROL) >> 5) & 1u) << 2));
    t[24] = (uint8_t)csr_rd(R_TEL_P1);
    t[25] = (uint8_t)csr_rd(R_TEL_P50);
    t[26] = (uint8_t)csr_rd(R_TEL_P99);
    for (int k = 0; k < 64; k++) put16(t + 48 + 2 * k, csr_rd(R_HIST + (unsigned)k));
}

/* ---------------------------------------------------------------- one connection */
static void handle_conn(int fd)
{
    uint8_t h[16];
    if (read_exact(fd, h, 16) != 0) return;
    if (get32(h) != NV_MAGIC) { send_error(fd, E_BAD_MAGIC); return; }
    if (get16(h + 4) != NV_VERSION) { send_error(fd, E_BAD_VERSION); return; }
    uint32_t type = get16(h + 6), len = get32(h + 12);
    if (type != T_HELLO || len != 8) { send_error(fd, E_BAD_SIZE); return; }
    uint8_t hp[8];
    if (read_exact(fd, hp, 8) != 0) return;
    uint32_t w = get16(hp), hh = get16(hp + 2);
    if (w != FRAME_W || hh != FRAME_H) { send_error(fd, E_BAD_SIZE); return; }

    uint32_t build = csr_rd(R_VERSION);
    printf("  engine VERSION 0x%08X (expected 0x%08X)\n", build, NV_EXPECTED_BUILD);
    if (build != NV_EXPECTED_BUILD) fprintf(stderr, "  WARNING: bitstream build id does not match this daemon\n");
    if (engine_start() != 0) { send_error(fd, E_FPGA_TIMEOUT); return; }

    uint8_t ack[12];
    put32(ack, 0); put32(ack + 4, build); put16(ack + 8, FRAME_W); put16(ack + 10, FRAME_H);
    if (send_msg(fd, T_HELLO_ACK, 0, ack, 12) != 0) return;

    uint8_t *inbuf = (uint8_t *)malloc(NPIX + 16), *outmsg = (uint8_t *)malloc(TELEMETRY_BYTES + NPIX);
    if (!inbuf || !outmsg) { send_error(fd, E_NOMEM); free(inbuf); free(outmsg); return; }
    uint32_t seq_ring[N_SLOTS] = {0};
    uint32_t in_wr = 0, out_done = 0;

    for (;;) {
        struct pollfd pf = { fd, POLLIN, 0 };
        int pr = poll(&pf, 1, 1);
        if (pr < 0 && errno != EINTR) break;
        if (pr > 0) {
            if (pf.revents & (POLLHUP | POLLERR)) break;
            if (read_exact(fd, h, 16) != 0) break;
            if (get32(h) != NV_MAGIC) { send_error(fd, E_BAD_MAGIC); break; }
            if (get16(h + 4) != NV_VERSION) { send_error(fd, E_BAD_VERSION); break; }
            type = get16(h + 6); uint32_t seq = get32(h + 8); len = get32(h + 12);
            if (type == T_FRAME_IN) {
                if (len != NPIX) { send_error(fd, E_BAD_SIZE); break; }
                if (read_exact(fd, inbuf, NPIX) != 0) break;
                if (in_wr - csr_rd(R_IN_RD_SEQ) >= N_SLOTS) { send_error(fd, E_BUSY); break; }
                unsigned slot = in_wr % N_SLOTS;
                ddr_write(slot, inbuf);
                seq_ring[slot] = seq;
                __sync_synchronize();
                in_wr++;
                csr_wr(R_IN_WR_SEQ, in_wr);
            } else if (type == T_CSR_WRITE && len == 8) {
                uint8_t p[8];
                if (read_exact(fd, p, 8) != 0) break;
                uint32_t a = get32(p), v = get32(p + 4);
                if (a < 256 * 4 && (a & 3) == 0 && a / 4 != R_IN_WR_SEQ) csr_wr(a / 4, v);
            } else if (type == T_CSR_READ && len == 4) {
                uint8_t p[4], r[8];
                if (read_exact(fd, p, 4) != 0) break;
                uint32_t a = get32(p);
                put32(r, a); put32(r + 4, (a < 256 * 4 && (a & 3) == 0) ? csr_rd(a / 4) : 0);
                if (send_msg(fd, T_CSR_REPLY, seq, r, 8) != 0) break;
            } else {
                send_error(fd, E_BAD_SIZE); break;
            }
        }
        /* completed frames */
        uint32_t os = csr_rd(R_OUT_SEQ);
        while (out_done < os) {
            unsigned slot = out_done % N_SLOTS;
            build_telemetry(outmsg, out_done + 1);
            ddr_read(slot, outmsg + TELEMETRY_BYTES);
            if (send_msg(fd, T_FRAME_OUT, seq_ring[slot], outmsg, TELEMETRY_BYTES + NPIX) != 0) goto done;
            out_done++;
        }
    }
done:
    engine_stop();
    free(inbuf); free(outmsg);
}

int main(int argc, char **argv)
{
    int port = 5002;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ddr-base") && i + 1 < argc) ddr_phys = (uint32_t)strtoul(argv[++i], NULL, 0);
        else { fprintf(stderr, "usage: %s [--port N] [--ddr-base 0xADDR]\n", argv[0]); return 2; }
    }
    signal(SIGPIPE, SIG_IGN);                               /* a client vanishing must not kill the daemon */

#ifdef NV_SIM
    ddr = (volatile uint8_t *)calloc(DDR_REGION_SPAN, 1);
    sim_regs[R_VERSION] = NV_EXPECTED_BUILD; sim_regs[R_STATUS] = ST_READY;
    printf("nv_streamer (SIMULATED hardware): passthrough emulator, port %d\n", port);
#else
    int memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (memfd < 0) { fprintf(stderr, "open /dev/mem: %s (run as root)\n", strerror(errno)); return 1; }
    void *lw = mmap(NULL, HPS_LW_BRIDGE_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, (off_t)HPS_LW_BRIDGE_BASE);
    void *dr = mmap(NULL, DDR_REGION_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, (off_t)ddr_phys);
    if (lw == MAP_FAILED || dr == MAP_FAILED) { fprintf(stderr, "mmap: %s\n", strerror(errno)); return 1; }
    csr = (volatile uint32_t *)((uint8_t *)lw + NV_CSR_OFFSET);
    ddr = (volatile uint8_t *)dr;
    printf("nv_streamer: CSR at 0x%08lX, VERSION 0x%08X, DDR3 rings at 0x%08X\n", HPS_LW_BRIDGE_BASE + NV_CSR_OFFSET, csr_rd(R_VERSION), ddr_phys);
    /* The preloader on the SD card was built for an older design and leaves the FPGA-to-SDRAM ports in reset (fpgaportrst = 0):
     * the engine's reads return nothing and its writes never land (docs/bug_log.md #10). Release them here until the preloader is rebuilt. */
    {
        volatile uint32_t *sdr = (volatile uint32_t *)mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0xFFC25000);
        if (sdr == (volatile uint32_t *)MAP_FAILED) { fprintf(stderr, "mmap sdr: %s\n", strerror(errno)); return 1; }
        uint32_t before = sdr[0x80 / 4];
        if ((before & 1u) == 0) sdr[0x80 / 4] = 0x3FFF;
        printf("SDRAM fpgaportrst 0x%04X -> 0x%04X\n", before, sdr[0x80 / 4]);
    }
    /* bus echo test before anything else (checklist 4.6): a register that must read back what was written */
    csr_wr(R_SCRATCH, 0xA5C31E7Fu);
    if (csr_rd(R_SCRATCH) != 0xA5C31E7Fu) fprintf(stderr, "WARNING: CSR scratch echo failed (is the right bitstream loaded?)\n");
#endif

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind"); return 1; }
    if (listen(srv, 2) != 0) { perror("listen"); return 1; }
    printf("listening on port %d (Ctrl+C to stop)\n", port);
    fflush(stdout);

    for (;;) {
        struct sockaddr_in cli;
        socklen_t clilen = sizeof(cli);
        int fd = accept(srv, (struct sockaddr *)&cli, &clilen);
        if (fd < 0) { if (errno == EINTR) continue; perror("accept"); break; }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        printf("connection from %s\n", inet_ntoa(cli.sin_addr));
        fflush(stdout);
        handle_conn(fd);
        close(fd);
        printf("connection closed\n");
        fflush(stdout);
    }
    close(srv);
    return 0;
}
