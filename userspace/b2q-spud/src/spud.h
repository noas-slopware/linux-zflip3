// SPDX-License-Identifier: MIT
#pragma once
#include <stddef.h>
#include <stdint.h>

#define spud_log(fmt, ...) fprintf(stderr, "b2q-spud: " fmt "\n", ##__VA_ARGS__)

struct nvm_part;
struct nvm_part *nvm_new(const char *channel);
/* One sec_nvm request in, its reply out (0 = none) */
size_t nvm_handle(struct nvm_part *p, const uint8_t *req, size_t len, uint8_t *rsp, size_t rsp_cap);
/* The SPSS kernel partition is open and committed or initialized (stock NVM_READY) */
int nvm_ready(const struct nvm_part *p);
