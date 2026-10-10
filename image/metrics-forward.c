/* Publish the loopback metrics ports where QEMU's host forward can reach them.
 * 0.0.0.0:9465 splices to mint at 127.0.0.1:9464.
 * 0.0.0.0:9998 splices to Zebra at 127.0.0.1:9999.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

struct relay {
  int listen_port;
  int upstream_port;
  int fd;
};

static void splice_both(int left, int right) {
  char buf[8192];
  for (;;) {
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(left, &fds);
    FD_SET(right, &fds);
    int max = left > right ? left : right;
    if (select(max + 1, &fds, NULL, NULL, NULL) < 0) {
      if (errno == EINTR) {
        continue;
      }
      return;
    }
    int pairs[2][2] = {{left, right}, {right, left}};
    for (int i = 0; i < 2; i++) {
      int from = pairs[i][0];
      int to = pairs[i][1];
      if (!FD_ISSET(from, &fds)) {
        continue;
      }
      ssize_t n = read(from, buf, sizeof buf);
      if (n <= 0) {
        return;
      }
      ssize_t off = 0;
      while (off < n) {
        ssize_t wrote = write(to, buf + off, (size_t)(n - off));
        if (wrote < 0) {
          if (errno == EINTR) {
            continue;
          }
          return;
        }
        off += wrote;
      }
    }
  }
}

static int listen_on(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short)port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 16) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static int connect_loopback(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static void serve(struct relay *relays, int count) {
  for (;;) {
    fd_set fds;
    FD_ZERO(&fds);
    int max = -1;
    for (int i = 0; i < count; i++) {
      FD_SET(relays[i].fd, &fds);
      if (relays[i].fd > max) {
        max = relays[i].fd;
      }
    }
    if (select(max + 1, &fds, NULL, NULL, NULL) < 0) {
      if (errno == EINTR) {
        continue;
      }
      perror("select");
      return;
    }
    for (int i = 0; i < count; i++) {
      if (!FD_ISSET(relays[i].fd, &fds)) {
        continue;
      }
      int client = accept(relays[i].fd, NULL, NULL);
      if (client < 0) {
        if (errno == EINTR) {
          continue;
        }
        perror("accept");
        return;
      }
      pid_t pid = fork();
      if (pid < 0) {
        close(client);
        continue;
      }
      if (pid > 0) {
        close(client);
        continue;
      }
      for (int j = 0; j < count; j++) {
        close(relays[j].fd);
      }
      int upstream = connect_loopback(relays[i].upstream_port);
      if (upstream < 0) {
        close(client);
        _exit(1);
      }
      splice_both(client, upstream);
      _exit(0);
    }
  }
}

int main(void) {
  signal(SIGCHLD, SIG_IGN);
  struct relay relays[] = {
      {.listen_port = 9465, .upstream_port = 9464, .fd = -1},
      {.listen_port = 9998, .upstream_port = 9999, .fd = -1},
  };
  int count = (int)(sizeof relays / sizeof relays[0]);
  for (int i = 0; i < count; i++) {
    relays[i].fd = listen_on(relays[i].listen_port);
    if (relays[i].fd < 0) {
      perror("listen");
      return 1;
    }
    fprintf(stderr, "[metrics] forwarding 0.0.0.0:%d to 127.0.0.1:%d\n", relays[i].listen_port,
            relays[i].upstream_port);
  }
  serve(relays, count);
  return 1;
}
