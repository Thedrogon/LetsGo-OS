BUILD_DIR := build

LD := ld
AS := nasm

GOOS := linux
GOARCH := 386
GOROOT := $(shell go env GOROOT)
ARCH := x86

LD_FLAGS := -n -melf_i386 -T arch/$(ARCH)/script/linker.ld -static --no-ld-generated-unwind-info
AS_FLAGS := -g -f elf32 -F dwarf -I arch/$(ARCH)/asm/

kernel_target :=$(BUILD_DIR)/kernel-$(ARCH).bin
iso_target := $(BUILD_DIR)/kernel-$(ARCH).iso

disk_image := disk.img

asm_src_files := $(wildcard arch/$(ARCH)/asm/*.s)
asm_obj_files := $(patsubst arch/$(ARCH)/asm/%.s, $(BUILD_DIR)/arch/$(ARCH)/asm/%.o, $(asm_src_files))

.PHONY: kernel iso

kernel: $(kernel_target)

$(kernel_target): $(asm_obj_files) go.o
	@echo "[$(LD)] linking kernel-$(ARCH).bin"
	@$(LD) $(LD_FLAGS) -o $(kernel_target) $(asm_obj_files) $(BUILD_DIR)/go.o


go.o:
	@mkdir -p $(BUILD_DIR)

	@echo "[go] compiling go sources into a standalone .o file"
	@# build/go.o is a elf32 object file but all Go symbols are unexported. Our
	@# asm entrypoint code needs to know the address to 'main.main' and 'runtime.g0'
	@# so we use objcopy to globalize them
	@GOARCH=$(GOARCH) GOOS=$(GOOS) go build -ldflags='-buildmode=c-archive' -o $(BUILD_DIR)/go.o
	@echo "[objcopy] globalizing symbols {runtime.g0, main.main} in go.o"
	@objcopy \
                --globalize-symbol runtime.g0 \
                --globalize-symbol main.main \
                $(BUILD_DIR)/go.o $(BUILD_DIR)/go.o

$(BUILD_DIR)/arch/$(ARCH)/asm/%.o: arch/$(ARCH)/asm/%.s
	@mkdir -p $(shell dirname $@)
	@echo "[$(AS)] $<"
	@$(AS) $(AS_FLAGS) $< -o $@

iso: $(iso_target)

$(iso_target): $(kernel_target)
	@echo "[grub] building ISO kernel-$(ARCH).iso"

	@mkdir -p $(BUILD_DIR)/isofiles/boot/grub
	@cp $(kernel_target) $(BUILD_DIR)/isofiles/boot/kernel.bin
	@cp arch/$(ARCH)/script/grub.cfg $(BUILD_DIR)/isofiles/boot/grub
	@grub-mkrescue -o $(iso_target) $(BUILD_DIR)/isofiles 2>&1 | sed -e "s/^/  | /g"
	@rm -r $(BUILD_DIR)/isofiles

run: iso
	qemu-system-i386 -d int,cpu_reset -no-reboot -cdrom $(iso_target) \
		-hda disk.img -boot order=dc

# When building gdb target disable optimizations (-N) and inlining (l) of Go code
gdb: GC_FLAGS += -N -l
gdb: iso
	qemu-system-i386 -d int,cpu_reset -s -S -cdrom $(iso_target) \
		-hda disk.img -boot order=dc &
	sleep 1
	echo $(GOROOT)
	gdb \
	    -ex 'add-auto-load-safe-path $(pwd)' \
	    -ex 'set disassembly-flavor intel' \
		-ex 'set arch i386:intel' \
	    -ex 'file $(kernel_target)' \
	    -ex 'target remote localhost:1234' \
	    -ex 'set arch i386:intel' \
		-ex 'source $(GOROOT)/src/runtime/runtime-gdb.py' \
	@killall qemu-system-i386 || true
