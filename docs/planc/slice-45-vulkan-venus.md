# Slice 45: VirtIO-GPU PCI Driver y Plan Vulkan sobre Protocolo Venus

Este documento describe la arquitectura e implementación incremental del soporte VirtIO-GPU en PlanetOS y la ruta hacia aceleración **Vulkan** usando el protocolo **Venus** (virtio-gpu `CAPSET_VENUS`) junto con los módulos SPIR-V generados por `planc --target=spirv`.

## 1. Estado Actual (Fase 1 — Implementado)

Archivo: `kernel/virtio_gpu.vala` (invocado desde `kernel/main.vala`, mapeo MMIO en `kernel/vmm.vala`).

### Capacidades implementadas en Fase 1
1. **Descubrimiento PCI Modern VirtIO 1.0**:
   - Escaneo de bus/slot/función PCI buscando Vendor `0x1AF4` (`VIRTIO_PCI_VENDOR`) y Device `0x1050` (`VIRTIO_PCI_DEV_GPU`).
   - Habilitación de PCI Memory Space (`0x02`) y Bus Master (`0x04`) en el registro Command.
   - Recorrido de la lista de capacidades PCI (`cap_id == 0x09`) para localizar:
     - `VIRTIO_PCI_CAP_COMMON_CFG` (1)
     - `VIRTIO_PCI_CAP_NOTIFY_CFG` (2) + `notify_off_multiplier`
     - `VIRTIO_PCI_CAP_DEVICE_CFG` (4)
   - Mapeo MMIO de 2 MiB en el VMM (`Vmm.map_mmio_2m (bar_addr)`) sobre `PDPT[3]` (`0xC0000000..0xFFFFFFFF`).
2. **Inicialización VirtIO & Negociación de Features**:
   - Secuencia estándar VirtIO 1.0: `RESET` -> `ACKNOWLEDGE` -> `DRIVER` -> lectura/escritura de features (`VERSION_1`, `VIRGL`, `EDID`, `RESOURCE_UUID`, `RESOURCE_BLOB`, `CONTEXT_INIT`) -> `FEATURES_OK` -> verificación -> `DRIVER_OK`.
3. **Cola `controlq` (Queue 0)**:
   - Virtqueue split de 16 entradas alineada a 4 KiB (`Pmm.alloc_frame ()`), con tablas de descriptores, `avail` ring y `used` ring, más buffers DMA dedicados para comandos y respuestas.
   - Envío síncrono de comandos con notificación MMIO (`notify_base + queue_notify_off * notify_mult`) y espera sobre el `used` ring.
4. **Comandos iniciales**:
   - `VIRTIO_GPU_CMD_GET_DISPLAY_INFO` (`0x0100`): consulta resolución y estado de `pmodes[0]`.
   - `VIRTIO_GPU_CMD_GET_CAPSET_INFO` (`0x0108`): consulta capsets 0..num_capsets-1 detectando `CAPSET_VENUS` (`capset_id = 4`).

## 2. Arquitectura Objetivo: Vulkan sobre Venus

El protocolo **Venus** serializa comandos de la API Vulkan (`VkInstance`, `VkDevice`, `VkCommandBuffer`, `VkPipeline`, `vkQueueSubmit`, etc.) dentro de un **VirtIO-GPU Context** (`CAPSET_VENUS = 4`), transportando los buffers de comandos en **Blob Resources** (`RESOURCE_BLOB`) compartidos entre el guest (PlanetOS) y el host (QEMU + `virglrenderer` con Venus habilitado sobre Vulkan del host).

```
  App Vala / Cairo / Compositor
        │  (stdlib/vulkan_compat.vala + shaders .spv de planc --target=spirv)
        ▼
  Venus Command Encoder (ring buffer en memoria compartida / blob)
        │  (syscall sys_gpu_submit / ioctl sobre /dev/virtio-gpu)
        ▼
  kernel/virtio_gpu.vala (CONTEXT_INIT + RESOURCE_BLOB + SUBMIT_3D)
        │  (controlq VirtIO-GPU PCI)
        ▼
  QEMU (virtio-gpu-gl-pci) + virglrenderer (Venus) ──► GPU Vulkan del Host
```

## 3. Fases Siguientes

### Fase 2 — Scanout 2D y Display VirtIO-GPU
- Implementar `RESOURCE_CREATE_2D`, `RESOURCE_ATTACH_BACKING`, `SET_SCANOUT`, `TRANSFER_TO_HOST_2D`, `RESOURCE_FLUSH`.
- Integrar como backend opcional de `kernel/fb.vala` cuando `VirtioGpu.is_present ()` es verdadero, manteniendo `BGA` / framebuffer multiboot2 como fallback.
- Exponer `cursorq` (Queue 1) para cursor hardware (`UPDATE_CURSOR` / `MOVE_CURSOR`), eliminando el parpadeo y copia de fondo del cursor por software.

### Fase 3 — Contextos 3D y Blob Resources (`VIRGL` / `VENUS`)
- Implementar `CTX_CREATE` con `context_init` (`CAPSET_VENUS = 4`), `CTX_DESTROY`.
- Implementar `RESOURCE_CREATE_BLOB` (host-visible / guest-shared shmem) y `CTX_ATTACH_RESOURCE` / `CTX_DETACH_RESOURCE`.
- Implementar `SUBMIT_3D` (`0x0207`) sobre `controlq` y soporte de fences (`VIRTIO_GPU_FLAG_FENCE`) para sincronización asíncrona con el host.
- Configurar `virglrenderer` en QEMU con `-device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M` (cuando el host disponga de backend GL/Vulkan).

### Fase 4 — Runtime Venus y Shaders SPIR-V de `planc`
- **Codificador Venus (userspace/kernel)**: empaquetado de comandos `vkCreateInstance`, `vkCreateDevice`, `vkCreateShaderModule` (usando directamente los binarios `.spv` emitidos por `planc --target=spirv`, como `frag.spv`), `vkCreateComputePipelines` / `vkCreateGraphicsPipelines`, `vkCmdDispatch` / `vkCmdDraw` y `vkQueueSubmit`.
- **Integración con `stdlib/vulkan_compat.vala`**: reemplazar o acelerar el rasterizador software actual de `vulkan_compat.vala` enviando los command buffers serializados al dispositivo Venus cuando esté disponible, conservando el rasterizador SIMD (`AVX2`/`SSE4.1`) como fallback en hardware sin Venus.
- **Compositor (`apps/desktop.vala`)**: presentación directa de superficies de ventanas mediante imágenes/texturas Vulkan y composición acelerada por GPU.
