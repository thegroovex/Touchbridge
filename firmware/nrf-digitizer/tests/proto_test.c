/*
 * Host test for the protocol parser and the HID report builder (no Zephyr).
 *   cc -std=c11 -Wall -Wextra -Werror -I../src ../src/tb_proto.c ../src/tb_report.c proto_test.c -o proto_test && ./proto_test
 * The frames below are the same test vectors as Tests/TouchBridgeCoreTests/NRFDigitizerTests.swift.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tb_proto.h"
#include "tb_report.h"

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static int feed_all(struct tb_parser *p, const uint8_t *b, size_t n)
{
	int got = 0;

	for (size_t i = 0; i < n; i++) {
		int len = tb_parser_feed(p, b[i]);

		if (len > 0) {
			got = len;
		}
	}
	return got;
}

static const uint8_t *contact(const uint8_t *report, int slot)
{
	return &report[1 + slot * TB_CONTACT_BYTES];
}

int main(void)
{
	/* CRC-8/SMBUS check value */
	CHECK(tb_crc8((const uint8_t *)"123456789", 9) == 0xF4);

	/* hello frame */
	uint8_t hello[] = { TB_MSG_HELLO };
	uint8_t frame[80];
	size_t n = tb_encode_frame(hello, 1, frame, sizeof(frame));

	CHECK(n == 4);
	CHECK(frame[0] == 0xA5 && frame[1] == 0x01 && frame[2] == 0x02);
	CHECK(frame[3] == tb_crc8(&frame[1], 2));

	/* touch frame: 2 contacts, with garbage and a corrupted copy in front */
	uint8_t touch[] = { TB_MSG_TOUCH, TB_PROTO_VERSION, 2,
			    0, TB_FLAG_TIP | TB_FLAG_CONFIDENCE, 0x00, 0x40, 0xFF, 0x7F,
			    1, TB_FLAG_TIP, 0x34, 0x12, 0x00, 0x00 };
	uint8_t stream[200];
	size_t fl = tb_encode_frame(touch, sizeof(touch), frame, sizeof(frame));
	size_t s = 0;

	stream[s++] = 0x00;
	stream[s++] = 0x13;
	memcpy(&stream[s], frame, fl);
	stream[s + 5] ^= 0x01; /* bad CRC */
	s += fl;
	memcpy(&stream[s], frame, fl);
	s += fl;

	struct tb_parser p;

	tb_parser_init(&p);
	int len = feed_all(&p, stream, s);

	CHECK(len == (int)sizeof(touch));
	CHECK(p.crc_errors == 1);

	struct tb_touch_frame f;

	CHECK(tb_decode_touch(p.buf, (size_t)len, &f) == 0);
	CHECK(f.count == 2);
	CHECK(f.c[0].x == 0x4000 && f.c[0].y == 0x7FFF);
	CHECK(f.c[1].id == 1 && f.c[1].x == 0x1234);

	/* wrong version / length */
	uint8_t badv[] = { TB_MSG_TOUCH, 9, 0 };

	CHECK(tb_decode_touch(badv, sizeof(badv), &f) == TB_ERR_VERSION);
	CHECK(tb_decode_touch(touch, sizeof(touch) - 1, &f) == TB_ERR_LENGTH);

	/* report: 2 down */
	struct tb_report_state st;
	uint8_t r[TB_REPORT_SIZE];

	tb_report_init(&st);
	tb_decode_touch(touch, sizeof(touch), &f);
	CHECK(tb_report_build(&st, &f, 1234, r) == 2);
	CHECK(r[0] == TB_REPORT_ID_INPUT);
	CHECK(contact(r, 0)[0] == 0x03 && contact(r, 0)[1] == 0);
	CHECK(contact(r, 0)[2] == 0x00 && contact(r, 0)[3] == 0x40);
	CHECK(r[61] == (1234 & 0xFF) && r[62] == (1234 >> 8) && r[63] == 2);
	CHECK(tb_report_any_down(&st));

	/* contact 1 disappears -> lifted automatically at its last position */
	struct tb_touch_frame one = { .count = 1, .c = { { 0, TB_FLAG_TIP, 100, 200 } } };

	CHECK(tb_report_build(&st, &one, 0, r) == 2);
	CHECK(contact(r, 1)[0] == 0x02 && contact(r, 1)[1] == 1);
	CHECK(contact(r, 1)[2] == 0x34 && contact(r, 1)[3] == 0x12);

	/* coalescing: unsent lift survives when the next report replaces it */
	uint8_t older[TB_REPORT_SIZE];

	memcpy(older, r, sizeof(older));
	CHECK(tb_report_build(&st, &one, 0, r) == 1);
	tb_report_merge_lifts(r, older);
	CHECK(r[63] == 2 && contact(r, 1)[1] == 1 && (contact(r, 1)[0] & 1) == 0);

	/* release all */
	struct tb_touch_frame none = { .count = 0 };

	CHECK(tb_report_build(&st, &none, 0, r) == 1);
	CHECK(contact(r, 0)[0] == 0x02 && r[63] == 1);
	CHECK(!tb_report_any_down(&st));
	CHECK(tb_report_build(&st, &none, 0, r) == 0);

	if (failures) {
		printf("%d check(s) failed\n", failures);
		return EXIT_FAILURE;
	}
	printf("proto_test: all checks passed\n");
	return EXIT_SUCCESS;
}
