/*
 * TouchBridge Digitizer serial protocol (host <-> dongle over USB CDC ACM).
 * Pure C, no Zephyr dependencies: also compiled natively by the CI host test
 * (tests/proto_test.c). Wire format: see ../PROTOCOL.md.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef TB_PROTO_H_
#define TB_PROTO_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TB_SYNC             0xA5
#define TB_PROTO_VERSION    1
#define TB_MAX_PAYLOAD      64
#define TB_MAX_CONTACTS     10
#define TB_COORD_MAX        32767

/* message types (first payload byte) */
#define TB_MSG_TOUCH        0x01 /* host -> dongle: contact frame               */
#define TB_MSG_HELLO        0x02 /* host -> dongle: who are you?                */
#define TB_MSG_RELEASE_ALL  0x03 /* host -> dongle: lift every contact now      */
#define TB_MSG_BOOTLOADER   0x04 /* host -> dongle: reboot into UF2 bootloader  */
#define TB_MSG_HELLO_REPLY  0x82 /* dongle -> host: identity + version          */
#define TB_MSG_ERROR        0x8F /* dongle -> host: frame rejected (code)       */

/* contact flags */
#define TB_FLAG_TIP         0x01
#define TB_FLAG_CONFIDENCE  0x02

/* TB_MSG_ERROR codes */
#define TB_ERR_CRC          1
#define TB_ERR_LENGTH       2
#define TB_ERR_VERSION      3
#define TB_ERR_TYPE         4

struct tb_contact {
	uint8_t id;     /* 0..127 */
	uint8_t flags;  /* TB_FLAG_* */
	uint16_t x;     /* 0..32767 */
	uint16_t y;     /* 0..32767 */
};

struct tb_touch_frame {
	uint8_t count;
	struct tb_contact c[TB_MAX_CONTACTS];
};

/* CRC-8, polynomial 0x07, init 0x00, no reflection (CRC-8/SMBUS) */
uint8_t tb_crc8(const uint8_t *data, size_t len);

/* Byte-wise stream parser */
struct tb_parser {
	uint8_t state;
	uint8_t len;
	uint8_t pos;
	uint8_t buf[TB_MAX_PAYLOAD];
	uint32_t crc_errors;
	uint32_t length_errors;
};

void tb_parser_init(struct tb_parser *p);

/*
 * Feed one byte. Returns the payload length (>0) when a complete frame with a
 * valid CRC is in p->buf, 0 otherwise. A bad length or CRC drops the frame;
 * the parser then waits for the next sync byte.
 */
int tb_parser_feed(struct tb_parser *p, uint8_t byte);

/*
 * Decode a TB_MSG_TOUCH payload. Returns 0 or a TB_ERR_* code.
 * Coordinates are clamped to TB_COORD_MAX, ids masked to 0..127.
 */
int tb_decode_touch(const uint8_t *payload, size_t len, struct tb_touch_frame *out);

/* Wrap a payload into a frame (sync, len, payload, crc). Returns frame size. */
size_t tb_encode_frame(const uint8_t *payload, uint8_t len, uint8_t *out, size_t out_size);

#endif /* TB_PROTO_H_ */
