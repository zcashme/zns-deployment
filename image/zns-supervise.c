/* Keep zebrad, zns-mint, and the metrics forwarder running.
 * Restart a process that exits. Restart one that was healthy and then fails
 * three checks. Leave Zebra alone while it is still syncing.
 */
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CHECK_INTERVAL 30
#define FAIL_LIMIT 3

static const char *ZEBRA = "/usr/local/bin/zebrad";
static const char *MINT = "/usr/local/bin/zns-mint";
static const char *FORWARD = "/usr/local/bin/zns-forward";

static int zebra_ready = 0;
static int zebra_misses = 0;
static int mint_ready = 0;
static int mint_misses = 0;

static void log_msg(const char *text) {
  fprintf(stderr, "[supervise] %s\n", text);
}

static int cmdline_is(int pid, const char *path) {
  char file[64];
  snprintf(file, sizeof file, "/proc/%d/cmdline", pid);
  int fd = open(file, O_RDONLY);
  if (fd < 0) {
    return 0;
  }
  char buf[256];
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n <= 0) {
    return 0;
  }
  buf[n] = '\0';
  return strcmp(buf, path) == 0;
}

static int is_zombie(int pid) {
  char file[64];
  snprintf(file, sizeof file, "/proc/%d/status", pid);
  FILE *fp = fopen(file, "r");
  if (fp == NULL) {
    return 1;
  }
  char line[256];
  int zombie = 0;
  while (fgets(line, sizeof line, fp) != NULL) {
    if (strncmp(line, "State:", 6) != 0) {
      continue;
    }
    char *p = line + 6;
    while (*p == ' ' || *p == '\t') {
      p++;
    }
    zombie = (*p == 'Z');
    break;
  }
  fclose(fp);
  return zombie;
}

static int living_pid(const char *path) {
  DIR *dir = opendir("/proc");
  if (dir == NULL) {
    return -1;
  }
  int found = -1;
  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL) {
    char *end = NULL;
    long pid = strtol(ent->d_name, &end, 10);
    if (end == ent->d_name || *end != '\0' || pid <= 1) {
      continue;
    }
    if (is_zombie((int)pid)) {
      continue;
    }
    if (cmdline_is((int)pid, path)) {
      found = (int)pid;
      break;
    }
  }
  closedir(dir);
  return found;
}

static void reap(void) {
  int status;
  while (waitpid(-1, &status, WNOHANG) > 0) {
  }
}

static void pause_ms(int ms) {
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  select(0, NULL, NULL, NULL, &tv);
}

static void stop_pid(int pid) {
  if (pid <= 1) {
    return;
  }
  kill(pid, SIGTERM);
  for (int i = 0; i < 50; i++) {
    int status;
    pid_t got = waitpid(pid, &status, WNOHANG);
    if (got == pid || (got < 0 && errno == ECHILD)) {
      return;
    }
    if (kill(pid, 0) != 0) {
      return;
    }
    pause_ms(100);
  }
  kill(pid, SIGKILL);
  for (int i = 0; i < 50; i++) {
    int status;
    pid_t got = waitpid(pid, &status, WNOHANG);
    if (got == pid || (got < 0 && errno == ECHILD) || kill(pid, 0) != 0) {
      return;
    }
    pause_ms(100);
  }
}

static void spawn(const char *log_path, const char *workdir, char **argv) {
  pid_t pid = fork();
  if (pid < 0) {
    perror("fork");
    return;
  }
  if (pid > 0) {
    return;
  }
  int logfd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (logfd >= 0) {
    dup2(logfd, STDOUT_FILENO);
    dup2(logfd, STDERR_FILENO);
    if (logfd > 2) {
      close(logfd);
    }
  }
  int in = open("/dev/null", O_RDONLY);
  if (in >= 0) {
    dup2(in, STDIN_FILENO);
    if (in > 2) {
      close(in);
    }
  }
  if (workdir != NULL && chdir(workdir) != 0) {
    _exit(127);
  }
  setsid();
  execv(argv[0], argv);
  _exit(127);
}

static int http_ok(int port, const char *path) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return 0;
  }
  struct timeval tv;
  tv.tv_sec = 2;
  tv.tv_usec = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    close(fd);
    return 0;
  }
  char req[128];
  int len = snprintf(req, sizeof req, "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", path);
  if (len < 0 || (size_t)len >= sizeof req || write(fd, req, (size_t)len) != len) {
    close(fd);
    return 0;
  }
  char buf[64];
  ssize_t n = read(fd, buf, sizeof buf - 1);
  close(fd);
  if (n < 12) {
    return 0;
  }
  buf[n] = '\0';
  return strncmp(buf, "HTTP/1.0 200", 12) == 0 || strncmp(buf, "HTTP/1.1 200", 12) == 0;
}

static int ceremony_complete(void) {
  FILE *fp = fopen("/state/keys/ceremony_state.toml", "r");
  if (fp == NULL) {
    return 0;
  }
  char line[256];
  int complete = 0;
  while (fgets(line, sizeof line, fp) != NULL) {
    if (strcmp(line, "state = \"COMPLETE\"\n") == 0) {
      complete = 1;
    }
  }
  fclose(fp);
  return complete;
}

static void ensure_forward(void) {
  if (living_pid(FORWARD) > 0) {
    return;
  }
  log_msg("starting metrics forwarder");
  char *argv[] = {"/usr/local/bin/zns-forward", NULL};
  spawn("/state/log/metrics.log", NULL, argv);
}

static void ensure_mint(void) {
  if (!zebra_ready || !ceremony_complete()) {
    return;
  }
  int pid = living_pid(MINT);
  if (pid < 0) {
    log_msg("starting mint");
    mint_ready = 0;
    mint_misses = 0;
    char *argv[] = {"/usr/local/bin/zns-mint", NULL};
    spawn("/state/log/mint.log", "/state", argv);
    return;
  }
  if (http_ok(9464, "/metrics")) {
    if (!mint_ready) {
      log_msg("mint metrics are up");
    }
    mint_ready = 1;
    mint_misses = 0;
    return;
  }
  if (!mint_ready) {
    return;
  }
  mint_misses++;
  if (mint_misses < FAIL_LIMIT) {
    return;
  }
  log_msg("mint metrics failed, restarting mint");
  stop_pid(pid);
  mint_ready = 0;
  mint_misses = 0;
  char *argv[] = {"/usr/local/bin/zns-mint", NULL};
  spawn("/state/log/mint.log", "/state", argv);
}

static void ensure_zebra(void) {
  int pid = living_pid(ZEBRA);
  if (pid < 0) {
    log_msg("starting zebra");
    zebra_ready = 0;
    zebra_misses = 0;
    mint_ready = 0;
    mint_misses = 0;
    char *argv[] = {"/usr/local/bin/zebrad", "-c", "/etc/zebra/zebrad.toml", "start", NULL};
    spawn("/state/log/zebra.log", NULL, argv);
    return;
  }
  if (http_ok(8080, "/ready")) {
    if (!zebra_ready) {
      log_msg("zebra is ready");
    }
    zebra_ready = 1;
    zebra_misses = 0;
    return;
  }
  if (!zebra_ready) {
    return;
  }
  zebra_misses++;
  if (zebra_misses < FAIL_LIMIT) {
    return;
  }
  log_msg("zebra lost readiness, restarting zebra and mint");
  stop_pid(pid);
  int mint = living_pid(MINT);
  if (mint > 0) {
    stop_pid(mint);
  }
  zebra_ready = 0;
  zebra_misses = 0;
  mint_ready = 0;
  mint_misses = 0;
  char *argv[] = {"/usr/local/bin/zebrad", "-c", "/etc/zebra/zebrad.toml", "start", NULL};
  spawn("/state/log/zebra.log", NULL, argv);
}

int main(void) {
  setvbuf(stderr, NULL, _IONBF, 0);
  mkdir("/state/log", 0755);
  log_msg("supervisor started");
  for (;;) {
    reap();
    ensure_zebra();
    ensure_forward();
    ensure_mint();
    sync();
    sleep(CHECK_INTERVAL);
  }
}
