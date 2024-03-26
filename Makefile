ASM=nasm

SRC_DIR=src
TOOLS_DIR=tools
BUILD_DIR=build

.PHONY: all floppy_image kernel bootloader clean always tools_fat

all: floppy_image tools_fat

# Floppy Image
floppy_image: $(BUILD_DIR)/main_floppy.img
floppy_image: bootloader kernel

    # initialize floppy_image file to 2880 blocks each 512 bytes in size
    # note /dev/zero supplies an endless stream of zeroes, so floppy_image
    # is 1.44MB of zeroes
	dd if=/dev/zero of=$(BUILD_DIR)/main_floppy.img bs=512 count=2880

    # creates a FAT 12 filesystem with a label name of NBOS
    # on the disk image file floppy_image
	mkfs.fat -F 12 -n "NBOS" $(BUILD_DIR)/main_floppy.img

    # copies data from bootloader file to first sector of the floppy_image
    # disk file without removing any data from floppy_image
	dd if=$(BUILD_DIR)/bootloader.bin of=$(BUILD_DIR)/main_floppy.img conv=notrunc

    # copies the kernel.bin file to the disk
	mcopy -i $(BUILD_DIR)/main_floppy.img $(BUILD_DIR)/kernel.bin "::kernel.bin"

    # copies the test.txt file to the disk
	mcopy -i $(BUILD_DIR)/main_floppy.img test.txt "::test.txt"


# Bootloader
bootloader: $(BUILD_DIR)/bootloader.bin
$(BUILD_DIR)/bootloader.bin: always
	$(ASM) $(SRC_DIR)/bootloader/boot.asm -f bin -o $(BUILD_DIR)/bootloader.bin


# Kernel
kernel: $(BUILD_DIR)/kernel.bin
$(BUILD_DIR)/kernel.bin: always
	$(ASM) $(SRC_DIR)/kernel/main.asm -f bin -o $(BUILD_DIR)/kernel.bin


# Tools
tools_fat: $(BUILD_DIR)/tools/fat
$(BUILD_DIR)/tools/fat: always tools/fat/fat.c
	mkdir -p $(BUILD_DIR)/tools
	$(CC) -g -o $(BUILD_DIR)/tools/fat $(TOOLS_DIR)/fat/fat.c


# always: creates build directory if not there
always:
	mkdir -p $(BUILD_DIR) 


# clean: removes all build files
clean:
	rm -rf $(BUILD_DIR)/*
