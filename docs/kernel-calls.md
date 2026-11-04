# The kernel's calls: capabilities

`INT 31h` (`KCALL_VECTOR`), an interrupt gate of DPL 3, is the kernel's own
interface: calls on capabilities (roadmap l4.md L3, D20). Today's system
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
| 5 | `CAP_ENDPOINT` | an endpoint, with a badge (IPC, roadmap l4.md L4) |
| 6 | `CAP_NOTIFY` | a notification, with a badge (L4) |
| 7 | `CAP_IRQ` | an interrupt line (L7) |

A selector that is not an LDT selector of the caller's space, or names a
slot past its end, names no capability: `KE_CAP`, as does a slot of the
wrong type. The GDT holds nothing a program could name.

## The calls

AH is the call. The status comes back in AL, with CF set on an error;
`KCALL_SEGMENT` returns data in AX, so its status is CF alone.
`KCALL_COUNT` is the number of calls; the ones not listed answer
`KE_NOSYS` until their milestone.

| AH | Constant | In | Out |
|---|---|---|---|
| 7 | `KCALL_RETYPE` | DX untyped; AL the type; SI an empty slot of the caller's; a segment: CX bytes (1-65535) and BL its access byte; a space: CX slots | the object made, zeroed, its capability in the slot |
| 8 | `KCALL_COPY` | DX a space the caller holds; SI a slot of the caller's; DI an empty slot of that space; AL `COPY_COPY`, `COPY_MOVE` or `COPY_MINT`; BX a badge (mint) | the capability there |
| 9 | `KCALL_THREAD` | DX a thread; AL `THREAD_CONFIGURE` (SI its space, BX its entry, CX its stack's top) or `THREAD_START` (CL its priority, 0 to `PRIORITY_MAX`; CH 1 to ask for IOPL) | |
| 12 | `KCALL_SEGMENT` | DX a segment | DL:AX its physical base, CX its limit (for DMA) |

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

## Errors

| Code | Constant | Meaning |
|---|---|---|
| 0 | `KE_OK` | done |
| 1 | `KE_CAP` | not a capability of the type the call needs |
| 2 | `KE_ARG` | an argument out of range |
| 3 | `KE_MEM` | the untyped memory has no room left |
| 4 | `KE_SLOT` | the destination slot is not empty |
| 5 | `KE_POOL` | no descriptor left in the kernel's pools |
| 6 | `KE_STATE` | not in that state: a thread started twice |
| 7 | `KE_NOSYS` | no such call |

## In test builds

`TEST_CAPS` gives the program, in slots 8-11 of a space of 16, the memory
for segments and the rest of the arena as untyped, its own space and its
own thread; `tests/caps/calls.test` uses them (*docs/testing.md*).
