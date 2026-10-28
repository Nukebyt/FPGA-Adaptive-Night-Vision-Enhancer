# FPGA Design & Bring-up Checklist — DE10-Standard / Cyclone V / Quartus Prime Lite 21.1

A distilled, reusable rulebook built from the complete bug history of three real
projects on this exact board: a streaming-DSP project (35 documented bugs,
from RTL authoring through synthesis, place & route, SD-card flashing, and
HPS/Linux integration), a hand-built AXI4 full crossbar verified with a UVM
environment (7 documented bugs — see `bugs.md`), and a systolic-array INT8
NPU taken from a golden-model/UVM simulation environment through synthesis,
Nios II soft-core SoC integration, and a full hardware verification +
Fmax-characterization campaign (25 documented bugs + 11 non-findings — see
that project's own `docs/bugs.md`). Together these cover three genuinely
different toolchain/simulator/SoC-integration paths on the same board and
device family, which is why the gotchas don't overlap much: RTL/synthesis
issues repeat across projects, but simulator setup (Icarus vs. Questa/UVM)
and SoC-integration path (HPS/Linux vs. Nios II soft core vs. no SoC at all)
each surface their own, unrelated category of mistake.

**Purpose:** paste or reference this at the start of a new FPGA project session
so the same class of bug is caught by a checklist instead of rediscovered by a
multi-hour debugging session. Every rule below cost real time to learn; none of
it is generic advice copied from a textbook.

**Target environment this was derived from:**

| Item | Value |
|---|---|
| Board | Terasic DE10-Standard |
| Device | Cyclone V `5CSXFC6D6F31C6` |
| Capacity | 41,910 ALMs · 112 DSP blocks · M10K block RAM |
| Toolchain | Quartus Prime Lite **21.1** |
| Simulator | Icarus Verilog (`iverilog -g2005`) for the DSP project; Questa Sim 2024.1 (UVM) for the crossbar and NPU projects |
| SoC (HPS/Linux path) | HPS (dual Cortex-A9) + DDR3, Terasic GHRD base |
| SoC (Nios II path) | `altera_nios2_gen2` soft core (`impl=Tiny`), no HPS/Linux involved — a separate integration path, see §2.5 |
| HPS Linux | Angstrom v2014.12 — Python **2.7 only**, no pip, ~51 MB free, dead opkg feeds |
| HPS↔FPGA | Lightweight bridge @ `0xFF200000`, span `0x200000` |

Rules marked **[Cyclone V / Q21.1]** are toolchain-specific. Rules marked
**[Universal]** apply to any FPGA work.

---

## 0. The five rules that would have prevented the most damage

If you read nothing else:

1. **A passing simulation does not mean working hardware.** Simulation has no
   concept of gate delay, wire delay, temperature, or bus timing. Run
   `quartus_sta` and read the actual slack number before you flash anything.
   **Add it to the build the day you synthesise your first module** — in the
   source project its absence hid a three-clock-period critical path for the
   entire life of the project while every other signal said "correct."
   A design that violates timing can still produce plausible output when its
   data source is slower than its clock; that is the most dangerous failure
   mode there is, because it looks like success.
2. **Never pair a saved bitstream with newer host software.** A bitstream is a
   versioned build artifact independent of your source tree. An Avalon write to
   a register that doesn't exist in older silicon is *legal and silent* — no
   error, just wrong results.
3. **Identical input must produce identical output.** Make this your first
   hardware test, always. Non-reproducibility means state is leaking between
   runs, and every measurement taken in that state is void.
4. **Test the timing dimension your testbenches don't vary.** Almost every
   testbench feeds data one item per cycle. Real sources pause. That single
   untested dimension hid the worst bug in the project.
5. **A hypothesis that explains the symptom is not a root cause until tested.**
   Prefer the cheap experiment that *discriminates between* hypotheses over the
   plausible story that accommodates all of them.
6. **A clean `quartus_sta` exit code does not prove the constraint set is
   complete.** Adding a PLL-derived clock domain without calling
   `derive_pll_clocks` leaves that entire domain with **zero timing
   constraint** — every tool in the flow reports "0 errors," a programmable
   bitstream comes out, and it looks exactly like clean timing closure at the
   new frequency, while the domain the whole exercise existed to check was
   never analyzed at all. Rule 1 above ("run `quartus_sta`") is necessary but
   not sufficient — you must also confirm the clock you care about actually
   *appears* in the slack tables it prints.

---

## 1. RTL coding rules

### 1.1 Memory inference **[Cyclone V / Q21.1]**

- **Never write an `always` block that should infer RAM inline inside a
  `generate for` body.** Quartus Prime Lite 21.1 will not recognize it and
  synthesizes raw flip-flops instead. Real measured cost in this project:
  **195,947 logic elements / 1,472 memory bits** instead of
  **4,272 LEs / 116,160 memory bits** — a ~46x logic blowup.
  **Fix:** extract the memory into a standalone `module`, instantiate it once
  per tap inside the `generate for`. Same logic, same code, different syntactic
  placement — and it infers correctly.
- This is *not* a general Verilog rule and is not documented by Intel. It is a
  specific limitation of this inference pass.
- **Red flag to watch for:** a resource report showing near-zero memory bits for
  something that is obviously memory. Check syntactic placement *before*
  assuming the logic is wrong.
- Verify inference with a tiny isolated synthesis probe project, not by reading
  the full design's report.
- **Combinational reads are not recognized as RAM-inference material at all.**
  `assign dbg_data = mem[dbg_addr];` compiles clean but Quartus's inference
  pattern-matcher only recognizes a **registered** read (a clocked output) as
  the simple-dual-port shape. A combinational read instead built the whole
  array as raw fabric logic — an 8x ALM jump (148 → 1,220) with `Total RAM
  Blocks` staying at **0**. **Fix:** `always_ff @(posedge clk) dbg_data <=
  mem[addr];` — one cycle of registered latency, then re-verify in simulation.
- **A runtime `for`+`if(wstrb[b])` byte-enable loop inside one `always` block
  is not recognized as RAM-inference material either**, even though it
  simulates correctly. **Fix:** one separate clocked block *per byte lane*,
  generated with `genvar`/`generate` (`for (gb=0; gb<STRB_WIDTH; gb=gb+1)
  begin : g_byte_write ... end`) — the idiom Quartus's pattern matcher
  actually recognizes.
- **Questa rejects Quartus's own recognized byte-enable idiom if written with
  `always_ff`:** `Variable 'mem' driven in an always_ff block, may not be
  driven by any other process` — SystemVerilog enforces single-driver-per-
  variable at *whole-array* granularity for `always_ff`, even when each
  generate iteration only touches its own disjoint bit-slice. Quartus has no
  such objection. **Fix:** use plain `always @(posedge clk)` for the per-lane
  blocks — synthesis-identical, and it satisfies both tools.
- **A dead read port can get the whole array deleted, not just optimized.**
  If nothing downstream ever samples a memory's read output as live (e.g. an
  AXI read channel that's never actually driven because every connected
  master is write-only), Quartus can *prove* the storage never reaches an
  output pin and deletes it entirely — `Total block memory bits: 0`, even
  though every write was semantically correct and the module "worked." This
  also removes the only node SignalTap could have probed. **Fix:** if nothing
  in the real datapath reads a memory back yet, add a cheap debug-only
  readback port (bypass the protocol entirely) so the storage stays live,
  observable, and testable.
- **Getting a memory inferred, mapped to block RAM, kept alive, and
  elaborating cleanly in both tools are four separate, independently-failing
  conditions** — indexing shape, byte-enable shape, registered-read-on-every-
  consumer (dead or not), and the `always` vs `always_ff` driver rule. None of
  the intermediate broken states throw an error in Quartus; it silently falls
  back to a logic-only implementation every time a shape doesn't match.
  **Debugging tip:** iterate with `quartus_map` alone (synthesis report only,
  seconds not minutes) rather than a full `quartus_fit` compile — it's what
  makes finding which of the four conditions failed tractable.

### 1.2 Same-cycle read-after-write **[Universal]**

- If an `always` block writes `mem[addr] <= x` with a non-blocking assignment
  and another expression in the *same* block reads `mem[addr]`, the read gets
  **stale data** — the write isn't visible until the next edge.
- **Fix:** add an explicit bypass for the element known to be current-cycle
  data; read the input signal directly rather than through the memory.
- **Detection trap:** on smooth synthetic stimulus this produces a suspiciously
  *clean constant* error (in this project, exactly `2×SLI`). A clean constant
  offset is a symptom to investigate, not evidence of a simple fixable
  off-by-one.

### 1.3 Port widths **[Universal]**

- Declare flattened bus ports with the full computed width
  (`output reg signed [SLI*SLI*DATA_WIDTH-1:0] bus`), never the element width.
- A too-narrow port declaration is **zero-padded silently** by the simulator.
  It compiles, it runs, and it produces plausible wrong values.
- Cross-check every port declaration against the widest expression that
  indexes it inside the module.

### 1.4 Fixed-point discipline **[Universal]**

- **Every fixed-point value carries a scale. Write it in the port comment.**
  (`// Q2.13`, `// Q4.12`.) Two values from different sources meeting at one
  arithmetic operator is the single most common silent numeric bug.
- Before any `a + b` / `a > b` between values from different modules or
  different generator scripts, verify their fractional bit counts match, and
  insert an explicit rescale if not. "Just add them" reads correctly in English
  and is wrong in hardware.
- **Reciprocal-multiply precision:** `INV_N = (1<<M)/N` truncates. At `M=16`,
  `N=40` this produced the wrong rounding direction on **~84% of inputs**, all
  biased the same way. `M=24` reduced it to ~2.5%, confined to exact `.5` ties.
  **Sweep `M` against exact-fraction arithmetic in Python before picking it** —
  don't guess.
- When you change a precision constant in RTL, **change it in the golden
  reference model in the same commit.** Otherwise the RTL becomes *more*
  accurate than the thing verifying it, and you get an artificial mismatch.

### 1.5 Shared modules with differently-timed call sites **[Universal]**

- A parameterized utility module (delay line, FIFO, counter) instantiated in two
  places often needs *semantically different* enable logic at each site.
  Example from this project: one `pipe_delay` instance must advance on every
  non-stalled clock cycle; another must advance only on *accepted data* cycles.
  A shared `we = !stall` was correct for one and wrong for the other.
- **Rule:** if two instantiations of the same module have different notions of
  "when time advances," parameterize the enable condition — don't share it.
- This bug is invisible under gap-free streaming and only appears under real
  bus timing.

### 1.6 Handshake and backpressure **[Universal]**

- An extra register stage on a `ready`/`valid` handshake signal is **invisible
  under back-to-back never-stalled traffic** and only diverges once real
  backpressure exercises the boundary cycle.
- Present handshake signals combinationally unless you have a specific timing
  reason not to — and if you register one, re-verify under stall.
- **Best test:** a differential testbench running a known-correct direct-drive
  instance alongside the wrapped instance, comparing cycle by cycle. This caught
  the bug in one run where result-only testbenches passed.

### 1.7 Unstated timing preconditions **[Universal]**

- **The highest-value question in this whole document:** *what does real
  hardware do that none of my testbenches do?*
- A module can carry an unstated precondition about *input timing* that every
  test satisfies by construction. Every testbench in this project fed one pixel
  per cycle — so all of them silently encoded "the source is infinitely fast."
  Real hardware pauses. That was the root cause of a bring-up failure that
  produced **zero output** and survived a comprehensively passing test suite.
- **Rule:** for every streaming module, write at least one testbench with
  randomized gaps and randomized stalls. Parameterize the gap so it can be
  swept 0..N.

### 1.8 Frame/transaction boundaries and sticky state **[Universal]**

- Any "warm-up complete" / "initialized" flag that is **sticky** across a
  transaction will contaminate the *next* transaction.
- Provide an explicit **soft-reset register** that re-arms per-frame state, and
  require software to pulse it before every frame.
- RAM *contents* need not (and cannot) be cleared — re-running warm-up is what
  handles stale contents, exactly as at power-on. Reset the *control* state.
- Reset the result-latch registers on the soft reset too, or a stale result from
  the previous frame is readable as if it belonged to the new one.
- **Beware:** a fix that removes one failure mode can install another at a
  different scope. Fixing correctness *within* a frame moved the defect to the
  boundary *between* frames. Ask, of any "hold state instead of clearing it"
  change: *what used to depend on that clearing?*

### 1.9 Constructs that simulate but don't synthesize **[Universal]**

- **Verilog hierarchical references** (`top.sub.internal_signal`) work fine in
  Icarus and are unambiguous Verilog — and Quartus Prime Lite 21.1 **rejects
  them outright** ("can't resolve reference to object").
  **Fix:** expose the signal as a real port on the child module.
- `break` inside a loop is SystemVerilog; Icarus in `-g2005` mode rejects it.
  Use a loop condition instead — also more portable.
- **Rule:** simulator acceptance and synthesizer acceptance are independent.
  Never assume they agree. Build a 4-minute isolated `quartus_map` probe before
  committing to a 90-minute full build.
- **Inline `genvar` in a `for` loop header** (`for (genvar gi = 0; gi < N;
  gi++)`) is SystemVerilog-2009 shorthand, accepted fine by Questa — and
  rejected by Quartus Prime Lite 21.1's synthesis-frontend parser:
  `near text: "genvar"; expecting an identifier`. **Fix:** declare `genvar
  gi;` separately before the loop, drop the keyword from the header.
- **`localparam` declared inside a module's `#(...)` parameter port list**
  (to derive one parameter from another right there in the header) is legal
  SystemVerilog, Questa-accepted, and rejected by Quartus: `near text:
  "localparam"`. **Fix:** move it into the module body, right after the port
  list and before first use — semantically identical as long as the port list
  itself never referenced it.
- Both of the above are invisible for an entire project's worth of
  simulation-only phases and only surface the first time RTL goes through a
  real synthesis tool. Apply the fix to **every** file with the pattern, not
  just the one the error message points at — the same construct is usually
  copy-pasted across sibling `generate` blocks.

### 1.10 One clock cycle is a budget, not a free pass **[Universal]**

This one cost more than any other single defect in the source project — a
**three-clock-period critical path that survived from a module's first
synthesis through months of work**, because every functional test passed.

- **A clocked `always` block with chained blocking assignments describes
  combinational logic between two registers, however many lines it is.**
  Writing eight arithmetic operations as eight sequential statements does not
  give them eight cycles — it gives them one, and builds the whole chain in
  logic. The offending module did: two 64-bit subtracts → 64×24 multiply →
  rounding divide → **64×64 multiply** → divide → multiply-subtract → 64-bit
  multiply → divide, all between two clock edges. Measured: **54.352 ns
  against a 20 ns period.**
- **Budget roughly one significant arithmetic operation per pipeline stage**
  for multiplies, divides, and wide adder trees at 50 MHz on this device.
- **Never declare intermediates wider than their actual range.** Every
  intermediate above was `reg signed [63:0]` "to be safe," which forced the
  one variable×variable multiply to synthesise at full 64×64. Narrowing the
  squared term to its real 32-bit range (justified: it feeds a 32-bit output,
  so anything wider was already broken) was most of the win. Multiplying by a
  **compile-time constant** is far cheaper than a general multiply — know
  which of yours are which.
- **Watch for stacked reduction trees.** A second violation in the same
  project summed *every* stored row accumulator in one combinational sweep on
  the final cycle of a bootstrap — an `SLI-1`-deep adder tree stacked on top
  of an `SLI`-deep tree and `SLI` multipliers, all reached through an 18:1
  mux. **Fix: accumulate incrementally** as each element completes, so the
  last cycle does one add. Bit-exact, because integer addition is
  associative.
- **Pipelining is value-preserving if you only insert registers.** Keep the
  operations and their widths identical, carry a `valid` shift register
  alongside, and re-verify bit-exactness — then the only thing that changed
  is latency. Export the latency as a `localparam` and mirror it in any
  parallel delay line (and in every testbench latency ledger).
- **Result in the source project:** −34.968 ns → −3.517 ns slack from
  pipelining one module, with resources essentially unchanged (52% ALM, 71%
  DSP), and 100.0000% bit-exactness preserved.

### 1.11 General style that paid off **[Universal]**

- Derive every dependent constant with a `localparam` expression rather than a
  hand-typed number, so one parameter change propagates.
- **Exception:** when a constant needs true round-to-nearest (Verilog integer
  division truncates), precompute it offline with a script and hardcode it —
  *with a comment naming the script that generates it.*
- Keep a single source of truth for shared constants and enumerate every place
  they are duplicated. This project had the same four constants copied across
  **9+ files** (RTL, Qsys `.tcl`, `.qsys`, generated `.v`, Python config, MATLAB
  generator, three test generators). Every geometry change needed a lockstep
  edit of all of them. If you cannot avoid the duplication, write the list of
  locations into a comment at the primary definition site.

### 1.12 Interface instance arrays reject runtime indexing **[Universal]**

- Indexing a *plain data* array with a runtime variable is completely normal
  Verilog. Indexing an **array of interface instances**
  (`axi4_if.slave s_axi [N]`) the same way is not — only constant/genvar
  indices are legal there, since each array element is conceptually a
  distinct set of nets, not a memory location. This trips both inside a
  plain (non-genvar) `for`/`always_comb` loop and on a direct
  `s_axi[runtime_sel]` reference fed by, e.g., an arbiter's grant index.
- **Fix:** a `generate for (genvar gi = ...)` loop (genvar indices *are*
  legal into an interface array) extracts each element's fields into plain
  `logic [...] arr [N]` arrays first. The actual runtime-indexed mux then
  operates only on those plain arrays, where indexing is unrestricted.
- **Rule of thumb:** flatten per-port signals into plain packed/unpacked
  arrays (or a struct-of-arrays) early for any muxing-heavy internals; reserve
  the interface-array form for the module boundary only.
- Applies to *every* interface instance array in a module — recurring on a
  second array in the same file (e.g. the downstream/slave-facing side after
  fixing the upstream/master-facing side) is not a new bug, just the same
  constraint applying twice.

### 1.13 Parameterized-interface port syntax **[Universal]**

- `axi4_if #(.WIDTH(WIDTH)).slave s_axi [N]` — explicit parameter overrides
  combined with a modport in one ANSI-style interface port header — is legal
  per the LRM but not accepted as written by every tool (rejected by Questa
  2024.1: `near "#": syntax error, unexpected '#', expecting ')'`).
- **Fix:** drop the parameter list from the port header
  (`axi4_if.slave s_axi [N]`); the concrete widths come from whichever
  instance the caller connects. This trades away port-level width-mismatch
  checking, so keep the module's own width localparams consistent with what
  callers instantiate **by documented convention**, and consider the
  stricter explicitly-parameterized form plus lint/CI once portability across
  tool versions stops being a constraint.

### 1.14 Multi-outstanding-transaction response routing **[Universal]**

- A B/R response router that broadcasts a master's own `BREADY`/`RREADY` to
  *every* slave whose response happens to be tagged for that master is only
  safe if at most one slave can ever be presenting a valid response to that
  master at once. That assumption holds trivially at outstanding-depth 1 and
  breaks silently the moment a master can have transactions outstanding to
  **multiple different slaves simultaneously**.
- **Failure mode:** two slaves both assert `VALID` for the same master on the
  same cycle; the master asserts ready meaning to consume one, both slaves'
  handshakes complete simultaneously, and the output mux can only present one
  — the other is silently dropped from the master's side even though the
  slave believes it delivered. Manifests as a response with the wrong ID
  arriving and the actually-requested one never showing up (permanent hang on
  that wait).
- **Fix:** real per-master arbitration among contending slaves for B and R —
  a combinational "winner" scan (fixed lowest-index-wins priority is fine;
  fairness *among responses* isn't a correctness requirement here) gates
  `BREADY`/`RREADY` to only the winning slave, holding every other contender
  deasserted. This is legal because AXI4 already requires a slave to hold
  `VALID` and its data stable until its own handshake completes — a
  non-winning response just waits for the next cycle's scan.
- **This class of bug is invisible to every earlier-phase regression** that
  never exercised the higher outstanding depth — re-run the full regression
  after raising outstanding depth or master/slave count, don't assume a
  previously-passing suite still covers the new configuration.

### 1.15 `ref` vs `inout` task arguments when a DUT must observe a signal *changing*, not just its final value **[Universal]**

- SystemVerilog `inout` task arguments use **copy-in/copy-out** semantics:
  the caller's variable is copied in at task entry and copied back out only
  when the task **returns**. A task that pulses a signal low then high again
  before returning (e.g. simulating a button press) writes back a value
  identical to what it started with — the DUT, watching the real net
  continuously, never observes the intermediate pulse at all, even though
  the task's own internal timing is completely correct.
- **The failure is silent and total**: no error, no mismatch pointing at the
  task — every downstream check just fails as if the stimulus never
  happened, because from the DUT's perspective it didn't.
- **Fix:** use `ref`, not `inout`, for any task argument that must drive a
  signal *during* execution (`ref logic [3:0] keys`, not
  `inout logic [3:0] keys`). `ref` is true by-reference aliasing — every
  intermediate assignment inside the task is immediately visible to
  anything watching the real net.
- **Rule of thumb:** if a task's job is "wiggle this signal for N cycles," it
  needs `ref`. If it only ever reports a final settled value back to the
  caller, `inout`/`output` is fine.

### 1.16 A long real-world counter makes a design untestable in simulation without being wrong in hardware **[Universal]**

- A power-on-reset (or similar) counter sized generously for real hardware
  (e.g. 20 bits, ~21 ms at 50 MHz — genuinely reasonable, a human would
  never notice) can sit far outside any normally-scoped testbench's total
  simulated cycle count, so the design never leaves reset in simulation at
  all. Every check fails, and it looks exactly like an RTL/reset bug — it
  isn't one.
- **Distinguish this from every other failure mode:** it is not a logic bug
  and not a timing bug — it is a *scale* mismatch between what's reasonable
  for a human at power-on and what's reasonable for a testbench's stimulus
  length. A `$strobe` trace showing the reset signal simply never
  deasserting, for a plausible, round-number reason (counter width × clock
  period), is the tell.
- **Fix:** make the counter width a module parameter (e.g. `POR_BITS`,
  default = the real hardware value) and override it to something small
  (e.g. 4) in the testbench instantiation only — the same
  "testbench-overridable parameter, real-hardware default kept separate"
  pattern you'd use for any config sweep.

---

## 2. Quartus / toolchain gotchas **[Cyclone V / Q21.1]**

### 2.1 The optimizer crash

- **Signature:** `Internal Error … RTL_ADDER::aggressive_adder_balancing`,
  `opt_op_add.cpp` line 10225, sub-system OPT.
- **Trigger:** large combined arithmetic (wide adder trees + multiply-accumulate)
  once flattened together.
- **It is NOT monotonic in your design parameters.** A *smaller* configuration
  can crash where a larger one doesn't. Never extrapolate "this is smaller so it
  will fit" — that assumption cost 7 failed builds in this project.
- **It ignores per-instance scoping.** `set_instance_assignment … -to
  <instance_path>` for `OPTIMIZATION_TECHNIQUE` or `AUTO_DSP_RECOGNITION` has
  **no effect** on this crash, even with a verified-correct hierarchy path — the
  pass operates on the fully-flattened whole-design netlist. Only the global
  default changes its behavior.
- **Both known global workarounds carry severe costs:**
  - `OPTIMIZATION_TECHNIQUE AREA` (global) — avoided the crash and fit the ALM
    budget, but destroyed timing **project-wide**, including HPS/DDR3 paths
    unrelated to the offending logic: **−15.480 ns setup slack, −45,308 ns TNS**.
  - `AUTO_DSP_RECOGNITION OFF` (global) — avoided the crash, but forced
    multiplies into logic everywhere in the SoC: **73,449 logic cells vs 44,961**
    baseline.
- **Conclusion:** treat any change to arithmetic width or window size as
  requiring an *empirical* synthesis check. Budget for it. Do not extrapolate.

### 2.2 Timing closure is a separate, mandatory step

- `quartus_fit` reporting success and a resource count under budget means
  **"compiles and fits"** — a completely different claim from **"works
  reliably in silicon."**
- **Always run `quartus_sta` and read `output_files/*.sta.summary`.** Check the
  worst corner, typically `Slow 1100mV 85C Model Setup`.
- **Negative slack manifests as thermal-looking degradation**: results get worse
  as the chip warms under sustained use, and identical runs disagree. If you see
  run-to-run degradation, check slack *and* check reproducibility (§4.1) —
  both produce this signature and they are easy to confuse.
- Any optimization-technique change known to trade timing for area **requires**
  a fresh timing run. This was the actual process gap that flashed a bad build.
- **A timing-closure claim is only as good as the constraint set that
  produced it — a clean `quartus_sta` exit code does not prove the
  constraint set is complete.** Adding a PLL-derived clock domain without
  calling `derive_pll_clocks` (the TimeQuest command that auto-generates
  `create_generated_clock` for every PLL output) leaves that entire domain
  with **zero timing constraint**. TimeQuest silently excludes every path in
  it from every slack report rather than erroring, and the fitter — which
  already ran under the same incomplete SDC — was never told to optimize
  for that domain's target frequency at all. `map`/`fit`/`asm`/`sta` all
  report "0 errors," a programmable bitstream comes out, and it looks
  exactly like "the new frequency closes cleanly."
  **Two specific tells, easy to skim past:**
  1. The per-corner slack tables in the STA log only list clocks that
     *were* constrained — if your new domain's clock name never appears in
     any of them, it was never analyzed.
  2. `Info: Design is not fully constrained for setup/hold requirements`
     near the end of the STA run, plus a PLL cross-checking warning about a
     "missing generated clock" during clock-uncertainty derivation.
  **Fix:** call `derive_pll_clocks` (after your explicit `create_clock`
  calls, before `derive_clock_uncertainty`) any time a PLL is added. After
  any STA run touching a new clock domain, confirm that domain's actual
  clock name appears in the slack tables before trusting the numbers —
  don't stop at the exit code or the headline "N errors, M warnings" line.

### 2.3 Platform Designer / Qsys components

- Pin the correct package version in `_hw.tcl`
  (`package require -exact qsys <version>`). Wrong version → the component is
  **silently invisible** to `add_instance`, with no error.
- `TOP_LEVEL_HDL_FILE` is deprecated and **silently aborts elaboration**. Use
  the `add_fileset` / `set_fileset_property … TOP_LEVEL` pattern.
- **Bugs mask each other.** The version-pin bug had to be fixed before
  elaboration would even *attempt* to run and surface the next one. A diagnostic
  that stops at the first error is not the same as having found all the errors.
- **`qsys-generate` can regress generated files.** In this project a full
  regeneration dropped required entries from `soc_system.qip`, breaking the DDR3
  sequencer build. The patch must be **re-applied after every regeneration** —
  document it as recurring, not as fixed.
- Because regeneration is risky, hand-editing the already-generated
  `soc_system.v` instantiation parameters is sometimes the safer path. If you do
  that, note it prominently — it is invisible to anyone reading only `.qsys`.
- **`add_fileset <name> <QUARTUS_SYNTH|SIM_VERILOG|...> generate`'s third
  argument is a *callback name*, not a free-form label.** Setting it to
  `generate` tells Platform Designer this fileset's file list is produced
  dynamically by a Tcl proc literally named `generate` (legitimate for
  components that render a file from a `.terp` template using instance
  parameters, e.g. one that bakes in a runtime ID/timestamp). For a
  component with a fixed, static file list and no such proc, this passes
  `add_instance`/validation fine and only fails later, at `qsys-generate`,
  with `invalid command name "generate"` — a confusing error pointing at
  the wrong layer. **Fix:** for a static file list, pass an empty callback
  (`add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""`), matching a working
  example component's `_hw.tcl` rather than a template that happens to use
  the dynamic form.

### 2.4 Bitstream generation and flashing

- **Always convert with compression on:**
  `quartus_cpf -c -o bitstream_compression=on foo.sof soc_system.rbf`
- A `.rbf` built **without** compression is roughly **2.4x larger** and will not
  load — a silent bring-up failure that looks like a dead design.
- **Sanity-check the output size against the last known-good `.rbf` before
  copying it to the card.** A large size delta sitting in the same directory is
  the cheapest possible check and was missed once here.
- **Prefer the project's existing script/Makefile target over hand-typing an
  equivalent command.** The flags such scripts carry are load-bearing and
  usually undocumented at the call site.
- On the DE10-Standard the bitstream lives on the **FAT partition
  (`/dev/mmcblk0p1`)** as `soc_system.rbf`, loaded by u-boot at boot. You can
  mount it from the running HPS Linux (`mount /dev/mmcblk0p1 /mnt/boot`), replace
  the file over SSH, `sync`, and reboot — **no SD card removal required.**
- **Back up the working `.rbf` on the FAT partition before overwriting it.**

### 2.4a Direct JTAG programming on a Cyclone V SoC's two-tap chain

The above is the SD-card/HPS-Linux flashing path. A pure fabric design
(bare-metal Nios II or no soft processor at all) is more often programmed
directly over JTAG (`quartus_pgm`), which has its own, unrelated gotcha:

- **Every Cyclone V SoC device presents two JTAG taps on the chain: the HPS
  (ARM) at one position, the FPGA fabric at another** — confirmed directly
  by `jtagconfig`'s own scan output. `quartus_pgm --mode=jtag -o
  "p;file.sof"` **with no explicit device index defaults to chain position
  1**, which is commonly the HPS tap, not the FPGA fabric.
- **Symptom:** `Error (209015): Can't configure device. Expected JTAG ID
  code 0x02D020DD for device 1, but found JTAG ID code 0x4BA00477` (or the
  equivalent pair for your specific device) — the tool is working
  correctly, it's just looking at the wrong tap.
- **Fix:** always target the FPGA fabric explicitly with an `@N`
  device-index suffix (`-o "p;file.sof@2"`) — confirm the right index once
  with `jtagconfig` for your specific board/cable and treat that as the
  permanent reference command going forward, never the bare default.
- **A generic-looking device-name label in `jtagconfig`'s scan output**
  (e.g. a sibling part number, not literally your exact target part) **is
  not by itself evidence of a device mismatch** — Cyclone V parts at the
  same density grade can share silicon and therefore a JTAG IDCODE. What
  matters is whether the raw IDCODE `quartus_pgm` computes from your actual
  `.sof` (built for your actual target part) matches what's on the chain —
  confirm via the IDCODE, not the label.

### 2.5 Nios II soft-core integration (Platform Designer/Qsys) — a distinct gotcha category from HPS/Linux

Everything in §5 below is about the *HPS* (hard ARM cores) on a Cyclone V
SoC. A Nios II *soft* core (synthesized into fabric, no HPS/Linux involved)
is a completely different integration path with its own, unrelated set of
gotchas:

- **The `altera_nios2_gen2` IP's `impl=Tiny` (the "/e" economy variant)
  still exposes two separate Avalon-MM masters — `instruction_master` and
  `data_master` — not one combined master.** Older/generic Nios II/e
  knowledge (classic SOPC-era IP) assumes a single combined master; this
  gen2 IP does not work that way regardless of `impl` setting.
  **Symptom:** `qsys-generate` fails validation with `Nios is not connected
  to any instruction memory` / `Reset slave <mem>.s1 not connected to
  instruction_master`, even though `data_master` is fully, correctly
  connected. **Fix:** connect `cpu.instruction_master` to program memory
  and the debug module, mirroring every `data_master` connection — both
  masters need their own path to both, or generation fails outright. This
  is a build-time validator failure, not a hardware bug, so it's cheap to
  catch — but only if you don't assume the old single-master model still
  applies.
- **"No interrupts wired" is a decision that must be threaded through the
  hardware AND every BSP driver setting independently.** Qsys itself only
  warns (non-fatally) about an unconnected `irq` sender. The BSP's default
  HAL drivers for the system-clock timer and JTAG UART are both
  interrupt-driven unless told otherwise, and will fail to **link**
  (`undefined reference to '__alt_invalid'`, plus an explicit "requires an
  interrupt to be connected" warning) a full toolchain stage after Qsys
  generation raised no error at all. **Fix:** regenerate the BSP with
  `--default_sys_timer none` if nothing calls `alt_alarm`/`usleep`-family
  APIs, and `nios2-bsp-update-settings --set
  altera_avalon_jtag_uart_driver.enable_small_driver true` for a polled
  JTAG UART — do this for *every* peripheral whose interrupt you
  deliberately left unwired, not just the first one that errors; fixing
  one at a time just surfaces the identical failure mode for the next
  peripheral.
- **Growing on-chip RAM (e.g. because `printf` overflowed it) can silently
  create Avalon address-map overlaps for every peripheral based above the
  old boundary.** A RAM resize is not an isolated change — re-check every
  base address against the new span before rebuilding.
- **This SDK's `make`-based BSP/app build can fail under Git Bash with a
  "no rule to make target `.../system.h`" error naming a file that
  demonstrably exists on disk.** This is a path-convention mismatch, not a
  missing file: the generated Makefile computes `ABS_BSP_ROOT` via
  `$(shell pwd)`, and other literal path forms baked into the same
  Makefile don't always agree with what that specific `pwd` resolution
  reports. **Fix:** run `make` from Git Bash (so the POSIX utilities the
  Makefile needs are present) while explicitly overriding the mismatched
  variable on the command line (`make ABS_BSP_ROOT=<absolute/posix/path>`),
  exporting it plus using `make -e` if a recursive sub-make also needs to
  see the override. Confirm this is path-convention, not a real missing
  dependency, by trying the identical command from a shell with a
  *different* failure signature (e.g. plain PowerShell failing on missing
  POSIX utilities rather than "no rule to make target") before spending
  time on the wrong fix.

### 2.6 PLL-derived clock domains via Platform Designer

- **`qsys_mm.clockCrossingAdapter=AUTO` (an interconnect requirement) does
  correctly auto-insert an Avalon-MM clock-crossing bridge** when a master
  and slave end up in different clock domains (e.g. after moving one
  peripheral onto its own PLL output) — confirmed directly in the
  generation log, which names the exact signal pair it inserted a crosser
  between. Worth setting this proactively before any peripheral might move
  clock domains, rather than reactively once generation first fails.
- **A PLL's `locked` output should gate the reset of whatever it clocks, or
  you should have a documented reason it doesn't.** Platform Designer will
  generate a design with the PLL's `locked` port left completely
  unconnected without complaint beyond a single warning (`<pll>.locked must
  be exported, or connected to a matching conduit`) — the auto-inserted
  reset synchronizer for that new clock domain will then deassert on the
  upstream reset alone, with no guarantee the PLL has actually locked yet.
  There's no scripted one-line fix for this (properly gating an
  auto-inserted reset controller with a lock conduit means hand-instantiating
  a reset bridge) — but at minimum, decide deliberately whether the
  exposure window (typically just the moment right after configuration,
  before anything downstream is used) is acceptable for your design, and
  document that decision rather than leaving the warning unexamined.

### 2.7 Questa/UVM environment setup (if using Questa instead of/alongside Icarus)

- **Questa JIT-compiles a small DPI trampoline at simulation startup using
  whatever `gcc` it finds on `PATH`.** An unrelated, incompatible `gcc`
  earlier on `PATH` fails this with an opaque call-failure (not a compile
  error) and blocks every simulation, UVM or not. **Fix:** prepend the
  specific, version-matched compiler that ships alongside your Questa
  install to `PATH`, ahead of everything else, before invoking
  `vlog`/`vsim`. Do not try to fix this via `modelsim.ini`'s
  `DpiCppPath`/`DpiCppInstall` — Questa can reject both as "not qualified"
  even when they point at a compiler that works fine via the PATH-order
  fix; PATH order, not the ini file, is what actually takes effect.
- **Never manually compile a `uvm_pkg.sv` from source.** Doing so can
  compile and elaborate with zero errors and then fail deep inside UVM's
  own base classes at `run -all` with a null-DPI-function-pointer fatal —
  hand-compiling UVM produces `import`/`export` DPI declarations with no
  compiled C implementation actually linked, a failure mode with no useful
  error at the point it's introduced. Just write ordinary UVM code
  (`` `include "uvm_macros.svh"`` + `import uvm_pkg::*;`) with no explicit
  `vlog` of any UVM source file — let the simulator auto-resolve the
  import to its own precompiled, correctly-linked UVM library.

---

## 3. Verification discipline

### 3.1 Test stimulus **[Universal — this is the big one]**

- **Never verify spatial or indexing logic with a smooth/structured synthetic
  image (ramp, gradient, constant).** Such a stimulus can be *invariant under
  the very transformation the bug introduces*, making an exact, reproducible,
  wrong offset look like the unique correct answer across an entire test run.
- Use stimulus with **enough entropy that only the true alignment can match**
  (e.g. `rng.integers()` over a realistic value range).
- "The RTL passes" is only as strong a claim as the test data's ability to
  distinguish right from wrong.
- Keep a smooth ramp around as a *diagnostic* tool (clean constant errors are
  informative once you know a bug exists) — just never as the *acceptance* test.

### 3.2 Golden references

- The reference generator is **as likely to be wrong as the RTL.** Multiple bugs
  in this project were in the MATLAB/Python reference, not the hardware.
- **Cross-check with a second, independently written model** (this project used
  MATLAB *and* a from-scratch Python replica). Two implementations that agree
  are strong evidence; one is an assumption.
- Watch for **same-name-different-meaning variables** across scripts — a classic
  source of "the golden reference is itself wrong."
- **Indexing conventions must match exactly**: centre-indexed vs bottom-right
  indexed, absolute-pixel-position vs valid-output-counter. A reference file
  written one-line-per-absolute-position compared against a counter that only
  advances on valid outputs will mismatch on essentially every line.
- Prefer indexing both sides by the **same absolute stream position** with an
  explicit latency offset, over maintaining a separate skip counter.

### 3.3 Latency bookkeeping

- The moment a testbench checks an **intermediate** signal in addition to the
  final output, it re-introduces multi-latency bookkeeping. Each signal has its
  *own* offset. Do not assume a working final-stage offset applies upstream.
- Maintain an explicit **latency ledger** comment in the testbench listing each
  checked signal and its offset, derived from the pipeline structure.

### 3.4 What "bit-exact" does and doesn't certify

- Proving signal A bit-exact certifies **nothing** about signal B, even when
  both are produced by the same module on the same cycle, if B additionally
  depends on a separately-timed input.
- In this project `T_log_code` was 100.0000% bit-exact while `detect` — computed
  from the same threshold *plus* a separately-delayed pixel — was unreliable.
- **Rule:** enumerate each output's *full* dependency set before claiming a test
  covers it.

### 3.5 New testbench vs stable design

- A **FAIL from a newly written testbench against a long-stable design** should
  raise "check the testbench's own assumptions first" at least as high as "the
  design has a new bug." Several "failures" here were testbench bugs.
- Equally: an **equivalence testbench is only fair while both sides genuinely
  share the thing being held constant.** When one side's reset gained extra
  logic, a long-latent race turned into 285 mismatches that looked exactly like
  a real regression.

### 3.6 Blocking vs non-blocking assignment races in hand-rolled BFMs **[Universal]**

- Two independent testbench processes (e.g. a master BFM driving `AWVALID`
  and a slave BFM driving `AWREADY`) reacting to the same `@(posedge clk)`
  and driving a shared interface with **blocking (`=`)** assignment have a
  scheduler-dependent race on whether one process's write is visible to the
  other's read within the same delta — not guaranteed by the language, even
  if it behaves consistently on one simulator.
- **Symptom is a permanent stall, not an intermittent glitch** — if the race
  resolves the same way every time on a given simulator, the handshake never
  completes, full stop, and it looks exactly like a logic bug rather than a
  race.
- **Fix:** drive every interface signal in testbench BFMs with **non-blocking
  (`<=`) assignment**, exactly as required for synthesizable registers. The
  NBA-region update guarantees every process sees a consistent pre-edge value
  when it checks a handshake condition.

### 3.7 UVM drivers need an explicit reset-abort path **[Universal]**

- A driver's handshake wait loop (`do @(posedge clk); while (!vif.ready);`)
  with no exit condition tied to reset **blocks forever** the instant reset
  lands mid-transaction — the DUT has already cleared that transaction's
  state and will never present the handshake again, reset or no reset.
- Because a `forever`-looped `run_phase()` typically only calls
  `seq_item_port.item_done()` *after* the drive task returns, one stuck wait
  permanently wedges that sequencer — every subsequent queued item, including
  the test's own "did it recover after reset" check, waits forever too. No
  `UVM_ERROR`, no protocol violation — just silence until the global watchdog
  fires.
- **Fix:** qualify every mid-burst wait condition on `rst_n`
  (`while (!vif.ready && vif.rst_n)`), `return`/`break` out of the drive task
  the moment reset is seen, deassert whatever was already asserted, and
  re-idle before the next `item_done()`/loop iteration.
- **Test it:** drive a burst partway, pulse reset mid-burst, then require a
  fresh transaction on the same master/slave to complete cleanly afterward.
  Every phase up to this point may have only ever exercised reset in the tidy
  power-on window, which never triggers this at all.

### 3.8 SVA `bind` needs explicit compilation-unit flags to elaborate at all, and `$error` doesn't set a nonzero exit code **[Universal]**

- A `bind <target_module> <checker_module> ... (.*);` statement declared in
  a file separate from the module it targets **only elaborates correctly if
  both files are compiled into the same compilation unit** — by default,
  each file passed to `vlog -sv` is its own separate unit. Without the
  right flags, the tool accepts the syntax, prints a **warning** (not an
  error) about needing `-mfcu -cuname` (or your simulator's equivalent),
  and **never elaborates the bind at all** — the checker instance is simply
  never created in the hierarchy.
- **The failure is completely silent from the outside:** simulation runs to
  completion reporting `UVM_ERROR: 0`/`Errors: 0`, indistinguishable from a
  genuine clean pass with every assertion actually running zero times.
- **Don't trust a "0 errors" result on a freshly-added bind/assertion file
  — prove it's actually running.** Temporarily break the property itself
  (e.g. shift a `##(N)` cycle-delay assertion by one) and re-run with the
  *current* compile flags: if it still reports 0 errors, the bind never
  elaborated, full stop. Only trust the "0 errors" result once you've
  independently confirmed the same setup fires on a known-broken property.
- **A second, independent trap the same diagnostic can surface:** once
  assertions genuinely fire via `$error` (rather than `$fatal`), the
  simulator's **process exit code can still be 0** — `$error` is designed
  to let simulation continue collecting further failures, at the cost of
  not being reflected in the exit code the way `$fatal` is. Any regression
  script relying on exit code alone as its pass/fail signal will report
  PASS on a run that logged real assertion failures.
- **Fix:** (1) always compile files containing cross-file `bind` statements
  with the merged-compilation-unit flags your simulator requires. (2) Make
  your regression harness parse the simulator's own final error-count
  summary line directly out of the transcript as the authoritative
  pass/fail signal, never exit code alone.

### 3.9 Verify your regression harness the same way you verify the DUT **[Universal]**

A harness that can silently report PASS for a real failure is more
dangerous than no harness at all — it actively produces false confidence,
and each way it can happen is easy to introduce in isolation while "fixing"
something else:

- **Non-ASCII characters in a script's comments/strings can corrupt parsing
  on a platform that reads the file in the wrong encoding**, breaking a
  trailing pass/fail block in a way that reports a fully-passing run as a
  failure (a **false negative** — worse than a false positive, because it
  trains you to ignore the harness). If your shell/OS combination has known
  encoding quirks for script files without a BOM, keep those scripts
  plain-ASCII.
- **A fix to a harness's output-capture mechanism can silently break every
  *other* script that depends on reading that output**, in the exact same
  commit that fixed the original problem. If script A calls script B and
  inspects B's text output to find a verdict line, changing *how* B emits
  that output (e.g. switching between a console-only stream and a
  capturable one) needs A re-tested immediately, not assumed compatible.
- **When more than one legitimate output-format convention exists in the
  same project** (e.g. a directed testbench's own `RESULT: PASS/FAIL` line
  vs. a UVM environment's native report-phase summary), a verdict detector
  that only recognizes one convention will silently misjudge the other.
  **If the detector's fallback for "no recognized verdict" is anything
  other than FAIL, fix that first** — an unrecognized output shape must
  never be silently interpreted as success.
- **The test for all of the above is the same, one level up:** don't
  declare a harness fix correct until you've shown it can still correctly
  detect a **known-bad** input, not just that it now runs without erroring
  on a known-good one. Re-break something on purpose and confirm the
  harness catches it, every time you touch the harness itself.

### 3.10 Read the full compile/simulation transcript occasionally, not just the grep'd pass/fail line **[Universal]**

- A regression script that only ever checks for `PASS`/`FAIL`/`Errors: N`
  will never surface a `vopt`/elaboration **warning** about a genuinely
  missing port connection on a testbench-instantiated DUT — the simulation
  still runs and every *checked* signal can still pass, because nothing was
  ever asserted against the unconnected one. This can go unnoticed for many
  phases/commits, silently narrowing what a "passing" testbench actually
  covers, with zero functional symptom to notice.
- **Fix:** periodically read a full, unfiltered transcript (not the grepped
  summary) for testbenches that haven't been touched recently, specifically
  scanning for `vopt`/synthesis-frontend warnings about port connections,
  width mismatches, or unused signals — not just the final verdict line.

---

## 4. Hardware bring-up checklist

Run these **in order**. Each is a gate on the next. Do not skip ahead to
measuring performance.

### 4.1 Gate 0 — Reproducibility (do this first, always)

```
Run the SAME input through the hardware 4 times.
All 4 results MUST be bit-identical.
```

- If they are not, **stop.** Per-frame state is leaking (missing/ineffective
  soft reset), or timing is failing. Every performance number measured in this
  state is void.
- This check takes seconds and would have saved this project a 15-minute sweep
  that produced a confident, completely meaningless result
  (98.7% detection rate at a 94x-too-high false-alarm rate).
- **Note:** run this in a *fresh process* too — if even the first frame of a new
  process differs, the board is retaining state across process boundaries.
- **On an FPGA + soft-processor system, know exactly what your
  "restart"/"redownload" command actually resets before trusting a "clean
  slate" premise.** A soft-core CPU debug-download command (e.g.
  `nios2-download -g`) can restart *only the CPU itself* over its own debug
  channel, leaving every other peripheral's internal state — including
  sticky status/control flags — untouched across repeated downloads within
  the same FPGA configuration. A test whose premise depends on "nothing has
  happened yet" can then silently and repeatedly test a false premise, and
  simply re-running the test produces the *identical* failure — which is
  itself the signal the problem isn't test ordering or a one-off fluke, but
  a genuinely stale starting state. **Fix:** if a test needs a true
  "power-on" starting condition and your CPU-restart command doesn't
  guarantee one, force a full reconfiguration (reprogram the same,
  unchanged bitstream) instead — extend "fresh process" above to mean
  "fresh FPGA configuration," not just "fresh software process," on any
  board where the two are not the same operation.

### 4.2 Gate 1 — Correctness vs the software model

- Compare hardware output against the bit-exact reference model on both
  synthetic and real input.
- **Sweep the result-index offset** (e.g. −2..+3) before concluding "the values
  are wrong." A constant offset means a *shift* (an indexing bug), not bad
  arithmetic — a completely different fix. In this project the hardware's first
  emitted result was window index **1**, not 0, and misreading that as a value
  bug caused ~100% apparent mismatch.
- A near-zero match rate at *every* offset means a genuine value problem.
- Weak-but-nonzero correlation usually means something structural (wrong LUT,
  wrong scale), not noise.

### 4.3 Gate 2 — Only now, measure performance

- Only after Gates 0 and 1 pass should you run a full dataset sweep or benchmark.
- **Build the gate into the measurement script** so it physically cannot produce
  numbers from unverified hardware. Exit non-zero on gate failure.

### 4.4 When hardware and simulation disagree

Work down this list — cheapest and most likely first:

1. **Is it reproducible?** (§4.1) Non-reproducible ⇒ state leak or timing, not logic.
2. **Is the bitstream actually the one you think?** Check its build date and
   size. Check that your parameters really elaborated — read the value out of
   `output_files/*.map.rpt`, don't trust the source file.
3. **Does the host software assume registers this bitstream has?** Diff the RTL
   against the commit the bitstream was built from. *Undecoded Avalon writes are
   silent.*
4. **Is a result-index offset involved?** Sweep it.
5. **Is timing actually closed?** Read `*.sta.summary`.
6. **What does real hardware do that no testbench does?** (gaps, stalls,
   multiple frames, warm chip)
7. Only then suspect the RTL logic itself.

### 4.5 Calibrate the instrument before trusting the measurement

- When a debugging chain narrows to a single observation, **audit what that
  observation assumes** before building more instrumentation on top of it.
- In this project, three unverified board-level facts sat underneath a "the core
  is dead" theory — each individually capable of producing the symptom, each
  checkable in a two-minute build.
- The reflex to add more debug signals to the complex design was wrong.
  Building a tiny **known-good calibration design** (blink an LED, echo a
  register) to validate the measurement path was right.
- **A measurement that's suspiciously *too* consistent (zero variance
  across every trial and every input configuration) deserves the opposite
  scrutiny from an unstable one** — not "is the hardware unreliable" but
  "am I actually measuring the hardware, or the measurement apparatus." A
  software-side latency measurement that's a large, fixed multiple of the
  DUT's true latency and never varies is a strong signal you're measuring
  your own polling-loop/instrumentation overhead, not the thing under test.
  **A clean discriminating test:** if you can change the DUT's actual speed
  (e.g. double its clock frequency) and the measured number barely moves,
  the measurement was never dominated by the DUT in the first place — it
  was dominated by whatever sits between you and it (CPU instruction rate,
  bus round-trip, polling granularity).

### 4.6 Debug signal instrumentation

- Expose internal state as **real ports** (hierarchical references don't
  synthesize — §1.9).
- Make debug bits **sticky latches** (set once, held) so a human can see them on
  an LED without catching a nanosecond pulse.
- Include a **free-running heartbeat counter bit** that proves `clk`/`rstn` are
  alive independently of anything else working.
- Route them to spare LEDs via a Qsys conduit interface.

---

## 5. HPS / Linux integration (DE10-Standard specific)

- **Do not plan to run a modern Python stack on the stock image.** Angstrom
  v2014.12 has Python 2.7 only, no pip, ~51 MB free, and dead package feeds.
  Building Python 3 + numpy from source on a 925 MHz Cortex-A9 is not realistic.
  **Move the boundary, not the language:** write a small C daemon on the HPS that
  owns `/dev/mem`, and talk to it over TCP from a development machine.
- `mmap` `/dev/mem` at the lightweight bridge base (`0xFF200000`, span
  `0x200000`), then index your peripheral at its Qsys offset. Confirm the offset
  from `soc_system.sopcinfo`'s `<baseAddress>`, not from memory.
- **Blocking MMIO stores respect `avs_waitrequest` in hardware** — the ARM store
  instruction does not retire until the peripheral is ready. You do not need
  software polling to honor backpressure.
- **A read-to-clear status bit must be polled once per write, and results must be
  drained in a `while` loop, not sampled once.** Downstream pipeline stages keep
  advancing on their own valid chains, so several results can land between your
  writes. A single poll per write silently *drops* results — measured at 41 lost
  over one 512×512 frame. And a dropped result **shifts every subsequent result
  onto the wrong position**, which looks like a total value corruption rather
  than a missing sample.
- **Background processes:** plain `nohup … &` does **not** survive SSH session
  end on this board's shell. Use
  `setsid ./daemon > daemon.log 2>&1 < /dev/null &` then `disown`.
- **Verify a daemon is running from a *fresh* SSH connection** (`netstat -ltn`),
  not from the session that started it. Also note `pgrep -f <name>` can match
  its own command line and report a false positive.
- Streaming input must be sized to the **synthesis-time** frame dimensions. A
  narrower raw stream never completes a row and produces zero output — pad to
  the compiled size first.

---

## 6. Environment (WSL / Windows)

- `systemd=true` in `wsl.conf` **breaks Windows interop** — native `.exe`
  invocation from WSL fails entirely.
- `appendWindowsPath=true` breaks downstream tools when `PATH` contains spaces
  or dead drive letters.
- **Test the mechanism in isolation before blaming the tool.** "This tool
  crashes" and "this environment cannot launch native tools at all" look
  identical from one failed invocation. `cmd.exe /c echo hello` separates them
  in one cheap check.
- **Do not bundle a speculative "probably helps" setting change with a confirmed
  necessary one.** Doing so here cost a full extra debugging round-trip.
- **PowerShell output buffering:** `quartus_map … | tail -N` yields nothing until
  the whole pipeline closes. Redirect to a plain log file (`> build.log 2>&1`)
  and `grep`/`cat` it at any time instead.
- **Backgrounding:** don't nest `nohup … &` inside an already-backgrounded call —
  the outer command returns instantly and the real work becomes untracked.
- **A native Windows console tool backgrounded from Git Bash (`tool.exe &`,
  output redirected with `>`) can silently produce zero captured output
  while the tool itself is working perfectly** — a known class of quirk
  mixing a POSIX-emulation shell with native Windows console-subsystem
  binaries (a JTAG terminal utility is a concrete real example). **Before
  concluding the target/design is broken, verify the capture mechanism
  itself:** switch to PowerShell's `Start-Process -RedirectStandardOutput`,
  or attach a debugger/register-level probe directly to confirm the actual
  target state independent of the log-capture path. `kill $!`/`kill <pid>`
  from Git Bash also does not reliably terminate a native `.exe` launched
  via `&` — use `taskkill //F //IM <name>.exe` instead, and rule out a
  stale leftover process explicitly before trusting a "fresh" capture.

---

## 7. Process rules

### 7.1 Provenance

- **Version-control everything a synthesis step reads**, including generated
  data files (`.hex` ROM images, coefficient tables). A file living outside the
  repo that `$readmemh` bakes into the bitstream is a silent external dependency:
  your source can be perfectly reverted while the flashed binary still reflects
  whatever was in that directory when it was built — and nothing records that.
- **Archive build inputs and outputs together per release**, or at minimum
  record the commit hash and the checksum of every generated input.
- **Reverting source to "match" a saved bitstream matches only what the source
  says, never what the binary contains.** When in doubt, rebuild.

### 7.2 Investigation

- **Two crashes with an identical low-level error signature are the same bug
  until proven otherwise**, even when surface symptoms look unrelated. Match the
  exact file/line/stack trace, not just "another crash."
- **A reproducible crash is a lead, not automatically the blocker.** Ask what
  the crashing step actually *produces* and whether anything downstream needs
  it. In this project the real bug sat one layer away from where every error
  message pointed.
- **Investigate why an assertion exists before routing around it.** A library's
  "input must be odd" check was pointing at a genuine structural property of the
  hardware, and understanding it turned a chore into a real improvement.
- **A coincidental partial match under an incorrect theory is a red herring.**
  Correct the theory mid-investigation rather than accepting the partial match.
- **Record wrong hypotheses and how they were disproven**, not just the final
  answer. The reasoning that eliminated a plausible-but-wrong explanation is
  often more reusable than the fix.

### 7.3 Documentation

Keep a numbered bug log with a fixed structure — it compounds in value:

```
### N. One-line title naming the actual root cause

**Symptom:**       what was observed, with real numbers
**Root cause:**    the mechanism, verified not assumed
**Fix:**           what changed
**Lesson:**        the transferable, generalizable rule
```

- Include the **exact numbers** (slack values, resource counts, match
  percentages, error signatures). They make a recurrence instantly
  recognizable.
- Note explicitly when a workaround **must be re-applied** after a regeneration
  step, rather than marking it "fixed."

---

## 8. Pre-flight checklist (condensed)

**While writing RTL**
- [ ] No clocked `always` block chains several multiplies/divides between one
      pair of registers (§1.10) — budget ~one big operation per stage
- [ ] No intermediate declared wider than its real range
- [ ] No reduction tree stacked on another reduction tree in one cycle
- [ ] Every interface signal in hand-rolled BFMs driven with `<=`, not `=` (§3.6)
- [ ] No runtime index into an interface instance array — genvar-extract to a
      plain array first (§1.12)
- [ ] Any B/R (or equivalent) response router re-checked for >1-outstanding
      contention if outstanding depth or slave count can exceed 1 (§1.14)
- [ ] Every UVM driver wait loop qualified on `rst_n`, with a re-idle path (§3.7)
- [ ] Any task that must drive a signal *during* execution (not just report a
      final value) uses `ref`, not `inout` (§1.15)
- [ ] Any free-running real-world-scale counter (POR, watchdog, timeout) has a
      testbench-overridable width parameter (§1.16)
- [ ] Any cross-file SVA `bind` compiled with the merged-compilation-unit
      flags your simulator needs, and confirmed to actually elaborate by
      breaking the property once and checking the fault fires (§3.8)

**Before synthesis**
- [ ] Parameters changed in *every* duplicated location (RTL, `_hw.tcl`, `.qsys`,
      generated `.v`, software config, all test/reference generators)
- [ ] Golden vectors regenerated for the new configuration
- [ ] Full simulation regression passes
- [ ] Value-level check passes at the **real production** parameters, not just a
      small test configuration
- [ ] No hierarchical references in synthesizable code
- [ ] No inline `genvar` in a `for` header, no `localparam` in a module's
      `#(...)` port list (§1.9) — Questa-legal, Quartus-fatal
- [ ] If your regression harness itself changed recently, re-confirmed it
      still correctly reports FAIL on a deliberately broken input, not just
      PASS on a good one (§3.9)

**After synthesis (`quartus_map`)**
- [ ] 0 errors, no `Internal Error`
- [ ] Parameters confirmed **from `*.map.rpt`**, not from the source file
- [ ] Memory bits look plausible (not near-zero for something that is memory)
- [ ] Any memory whose read port is currently unread by anything real still
      shows up as inferred RAM, not silently deleted (§1.1) — add a debug
      readback port if needed
- [ ] DSP / resource counts in line with expectations
- [ ] Nios II (or other soft core) instruction master connected to program
      memory + debug module, mirroring every data-master connection (§2.5)

**After fit + `quartus_sta`** ← *never skip*
- [ ] Positive setup slack on the **slow, hot** corner
- [ ] TNS ≈ 0
- [ ] Resource usage within budget
- [ ] If a PLL was added, `derive_pll_clocks` was called, and the new
      domain's clock name actually appears in the slack tables — not just a
      clean overall exit code (§2.2, §2.6)
- [ ] If a PLL was added, its `locked` output either gates the reset of what
      it clocks, or that choice not to is a deliberate, documented one (§2.6)

**Before flashing**
- [ ] `.rbf` built **with compression**
- [ ] `.rbf` size sane vs last known-good
- [ ] Previous working `.rbf` backed up
- [ ] Bitstream and host software built from the **same source revision**
- [ ] If programming over JTAG directly, the device index (`@N`) is
      confirmed against `jtagconfig`'s scan — never the bare default on a
      Cyclone V SoC's two-tap chain (§2.4a)

**After flashing**
- [ ] Gate 0: 4 identical runs → bit-identical output
- [ ] Gate 0, extended: if using a soft core, confirm what your
      redownload/restart command actually resets — a full reconfigure if it
      doesn't reset peripheral state (§4.1)
- [ ] Gate 1: matches the software model (with offset sweep)
- [ ] Only then: measure performance
- [ ] If a performance number looks suspiciously too-consistent, checked
      whether it moves when the DUT's actual speed changes, before trusting
      it as a DUT measurement (§4.5)

---

## 9. Prompt snippet for a new session

> This project targets a Terasic DE10-Standard (Cyclone V `5CSXFC6D6F31C6`,
> 41,910 ALMs, 112 DSP) with Quartus Prime Lite 21.1, Icarus Verilog for
> simulation, and an HPS running an old Angstrom Linux (Python 2.7 only).
> Follow `fpga_checklist.md` in this repo. In particular:
> never infer RAM inline in a `generate for` body; never use hierarchical
> references in synthesizable code; always run `quartus_sta` and read the actual
> slack before flashing — AND, if a PLL is involved, confirm `derive_pll_clocks`
> was called and that the PLL's clock name actually appears in the slack tables,
> since a clean exit code alone does not prove the domain was analyzed at all;
> always verify hardware reproducibility (same input → bit-identical output)
> before trusting any measurement, including confirming exactly what your
> soft-core restart/redownload command does and doesn't reset; never pair a
> saved bitstream with newer host software; when programming over JTAG directly
> on a Cyclone V SoC, always target the FPGA fabric's explicit device index
> (`@N`), never the bare default. Verify claims against real evidence — tool
> output, measured numbers — rather than asserting them; verify your own
> regression harness against a known-bad input the same way you verify the DUT;
> and keep a numbered bug log with Symptom / Root cause / Fix / Lesson for each
> issue found.
