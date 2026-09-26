/*	$NetBSD: bl.c,v 1.9 2025/03/30 01:53:59 christos Exp $	*/

/*-
 * Copyright (c) 2014 The NetBSD Foundation, Inc.
 * All rights reserved.
 *
 * This code is derived from software contributed to The NetBSD Foundation
 * by Christos Zoulas.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE NETBSD FOUNDATION, INC. AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#ifdef HAVE_SYS_CDEFS_H
#include <sys/cdefs.h>
#endif
__RCSID("$NetBSD: bl.c,v 1.9 2025/03/30 01:53:59 christos Exp $");

#include <sys/param.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

#include <stdio.h>
#include <string.h>
#include <syslog.h>
#include <signal.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <stdarg.h>
#include <netinet/in.h>
#ifdef _REENTRANT
#include <pthread.h>
#endif

#if defined(SO_RECVUCRED)
#include <ucred.h>
#endif

#include "bl.h"
#include "bl_listen.h"

typedef struct {
	uint32_t bl_len;
	uint32_t bl_version;
	uint32_t bl_type;
	uint32_t bl_salen;
	struct sockaddr_storage bl_ss;
	char bl_data[];
} bl_message_t;

struct blocklist {
#ifdef _REENTRANT
	pthread_mutex_t b_mutex;
# define BL_INIT(b)	pthread_mutex_init(&b->b_mutex, NULL)
# define BL_LOCK(b)	pthread_mutex_lock(&b->b_mutex)
# define BL_UNLOCK(b)	pthread_mutex_unlock(&b->b_mutex)
#else
# define BL_INIT(b)	do {} while(/*CONSTCOND*/0)
# define BL_LOCK(b)	BL_INIT(b)
# define BL_UNLOCK(b)	BL_INIT(b)
#endif
	int b_fd;
	int b_connected;
	int b_inherited;
	struct sockaddr_un b_sun;
	struct syslog_data b_syslog_data;
	void (*b_fun)(int, struct syslog_data *, const char *, va_list);
	bl_info_t b_info;
};

#define BL_VERSION	1

bool
bl_isconnected(bl_t b)
{
	return b->b_connected == 0;
}
