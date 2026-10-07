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
 *
 * Every byte also goes to the JTAG UART at 0xC0000000, which a host console reads while the
 * program runs. The UART is a live view: the buffer stays the copy the test checks. A program
 * prints to the UART only once a host has scanned it (bit 17 of the status register), so one with
 * nobody listening is never slowed down; once someone listens it waits for a free place in the
 * queue, up to a bound, then drops the byte. Spike has no such device: its build skips the UART.
 */
#include <stdint.h>
#include <stdio.h>
#include <sys/cdefs.h>

#define STDOUT_BASE 0x43FFFBE0u
#define STDOUT_SIZE 1024u

#define UART_TXDATA ((volatile uint32_t *)0xC0000000u)
#define UART_STATUS ((volatile uint32_t *)0xC0000008u)
#define UART_FREE(status)     ((status) & 0xFFu)
#define UART_ATTACHED(status) (((status) >> 17) & 1u)
#define UART_WAIT_POLLS 200000u

struct stdout_buffer {
    volatile uint32_t length;
    volatile uint32_t truncated;
    volatile char data[STDOUT_SIZE];
};

#ifndef RV32_SPIKE
static void uart_put(char c)
{
    uint32_t status = *UART_STATUS;

    if (!UART_ATTACHED(status))
        return;
    for (uint32_t polls = 0; UART_FREE(status) == 0; polls++) {
        if (polls == UART_WAIT_POLLS)
            return;
        status = *UART_STATUS;
    }
    *UART_TXDATA = (uint8_t)c;
}
#else
static void uart_put(char c) { (void)c; }
#endif

static int rv32_putc(char c, FILE *file)
{
    struct stdout_buffer *buf = (struct stdout_buffer *)STDOUT_BASE;
    uint32_t length = buf->length;

    (void)file;
    uart_put(c);
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
