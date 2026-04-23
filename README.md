## Bare-Metal Assembly HTTP Server
When we need to quickly share files or serve a local directory, we often rely on the convenient python -m http.server command. But how does that "magic" actually work under the hood at the operating system level?

This project is an experiment in recreating the core functionality of a standard HTTP server without using any external libraries (not even libc), relying purely on x86_64 Assembly and direct Linux System Calls (Syscalls).

It strips away the abstractions provided by modern programming languages, handling networking, memory management, and file I/O directly at the kernel level.

## Features
Zero-Copy File Transfer: Instead of reading files into user-space memory and then writing them to a socket, it utilizes sys_sendfile for high-performance, direct kernel-level data transfer.

Live Logging: Dynamically parses the connected client's IPv4 address (converting it from binary to ASCII) and prints the raw incoming HTTP GET requests directly to the terminal (stdout).

Security (Path Traversal Protection): Scans incoming requests for ../ sequences to prevent directory climbing and unauthorized access to critical system files (e.g., /etc/passwd).

HTTP Status Management: Dynamically responds with standard 200 OK headers for successful file requests and 404 Not Found for missing files.

Zero Dependencies: Requires nothing but the Linux kernel.

Under the Hood: The Syscall Arsenal
This server speaks directly to the Linux kernel using the following x86_64 system calls:

## Networking:

sys_socket (41): Creates the TCP (IPv4) endpoint.

sys_bind (49): Binds the server to 0.0.0.0:8080 (handling Big-Endian network byte order conversions).

sys_listen (50): Initializes the backlog queue for incoming connections.

sys_accept (43): Accepts a client connection and generates a new dedicated file descriptor (FD).

File & I/O Operations:

sys_read (0): Reads the raw HTTP GET request from the client socket into a buffer.

sys_write (1): Used for printing live logs to the terminal and sending HTTP headers to the browser.

sys_open (2): Opens the requested file from the disk in read-only (O_RDONLY) mode.

sys_close (3): Closes sockets and file descriptors after each transaction to prevent FD leaks.

sys_fstat (5): Retrieves file metadata to calculate the exact st_size (file size) before transmission.

sys_sendfile (40): The star of I/O performance. Blasts the file content directly from the disk FD to the socket FD.

System:

sys_exit (60): Safely terminates the program in case of a critical failure.

## How to Build and Run
The easiest way to build and manage this server is by using the provided Makefile. You will need nasm (Netwide Assembler), ld (GNU Linker), and make installed on your Linux system.
### 1. Build the Server
Compiles the assembly source and links the object file into an executable named server:

```bash
make
```
### 2. Run the Server
Compiles (if necessary) and immediately starts the server on port 8080:

```bash
make run
```
### 3. Clean Build Files
Removes the executable and the .o object files to keep your directory clean:

```bash
make clean
```
### 4. Manual Build (Without Make)
If you prefer to run the commands manually:

```bash
nasm -f elf64 server.asm -o server.o
ld server.o -o server
./server
```

### Testing the Server
Once the server is running, you can test it from another terminal using curl or by visiting http://localhost:8080/your_file.txt in your web browser.

Fetch a file and display in terminal:
```bash
curl http://localhost:8080/randomfile.txt
```

Download and save with the original filename:
```bash
curl -O http://localhost:8080/randomfile.txt
```
See the raw HTTP headers (useful for debugging):
```bash
curl -v http://localhost:8080/randomfile.txt
```

**Resource:**
https://netacoding.com/posts/assembly-httpserver/