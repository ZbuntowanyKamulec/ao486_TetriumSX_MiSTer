/* CoreMark port for the Tetrium benchmarks: no timer (the testbench counts
 * cycles), seeds for a performance run, ITERATIONS set at build time. */
#include "coremark.h"
#include "core_portme.h"
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
static CORE_TICKS t0, t1, ticks;
void start_time(void) { t0 = ++ticks; }
void stop_time(void) { t1 = ++ticks; }
CORE_TICKS get_time(void) { return t1 - t0; }
secs_ret time_in_secs(CORE_TICKS t) { return (secs_ret)t; }
ee_u32 default_num_contexts = 1;
void portable_init(core_portable *p, int *argc, char *argv[]) { (void)argc; (void)argv; p->portable_id = 1; }
void portable_fini(core_portable *p) { p->portable_id = 0; }
