/*
 * Copyright 2010-2017, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * This file contains code used for creating, destroying, and populating
 * a VDBE (or an "sql_stmt" as it is known to the outside world.)
 */
#include "fiber.h"
#include "coll/coll.h"
#include "box/session.h"
#include "box/schema.h"
#include "box/tuple_format.h"
#include "box/txn.h"
#include "msgpuck/msgpuck.h"
#include "sqlInt.h"
#include "mem.h"
#include "vdbeInt.h"
#include "tarantoolInt.h"
#include "box/execute.h"
#include "box/coll_id_cache.h"

/**
 * Make the data of EXPLAIN for a new statement. Return NULL if the
 * statement needs none: it is not under EXPLAIN, and it is not a program
 * that a debug build traces or lists.
 */
static VdbeExplain *
vdbe_explain_new(const struct Parse *parse)
{
	const struct Parse *top = sqlParseToplevel(parse);
	bool is_needed = top->explain != EXPLAIN_MODE_OFF;
#ifdef SQL_DEBUG
	if ((top->sql_flags & (SQL_VdbeListing | SQL_VdbeTrace)) != 0)
		is_needed = true;
#endif
	if (!is_needed)
		return NULL;
	VdbeExplain *explain = sql_xmalloc0(sizeof(*explain));
	explain->mode = top->explain;
	return explain;
}

/*
 * Create a new virtual database engine.
 */
Vdbe *
sqlVdbeCreate(Parse * pParse)
{
	assert(!pParse->parse_only);
	sql *db = sql_get();
	Vdbe *p;
	p = sql_xmalloc(sizeof(Vdbe));
	memset(p, 0, sizeof(Vdbe));
	stailq_create(&p->autoinc_id_list);
	if (db->pVdbe) {
		db->pVdbe->pPrev = p;
	}

	p->pNext = db->pVdbe;
	p->pPrev = 0;
	db->pVdbe = p;
	p->magic = VDBE_MAGIC_INIT;
	p->pParse = pParse;
	p->explain_data = vdbe_explain_new(pParse);
	p->schema_ver = stmt_cache_schema_version();
	assert(pParse->aLabel == 0);
	assert(pParse->nLabel == 0);
	assert(pParse->nOpAlloc == 0);
	assert(pParse->szOpAlloc == 0);
	return p;
}

int
sql_vdbe_prepare(struct Vdbe *vdbe)
{
	assert(vdbe != NULL);
	struct txn *txn = in_txn();
	vdbe->auto_commit = txn == NULL;
	return 0;
}

/*
 * Remember the SQL string for a prepared statement.
 */
void
sqlVdbeSetSql(Vdbe * p, const char *z, int n)
{
	if (p == 0)
		return;
	assert(p->zSql == 0);
	p->zSql = sql_xstrndup(z, n);
}

/*
 * Swap all content between two VDBE structures.
 */
void
sqlVdbeSwap(Vdbe * pA, Vdbe * pB)
{
	Vdbe tmp, *pTmp;
	char *zTmp;
	tmp = *pA;
	*pA = *pB;
	*pB = tmp;
	pTmp = pA->pNext;
	pA->pNext = pB->pNext;
	pB->pNext = pTmp;
	pTmp = pA->pPrev;
	pA->pPrev = pB->pPrev;
	pB->pPrev = pTmp;
	zTmp = pA->zSql;
	pA->zSql = pB->zSql;
	pB->zSql = zTmp;
}

/*
 * Resize the Vdbe.aOp array so that it is at least nOp elements larger
 * than its current size. nOp is guaranteed to be less than or equal
 * to 1024/sizeof(Op).
 *
 * If an out-of-memory error occurs while resizing the array, return
 * -1. In this case Vdbe.aOp and Parse.nOpAlloc remain
 * unchanged (this is so that any opcodes already allocated can be
 * correctly deallocated along with the rest of the Vdbe).
 */
static int
growOpArray(Vdbe * v, int nOp)
{
	VdbeOp *pNew;
	Parse *p = v->pParse;

	/* The SQL_TEST_REALLOC_STRESS compile-time option is designed to force
	 * more frequent reallocs and hence provide more opportunities for
	 * simulated OOM faults.  SQL_TEST_REALLOC_STRESS is generally used
	 * during testing only.  With SQL_TEST_REALLOC_STRESS grow the op array
	 * by the minimum* amount required until the size reaches 512.  Normal
	 * operation (without SQL_TEST_REALLOC_STRESS) is to double the current
	 * size of the op array or add 1KB of space, whichever is smaller.
	 */
#ifdef SQL_TEST_REALLOC_STRESS
	int nNew = (p->nOpAlloc >= 512 ? p->nOpAlloc * 2 : p->nOpAlloc + nOp);
#else
	int nNew = (p->nOpAlloc ? p->nOpAlloc * 2 : (int)(1024 / sizeof(Op)));
	UNUSED_PARAMETER(nOp);
#endif

	assert((unsigned)nOp <= (1024 / sizeof(Op)));
	assert(nNew >= (p->nOpAlloc + nOp));
	size_t size = nNew * sizeof(Op);
	pNew = sql_xrealloc(v->aOp, size);
	p->szOpAlloc = size;
	p->nOpAlloc = p->szOpAlloc / sizeof(Op);
	v->aOp = pNew;
	return 0;
}

#ifdef SQL_DEBUG
/*
 * This routine is just a convenient place to set a breakpoint
 * that will fire after each opcode is inserted in debug build.
 */
static void
test_addop_breakpoint(void)
{
	static int n = 0;
	n++;
	(void)n;
}
#endif

/*
 * Add a new instruction to the list of instructions current in the
 * VDBE.  Return the address of the new instruction.
 *
 * Parameters:
 *
 *    p               Pointer to the VDBE
 *
 *    op              The opcode for this instruction
 *
 *    p1, p2, p3      Operands
 *
 * Use the sqlVdbeResolveLabel() function to fix an address and
 * the sqlVdbeChangeP4() function to change the value of the P4
 * operand.
 */
static SQL_NOINLINE int
growOp3(Vdbe * p, int op, int p1, int p2, int p3)
{
	assert(p->pParse->nOpAlloc <= p->nOp);
	if (growOpArray(p, 1))
		return 1;
	assert(p->pParse->nOpAlloc > p->nOp);
	return sqlVdbeAddOp3(p, op, p1, p2, p3);
}

int
sqlVdbeAddOp3(Vdbe * p, int op, int p1, int p2, int p3)
{
	int i;
	VdbeOp *pOp;
	i = p->nOp;
	assert(p->magic == VDBE_MAGIC_INIT);
	assert(op >= 0 && op < 0xff);
	if (p->pParse->nOpAlloc <= i) {
		return growOp3(p, op, p1, p2, p3);
	}
	p->nOp++;
	pOp = &p->aOp[i];
	pOp->opcode = (u8) op;
	pOp->p5 = 0;
	pOp->p1 = p1;
	pOp->p2 = p2;
	pOp->p3 = p3;
	pOp->p4.p = 0;
	pOp->p4type = P4_NOTUSED;
#ifdef SQL_DEBUG
	test_addop_breakpoint();
#endif
	return i;
}

int
sqlVdbeAddOp0(Vdbe * p, int op)
{
	return sqlVdbeAddOp3(p, op, 0, 0, 0);
}

int
sqlVdbeAddOp1(Vdbe * p, int op, int p1)
{
	return sqlVdbeAddOp3(p, op, p1, 0, 0);
}

int
sqlVdbeAddOp2(Vdbe * p, int op, int p1, int p2)
{
	return sqlVdbeAddOp3(p, op, p1, p2, 0);
}

/* Generate code for an unconditional jump to instruction iDest
 */
int
sqlVdbeGoto(Vdbe * p, int iDest)
{
	return sqlVdbeAddOp3(p, OP_Goto, 0, iDest, 0);
}

/* Generate code to cause the string zStr to be loaded into
 * register iDest
 */
int
sqlVdbeLoadString(Vdbe * p, int iDest, const char *zStr)
{
	return sqlVdbeAddOp4(p, OP_String8, 0, iDest, 0, zStr, 0);
}

/*
 * Generate code that initializes multiple registers to string or integer
 * constants.  The registers begin with iDest and increase consecutively.
 * One register is initialized for each character in zTypes[].  For each
 * "s" character in zTypes[], the register is a string if the argument is
 * not NULL, or OP_Null if the value is a null pointer.  For each "i" character
 * in zTypes[], the register is initialized to an integer.
 */
void
sqlVdbeMultiLoad(Vdbe * p, int iDest, const char *zTypes, ...)
{
	va_list ap;
	int i;
	char c;
	va_start(ap, zTypes);
	for (i = 0; (c = zTypes[i]) != 0; i++) {
		if (c == 's') {
			const char *z = va_arg(ap, const char *);
			sqlVdbeAddOp4(p, z == 0 ? OP_Null : OP_String8, 0,
					  iDest++, 0, z, 0);
		} else {
			assert(c == 'i');
			sqlVdbeAddOp2(p, OP_Integer, va_arg(ap, int),
					  iDest++);
		}
	}
	va_end(ap);
}

/*
 * Add an opcode that includes the p4 value as a pointer.
 */
int
sqlVdbeAddOp4(Vdbe * p,	/* Add the opcode to this VM */
		  int op,	/* The new opcode */
		  int p1,	/* The P1 operand */
		  int p2,	/* The P2 operand */
		  int p3,	/* The P3 operand */
		  const char *zP4,	/* The P4 operand */
		  int p4type)	/* P4 operand type */

{
	int addr = sqlVdbeAddOp3(p, op, p1, p2, p3);
	sqlVdbeChangeP4(p, addr, zP4, p4type);
	return addr;
}

/*
 * Add an opcode that includes the p4 value as an integer.
 */
int
sqlVdbeAddOp4Int(Vdbe * p,	/* Add the opcode to this VM */
		     int op,	/* The new opcode */
		     int p1,	/* The P1 operand */
		     int p2,	/* The P2 operand */
		     int p3,	/* The P3 operand */
		     int p4)	/* The P4 operand as an integer */
{
	int addr = sqlVdbeAddOp3(p, op, p1, p2, p3);
	VdbeOp *pOp = &p->aOp[addr];
	pOp->p4type = P4_INT32;
	pOp->p4.i = p4;
	return addr;
}

int
sql_vdbe_add_op4_int64(Vdbe *p, int p1, int p2, int p3, int64_t p4)
{
	int addr = sqlVdbeAddOp3(p, OP_Int64, p1, p2, p3);
	VdbeOp *pOp = &p->aOp[addr];
	pOp->p4type = P4_INT64;
	pOp->p4.i64 = p4;
	return addr;
}

int
sql_vdbe_add_op4_uint64(Vdbe *p, int p1, int p2, int p3, int64_t p4)
{
	int addr = sqlVdbeAddOp3(p, OP_Int64, p1, p2, p3);
	VdbeOp *pOp = &p->aOp[addr];
	pOp->p4type = P4_UINT64;
	pOp->p4.i64 = p4;
	return addr;
}

int
sql_vdbe_add_op4_real(Vdbe *p, int p1, int p2, int p3, double p4)
{
	int addr = sqlVdbeAddOp3(p, OP_Real, p1, p2, p3);
	VdbeOp *pOp = &p->aOp[addr];
	pOp->p4type = P4_REAL;
	pOp->p4.real = p4;
	return addr;
}

/* Insert the end of a co-routine
 */
void
sqlVdbeEndCoroutine(Vdbe * v, int regYield)
{
	sqlVdbeAddOp1(v, OP_EndCoroutine, regYield);

	/* Clear the temporary register cache, thereby ensuring that each
	 * co-routine has its own independent set of registers, because co-routines
	 * might expect their registers to be preserved across an OP_Yield, and
	 * that could cause problems if two or more co-routines are using the same
	 * temporary register.
	 */
	v->pParse->nTempReg = 0;
	v->pParse->nRangeReg = 0;
}

/*
 * Create a new symbolic label for an instruction that has yet to be
 * coded.  The symbolic label is really just a negative number.  The
 * label can be used as the P2 value of an operation.  Later, when
 * the label is resolved to a specific address, the VDBE will scan
 * through its operation list and change all values of P2 which match
 * the label into the resolved address.
 *
 * The VDBE knows that a P2 value is a label because labels are
 * always negative and P2 values are suppose to be non-negative.
 * Hence, a negative P2 value is a label that has yet to be resolved.
 *
 * Zero is returned if a malloc() fails.
 */
int
sqlVdbeMakeLabel(Vdbe * v)
{
	Parse *p = v->pParse;
	int i = p->nLabel++;
	assert(v->magic == VDBE_MAGIC_INIT);
	if ((i & (i - 1)) == 0) {
		p->aLabel = sql_xrealloc(p->aLabel,
					 (i * 2 + 1) * sizeof(p->aLabel[0]));
	}
	if (p->aLabel) {
		p->aLabel[i] = -1;
	}
	return ADDR(i);
}

/*
 * Resolve label "x" to be the address of the next instruction to
 * be inserted.  The parameter "x" must have been obtained from
 * a prior call to sqlVdbeMakeLabel().
 */
void
sqlVdbeResolveLabel(Vdbe * v, int x)
{
	Parse *p = v->pParse;
	int j = ADDR(x);
	assert(v->magic == VDBE_MAGIC_INIT);
	assert(j < p->nLabel);
	assert(j >= 0);
	if (p->aLabel) {
		p->aLabel[j] = v->nOp;
	}
}

/*
 * Mark the VDBE as one that can only be run one time.
 */
void
sqlVdbeRunOnlyOnce(Vdbe * p)
{
	p->runOnlyOnce = 1;
}

/*
 * This routine is called after all opcodes have been inserted.  It loops
 * through all the opcodes and fixes up some details.
 *
 * (1) For each jump instruction with a negative P2 value (a label)
 *     resolve the P2 value to an actual address.
 *
 * (2) Initialize the p4.xAdvance pointer on opcodes that use it.
 *
 * (3) Reclaim the memory allocated for storing labels.
 *
 * This routine will only function correctly if the mkopcodeh.sh generator
 * script numbers the opcodes correctly.  Changes to this routine must be
 * coordinated with changes to mkopcodeh.sh.
 */
static void
resolveP2Values(Vdbe * p)
{
	Op *pOp;
	Parse *pParse = p->pParse;
	int *aLabel = pParse->aLabel;
	pOp = &p->aOp[p->nOp - 1];
	while (1) {

		/* Only JUMP opcodes and the short list of special opcodes in the switch
		 * below need to be considered.  The mkopcodeh.sh generator script groups
		 * all these opcodes together near the front of the opcode list.  Skip
		 * any opcode that does not need processing by virtual of the fact that
		 * it is larger than SQL_MX_JUMP_OPCODE, as a performance optimization.
		 */
		if (pOp->opcode <= SQL_MX_JUMP_OPCODE) {
			/* NOTE: Be sure to update mkopcodeh.sh when adding or removing
			 * cases from this switch!
			 */
			switch (pOp->opcode) {
			case OP_Next:
			case OP_NextIfOpen:
			case OP_SorterNext:{
					pOp->p4.xAdvance = sqlCursorNext;
					pOp->p4type = P4_ADVANCE;
					break;
				}
			case OP_Prev:
			case OP_PrevIfOpen:{
					pOp->p4.xAdvance = sqlCursorPrevious;
					pOp->p4type = P4_ADVANCE;
					break;
				}
			}
			if ((sqlOpcodeProperty[pOp->opcode] & OPFLG_JUMP) !=
			    0 && pOp->p2 < 0) {
				assert(ADDR(pOp->p2) < pParse->nLabel);
				pOp->p2 = aLabel[ADDR(pOp->p2)];
			}
		}
		if (pOp == p->aOp)
			break;
		pOp--;
	}
	sql_xfree(pParse->aLabel);
	pParse->aLabel = 0;
	pParse->nLabel = 0;
}

/*
 * Return the address of the next instruction to be inserted.
 */
int
sqlVdbeCurrentAddr(Vdbe * p)
{
	assert(p->magic == VDBE_MAGIC_INIT);
	return p->nOp;
}

/*
 * This function returns a pointer to the array of opcodes associated with
 * the Vdbe passed as the first argument. It is the callers responsibility
 * to arrange for the returned array to be eventually freed using the
 * vdbeFreeOpArray() function.
 *
 * Before returning, *pnOp is set to the number of entries in the returned
 * array.
 */
struct VdbeOp *
sqlVdbeTakeOpArray(struct Vdbe *p, int *pnOp)
{
	VdbeOp *aOp = p->aOp;
	assert(aOp != NULL);

	resolveP2Values(p);
	*pnOp = p->nOp;
	p->aOp = 0;
	return aOp;
}

VdbeOpSynopsisAux *
vdbe_take_synopsis_aux(struct Vdbe *p)
{
	if (p->explain_data == NULL)
		return NULL;
	VdbeOpSynopsisAux *aux = p->explain_data->synopsis_aux;
	p->explain_data->synopsis_aux = NULL;
	return aux;
}

/*
 * Change the value of the opcode, or P1, P2, P3, or P5 operands
 * for a specific instruction.
 */
void
sqlVdbeChangeOpcode(Vdbe * p, u32 addr, u8 iNewOpcode)
{
	sqlVdbeGetOp(p, addr)->opcode = iNewOpcode;
}

void
sqlVdbeChangeP1(Vdbe * p, u32 addr, int val)
{
	sqlVdbeGetOp(p, addr)->p1 = val;
}

void
sqlVdbeChangeP2(Vdbe * p, u32 addr, int val)
{
	sqlVdbeGetOp(p, addr)->p2 = val;
}

void
sqlVdbeChangeP3(Vdbe * p, u32 addr, int val)
{
	sqlVdbeGetOp(p, addr)->p3 = val;
}

void
sqlVdbeChangeP5(Vdbe * p, int p5)
{
	assert(p->nOp > 0);
	if (p->nOp > 0)
		p->aOp[p->nOp - 1].p5 = p5;
}

/*
 * Change the P2 operand of instruction addr so that it points to
 * the address of the next instruction to be coded.
 */
void
sqlVdbeJumpHere(Vdbe * p, int addr)
{
	sqlVdbeChangeP2(p, addr, p->nOp);
}

/**
 * Free the space allocated for aOp and any p4 values allocated for the opcodes
 * contained within. If aOp is not NULL it is assumed to contain nOp entries.
 */
static void
vdbeFreeOpArray(struct VdbeOp *aOp, int nOp);

static void
freeP4(int p4type, void *p4)
{
	switch (p4type) {
	case P4_FUNCCTX:{
			sql_context_delete(p4);
			break;
		}
	case P4_DEC:
	case P4_DYNAMIC:
	case P4_INTARRAY:{
			sql_xfree(p4);
			break;
		}
	case P4_KEYINFO:
		sql_key_info_unref(p4);
		break;
	case P4_MEM:
		sqlValueFree((sql_value *) p4);
		break;
	default:
		break;
	}
}

static void
vdbeFreeOpArray(struct VdbeOp *aOp, int nOp)
{
	if (aOp) {
		Op *pOp;
		for (pOp = aOp; pOp < &aOp[nOp]; pOp++) {
			if (pOp->p4type)
				freeP4(pOp->p4type, pOp->p4.p);
		}
	}
	sql_xfree(aOp);
}

/** Free the synopsis data of a program, which can be NULL. */
static void
vdbe_synopsis_aux_delete(VdbeOpSynopsisAux *aux)
{
	if (aux == NULL)
		return;
	for (int i = 0; i < aux->count; i++)
		sql_xfree(aux->items[i].text);
	sql_xfree(aux);
}

/**
 * Set the text of the instruction at an address. Take the string.
 * capacity is the number of instructions that the program has memory
 * for: the items grow to it, so *paux can change.
 */
static void
vdbe_synopsis_aux_set(VdbeOpSynopsisAux **paux, int addr, char *text,
		      bool is_obj_name, int capacity)
{
	VdbeOpSynopsisAux *aux = *paux;
	int old_count = aux != NULL ? aux->count : 0;
	if (addr >= old_count) {
		int count = MAX(capacity, addr + 1);
		size_t size = sizeof(aux->items[0]);
		aux = sql_xrealloc(aux, sizeof(*aux) + count * size);
		memset(aux->items + old_count, 0,
		       (count - old_count) * size);
		aux->count = count;
		*paux = aux;
	}
	sql_xfree(aux->items[addr].text);
	aux->items[addr].text = text;
	aux->items[addr].is_obj_name = is_obj_name;
}

/** Remove the text of the instruction at an address, if it has one. */
static void
vdbe_synopsis_aux_clear(VdbeOpSynopsisAux *aux, int addr)
{
	if (aux == NULL || addr >= aux->count)
		return;
	sql_xfree(aux->items[addr].text);
	aux->items[addr].text = NULL;
	aux->items[addr].is_obj_name = false;
}

/** Get the text of the instruction at an address, NULL if none. */
static const char *
vdbe_synopsis_aux_get(const VdbeOpSynopsisAux *aux, int addr,
		      bool *is_obj_name)
{
	if (aux == NULL || addr >= aux->count)
		return NULL;
	*is_obj_name = aux->items[addr].is_obj_name;
	return aux->items[addr].text;
}

/*
 * Link the SubProgram object passed as the second argument into the linked
 * list at Vdbe.pSubProgram. This list is used to delete all sub-program
 * objects when the VM is no longer required.
 */
void
sqlVdbeLinkSubProgram(Vdbe * pVdbe, SubProgram * p)
{
	p->pNext = pVdbe->pProgram;
	pVdbe->pProgram = p;
}

/*
 * Change the opcode at addr into OP_Noop
 */
int
sqlVdbeChangeToNoop(Vdbe * p, int addr)
{
	VdbeOp *pOp;
	assert(addr >= 0 && addr < p->nOp);
	pOp = &p->aOp[addr];
	freeP4(pOp->p4type, pOp->p4.p);
	pOp->p4type = P4_NOTUSED;
	pOp->p4.z = 0;
	pOp->opcode = OP_Noop;
	/* The comment was for the instruction that is not there now. */
	if (p->explain_data != NULL)
		vdbe_synopsis_aux_clear(p->explain_data->synopsis_aux, addr);
	return 1;
}

/*
 * If the last opcode is "op" and it is not a jump destination,
 * then remove it.  Return true if and only if an opcode was removed.
 */
int
sqlVdbeDeletePriorOpcode(Vdbe * p, u8 op)
{
	if (p->nOp > 0 && p->aOp[p->nOp - 1].opcode == op) {
		return sqlVdbeChangeToNoop(p, p->nOp - 1);
	} else {
		return 0;
	}
}

/*
 * Change the value of the P4 operand for a specific instruction.
 *
 * If n>=0 then the P4 operand is dynamic, meaning that a copy of
 * the string is made into memory obtained from malloc().
 * A value of n==0 means copy bytes of zP4 up to and including the
 * first null byte.  If n>0 then copy n+1 bytes of zP4.
 *
 * Other values of n (P4_STATIC, P4_COLLSEQ etc.) indicate that zP4 points
 * to a string or structure that is guaranteed to exist for the lifetime of
 * the Vdbe. In these cases we can just copy the pointer.
 *
 * If addr<0 then change P4 on the most recently inserted instruction.
 */
static void SQL_NOINLINE
vdbeChangeP4Full(Vdbe * p, Op * pOp, const char *zP4, int n)
{
	if (pOp->p4type) {
		freeP4(pOp->p4type, pOp->p4.p);
		pOp->p4type = 0;
		pOp->p4.p = 0;
	}
	if (n < 0) {
		sqlVdbeChangeP4(p, (int)(pOp - p->aOp), zP4, n);
	} else {
		if (n == 0)
			n = sqlStrlen30(zP4);
		pOp->p4.z = sql_xstrndup(zP4, n);
		pOp->p4type = P4_DYNAMIC;
	}
}

void
sqlVdbeChangeP4(Vdbe * p, int addr, const char *zP4, int n)
{
	Op *pOp;
	assert(p != 0);
	assert(p->magic == VDBE_MAGIC_INIT);
	assert(p->aOp != 0);
	assert(p->nOp > 0);
	assert(addr < p->nOp);
	if (addr < 0) {
		addr = p->nOp - 1;
	}
	pOp = &p->aOp[addr];
	if (n >= 0 || pOp->p4type) {
		vdbeChangeP4Full(p, pOp, zP4, n);
		return;
	}
	if (n == P4_INT32) {
		/* Note: this cast is safe, because the origin data point was an int
		 * that was cast to a (const char *).
		 */
		pOp->p4.i = SQL_PTR_TO_INT(zP4);
		pOp->p4type = P4_INT32;
	} if (n == P4_BOOL) {
		pOp->p4.b = *(bool*)zP4;
		pOp->p4type = P4_BOOL;
	} else {
		assert(n < 0);
		pOp->p4.p = (void *)zP4;
		pOp->p4type = (signed char)n;
	}
}

/*
 * Change the P4 operand of the most recently coded instruction
 * to the value defined by the arguments.  This is a high-speed
 * version of sqlVdbeChangeP4().
 *
 * The P4 operand must not have been previously defined.  And the new
 * P4 must not be P4_INT32.  Use sqlVdbeChangeP4() in either of
 * those cases.
 */
void
sqlVdbeAppendP4(Vdbe * p, void *pP4, int n)
{
	VdbeOp *pOp;
	assert(n != P4_INT32);
	assert(n <= 0);
	assert(pP4 != 0);
	assert(p->nOp > 0);
	pOp = &p->aOp[p->nOp - 1];
	assert(pOp->p4type == P4_NOTUSED);
	pOp->p4type = n;
	pOp->p4.p = pP4;
}

/**
 * Check that a program keeps the comments and the object names of its
 * instructions: EXPLAIN shows them, and a debug build prints them in the
 * trace and in the listing. EXPLAIN QUERY PLAN does not show them.
 */
static bool
vdbe_has_synopsis_aux(const struct Vdbe *p)
{
	return p->explain_data != NULL &&
	       p->explain_data->mode != EXPLAIN_MODE_QUERY_PLAN;
}

/*
 * Change the comment or the object name of the most recently coded
 * instruction, if the program keeps them.
 */
static void
vdbeVComment(Vdbe *p, bool is_obj_name, const char *zFormat, va_list ap)
{
	if (p == NULL || p->nOp == 0 || !vdbe_has_synopsis_aux(p))
		return;
	assert(p->aOp);
	vdbe_synopsis_aux_set(&p->explain_data->synopsis_aux, p->nOp - 1,
			      sqlVMPrintf(zFormat, ap), is_obj_name,
			      p->pParse->nOpAlloc);
}

/**
 * Find the sub-program that has an instruction. Return NULL if none has
 * it: then the instruction is in the main program.
 */
static const struct SubProgram *
vdbe_op_sub_program(const struct Vdbe *p, const struct VdbeOp *op)
{
	for (const struct SubProgram *sub = p->pProgram; sub != NULL;
	     sub = sub->pNext) {
		if (op >= sub->aOp && op < sub->aOp + sub->nOp)
			return sub;
	}
	return NULL;
}

/**
 * Get the comment or the object name of an instruction of the program or
 * of one of its sub-programs, NULL if it has none.
 */
static const char *
vdbe_op_synopsis_aux(const struct Vdbe *p, const struct VdbeOp *op,
		     bool *is_obj_name)
{
	/*
	 * While a sub-program runs, Vdbe.aOp is the array of the
	 * sub-program, so look in the sub-programs first.
	 */
	const struct SubProgram *sub = vdbe_op_sub_program(p, op);
	if (sub != NULL) {
		return vdbe_synopsis_aux_get(sub->synopsis_aux,
					     op - sub->aOp, is_obj_name);
	}
	if (p->explain_data == NULL || p->aOp == NULL || op < p->aOp ||
	    op >= p->aOp + p->nOp)
		return NULL;
	return vdbe_synopsis_aux_get(p->explain_data->synopsis_aux,
				     op - p->aOp, is_obj_name);
}

void
sqlVdbeComment(Vdbe *p, const char *zFormat, ...)
{
	va_list ap;
	va_start(ap, zFormat);
	vdbeVComment(p, false, zFormat, ap);
	va_end(ap);
}

void
sqlVdbeSynopsisObjName(Vdbe *p, const char *zFormat, ...)
{
	va_list ap;
	va_start(ap, zFormat);
	vdbeVComment(p, true, zFormat, ap);
	va_end(ap);
}

void
sqlVdbeNoopComment(Vdbe *p, const char *zFormat, ...)
{
	/*
	 * A program that keeps no comments does not get the instruction:
	 * it would run and count as a step for nothing.
	 */
	if (p == NULL || !vdbe_has_synopsis_aux(p))
		return;
	sqlVdbeAddOp0(p, OP_Noop);
	va_list ap;
	va_start(ap, zFormat);
	vdbeVComment(p, false, zFormat, ap);
	va_end(ap);
}

/*
 * Return the opcode for a given address.  If the address is -1, then
 * return the most recently inserted opcode.
 */
VdbeOp *
sqlVdbeGetOp(Vdbe * p, int addr)
{
	assert(p->magic == VDBE_MAGIC_INIT);
	if (addr < 0) {
		addr = p->nOp - 1;
	}
	assert(addr >= 0 && addr < p->nOp);
	return &p->aOp[addr];
}

/*
 * Return an integer value for one of the parameters to the opcode pOp
 * determined by character c.
 */
static int
translateP(char c, const Op * pOp)
{
	if (c == '1')
		return pOp->p1;
	if (c == '2')
		return pOp->p2;
	if (c == '3')
		return pOp->p3;
	if (c == '4')
		return pOp->p4.i;
	return pOp->p5;
}

/**
 * Check that a synopsis has an operand at a position: "P1" to "P5", or
 * "PC", the address of the instruction. Other text, such as the "P" in
 * a flag name, is written as is.
 */
static bool
isSynopsisOperand(const char *z)
{
	return z[0] == 'P' && z[1] != '\0' && strchr("12345C", z[1]) != NULL;
}

/**
 * Check that a synopsis has "OBJ_NAME" at a position: the comment of the
 * instruction, which is the name of an object.
 */
static bool
isSynopsisObjName(const char *z)
{
	return strncmp(z, "OBJ_NAME", strlen("OBJ_NAME")) == 0;
}

/**
 * Read the offset of an operand in a synopsis: "+N" or "-N" right after
 * it, without spaces, as in "P3-1". Return the number of characters read,
 * 0 if there is no offset.
 */
static int
synopsisOffset(const char *z, int *offset)
{
	if ((z[0] != '+' && z[0] != '-') || !sqlIsdigit(z[1]))
		return 0;
	char *end;
	long n = strtol(z + 1, &end, 10);
	*offset = z[0] == '+' ? n : -n;
	return end - z;
}

/**
 * Print P4 of an instruction for its synopsis. A function or an aggregate
 * is its name, without the number of arguments that the column p4 shows.
 * A trigger program is the name of its trigger alone.
 */
static void
displaySynopsisP4(const Op *pOp, const char *zP4, char *zTemp, int nTemp)
{
	const char *name = zP4;
	if (pOp->p4type == P4_FUNCCTX)
		name = pOp->p4.pCtx->func->def->name;
	else if (pOp->p4type == P4_FUNC)
		name = pOp->p4.func->def->name;
	else if (pOp->p4type == P4_SUBPROGRAM &&
		 pOp->p4.pProgram->name != NULL)
		name = pOp->p4.pProgram->name;
	sql_snprintf(nTemp, zTemp, "%s", name);
}

/**
 * Print an operand of an instruction by the name of what it identifies:
 * P2 of OP_Cast is a type, and P2 of OP_OpenSpace is the ID of a space.
 * Return false and print nothing for other operands, and for an ID
 * without a name.
 */
static bool
displayOperandName(const Op *pOp, char c, char *zTemp, int nTemp)
{
	if (c != '2')
		return false;
	if (pOp->opcode == OP_Cast && pOp->p2 >= 0 &&
	    pOp->p2 < field_type_MAX) {
		sql_snprintf(nTemp, zTemp, "%s", field_type_strs[pOp->p2]);
		return true;
	}
	if (pOp->opcode == OP_OpenSpace) {
		struct space *space = space_by_id(pOp->p2);
		if (space == NULL)
			return false;
		sql_snprintf(nTemp, zTemp, "'%s'", space->def->name);
		return true;
	}
	return false;
}

/** Cut an incomplete UTF-8 character from the end of a string. */
static void
displayTrimUtf8(char *str)
{
	int len = strlen(str);
	/* Go back over the continuation bytes to the lead byte. */
	int lead = len - 1;
	while (lead >= 0 && len - lead < 4 &&
	       ((unsigned char)str[lead] & 0xC0) == 0x80)
		lead--;
	if (lead < 0)
		return;
	unsigned char c = str[lead];
	int size = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
	if (len - lead < size)
		str[lead] = '\0';
}

/*
 * Compute the synopsis of an instruction, which EXPLAIN shows in the
 * column "pseudocode".
 *
 * The Synopsis: fields in comments in the vdbe.c source file get converted
 * to the sqlOpcodeSynopsis() function, which selects the synopsis of an
 * instruction by its operands.  In the absence of other comments, this
 * synopsis becomes the comment on the opcode.  Some translation occurs:
 *
 *       "PX@PY"   ->  "r[X..X+Y-1]"  or "r[x]" if y is 0 or 1
 *       "PX@PY+1" ->  "r[X..X+Y]"    or "r[x]" if y is 0
 *       "PX@2PY"  ->  "r[X..X+2*Y-1]"
 *       "PY..PY"  ->  "r[X..Y]"      or "r[x]" if y<=x
 *       "PX+PY"   ->  "r[X+Y]"
 *       "PX-1"    ->  "X-1", any number after "+" or "-"
 *       "PC"      ->  the address of the instruction
 *       "OBJ_NAME" ->  the comment of the instruction that is a name
 *
 * See displayOperandName() for the operands that are written by name.
 */
static int
displaySynopsis(const struct Vdbe *p,	/* The program of the opcode */
		const Op *pOp,	/* The opcode to be commented */
		int addr,	/* The address of the opcode */
		const char *zP4,	/* Previously obtained value for P4 */
		char *zTemp,	/* Write result here */
		int nTemp)	/* Space available in zTemp[] */
{
	bool is_obj_name = false;
	const char *zComment = vdbe_op_synopsis_aux(p, pOp, &is_obj_name);
	bool has_comment = zComment != NULL && zComment[0] != '\0';
	const char *zSynopsis =
		sqlOpcodeSynopsis(pOp, has_comment && is_obj_name);
	int ii, jj;
	if (zSynopsis[0] != '\0') {
		int seenCom = 0;
		char c;
		for (ii = jj = 0; jj < nTemp - 1 && (c = zSynopsis[ii]) != 0;
		     ii++) {
			if (isSynopsisObjName(&zSynopsis[ii])) {
				sql_snprintf(nTemp - jj, zTemp + jj, "%s",
					     has_comment ? zComment : "");
				jj += sqlStrlen30(zTemp + jj);
				seenCom = 1;
				ii += strlen("OBJ_NAME") - 1;
			} else if (isSynopsisOperand(&zSynopsis[ii])) {
				c = zSynopsis[++ii];
				if (c == '4') {
					displaySynopsisP4(pOp, zP4, zTemp + jj,
							  nTemp - jj);
				} else if (c == 'C') {
					sql_snprintf(nTemp - jj, zTemp + jj,
						     "%d", addr);
				} else if (displayOperandName(pOp, c,
							      zTemp + jj,
							      nTemp - jj)) {
					/* Written by its name. */
				} else {
					int v1 = translateP(c, pOp);
					int v2;
					/* A sum of operands: P3+P1. */
					if (strncmp(zSynopsis + ii + 1, "+P", 2)
					    == 0) {
						ii += 3;
						v1 += translateP(zSynopsis[ii],
								 pOp);
					}
					/* An offset: P3-1. */
					int offset = 0;
					ii += synopsisOffset(zSynopsis + ii + 1,
							     &offset);
					v1 += offset;
					sql_snprintf(nTemp - jj, zTemp + jj,
							 "%d", v1);
					/* "@2P1" is twice as many as "@P1". */
					int factor = 0;
					if (strncmp(zSynopsis + ii + 1, "@P", 2)
					    == 0)
						factor = 1;
					else if (strncmp(zSynopsis + ii + 1,
							 "@2P", 3) == 0)
						factor = 2;
					if (factor != 0) {
						ii += factor + 2;
						jj +=
						    sqlStrlen30(zTemp + jj);
						v2 = factor *
						     translateP(zSynopsis[ii],
								pOp);
						if (strncmp
						    (zSynopsis + ii + 1, "+1",
						     2) == 0) {
							ii += 2;
							v2++;
						}
						if (v2 > 1) {
							sql_snprintf(nTemp -
									 jj,
									 zTemp +
									 jj,
									 "..%d",
									 v1 +
									 v2 -
									 1);
						}
					} else
					    if (strncmp
						(zSynopsis + ii + 1, "..P3",
						 4) == 0 && pOp->p3 <= v1) {
						ii += 4;
					}
				}
				jj += sqlStrlen30(zTemp + jj);
			} else {
				zTemp[jj++] = c;
			}
		}
		if (!seenCom && jj < nTemp - 5 && has_comment) {
			sql_snprintf(nTemp - jj, zTemp + jj, "  # %s",
				     zComment);
			jj += sqlStrlen30(zTemp + jj);
		}
		if (jj < nTemp)
			zTemp[jj] = 0;
	} else if (zComment != NULL) {
		sql_snprintf(nTemp, zTemp, "%s", zComment);
	} else {
		zTemp[0] = 0;
	}
	/* The text can be cut at the end of the buffer. */
	displayTrimUtf8(zTemp);
	return sqlStrlen30(zTemp);
}

/**
 * Describe the P4 of OP_Blob. MsgPack, which is a subtype of the blob and
 * not a type of P4, is decoded to a readable form. Other data is a hex
 * literal, which ends with "..." if it is too long for the buffer.
 */
static void
displayP4Blob(const Op *pOp, char *zTemp, int nTemp)
{
	assert(nTemp >= 20);
	zTemp[0] = '\0';
	if (pOp->p4.z == NULL)
		return;
	if (pOp->p3 == SQL_SUBTYPE_MSGPACK) {
		if (mp_snprint(zTemp, nTemp, pOp->p4.z) >= nTemp)
			displayTrimUtf8(zTemp);
		return;
	}
	/* The room for "x'", for "'" or "...", and for the end. */
	static const char digits[] = "0123456789ABCDEF";
	int count = MIN(pOp->p1, (nTemp - 6) / 2);
	char *pos = zTemp;
	*pos++ = 'x';
	*pos++ = '\'';
	for (int i = 0; i < count; i++) {
		unsigned char byte = pOp->p4.z[i];
		*pos++ = digits[byte >> 4];
		*pos++ = digits[byte & 0xF];
	}
	strlcpy(pos, count < pOp->p1 ? "..." : "'", zTemp + nTemp - pos);
}

/**
 * Describe the P4 of an instruction that keeps a structure there, not
 * a string. Return false if the instruction is not one of them.
 */
static bool
displayP4Struct(const Op *pOp, StrAccum *x)
{
	switch (pOp->opcode) {
	case OP_OpenTEphemeral:
		sqlXPrintf(x, "%u fields", pOp->p4.space_info->field_count);
		return true;
	case OP_ApplyType:
		for (int i = 0; i < pOp->p2; i++) {
			/* field_type_MAX is for a value of any type. */
			enum field_type type = pOp->p4.types[i];
			if (type >= field_type_MAX)
				type = FIELD_TYPE_ANY;
			sqlXPrintf(x, "%s%s", i == 0 ? "" : ",",
				   field_type_strs[type]);
		}
		return true;
	default:
		return false;
	}
}

/** Get the name of a collation, or its properties if it has no name. */
static const char *
collName(const struct coll *coll)
{
	struct coll_id *coll_id = coll_by_coll(coll);
	return coll_id != NULL ? coll_id->name : coll->fingerprint;
}

/*
 * Compute a string that describes the P4 parameter for an opcode.
 * Use zTemp for any required temporary buffer space.
 */
static char *
displayP4(Op * pOp, char *zTemp, int nTemp)
{
	if (pOp->opcode == OP_Blob) {
		displayP4Blob(pOp, zTemp, nTemp);
		return zTemp;
	}
	char *zP4 = zTemp;
	StrAccum x;
	assert(nTemp >= 20);
	sqlStrAccumInit(&x, zTemp, nTemp, 0);
	if (displayP4Struct(pOp, &x)) {
		sqlStrAccumFinish(&x);
		return zTemp;
	}
	switch (pOp->p4type) {
	case P4_KEYINFO:{
			struct key_def *def = NULL;
			if (pOp->p4.key_info != NULL)
				def = sql_key_info_to_key_def(pOp->p4.key_info);
			if (def == NULL) {
				sqlXPrintf(&x, "k[NULL]");
			} else {
				sqlXPrintf(&x, "k(%d", def->part_count);
				for (int j = 0; j < (int)def->part_count; j++) {
					struct coll *coll = def->parts[j].coll;
					const char *coll_str;
					if (coll == NULL)
						coll_str = "B";
					else
						coll_str = collName(coll);
					const char *sort_order = "";
					if (def->parts[j].sort_order ==
					    SORT_ORDER_DESC) {
						sort_order = "-";
					}
					sqlXPrintf(&x, ",%s%s",
						       sort_order,
						       coll_str);
				}
				sqlStrAccumAppend(&x, ")", 1);
			}
			break;
		}
	case P4_COLLSEQ:{
			struct coll *pColl = pOp->p4.pColl;
			if (pColl != NULL)
				sqlXPrintf(&x, "(%.100s)", collName(pColl));
			else
				sqlXPrintf(&x, "(binary)");
			break;
		}
	case P4_FUNC:{
			struct func *func = pOp->p4.func;
			sqlXPrintf(&x, "%s(%d)", func->def->name,
				   func->def->param_count);
			break;
		}
	case P4_FUNCCTX:{
			struct func *func = pOp->p4.pCtx->func;
			sqlXPrintf(&x, "%s(%d)", func->def->name,
				   func->def->param_count);
			break;
		}
	case P4_BOOL:
			sqlXPrintf(&x, "%d", pOp->p4.b);
			break;
	case P4_INT64:{
			sqlXPrintf(&x, "%lld", pOp->p4.i64);
			break;
		}
	case P4_UINT64: {
		sqlXPrintf(&x, "%llu", (uint64_t)pOp->p4.i64);
			break;
	}
	case P4_INT32:{
			sqlXPrintf(&x, "%d", pOp->p4.i);
			break;
		}
	case P4_REAL:{
			sqlXPrintf(&x, "%.16g", pOp->p4.real);
			break;
		}
	case P4_DEC:{
			sqlXPrintf(&x, "%s", decimal_str(pOp->p4.dec));
			break;
		}
	case P4_MEM:{
			const char *value = mem_str(pOp->p4.pMem);
			sqlStrAccumAppend(&x, value, strlen(value));
			break;
		}
	case P4_INTARRAY:{
			int i;
			int *ai = pOp->p4.ai;
			/*
			 * The first element of an INTARRAY is always
			 * the count of the number of elements to follow.
			 */
			int n = ai[0];
			for (i = 1; i <= n; i++) {
				sqlXPrintf(&x, "%c%d", i == 1 ? '[' : ',',
					   ai[i]);
			}
			sqlStrAccumAppend(&x, "]", 1);
			break;
		}
	case P4_SUBPROGRAM:{
			/* Each sub-program is the program of a trigger. */
			const char *name = pOp->p4.pProgram->name;
			if (name != NULL)
				sqlXPrintf(&x, "trigger %s", name);
			else
				sqlXPrintf(&x, "program");
			break;
		}
	case P4_PTR:{
			/* An opaque pointer tells nothing. */
			zTemp[0] = 0;
			break;
		}
	case P4_ADVANCE:{
			zTemp[0] = 0;
			break;
		}
	default:{
			zP4 = pOp->p4.z;
			if (zP4 == 0) {
				zP4 = zTemp;
				zTemp[0] = 0;
			}
		}
	}
	sqlStrAccumFinish(&x);
	assert(zP4 != 0);
	/* The text can be cut at the end of the buffer. */
	if (zP4 == zTemp)
		displayTrimUtf8(zTemp);
	return zP4;
}

/*
 * Return a detail string for an OP_Explain opcode backed by
 * struct sql_explain_hook.
 */
static const char *
op_explain_hook_detail(Op *pOp)
{
	assert(pOp->opcode == OP_Explain);
	assert(pOp->p4type == P4_PTR);
	if (pOp->p4.p == NULL) {
		diag_set(ClientError, ER_SQL_EXECUTE,
			 "SQL explain hook is not installed");
		return NULL;
	}
	struct sql_explain_hook *hook = pOp->p4.p;
	if (hook->run == NULL) {
		diag_set(ClientError, ER_SQL_EXECUTE,
			 "SQL explain hook callback is not installed");
		return NULL;
	}
	struct sql_explain_hook_args args = {
		.select_id = pOp->p1,
		.order = pOp->p2,
		.from = pOp->p3,
		.ctx = hook->ctx,
	};
	const char *detail = hook->run(&args);
	if (detail == NULL) {
		diag_set(ClientError, ER_SQL_EXECUTE,
			 "SQL explain hook callback returned NULL");
		return NULL;
	}
	return detail;
}


#if defined(SQL_DEBUG)
/*
 * Print a single opcode.  This routine is used for debugging only.
 */
void
sqlVdbePrintOp(FILE *pOut, struct Vdbe *p, int pc, struct VdbeOp *pOp)
{
	char *zP4;
	char zPtr[256];
	char zCom[256];
	static const char *zFormat1 =
	    "%4d> %4d %-13s %4d %4d %4d %-13s %.2X %s\n";
	if (pOut == 0)
		pOut = stdout;
	zP4 = displayP4(pOp, zPtr, sizeof(zPtr));
	displaySynopsis(p, pOp, pc, zP4, zCom, sizeof(zCom));
	/* NB:  The sqlOpcodeName() function is implemented by code created
	 * by the mkopcodeh.awk and mkopcodec.awk scripts which extract the
	 * information from the vdbe.c source text
	 */
	fprintf(pOut, zFormat1, fiber_self()->fid, pc,
		sqlOpcodeName(pOp->opcode), pOp->p1, pOp->p2, pOp->p3, zP4,
		pOp->p5, zCom);
	fflush(pOut);
}
#endif

/*
 * Delete a VdbeFrame object and its contents. VdbeFrame objects are
 * allocated by the OP_Program opcode in sqlVdbeExec().
 */
void
sqlVdbeFrameDelete(VdbeFrame * p)
{
	int i;
	Mem *aMem = VdbeFrameMem(p);
	VdbeCursor **apCsr = (VdbeCursor **) & aMem[p->nChildMem];
	for (i = 0; i < p->nChildCsr; i++)
		sqlVdbeFreeCursor(apCsr[i]);
	releaseMemArray(aMem, p->nChildMem);
	sql_xfree(p);
}

/* Box-drawing characters, named as in Unicode. */
#define BOX_HORIZONTAL "\u2500"
#define BOX_VERTICAL "\u2502"
#define BOX_VERTICAL_AND_RIGHT "\u251c"
#define BOX_DOWN_AND_HORIZONTAL "\u252c"
#define BOX_UP_AND_HORIZONTAL "\u2534"
#define BOX_VERTICAL_AND_HORIZONTAL "\u253c"
#define BOX_ARC_DOWN_AND_RIGHT "\u256d"
#define BOX_ARC_UP_AND_RIGHT "\u2570"

/** The arrow of a jump source that is also a jump target. */
#define GRAPH_ARROW_BOTH "X"

/** The dot of backward jumps: U+00B7 MIDDLE DOT, from Latin-1. */
#define GRAPH_DOT "\u00b7"

/** Bits of a cell in a row of the EXPLAIN jump graph. */
enum {
	/** The lane of the cell goes up from the cell. */
	GRAPH_UP = 1 << 0,
	/** The lane of the cell goes down from the cell. */
	GRAPH_DOWN = 1 << 1,
	/** The lane of the cell goes right to the instruction. */
	GRAPH_LINK = 1 << 2,
	/** The cell is below the target of its lane: a backward jump. */
	GRAPH_BACK = 1 << 3,
	/**
	 * The cell links to the instruction by a backward jump: the
	 * instruction is below the target of the lane, or it is the target
	 * of a lane without forward jumps.
	 */
	GRAPH_BACK_LINK = 1 << 4,
};

/** A vertical line of the EXPLAIN jump graph. */
struct ExplainLane {
	/** The address that all jumps of the lane go to. */
	int target;
	/** The first address of the lane. */
	int first;
	/** The last address of the lane. */
	int last;
	/** The column of the lane, 0 is next to the addresses. */
	int column;
};

typedef struct ExplainLane ExplainLane;

/**
 * The jump graph of one program, the first column of EXPLAIN.
 * All jumps to one address share a lane. Shorter lanes are nearer
 * to the addresses.
 */
struct ExplainGraph {
	/** The instructions of the program. */
	const struct VdbeOp *ops;
	/** The number of instructions. */
	int op_count;
	/** The lanes, sorted by length. */
	ExplainLane *lanes;
	/** The number of lanes. */
	int lane_count;
	/** The lane of each address, -1 if no jump goes there. */
	int *lane_of;
	/** The number of columns. */
	int column_count;
	/**
	 * The lane in each column at each address, -1 if none. The lane
	 * at address a in column c is grid[c * op_count + a].
	 */
	int *grid;
	/**
	 * The addresses whose jumps are shown: a jump is shown if it
	 * starts or ends on one of them.
	 */
	const int *filter;
	/**
	 * The number of addresses in filter. 0 to show all jumps, -1 to
	 * show no jumps.
	 */
	int filter_count;
	/**
	 * True for each address that starts or ends a jump that is not
	 * shown: because of the lines, or because the target of the jump
	 * is not known before the run.
	 */
	bool *is_hidden;
	/** True if one address or more is hidden. */
	bool has_hidden;
};

/**
 * Check that an instruction is a comparison that stores its result in
 * the register P2 and does not jump to the address P2.
 */
static bool
explain_is_stored_comparison(const struct VdbeOp *op)
{
	switch (op->opcode) {
	case OP_Eq:
	case OP_Ne:
	case OP_Lt:
	case OP_Le:
	case OP_Gt:
	case OP_Ge:
		return (op->p5 & SQL_STOREP2) != 0;
	default:
		return false;
	}
}

/**
 * Check that a seek skips the instruction after it when it finds a row.
 * OP_SeekGE and OP_SeekLE do this if their cursor was opened for a seek
 * by equality: the next instruction, OP_IdxGT or OP_IdxLT, is then only
 * for the next iterations of the loop.
 */
static bool
explain_is_seek_with_skip(const struct VdbeOp *ops, int op_count, int addr)
{
	const struct VdbeOp *op = &ops[addr];
	if (op->opcode != OP_SeekGE && op->opcode != OP_SeekLE)
		return false;
	if (addr + 1 >= op_count || (ops[addr + 1].opcode != OP_IdxGT &&
				     ops[addr + 1].opcode != OP_IdxLT))
		return false;
	/*
	 * The hint is on the instruction that opens the cursor. It can be
	 * at any address, and more than one instruction can open the
	 * cursor: then the skip is possible if one of them has the hint.
	 */
	for (int i = 0; i < op_count; i++) {
		if (ops[i].opcode == OP_IteratorOpen && ops[i].p1 == op->p1 &&
		    (ops[i].p5 & OPFLAG_SEEKEQ) != 0)
			return true;
	}
	return false;
}

/**
 * Get the jump targets of an instruction to draw. Address 0 is not
 * a target: OP_Init is there, and some opcodes use 0 to tell that they
 * do not jump. A jump to the next instruction is not drawn.
 */
static int
explain_jump_targets(const struct VdbeOp *ops, int op_count, int addr,
		     int targets[3])
{
	const struct VdbeOp *op = &ops[addr];
	if ((sqlOpcodeProperty[op->opcode] & OPFLG_JUMP) == 0 ||
	    explain_is_stored_comparison(op))
		return 0;
	int addrs[3] = {op->p2, op->p1, op->p3};
	int addr_count = op->opcode == OP_Jump ? 3 : 1;
	if (explain_is_seek_with_skip(ops, op_count, addr)) {
		addrs[1] = addr + 2;
		addr_count = 2;
	}
	int count = 0;
	for (int i = 0; i < addr_count; i++) {
		if (addrs[i] > 0 && addrs[i] < op_count &&
		    addrs[i] != addr + 1)
			targets[count++] = addrs[i];
	}
	return count;
}

/** Check that a line of the graph is one of the given lines. */
static bool
explain_graph_has_line(const ExplainGraph *graph, int addr)
{
	for (int i = 0; i < graph->filter_count; i++) {
		if (graph->filter[i] == addr)
			return true;
	}
	return false;
}

/**
 * Check that the graph shows a jump: with lines given, only a jump that
 * starts or ends on one of them.
 */
static bool
explain_graph_shows(const ExplainGraph *graph, int addr, int target)
{
	return graph->filter_count == 0 ||
	       explain_graph_has_line(graph, addr) ||
	       explain_graph_has_line(graph, target);
}

/** Get the jump targets of an instruction that the graph shows. */
static int
explain_graph_targets(const ExplainGraph *graph, int addr,
		      int targets[3])
{
	int count = explain_jump_targets(graph->ops, graph->op_count, addr,
					 targets);
	int shown = 0;
	for (int i = 0; i < count; i++) {
		if (explain_graph_shows(graph, addr, targets[i]))
			targets[shown++] = targets[i];
	}
	return shown;
}

/**
 * Check that an instruction jumps to an address that it takes from a
 * register, so the target is not known before the run.
 */
static bool
explain_is_computed_jump(const struct VdbeOp *op)
{
	return op->opcode == OP_Yield || op->opcode == OP_Return ||
	       op->opcode == OP_EndCoroutine;
}

/** Compare the lanes by length, then by the first address. */
static int
explain_lane_cmp(const void *a, const void *b)
{
	const ExplainLane *lane_a = a;
	const ExplainLane *lane_b = b;
	int length_a = lane_a->last - lane_a->first;
	int length_b = lane_b->last - lane_b->first;
	if (length_a != length_b)
		return length_a < length_b ? -1 : 1;
	if (lane_a->first != lane_b->first)
		return lane_a->first < lane_b->first ? -1 : 1;
	return lane_a->target < lane_b->target ? -1 :
	       lane_a->target > lane_b->target;
}

/**
 * Make a lane for each jump target and sort the lanes by length. Mark
 * as hidden the two ends of each jump that the graph does not show, and
 * each instruction that jumps to an address that is not known before the
 * run.
 */
static void
explain_graph_add_lanes(ExplainGraph *graph)
{
	for (int addr = 0; addr < graph->op_count; addr++) {
		if (explain_is_computed_jump(&graph->ops[addr])) {
			graph->is_hidden[addr] = true;
			graph->has_hidden = true;
		}
		int targets[3];
		int count = explain_jump_targets(graph->ops, graph->op_count,
						 addr, targets);
		for (int i = 0; i < count; i++) {
			int target = targets[i];
			if (!explain_graph_shows(graph, addr, target)) {
				graph->is_hidden[addr] = true;
				graph->is_hidden[target] = true;
				graph->has_hidden = true;
				continue;
			}
			if (graph->lane_of[target] < 0) {
				graph->lane_of[target] = graph->lane_count;
				graph->lanes[graph->lane_count++] =
					(ExplainLane){
						.target = target,
						.first = target,
						.last = target,
					};
			}
			ExplainLane *lane =
				&graph->lanes[graph->lane_of[target]];
			lane->first = MIN(lane->first, addr);
			lane->last = MAX(lane->last, addr);
		}
	}
	qsort(graph->lanes, graph->lane_count, sizeof(graph->lanes[0]),
	      explain_lane_cmp);
	for (int i = 0; i < graph->lane_count; i++)
		graph->lane_of[graph->lanes[i].target] = i;
}

/** Check that no lane in a column touches the addresses of a lane. */
static bool
explain_column_is_free(const ExplainGraph *graph, int column,
		       const ExplainLane *lane)
{
	const int *cells = &graph->grid[column * graph->op_count];
	for (int addr = lane->first; addr <= lane->last; addr++) {
		if (cells[addr] >= 0)
			return false;
	}
	return true;
}

/**
 * Put each lane in the column nearest to the addresses where it does
 * not touch other lanes.
 */
static void
explain_graph_set_columns(ExplainGraph *graph)
{
	int op_count = graph->op_count;
	for (int i = 0; i < graph->lane_count; i++) {
		ExplainLane *lane = &graph->lanes[i];
		int column = 0;
		while (column < graph->column_count &&
		       !explain_column_is_free(graph, column, lane))
			column++;
		if (column == graph->column_count) {
			graph->column_count++;
			size_t size = graph->column_count * op_count *
				      sizeof(graph->grid[0]);
			graph->grid = sql_xrealloc(graph->grid, size);
			for (int addr = 0; addr < op_count; addr++)
				graph->grid[column * op_count + addr] = -1;
		}
		for (int addr = lane->first; addr <= lane->last; addr++)
			graph->grid[column * op_count + addr] = i;
		lane->column = column;
	}
}

/**
 * Check that an instruction jumps back to the start of a loop. The rules
 * are the ones that the SQLite shell uses to indent EXPLAIN: a backward
 * jump of Next, Prev or SorterNext, or a backward Goto to an instruction
 * that starts a loop. Other backward jumps, such as the Goto back to the
 * start of the program after the transaction begins, run once.
 */
static bool
explain_is_loop_end(const struct VdbeOp *ops, int addr)
{
	const struct VdbeOp *op = &ops[addr];
	if (op->p2 <= 0 || op->p2 >= addr)
		return false;
	switch (op->opcode) {
	case OP_Next:
	case OP_Prev:
	case OP_NextIfOpen:
	case OP_PrevIfOpen:
	case OP_SorterNext:
		return true;
	case OP_Goto:
		switch (ops[op->p2].opcode) {
		case OP_Yield:
		case OP_SeekLT:
		case OP_SeekGT:
		case OP_Rewind:
			return true;
		default:
			return op->p1 != 0;
		}
	default:
		return false;
	}
}

/**
 * Count the loops around each address of a program. A loop takes the
 * addresses from the target of its backward jump to the address before
 * the jump. The result is a new array.
 */
static int *
explain_loop_depth_new(const struct VdbeOp *ops, int op_count)
{
	int *depth = sql_xmalloc0(op_count * sizeof(depth[0]));
	/* First mark the loop bounds, then sum them up. */
	for (int addr = 0; addr < op_count; addr++) {
		if (!explain_is_loop_end(ops, addr))
			continue;
		depth[ops[addr].p2]++;
		depth[addr]--;
	}
	for (int addr = 1; addr < op_count; addr++)
		depth[addr] += depth[addr - 1];
	return depth;
}

/**
 * Make the jump graph of a program. The filter selects the jumps that it
 * shows, see ExplainGraph.
 */
static ExplainGraph *
explain_graph_new(const struct VdbeOp *ops, int op_count, const int *filter,
		  int filter_count)
{
	ExplainGraph *graph = sql_xmalloc0(sizeof(*graph));
	graph->ops = ops;
	graph->op_count = op_count;
	graph->filter = filter;
	graph->filter_count = filter_count;
	graph->lanes = sql_xmalloc(op_count * sizeof(graph->lanes[0]));
	graph->lane_of = sql_xmalloc(op_count * sizeof(graph->lane_of[0]));
	for (int addr = 0; addr < op_count; addr++)
		graph->lane_of[addr] = -1;
	graph->is_hidden = sql_xmalloc0(op_count * sizeof(graph->is_hidden[0]));
	explain_graph_add_lanes(graph);
	explain_graph_set_columns(graph);
	return graph;
}

static void
explain_graph_delete(ExplainGraph *graph)
{
	if (graph == NULL)
		return;
	sql_xfree(graph->lanes);
	sql_xfree(graph->lane_of);
	sql_xfree(graph->grid);
	sql_xfree(graph->is_hidden);
	sql_xfree(graph);
}

/**
 * Get the glyph of a cell that links to the instruction. A backward jump
 * is drawn with dots, as in the ASCII mode of radare2: "." at its target,
 * "`" at its source, and "+" at a source between the two ends of a lane.
 * Other links are box-drawing characters with round corners.
 */
static const char *
explain_graph_link_glyph(uint8_t cell, bool has_left)
{
	/* Indexed by GRAPH_UP | GRAPH_DOWN. */
	static const char *const back_glyphs[] = {GRAPH_DOT, "`", ".", "+"};
	/* Indexed by GRAPH_UP | GRAPH_DOWN | has_left << 2. */
	static const char *const link_glyphs[] = {
		BOX_HORIZONTAL, BOX_ARC_UP_AND_RIGHT, BOX_ARC_DOWN_AND_RIGHT,
		BOX_VERTICAL_AND_RIGHT, BOX_HORIZONTAL, BOX_UP_AND_HORIZONTAL,
		BOX_DOWN_AND_HORIZONTAL, BOX_VERTICAL_AND_HORIZONTAL,
	};
	if ((cell & GRAPH_BACK_LINK) != 0)
		return back_glyphs[cell & (GRAPH_UP | GRAPH_DOWN)];
	return link_glyphs[(cell & (GRAPH_UP | GRAPH_DOWN)) |
			   (has_left ? 4 : 0)];
}

/** Get the bits of the cell of a column at an address. */
static uint8_t
explain_graph_cell(const ExplainGraph *graph, int column, int addr,
		   const int *links, int link_count)
{
	int i = graph->grid[column * graph->op_count + addr];
	if (i < 0)
		return 0;
	const ExplainLane *lane = &graph->lanes[i];
	uint8_t cell = 0;
	if (lane->first < addr)
		cell |= GRAPH_UP;
	if (lane->last > addr)
		cell |= GRAPH_DOWN;
	if (lane->target < addr)
		cell |= GRAPH_BACK;
	for (int j = 0; j < link_count; j++) {
		if (links[j] != i)
			continue;
		cell |= GRAPH_LINK;
		/* A lane that starts at its target has no forward jumps. */
		if (lane->target < addr || lane->first == lane->target)
			cell |= GRAPH_BACK_LINK;
		break;
	}
	return cell;
}

/**
 * Make the row of the jump graph for an instruction. A jump source ends
 * with "<", a jump target with ">", and an instruction that is both with
 * GRAPH_ARROW_BOTH. The horizontal line from the leftmost link to the
 * instruction goes over the lanes that do not link to it, and each part
 * of it has the style of the nearest link on its left. A lane below its
 * target is ":": only backward jumps go there. An instruction without an
 * arrow that has a hidden jump ends with GRAPH_DOT, see
 * explain_graph_add_lanes().
 */
static char *
explain_graph_row(const ExplainGraph *graph, int addr)
{
	/* The lanes that link to the instruction. */
	int links[4];
	int link_count = explain_graph_targets(graph, addr, links);
	bool is_source = link_count > 0;
	bool is_target = graph->lane_of[addr] >= 0;
	if (is_target)
		links[link_count++] = addr;
	/* The leftmost column that links to the instruction. */
	int outer = -1;
	for (int i = 0; i < link_count; i++) {
		links[i] = graph->lane_of[links[i]];
		outer = MAX(outer, graph->lanes[links[i]].column);
	}
	StrAccum row;
	char buf[64];
	sqlStrAccumInit(&row, buf, sizeof(buf), SQL_MAX_LENGTH);
	/* The horizontal line from the last link. */
	const char *line = BOX_HORIZONTAL;
	for (int column = graph->column_count - 1; column >= 0; column--) {
		uint8_t cell = explain_graph_cell(graph, column, addr, links,
						  link_count);
		const char *glyph;
		if ((cell & GRAPH_LINK) != 0) {
			glyph = explain_graph_link_glyph(cell, column < outer);
			/* The line of a backward jump is dotted. */
			line = (cell & GRAPH_BACK_LINK) != 0 ?
			       GRAPH_DOT : BOX_HORIZONTAL;
		} else if (column < outer) {
			glyph = line;
		} else if ((cell & GRAPH_UP) == 0) {
			glyph = " ";
		} else {
			glyph = (cell & GRAPH_BACK) != 0 ? ":" : BOX_VERTICAL;
		}
		sqlStrAccumAppendAll(&row, glyph);
	}
	if (outer < 0) {
		if (graph->is_hidden[addr]) {
			sqlStrAccumAppendAll(&row, " " GRAPH_DOT);
		} else if (graph->column_count > 0 ||
			   graph->filter_count != 0 || graph->has_hidden) {
			sqlStrAccumAppendAll(&row, "  ");
		}
		/* A program without jumps has an empty graph. */
		return sqlStrAccumFinish(&row);
	}
	sqlStrAccumAppendAll(&row, line);
	if (is_target && is_source)
		sqlStrAccumAppendAll(&row, GRAPH_ARROW_BOTH);
	else
		sqlStrAccumAppend(&row, is_target ? ">" : "<", 1);
	return sqlStrAccumFinish(&row);
}

/** Free the state of the listing of a program. */
static void
vdbe_explain_reset_listing(VdbeExplain *explain)
{
	explain_graph_delete(explain->graph);
	sql_xfree(explain->loop_depth);
	explain->graph = NULL;
	explain->loop_depth = NULL;
	explain->ops = NULL;
}

/** Free the data of EXPLAIN of a statement, which can be NULL. */
static void
vdbe_explain_delete(VdbeExplain *explain)
{
	if (explain == NULL)
		return;
	vdbe_explain_reset_listing(explain);
	vdbe_synopsis_aux_delete(explain->synopsis_aux);
	sql_xfree(explain->opts.graph_filter);
	sql_xfree(explain);
}

/**
 * Fill the row of EXPLAIN for an instruction with the columns of the
 * facets of the statement, and set the number of columns.
 */
static void
explain_list_row(struct Vdbe *p, Op *ops, int op_count, int addr,
		 struct Mem *mem)
{
	VdbeExplain *state = p->explain_data;
	const ExplainOpts *opts = &state->opts;
	uint8_t mask = opts->facets;
	if (state->loop_depth == NULL || state->ops != ops) {
		/* A new program is listed: the main one or a trigger. */
		vdbe_explain_reset_listing(state);
		state->ops = ops;
		state->loop_depth = explain_loop_depth_new(ops, op_count);
		if ((mask & EXPLAIN_FACET_GRAPH) != 0) {
			/*
			 * The filter has addresses of the main program. No
			 * address is in a trigger program: with a filter,
			 * such a program shows no jumps.
			 */
			int count = opts->graph_filter_count;
			if (ops != p->aOp && count != 0)
				count = -1;
			state->graph = explain_graph_new(ops, op_count,
							 opts->graph_filter,
							 count);
		}
	}
	/* The pseudocode gets 2 spaces for each loop. */
	int indent = 2 * state->loop_depth[addr];
	Op *op = &ops[addr];
	struct Mem *first = mem;
	if (state->graph != NULL) {
		mem_set_str0_allocated(mem++,
				       explain_graph_row(state->graph, addr));
	}
	char buf[256];
	const char *p4 = displayP4(op, buf, sizeof(buf));
	if ((mask & EXPLAIN_FACET_OPCODE) != 0) {
		mem_set_uint(mem++, addr);
		mem_set_str0_static(mem++, (char *)sqlOpcodeName(op->opcode));
		mem_set_int(mem++, op->p1);
		mem_set_int(mem++, op->p2);
		mem_set_int(mem++, op->p3);
		mem_copy_str0(mem++, p4);
		mem_set_str0_allocated(mem++, sqlMPrintf("%.2x", op->p5));
	}
	if ((mask & EXPLAIN_FACET_PSEUDOCODE) != 0) {
		/* The address again, next to the pseudocode. */
		mem_set_uint(mem++, addr);
		char *text = sql_xmalloc(indent + 500);
		memset(text, ' ', indent);
		if (displaySynopsis(p, op, addr, p4, text + indent, 500) == 0)
			text[0] = '\0';
		mem_set_str0_allocated(mem++, text);
	}
	assert(mem - first <= EXPLAIN_MAX_COLUMNS);
	p->nResColumn = mem - first;
}

/*
 * Give a listing of the program in the virtual machine.
 *
 * The interface is the same as sqlVdbeExec().  But instead of
 * running the code, it invokes the callback once for each instruction.
 * This feature is used to implement "EXPLAIN".
 *
 * In the mode EXPLAIN_MODE_PROGRAM, each instruction is listed: first
 * the main program, then each of the trigger subprograms one by one.
 * In the mode EXPLAIN_MODE_QUERY_PLAN, only OP_Explain instructions are
 * listed and these are shown in a different format.
 */
int
sqlVdbeList(Vdbe * p)
{
	int nRow;		/* Stop when row count reaches this */
	int nSub = 0;		/* Number of sub-vdbes seen so far */
	SubProgram **apSub = 0;	/* Array of sub-vdbes */
	Mem *pSub = 0;		/* Memory cell hold array of subprogs */
	int i;			/* Loop counter */
	int rc = 0;	/* Return code */
	Mem *pMem = &p->aMem[1];	/* First Mem of result set */

	ExplainMode mode = vdbe_explain_mode(p);
	assert(mode != EXPLAIN_MODE_OFF);
	assert(p->magic == VDBE_MAGIC_RUN);

	/* Even though this opcode does not use dynamic strings for
	 * the result, result columns may become dynamic if the user calls
	 * sql_column_text16(), causing a translation to UTF-16 encoding.
	 */
	releaseMemArray(pMem, EXPLAIN_MAX_COLUMNS);
	p->pResultSet = 0;

	/* When the number of output rows reaches nRow, that means the
	 * listing has finished and sql_step() should return SQL_DONE.
	 * nRow is the sum of the number of rows in the main program, plus
	 * the sum of the number of rows in all trigger subprograms encountered
	 * so far.  The nRow value will increase as new trigger subprograms are
	 * encountered, but p->pc will eventually catch up to nRow.
	 */
	nRow = p->nOp;
	if (mode == EXPLAIN_MODE_PROGRAM) {
		/*
		 * The memory cells from 1 to EXPLAIN_MAX_COLUMNS are used
		 * for the result set. The next cell holds the array of
		 * pointers to trigger subprograms. sqlVdbeMakeReady()
		 * gives the VDBE these cells.
		 */
		assert(p->nMem > EXPLAIN_MAX_COLUMNS + 1);
		pSub = &p->aMem[EXPLAIN_MAX_COLUMNS + 1];
		if (mem_is_bin(pSub)) {
			/* On the first call to sql_step(), pSub will hold a NULL.  It is
			 * initialized to a BLOB by the P4_SUBPROGRAM processing logic below
			 */
			nSub = pSub->n / sizeof(Vdbe *);
			apSub = (SubProgram **) pSub->z;
		}
		for (i = 0; i < nSub; i++) {
			nRow += apSub[i]->nOp;
		}
	}

	do {
		i = p->pc++;
	} while (i < nRow && mode == EXPLAIN_MODE_QUERY_PLAN &&
		 p->aOp[i].opcode != OP_Explain);
	if (i >= nRow) {
		vdbe_explain_reset_listing(p->explain_data);
		rc = SQL_DONE;
	} else {
		char *zP4;
		Op *pOp;
		Op *aOp = p->aOp;
		int nOp = p->nOp;
		if (i < p->nOp) {
			/* The output line number is small enough that we are still in the
			 * main program.
			 */
			pOp = &p->aOp[i];
		} else {
			/* We are currently listing subprograms.  Figure out which one and
			 * pick up the appropriate opcode.
			 */
			int j;
			i -= p->nOp;
			for (j = 0; i >= apSub[j]->nOp; j++) {
				i -= apSub[j]->nOp;
			}
			aOp = apSub[j]->aOp;
			nOp = apSub[j]->nOp;
			pOp = &aOp[i];
		}
		if (mode == EXPLAIN_MODE_PROGRAM) {
			assert(i >= 0);
			/*
			 * When an OP_Program opcode is encounter (the only
			 * opcode that has a P4_SUBPROGRAM argument), expand
			 * the size of the array of subprograms kept in
			 * pSub->z to hold the new program - assuming this
			 * subprogram has not already been seen.
			 */
			if (pOp->p4type == P4_SUBPROGRAM) {
				int j;
				for (j = 0; j < nSub; j++) {
					if (apSub[j] == pOp->p4.pProgram)
						break;
				}
				if (nSub == 0) {
					uint32_t size = sizeof(SubProgram *);
					char *bin = (char *)&pOp->p4.pProgram;
					mem_copy_bin(pSub, bin, size);
				} else if (j == nSub) {
					char *bin = (char *)&pOp->p4.pProgram;
					uint32_t size = sizeof(SubProgram *);
					if (mem_append(pSub, bin, size) != 0)
						return -1;
				}
			}
			explain_list_row(p, aOp, nOp, i, pMem);
		} else {
			mem_set_int(pMem, pOp->p1);
			pMem++;

			mem_set_int(pMem, pOp->p2);
			pMem++;

			mem_set_int(pMem, pOp->p3);
			pMem++;

			if (pOp->opcode == OP_Explain &&
			    pOp->p4type == P4_PTR) {
				zP4 = (char *)op_explain_hook_detail(pOp);
				if (zP4 == NULL)
					return -1;
				mem_set_str0_ephemeral(pMem, zP4);
			} else {
				char *buf = sql_xmalloc(256);
				zP4 = displayP4(pOp, buf, 256);
				if (zP4 != buf) {
					sql_xfree(buf);
					mem_set_str0_ephemeral(pMem, zP4);
				} else {
					mem_set_str0_allocated(pMem, zP4);
				}
			}
			p->nResColumn = 4;
		}
		p->pResultSet = &p->aMem[1];
		rc = SQL_ROW;
	}
	return rc;
}

#ifdef SQL_DEBUG
/*
 * Print the SQL that was used to generate a VDBE program.
 */
void
sqlVdbePrintSql(Vdbe * p)
{
	const char *z = 0;
	if (p->zSql) {
		z = p->zSql;
	} else if (p->nOp >= 1) {
		const VdbeOp *pOp = &p->aOp[0];
		if (pOp->opcode == OP_Init && pOp->p4.z != 0) {
			z = pOp->p4.z;
			while (sqlIsspace(*z))
				z++;
		}
	}
	if (z)
		printf("SQL: [%s]\n", z);
}
#endif


/* An instance of this object describes bulk memory available for use
 * by subcomponents of a prepared statement.  Space is allocated out
 * of a ReusableSpace object by the allocSpace() routine below.
 */
struct ReusableSpace {
	u8 *pSpace;		/* Available memory */
	int nFree;		/* Bytes of available memory */
	int nNeeded;		/* Total bytes that could not be allocated */
};

/* Try to allocate nByte bytes of 8-byte aligned bulk memory for pBuf
 * from the ReusableSpace object.  Return a pointer to the allocated
 * memory on success.  If insufficient memory is available in the
 * ReusableSpace object, increase the ReusableSpace.nNeeded
 * value by the amount needed and return NULL.
 *
 * If pBuf is not initially NULL, that means that the memory has already
 * been allocated by a prior call to this routine, so just return a copy
 * of pBuf and leave ReusableSpace unchanged.
 *
 * This allocator is employed to repurpose unused slots at the end of the
 * opcode array of prepared state for other memory needs of the prepared
 * statement.
 */
static void *
allocSpace(struct ReusableSpace *p,	/* Bulk memory available for allocation */
	   void *pBuf,		/* Pointer to a prior allocation */
	   int nByte		/* Bytes of memory needed */
    )
{
	assert(EIGHT_BYTE_ALIGNMENT(p->pSpace));
	if (pBuf == 0) {
		nByte = ROUND8(nByte);
		if (nByte <= p->nFree) {
			p->nFree -= nByte;
			pBuf = &p->pSpace[p->nFree];
		} else {
			p->nNeeded += nByte;
		}
	}
	assert(EIGHT_BYTE_ALIGNMENT(pBuf));
	return pBuf;
}

/*
 * Rewind the VDBE back to the beginning in preparation for
 * running it.
 */
void
sqlVdbeRewind(Vdbe * p)
{
	assert(p != 0);
	assert(p->magic == VDBE_MAGIC_INIT || p->magic == VDBE_MAGIC_RESET);

	/* There should be at least one opcode.
	 */
	assert(p->nOp > 0);

	/* Set the magic to VDBE_MAGIC_RUN sooner rather than later. */
	p->magic = VDBE_MAGIC_RUN;

	p->step_count = 0;
	p->pc = -1;
	p->is_aborted = false;
	p->ignoreRaised = 0;
	p->errorAction = ON_CONFLICT_ACTION_ABORT;
	p->nChange = 0;
	p->cacheCtr = 1;
	p->iStatement = 0;
	p->nFkConstraint = 0;
}

/*
 * Prepare a virtual machine for execution for the first time after
 * creating the virtual machine.  This involves things such
 * as allocating registers and initializing the program counter.
 * After the VDBE has be prepped, it can be executed by one or more
 * calls to sqlVdbeExec().
 *
 * This function may be called exactly once on each virtual machine.
 * After this routine is called the VM has been "packaged" and is ready
 * to run.  After this routine is called, further calls to
 * sqlVdbeAddOp() functions are prohibited.  This routine disconnects
 * the Vdbe from the Parse object that helped generate it so that the
 * the Vdbe becomes an independent entity and the Parse object can be
 * destroyed.
 *
 * Use the sqlVdbeRewind() procedure to restore a virtual machine back
 * to its initial state after it has been run.
 */
void
sqlVdbeMakeReady(Vdbe * p,	/* The VDBE */
		     Parse * pParse	/* Parsing context */
    )
{
	int nVar;		/* Number of parameters */
	int nMem;		/* Number of VM memory registers */
	int nCursor;		/* Number of cursors required */
	int n;			/* Loop counter */
	struct ReusableSpace x;	/* Reusable bulk memory */

	assert(p != 0);
	assert(p->nOp > 0);
	assert(pParse != 0);
	assert(p->magic == VDBE_MAGIC_INIT);
	assert(pParse == p->pParse);
	nVar = pParse->nVar;
	nMem = pParse->nMem;
	nCursor = pParse->nTab;

	/* Each cursor uses a memory cell.  The first cursor (cursor 0) can
	 * use aMem[0] which is not otherwise used by the VDBE program.  Allocate
	 * space at the end of aMem[] for cursors 1 and greater.
	 * See also: allocateCursor().
	 */
	nMem += nCursor;
	if (nCursor == 0 && nMem > 0)
		nMem++;		/* Space for aMem[0] even if not used */

	/* Figure out how much reusable memory is available at the end of the
	 * opcode array.  This extra memory will be reallocated for other elements
	 * of the prepared statement.
	 */
	n = ROUND8(sizeof(Op) * p->nOp);	/* Bytes of opcode memory used */
	x.pSpace = &((u8 *) p->aOp)[n];	/* Unused opcode memory */
	assert(EIGHT_BYTE_ALIGNMENT(x.pSpace));
	x.nFree = ROUNDDOWN8(pParse->szOpAlloc - n);	/* Bytes of unused memory */
	assert(x.nFree >= 0);
	assert(EIGHT_BYTE_ALIGNMENT(&x.pSpace[x.nFree]));

	resolveP2Values(p);
	if (pParse->explain != EXPLAIN_MODE_OFF &&
	    nMem < EXPLAIN_MAX_COLUMNS + 2) {
		nMem = EXPLAIN_MAX_COLUMNS + 2;
	}
	p->expired = 0;

	/* Memory for registers, parameters, cursor, etc, is allocated in one or two
	 * passes.  On the first pass, we try to reuse unused memory at the
	 * end of the opcode array.  If we are unable to satisfy all memory
	 * requirements by reusing the opcode array tail, then the second
	 * pass will fill in the remainder using a fresh memory allocation.
	 *
	 * This two-pass approach that reuses as much memory as possible from
	 * the leftover memory at the end of the opcode array.  This can significantly
	 * reduce the amount of memory held by a prepared statement.
	 */
	do {
		x.nNeeded = 0;
		p->aMem = allocSpace(&x, p->aMem, nMem * sizeof(Mem));
		p->aVar = allocSpace(&x, p->aVar, nVar * sizeof(Mem));
		p->apCsr =
		    allocSpace(&x, p->apCsr, nCursor * sizeof(VdbeCursor *));
		if (x.nNeeded == 0)
			break;
		x.pSpace = sql_xmalloc(x.nNeeded);
		p->pFree = x.pSpace;
		x.nFree = x.nNeeded;
	} while (true);

	p->pVList = pParse->pVList;
	pParse->pVList = 0;
	assert(vdbe_explain_mode(p) == pParse->explain);
	if (p->explain_data != NULL) {
		/* The statement takes the filter of the graph. */
		p->explain_data->opts = pParse->explain_opts;
		pParse->explain_opts.graph_filter = NULL;
		pParse->explain_opts.graph_filter_count = 0;
	}
	p->nCursor = nCursor;
	p->nVar = nVar;
	for (int i = 0; i < nVar; ++i)
		mem_create(&p->aVar[i]);
	p->nMem = nMem;
	for (int i = 0; i < nMem; ++i) {
		mem_create(&p->aMem[i]);
		mem_set_invalid(&p->aMem[i]);
	}
	memset(p->apCsr, 0, nCursor * sizeof(VdbeCursor *));
	sqlVdbeRewind(p);
}

void
sqlVdbeFreeCursor(struct VdbeCursor *pCx)
{
	if (pCx == 0) {
		return;
	}
	switch (pCx->eCurType) {
	case CURTYPE_SORTER:{
			sqlVdbeSorterClose(pCx);
			break;
		}
	case CURTYPE_TARANTOOL:{
		assert(pCx->uc.pCursor != 0);
		sql_cursor_close(pCx->uc.pCursor);
			break;
		}
	}
}

/*
 * Close all cursors in the current frame.
 */
static void
closeCursorsInFrame(Vdbe * p)
{
	if (p->apCsr) {
		int i;
		for (i = 0; i < p->nCursor; i++) {
			VdbeCursor *pC = p->apCsr[i];
			if (pC) {
				sqlVdbeFreeCursor(pC);
				p->apCsr[i] = 0;
			}
		}
	}
}

/*
 * Copy the values stored in the VdbeFrame structure to its Vdbe. This
 * is used, for example, when a trigger sub-program is halted to restore
 * control to the main program.
 */
int
sqlVdbeFrameRestore(VdbeFrame * pFrame)
{
	Vdbe *v = pFrame->v;
	closeCursorsInFrame(v);
	v->aOp = pFrame->aOp;
	v->nOp = pFrame->nOp;
	v->aMem = pFrame->aMem;
	v->nMem = pFrame->nMem;
	v->apCsr = pFrame->apCsr;
	v->nCursor = pFrame->nCursor;
	v->nChange = pFrame->nChange;
	sql_get()->nChange = pFrame->nDbChange;
	return pFrame->pc;
}

/*
 * Close top frame cursors.
 *
 */
static void
closeTopFrameCursors(Vdbe * p)
{
	if (p->pFrame) {
		VdbeFrame *pFrame;
		for (pFrame = p->pFrame; pFrame->pParent;
		     pFrame = pFrame->pParent) ;
		sqlVdbeFrameRestore(pFrame);
		p->pFrame = 0;
		p->nFrame = 0;
	}
	assert(p->nFrame == 0);
	closeCursorsInFrame(p);
}

/*
 * Close cursors in frames marked for deletetion and free memory
 *
 * Delete all frames marked for deletion, which in turn will cause in-frame
 * cursors to be closed.
 * Also release any dynamic memory held by the VM in the Vdbe.aMem memory
 * cell array. This is necessary as the memory cell array may contain
 * pointers to VdbeFrame objects, which may in turn contain pointers to
 * open cursors.
 */
static void
closeCursorsAndFree(Vdbe * p)
{
	if (p->aMem) {
		releaseMemArray(p->aMem, p->nMem);
	}
	while (p->pDelFrame) {
		VdbeFrame *pDel = p->pDelFrame;
		p->pDelFrame = pDel->pParent;
		sqlVdbeFrameDelete(pDel);
	}
}

/*
 * Clean up the VM after a single run.
 */
static void
Cleanup(Vdbe * p)
{

#ifdef SQL_DEBUG
	/* Execute assert() statements to ensure that the Vdbe.apCsr[] and
	 * Vdbe.aMem[] arrays have already been cleaned up.
	 */
	int i;
	if (p->apCsr)
		for (i = 0; i < p->nCursor; i++)
			assert(p->apCsr[i] == 0);
	if (p->aMem) {
		for (i = 0; i < p->nMem; i++)
			assert(mem_is_invalid(&p->aMem[i]));
	}
#endif

	p->pResultSet = 0;
}

void
vdbe_metadata_delete(struct Vdbe *v)
{
	if (v->metadata != NULL) {
		for (int i = 0; i < v->nResColumn; ++i) {
			free(v->metadata[i].name);
			free(v->metadata[i].type);
			free(v->metadata[i].collation);
		}
		free(v->metadata);
	}
}

/*
 * Set the number of result columns that will be returned by this SQL
 * statement. This is now set at compile time, rather than during
 * execution of the vdbe program so that sql_column_count() can
 * be called on an SQL statement before sql_step().
 */
void
sqlVdbeSetNumCols(Vdbe * p, int nResColumn)
{
	vdbe_metadata_delete(p);
	p->nResColumn = (u16) nResColumn;
	p->metadata = (struct sql_column_metadata *)
		calloc(nResColumn, sizeof(struct sql_column_metadata));
	if (p->metadata == NULL) {
		diag_set(OutOfMemory,
			 nResColumn * sizeof(struct sql_column_metadata),
			 "calloc", "metadata");
		return;
	}
	for (int i = 0; i < nResColumn; ++i)
		p->metadata[i].nullable = -1;

}

int
vdbe_metadata_set_col_name(struct Vdbe *p, int idx, const char *name)
{
	assert(idx < p->nResColumn);
	if (p->metadata[idx].name != NULL)
		free(p->metadata[idx].name);
	p->metadata[idx].name = strdup(name);
	if (p->metadata[idx].name == NULL) {
		diag_set(OutOfMemory, strlen(name) + 1, "strdup", "name");
		return -1;
	}
	return 0;
}

int
vdbe_metadata_set_col_type(struct Vdbe *p, int idx, const char *type)
{
	assert(idx < p->nResColumn);
	if (p->metadata[idx].type != NULL)
		free(p->metadata[idx].type);
	p->metadata[idx].type = strdup(type);
	if (p->metadata[idx].type == NULL) {
		diag_set(OutOfMemory, strlen(type) + 1, "strdup", "type");
		return -1;
	}
	return 0;
}

int
vdbe_metadata_set_col_collation(struct Vdbe *p, int idx, const char *coll,
				size_t coll_len)
{
	assert(idx < p->nResColumn);
	if (p->metadata[idx].collation != NULL)
		free(p->metadata[idx].collation);
	p->metadata[idx].collation = strndup(coll, coll_len);
	if (p->metadata[idx].collation == NULL) {
		diag_set(OutOfMemory, coll_len + 1, "strndup", "collation");
		return -1;
	}
	return 0;
}

void
vdbe_metadata_set_col_nullability(struct Vdbe *p, int idx, int nullable)
{
	assert(idx < p->nResColumn);
	p->metadata[idx].nullable = nullable;
}

void
vdbe_metadata_set_col_autoincrement(struct Vdbe *p, int idx)
{
	assert(idx < p->nResColumn);
	p->metadata[idx].is_actoincrement = true;
}

#ifndef NDEBUG
/*
 * This routine checks that the sql.nVdbeActive count variable
 * matches the number of vdbe's in the list sql.pVdbe that are
 * currently active. An assertion fails if the two counts do not match.
 * This is an internal self-check only - it is not an essential processing
 * step.
 *
 * This is a no-op if NDEBUG is defined.
 */
static void
checkActiveVdbeCnt(void)
{
	Vdbe *p;
	int cnt = 0;
	p = sql_get()->pVdbe;
	while (p) {
		if (sql_stmt_busy((sql_stmt *) p)) {
			cnt++;
		}
		p = p->pNext;
	}
	assert(cnt == sql_get()->nVdbeActive);
}
#else
#define checkActiveVdbeCnt()
#endif

/*
 * If the Vdbe passed as the first argument opened a statement-transaction,
 * close it now. Argument eOp must be either SAVEPOINT_ROLLBACK or
 * SAVEPOINT_RELEASE. If it is SAVEPOINT_ROLLBACK, then the statement
 * transaction is rolled back. If eOp is SAVEPOINT_RELEASE, then the
 * statement transaction is committed.
 *
 * If an IO error occurs, -1 is returned.
 * Otherwise 0.
 */
int
sqlVdbeCloseStatement(Vdbe * p, int eOp)
{
	int rc = 0;
	struct txn_savepoint *savepoint = p->anonymous_savepoint;
	/*
	 * If we have an anonymous transaction opened -> perform eOp.
	 */
	if (savepoint && eOp == SAVEPOINT_ROLLBACK)
		rc = box_txn_rollback_to_savepoint(savepoint);
	p->anonymous_savepoint = NULL;
	return rc;
}

/*
 * This routine is called the when a VDBE tries to halt.  If the VDBE
 * has made changes and is in autocommit mode, then commit those
 * changes.  If a rollback is needed, then do the rollback.
 *
 * This routine is the only way to move the state of a VM from
 * SQL_MAGIC_RUN to SQL_MAGIC_HALT.  It is harmless to
 * call this on a VM that is in the SQL_MAGIC_HALT state.
 *
 * Return an error code.
 */
int
sqlVdbeHalt(Vdbe * p)
{
	int rc;			/* Used to store transient return codes */
	sql *db = sql_get();

	/* This function contains the logic that determines if a statement or
	 * transaction will be committed or rolled back as a result of the
	 * execution of this virtual machine.
	 */

	closeTopFrameCursors(p);
	if (p->magic != VDBE_MAGIC_RUN) {
		return 0;
	}
	checkActiveVdbeCnt();

	/* No commit or rollback needed if the program never started or if the
	 * SQL statement does not read or write a database file.
	 */
	if (p->pc >= 0) {
		int eStatementOp = 0;

		/* Check for immediate foreign key violations. */
		if (!p->is_aborted && p->nFkConstraint > 0) {
			p->is_aborted = true;
			p->errorAction = ON_CONFLICT_ACTION_ABORT;
			diag_set(ClientError, ER_SQL_EXECUTE, "FOREIGN KEY "
				 "constraint failed");
		}

		/* If the auto-commit flag is set and this is the only active writer
		 * VM, then we do either a commit or rollback of the current transaction.
		 *
		 * Note: This block also runs if one of the special errors handled
		 * above has occurred.
		 */
		if (p->auto_commit) {
			if (!p->is_aborted
			    || (p->errorAction == ON_CONFLICT_ACTION_FAIL)) {
				/*
				 * The auto-commit flag is true, the vdbe
				 * program was successful or hit an 'OR FAIL'
				 * constraint and there are no deferred foreign
				 * key constraints to hold up the transaction.
				 * This means a commit is required.
				 */
				rc = (in_txn() == NULL ||
				      txn_commit(in_txn()) == 0) ?
				      0 : -1;
				closeCursorsAndFree(p);
				if (rc != 0) {
					p->is_aborted = true;
					box_txn_rollback();
					sqlRollbackAll(p);
					p->nChange = 0;
				}
			} else {
				box_txn_rollback();
				closeCursorsAndFree(p);
				sqlRollbackAll(p);
				p->nChange = 0;
			}
			p->anonymous_savepoint = NULL;
		} else if (eStatementOp == 0) {
			if (!p->is_aborted ||
			    p->errorAction == ON_CONFLICT_ACTION_FAIL) {
				eStatementOp = SAVEPOINT_RELEASE;
			} else if (p->errorAction == ON_CONFLICT_ACTION_ABORT) {
				eStatementOp = SAVEPOINT_ROLLBACK;
			} else {
				box_txn_rollback();
				closeCursorsAndFree(p);
				sqlRollbackAll(p);
				sqlCloseSavepoints(p);
				p->nChange = 0;
			}
		}

		/* If eStatementOp is non-zero, then a statement transaction needs to
		 * be committed or rolled back. Call sqlVdbeCloseStatement() to
		 * do so. If this operation returns an error, and the current statement
		 * error code is 0 or -1, then promote the
		 * current statement error code.
		 */
		if (eStatementOp) {
			rc = sqlVdbeCloseStatement(p, eStatementOp);
			if (rc) {
				box_txn_rollback();
				p->is_aborted = true;
				closeCursorsAndFree(p);
				sqlRollbackAll(p);
				sqlCloseSavepoints(p);
				p->nChange = 0;
			}
		}

		/*
		 * If this was an INSERT, UPDATE or DELETE and
		 * statement transaction has been rolled back,
		 * update the database connection change-counter.
		 * Other statements should return 0 (zero).
		 */
		if (p->changeCntOn) {
			sqlVdbeSetChanges(p->nChange);
			p->nChange = 0;
		} else {
			db->nChange = 0;
		}
	}

	closeCursorsAndFree(p);

	/* We have successfully halted and closed the VM.  Record this fact. */
	if (p->pc >= 0) {
		db->nVdbeActive--;
	}
	p->magic = VDBE_MAGIC_HALT;
	checkActiveVdbeCnt();

	assert(db->nVdbeActive > 0 || box_txn() ||
	       p->anonymous_savepoint == NULL);
	return 0;
}

/*
 * This routine sets is_aborted of VDBE to false.
 */
void
sqlVdbeResetStepResult(Vdbe * p)
{
	p->is_aborted = false;
}

/*
 * Clean up a VDBE after execution but do not delete the VDBE just yet.
 * Return the result code.
 *
 * After this routine is run, the VDBE should be ready to be executed
 * again.
 *
 * To look at it another way, this routine resets the state of the
 * virtual machine from VDBE_MAGIC_RUN or VDBE_MAGIC_HALT back to
 * VDBE_MAGIC_INIT.
 */
int
sqlVdbeReset(Vdbe * p)
{
	/* If the VM did not run to completion or if it encountered an
	 * error, then it might not have been halted properly.  So halt
	 * it now.
	 */
	sqlVdbeHalt(p);

	/* If the VDBE has be run even partially, then transfer the error code
	 * and error message from the VDBE into the main database structure.  But
	 * if the VDBE has just been set to run but has not actually executed any
	 * instructions yet, leave the main database error information unchanged.
	 */
	if (p->pc >= 0) {
		if (p->runOnlyOnce)
			p->expired = 1;
	} else {
		/*
		 * An error should be thrown here if the expired
		 * flag is set on the VDBE flag with the first
		 * call to sql_step(). However, the expired flag
		 * is currently disabled, so this error has been
		 * replaced with assert.
		 */
		assert(!p->is_aborted || p->expired == 0);
	}

	/* Reclaim all memory used by the VDBE
	 */
	Cleanup(p);

	p->iCurrentTime = 0;
	p->magic = VDBE_MAGIC_RESET;
	return p->is_aborted ? -1 : 0;
}

/*
 * Clean up and delete a VDBE after execution.  Return an integer which is
 * the result code.
 */
int
sqlVdbeFinalize(Vdbe * p)
{
	int rc = 0;
	if (p->magic == VDBE_MAGIC_RUN || p->magic == VDBE_MAGIC_HALT)
		rc = sqlVdbeReset(p);
	sqlVdbeDelete(p);
	return rc;
}

/*
 * Free all memory associated with the Vdbe passed as the second argument,
 * except for object itself, which is preserved.
 *
 * The difference between this function and sqlVdbeDelete() is that
 * VdbeDelete() also unlinks the Vdbe from the list of VMs associated with
 * the database connection and frees the object itself.
 */
static void
sqlVdbeClearObject(struct Vdbe *p)
{
	SubProgram *pSub, *pNext;
	vdbe_metadata_delete(p);
	for (pSub = p->pProgram; pSub; pSub = pNext) {
		pNext = pSub->pNext;
		vdbeFreeOpArray(pSub->aOp, pSub->nOp);
		vdbe_synopsis_aux_delete(pSub->synopsis_aux);
		sql_xfree(pSub->name);
		sql_xfree(pSub);
	}
	if (p->magic != VDBE_MAGIC_INIT) {
		releaseMemArray(p->aVar, p->nVar);
		sql_xfree(p->pVList);
		sql_xfree(p->pFree);
	}
	vdbeFreeOpArray(p->aOp, p->nOp);
	vdbe_explain_delete(p->explain_data);
	sql_xfree(p->zSql);
}

/*
 * Delete an entire VDBE.
 */
void
sqlVdbeDelete(Vdbe * p)
{
	if (NEVER(p == 0))
		return;
	sqlVdbeClearObject(p);
	if (p->pPrev) {
		p->pPrev->pNext = p->pNext;
	} else {
		assert(sql_get()->pVdbe == p);
		sql_get()->pVdbe = p->pNext;
	}
	if (p->pNext) {
		p->pNext->pPrev = p->pPrev;
	}
	p->magic = VDBE_MAGIC_DEAD;
	free(p->var_pos);
	sql_xfree(p);
}

struct UnpackedRecord *
sqlVdbeAllocUnpackedRecord(struct key_def *key_def)
{
	UnpackedRecord *p;	/* Unpacked record to return */
	int nByte;		/* Number of bytes required for *p */
	nByte =
	    ROUND8(sizeof(UnpackedRecord)) + sizeof(Mem) * (key_def->part_count +
							    1);
	p = sql_xmalloc(nByte);
	p->aMem = (Mem *) & ((char *)p)[ROUND8(sizeof(UnpackedRecord))];
	for (uint32_t i = 0; i < key_def->part_count + 1; ++i)
		mem_create(&p->aMem[i]);
	p->key_def = key_def;
	p->nField = key_def->part_count + 1;
	return p;
}

void
sqlVdbeSetChanges(int nChange)
{
	sql_get()->nChange = nChange;
}

/*
 * Set a flag in the vdbe to update the change counter when it is finalised
 * or reset.
 */
void
sqlVdbeCountChanges(Vdbe * v)
{
	v->changeCntOn = 1;
}

/**
 * Mark every prepared statement as expired.
 *
 * An expired statement means that recompilation of the statement is recommend.
 * Statements expire when things happen that make their programs obsolete.
 * Removing user-defined functions or collating sequences, or changing an
 * authorization function are the types of things that make prepared statements
 * obsolete.
 */
void
sqlExpirePreparedStatements(void)
{
	Vdbe *p;
	for (p = sql_get()->pVdbe; p; p = p->pNext)
		p->expired = p->is_sandboxed == 0 ? 1 : 0;
}

const struct Mem *
vdbe_get_bound_value(struct Vdbe *vdbe, int id)
{
	if (vdbe == NULL || id < 0 || id >= vdbe->nVar)
		return NULL;
	return &vdbe->aVar[id];
}

void
sqlVdbeRecordUnpackMsgpack(struct key_def *key_def,	/* Information about the record format */
			       const void *pKey,	/* The binary record */
			       UnpackedRecord * p)	/* Populate this structure before returning. */
{
	uint32_t n;
	const char *zParse = pKey;
	Mem *pMem = p->aMem;
	n = mp_decode_array(&zParse);
	n = p->nField = MIN(n, key_def->part_count);
	p->default_rc = 0;
	p->key_def = key_def;
	while (n--) {
		pMem->szMalloc = 0;
		pMem->z = 0;
		uint32_t sz = 0;
		mem_from_mp_ephemeral(pMem, zParse, &sz);
		assert(sz != 0);
		zParse += sz;
		pMem++;
	}
}
