/*
 * TouchBridge Digitizer serial protocol, see tb_proto.h and ../PROTOCOL.md.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "tb_proto.h"

#include <string.h>

enum { ST_SYNC, ST_LEN, ST_PAYLOAD, ST_CRC };

uint8_t tb_crc8(const uint8_t *data, size_t len)
{
	uint8_t crc = 0x00;

	for (size_t i = 0; i < len; i++) {
		crc ^= data[i];
		for (int b = 0; b < 8; b++) {
			crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
		}
	}
	return crc;
}

void tb_parser_init(struct tb_parser *p)
{
	memset(p, 0, sizeof(*p));
	p->state = ST_SYNC;
}

int tb_parser_feed(struct tb_parser *p, uint8_t byte)
{
	switch (p->state) {
	case ST_SYNC:
		if (byte == TB_SYNC) {
			p->state = ST_LEN;
		}
		return 0;
	case ST_LEN:
		if (byte == 0 || byte > TB_MAX_PAYLOAD) {
			p->length_errors++;
			/* a sync byte here may start the real frame */
			p->state = (byte == TB_SYNC) ? ST_LEN : ST_SYNC;
			return 0;
		}
		p->len = byte;
		p->pos = 0;
		p->state = ST_PAYLOAD;
		return 0;
	case ST_PAYLOAD:
		p->buf[p->pos++] = byte;
		if (p->pos >= p->len) {
			p->state = ST_CRC;
		}
		return 0;
	case ST_CRC: {
		/* CRC covers LEN + payload */
		uint8_t tmp[TB_MAX_PAYLOAD + 1];
		uint8_t crc;

		tmp[0] = p->len;
		memcpy(&tmp[1], p->buf, p->len);
		crc = tb_crc8(tmp, (size_t)p->len + 1U);
		p->state = ST_SYNC;
		if (crc != byte) {
			p->crc_errors++;
			return 0;
		}
		return p->len;
	}
	default:
		p->state = ST_SYNC;
		return 0;
	}
}

int tb_decode_touch(const uint8_t *payload, size_t len, struct tb_touch_frame *out)
{
	/* type, version, count, count x 6 bytes */
	if (len < 3U || payload[0] != TB_MSG_TOUCH) {
		return TB_ERR_LENGTH;
	}
	if (payload[1] != TB_PROTO_VERSION) {
		return TB_ERR_VERSION;
	}
	uint8_t count = payload[2];

	if (count > TB_MAX_CONTACTS || len != 3U + 6U * count) {
		return TB_ERR_LENGTH;
	}
	out->count = count;
	for (uint8_t i = 0; i < count; i++) {
		const uint8_t *c = &payload[3 + 6 * i];
		uint16_t x = (uint16_t)(c[2] | (c[3] << 8));
		uint16_t y = (uint16_t)(c[4] | (c[5] << 8));

		out->c[i].id = c[0] & 0x7F;
		out->c[i].flags = c[1];
		out->c[i].x = x > TB_COORD_MAX ? TB_COORD_MAX : x;
		out->c[i].y = y > TB_COORD_MAX ? TB_COORD_MAX : y;
	}
	return 0;
}

size_t tb_encode_frame(const uint8_t *payload, uint8_t len, uint8_t *out, size_t out_size)
{
	if (len == 0 || len > TB_MAX_PAYLOAD || out_size < (size_t)len + 3U) {
		return 0;
	}
	out[0] = TB_SYNC;
	out[1] = len;
	memcpy(&out[2], payload, len);
	out[2 + len] = tb_crc8(&out[1], (size_t)len + 1U);
	return (size_t)len + 3U;
}
