#include "msgpuck.h"
#include "module.h"

enum {
	BUF_SIZE = 512,
};

int
ret_array(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	(void)args;
	(void)args_end;
	char buf[BUF_SIZE] = {0};
	char *pos = buf;
	pos = mp_encode_array(pos, 2);
	pos = mp_encode_uint(pos, 2);
	pos = mp_encode_uint(pos, 42);
	return box_return_mp(ctx, buf, pos);
}

int
ret_map(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	(void)args;
	(void)args_end;
	char buf[BUF_SIZE] = {0};
	char *pos = buf;
	pos = mp_encode_map(pos, 2);
	pos = mp_encode_str0(pos, "key1");
	pos = mp_encode_uint(pos, 2);
	pos = mp_encode_str0(pos, "key2");
	pos = mp_encode_uint(pos, 42);
	return box_return_mp(ctx, buf, pos);
}

int
ret_array_tuple(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	(void)args;
	(void)args_end;
	char buf[BUF_SIZE] = {0};
	char *pos = buf;
	pos = mp_encode_array(pos, 1);
	pos = mp_encode_array(pos, 2);
	pos = mp_encode_uint(pos, 2);
	pos = mp_encode_uint(pos, 42);
	box_tuple_t *tuple = box_tuple_new(box_tuple_format_default(),
					   buf, pos);
	if (tuple == NULL)
		return -1;
	return box_return_tuple(ctx, tuple);
}

int
ret_map_tuple(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	(void)args;
	(void)args_end;
	char buf[BUF_SIZE] = {0};
	char *pos = buf;
	pos = mp_encode_array(pos, 1);
	pos = mp_encode_map(pos, 2);
	pos = mp_encode_str0(pos, "key1");
	pos = mp_encode_uint(pos, 2);
	pos = mp_encode_str0(pos, "key2");
	pos = mp_encode_uint(pos, 42);
	box_tuple_t *tuple = box_tuple_new(box_tuple_format_default(),
					   buf, pos);
	if (tuple == NULL)
		return -1;
	return box_return_tuple(ctx, tuple);
}
