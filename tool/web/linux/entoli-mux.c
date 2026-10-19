/*
 * entoli-mux: the guest end of the browser's Linux. It runs as PID 1 and
 * carries every process the app starts over one serial line, so a chat's
 * shell, a sub-agent's one-shot and the next chat's shell can all be running
 * at once. See "The browser's Linux" in lib/data/web/AGENTS.md.
 *
 * One frame per line, fields space-separated, anything binary in base64:
 *
 *   host -> guest              guest -> host
 *   O id argv cwd env          R             ready
 *   I id data                  D id data     output (stdout and stderr)
 *   C id      close stdin      E id          output closed
 *   K id sig  signal group     X id code     exited (128+n for signal n)
 *   P         ping             F id msg      could not start
 *                              P             pong
 *
 * argv and env are NUL-separated lists. The serial line is never allowed to
 * back up: a child that is not reading its stdin has the bytes held here
 * rather than stalling the read of the line, since the guest's tty drops what
 * arrives while nobody reads it.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

struct buf {
	char *data;
	size_t len, cap;
};

struct proc {
	uint32_t id;
	pid_t pid;
	int in, out;
	struct buf pending;
	int close_in;
	int exited;
};

static int tty_in = -1, tty_out = -1;
static int sig_pipe[2];
static struct proc *procs;
static size_t nprocs, capprocs;

static void buf_reserve(struct buf *b, size_t more)
{
	if (b->len + more <= b->cap)
		return;
	size_t cap = b->cap ? b->cap : 4096;
	while (cap < b->len + more)
		cap *= 2;
	b->data = realloc(b->data, cap);
	if (!b->data)
		abort();
	b->cap = cap;
}

static void buf_add(struct buf *b, const char *data, size_t len)
{
	buf_reserve(b, len);
	memcpy(b->data + b->len, data, len);
	b->len += len;
}

static void buf_drop(struct buf *b, size_t n)
{
	memmove(b->data, b->data + n, b->len - n);
	b->len -= n;
}

static const char b64[] =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static size_t b64_encode(const unsigned char *in, size_t len, char *out)
{
	size_t o = 0;
	for (size_t i = 0; i < len; i += 3) {
		uint32_t v = in[i] << 16;
		if (i + 1 < len)
			v |= in[i + 1] << 8;
		if (i + 2 < len)
			v |= in[i + 2];
		out[o++] = b64[v >> 18 & 63];
		out[o++] = b64[v >> 12 & 63];
		out[o++] = i + 1 < len ? b64[v >> 6 & 63] : '=';
		out[o++] = i + 2 < len ? b64[v & 63] : '=';
	}
	return o;
}

static int b64_value(char c)
{
	if (c >= 'A' && c <= 'Z')
		return c - 'A';
	if (c >= 'a' && c <= 'z')
		return c - 'a' + 26;
	if (c >= '0' && c <= '9')
		return c - '0' + 52;
	if (c == '+')
		return 62;
	if (c == '/')
		return 63;
	return -1;
}

/* Decodes in place; returns the length, or -1 on a malformed field. */
static ssize_t b64_decode(char *s)
{
	size_t o = 0;
	uint32_t v = 0;
	int bits = 0;
	for (char *p = s; *p && *p != '='; p++) {
		int d = b64_value(*p);
		if (d < 0)
			return -1;
		v = v << 6 | d;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			s[o++] = v >> bits & 0xff;
		}
	}
	return o;
}

static void write_all(int fd, const char *data, size_t len)
{
	while (len) {
		ssize_t n = write(fd, data, len);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return;
		}
		data += n;
		len -= n;
	}
}

static void frame(char op, uint32_t id, const char *field, size_t len)
{
	static struct buf line;
	char head[32];
	int n = snprintf(head, sizeof head, "%c %u", op, id);
	line.len = 0;
	buf_add(&line, head, n);
	if (field) {
		buf_add(&line, " ", 1);
		buf_reserve(&line, (len + 2) / 3 * 4);
		line.len += b64_encode((const unsigned char *)field, len, line.data + line.len);
	}
	buf_add(&line, "\n", 1);
	write_all(tty_out, line.data, line.len);
}

static void frame_number(char op, uint32_t id, int number)
{
	char line[48];
	int n = snprintf(line, sizeof line, "%c %u %d\n", op, id, number);
	write_all(tty_out, line, n);
}

static struct proc *find(uint32_t id)
{
	for (size_t i = 0; i < nprocs; i++)
		if (procs[i].id == id)
			return &procs[i];
	return NULL;
}

static void reap_finished(void)
{
	for (size_t i = 0; i < nprocs;) {
		struct proc *p = &procs[i];
		if (p->exited && p->out < 0) {
			if (p->in >= 0)
				close(p->in);
			free(p->pending.data);
			procs[i] = procs[--nprocs];
			continue;
		}
		i++;
	}
}

/* NUL-separated fields into a NULL-terminated vector, in place. */
static char **split(char *s, size_t len)
{
	size_t n = 0;
	for (size_t i = 0; i < len; i++)
		if (s[i] == '\0')
			n++;
	if (len && s[len - 1] != '\0')
		n++;
	char **v = calloc(n + 1, sizeof *v);
	size_t k = 0;
	for (size_t i = 0; i < len && k < n;) {
		v[k++] = s + i;
		while (i < len && s[i])
			i++;
		i++;
	}
	return v;
}

static void spawn(uint32_t id, char *argv_b64, char *cwd_b64, char *env_b64)
{
	ssize_t argv_len = b64_decode(argv_b64);
	ssize_t cwd_len = b64_decode(cwd_b64);
	ssize_t env_len = env_b64 ? b64_decode(env_b64) : 0;
	if (argv_len <= 0 || cwd_len < 0 || env_len < 0) {
		const char *msg = "malformed spawn";
		frame('F', id, msg, strlen(msg));
		return;
	}
	argv_b64[argv_len] = '\0';
	cwd_b64[cwd_len] = '\0';
	if (env_b64)
		env_b64[env_len] = '\0';
	char **argv = split(argv_b64, argv_len);
	char **envp = env_b64 ? split(env_b64, env_len) : calloc(1, sizeof *envp);

	int in[2], out[2], err[2];
	if (pipe2(in, O_CLOEXEC) || pipe2(out, O_CLOEXEC) || pipe2(err, O_CLOEXEC)) {
		const char *msg = strerror(errno);
		frame('F', id, msg, strlen(msg));
		free(argv);
		free(envp);
		return;
	}
	pid_t pid = fork();
	if (pid == 0) {
		sigset_t none;
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		signal(SIGPIPE, SIG_DFL);
		signal(SIGCHLD, SIG_DFL);
		signal(SIGINT, SIG_DFL);
		signal(SIGTERM, SIG_DFL);
		signal(SIGHUP, SIG_DFL);
		setsid();
		dup2(in[0], 0);
		dup2(out[1], 1);
		dup2(out[1], 2);
		if (cwd_len && chdir(cwd_b64) != 0) {
			int e = errno;
			write_all(err[1], (char *)&e, sizeof e);
			_exit(127);
		}
		execve(argv[0], argv, envp);
		int e = errno;
		write_all(err[1], (char *)&e, sizeof e);
		_exit(127);
	}
	close(in[0]);
	close(out[1]);
	close(err[1]);
	free(argv);
	free(envp);
	int e = 0;
	ssize_t got;
	do
		got = read(err[0], &e, sizeof e);
	while (got < 0 && errno == EINTR);
	close(err[0]);
	if (pid < 0 || got > 0) {
		const char *msg = strerror(pid < 0 ? errno : e);
		frame('F', id, msg, strlen(msg));
		close(in[1]);
		close(out[0]);
		/* The failed child is reaped by the loop and matches nothing. */
		return;
	}
	fcntl(in[1], F_SETFL, O_NONBLOCK);
	fcntl(out[0], F_SETFL, O_NONBLOCK);
	if (nprocs == capprocs) {
		capprocs = capprocs ? capprocs * 2 : 16;
		procs = realloc(procs, capprocs * sizeof *procs);
	}
	procs[nprocs++] = (struct proc){ .id = id, .pid = pid, .in = in[1], .out = out[0] };
}

static void flush_stdin(struct proc *p)
{
	while (p->in >= 0 && p->pending.len) {
		ssize_t n = write(p->in, p->pending.data, p->pending.len);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN)
				return;
			/* The reader is gone; what it never read goes with it. */
			p->pending.len = 0;
			break;
		}
		buf_drop(&p->pending, n);
	}
	if (p->in >= 0 && p->close_in && !p->pending.len) {
		close(p->in);
		p->in = -1;
	}
}

static void handle(char *line)
{
	char *save, *op = strtok_r(line, " ", &save);
	if (!op)
		return;
	if (op[0] == 'P') {
		write_all(tty_out, "P\n", 2);
		return;
	}
	char *id_s = strtok_r(NULL, " ", &save);
	if (!id_s)
		return;
	uint32_t id = strtoul(id_s, NULL, 10);
	char *a = strtok_r(NULL, " ", &save);
	struct proc *p = find(id);
	switch (op[0]) {
	case 'O': {
		char *cwd = strtok_r(NULL, " ", &save);
		char *env = strtok_r(NULL, " ", &save);
		if (p) {
			const char *msg = "id in use";
			frame('F', id, msg, strlen(msg));
		} else if (a && cwd) {
			spawn(id, a, cwd, env);
		}
		break;
	}
	case 'I':
		if (p && a && p->in >= 0) {
			ssize_t n = b64_decode(a);
			if (n > 0) {
				buf_add(&p->pending, a, n);
				flush_stdin(p);
			}
		}
		break;
	case 'C':
		if (p) {
			p->close_in = 1;
			flush_stdin(p);
		}
		break;
	case 'K':
		if (p && a && !p->exited) {
			int sig = atoi(a);
			if (kill(-p->pid, sig) != 0)
				kill(p->pid, sig);
		}
		break;
	}
}

static void on_child(int sig)
{
	(void)sig;
	int saved = errno;
	char c = 0;
	(void)!write(sig_pipe[1], &c, 1);
	errno = saved;
}

static void reap(void)
{
	char drain[64];
	while (read(sig_pipe[0], drain, sizeof drain) > 0)
		;
	int status;
	pid_t pid;
	while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
		for (size_t i = 0; i < nprocs; i++) {
			struct proc *p = &procs[i];
			if (p->pid != pid)
				continue;
			p->exited = 1;
			int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
			frame_number('X', p->id, code);
		}
	}
}

static void open_tty(const char *path)
{
	tty_out = open(path, O_WRONLY | O_NOCTTY | O_CLOEXEC);
	tty_in = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
	if (tty_in < 0 || tty_out < 0) {
		perror(path);
		for (;;)
			pause();
	}
	struct termios t;
	if (tcgetattr(tty_in, &t) == 0) {
		cfmakeraw(&t);
		tcsetattr(tty_in, TCSANOW, &t);
	}
}

int main(int argc, char **argv)
{
	open_tty(argc > 1 ? argv[1] : "/dev/ttyS1");
	if (pipe2(sig_pipe, O_CLOEXEC | O_NONBLOCK))
		return 1;
	signal(SIGPIPE, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	signal(SIGTERM, SIG_IGN);
	signal(SIGHUP, SIG_IGN);
	struct sigaction sa = { .sa_handler = on_child, .sa_flags = SA_RESTART | SA_NOCLDSTOP };
	sigaction(SIGCHLD, &sa, NULL);
	write_all(tty_out, "R\n", 2);

	struct buf line = { 0 };
	struct pollfd *fds = NULL;
	size_t capfds = 0;
	char chunk[3072];
	for (;;) {
		size_t want = 2 + nprocs * 2;
		if (want > capfds) {
			capfds = want * 2;
			fds = realloc(fds, capfds * sizeof *fds);
		}
		size_t n = 0;
		fds[n++] = (struct pollfd){ .fd = tty_in, .events = POLLIN };
		fds[n++] = (struct pollfd){ .fd = sig_pipe[0], .events = POLLIN };
		for (size_t i = 0; i < nprocs; i++) {
			if (procs[i].out >= 0)
				fds[n++] = (struct pollfd){ .fd = procs[i].out, .events = POLLIN };
			if (procs[i].in >= 0 && procs[i].pending.len)
				fds[n++] = (struct pollfd){ .fd = procs[i].in, .events = POLLOUT };
		}
		if (poll(fds, n, -1) < 0) {
			if (errno == EINTR)
				continue;
			return 1;
		}
		if (fds[1].revents)
			reap();
		/* Output before input: a child's last words reach the host before the
		 * exit frame the next round would otherwise send ahead of them. */
		for (size_t i = 0; i < nprocs; i++) {
			struct proc *p = &procs[i];
			if (p->in >= 0 && p->pending.len)
				flush_stdin(p);
			/* Bounded, so a child that never stops printing cannot starve the
			 * read of the line below. */
			for (int round = 0; round < 16 && p->out >= 0; round++) {
				ssize_t got = read(p->out, chunk, sizeof chunk);
				if (got > 0) {
					frame('D', p->id, chunk, got);
					continue;
				}
				if (got < 0 && (errno == EAGAIN || errno == EINTR))
					break;
				close(p->out);
				p->out = -1;
				frame('E', p->id, NULL, 0);
			}
		}
		if (fds[0].revents) {
			for (;;) {
				char in[4096];
				ssize_t got = read(tty_in, in, sizeof in);
				if (got <= 0)
					break;
				size_t start = line.len;
				buf_add(&line, in, got);
				for (size_t i = start; i < line.len; i++) {
					if (line.data[i] != '\n')
						continue;
					line.data[i] = '\0';
					handle(line.data);
					buf_drop(&line, i + 1);
					i = (size_t)-1;
				}
			}
		}
		reap_finished();
	}
}
