; using x86 assembly

org 0x7C00                  ; program starts at address 0x7C00
bits 16                     ; tells program to use 16 bit addressing mode

%define ENDL 0x0D, 0x0A     ; endline macro definition (13 for carriage return, 10 for newline) 
                            ; carriage return means move to beginning of current line
                            ; line feed means move down one line
                            ; so together they move to the first char on the next line



; Initializing the BPB (BIOS Parameter Block)
; see https://wiki.osdev.org/FAT

; FAT12 header
jmp short start
nop

bdb_oem:                    db "MSWIN4.1"
bdb_bytes_per_sector:       dw 512
bdb_sectors_per_cluster:    db 1
bdb_reserved_sectors:       dw 1
bdb_fat_count:              db 2
bdb_dir_entries_count:      dw 0xE0
bdb_total_sectors:          dw 2880                 ; 2880 * 512 = 1440 bytes
bdb_media_descriptor_type:  db 0xf0
bdb_sectors_per_fat:        dw 9
bdb_sectors_per_track:      dw 18 
bdb_heads:                  dw 2
bdb_hidden_sectors:         dd 0
bdb_large_sector_count:     dd 0

; extended boot record
ebr_drive_number:           db 0                    ; 0x00 floppy, 0x80 hdd, useless
                            db 0                    ; reserved
ebr_signature:              db 29h
ebr_volume_id:              db 12h, 34h, 56h, 78h   ; serial number, value doesn't matter
ebr_volume_label:           db 'ANDREW OS  '        ; 11 bytes, padded with spaces
ebr_system_id:              db 'FAT12   '           ; 8 bytes

; code goes here

start:
    ; setup data segments
    mov ax, 0
    mov ds, ax
    mov es, ax

    ; setup stack
    mov ss, ax
    mov sp, 0x7C00                      ; stack grows downwards from this address

    ; some BIOSes might start us at 
    ; 07C0:0000 instead of 0000:07C0
    push es
    push word .after
    retf

.after:
    ; read something from floppy disk
    ; BIOS should set dl to drive number
    mov [ebr_drive_number], dl

    ; show loading message
    mov si, msg_loading                 ; setup ds:si for puts
    call puts

    ; read drive parameters 
    ; (sectors per track & head count)
    ; instead of relying on formatted disk
    push es
    mov ah, 0x8
    int 13h
    jc floppy_error
    pop es

    and cl, 0x3f                        ; remove top 2 bits
    xor ch, ch                          
    mov [bdb_sectors_per_track], cx     ; sector count

    inc dh
    mov [bdb_heads], dh                 ; head count

    ; compute LBA of root directory 
    ; = reserved + fats * sectors_per_fat
    mov ax, [bdb_sectors_per_fat]
    mov bl, [bdb_fat_count]
    xor bh, bh 
    mul bx                              ; ax = ax * bx
                                        ; axs = fats * sectors_per_fat
    add ax, [bdb_reserved_sectors]
    push ax

    ; compute size of root directory
    ; = (32 * num_entries) / bytes_per_sector
    mov ax, [bdb_dir_entries_count]
    shl ax, 5                           ; ax = num_entries * 32
    xor dx, dx                          ; dx = 0
    div word [bdb_bytes_per_sector]     ; ax = num * 32 / bytes_per_sector

    test dx, dx                         ; if remainder != 0, add 1 sector (round up)
    jz .root_dir_after
    inc ax

.root_dir_after:
    mov cl, al                          ; cl = num sectors to read (size of root dir)
    pop ax                              ; ax = lba of root dir
    mov dl, [ebr_drive_number]          ; dl = drive number
    mov bx, buffer                      ; es:dx = buffer
    call disk_read 

    ; search root directory for kernel.bin file
    ; i.e. "findFile"
    xor bx, bx 
    mov di, buffer

.search_kernel:
    mov si, file_kernel_bin             ; file_kernel_bin = "KERNEL  BIN"
    mov cx, 11                          ; compare up to 11 characters
    push di
    repe cmpsb                          ; cmpsb compares two bytes located at ds:si and es:di
                                        ; si and di are incremented with direction flag = 0, or decremented
                                        ; with direction flag = 1
    pop di
    je .found_kernel

    add di, 32
    inc bx
    cmp bx, [bdb_dir_entries_count]
    jl .search_kernel

    ; kernel not found
    jmp kernel_not_found_error

.found_kernel:

    ; di should have the address to the entry
    mov ax, [di + 26]                           ; first logical cluster field (defined offset 26)
    mov [kernel_cluster], ax

    ; load FAT from disk into memory
    mov ax, [bdb_reserved_sectors]
    mov bx, buffer
    mov cl, [bdb_sectors_per_fat]
    mov dl, [ebr_drive_number]
    call disk_read

    ; read kernel and process FAT cluster chain
    mov bx, KERNEL_LOAD_SEGMENT
    mov es, bx
    mov bx, KERNEL_LOAD_OFFSET

.load_kernel_loop:
    ; read next cluster
    mov ax, [kernel_cluster]
    
    ; hardcoded offset value TODO: fix later
    add ax, 31                                  ; first cluster = (kernel_cluster - 2) * sectors_per_cluster + start_sector
                                                ; start sector = reserved + fats + root directory size = 1 + 18 + 134 = 33
    mov cl, 1
    mov dl, [ebr_drive_number]
    call disk_read

    add bx, [bdb_bytes_per_sector]

    ; compute location of next cluster
    mov ax, [kernel_cluster]
    mov cx, 3
    mul cx
    mov cx, 2
    div cx                                  ; ax = fatIndex, dx = cluster mod 2

    mov si, buffer
    add si, ax
    mov ax, [ds:si]

    or dx, dx
    jz .even

.odd:
    shr ax, 4
    jmp .next_cluster_after

.even:
    and ax, 0x0fff

.next_cluster_after:
    cmp ax, 0x0ff8                          ; end of chain
    jae .read_finish

    mov [kernel_cluster], ax
    jmp .load_kernel_loop

.read_finish:
    ; boot device in dl
    mov dl, [ebr_drive_number]

    mov ax, KERNEL_LOAD_SEGMENT
    mov ds, ax
    mov es, ax

    jmp KERNEL_LOAD_SEGMENT:KERNEL_LOAD_OFFSET
    
    jmp wait_key_and_reboot                 ; should never happen

    cli
    hlt



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Error handlers

floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

kernel_not_found_error:
    mov si, msg_kernel_not_found
    call puts
    jmp wait_key_and_reboot

wait_key_and_reboot:
    mov ah, 0
    int 16h                     ; waits for keypress
    jmp 0xFFFF:0                ; jump to beginning of BIOS (reboot)

.halt:
    cli                         ; disable interrupts, so CPU can't get out of halt state
    hlt

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;
; Prints a string to the screen
;   @param ds:si points to the desired string
;
puts:
    ; save registers we will use to the stack
    push si
    push ax
    push bx

.loop:
    lodsb                   ; loads a byte from ds:si into al register and increments si

    or al, al               ; perform bitwise or on next character
                            ; if next char is null (all zeroes) then al will be zero
                            ; and the zero flag will be set
    
    jz .done                ; if zero flag is set (we found null) jump to done

    ; print char to screen
    mov ah, 0x0e            ; set video function call to tty (text printing)
    mov bh, 0               ; set page number to zero
    int 0x10                ; system called video interrupt

    jmp .loop               ; else continue onto next character

.done:
    pop bx
    pop ax
    pop si
    ret


; Disk Routines

;
; Converts an LBA address to a CHS address
;  @param ax LBA address
;  @return cx [bits 0-5]: sector number
;  @return cx [bits 6-15]: cylinder
;  @return dh head
;

lba_to_chs:

    push ax
    push dx

    xor dx, dx                          ; dx = 0
    div word [bdb_sectors_per_track]    ; ax = LBA / bdb_sectors_per_track
                                        ; dx = LBA % bdb_sectors_per_track

    ; calculate sector
    inc dx                              ; dx = (LBA % bdb_sectors_per_track) + 1 = sector
    mov cx, dx

    ; calculate cylinder and head
    xor dx, dx                          ; dx = 0
    div word [bdb_heads]                ; ax = (LBA / bdb_sectors_per_track) / heads = cylinder
                                        ; dx = (LBA / bdb_sectors_per_track) % heads = head

    ; set head number
    mov dh, dl

    ; join sector and cylinder numbers
    ; GOAL: C7-0 | C9-8 | S5-0
    mov ch, al                          ; put lower 8 bits of cylinder into upper 8 of cx
    shl ah, 6                           ; shift left bits 9 and 10 by six so they are the 2
                                        ; most significant bits
    or cl, ah                           ; join two msb from cylinder with sector bits


    pop ax                              ; pop value of dx into ax temporarily
    mov dl, al                          ; save value of old dl only (new dh is reserved for return value)
    pop ax                              ; restore ax
    ret


;
; Reads sectors from a disk
;   @param ax LBA address
;   @param cl number of sectors to read (<= 128)
;   @param dl drive number
;   @param es:bx memory address to store the data read
;

disk_read:
    push ax                             ; save modified registers
    push cx
    push di
    push dx
    push bx

    push cx                             ; save cx
    call lba_to_chs                     ; compute chs address
    pop ax                              ; put num sectors to read into al

    mov ah, 0x2
    mov di, 3                           ; retry count


.retry:
    pusha                               ; save all registers to the stack
    stc                                 ; set carry flag (not all BIOS's do this)
    int 0x13                            ; if carry flag cleared -> success
    jnc .done                           ; jump if carry flag not set

    ; read failed
    popa                                ; restore all registers
    call disk_reset                     ; restore state of floppy disk

    dec di                              ; decrement di
    test di, di                         ; set condition flags based on di
    jnz .retry                          ; if di not zero, try to read again

.fail:
    ; still failed to read after exhausted all methods
    jmp floppy_error

.done: 
    popa                                ; restore all registers

    pop bx                             ; restore modified registers
    pop dx
    pop di
    pop cx
    pop ax
    ret


;
; Resets disk controller
;   @param dl drive number
;
disk_reset:
    pusha
    mov ah, 0
    stc
    int 0x13
    jc floppy_error
    popa
    ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


msg_loading:                db "Loading...", ENDL, 0
msg_read_failed:            db "Read from disk failed.", ENDL, 0
msg_kernel_not_found:       db "Kernel.bin File Not Found.", ENDL, 0
file_kernel_bin:            db "KERNEL  BIN"
kernel_cluster:             db 0

KERNEL_LOAD_SEGMENT         equ 0x2000
KERNEL_LOAD_OFFSET          equ 0


times 510 - ($ - $$) db 0               ; times X INSTRUCTION
                                        ; executes following instruction X times
                                        ; we want the program to fit into 512 bytes with the last two bytes
                                        ; reserved for 0xaa55, which tells the compiler that this is a boot sector
                                        ; $ will get the current instruction address, and $$ gets the address of the first
                                        ; instruction in this program, so $ - $$ will get the size of the program so far
                                        ; and 510 - ($ - $$) will get the remaining addresses left until the last two addresses
                                        ; then we fill all those bytes with zeros with db 0 (define byte 0)

dw 0xaa55 

buffer: