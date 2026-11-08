# The kernel's calls: capabilities and IPC

`INT 31h` (`KCALL_VECTOR`), an interrupt gate of DPL 3, is the kernel's
only interface (roadmap l4.md L3-L5, L10, D20): calls on capabilities, IPC
between threads, the timer, the ticks and the log. The system calls are the
OS server's (*docs/syscalls.md*); `INT 30h`, theirs until L10, faults like
any vector of the kernel's. `src/include/kcalls.inc` holds the numbers, the
types and the macro `kcall`:

```nasm
        mov dx, UT_MEMORY               ; an untyped capability
        mov al, CAP_SEGMENT
        mov si, MY_SLOT3                ; an empty slot of the caller's
        mov cx, 256
        mov bl, 0xF2                    ; present, DPL 3, data, writable
        kcall KCALL_RETYPE              ; mov ah, KCALL_RETYPE / int 31h
        jc .refused                     ; AL = KE_*
```

## Capabilities

A thread holds capabilities in the slots of its space, and names each by
its selector: slot n is n × 8 + 4 + its ring. A space is an LDT and a shadow
entry for each slot, an object of the kernel's (*docs/memory-map.md*),
which no program can reach.

- **A segment capability is its descriptor.** The program loads it into DS
  or ES, and the CPU checks every access to it.
- **Every other capability is a descriptor of all zeros:** not present, DPL
  0, no valid type. Ring 3 can neither load it (#GP) nor learn anything of
  it with `LAR`, `LSL`, `VERR` or `VERW`; the shadow entry says what it is.

| Type | Constant | What it names |
|---|---|---|
| 0 | `CAP_EMPTY` | nothing: an empty slot |
| 1 | `CAP_SEGMENT` | memory, as a segment (data; code only from the kernel's image) |
| 2 | `CAP_UNTYPED` | memory not yet made into anything: the arena's, or the memory for segments; either makes objects and segments alike |
| 3 | `CAP_THREAD` | a thread |
| 4 | `CAP_SPACE` | a space: an LDT and its slots |
| 5 | `CAP_ENDPOINT` | an endpoint, with a badge and rights (*IPC*, below) |
| 6 | `CAP_NOTIFY` | a notification, with a badge and rights |
| 7 | `CAP_IRQ` | an interrupt line (roadmap l4.md L7) |
| 8 | `CAP_REPLY` | a reply owed, saved by `KCALL_SAVE_REPLY`: sent on once |

An endpoint's or notification's capability carries rights: `RIGHT_SEND`
(call, send, signal, arm a timer), `RIGHT_RECV` (receive, poll, bind) and,
for an endpoint, `RIGHT_GRANT` (its messages may pass a capability).
Retype gives `RIGHTS_ALL`; mint can take rights away, never add them.

A selector that is not an LDT selector of the caller's space, or names a
slot past its end, names no capability: `KE_CAP`, as does a slot of the
wrong type. The GDT holds nothing a program could name.

## The calls

AH is the call. The status comes back in AL, with CF set on an error;
`KCALL_SEGMENT`, `KCALL_LOG` and `KCALL_TICKS` return data in AX, so their
status is CF alone (and AX the error), and a receive returns the message's
label in AL with CF clear. `KCALL_COUNT` is
the number of calls; the ones not listed answer `KE_NOSYS` until their
milestone.

| AH | Constant | In | Out |
|---|---|---|---|
| 1 | `KCALL_CALL` | DX an endpoint; AL the label; BX CX SI DI; BP a capability to pass, or 0 | AL the status; BX CX SI DI the reply |
| 2 | `KCALL_REPLY_RECV` | BX CX SI DI the reply owed; then as `KCALL_RECV` | as `KCALL_RECV` |
| 3 | `KCALL_RECV` | DX an endpoint or a notification; BP an empty slot of the caller's for a capability, or 0 | AL the label, DX the sender's badge, BX CX SI DI, BP the capability received, or 0; a notification: BX its bits |
| 4 | `KCALL_SEND` | as `KCALL_CALL`; or DX a saved reply and BX CX SI DI the reply (`KCALL_CALL` on a saved reply is `KE_CAP`) | AL the status |
| 5 | `KCALL_SIGNAL` | DX a notification | |
| 6 | `KCALL_POLL` | as `KCALL_RECV` | as `KCALL_RECV`, or `KE_EMPTY` at once |
| 7 | `KCALL_RETYPE` | DX untyped; AL the type; SI an empty slot of the caller's; a segment: CX bytes (1-65535) and BL its access byte; a space: CX slots; untyped: CX paragraphs | the object made, zeroed, its capability in the slot |
| 8 | `KCALL_COPY` | DX a space the caller holds; SI a slot of the caller's; DI an empty slot of that space; AL `COPY_COPY`, `COPY_MOVE` or `COPY_MINT`; a mint: BX the badge, CL the rights it keeps (`RIGHT_*`; 0: all) | the capability there |
| 9 | `KCALL_THREAD` | DX a thread; AL `THREAD_CONFIGURE` (SI its space, BX its entry, CX its stack's top), `THREAD_START` (CL its priority, 0 to `PRIORITY_MAX`; CH `START_*`), `THREAD_BIND` (SI a notification), `THREAD_FAULT` (SI an endpoint), `THREAD_RESTART`, `THREAD_STOP`, `THREAD_INFO`, `THREAD_SUSPEND` (SI a notification, or 0) or `THREAD_FRAME` (BL `FRAME_READ` or `FRAME_WRITE`; SI:DI `TFR_SIZE` bytes of the caller's) | `THREAD_INFO`: BL its state (`STATE_*`), BH its priority, CX how often it ran |
| 10 | `KCALL_IRQ` | DX an interrupt line; AL `IRQ_BIND` (SI a notification) or `IRQ_ACK` | the line unmasked |
| 11 | `KCALL_TIMER` | DX a notification; CX ticks, 1 to 7FFFh (`KE_ARG` otherwise) | |
| 12 | `KCALL_SEGMENT` | DX a segment | DL:AX its physical base, CX its limit (for DMA) |
| 13 | `KCALL_DELETE` | DX a slot of the caller's, not empty | the slot empty |
| 14 | `KCALL_SAVE_REPLY` | SI an empty slot of the caller's | the reply owed, as a `CAP_REPLY` there |
| 15 | `KCALL_REVOKE` | DX a slot of the caller's, not empty | every capability derived from it deleted, in every space; an untyped's memory free again |
| 16 | `KCALL_TEST` | debug and test builds: AL `TEST_*` (*In test builds*, below) | |
| 17 | `KCALL_LOG` | DS:SI bytes, CX how many (`LOG_MAX` at most) | AX the bytes written to the kernel's log (fewer if the thread is to restart); or `KE_ARG`, `KE_CAP` (a buffer the caller may not read) |
| 18 | `KCALL_TICKS` | | DX:AX the ticks since the start, `TICKS_HZ` (50) a second |
| 19 | `KCALL_SEAL` | DX a data segment of DPL 3, retyped from untyped, with no other capability to it | the segment readable code of DPL 3 (*Code from data*, below) |
| 20 | `KCALL_RESIZE` | DX a data segment retyped from an untyped of the caller's, the last thing carved there; CX bytes, 1 to 65,535 | it and every copy of it so long, in place, new bytes zeroed (*A segment in place*, below) |

### Retype

Retype makes an object from untyped memory, at the untyped's next
paragraph (`retype_place`, `src/lib/caps.asm`), and zeroes it. Every
object is aligned to a paragraph alone, so no room is skipped, and an
untyped keeps no hole (roadmap l4.md L10's; os-server.md P15). A segment of more than 2 KB is zeroed 2 KB at a time
with an interrupt window between (about 0.8 ms each on an AT; roadmap
os-server.md P2): a 64 KB retype no longer keeps interrupts off for 27 ms,
and the call checks afterwards that its slot, its untyped and its space
are still as they were (`KE_STATE` if not).

- **Kernel objects** - spaces, threads, endpoints, notifications - from any
  untyped (roadmap os-server.md P3). Each takes a descriptor of the GDT's
  pool, and a space a second for its LDT; the kernel lists 128 spaces
  (`SPACE_MAX`) and 192 threads (`THREAD_MAX`) at most: `KE_POOL` past any
  of these.
- **Segments** from any untyped, and only data: present, of DPL 1-3. Code
  comes from the boot image, or from data sealed (`KCALL_SEAL`, below),
  never otherwise (roadmap l4.md X14). An untyped's watermark gives no
  memory twice, so a segment never lies over an object.
- **Untyped** from untyped, of so many paragraphs: memory of its own, which
  a revoke of it gives back whole (roadmap l4.md L12). The root's
  allocator carves the processes' memory of it (roadmap os-server.md P4).
- **The new capability is a child** of the untyped it came from, so
  revoking the untyped deletes it.
- **A space** has `SPACE_SLOTS_MIN` to `SPACE_SLOTS_MAX` slots, a power of
  two.

### Copy, move and mint

- **Copy** puts a second capability to the same thing in the slot; **move**
  empties the source; **mint** copies an endpoint or a notification that has
  no badge yet with a badge, which can never be changed, and with fewer
  rights if CL names them. Untyped memory and a saved reply are moved,
  never copied (`KE_ARG`), and a message may not grant them (they are left
  out of it): two retypes of the same untyped would carve the same memory,
  and a reply is answered once (roadmap l4.md L13).
- **A copy is a child of its source:** first in the source's ring of
  children, for revocation (roadmap l4.md L12; os-server.md D9). A move
  takes the capability's place in its parent's ring, and its children,
  with it, at once: only its neighbours and its first child are told
  (os-server.md P15).
- **A segment moved away is gone at once** for the caller: a DS or ES still
  holding it is made null on the way back to ring 3 (*docs/interrupts.md*).

### Threads

A thread made by retype is configured, then started:

- **Configure** gives it a space whose slots 0, 1 and 2 are its program's
  code, data and stack, an entry and a stack's top. Slot 0 must be code,
  not conforming; its DPL is the thread's ring (never 0).
- **Start** puts it in the scheduler at a priority. `START_IOPL` asks for
  IOPL 1, which goes only to a thread of ring 1 (roadmap l4.md D11);
  `START_FOREGROUND` marks it as the program the keys are for, which only
  a thread of ring 1 or 2 may say. Since the keyboard left the kernel
  (l4.md L8) the mark serves only the kernel's test hooks, which follow
  that program; the keys and Ctrl+Break are the keyboard driver's and the
  OS server's (*docs/os-server.md*).
- A thread is configured and started once: `KE_STATE` after that.
- **Bind** ties it to a notification it may receive on, in any state: one
  each, so binding again unbinds the old.
- **Fault** gives it a fault endpoint, one it may send on, in any state
  (*Faults*, below).
- **Restart** (`THREAD_RESTART`) starts a started thread's program again
  at its entry, as Ctrl+Break does: the OS server's way to end a program
  the root builds that calls `PX_EXIT` (*docs/syscalls.md*). A thread waiting for the reply
  of a server's thread started with `START_SESSION` - one that serves it
  alone, from rings 1-2 only - takes that thread with it, so that a wait in
  the kernel on its behalf is given up too.

### Code from data

`KCALL_SEAL` (roadmap os-server.md P2, D6) turns a data segment into code,
for a program loaded from a disk: the root reads the file into a segment
it made, revokes it to prove no alias is left, and seals it. The segment
must be data of DPL 3, expand-up, present; a direct child of the untyped
it came from; and without a child, so that no other capability to it
lives (`KE_STATE`). It becomes readable code of DPL 3, non-conforming, at
the same selector: a write through it faults from then on, and the root
moves it into the program's slot 0. A segment of any other DPL, code, an
endpoint, a segment sealed already: `KE_ARG`, `KE_CAP` or `KE_STATE`.

### A segment in place

`KCALL_RESIZE` (roadmap os-server.md P15) makes a data segment longer or
shorter without moving it, so that a process's heap grows without a copy
and without new capabilities: the root's `ROOT_BRK` uses it while the
process's block has room. The segment must be data, expand-up, a direct
child of an untyped in the caller's own space - a segment moved to another
space takes no more of its untyped's memory - and the last thing carved
there, its end the untyped's watermark (`KE_STATE` otherwise; `KE_ARG`
for code, `KE_MEM` past the untyped). A longer segment's new paragraphs
are carved first, so that nothing else takes them, then zeroed 2 KB at a
time with windows, as a retype's are; afterwards the call checks that the
segment and its untyped are as they were (`KE_STATE` if not; a revoke of
the untyped meanwhile cancels the zeroing). A shorter one gives its end
back to the untyped. Every capability derived from the segment - its
copies, and theirs - gets the new limit, in a walk of its children with
an interrupt window every `CHILDREN_WINDOW` (16), where no thread gives
way. A thread that holds a copy in a segment register loads it again on
its way back to its ring, as after every kernel entry, so it sees the new
limit; a kernel call that reads a caller's buffer across windows checks it
again after each (`recheck_buffer`).

### Suspending a thread

The OS server delivers a signal to a thread in ring 3 by stopping it with
its registers kept, writing its frame, and resuming it (roadmap os-server.md
E6, D7):

- **`THREAD_SUSPEND`** marks a thread of ring 3, not the caller, to stop on
  its way back to its ring, as a restart does: any kernel call it is in
  ends first, its results in its frame and the log's turn given up (E11).
  Once it has stopped (`STATE_STOPPED`), the notification SI named is
  signalled with its capability's badge (1 if none). A thread waiting for
  its fault's reply stops at once instead, its wait ended and its registers
  as they were at the fault; the handler's reply then finds nobody
  (`KE_STATE`). A thread stopped, free or marked already: `KE_STATE`;
  but one marked that faulted before it stopped, and so waits for its
  fault's reply, stops at once at the fault, for the notification first
  named (roadmap os-server.md P10).
- **`THREAD_FRAME`** reads or writes a suspended thread's whole frame,
  `TFR_SIZE` bytes at SI:DI of the caller's, checked as `KCALL_LOG` checks
  its buffer (`KE_CAP`): ES, DS, `PUSHA`'s eight words, the vector and
  error code (not written), IP, CS, FLAGS, SP and SS (`TFR_*`). A write
  keeps the thread's IOPL and IF, clears NT, and makes the RPL of CS and
  SS the thread's ring; the way back checks every selector, as for any
  frame. A write to a thread stopped in a kernel call half done gives the
  call up: the thread goes back with the frame written. A thread not yet
  stopped: `KE_STATE` (os-server.md P15).
- **`THREAD_START`** resumes a suspended thread where it was, at the
  priority given.
- **`THREAD_FPU`** gives a thread that has not started, or is stopped,
  the 287 state of the thread SI names: its saved state, or the 287's own
  if that thread owns it (saved and restored at once, so that it owns it
  still). The thread's first start keeps it, where a start resets the 287
  otherwise (os-server.md P15: a fork's child, XSH fork).

| Offset | Constant | | Offset | Constant | |
|---|---|---|---|---|---|
| 0 | `TFR_ES` | | 18 | `TFR_AX` | |
| 2 | `TFR_DS` | | 20 | `TFR_VECTOR` | the kernel's: not written |
| 4 | `TFR_DI` | `PUSHA`'s words | 22 | `TFR_ERROR` | likewise |
| 6 | `TFR_SI` | | 24 | `TFR_IP` | |
| 8 | `TFR_BP` | | 26 | `TFR_CS` | |
| 10 | `TFR_SP_POPA` | `PUSHA`'s copy of SP, which `POPA` skips | 28 | `TFR_FLAGS` | |
| 12 | `TFR_BX` | | 30 | `TFR_SP` | the thread's SP |
| 14 | `TFR_DX` | | 32 | `TFR_SS` | |
| 16 | `TFR_CX` | | 34 | `TFR_SIZE` | the frame's bytes |

## IPC

IPC is synchronous and copies nothing but registers (roadmap l4.md D5). A
message is a label (AL, 0 to FEh), four words (BX, CX, SI, DI) and at most
one capability; larger data goes through a segment the two threads share.

- **An endpoint** has a queue of senders, or of receivers. Whoever comes
  second does the transfer: a receive takes the first sender's message, a
  send gives its message to the first receiver. Neither has a timeout
  (D6): a thread waits until the other comes, or until it is restarted
  (Ctrl+Break, a 287 error), which wakes it with `KE_STATE`.
- **The badge** of the sender's capability arrives in DX: a server minted
  a capability with a badge for each client (`COPY_MINT`) and knows who
  calls. A capability without a badge sends 0.
- **A call** waits for its reply. The receiver now owes the caller one: a
  link in its control block, which `KCALL_REPLY_RECV` answers before it
  receives again. A server that must wait for something else first saves
  the link into a slot (`KCALL_SAVE_REPLY`) and answers later with
  `KCALL_SEND` on it, which empties the slot. A reply the caller no longer
  waits for (it was restarted) is `KE_STATE`; a server restarted, or
  linked to a new call before it answered, leaves its caller `KE_STATE`
  too.
- **A capability** goes with a message when the sender's BP names one and
  the endpoint has `RIGHT_GRANT` (else `KE_ARG`). It is copied into the
  slot the receiver's BP named, if that slot is empty; if not, the message
  arrives without it, as BP = 0 (seL4's rule). A server deletes what it
  received when it has done with it (`KCALL_DELETE`), so that its slot can
  take the next one.
- **The direct switch:** a call or reply that wakes a thread at least as
  urgent as the running one puts it first in its queue, so it runs as soon
  as the running thread waits; a less urgent one waits its turn. A server
  below its client therefore makes the client wait for every thread
  between them (`tests/ipc` measures it): servers should run above their
  clients.

### Notifications

A notification is a word of bits, for events and interrupts:

- `KCALL_SIGNAL` ORs the capability's badge (1 if it has none) into it,
  and never waits. `KCALL_RECV` on it returns the bits in BX and clears
  them, or waits for a signal; one thread at a time may wait
  (`KE_STATE`). `KCALL_POLL` returns `KE_EMPTY` instead of waiting.
- **Bound** to a thread (`THREAD_BIND`), a signal also reaches it while it
  waits on an endpoint: the receive returns with AL = `NOTIFY_LABEL`, BX
  the bits, DX and BP 0. No sender may use that label (`KE_ARG`).

### The kernel's timer

`KCALL_TIMER` signals a notification once, CX ticks from now (50 a second,
*docs/syscalls.md*), with the capability's badge. It is the kernel's answer
to timeouts: a driver waits on one notification, bound or not, for its
interrupt or its timer, whichever comes first. A notification has one
timer at most: arming it again replaces the one armed, so a wait's timer
left behind cannot use the kernel's up (roadmap l4.md L9). 48
notifications (`TIMER_MAX`) can have a timer armed at once across the
system: `KE_POOL` after that. Every thread of the OS server's arms one while
it waits for the server's lock, a tick at a time: with sixteen, the waits of
more than sixteen threads at once found none and slept for ever (roadmap
memory.md M1). A timer is at most 7FFFh ticks away, about
11 minutes.

### Stopping a thread

`THREAD_STOP` (roadmap l4.md L11) takes a thread, not the caller, off every
queue: a wait in IPC is given up as a restart gives it up, the server of
its session starts again, and its turn at the log is given up. Its state is
`STATE_STOPPED` until `THREAD_START` starts it again, at the priority given:
it goes on from where it stopped inside the kernel, and its way back starts
its program at its entry. A thread stopped already, or not started, is
`KE_STATE`. `THREAD_INFO` says a thread's state:

| State | Constant | |
|---|---|---|
| 0 | `STATE_FREE` | not started |
| 1 | `STATE_READY` | in its ready queue |
| 2 | `STATE_RUNNING` | the caller, when it asks of itself |
| 3 | `STATE_WAITING` | inside the kernel, for its turn at the log |
| 4 | `STATE_SENDING` | queued on an endpoint, to send or call |
| 5 | `STATE_RECEIVING` | queued on an endpoint, to receive |
| 6 | `STATE_REPLY` | awaiting its call's reply |
| 7 | `STATE_NOTIFY` | awaiting a notification |
| 8 | `STATE_STOPPED` | stopped |

### The log and the ticks

`KCALL_LOG` writes bytes to the kernel's log (roadmap l4.md L10, D15): COM2
in debug and test builds (COM3 when COM2 is the modem), which every test
reads; and the screen, until the threads start. The OS server writes the
first terminal's output and the writes of the programs the root builds
there, before the console driver writes the screen; the root, the drivers
and the test programs' workers write their own lines. The buffer is
checked with the 286's own instructions at the caller's privilege: `ARPL`
against the caller's CS, `VERR`, `LAR`'s present bit (no expand-down
segment), `LSL` and bounds; and again after every
interrupt window: interrupts come in after each byte, and a thread more
urgent may run. One thread's line at a time: a thread that finds another
writing waits its turn, so lines never mix. `KCALL_TICKS` gives the
timer's count, 50 a second, 32 bits.

### Faults

A thread with a fault endpoint does not fault alone (roadmap l4.md D18):
its fault - an exception of its own, or a frame the way back to its ring
refuses - is a call on that endpoint, with the badge of the capability it
was given. The label is the vector; BX the error code (0 if none); CX:SI
the CS:IP; DI `FAULT_COUNTED` if a test build counted the fault already
(the fuzzer), which the handler then does not report. The thread waits
for the reply, and the reply restarts it at the IP in its BX, with fresh
registers and a fresh stack; until one comes it waits, or a
`THREAD_SUSPEND` stops it as it was. A thread without a fault endpoint is
reported and restarted by the kernel, as before.

### Interrupt lines

A `CAP_IRQ` names an interrupt line (roadmap l4.md L7, D10). `IRQ_BIND`
binds it to a notification the caller may send on: from then on each
interrupt of the line masks it, is acknowledged at the 8259A, and signals
the notification with that capability's badge (1 if none). `IRQ_ACK`, once
the driver has served the device, unmasks the line; an interrupt that came
meanwhile waits in the 8259A. *docs/drivers.md* shows how the drivers use
them.

### Delete and revoke

The capabilities form a tree: each has a parent, the slot it was copied,
minted or granted from, or the untyped it was retyped from, and each keeps
its children in a ring, linked both ways through their shadow entries, as
seL4 keeps its derivation tree (`src/kernel/revoke.asm`; roadmap l4.md
L12, D8; os-server.md D9). Only the first of a ring names the parent; the
others find it back along the ring (os-server.md P15). Every kernel object
counts the capabilities to it. Nothing looks through every slot of every
space any more, nor through a capability's children: a delete's time grows
with neither.

- **`KCALL_DELETE`** empties a slot of the caller's. Its children take its
  place in its parent's ring, at once, so the tree holds: only the first
  of them is told (a capability with no parent: its children have none
  either, each told, with an interrupt window every 16). A segment deleted while DS or ES holds it is gone at
  once, as for a move: the way back makes the register null.
- **The last capability to an object** (its count 0) takes the object with
  it:
  - an endpoint: every thread queued on it, to send or to receive, fails
    with `KE_CAP`, and no thread's faults go to it any more;
  - a notification: the thread waiting on it fails with `KE_CAP`; its
    thread and its interrupt lines are unbound (the lines masked), and its
    timer stops;
  - a thread: it stops for good, every link naming it - a reply owed to it,
    a reply it owes, the saved reply owed to it (which its control block
    names; a reply saved again for the same caller makes the older one owed
    to nobody, `KE_STATE`) - is cleared, a thread awaiting its reply fails
    with `KE_CAP`; the running thread dies at its way back;
  - a space: its threads stop and lose it (they may be configured again),
    its slots are emptied in turn - which may take more objects with them -
    and its LDT's descriptor goes back to the pool once no thread names it;
  - an interrupt line: unbound.
  Segments and untyped are memory: nothing dies with them.
- **`KCALL_REVOKE`** deletes every capability below a slot, in every space,
  and keeps the slot's own: the slot's first child, whose own children
  become the slot's first, until it has none. Revoking untyped deletes
  everything made from it, so none of its memory is used any more: its
  watermark goes back to 0, and the next retype uses it again,
  zeroed. (The root's untyped in slots 3 and 4 begin past what the kernel
  made for the root itself, which is no child of theirs.) Interrupts are
  open after each capability it deletes, and other threads may run there.
  A thread that is to restart meanwhile gives the revoke up, partly done,
  and may call it again (roadmap l4.md L13); one suspended meanwhile stops
  once the revoke has ended. If the slot is emptied, or holds another
  capability, when the revoke comes back from a window, it ends with
  `KE_STATE`. Before an untyped's memory is free again, every dead space
  still to be emptied is emptied and released, and a retype still zeroing
  in that memory is given up (`KE_STATE`): nothing of the memory is
  written after it is given back (os-server.md P15). A thread whose last
  capability, or whose space, went while it ran ends at its call's next
  window rather than give way there.

## Errors

| Code | Constant | Meaning |
|---|---|---|
| 0 | `KE_OK` | done |
| 1 | `KE_CAP` | not a capability of the type the call needs |
| 2 | `KE_ARG` | an argument out of range |
| 3 | `KE_MEM` | the untyped memory has no room left |
| 4 | `KE_SLOT` | the destination slot is not empty |
| 5 | `KE_POOL` | no descriptor left in the kernel's pools |
| 6 | `KE_STATE` | not in that state: a thread started twice; no reply owed; a wait ended by a restart |
| 7 | `KE_NOSYS` | no such call |
| 8 | `KE_EMPTY` | `KCALL_POLL`: nothing there |

## The root's capabilities

The kernel builds the root from the boot image's first module, in ring 2,
and gives it everything (roadmap l4.md L5; *docs/memory-map.md*). Its space
has `ROOT_SLOTS` slots:

| Slot | Constant | What |
|---|---|---|
| 0, 1, 2 | | its code, its data (initialised from its module) and its stack |
| 3 | `ROOT_SLOT_UNTYPED` | the memory for programs, as untyped: what its data and stack left; with extended memory, three quarters of that, up to 1 MB (roadmap os-server.md P3) |
| 4 | `ROOT_SLOT_ARENA` | the arena, as untyped: what its space and thread left; with extended memory, the rest of it, up to 1 MB |
| 5 | `ROOT_SLOT_MODULES` | the module table, read-only |
| 6 | `ROOT_SLOT_SPACE` | its own space |
| 7 | `ROOT_SLOT_THREAD` | its own thread |
| 8 on | `ROOT_SLOT_MODULE` | for module n (n from 1): its code, as a segment of the module's ring, at 8 + 2 (n - 1); its data as assembled, read-only, in the next |
| 100 | `ROOT_SLOT_LOW_UNTYPED` | with extended memory: the memory for programs below 1 MB, what its data and stack left |
| 101 | `ROOT_SLOT_LOW_ARENA` | with extended memory: the arena, what its space and thread left |
| 111 | `ROOT_SLOT_VIDEO` | the screen's text page, a segment of DPL 1, for the console driver |
| 112-127 | `ROOT_SLOT_IRQ` | interrupt line n at 112 + n: every line the kernel does not keep (*docs/interrupts.md*) |

The rest are the root's own (*docs/root.md*): its fault endpoint (36), a
scratch slot (37), the OS server's control notification (110), from 128 on
eight slots for each
module it builds (roadmap l4.md L10, L12), and from `ROOT_SLOT_DYNAMIC`
(256) to 511 the slots its services make and give back (roadmap
os-server.md P4).

The root (`src/root/root.c`; in C since roadmap os-server.md P4) builds a
space for every other module: the module's code copied in as slot 0; a
data segment of its room, initialised from its data, as slot 1; a stack as
slot 2. The OS server's module ("os") gets a space of 512 slots and a
thread for each program, which serves it alone (`START_SESSION`), with the
program's capabilities in slots 8n to 8n + 5 (*docs/os-server.md*), and
in slot 128 + n a notification the thread sleeps on, a tick at a time or,
the foreground program's, until the keyboard driver signals. A
driver (`MF_DRIVER`) gets a space of `DRV_SLOTS` slots, a thread with
IOPL, an endpoint, a notification and its interrupt line
(*docs/drivers.md*). Every other module is a program: a thread and an
endpoint to the OS server, and its faults go to the OS server. The root starts each at the priority the table gives, the
program the keys are for with `START_FOREGROUND`. Then it handles the OS
server's faults: it reports each as the kernel did ("rx286: os fault
#GP(0000) at 0006:0123", the module's name for "program"), copies back any
of the three slots the module emptied, and replies with the module's
entry.

## In test builds

`KCALL_TEST` holds the hooks of debug and test builds; release builds
answer `KE_NOSYS`:

| AL | Constant | What |
|---|---|---|
| 0 | `TEST_MOUSE_BYTE` | test builds: BL the next byte a key script gave the mouse, its IRQ4 signalled; or `KE_EMPTY` |
| 1 | `TEST_KEY_BYTE` | test builds: BL the next key a script typed where the 8042 cannot take it (MAME), IRQ1 signalled; or `KE_EMPTY` |
| 2 | `TEST_READER` | test builds: BL `TEST_READER_NONE`, `TEST_READER_TIMED` or `TEST_READER_FOREVER`: whether the OS server waits for a key, having found none, and for how long. The script types while one waits, and ends once one waits for ever |
| 3 | `TEST_DUMP` | debug and test builds: every thread on the log (the keyboard driver's Sys Req) |
| 4 | `TEST_KEYS_READY` | test builds: the keyboard driver has started; the script waits for it |
| 5 | `TEST_SOUND_PROBE` | `TEST_SOUND` builds: BX the frequency the speaker sounds; the sound driver asks, and the kernel measures channel 2's output over a tick and says on the log whether it is that |
| 6 | `TEST_SILENCE_PROBE` | `TEST_SOUND` builds: the speaker silent over a tick? |
| 7 | `TEST_PROBE` | `TEST_ATTACK` builds: BL `PROBE_*`, below |
| 8 | `TEST_GIVE_WAY` | test builds: the next CX interrupt windows of any kernel call give way, a more urgent thread ready or not, so that the calls resume (roadmap os-server.md P3); CX back: the windows that were still to |
| 9 | `TEST_OVERRUN` | `TEST_ATTACK` builds: `INT 9` in ring 0, as the 287's overrun of a segment after the CPU had moved on (Intel 9.6.3) arrives: the caller is restarted as the program whose 287 it is (*docs/security.md*); no emulator the suites run raises vector 9 itself (roadmap os-server.md P15) |

In `TEST_FUZZ` builds the fuzz program's own `KCALL_TEST` is `KE_NOSYS`, as
in a release build: its random calls reach only what a release kernel has.

The test probe changes one of the caller's own descriptors during the
call, as a revocation would, so that the way back to its ring can be
tested (roadmap l4.md L1; *docs/interrupts.md*). The next start of its
program undoes the change; another BL is `KE_ARG`:

| BL | Constant | The change |
|---|---|---|
| 1 | `PROBE_DS_ABSENT` | the data segment's descriptor not present |
| 2 | `PROBE_DS_EXEC` | the data segment's slot refilled with execute-only code |
| 3 | `PROBE_SS_ABSENT` | the stack's descriptor not present |
| 4 | `PROBE_SS_READONLY` | the stack's slot refilled with read-only data |
| 5 | `PROBE_CS_ABSENT` | the code's descriptor not present |
| 6 | `PROBE_CS_DATA` | the code's slot refilled with data |

`PROBE_COUNT` is one past the last.

In `TEST_CAPS` builds the root gives the program, in slots 10-13 of a
space of 64, the rest of the memory for segments and of the arena as
untyped, its own space and its own thread; `tests/caps/calls.test` and
`tests/ipc/ipc.test` use them (*docs/testing.md*). `tests/timing/ipc.test` counts a round trip's
instructions on Bochs: 872 at L4.
