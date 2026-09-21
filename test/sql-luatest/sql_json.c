#include <string.h>

#include "msgpuck.h"
#include "module.h"

enum {
	BUF_SIZE = 512,
	/** MP_EXT subtype of a JSON value. */
	MP_JSON = 20,
};

/** {"a": 2, "b": 1} in normal form. */
static const char SORTED[] = {
	'\x82', '\xa1', 'a', '\x02', '\xa1', 'b', '\x01',
};

/** Write an MP_EXT/MP_JSON envelope around @a inner. */
static char *
encode_json(char *pos, const char *inner, uint32_t len)
{
	pos = mp_encode_extl(pos, MP_JSON, len);
	memcpy(pos, inner, len);
	return pos + len;
}

int
ret_json_sorted(box_function_ctx_t *ctx, const char *args,
		const char *args_end)
{
	(void)args;
	(void)args_end;
	char buf[BUF_SIZE] = {0};
	char *pos = encode_json(buf, SORTED, sizeof(SORTED));
	return box_return_mp(ctx, buf, pos);
}

int
ret_map_json_sorted(box_function_ctx_t *ctx, const char *args,
		    const char *args_end)
{
	(void)args;
	(void)args_end;
	char buf[BUF_SIZE] = {0};
	char *pos = mp_encode_map(buf, 1);
	pos = mp_encode_str0(pos, "k");
	pos = encode_json(pos, SORTED, sizeof(SORTED));
	return box_return_mp(ctx, buf, pos);
}
