/*
 * Checks of the bundled libyaml that can't be done from Lua: the emitter
 * output for given events, the parser output for given documents and the
 * nesting depth limit for both tokens and events.
 */
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <yaml.h>

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

static const char depth_problem[] = "exceeded maximum nesting depth";

static yaml_emitter_t emitter;
static unsigned char out[256];
static size_t out_len;

static void
emit(yaml_event_t *event)
{
	fail_unless(yaml_emitter_emit(&emitter, event));
}

static void
emit_begin(void)
{
	yaml_event_t event;
	fail_unless(yaml_emitter_initialize(&emitter));
	yaml_emitter_set_output_string(&emitter, out, sizeof(out) - 1,
				       &out_len);
	fail_unless(yaml_stream_start_event_initialize(&event,
						       YAML_UTF8_ENCODING));
	emit(&event);
}

static const char *
emit_end(void)
{
	yaml_event_t event;
	fail_unless(yaml_stream_end_event_initialize(&event));
	emit(&event);
	yaml_emitter_delete(&emitter);
	out[out_len] = '\0';
	return (const char *)out;
}

static void
emit_doc_start(yaml_version_directive_t *version, bool implicit)
{
	yaml_event_t event;
	fail_unless(yaml_document_start_event_initialize(&event, version,
							 NULL, NULL,
							 implicit));
	emit(&event);
}

static void
emit_doc_end(bool implicit)
{
	yaml_event_t event;
	fail_unless(yaml_document_end_event_initialize(&event, implicit));
	emit(&event);
}

static void
emit_scalar(const char *value, yaml_scalar_style_t style)
{
	yaml_event_t event;
	fail_unless(yaml_scalar_event_initialize(&event, NULL, NULL,
						 (yaml_char_t *)value,
						 strlen(value), 1, 1, style));
	emit(&event);
}

/**
 * Tarantool keeps the space after the indicator before an empty plain
 * scalar, unlike upstream libyaml since #186.
 */
static void
test_empty_scalar(void)
{
	plan(3);
	header();

	yaml_event_t event;
	emit_begin();
	emit_doc_start(NULL, false);
	emit_scalar("", YAML_ANY_SCALAR_STYLE);
	emit_doc_end(false);
	is_str(emit_end(), "--- \n...\n", "top level");

	emit_begin();
	emit_doc_start(NULL, false);
	fail_unless(yaml_sequence_start_event_initialize(
		&event, NULL, NULL, 1, YAML_BLOCK_SEQUENCE_STYLE));
	emit(&event);
	emit_scalar("", YAML_ANY_SCALAR_STYLE);
	fail_unless(yaml_sequence_end_event_initialize(&event));
	emit(&event);
	emit_doc_end(false);
	is_str(emit_end(), "---\n- \n...\n", "sequence item");

	emit_begin();
	emit_doc_start(NULL, false);
	fail_unless(yaml_mapping_start_event_initialize(
		&event, NULL, NULL, 1, YAML_BLOCK_MAPPING_STYLE));
	emit(&event);
	emit_scalar("key", YAML_ANY_SCALAR_STYLE);
	emit_scalar("", YAML_ANY_SCALAR_STYLE);
	fail_unless(yaml_mapping_end_event_initialize(&event));
	emit(&event);
	emit_doc_end(false);
	is_str(emit_end(), "---\nkey: \n...\n", "mapping value");

	footer();
	check_plan();
}

/** The %YAML directive and the end marker of the previous document. */
static void
test_directives(void)
{
	plan(2);
	header();

	yaml_version_directive_t v12 = {1, 2};
	emit_begin();
	emit_doc_start(&v12, false);
	emit_scalar("a", YAML_PLAIN_SCALAR_STYLE);
	emit_doc_end(false);
	is_str(emit_end(), "%YAML 1.2\n--- a\n...\n", "%YAML 1.2");

	yaml_version_directive_t v11 = {1, 1};
	emit_begin();
	emit_doc_start(NULL, true);
	emit_scalar("a", YAML_LITERAL_SCALAR_STYLE);
	emit_doc_end(true);
	emit_doc_start(&v11, false);
	emit_scalar("b", YAML_PLAIN_SCALAR_STYLE);
	emit_doc_end(true);
	is_str(emit_end(), "|-\n  a\n...\n%YAML 1.1\n--- b\n",
	       "document end before a directive");

	footer();
	check_plan();
}

/**
 * Parses @a input and writes its scalars as "tag=value;" to @a trace.
 * Returns the parser problem or NULL on success.
 */
static const char *
parse_scalars(const char *input, char *trace, size_t size)
{
	static char problem[128];
	yaml_parser_t parser;
	yaml_event_t event;
	const char *result = NULL;
	trace[0] = '\0';
	fail_unless(yaml_parser_initialize(&parser));
	yaml_parser_set_input_string(&parser, (const unsigned char *)input,
				     strlen(input));
	while (true) {
		if (!yaml_parser_parse(&parser, &event)) {
			snprintf(problem, sizeof(problem), "%s",
				 parser.problem);
			result = problem;
			break;
		}
		yaml_event_type_t type = event.type;
		if (type == YAML_SCALAR_EVENT) {
			size_t len = strlen(trace);
			const char *tag = (const char *)event.data.scalar.tag;
			snprintf(trace + len, size - len, "%s=%.*s;",
				 tag != NULL ? tag : "",
				 (int)event.data.scalar.length,
				 (const char *)event.data.scalar.value);
		}
		yaml_event_delete(&event);
		if (type == YAML_STREAM_END_EVENT)
			break;
	}
	yaml_parser_delete(&parser);
	return result;
}

/** A tag doesn't consume the flow indicator after it. */
static void
test_tag_before_flow_indicator(void)
{
	plan(2);
	header();

	char trace[256];
	const char *problem = parse_scalars("{foo : !!str, !!str : bar}",
					    trace, sizeof(trace));
	is(problem, NULL, "parsed");
	is_str(trace, "=foo;tag:yaml.org,2002:str=;"
	       "tag:yaml.org,2002:str=;=bar;", "scalars");

	footer();
	check_plan();
}

/** Reads all tokens of @a input. Returns the problem or NULL. */
static const char *
scan(const char *input)
{
	static char problem[128];
	yaml_parser_t parser;
	yaml_token_t token;
	const char *result = NULL;
	fail_unless(yaml_parser_initialize(&parser));
	yaml_parser_set_input_string(&parser, (const unsigned char *)input,
				     strlen(input));
	while (true) {
		if (!yaml_parser_scan(&parser, &token)) {
			snprintf(problem, sizeof(problem), "%s",
				 parser.problem);
			result = problem;
			break;
		}
		yaml_token_type_t type = token.type;
		yaml_token_delete(&token);
		if (type == YAML_STREAM_END_TOKEN)
			break;
	}
	yaml_parser_delete(&parser);
	return result;
}

/** Large enough for the mapping and sequence chain of 1000 pairs. */
static char doc[1 << 21];

/** Appends @a count copies of @a s at @a p, returns the new end. */
static char *
put(char *p, const char *s, int count)
{
	size_t len = strlen(s);
	for (int i = 0; i < count; i++, p += len)
		memcpy(p, s, len);
	*p = '\0';
	return p;
}

/** Nested flow sequences: [[[0]]]. */
static const char *
gen_flow(int n)
{
	put(put(put(doc, "[", n), "0", 1), "]", n);
	return doc;
}

/** Nested block sequences, each "- " adds an indentation level. */
static const char *
gen_block(int n)
{
	put(put(doc, "- ", n), "0", 1);
	return doc;
}

/** 500 block levels followed by @a n flow levels. */
static const char *
gen_mixed(int n)
{
	put(put(put(put(doc, "- ", 500), "[", n), "0", 1), "]", n);
	return doc;
}

/** A flow mapping in every flow sequence: [a: [a: 0]]. */
static const char *
gen_flow_pairs(int n)
{
	put(put(put(doc, "[a: ", n), "0", 1), "]", n);
	return doc;
}

/** Block mappings and sequences without an extra indentation. */
static const char *
gen_block_pairs(int n)
{
	char *p = put(doc, "a:\n", 1);
	for (int i = 0; i < n - 1; i++)
		p = put(put(p, "  ", i), "- a:\n", 1);
	put(put(p, "  ", n - 1), "- 0\n", 1);
	return doc;
}

static void
check_depth(const char *(*gen)(int), int n, bool accepted,
	    const char *name)
{
	char trace[64];
	const char *expected = accepted ? NULL : depth_problem;
	const char *problem = scan(gen(n));
	ok(problem == expected ||
	   (problem != NULL && expected != NULL &&
	    strcmp(problem, expected) == 0),
	   "%s %d: tokens: %s", name, n, problem != NULL ? problem : "ok");
	problem = parse_scalars(gen(n), trace, sizeof(trace));
	ok(problem == expected ||
	   (problem != NULL && expected != NULL &&
	    strcmp(problem, expected) == 0),
	   "%s %d: events: %s", name, n, problem != NULL ? problem : "ok");
}

/**
 * The scanner limits the sum of the flow level and the indentation
 * stack, so the number of nested collections depends on the form.
 */
static void
test_nesting_limit(void)
{
	plan(21);
	header();

	is(yaml_get_max_nest_level(), 1000, "default limit");
	check_depth(gen_flow, 1000, true, "flow");
	check_depth(gen_flow, 1001, false, "flow");
	check_depth(gen_block, 999, true, "block");
	check_depth(gen_block, 1000, false, "block");
	check_depth(gen_mixed, 500, true, "mixed");
	check_depth(gen_mixed, 501, false, "mixed");
	check_depth(gen_flow_pairs, 1000, true, "flow pairs");
	check_depth(gen_flow_pairs, 1001, false, "flow pairs");
	check_depth(gen_block_pairs, 999, true, "block pairs");
	check_depth(gen_block_pairs, 1000, false, "block pairs");

	footer();
	check_plan();
}

int
main(void)
{
	plan(4);
	test_empty_scalar();
	test_directives();
	test_tag_before_flow_indicator();
	test_nesting_limit();
	return check_plan();
}
