/* stdout, stdin and stderr for the picolibc stdio (printf, puts, putchar).
 *
 * The core has no output device, so output goes to a buffer in RAM that
 * the host reads over JTAG once the test is over: a fixed region at the
 * top of RAM, just below the words the boot ROM clears (mailbox, go flag,
 * tohost, fromhost). rv32im-fpga.specs leaves it out of RAM's size, so
 * the stack never reaches it. The boot ROM clears the header on every
 * start.
 *
 *   0x43FFFBE0  length     bytes written, at most STDOUT_SIZE
 *   0x43FFFBE4  truncated  1 once a byte did not fit, 0 otherwise
 *   0x43FFFBE8  data       STDOUT_SIZE bytes
 *
 * The buffer is linear: when it is full, further bytes are dropped and
 * `truncated` is set. There is no input: reads report end of file.
 */
#include <stdint.h>
#include <stdio.h>
#include <sys/cdefs.h>

#define STDOUT_BASE 0x43FFFBE0u
#define STDOUT_SIZE 1024u

struct stdout_buffer {
    volatile uint32_t length;
    volatile uint32_t truncated;
    volatile char data[STDOUT_SIZE];
};

static int rv32_putc(char c, FILE *file)
{
    struct stdout_buffer *buf = (struct stdout_buffer *)STDOUT_BASE;
    uint32_t length = buf->length;

    (void)file;
    if (length < STDOUT_SIZE) {
        buf->data[length] = c;
        buf->length = length + 1u;
    } else {
        buf->truncated = 1u;
    }
    return (unsigned char)c;
}

static int rv32_getc(FILE *file)
{
    (void)file;
    return _FDEV_EOF;
}

static FILE rv32_stdio = FDEV_SETUP_STREAM(rv32_putc, rv32_getc, NULL, _FDEV_SETUP_RW);

FILE *const stdin = &rv32_stdio;
__strong_reference(stdin, stdout);
__strong_reference(stdin, stderr);
