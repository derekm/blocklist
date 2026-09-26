/* systemd socket activation for bl_create() — Linux port only, no libsystemd. */
#ifndef BL_LISTEN_H
#define BL_LISTEN_H

#ifndef SD_LISTEN_FDS_START
#define SD_LISTEN_FDS_START 3
#endif

static int
bl_take_listen_fd(bl_t b)
{
	static int next;
	const char *pid_s, *fds_s;
	char *ep;
	long pid, n;
	int i;

	pid_s = getenv("LISTEN_PID");
	fds_s = getenv("LISTEN_FDS");
	if (pid_s == NULL || fds_s == NULL)
		return -1;
	pid = strtol(pid_s, &ep, 10);
	if (ep == pid_s || *ep != '\0' || pid != (long)getpid())
		return -1;
	n = strtol(fds_s, &ep, 10);
	if (ep == fds_s || *ep != '\0' || n < 1)
		return -1;

	for (i = next; i < (int)n; i++) {
		int fd = SD_LISTEN_FDS_START + i;
		struct sockaddr_un un;
		socklen_t slen, tlen;
		int type;

		type = 0;
		tlen = (socklen_t)sizeof(type);
		if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tlen) == -1)
			continue;
		if (type != SOCK_DGRAM)
			continue;
		memset(&un, 0, sizeof(un));
		slen = (socklen_t)sizeof(un);
		if (getsockname(fd, (struct sockaddr *)&un, &slen) == -1)
			continue;
		if (un.sun_family != AF_LOCAL && un.sun_family != AF_UNIX)
			continue;
		if (b->b_sun.sun_path[0] != '\0' && un.sun_path[0] != '\0' &&
		    strcmp(un.sun_path, b->b_sun.sun_path) != 0)
			continue;
		(void)fcntl(fd, F_SETFD, FD_CLOEXEC);
		(void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
		next = i + 1;
		return fd;
	}
	return -1;
}

#endif /* BL_LISTEN_H */
