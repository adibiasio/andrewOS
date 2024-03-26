; using x86 assembly

org 0x0                     ; program starts at address 0x7C00
bits 16                     ; tells program to use 16 bit addressing mode

%define ENDL 0x0D, 0x0A     ; endline macro definition (13 for carriage return, 10 for newline) 
                            ; carriage return means move to beginning of current line
                            ; line feed means move down one line
                            ; so together they move to the first char on the next line

start:
    ; setup ds:si for puts
    mov si, msg_hello
    call puts

.halt:
    cli
    hlt
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

msg_hello: db "Hello World from THE KERNEL!!!", ENDL, 0
