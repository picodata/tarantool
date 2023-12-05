#include "box/wal_ext_impl.h"
#include "stdio.h"
#include "trivia/util.h"
#include "tuple.h"
#include "xrow.h"
#include "txn.h"

/*
 * space_wal_ext is a virtual table with single method that process
 * a wal request.
 */
struct space_wal_ext {
	/* Process an WAL request. */
	void (*process)(struct txn_stmt *stmt, struct request *request);
};

/** List of wal extensions. */
enum wal_extension {
	NEW_OLD_TUPLE,
	wal_extension_MAX
};

static const char *const wal_extension_strs[] = {
	[NEW_OLD_TUPLE] = "new_old",
};

static bool global_extensions[] = {
	[NEW_OLD_TUPLE] = false,
	[wal_extension_MAX] = false,
};

static inline enum wal_extension
extension_by_name(const char *name)
{
	return STR2ENUM(wal_extension, name);
}

int
set_enable_extension(const char *ext_name, bool enable)
{
	enum wal_extension ext = extension_by_name(ext_name);
	if (ext == wal_extension_MAX) {
		return -1;
	}

	global_extensions[ext] = enable;
	return 0;
}

void
append_old_and_new_tuple(struct txn_stmt *stmt, struct request *request)
{
	if (stmt->new_tuple != NULL &&
	    (request->type == IPROTO_INSERT ||
	     request->type == IPROTO_UPDATE ||
	     request->type == IPROTO_UPSERT ||
	     request->type == IPROTO_REPLACE)) {
		const char *new_data = tuple_data(stmt->new_tuple);
		request->new_tuple = new_data;
		request->new_tuple_end =
			new_data + tuple_bsize(stmt->new_tuple);
	}

	if (stmt->old_tuple != NULL &&
	    (request->type == IPROTO_DELETE ||
	     request->type == IPROTO_UPDATE ||
	     request->type == IPROTO_UPSERT ||
	     request->type == IPROTO_REPLACE)) {
		const char *old_data = tuple_data(stmt->old_tuple);
		request->old_tuple = old_data;
		request->old_tuple_end =
			old_data + tuple_bsize(stmt->old_tuple);
	}
}

/*
 * new_old extension
 */
static struct space_wal_ext new_old_ext = {
	.process = append_old_and_new_tuple,
};

void
wal_ext_init(void)
{
}

void
wal_ext_free(void)
{
}

void
space_wal_ext_process_request(struct space_wal_ext *ext, struct txn_stmt *stmt,
			      struct request *request)
{
	assert(ext != NULL);
	ext->process(stmt, request);
}

struct space_wal_ext *
space_wal_ext_by_name(const char *space_name)
{
	(void)space_name;
	if (global_extensions[NEW_OLD_TUPLE]) {
		return &new_old_ext;
	}
	return NULL;
}
