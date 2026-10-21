/*
 * SPDX-License-Identifier: Apache-2.0
 */
#include "tb_report.h"

#include <string.h>

static bool bit_get(const uint8_t *m, uint8_t id) { return (m[id >> 3] >> (id & 7)) & 1U; }
static void bit_set(uint8_t *m, uint8_t id) { m[id >> 3] |= (uint8_t)(1U << (id & 7)); }

void tb_report_init(struct tb_report_state *s)
{
	memset(s, 0, sizeof(*s));
}

bool tb_report_any_down(const struct tb_report_state *s)
{
	for (size_t i = 0; i < sizeof(s->down); i++) {
		if (s->down[i]) {
			return true;
		}
	}
	return false;
}

static void put_contact(uint8_t *out, uint8_t slot, uint8_t id, bool tip, uint16_t x, uint16_t y)
{
	uint8_t *c = &out[1 + slot * TB_CONTACT_BYTES];

	c[0] = (tip ? 0x01 : 0x00) | 0x02; /* tip switch, confidence (always 1: no palm rejection) */
	c[1] = id & 0x7F;
	c[2] = (uint8_t)(x & 0xFF);
	c[3] = (uint8_t)(x >> 8);
	c[4] = (uint8_t)(y & 0xFF);
	c[5] = (uint8_t)(y >> 8);
}

uint8_t tb_report_build(struct tb_report_state *s, const struct tb_touch_frame *f,
			uint16_t scan_time, uint8_t out[TB_REPORT_SIZE])
{
	uint8_t next[16] = {0};
	uint8_t seen[16] = {0};
	uint8_t n = 0;

	memset(out, 0, TB_REPORT_SIZE);
	out[0] = TB_REPORT_ID_INPUT;

	for (uint8_t i = 0; i < f->count && n < TB_MAX_CONTACTS; i++) {
		const struct tb_contact *c = &f->c[i];
		uint8_t id = c->id & 0x7F;
		bool tip = (c->flags & TB_FLAG_TIP) != 0;

		if (bit_get(seen, id)) {
			continue; /* duplicate id in one frame */
		}
		bit_set(seen, id);
		if (!tip && !bit_get(s->down, id)) {
			continue; /* lift of a contact the OS never saw */
		}
		put_contact(out, n++, id, tip, c->x, c->y);
		s->last_x[id] = c->x;
		s->last_y[id] = c->y;
		if (tip) {
			bit_set(next, id);
		}
	}
	/* contacts that disappeared from the frame: lift them once */
	for (uint16_t id = 0; id < 128; id++) {
		if (!bit_get(s->down, (uint8_t)id) || bit_get(seen, (uint8_t)id)) {
			continue;
		}
		if (n < TB_MAX_CONTACTS) {
			put_contact(out, n++, (uint8_t)id, false, s->last_x[id], s->last_y[id]);
		} else {
			bit_set(next, (uint8_t)id); /* no room: still down, lifted next time */
		}
	}
	memcpy(s->down, next, sizeof(next));

	uint8_t *tail = &out[1 + TB_MAX_CONTACTS * TB_CONTACT_BYTES];

	tail[0] = (uint8_t)(scan_time & 0xFF);
	tail[1] = (uint8_t)(scan_time >> 8);
	tail[2] = n;
	return n;
}

void tb_report_merge_lifts(uint8_t report[TB_REPORT_SIZE], const uint8_t older[TB_REPORT_SIZE])
{
	uint8_t *count = &report[1 + TB_MAX_CONTACTS * TB_CONTACT_BYTES + 2];
	uint8_t old_count = older[1 + TB_MAX_CONTACTS * TB_CONTACT_BYTES + 2];

	for (uint8_t i = 0; i < old_count && i < TB_MAX_CONTACTS; i++) {
		const uint8_t *oc = &older[1 + i * TB_CONTACT_BYTES];
		bool present = false;

		if (oc[0] & 0x01) {
			continue; /* was down: still down or lifted by the newer report */
		}
		for (uint8_t k = 0; k < *count; k++) {
			if (report[1 + k * TB_CONTACT_BYTES + 1] == oc[1]) {
				present = true;
				break;
			}
		}
		if (!present && *count < TB_MAX_CONTACTS) {
			memcpy(&report[1 + *count * TB_CONTACT_BYTES], oc, TB_CONTACT_BYTES);
			(*count)++;
		}
	}
}
