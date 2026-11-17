# Slice 48: VirtIO-GPU Phase 3 — wire format, lifetime and a 3D probe

Phase 3 of [slice 45](slice-45-vulkan-venus.md) was written but never exercised.
The first probe found two defects that made the 3D path unusable before any
Venus work could start, so this slice fixes them and adds the instrument that
proves the path end to end.

## 1. Defects

### 1.1 `RESOURCE_CREATE_BLOB` had `size` and `blob_id` swapped

`virtio_gpu_resource_create_blob` is laid out by the virtio specification as:

```
off  field
24   resource_id
28   blob_mem
32   blob_flags
36   nr_entries
40   blob_id          (u64)
48   size             (u64)
56   entries[]
```

`create_blob` and `create_blob_mapped` wrote `size` at +40 and `blob_id` at
+48. A GUEST blob has `blob_id = 0`, so the device received a zero-sized blob
and rejected it. Both functions now follow the wire order.

### 1.2 Venus was reported present when the host had no Venus backend

`GET_CAPSET_INFO` answers with `capset_max_size = 0` for a capset the
virglrenderer build cannot create. The driver only compared the id, so
`has_venus ()` could be true on hosts that cannot make a Venus context. The
check now requires `capset_max_size > 0`.

## 2. Lifetime

The device is global; a process's contexts and blobs are not. Before this
slice, `CTX_CREATE` had no matching detach/unref path and nothing released a
process's GPU objects when it was reaped, so a crashed demo left resources
behind until reboot.

`kernel/virtio_gpu.vala` now keeps a one-page ownership table (64 x 32-byte
entries) with the owner tid, context, resource id, physical address, size and
page count. On top of it:

- `ctx_detach` (`CTX_DETACH_RESOURCE`, `0x0203`) and `resource_unref`
  (`RESOURCE_UNREF`, `0x0102`) complete the lifecycle.
- `blob_destroy` only releases a blob the kernel recorded for the calling
  task with the same context, address and size, so a bad argument cannot free
  frames that belong to somebody else. It unmaps the user range before
  returning the frames to the PMM.
- `create_blob_mapped` uses `Vmm.map_user_range_checked` and unwinds the
  blob, the attach and the frames when the mapping fails, instead of handing
  userland an address whose first write would fault.
- `release_task` is called from `Sched.wait_tid` before the address space is
  destroyed: it detaches/unrefs/ frees the task's blobs and destroys its
  contexts.

`SYS_GPU_BLOB_DESTROY` (46) exposes the blob release to userland.

## 3. Probe

Two entry points, both in the existing binaries (no new ELF, no new disk
entry):

```
planet> gpu
gpu: present=1 virgl=1 blob=1 ctx=1 venus=0 display=1280x800

planet> gpu probe
gpu: present=1 virgl=1 blob=1 ctx=1 venus=0 display=1280x800
gpu: probe ctx=1 submit=1 blob=0 venus=0 cleanup=1
```

`gpu` reads `SYS_GPU_INFO`. `gpu probe` runs `vk_demo.elf --probe`, which uses
`Venus.ProbeResult` in [stdlib/venus_compat.vala](../../stdlib/venus_compat.vala):
create a VirGL2 context, submit one `VIRGL_CCMD_NOP` dword through
`SYS_GPU_SUBMIT_3D`, optionally create/attach/destroy a GUEST blob, try a
Venus context when the capset is real, and destroy everything it created.
`cleanup` is false only when a created object failed to be released.

The probe is deliberately an ordinary userland client of the same syscalls
the compositor uses. It is not a kernel self-test.

## 4. Verification

### 4.1 Regression harness (`-vga std`, no GPU)

`tests/cases/gpu.sh` runs `gpu` and `gpu probe` with no virtio-gpu device and
requires:

```
gpu: present=0 virgl=0 blob=0 ctx=0 venus=0 display=0x0
gpu: probe skipped (no virtio-gpu)
```

That covers the absent-device path and the `!fault:` assertion.

### 4.2 Real 3D path (`-display egl-headless`, `virtio-gpu-gl-pci,blob=on`)

```
virtio_gpu:found=1 w=1280 h=800 virgl=1 blob=1 ctx=1 venus=0
...
gpu: probe ctx=1 submit=1 blob=0 venus=0 cleanup=1
```

Running `gpu probe` twice in the same boot produces the same result, which is
the observable proof that `CTX_DESTROY` released the context: a second
`CTX_CREATE` with the same id would be refused by the ownership table.

## 5. Host limitation found by the probe

QEMU 11.1.3 (MSYS2 `mingw-w64-ucrt-x86_64-qemu 11.1.3-2`) advertises
`F_RESOURCE_BLOB` with `-device virtio-gpu-gl-pci,blob=on` (the guest reports
`blob=1`) and QOM reports `blob = true`, yet `RESOURCE_CREATE_BLOB` is rejected
with `VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER` (`0x1205`) **before**
`trace_virtio_gpu_cmd_res_create_blob` is reached. The handler's first check
is `virtio_gpu_blob_enabled (g->parent_obj.conf)`, so on this build the bit the
command path reads is clear even though the qdev property reports it set.

The consequence is that GUEST blobs cannot be created here. The wire format
and the lifetime code are still exercised on the paths that do work, and the
probe reports `blob=0` instead of failing. Venus needs HOST3D blobs plus
hostmem, so the same host limitation blocks the Venus phase until either the
host accepts blobs or a different QEMU build is used.

The default `gl` GPU mode now passes `blob=on` (guest blobs need no hostmem),
so the day the host accepts them the probe picks them up without a guest
change.

## 6. GTK4 track

Nothing in this slice introduces a GTK3-only surface API. The probe and the
compositor meet at `Venus.GpuDevice` / `Gsk.Renderer`; the renderer interface
(`render (root, surface)`, `backend_name`) is the shape a GTK4 `GskRenderer`
has, and the Cairo fallback remains the renderer used while no Vulkan ICD
exists. The GPU ownership rules added here are what a long-lived GTK4
application needs: a leaked context from a closed window is no longer a leak
for the whole session.

## 7. Next

1. `RESOURCE_CREATE_3D` + attach/detach for the classic VirGL resource path,
   which works without blobs.
2. HOST3D blob + `RESOURCE_MAP_BLOB`/`UNMAP_BLOB` once the host accepts blobs.
3. Venus command ring and `vkQueueSubmit` encoding over the blob, then wire
   `GpuDevice` to submit the commands it already encodes.
