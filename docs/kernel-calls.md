# The kernel's calls: capabilities and IPC

`INT 31h` (`KCALL_VECTOR`), an interrupt gate of DPL 3, is the kernel's own
interface: calls on capabilities and IPC between threads (roadmap l4.md
L3-L4, D20). Today's system
calls stay on `INT 30h` (*docs/syscalls.md*) until the OS server takes them
over. `src/include/kcalls.inc` holds the numbers, the types and the macro
`kcall`:

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
entry for each slot, which the kernel keeps in the arena
(*docs/memory-map.md*), where no program can reach it.

- **A segment capability is its descriptor.** The program loads it into DS
  or ES, and the CPU checks every access to it.
- **Every other capability is a descriptor of all zeros:** not present, DPL
  0, no valid type. Ring 3 can neither load it (#GP) nor learn anything of
  it with `LAR`, `LSL`, `VERR` or `VERW`; the shadow entry says what it is.

| Type | Constant | What it names |
|---|---|---|
| 0 | `CAP_EMPTY` | nothing: an empty slot |
| 1 | `CAP_SEGMENT` | memory, as a segment (data; code only from the kernel's image) |
| 2 | `CAP_UNTYPED` | memory not yet made into anything: the arena's, or the memory for segments |
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
`KCALL_SEGMENT` returns data in AX, so its status is CF alone, and a
receive returns the message's label in AL with CF clear. `KCALL_COUNT` is
the number of calls; the ones not listed answer `KE_NOSYS` until their
milestone.

| AH | Constant | In | Out |
|---|---|---|---|
| 1 | `KCALL_CALL` | DX an endpoint; AL the label; BX CX SI DI; BP a capability to pass, or 0 | AL the status; BX CX SI DI the reply |
| 2 | `KCALL_REPLY_RECV` | BX CX SI DI the reply owed; then as `KCALL_RECV` | as `KCALL_RECV` |
| 3 | `KCALL_RECV` | DX an endpoint or a notification; BP an empty slot of the caller's for a capability, or 0 | AL the label, DX the sender's badge, BX CX SI DI, BP the capability received, or 0; a notification: BX its bits |
| 4 | `KCALL_SEND` | as `KCALL_CALL`; or DX a saved reply and BX CX SI DI the reply | AL the status |
| 5 | `KCALL_SIGNAL` | DX a notification | |
| 6 | `KCALL_POLL` | as `KCALL_RECV` | as `KCALL_RECV`, or `KE_EMPTY` at once |
| 7 | `KCALL_RETYPE` | DX untyped; AL the type; SI an empty slot of the caller's; a segment: CX bytes (1-65535) and BL its access byte; a space: CX slots | the object made, zeroed, its capability in the slot |
| 8 | `KCALL_COPY` | DX a space the caller holds; SI a slot of the caller's; DI an empty slot of that space; AL `COPY_COPY`, `COPY_MOVE` or `COPY_MINT`; BX a badge (mint) | the capability there |
| 9 | `KCALL_THREAD` | DX a thread; AL `THREAD_CONFIGURE` (SI its space, BX its entry, CX its stack's top), `THREAD_START` (CL its priority, 0 to `PRIORITY_MAX`; CH 1 to ask for IOPL) or `THREAD_BIND` (SI a notification) | |
| 11 | `KCALL_TIMER` | DX a notification; CX ticks, 1 or more | |
| 12 | `KCALL_SEGMENT` | DX a segment | DL:AX its physical base, CX its limit (for DMA) |
| 13 | `KCALL_DELETE` | DX a slot of the caller's, not empty | the slot empty |
| 14 | `KCALL_SAVE_REPLY` | SI an empty slot of the caller's | the reply owed, as a `CAP_REPLY` there |

### Retype

Retype makes an object from untyped memory, at the untyped's next address
aligned to the object's size (`retype_place`, `src/lib/caps.asm`), and
zeroes it:

- **Kernel objects** - spaces, threads, endpoints, notifications - only from
  the arena's untyped. A thread takes a kernel stack's descriptor, and a
  space an LDT descriptor, from the GDT's pools: `KE_POOL` when none is left.
- **Segments** only from untyped outside the arena, and only data: present,
  of DPL 1-3. No program can make code; code comes only from the boot image
  (roadmap l4.md X14).
- **A space** has `SPACE_SLOTS_MIN` to `SPACE_SLOTS_MAX` slots, a power of
  two.

### Copy, move and mint

- **Copy** puts a second capability to the same thing in the slot; **move**
  empties the source; **mint** copies an endpoint or a notification that has
  no badge yet with a badge, which can never be changed. Untyped memory is
  moved, never copied.
- **A copy records its parent:** the space and slot it came from, for
  revocation (roadmap l4.md L12).
- **A segment moved away is gone at once** for the caller: a DS or ES still
  holding it is made null on the way back to ring 3 (*docs/interrupts.md*).

### Threads

A thread made by retype is configured, then started:

- **Configure** gives it a space whose slots 0, 1 and 2 are its program's
  code, data and stack, an entry and a stack's top. Slot 0 must be code;
  its DPL is the thread's ring (never 0).
- **Start** puts it in the scheduler at a priority. IOPL 1 goes only to a
  thread of ring 1 that asks for it (roadmap l4.md D11).
- A thread is configured and started once: `KE_STATE` after that.
- **Bind** ties it to a notification it may receive on, in any state: one
  each, so binding again unbinds the old.

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
interrupt or its timer, whichever comes first. Eight timers can be armed at
once across the system: `KE_POOL` after that.

### Delete

`KCALL_DELETE` empties a slot of the caller's. What it named lives on:
taking it back from every holder is revocation, roadmap l4.md L12. A
segment deleted while DS or ES holds it is gone at once, as for a move.

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

## In test builds

`TEST_CAPS` gives the program, in slots 8-11 of a space of 32, the memory
for segments and the rest of the arena as untyped, its own space and its
own thread; `tests/caps/calls.test` and `tests/ipc/ipc.test` use them
(*docs/testing.md*). `tests/timing/ipc.test` counts a round trip's
instructions on Bochs: 872 at L4.
