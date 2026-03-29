section .bss
    fd_no           resq 1     ; Server socket file descriptor
    socketfd_no     resq 1     ; Client socket file descriptor
    client_addr     resb 16    ; Buffer for client's sockaddr_in structure
    request_buffer  resb 2048  ; Buffer to store incoming HTTP request
    file_path       resb 256   ; Buffer to store the extracted requested file path
    file_fdno       resq 1     ; File descriptor for the opened file
    statbuff        resb 144   ; Buffer for sys_fstat to store file metadata
    ip_string       resb 16    ; Buffer to convert and store IP string ("xxx.xxx.xxx.xxx")
    read_bytes      resq 1     ; Variable to store the length of the read request
    
    serv_addr:                 ; sockaddr_in structure for the server
        serv_family: resw 1    ; 2 bytes (AF_INET)
        serv_port:   resw 1    ; 2 bytes (Port - Big Endian)
        serv_ip:     resd 1    ; 4 bytes (IP - 0.0.0.0 for INADDR_ANY)
        serv_pad:    resb 8    ; 8 bytes (Padding - filled with 0)

section .data
    client_addr_len dd 16      ; Length of the client_addr structure (needed for accept)
    
    forbidden_msg   db "Path Traversal Detected!", 10
    forbidden_len   equ $ - forbidden_msg
    
    ; HTTP 404 Response Header
    msg_404 db "HTTP/1.1 404 Not Found", 13, 10
            db "Content-Type: text/plain", 13, 10
            db "Content-Length: 14", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
            db "File Not Found"
    len_404 equ $ - msg_404
    
    ; HTTP 200 Response Header
    msg_200 db "HTTP/1.1 200 OK", 13, 10
            db "Content-Type: text/html", 13, 10 
            db "Connection: close", 13, 10
            db 13, 10
    len_200 equ $ - msg_200
    
    ; Terminal Log Prefixes
    log_ip_prefix  db "[+] Connected IP: "
    len_ip_prefix  equ $ - log_ip_prefix
    
    log_req_prefix db "[+] Incoming Request: ", 10
    len_req_prefix equ $ - log_req_prefix
    
    dot            db "."      ; Dot character for IP address formatting

section .text

global _start

_start:
    call init_struct           ; Initialize sockaddr_in struct with IP and Port
    call socket_create         ; Create TCP socket
    call socket_bind           ; Bind socket to 0.0.0.0:8080
    call socket_listen         ; Start listening for connections
    
server_loop:                
    call socket_accept         ; Accept incoming client connection (Blocks until client connects)
    
    ; --- 1. Print Client IP Address to Terminal ---
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; FD 1 (stdout)
    lea rsi, [log_ip_prefix]   ; Load prefix message
    mov rdx, len_ip_prefix     ; Length of prefix
    syscall

    call print_ip              ; Parse and print the client's IP address
    
    ; Print newline after IP
    mov byte [ip_string], 10   ; Reusing ip_string buffer for newline char
    mov rax, 1
    mov rdi, 1
    lea rsi, [ip_string]
    mov rdx, 1
    syscall
    ; ------------------------------------

    call sys_read              ; Read the HTTP request from the client
    
    ; --- 2. Print Incoming HTTP Request to Terminal ---
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; FD 1 (stdout)
    lea rsi, [log_req_prefix]  ; Load request log prefix
    mov rdx, len_req_prefix    ; Length of prefix
    syscall
    
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; FD 1 (stdout)
    lea rsi, [request_buffer]  ; Load the actual HTTP request buffer
    mov rdx, [read_bytes]      ; Print exactly the amount of bytes we read
    syscall
    ; ----------------------------------------

    call parse_request         ; Extract file path from GET request and check for ".."
    
    ; 3. Try to open the requested file
    call sys_open

    ; 4. Send HTTP 200 OK header to the client
    mov rax, 1                 ; sys_write
    mov rdi, [socketfd_no]     ; Destination: Client socket
    lea rsi, [msg_200]         ; Source: 200 OK Header
    mov rdx, len_200           ; Length of header
    syscall

    ; 5. Get file size and send file content directly from Kernel
    call sys_fstat             ; Get file metadata (including size)
    call sys_sendfile          ; Send file content using zero-copy sys_sendfile
    
    ; 6. Cleanup: Close file and client socket descriptors to prevent FD leaks
    mov rax, 3                 ; sys_close
    mov rdi, [file_fdno]       ; Close opened file
    syscall
    
    mov rax, 3                 ; sys_close
    mov rdi, [socketfd_no]     ; Close client socket
    syscall
    
    jmp server_loop            ; Loop back and wait for the next client


; ====================================================
; FUNCTIONS
; ====================================================

socket_create:
    mov rax, 41                ; sys_socket
    mov rdi, 2                 ; AF_INET (IPv4)
    mov rsi, 1                 ; SOCK_STREAM (TCP)
    xor rdx, rdx               ; Protocol 0
    syscall
    test rax, rax              ; Check if socket creation failed
    js _exit                   ; If negative (error), exit program
    mov [fd_no], rax           ; Save server socket FD
    ret

socket_bind:
    mov rax, 49                ; sys_bind
    mov rdi, [fd_no]           ; Server socket FD
    lea rsi, [serv_addr]       ; Pointer to sockaddr_in struct
    mov rdx, 16                ; Size of sockaddr_in
    syscall
    ret

init_struct:
    mov word [serv_family], 2  ; Set family to AF_INET (2)
    mov eax, 8080              ; Set port to 8080
    bswap eax                  ; Convert Little Endian to Big Endian (Network Byte Order)
    shr eax, 16                ; Shift right to get the upper 16 bits
    mov word [serv_port], ax   ; Save Big Endian port to struct
    mov dword [serv_ip], 0     ; Set IP to 0.0.0.0 (INADDR_ANY)
    mov qword [serv_pad], 0    ; Zero out the padding
    ret

socket_listen:
    mov rax, 50                ; sys_listen
    mov rdi, [fd_no]           ; Server socket FD
    mov rsi, 128               ; Backlog queue size (128 connections)
    syscall
    test rax, rax              ; Check for error
    js _exit
    ret

socket_accept:
    mov rax, 43                ; sys_accept
    mov rdi, [fd_no]           ; Server socket FD
    lea rsi, [client_addr]     ; Pointer to store incoming client's info
    lea rdx, [client_addr_len] ; Pointer to length of client_addr (must be 16)
    syscall
    test rax, rax              ; Check if accept failed
    js _exit
    mov [socketfd_no], rax     ; Save new client socket FD
    ret

sys_read:
    mov rax, 0                 ; sys_read
    mov rdi, [socketfd_no]     ; Read from client socket
    lea rsi, [request_buffer]  ; Store data in request_buffer
    mov rdx, 2048              ; Max bytes to read
    syscall
    mov [read_bytes], rax      ; Save actual bytes read for logging
    test rax, rax              ; Check for read error
    js _exit
    ret

parse_request:
    cld                        ; Clear direction flag (scan forward)
    lea rdi, [request_buffer]  ; String to scan
    mov rcx, 2048              ; Max length
    mov al, ' '                ; Look for space character (after "GET")
    repne scasb                ; Scan until space is found
    
    ; RDI now points to the character right after the first space (start of file path)
    mov rsi, rdi               ; Source = start of path
    lea rdi, [file_path]       ; Destination = file_path buffer
    
.copy_path:
    lodsb                      ; Load byte from RSI to AL, increment RSI
    cmp al, ' '                ; Check if we hit the second space (before "HTTP/1.1")
    je .done_copy              ; If yes, finish copying
    cmp al, 0                  ; Check if we hit end of buffer
    je .done_copy
    stosb                      ; Store AL to RDI, increment RDI
    loop .copy_path            ; Repeat

.done_copy:
    mov byte [rdi], 0          ; Null-terminate the string (required for sys_open)
    
    ; --- Security Check: Prevent Path Traversal (directory climbing using "..") ---
    lea rsi, [file_path]
.check_dots:
    lodsb
    cmp al, 0                  ; Reached end of string?
    je .secure                 ; If yes, path is safe
    cmp al, '.'                ; Found a dot?
    jne .check_dots            ; If not, keep checking
    lodsb                      ; Load next byte
    cmp al, '.'                ; Is it a second dot consecutively ("..")?
    je _security_alert         ; If yes, trigger security alert
    jmp .check_dots            ; Keep checking rest of the string

.secure:
    ret

_security_alert:
    ; Print Forbidden message to stdout and exit (Can be modified to send HTTP 403 instead)
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; FD 1 (stdout)
    lea rsi, [forbidden_msg]
    mov rdx, forbidden_len
    syscall
    jmp _exit

sys_open:
    mov rax, 2                 ; sys_open
    lea rdi, [file_path + 1]   ; Skip the leading '/' in the requested path (e.g., "/index.html" -> "index.html")
    mov rsi, 0                 ; O_RDONLY (Read only flag)
    syscall
    test rax, rax              ; Check if file exists/can be opened
    js open_error              ; If negative, jump to 404 handler
    mov [file_fdno], rax       ; Save the file descriptor
    ret
    
sys_fstat:
    mov rax, 5                 ; sys_fstat
    mov rdi, [file_fdno]       ; Opened file FD
    lea rsi, [statbuff]        ; Buffer to store stat struct
    syscall
    ret

sys_sendfile:
    mov rax, 40                ; sys_sendfile (Zero-copy transfer)
    mov rdi, [socketfd_no]     ; Destination FD (Client socket)
    mov rsi, [file_fdno]       ; Source FD (Opened file)
    xor rdx, rdx               ; Offset: 0 (Start from beginning of file)
    mov r10, [statbuff + 48]   ; File size: Located at offset 48 in x86_64 stat struct
    syscall
    ret

print_ip:
    ; The IP is located 4 bytes into the sockaddr_in structure
    lea rsi, [client_addr + 4]
    mov rcx, 4                 ; IP has 4 octets

.next_byte:
    push rcx                   ; Preserve loop counter
    push rsi                   ; Preserve string pointer
    
    movzx rax, byte [rsi]      ; Load one byte (octet) into RAX (0-255)
    call print_decimal         ; Convert integer to string and print it
    
    pop rsi                    ; Restore string pointer
    pop rcx                    ; Restore loop counter
    
    dec rcx                    ; Decrement octet counter
    jz .done                   ; If 0, we printed all 4 octets, do not print a dot
    
    ; Print the dot separator "."
    push rcx
    push rsi
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; FD 1 (stdout)
    lea rsi, [dot]             ; "." character
    mov rdx, 1
    syscall
    pop rsi
    pop rcx
    
    inc rsi                    ; Move to the next octet
    jmp .next_byte
.done:
    ret

print_decimal:
    ; Converts value in RAX to decimal ASCII and prints to stdout
    mov rbx, 10                ; Divisor for base 10
    mov rcx, 0                 ; Digit counter
.div_loop:
    xor rdx, rdx               ; Clear RDX before division
    div rbx                    ; Divide RAX by 10. Quotient in RAX, Remainder in RDX
    push rdx                   ; Push remainder (digit) to stack
    inc rcx                    ; Increment digit counter
    test rax, rax              ; Check if quotient is 0
    jnz .div_loop              ; If not, continue extracting digits

.print_loop:
    pop rdx                    ; Pop digits in reverse order (most significant first)
    add dl, '0'                ; Convert integer (0-9) to ASCII character ('0'-'9')
    mov [ip_string], dl        ; Temporarily store char in buffer
    
    push rcx                   ; Preserve counter during syscall
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; FD 1 (stdout)
    lea rsi, [ip_string]       ; Pointer to the character
    mov rdx, 1                 ; Length = 1 byte
    syscall
    pop rcx                    ; Restore counter
    
    loop .print_loop           ; Repeat for all digits
    ret

open_error:                
    ; Handler for file not found (sys_open failed)
    mov rax, 1                 ; sys_write
    mov rdi, [socketfd_no]     ; Send to client socket
    lea rsi, [msg_404]         ; HTTP 404 Response Header & Body
    mov rdx, len_404
    syscall

    mov rax, 3                 ; sys_close
    mov rdi, [socketfd_no]     ; Close client socket immediately
    syscall
    jmp server_loop            ; Go back and wait for next client
    
_exit:
    ; Graceful exit for critical errors
    mov rax, 60                ; sys_exit
    xor rdi, rdi               ; Exit code 0
    syscall
