/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright 2010-2022, Tarantool AUTHORS, please see AUTHORS file.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "small/rlist.h"
#include "vclock/vclock.h"

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

struct cord;
struct field_def;
struct index;
struct index_read_view;
struct space;
struct space_upgrade_read_view;
struct tuple_format;

/** Read view of a space. */
struct space_read_view {
	/** Link in read_view::spaces. */
	struct rlist link;
	/** Read view that owns this space. */
	struct read_view *rv;
	/** Space id. */
	uint32_t id;
	/** Space name. */
	char *name;
	/**
	 * Tuple field definition array used by this space. Allocated only if
	 * read_view_opts::enable_field_names is set, otherwise set to NULL.
	 * Used for creation of space_read_view::format.
	 */
	struct field_def *fields;
	/** Number of entries in the fields array. */
	uint32_t field_count;
	/**
	 * Runtime tuple format needed to access tuple field names by name.
	 * Referenced (ref counter incremented).
	 *
	 * A new format is created only if read_view_opts::enable_field_names
	 * is set, otherwise runtime_tuple_format is used.
	 *
	 * We can't just use the space tuple format as is because it allocates
	 * tuples from the space engine arena, which is single-threaded, while
	 * a read view may be used from threads other than tx. Good news is
	 * runtime tuple formats are reusable so if we create more than one
	 * read view of the same space, we will use just one tuple format for
	 * them all.
	 */
	struct tuple_format *format;
	/**
	 * Upgrade function for this space read view or NULL if there wasn't
	 * a space upgrade in progress at the time when this read view was
	 * created or read_view_opts::enable_space_upgrade wasn't set.
	 */
	struct space_upgrade_read_view *upgrade;
	/** Replication group id. See space_opts::group_id. */
	uint32_t group_id;
	/**
	 * Max index id.
	 *
	 * (The number of entries in index_map is index_id_max + 1.)
	 */
	uint32_t index_id_max;
	/**
	 * Sparse (may contain nulls) array of index read views,
	 * indexed by index id.
	 */
	struct index_read_view **index_map;
};

static inline struct index_read_view *
space_read_view_index(struct space_read_view *space_rv, uint32_t id)
{
	return id <= space_rv->index_id_max ? space_rv->index_map[id] : NULL;
}

/** Read view of the entire database. */
struct read_view {
	/** Unique read view identifier. */
	uint64_t id;
	/** Read view name. Used for introspection. */
	char *name;
	/**
	 * Set if this read view is needed for system purposes (for example, to
	 * make a checkpoint). Initialized with read_view_opts::is_system.
	 */
	bool is_system;
	/**
	 * Set if tuples read from the read view don't need to be decompressed.
	 * Initialized with read_view_opts::disable_decompression.
	 */
	bool disable_decompression;
	/** Monotonic clock at the time when the read view was created. */
	double timestamp;
	/** Replicaset vclock at the time when the read view was created. */
	struct vclock vclock;
	/** List of engine read views, linked by engine_read_view::link. */
	struct rlist engines;
	/** List of space read views, linked by space_read_view::link. */
	struct rlist spaces;
	/**
	 * Thread that exclusively owns this read view or NULL if the read view
	 * may be used by any thread.
	 */
	struct cord *owner;
};

#define read_view_foreach_space(space_rv, rv) \
	rlist_foreach_entry(space_rv, &(rv)->spaces, link)

/** Read view creation options. */
struct read_view_opts {
	/** Read view name. Used for introspection. Must be set. */
	const char *name;
	/**
	 * Set if this read view is needed for system purposes (for example, to
	 * make a checkpoint). Default: false.
	 */
	bool is_system;
	/**
	 * Space filter: should return true if the space should be included
	 * into the read view.
	 *
	 * Default: include all spaces (return true, ignore arguments).
	 */
	bool
	(*filter_space)(struct space *space, void *arg);
	/**
	 * Index filter: should return true if the index should be included
	 * into the read view.
	 *
	 * Default: include all indexes (return true, ignore arguments).
	 */
	bool
	(*filter_index)(struct space *space, struct index *index, void *arg);
	/**
	 * Argument passed to filter functions.
	 */
	void *filter_arg;
	/**
	 * If this flag is set, a new runtime tuple format will be created for
	 * each read view space to support accessing tuple fields by name,
	 * otherwise the preallocated name-less runtime tuple format will be
	 * used instead.
	 */
	bool enable_field_names;
	/**
	 * If this flag is set and there's a space upgrade in progress at the
	 * time when this read view is created, create an upgrade function that
	 * can be applied to tuples retrieved from this read view. See also
	 * space_read_view::upgrade.
	 */
	bool enable_space_upgrade;
	/**
	 * Data-temporary spaces aren't included into this read view unless this
	 * flag is set.
	 */
	bool enable_data_temporary_spaces;
	/**
	 * Memtx-specific. Disables decompression of tuples fetched from
	 * the read view. Setting this flag makes the raw read view methods
	 * (get_raw, next_raw) return a pointer to the data stored in
	 * the read view as is, without any preprocessing or copying to
	 * the fiber region. The user is supposed to decompress the data
	 * encoded in the MP_COMPRESSION MsgPack extension manually.
	 */
	bool disable_decompression;
};

/** Sets read view options to default values. */
void
read_view_opts_create(struct read_view_opts *opts);

/**
 * Opens a database read view: all changes done to the database after a read
 * view was open will not be visible from the read view.
 *
 * Engines that don't support read view creation are silently skipped.
 *
 * Returns 0 on success. On error, returns -1 and sets diag.
 */
int
read_view_open(struct read_view *rv, const struct read_view_opts *opts);

/**
 * Closes a database read view.
 */
void
read_view_close(struct read_view *rv);

/**
 * Looks up an open read view by id.
 *
 * Returns NULL if not found.
 */
struct read_view *
read_view_by_id(uint64_t id);

typedef bool
read_view_foreach_f(struct read_view *rv, void *arg);

/**
 * Invokes a callback for each open read view with no particular order.
 *
 * The callback is passed a read view object and the given argument.
 * If it returns true, iteration continues. Otherwise, iteration breaks,
 * and the function returns false.
 */
bool
read_view_foreach(read_view_foreach_f cb, void *arg);

/** \cond public */

typedef struct index_read_view_iterator box_read_view_iterator_t;
typedef struct read_view box_read_view_t;

/**
 * Flags supported by \link box_read_view_open_for_given_spaces \endlink.
 */
enum box_read_view_flags {
	BOX_READ_VIEW_FIELD_NAMES = 0x0001,
};

struct space_index_id {
	uint32_t space_id;
	uint32_t index_id;
};

/**
 * Open a read view on the spaces and indexes specified by the given parameters.
 *
 * \param name                   Read view name. Will be copied
 *                               so memory may be reused immediately.
 *
 * \param space_index_ids        Array of pairs (space id, index id) which
 *                               should be added to the read view.
 * \param space_index_ids_count  Number of elements in \a space_index_ids
 *
 * \param flags                  Read view flags. Must be a disjunction of
 *                               enum \link box_read_view_flags \endlink values
 *                               or 0.
 *
 * \retval NULL                  On error (check box_error_last()).
 * \retval read view		 Otherwise.
 *
 * \sa box_read_view_iterator()
 * \sa box_read_view_close()
 */
box_read_view_t *
box_read_view_open_for_given_spaces(const char *name,
				    struct space_index_id *space_index_ids,
				    uint32_t space_index_ids_count,
				    uint64_t flags);

/**
 * Close the read view and dispose off any resources taken up by it.
 *
 * \sa box_read_view_open_for_given_spaces()
 */
void
box_read_view_close(box_read_view_t *rv);

/**
 * Create an iterator over all the tuples in the read view of the given index.
 *
 * \param rv         Read view returned by box_read_view_open_for_given_spaces()
 * \param space_id   Space identifier
 * \param index_id   Index identifier
 * \param[out] iter  Iterator or NULL if the given index is not in the read view
 *
 * \retval -1        On error (check box_error_last())
 * \retval 0         Otherwise. Index not existing is not an error
 *
 * \sa box_read_view_iterator_next()
 * \sa box_read_view_iterator_free()
 */
int
box_read_view_iterator_all(box_read_view_t *rv,
			   uint32_t space_id, uint32_t index_id,
			   box_read_view_iterator_t **iter);

/**
 * Retrieve the next item from the \a iterator.
 *
 * \param iterator      An iterator returned by box_read_view_iterator()
 * \param[out] data     A pointer to the raw tuple data
 *			or NULL if there's no more data
 * \param[out] size     Size of the returned tuple data
 *
 * \retval -1           On error (check box_error_last() for details)
 * \retval 0            On success. The end of data is not an error
 *
 * \sa box_read_view_iterator()
 * \sa box_read_view_iterator_free()
 */
int
box_read_view_iterator_next_raw(box_read_view_iterator_t *iterator,
				const char **data, uint32_t *size);

/**
 * Destroy and deallocate the read view iterator.
 *
 * \sa box_read_view_iterator()
 * \sa box_read_view_iterator_free()
 */
void
box_read_view_iterator_free(box_read_view_iterator_t *iterator);

/** \endcond public */

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */
