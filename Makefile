# Assembler and Linker definitions
ASM = nasm
LD = ld
ASM_FLAGS = -f elf64
TARGET = server
OBJ = server.o
SRC = server.asm

# Default target
all: $(TARGET)

# Link the object file to create the executable
$(TARGET): $(OBJ)
	$(LD) $(OBJ) -o $(TARGET)

# Assemble the source file
$(OBJ): $(SRC)
	$(ASM) $(ASM_FLAGS) $(SRC) -o $(OBJ)

# Clean up build files
clean:
	rm -f $(OBJ) $(TARGET)

# Run the server
run: all
	./$(TARGET)

.PHONY: all clean run
