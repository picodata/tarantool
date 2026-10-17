/*
 * Checks of the bundled libyaml that can't be done from Lua: the emitter
 * output for given events and the parser output for given documents.
 */
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <yaml.h>

#define UNIT_TAP_COMPATIBLE 1
#include "unit.h"

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
	yaml_parser_t parser;
	yaml_event_t event;
	const char *result = NULL;
	trace[0] = '\0';
	fail_unless(yaml_parser_initialize(&parser));
	yaml_parser_set_input_string(&parser, (const unsigned char *)input,
				     strlen(input));
	while (true) {
		if (!yaml_parser_parse(&parser, &event)) {
			result = parser.problem;
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

int
main(void)
{
	plan(2);
	test_directives();
	test_tag_before_flow_indicator();
	return check_plan();
}
