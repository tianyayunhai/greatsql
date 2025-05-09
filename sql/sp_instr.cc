/* Copyright (c) 2012, 2022, Oracle and/or its affiliates. All rights reserved.
   Copyright (c) 2023, 2025, GreatDB Software Co., Ltd.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License, version 2.0,
   as published by the Free Software Foundation.

   This program is also distributed with certain software (including
   but not limited to OpenSSL) that is licensed under separate terms,
   as designated in a particular file or component or in included license
   documentation.  The authors of MySQL hereby grant you an additional
   permission to link the program and your derivative works with the
   separately licensed software that they have included with MySQL.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License, version 2.0, for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA */

#include "sql/sp_instr.h"

#include "my_config.h"

#include <algorithm>
#include <atomic>
#include <functional>

#include "debug_sync.h"  // DEBUG_SYNC
#include "m_ctype.h"
#include "my_command.h"
#include "my_compiler.h"
#include "my_dbug.h"
#include "my_sqlcommand.h"
#include "mysql/components/services/bits/psi_bits.h"
#include "mysql/components/services/log_shared.h"
#include "mysql/plugin.h"
#include "mysql/psi/mysql_statement.h"
#include "mysql_com.h"
#include "mysqld_error.h"
#include "prealloced_array.h"  // Prealloced_array
#include "scope_guard.h"
#include "sql/auth/auth_acls.h"
#include "sql/auth/auth_common.h"  // check_table_access
#include "sql/binlog.h"            // mysql_bin_log
#include "sql/debug_sync.h"
#include "sql/enum_query_type.h"
#include "sql/error_handler.h"  // Strict_error_handler
#include "sql/field.h"
#include "sql/item.h"          // Item_splocal
#include "sql/item_cmpfunc.h"  // Item_func_eq
#include "sql/item_sum.h"
#include "sql/log.h"  // Query_logger
#include "sql/mdl.h"
#include "sql/mysqld.h"     // next_query_id
#include "sql/opt_trace.h"  // Opt_trace_start
#include "sql/protocol.h"
#include "sql/query_options.h"
#include "sql/query_plan_plugin.h"  // has_additional_query_plan
#include "sql/session_tracker.h"
#include "sql/sp.h"           // sp_get_item_value
#include "sql/sp_head.h"      // sp_head
#include "sql/sp_pcontext.h"  // sp_pcontext
#include "sql/sp_rcontext.h"  // sp_rcontext
#include "sql/sql_audit.h"
#include "sql/sql_base.h"  // open_temporary_tables
#include "sql/sql_const.h"
#include "sql/sql_cursor.h"
#include "sql/sql_digest_stream.h"
#include "sql/sql_insert.h"
#include "sql/sql_list.h"
#include "sql/sql_parse.h"    // parse_sql
#include "sql/sql_prepare.h"  // Reprepare_observer
#include "sql/sql_profile.h"
#include "sql/sql_tmp_table.h"  // Tmp tables
#include "sql/system_variables.h"
#include "sql/table_function.h"
#include "sql/table_trigger_dispatcher.h"  // Table_trigger_dispatcher
#include "sql/thr_malloc.h"
#include "sql/transaction.h"  // trans_commit_stmt
#include "sql/transaction_info.h"
#include "sql/trigger.h"  // Trigger
#include "sql/trigger_def.h"
#include "unsafe_string_append.h"

class Cmp_splocal_locations {
 public:
  bool operator()(const Item_splocal *a, const Item_splocal *b) {
    assert(a == b || a->pos_in_query != b->pos_in_query);
    return a->pos_in_query < b->pos_in_query;
  }
};

/*
  StoredRoutinesBinlogging
  This paragraph applies only to statement-based binlogging. Row-based
  binlogging does not need anything special like this except for a special
  case that is mentioned below in section 2.1

  Top-down overview:

  1. Statements

  Statements that have is_update_query(stmt) == true are written into the
  binary log verbatim.
  Examples:
    UPDATE tbl SET tbl.x = spfunc_w_side_effects()
    UPDATE tbl SET tbl.x=1 WHERE spfunc_w_side_effect_that_returns_false(tbl.y)

  Statements that have is_update_query(stmt) == false (e.g. SELECTs) are not
  written into binary log. Instead we catch function calls the statement
  makes and write it into binary log separately (see #3).

  2. PROCEDURE calls

  CALL statements are not written into binary log. Instead
  * Any FUNCTION invocation (in SET, IF, WHILE, OPEN CURSOR and other SP
    instructions) is written into binlog separately.

  * Each statement executed in SP is binlogged separately, according to rules
    in #1, with the exception that we modify query string: we replace uses
    of SP local variables with NAME_CONST('spvar_name', <spvar-value>) calls.
    This substitution is done in subst_spvars().

  2.1 Miscellaneous case: DDLs (Eg: ALTER EVENT) in StoredProcedure(SP) uses
      its local variables

  * Irrespective of binlog format, DDLs are always binlogged in statement mode.
    Hence if there are any DDLs, in stored procedure, that uses SP local
    variables,  those should be replaced with NAME_CONST('spvar_name',
  <spvar-value>) even if binlog format is 'row'.

  3. FUNCTION calls

  In sp_head::execute_function(), we check
   * If this function invocation is done from a statement that is written
     into the binary log.
   * If there were any attempts to write events to the binary log during
     function execution (grep for start_union_events and stop_union_events)

   If the answers are No and Yes, we write the function call into the binary
   log as "SELECT spfunc(<param1value>, <param2value>, ...)"


  4. Miscellaneous issues.

  4.1 User variables.

  When we call mysql_bin_log.write() for an SP statement, thd->user_var_events
  must hold set<{var_name, value}> pairs for all user variables used during
  the statement execution.
  This set is produced by tracking user variable reads during statement
  execution.

  For SPs, this has the following implications:
  1) thd->user_var_events may contain events from several SP statements and
     needs to be valid after execution of these statements was finished. In
     order to achieve that, we
     * Allocate user_var_events array elements on appropriate mem_root (grep
       for user_var_events_alloc).
     * Use is_query_in_union() to determine if user_var_event is created.

  2) We need to empty thd->user_var_events after we have wrote a function
     call. This is currently done by making
     thd->user_var_events.clear()
     calls in several different places. (TODO consider moving this into
     mysql_bin_log.write() function)

  4.2 Auto_increment storage in binlog

  As we may write two statements to binlog from one single logical statement
  (case of "SELECT func1(),func2()": it is binlogged as "SELECT func1()" and
  then "SELECT func2()"), we need to reset auto_increment binlog variables
  after each binlogged SELECT. Otherwise, the auto_increment value of the
  first SELECT would be used for the second too.
*/

/**
  Replace thd->query{_length} with a string that one can write to
  the binlog.

  The binlog-suitable string is produced by replacing references to SP local
  variables with NAME_CONST('sp_var_name', value) calls.

  @param thd        Current thread.
  @param instr      Instruction (we look for Item_splocal instances in
                    instr->item_list)
  @param query_str  Original query string

  @retval false on success.
  thd->query{_length} either has been appropriately replaced or there
  is no need for replacements.

  @retval true in case of out of memory error.
*/
static bool subst_spvars(THD *thd, sp_instr *instr, LEX_CSTRING query_str) {
  // Stack-local array, does not need instrumentation.
  Prealloced_array<Item_splocal *, 16> sp_vars_uses(PSI_NOT_INSTRUMENTED);

  /* Find all instances of Item_splocal used in this statement */
  for (Item *item = instr->m_arena.item_list(); item; item = item->next_free) {
    if (item->is_splocal()) {
      Item_splocal *item_spl = (Item_splocal *)item;
      if (item_spl->pos_in_query) sp_vars_uses.push_back(item_spl);
    }
  }

  if (sp_vars_uses.empty()) return false;

  /* Sort SP var refs by their occurrences in the query */
  std::sort(sp_vars_uses.begin(), sp_vars_uses.end(), Cmp_splocal_locations());

  /*
    Construct a statement string where SP local var refs are replaced
    with "NAME_CONST(name, value)"
  */
  char buffer[512];
  String qbuf(buffer, sizeof(buffer), &my_charset_bin);
  qbuf.length(0);
  const char *cur = query_str.str;
  int prev_pos = 0;
  bool res = false;
  thd->query_name_consts = 0;

  for (Item_splocal **splocal = sp_vars_uses.begin();
       splocal != sp_vars_uses.end(); splocal++) {
    Item *val;

    char str_buffer[STRING_BUFFER_USUAL_SIZE];
    String str_value_holder(str_buffer, sizeof(str_buffer), &my_charset_latin1);
    String *str_value;

    /* append the text between sp ref occurrences */
    /*
      e.g:select rec1(i).id
      it will be (*splocal)->pos_in_query - prev_pos < 0 for i.
    */
    if ((int)(*splocal)->pos_in_query - prev_pos < 0) continue;
    res |= qbuf.append(cur + prev_pos, (*splocal)->pos_in_query - prev_pos);
    prev_pos = (*splocal)->pos_in_query + (*splocal)->len_in_query;

    res |= (*splocal)->fix_fields(thd, (Item **)splocal);
    if (res) break;

    if ((*splocal)->limit_clause_param) {
      res |= qbuf.append_ulonglong((*splocal)->val_uint());
      if (res) break;
      continue;
    }

    /* append the spvar substitute */
    res |= qbuf.append(STRING_WITH_LEN(" NAME_CONST('"));
    /*e.g:select rec1(i).id,m_name = rec1,item_name = rec1(i).id.*/
    if ((*splocal)->type() == Item::ORACLE_ROWTYPE_TABLE_ITEM ||
        (*splocal)->type() == Item::ORACLE_ROWTYPE_ITEM)
      res |= qbuf.append((*splocal)->item_name);
    else
      res |= qbuf.append((*splocal)->m_name);
    res |= qbuf.append(STRING_WITH_LEN("',"));

    if (res) break;

    val = (*splocal)->this_item();
    str_value = sp_get_item_value(thd, val, &str_value_holder);
    if (str_value)
      res |= qbuf.append(*str_value);
    else
      res |= qbuf.append(STRING_WITH_LEN("NULL"));
    res |= qbuf.append(')');
    if (res) break;

    thd->query_name_consts++;
  }
  if (res || qbuf.append(cur + prev_pos, query_str.length - prev_pos))
    return true;

  char *pbuf;
  if ((pbuf = static_cast<char *>(thd->alloc(qbuf.length() + 1)))) {
    memcpy(pbuf, qbuf.ptr(), qbuf.length());
    pbuf[qbuf.length()] = 0;
  } else
    return true;

  thd->set_query(pbuf, qbuf.length());

  return false;
}

///////////////////////////////////////////////////////////////////////////
// Sufficient max length of printed destinations and frame offsets (all
// uints).
///////////////////////////////////////////////////////////////////////////

#define SP_INSTR_UINT_MAXLEN 8
#define SP_STMT_PRINT_MAXLEN 40

///////////////////////////////////////////////////////////////////////////
// sp_lex_instr implementation.
///////////////////////////////////////////////////////////////////////////

class SP_instr_error_handler : public Internal_error_handler {
 public:
  bool handle_condition(THD *thd, uint sql_errno, const char *,
                        Sql_condition::enum_severity_level *,
                        const char *) override {
    /*
      Check if the "table exists" error or warning reported for the
      CREATE TABLE ... SELECT statement.
    */
    if (thd->lex && thd->lex->sql_command == SQLCOM_CREATE_TABLE &&
        thd->lex->query_block &&
        !thd->lex->query_block->field_list_is_empty() &&
        sql_errno == ER_TABLE_EXISTS_ERROR)
      cts_table_exists_error = true;

    return false;
  }

  bool cts_table_exists_error = false;
};

bool sp_lex_instr::reset_lex_and_exec_core(THD *thd, uint *nextp,
                                           bool open_tables) {
  /*
    The flag is saved at the entry to the following substatement.
    It's reset further in the common code part.
    It's merged with the saved parent's value at the exit of this func.
  */

  unsigned int parent_unsafe_rollback_flags =
      thd->get_transaction()->get_unsafe_rollback_flags(Transaction_ctx::STMT);
  thd->get_transaction()->reset_unsafe_rollback_flags(Transaction_ctx::STMT);

  /* Check pre-conditions. */

  assert(thd->change_list.is_empty());

  /*
    Use our own lex.

    Although it is saved/restored in sp_head::execute() when we are
    entering/leaving routine, it's still should be saved/restored here,
    in order to properly behave in case of ER_NEED_REPREPARE error
    (when ER_NEED_REPREPARE happened, and we failed to re-parse the query).
  */

  LEX *lex_saved = thd->lex;
  thd->lex = m_lex;
  m_lex->thd = thd;

  /* Set new query id. */

  thd->set_query_id(next_query_id());

  if (thd->locked_tables_mode <= LTM_LOCK_TABLES) {
    /*
      This statement will enter/leave prelocked mode on its own.
      Entering prelocked mode changes table list and related members
      of LEX, so we'll need to restore them.
    */
    if (m_lex_query_tables_own_last) {
      /*
        We've already entered/left prelocked mode with this statement.
        Attach the list of tables that need to be prelocked and mark m_lex
        as having such list attached.
      */
      *m_lex_query_tables_own_last = m_prelocking_tables;
      m_lex->mark_as_requiring_prelocking(m_lex_query_tables_own_last);
    }
  }

  bool error = m_lex->check_preparation_invalid(thd);

  m_lex->clear_execution();

  /*
    In case a session state exists do not cache the SELECT stmt. If we
    cache SELECT statement when session state information exists, then
    the result sets of this SELECT are cached which contains changed
    session information. Next time when same query is executed when there
    is no change in session state, then result sets are picked from cache
    which is wrong as the result sets picked from cache have changed
    state information.
  */

  if (thd->get_protocol()->has_client_capability(CLIENT_SESSION_TRACK) &&
      thd->session_tracker.enabled_any() && thd->session_tracker.changed_any())
    thd->lex->safe_to_cache_query = false;

  SP_instr_error_handler sp_instr_error_handler;
  thd->push_internal_handler(&sp_instr_error_handler);

  /* Open tables if needed. */

  if (!error) {
    if (open_tables) {
      // todo: break this block out into a separate function.
      /*
        IF, CASE, DECLARE, SET, RETURN, have 'open_tables' true; they may
        have a subquery in parameter and are worth tracing. They don't
        correspond to a SQL command so we pretend that they are SQLCOM_SELECT.
      */
      Opt_trace_start ots(thd, m_lex->query_tables, SQLCOM_SELECT,
                          &m_lex->var_list, nullptr, 0, this,
                          thd->variables.character_set_client);
      Opt_trace_object trace_command(&thd->opt_trace);
      Opt_trace_array trace_command_steps(&thd->opt_trace, "steps");

      /*
        Check whenever we have access to tables for this statement
        and open and lock them before executing instructions core function.
        If we are not opening any tables, we don't need to check permissions
        either.
      */
      if (m_lex->query_tables)
        error = (open_temporary_tables(thd, m_lex->query_tables) ||
                 check_table_access(thd, SELECT_ACL, m_lex->query_tables, false,
                                    UINT_MAX, false));

      if (!error) error = open_and_lock_tables(thd, m_lex->query_tables, 0);

      if (!error) {
        m_lex->restore_cmd_properties();
        bind_fields(m_arena.item_list());

        error = exec_core(thd, nextp);
        DBUG_PRINT("info", ("exec_core returned: %d", error));
      }

      /*
        Call after unit->cleanup() to close open table
        key read.
      */

      m_lex->cleanup(true);

      /* Here we also commit or rollback the current statement. */

      if (!thd->in_sub_stmt) {
        thd->get_stmt_da()->set_overwrite_status(true);
        thd->is_error() ? trans_rollback_stmt(thd) : trans_commit_stmt(thd);
        thd->get_stmt_da()->set_overwrite_status(false);
      }
      thd_proc_info(thd, "closing tables");
      close_thread_tables(thd);
      thd_proc_info(thd, nullptr);

      if (!thd->in_sub_stmt) {
        if (thd->transaction_rollback_request) {
          trans_rollback_implicit(thd);
          thd->mdl_context.release_transactional_locks();
        } else if (!thd->in_multi_stmt_transaction_mode())
          thd->mdl_context.release_transactional_locks();
        else
          thd->mdl_context.release_statement_locks();
      }
    } else {
      DEBUG_SYNC(thd, "sp_lex_instr_before_exec_core");
      error = exec_core(thd, nextp);
      DBUG_PRINT("info", ("exec_core returned: %d", error));
    }
  }

  if (m_lex->current_query_block() &&
      m_lex->current_query_block()->sequences_counter) {
    m_lex->current_query_block()->sequences_counter->Clear();
  }

  // Pop SP_instr_error_handler error handler.
  thd->pop_internal_handler();

  if (m_lex->query_tables_own_last) {
    /*
      We've entered and left prelocking mode when executing statement
      stored in m_lex.
      m_lex->query_tables(->next_global)* list now has a 'tail' - a list
      of tables that are added for prelocking. (If this is the first
      execution, the 'tail' was added by open_tables(), otherwise we've
      attached it above in this function).
      Now we'll save the 'tail', and detach it.
    */
    m_lex_query_tables_own_last = m_lex->query_tables_own_last;
    m_prelocking_tables = *m_lex_query_tables_own_last;
    *m_lex_query_tables_own_last = nullptr;
    m_lex->mark_as_requiring_prelocking(nullptr);
  }

  /* Rollback changes to the item tree during execution. */

  thd->rollback_item_tree_changes();

  /*
    Change state of current arena according to outcome of execution.

    When entering this function, state is STMT_INITIALIZED_FOR_SP if this is
    the first execution, otherwise it is STMT_EXECUTED.

    When a re-prepare error is raised, the next execution will re-prepare the
    statement. To make sure that items are created in the statement mem_root,
    change state to STMT_INITIALIZED_FOR_SP.

    When a "table exists" error occurs for CREATE TABLE ... SELECT change state
    to STMT_INITIALIZED_FOR_SP, as if statement must be reprepared.

      Why is this necessary? A useful pointer would be to note how
      PREPARE/EXECUTE uses functions like select_like_stmt_test to implement
      CREATE TABLE .... SELECT. The SELECT part of the DDL is resolved first.
      Then there is an attempt to create the table. So in the execution phase,
      if "table exists" error occurs or flush table precedes the execute, the
      item tree of the select is re-created and followed by an attempt to create
      the table.

      But SP uses mysql_execute_command (which is used by the conventional
      execute) after doing a parse. This creates a problem for SP since it
      tries to preserve the item tree from the previous execution.

    When execution of the statement was started (completed), change state to
    STMT_EXECUTED.

    When an error occurs before statement execution starts (m_exec_started is
    false at this stage of execution), state is not changed.
    (STMT_INITIALIZED_FOR_SP means the statement was never prepared,
    STMT_EXECUTED means the statement has been prepared and executed before,
    but some error occurred during table open or execution).
  */
  bool reprepare_error =
      error && thd->is_error() &&
      (thd->get_stmt_da()->mysql_errno() == ER_NEED_REPREPARE ||
       thd->get_stmt_da()->mysql_errno() == ER_PREPARE_FOR_PRIMARY_ENGINE ||
       thd->get_stmt_da()->mysql_errno() == ER_PREPARE_FOR_SECONDARY_ENGINE);

  // Unless there is an error, execution must have started (and completed)
  assert(error || m_lex->is_exec_started());

  if (reprepare_error || sp_instr_error_handler.cts_table_exists_error)
    thd->stmt_arena->set_state(Query_arena::STMT_INITIALIZED_FOR_SP);
  else if (m_lex->is_exec_started())
    thd->stmt_arena->set_state(Query_arena::STMT_EXECUTED);

  /*
    Merge here with the saved parent's values
    what is needed from the substatement gained
  */

  thd->get_transaction()->add_unsafe_rollback_flags(
      Transaction_ctx::STMT, parent_unsafe_rollback_flags);

  if (thd->variables.session_track_transaction_info > TX_TRACK_NONE) {
    TX_TRACKER_GET(tst);
    tst->add_trx_state_from_thd(thd);
  }

  /* Restore original lex. */

  thd->lex = lex_saved;

  /*
    Unlike for PS we should not call Item's destructors for newly created
    items after execution of each instruction in stored routine. This is
    because SP often create Item (like Item_int, Item_string etc...) when
    they want to store some value in local variable, pass return value and
    etc... So their life time should be longer than one instruction.

    cleanup_items() is called in sp_head::execute()
  */

  return error || thd->is_error();
}

LEX *sp_lex_instr::parse_expr(THD *thd, sp_head *sp) {
  String sql_query;
  sql_digest_state *parent_digest = thd->m_digest;
  PSI_statement_locker *parent_locker = thd->m_statement_psi;
  SQL_I_List<Item_trigger_field> *next_trig_list_bkp = nullptr;
  sql_query.set_charset(system_charset_info);

  get_query(&sql_query);

  if (sql_query.length() == 0) {
    // The instruction has returned zero-length query string. That means, the
    // re-preparation of the instruction is not possible. We should not come
    // here in the normal life.
    assert(false);
    my_error(ER_UNKNOWN_ERROR, MYF(0));
    return nullptr;
  }

  if (m_trig_field_list.elements)
    next_trig_list_bkp = m_trig_field_list.first->next_trig_field_list;
  // Cleanup current THD from previously held objects before new parsing.
  cleanup_before_parsing(thd);

  // Cleanup and re-init the lex mem_root for re-parse.
  m_lex_mem_root.ClearForReuse();

  /*
    Switch mem-roots. We store the new LEX and its Items in the
    m_lex_mem_root since it is freed before reparse triggered due to
    invalidation. This avoids the memory leak in case re-parse is
    initiated. Also set the statement query arena to the lex mem_root.
  */
  MEM_ROOT *execution_mem_root = thd->mem_root;
  Query_arena parse_arena(&m_lex_mem_root, thd->stmt_arena->get_state());

  thd->mem_root = &m_lex_mem_root;
  thd->stmt_arena->set_query_arena(parse_arena);

  // Prepare parser state. It can be done just before parse_sql(), do it here
  // only to simplify exit in case of failure (out-of-memory error).

  Parser_state parser_state;

  if (parser_state.init(thd, sql_query.c_ptr(), sql_query.length()))
    return nullptr;

  // Switch THD's item list. It is used to remember the newly created set
  // of Items during parsing. We should clean those items after each execution.

  Item *execution_item_list = thd->item_list();
  thd->reset_item_list();

  // Create a new LEX and initialize it.

  LEX *lex_saved = thd->lex;

  thd->lex = new (thd->mem_root) st_lex_local;
  lex_start(thd);

  thd->lex->sphead = sp;
  thd->lex->set_sp_current_parsing_ctx(get_parsing_ctx());
  sp->m_parser_data.set_current_stmt_start_ptr(sql_query.c_ptr());

  // Parse the just constructed SELECT-statement.

  thd->m_digest = nullptr;
  thd->m_statement_psi = nullptr;
  bool parsing_failed = parse_sql(thd, &parser_state, nullptr);
  thd->m_digest = parent_digest;
  thd->m_statement_psi = parent_locker;

  if (!parsing_failed) {
    adjust_sql_command(thd->lex);
    thd->lex->set_trg_event_type_for_tables();

    // Mark statement as belonging to a stored procedure:
    if (thd->lex->m_sql_cmd != nullptr)
      thd->lex->m_sql_cmd->set_as_part_of_sp();

    // Call after-parsing callback.
    parsing_failed = on_after_expr_parsing(thd);

    if (sp->m_type == enum_sp_type::TRIGGER) {
      /*
        Also let us bind these objects to Field objects in table being opened.

        We ignore errors of setup_field() here, because if even something is
        wrong we still will be willing to open table to perform some operations
        (e.g.  SELECT)... Anyway some things can be checked only during trigger
        execution.
      */

      Trigger *t = sp->m_trg_list->find_trigger(thd->lex->sphead->m_name);

      assert(t);

      if (!t) return nullptr;  // Don't take chances in production.

      for (Item_trigger_field *trg_fld = sp->m_cur_instr_trig_field_items.first;
           trg_fld; trg_fld = trg_fld->next_trg_field) {
        trg_fld->setup_field(sp->m_trg_list, t->get_subject_table_grant());
      }

      /**
        Move Item_trigger_field's list to instruction's Item_trigger_field
        list.
      */
      if (sp->m_cur_instr_trig_field_items.elements) {
        sp->m_cur_instr_trig_field_items.save_and_clear(&m_trig_field_list);
        m_trig_field_list.first->next_trig_field_list = next_trig_list_bkp;
      }
    }

    // Append newly created Items to the list of Items, owned by this
    // instruction.
    m_arena.set_item_list(thd->item_list());
  }

  // Restore THD::lex.

  thd->lex->sphead = nullptr;
  thd->lex->set_sp_current_parsing_ctx(nullptr);

  LEX *expr_lex = thd->lex;
  thd->lex = lex_saved;

  // Restore execution mem-root and item list.

  thd->mem_root = execution_mem_root;
  thd->set_item_list(execution_item_list);

  // That's it.

  return parsing_failed ? nullptr : expr_lex;
}

bool sp_lex_instr::validate_lex_and_execute_core(THD *thd, uint *nextp,
                                                 bool open_tables) {
  // Remember if the general log was temporarily disabled when repreparing the
  // statement for a secondary engine.
  bool general_log_temporarily_disabled = false;

  Reprepare_observer reprepare_observer;

  if (!is_sp_copen())
    thd->set_secondary_engine_optimization(
        Secondary_engine_optimization::PRIMARY_TENTATIVELY);

  while (true) {
    DBUG_EXECUTE_IF("simulate_bug18831513", { invalidate(); });
    if (is_invalid() || ((m_lex->has_udf() || m_lex->has_udt_table() ||
                          has_additional_query_plan(thd, m_lex)) &&
                         !m_first_execution)) {
      free_lex();
      LEX *lex = parse_expr(thd, thd->sp_runtime_ctx->sp);

      if (!lex) return true;

      set_lex(lex, true);

      m_first_execution = true;
    }

    /*
      Install the metadata observer. If some metadata version is
      different from prepare time and an observer is installed,
      the observer method will be invoked to push an error into
      the error stack.
    */
    Reprepare_observer *stmt_reprepare_observer = nullptr;

    /*
      Meta-data versions are stored in the LEX-object on the first execution.
      Thus, the reprepare observer should not be installed for the first
      execution, because it will always be triggered.

      Then, the reprepare observer should be installed for the statements, which
      are marked by CF_REEXECUTION_FRAGILE (@sa CF_REEXECUTION_FRAGILE) or if
      the SQL-command is SQLCOM_END, which means that the LEX-object is
      representing an expression, so the exact SQL-command does not matter.
    */

    if (is_ref_cursor() || /* ref_cursor needs observer to reprepare sql */
        (!m_first_execution &&
         (sql_command_flags[m_lex->sql_command] & CF_REEXECUTION_FRAGILE ||
          m_lex->sql_command == SQLCOM_END))) {
      reprepare_observer.reset_reprepare_observer();
      stmt_reprepare_observer = &reprepare_observer;
    }

    thd->push_reprepare_observer(stmt_reprepare_observer);

    bool rc = reset_lex_and_exec_core(thd, nextp, open_tables);

    thd->pop_reprepare_observer();

    /*
      Re-enable the general log if it was temporarily disabled while repreparing
      and executing a statement for a secondary engine.
    */
    if (general_log_temporarily_disabled) {
      thd->variables.option_bits &= ~OPTION_LOG_OFF;
      general_log_temporarily_disabled = false;
    }

    m_first_execution = false;

    if (!rc) return false;

    // Exit if a fatal error has occurred or statement execution was killed.
    if (thd->is_fatal_error() || thd->is_killed()) {
      return true;
    }
    int my_errno = thd->get_stmt_da()->mysql_errno();

    if (my_errno != ER_NEED_REPREPARE &&
        my_errno != ER_PREPARE_FOR_PRIMARY_ENGINE &&
        my_errno != ER_PREPARE_FOR_SECONDARY_ENGINE) {
      /*
        If an error occurred before execution, make sure next execution is
        started with a clean statement:
      */
      if (m_lex->sql_command == SQLCOM_CREATE_TABLE &&
          (m_lex->is_metadata_used() && !m_lex->is_exec_started())) {
        invalidate();
      }
      if (m_lex->m_sql_cmd != nullptr &&
          thd->secondary_engine_optimization() ==
              Secondary_engine_optimization::SECONDARY &&
          !m_lex->unit->is_executed()) {
        if (!thd->is_secondary_engine_forced()) {
          /*
            Some error occurred during resolving or optimization in
            the secondary engine, and secondary engine execution is not forced.
            Retry execution of the statement in the primary engine.
          */
          thd->clear_error();
          thd->set_secondary_engine_optimization(
              Secondary_engine_optimization::PRIMARY_ONLY);
          invalidate();
          // Disable the general log. The query was written to the general log
          // in the first attempt to execute it. No need to write it twice.
          if ((thd->variables.option_bits & OPTION_LOG_OFF) == 0) {
            thd->variables.option_bits |= OPTION_LOG_OFF;
            general_log_temporarily_disabled = true;
          }
          continue;
        }
      }
      assert(thd->is_error());
      return true;
    }
    if (my_errno == ER_NEED_REPREPARE) {
      /*
        Reprepare_observer ensures that the statement is retried a maximum
        number of times, to avoid an endless loop.
      */
      assert(stmt_reprepare_observer != nullptr &&
             stmt_reprepare_observer->is_invalidated());
      if (!stmt_reprepare_observer->can_retry()) {
        /*
          Reprepare_observer sets error status in DA but Sql_condition is not
          added. Please check Reprepare_observer::report_error(). Pushing
          Sql_condition for ER_NEED_REPREPARE here.
        */
        Diagnostics_area *da = thd->get_stmt_da();
        da->push_warning(thd, da->mysql_errno(), da->returned_sqlstate(),
                         Sql_condition::SL_ERROR, da->message_text());
        assert(thd->is_error());
        return true;
      }
      thd->clear_error();
    } else {
      assert(my_errno == ER_PREPARE_FOR_PRIMARY_ENGINE ||
             my_errno == ER_PREPARE_FOR_SECONDARY_ENGINE);
      assert(thd->secondary_engine_optimization() ==
             Secondary_engine_optimization::PRIMARY_TENTATIVELY);
      thd->clear_error();
      if (my_errno == ER_PREPARE_FOR_SECONDARY_ENGINE) {
        thd->set_secondary_engine_optimization(
            Secondary_engine_optimization::SECONDARY);
      } else {
        thd->set_secondary_engine_optimization(
            Secondary_engine_optimization::PRIMARY_ONLY);
      }
      // Disable the general log. The query was written to the general log in
      // the first attempt to execute it. No need to write it twice.
      if ((thd->variables.option_bits & OPTION_LOG_OFF) == 0) {
        thd->variables.option_bits |= OPTION_LOG_OFF;
        general_log_temporarily_disabled = true;
      }
    }
    invalidate();
  }
}

void sp_lex_instr::set_lex(LEX *lex, bool is_lex_owner) {
  free_lex();

  m_lex = lex;
  m_is_lex_owner = is_lex_owner;
  m_lex_query_tables_own_last = nullptr;

  if (m_lex) m_lex->sp_lex_in_use = true;
}

void sp_lex_instr::free_lex() {
  if (!m_is_lex_owner || !m_lex) return;

  /* Prevent endless recursion. */
  m_lex->sphead = nullptr;
  lex_end(m_lex);
  destroy(m_lex->result);
  m_lex->set_secondary_engine_execution_context(nullptr);
  m_lex->destroy();
  delete (st_lex_local *)m_lex;

  m_lex = nullptr;
  m_is_lex_owner = false;
  m_lex_query_tables_own_last = nullptr;
}

void sp_lex_instr::cleanup_before_parsing(THD *thd) {
  /*
    Destroy items in the instruction's free list before re-parsing the
    statement query string (and thus, creating new items).
  */
  m_arena.free_items();

  // Remove previously stored trigger-field items.
  sp_head *sp = thd->sp_runtime_ctx->sp;

  if (sp->m_type == enum_sp_type::TRIGGER) m_trig_field_list.clear();
}

void sp_lex_instr::get_query(String *sql_query) const {
  LEX_CSTRING expr_query = get_expr_query();

  if (!expr_query.str) {
    sql_query->length(0);
    return;
  }

  sql_query->append("SELECT ");
  sql_query->append(expr_query.str, expr_query.length);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_stmt implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_stmt::psi_info = {0, "stmt", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_stmt::execute(THD *thd, uint *nextp) {
  bool need_subst = false;
  bool rc = false;
  QUERY_START_TIME_INFO time_info;

  DBUG_PRINT("info", ("query: '%.*s'", (int)m_query.length, m_query.str));

  thd->set_query_for_display(m_query.str, m_query.length);

  const LEX_CSTRING query_backup = thd->query();

#if defined(ENABLED_PROFILING)
  /* This SP-instr is profilable and will be captured. */
  thd->profiling->set_query_source(m_query.str, m_query.length);
#endif

  memset(&time_info, 0, sizeof(time_info));

  if (thd->enable_slow_log) {
    /*
      Save start time info for the CALL statement and overwrite it with the
      current time for log_slow_statement() to log the individual query timing.
    */
    thd->get_time(&time_info);
    thd->set_time();
  }

  /*
    If we can't set thd->query_string at all, we give up on this statement.
  */
  if (alloc_query(thd, m_query.str, m_query.length)) return true;

  /*
    Check whether we actually need a substitution of SP variables with
    NAME_CONST(...) (using subst_spvars()).
    If both of the following apply, we won't need to substitute:

    - general log is off

    - binary logging is off

    - if the query generates row events in binlog row format mode
    (DDLs are always written in statement format irrespective of binlog_format
    and they can have SP variables in it. For example, 'ALTER EVENT' is allowed
    inside a procedure and can contain SP variables in it. Those too need to be
    substituted with NAME_CONST(...))

    query_name_consts is used elsewhere in a special case concerning
    CREATE TABLE, but we do not need to do anything about that here.

    The slow query log is another special case: we won't know whether a
    query qualifies for the slow query log until after it's been
    executed. We assume that most queries are not slow, so we do not
    pre-emptively substitute just for the slow query log. If a query
    ends up being slow after all and we haven't done the substitution
    already for any of the above (general log etc.), we'll do the
    substitution immediately before writing to the log.
  */

  need_subst = !((thd->variables.option_bits & OPTION_LOG_OFF) &&
                 (!(thd->variables.option_bits & OPTION_BIN_LOG) ||
                  !mysql_bin_log.is_open() ||
                  (thd->is_current_stmt_binlog_format_row() &&
                   sqlcom_can_generate_row_events(m_lex->sql_command))));

  /*
    If we need to do a substitution but can't (OOM), give up.
  */

  if (need_subst && subst_spvars(thd, this, m_query)) return true;

  if (unlikely((thd->variables.option_bits & OPTION_LOG_OFF) == 0))
    query_logger.general_log_write(thd, COM_QUERY, thd->query().str,
                                   thd->query().length);

  rc = validate_lex_and_execute_core(thd, nextp, false);

  if (thd->get_stmt_da()->is_eof()) {
    /* Finalize server status flags after executing a statement. */
    thd->update_slow_query_status();

    thd->send_statement_status();
  }

  const std::string &cn = Command_names::str_notranslate(COM_QUERY);
  mysql_audit_notify(
      thd, AUDIT_EVENT(MYSQL_AUDIT_GENERAL_STATUS),
      thd->get_stmt_da()->is_error() ? thd->get_stmt_da()->mysql_errno() : 0,
      cn.c_str(), cn.length());

  if (!rc && unlikely(log_slow_applicable(thd, get_command()))) {
    /*
      We actually need to write the slow log. Check whether we already
      called subst_spvars() above, otherwise, do it now.  In the highly
      unlikely event of subst_spvars() failing (OOM), we'll try to log
      the unmodified statement instead.
    */
    if (!need_subst) rc = subst_spvars(thd, this, m_query);
    /*
      We currently do not support --log-slow-extra for this case,
      and therefore pass in a null-pointer instead of a pointer to
      state at the beginning of execution.
    */
    log_slow_do(thd);
  }

  /*
    With the current setup, a subst_spvars() and a mysql_rewrite_query()
    (rewriting passwords etc.) will not both happen to a query.
    If this ever changes, we give the engineer pause here so they will
    double-check whether the potential conflict they created is a
    problem.
  */
  assert((thd->query_name_consts == 0) ||
         (thd->rewritten_query().length() == 0));

  thd->set_query(query_backup);
  thd->query_name_consts = 0;

  /* Restore the original query start time */
  if (thd->enable_slow_log) thd->set_time(time_info);

  return rc || thd->is_error();
}

void sp_instr_stmt::print(const THD *, String *str) {
  /* stmt CMD "..." */
  if (str->reserve(SP_STMT_PRINT_MAXLEN + SP_INSTR_UINT_MAXLEN + 8)) return;
  qs_append(STRING_WITH_LEN("stmt"), str);
  qs_append(STRING_WITH_LEN(" \""), str);

  /*
    Print the query string (but not too much of it), just to indicate which
    statement it is.
  */
  size_t len = m_query.length;
  if (len > SP_STMT_PRINT_MAXLEN) len = SP_STMT_PRINT_MAXLEN - 3;

  /* Copy the query string and replace '\n' with ' ' in the process */
  for (size_t i = 0; i < len; i++) {
    char c = m_query.str[i];
    if (c == '\n') c = ' ';
    qs_append(c, str);
  }
  if (m_query.length > SP_STMT_PRINT_MAXLEN)
    qs_append(STRING_WITH_LEN("..."), str); /* Indicate truncated string */
  qs_append(STRING_WITH_LEN("\""), str);
}

bool sp_instr_stmt::exec_core(THD *thd, uint *nextp) {
  LEX *const lex = thd->lex;
  lex->set_sp_current_parsing_ctx(get_parsing_ctx());
  lex->sphead = thd->sp_runtime_ctx->sp;

  PSI_statement_locker *statement_psi_saved = thd->m_statement_psi;

  assert(lex->m_sql_cmd == nullptr || lex->m_sql_cmd->is_part_of_sp());

  bool rc = mysql_execute_command(thd);

  lex->set_sp_current_parsing_ctx(nullptr);
  lex->sphead = nullptr;
  thd->m_statement_psi = statement_psi_saved;

  *nextp = get_ip() + 1;

  return rc;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_set implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_set::psi_info = {0, "set", 0, PSI_DOCUMENT_ME};
#endif

sp_rcontext *sp_instr_set::get_rcontext(THD *thd) const {
  return m_rcontext_handler->get_rcontext(thd->sp_runtime_ctx);
}

bool sp_instr_set::exec_core(THD *thd, uint *nextp) {
  sp_rcontext *ctx = get_rcontext(thd);
  *nextp = get_ip() + 1;

  if (!ctx->set_variable(thd, m_offset, &m_value_item)) return false;

  /* Failed to evaluate the value. Reset the variable to NULL. */

  if (ctx->set_variable(thd, m_offset, nullptr)) {
    /* If this also failed, let's abort. */
    my_error(ER_OUT_OF_RESOURCES, MYF(ME_FATALERROR));
  }

  return true;
}

void sp_instr_set::print(const THD *thd, String *str) {
  /* set name@offset ... */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 6;
  sp_variable *var = m_pcont->find_variable(m_offset);
  const LEX_CSTRING *prefix = m_rcontext_handler->get_name_prefix();

  /* 'var' should always be non-null, but just in case... */
  if (var) rsrv += var->name.length + prefix->length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("set "), str);
  qs_append(prefix->str, prefix->length, str);
  if (var) {
    qs_append(var->name.str, var->name.length, str);
    qs_append('@', str);
  }
  qs_append(m_offset, str);
  qs_append(' ', str);
  m_value_item->print(thd, str, QT_TO_ARGUMENT_CHARSET);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_set_row_field implementation.
///////////////////////////////////////////////////////////////////////////
bool sp_instr_set_row_field::exec_core(THD *thd, uint *nextp) {
  sp_rcontext *ctx = get_rcontext(thd);
  *nextp = get_ip() + 1;

  if (ctx->set_variable_row_field(thd, m_offset, m_field_offset, &m_value_item))
    return true;

  return false;
}

void sp_instr_set_row_field::print(const THD *thd, String *str) {
  /* set name@offset ... */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 40;
  sp_variable *var = m_pcont->find_variable(m_offset);
  const LEX_CSTRING *prefix = m_rcontext_handler->get_name_prefix();
  const Create_field *def = var->field_def.ora_record.row_field_definitions()
                                ->find_row_field_by_offset(m_field_offset);

  /* 'var' should always be non-null, but just in case... */
  if (var)
    rsrv += var->name.length + prefix->length + 5 + strlen(def->field_name);
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("set "), str);
  qs_append(prefix->str, prefix->length, str);
  qs_append(var->name.str, var->name.length, str);
  qs_append('.', str);
  qs_append(to_lex_cstring(def->field_name).str,
            to_lex_cstring(def->field_name).length, str);
  qs_append('@', str);
  qs_append(m_offset, str);
  qs_append('[', str);
  qs_append(m_field_offset, str);
  qs_append(']', str);
  qs_append(' ', str);
  m_value_item->print(thd, str, QT_TO_ARGUMENT_CHARSET);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_setup_row_field implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_setup_row_field::psi_info = {0, "setup_row_field",
                                                         0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_setup_row_field::execute(THD *thd, uint *nextp) {
  sp_rcontext *ctx = thd->sp_runtime_ctx;
  *nextp = get_ip() + 1;
  Query_arena old_arena;
  thd->swap_query_arena(*thd->sp_runtime_ctx->callers_arena, &old_arena);
  Item *item = ctx->get_item(m_spv->offset);
  sp_variable *spv_last =
      ctx->search_variable(m_spv->name.str, m_spv->name.length);
  bool rc = true;
  Item_field_row_table *item_table = dynamic_cast<Item_field_row_table *>(item);
  if (item_table) {
    rc = item_table->row_table_create_items(
        thd, spv_last->field_def.ora_record.row_field_table_definitions());
  } else {
    rc = item->row_create_items(
        thd, spv_last->field_def.ora_record.row_field_definitions());
  }
  thd->swap_query_arena(old_arena, thd->sp_runtime_ctx->callers_arena);
  return rc;
}

void sp_instr_setup_row_field::print(const THD *, String *str) {
  /* set name@offset ... */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + m_spv->name.length + 18;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("setup_row_field "), str);
  qs_append(m_spv->name.str, m_spv->name.length, str);
  qs_append('@', str);
  qs_append(m_spv->offset, str);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_set_row_field_by_name implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_set_row_field_by_name::psi_info = {
    0, "set_row_field", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_set_row_field_by_name::exec_core(THD *thd, uint *nextp) {
  sp_rcontext *ctx = get_rcontext(thd);
  *nextp = get_ip() + 1;

  if (ctx->set_variable_row_field_by_name(thd, m_offset, m_field_name,
                                          &m_value_item))
    return true;

  return false;
}

void sp_instr_set_row_field_by_name::print(const THD *thd, String *str) {
  /* set name@offset ... */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 6;
  sp_variable *var = m_pcont->find_variable(m_offset);
  const LEX_CSTRING *prefix = m_rcontext_handler->get_name_prefix();

  /* 'var' should always be non-null, but just in case... */
  if (var)
    rsrv += var->name.length + prefix->length + m_field_name.length * 2 + 2;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("set "), str);
  qs_append(prefix->str, prefix->length, str);
  qs_append(var->name.str, var->name.length, str);
  qs_append('.', str);
  qs_append(m_field_name.str, m_field_name.length, str);
  qs_append('@', str);
  qs_append(m_offset, str);
  qs_append('[', str);
  qs_append(m_field_name.str, m_field_name.length, str);
  qs_append(']', str);
  qs_append(' ', str);
  m_value_item->print(thd, str, QT_TO_ARGUMENT_CHARSET);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_set_row_field_table_by_name implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_set_row_field_table_by_name::psi_info = {
    0, "set_row_field_table_by_name", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_set_row_field_table_by_name::exec_core(THD *thd, uint *nextp) {
  sp_rcontext *ctx = get_rcontext(thd);
  *nextp = get_ip() + 1;
  if (ctx->set_variable_row_table_by_name(thd, m_pcont, m_offset, m_field_name,
                                          m_args_list, &m_value_item))
    return true;

  return false;
}

void sp_instr_set_row_field_table_by_name::print(const THD *thd, String *str) {
  /* set name@offset ... */
  size_t reslen = m_field_name.length + 8;
  List_iterator_fast<ora_simple_ident_def> it_len(*m_args_list);
  ora_simple_ident_def *def_len;
  for (uint offset = 0; (def_len = it_len++); offset++) {
    reslen = reslen + def_len->ident.length + 1;
    if (def_len->number != nullptr) {
      reslen = reslen + def_len->number->item_name.length() + 2;
    }
  }
  str->reserve(reslen);
  qs_append(STRING_WITH_LEN("set "), str);
  List_iterator_fast<ora_simple_ident_def> it(*m_args_list);
  ora_simple_ident_def *def;
  for (uint offset = 0; (def = it++); offset++) {
    str->append(def->ident);
    if (def->number != nullptr) {
      str->append('(');
      str->append(def->number->item_name.ptr());
      str->append(')');
    }
    str->append('.');
  }
  str->append(to_lex_string(m_field_name));
  qs_append(' ', str);
  m_value_item->print(thd, str, QT_TO_ARGUMENT_CHARSET);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_set_row_field_table_by_index implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_set_row_field_table_by_index::psi_info = {
    0, "set_row_field_table_by_index", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_set_row_field_table_by_index::exec_core(THD *thd, uint *nextp) {
  sp_rcontext *ctx = get_rcontext(thd);
  *nextp = get_ip() + 1;
  if (ctx->set_variable_row_table_by_index(thd, m_offset, m_index,
                                           &m_value_item))
    return true;

  return false;
}

void sp_instr_set_row_field_table_by_index::print(const THD *thd, String *str) {
  /* set name@offset ... */
  const char *index_name = nullptr;
  if (m_index->is_splocal()) {
    Item_splocal *item_sp = dynamic_cast<Item_splocal *>(m_index);
    index_name = item_sp->m_name.ptr();
  } else
    index_name = m_index->full_name();
  size_t reslen = strlen(index_name) + 8;
  sp_variable *var = m_pcont->find_variable(m_offset);
  if (var) reslen += var->name.length;
  str->reserve(reslen);
  qs_append(STRING_WITH_LEN("set_record_table "), str);
  str->append(var->name.str);
  str->append('(');
  str->append(index_name);
  str->append(')');
  qs_append(' ', str);
  m_value_item->print(thd, str, QT_TO_ARGUMENT_CHARSET);
}
///////////////////////////////////////////////////////////////////////////
// sp_instr_set_trigger_field implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_set_trigger_field::psi_info = {
    0, "set_trigger_field", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_set_trigger_field::exec_core(THD *thd, uint *nextp) {
  *nextp = get_ip() + 1;
  thd->check_for_truncated_fields = CHECK_FIELD_ERROR_FOR_NULL;
  Strict_error_handler strict_handler(
      Strict_error_handler::ENABLE_SET_SELECT_STRICT_ERROR_HANDLER);
  /*
    Before Triggers are executed after the 'data' is assigned
    to the Field objects. If triggers wants to SET invalid value
    to the Field objects (NEW.<variable_name>= <Invalid value>),
    it should not be allowed.
  */
  if (thd->is_strict_mode() && !thd->lex->is_ignore())
    thd->push_internal_handler(&strict_handler);
  bool error = m_trigger_field->set_value(thd, &m_value_item);
  if (thd->is_strict_mode() && !thd->lex->is_ignore())
    thd->pop_internal_handler();
  return error;
}

void sp_instr_set_trigger_field::print(const THD *thd, String *str) {
  str->append(STRING_WITH_LEN("set_trigger_field "));
  m_trigger_field->print(thd, str, QT_ORDINARY);
  str->append(STRING_WITH_LEN(":="));
  m_value_item->print(thd, str, QT_TO_ARGUMENT_CHARSET);
}

bool sp_instr_set_trigger_field::on_after_expr_parsing(THD *thd) {
  m_value_item = thd->lex->query_block->single_visible_field();
  assert(m_value_item != nullptr);

  assert(!m_trigger_field);

  m_trigger_field = new (thd->mem_root)
      Item_trigger_field(thd->lex->current_context(), TRG_NEW_ROW,
                         m_trigger_field_name.str, UPDATE_ACL, false);

  if (m_trigger_field) {
    /* Adding m_trigger_field to the list of all Item_trigger_field objects */
    sp_head *sp = thd->sp_runtime_ctx->sp;
    sp->m_cur_instr_trig_field_items.link_in_list(
        m_trigger_field, &m_trigger_field->next_trg_field);
  }

  return m_value_item == nullptr || m_trigger_field == nullptr;
}

void sp_instr_set_trigger_field::cleanup_before_parsing(THD *thd) {
  sp_lex_instr::cleanup_before_parsing(thd);

  m_trigger_field = nullptr;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_jump implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_jump::psi_info = {0, "jump", 0, PSI_DOCUMENT_ME};
#endif

void sp_instr_jump::print(const THD *, String *str) {
  /* jump dest */
  if (str->reserve(SP_INSTR_UINT_MAXLEN + 5)) return;
  qs_append(STRING_WITH_LEN("jump "), str);
  qs_append(m_dest, str);
}

uint sp_instr_jump::opt_mark(sp_head *sp, List<sp_instr> *) {
  m_dest = opt_shortcut_jump(sp, this);
  if (m_dest != get_ip() + 1) /* Jumping to following instruction? */
    m_marked = true;
  m_optdest = sp->get_instr(m_dest);
  return m_dest;
}

uint sp_instr_jump::opt_shortcut_jump(sp_head *sp, sp_instr *start) {
  uint dest = m_dest;
  sp_instr *i;

  while ((i = sp->get_instr(dest))) {
    uint ndest;

    if (start == i || this == i) break;
    ndest = i->opt_shortcut_jump(sp, start);
    if (ndest == dest) break;
    dest = ndest;
  }
  return dest;
}

void sp_instr_jump::opt_move(uint dst, List<sp_branch_instr> *bp) {
  if (m_dest > get_ip())
    bp->push_back(this);  // Forward
  else if (m_optdest)
    m_dest = m_optdest->get_ip();  // Backward
  m_ip = dst;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_jump_if_not class implementation
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_jump_if_not::psi_info = {0, "jump_if_not", 0,
                                                     PSI_DOCUMENT_ME};
#endif

bool sp_instr_jump_if_not::exec_core(THD *thd, uint *nextp) {
  assert(m_expr_item);

  Item *item = sp_prepare_func_item(thd, &m_expr_item);

  if (!item) return true;

  if (item->result_type() == ROW_RESULT) {
    my_error(ER_NOT_SUPPORTED_YET, MYF(0), "expression is of wrong type");
    return true;
  }
  *nextp = item->val_bool() ? get_ip() + 1 : m_dest;

  return false;
}

void sp_instr_jump_if_not::print(const THD *thd, String *str) {
  /* jump_if_not dest(cont) ... */
  if (str->reserve(2 * SP_INSTR_UINT_MAXLEN + 14 +
                   32))  // Add some for the expr. too
    return;
  qs_append(STRING_WITH_LEN("jump_if_not "), str);
  qs_append(m_dest, str);
  qs_append('(', str);
  qs_append(m_cont_dest, str);
  qs_append(STRING_WITH_LEN(") "), str);
  m_expr_item->print(thd, str, QT_ORDINARY);
}

///////////////////////////////////////////////////////////////////////////
// sp_lex_branch_instr implementation.
///////////////////////////////////////////////////////////////////////////

uint sp_lex_branch_instr::opt_mark(sp_head *sp, List<sp_instr> *leads) {
  m_marked = true;

  sp_instr *i = sp->get_instr(m_dest);

  if (i) {
    m_dest = i->opt_shortcut_jump(sp, this);
    m_optdest = sp->get_instr(m_dest);
  }

  sp->add_mark_lead(m_dest, leads);

  i = sp->get_instr(m_cont_dest);

  if (i) {
    m_cont_dest = i->opt_shortcut_jump(sp, this);
    m_cont_optdest = sp->get_instr(m_cont_dest);
  }

  sp->add_mark_lead(m_cont_dest, leads);

  return get_ip() + 1;
}

void sp_lex_branch_instr::opt_move(uint dst, List<sp_branch_instr> *bp) {
  /*
    cont. destinations may point backwards after shortcutting jumps
    during the mark phase. If it's still pointing forwards, only
    push this for backpatching if sp_instr_jump::opt_move() will not
    do it (i.e. if the m_dest points backwards).
   */
  if (m_cont_dest > get_ip()) {  // Forward
    if (m_dest < get_ip()) bp->push_back(this);
  } else if (m_cont_optdest)
    m_cont_dest = m_cont_optdest->get_ip();  // Backward

  /* This will take care of m_dest and m_ip */
  if (m_dest > get_ip())
    bp->push_back(this);  // Forward
  else if (m_optdest)
    m_dest = m_optdest->get_ip();  // Backward
  m_ip = dst;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_jump_case_when implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_jump_case_when::psi_info = {0, "jump_case_when", 0,
                                                        PSI_DOCUMENT_ME};
#endif

bool sp_instr_jump_case_when::exec_core(THD *thd, uint *nextp) {
  assert(m_eq_item);

  Item *item = sp_prepare_func_item(thd, &m_eq_item);

  if (!item) return true;

  *nextp = item->val_bool() ? get_ip() + 1 : m_dest;

  return false;
}

void sp_instr_jump_case_when::print(const THD *thd, String *str) {
  /* jump_if_not dest(cont) ... */
  if (str->reserve(2 * SP_INSTR_UINT_MAXLEN + 14 +
                   32))  // Add some for the expr. too
    return;
  qs_append(STRING_WITH_LEN("jump_if_not_case_when "), str);
  qs_append(m_dest, str);
  qs_append('(', str);
  qs_append(m_cont_dest, str);
  qs_append(STRING_WITH_LEN(") "), str);
  m_eq_item->print(thd, str, QT_ORDINARY);
}

bool sp_instr_jump_case_when::on_after_expr_parsing(THD *thd) {
  // Setup CASE-expression item (m_case_expr_item).

  m_case_expr_item = new Item_case_expr(m_case_expr_id);

  if (!m_case_expr_item) return true;

#ifndef NDEBUG
  m_case_expr_item->m_sp = thd->lex->sphead;
#endif

  // Setup WHEN-expression item (m_expr_item) if it is not already set.
  //
  // This function can be called in two cases:
  //
  //   - during initial (regular) parsing of SP. In this case we don't have
  //     lex->query_block (because it's not a SELECT statement), but
  //     m_expr_item is already set in constructor.
  //
  //   - during re-parsing after meta-data change. In this case we've just
  //     parsed aux-SELECT statement, so we need to take 1st (and the only one)
  //     item from its list.

  if (!m_expr_item) {
    m_expr_item = thd->lex->query_block->single_visible_field();
    assert(m_expr_item != nullptr);
  }

  // Setup main expression item (m_expr_item).

  m_eq_item = new Item_func_eq(m_case_expr_item, m_expr_item);

  if (!m_eq_item) return true;

  return false;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_freturn implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_freturn::psi_info = {0, "freturn", 0,
                                                 PSI_DOCUMENT_ME};
#endif

bool sp_instr_freturn::exec_core(THD *thd, uint *nextp) {
  /*
    Change <next instruction pointer>, so that this will be the last
    instruction in the stored function.
  */

  *nextp = UINT_MAX;

  /*
    Evaluate the value of return expression and store it in current runtime
    context.

    NOTE: It's necessary to evaluate result item right here, because we must
    do it in scope of execution the current context/block.
  */

  return thd->sp_runtime_ctx->set_return_value(thd, &m_expr_item);
}

void sp_instr_freturn::print(const THD *thd, String *str) {
  /* freturn type expr... */
  if (str->reserve(1024 + 8 + 32))  // Add some for the expr. too
    return;
  qs_append(STRING_WITH_LEN("freturn "), str);
  qs_append((uint)m_return_field_type, str);
  qs_append(' ', str);
  m_expr_item->print(thd, str, QT_ORDINARY);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_preturn implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_preturn::psi_info = {0, "preturn", 0,
                                                 PSI_DOCUMENT_ME};
#endif
uint sp_instr_preturn::opt_mark(sp_head *, List<sp_instr> *) {
  m_marked = true;
  return UINT_MAX;
}

bool sp_instr_preturn::execute(THD *, uint *nextp) {
  DBUG_ENTER("sp_instr_preturn::execute");
  *nextp = UINT_MAX;
  DBUG_RETURN(false);
}

void sp_instr_preturn::print(const THD *, String *str) {
  str->append(STRING_WITH_LEN("preturn"));
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_hpush_jump implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_hpush_jump::psi_info = {0, "hpush_jump", 0,
                                                    PSI_DOCUMENT_ME};
#endif

sp_instr_hpush_jump::sp_instr_hpush_jump(uint ip, sp_pcontext *ctx,
                                         sp_handler *handler)
    : sp_instr_jump(ip, ctx),
      m_handler(handler),
      m_opt_hpop(0),
      m_frame(ctx->current_var_count()) {
  assert(m_handler->condition_values.elements == 0);
}

sp_instr_hpush_jump::~sp_instr_hpush_jump() {
  m_handler->condition_values.clear();
  m_handler = nullptr;
}

void sp_instr_hpush_jump::add_condition(sp_condition_value *condition_value) {
  m_handler->condition_values.push_back(condition_value);
}

bool sp_instr_hpush_jump::execute(THD *thd, uint *nextp) {
  *nextp = m_dest;

  return thd->sp_runtime_ctx->push_handler(m_handler, get_ip() + 1);
}

void sp_instr_hpush_jump::print(const THD *, String *str) {
  /* hpush_jump dest fsize type */
  if (str->reserve(SP_INSTR_UINT_MAXLEN * 2 + 21)) return;

  qs_append(STRING_WITH_LEN("hpush_jump "), str);
  qs_append(m_dest, str);
  qs_append(' ', str);
  qs_append(m_frame, str);

  m_handler->print(str);
}

uint sp_instr_hpush_jump::opt_mark(sp_head *sp, List<sp_instr> *leads) {
  m_marked = true;

  sp_instr *i = sp->get_instr(m_dest);

  if (i) {
    m_dest = i->opt_shortcut_jump(sp, this);
    m_optdest = sp->get_instr(m_dest);
  }

  sp->add_mark_lead(m_dest, leads);

  /*
    For continue handlers, all instructions in the scope of the handler
    are possible leads. For example, the instruction after freturn might
    be executed if the freturn triggers the condition handled by the
    continue handler.

    m_dest marks the start of the handler scope. It's added as a lead
    above, so we start on m_dest+1 here.
    m_opt_hpop is the hpop marking the end of the handler scope.
  */
  if (m_handler->type == sp_handler::CONTINUE) {
    for (uint scope_ip = m_dest + 1; scope_ip <= m_opt_hpop; scope_ip++)
      sp->add_mark_lead(scope_ip, leads);
  }

  return get_ip() + 1;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_hpop implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_hpop::psi_info = {0, "hpop", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_hpop::execute(THD *thd, uint *nextp) {
  thd->sp_runtime_ctx->pop_handlers(m_parsing_ctx);
  *nextp = get_ip() + 1;
  return false;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_goto implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_goto::psi_info = {0, "goto", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_goto::execute(THD *thd, uint *nextp) {
  // for goto label,it doesn't do pop_cursors.
  if (!m_ignore_cursor_execute)
    thd->sp_runtime_ctx->pop_cursors(m_cursor_count);
  // for goto label,it doesn't do pop_handlers.
  if (!m_ignore_handler_execute)
    thd->sp_runtime_ctx->pop_handlers(m_parsing_ctx, m_handler_count);
  *nextp = get_ip() + 1;
  return false;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_continue implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_continue::psi_info = {0, "continue", 0,
                                                  PSI_DOCUMENT_ME};
#endif

///////////////////////////////////////////////////////////////////////////
// sp_instr_hreturn implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_hreturn::psi_info = {0, "hreturn", 0,
                                                 PSI_DOCUMENT_ME};
#endif

sp_instr_hreturn::sp_instr_hreturn(uint ip, sp_pcontext *ctx)
    : sp_instr_jump(ip, ctx), m_frame(ctx->current_var_count()) {}

bool sp_instr_hreturn::execute(THD *thd, uint *nextp) {
  /*
    Obtain next instruction pointer (m_dest is set for EXIT handlers, retrieve
    the instruction pointer from runtime context for CONTINUE handlers).
  */

  sp_rcontext *rctx = thd->sp_runtime_ctx;

  *nextp = m_dest ? m_dest : rctx->get_last_handler_continue_ip();

  /*
    Remove call frames for handlers, which are "below" the BEGIN..END block of
    the next instruction.
  */

  sp_instr *next_instr = rctx->sp->get_instr(*nextp);
  rctx->exit_handler(thd, next_instr->get_parsing_ctx());

  return false;
}

void sp_instr_hreturn::print(const THD *, String *str) {
  /* hreturn framesize dest */
  if (str->reserve(SP_INSTR_UINT_MAXLEN * 2 + 9)) return;
  qs_append(STRING_WITH_LEN("hreturn "), str);
  if (m_dest) {
    // NOTE: this is legacy: hreturn instruction for EXIT handler
    // should print out 0 as frame index.
    qs_append(STRING_WITH_LEN("0 "), str);
    qs_append(m_dest, str);
  } else {
    qs_append(m_frame, str);
  }
}

uint sp_instr_hreturn::opt_mark(sp_head *, List<sp_instr> *) {
  m_marked = true;

  if (m_dest) {
    /*
      This is an EXIT handler; next instruction step is in m_dest.
     */
    return m_dest;
  }

  /*
    This is a CONTINUE handler; next instruction step will come from
    the handler stack and not from opt_mark.
   */
  return UINT_MAX;
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_cpush implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cpush::psi_info = {0, "cpush", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_cpush::execute(THD *thd, uint *nextp) {
  *nextp = get_ip() + 1;

  /*for ref cursor as next,if the cursor exists,return false.
  e.g:
  Loop
    for i in (select stmt) loop
    end loop;
  end loop;*/
  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  if (c) return false;

  bool rc = thd->sp_runtime_ctx->push_cursor(this, m_cursor_idx);
  if (rc) return true;
  c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), "cursor");
    return true;
  }
  if (!(thd->variables.sql_mode & MODE_ORACLE)) return rc;

  // for cursor return type save the structure.
  sp_pcursor *pcursor = m_parsing_ctx->find_cursor_parameters(m_cursor_idx);
  if (!pcursor) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), "cursor");
    return true;
  }
  /// for cursor return type
  if (c->m_result.get_return_table()) return false;
  // For static cursor,it needs the table's column name not return columns's
  // name.
  is_copy_struct = true;
  rc = validate_lex_and_execute_core(thd, nextp, false);
  is_copy_struct = false;
  return rc;
}

bool sp_instr_cpush::exec_core(THD *thd, uint *) {
  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);

  // sp_instr_cpush::exec_core() opens the cursor (it's called from
  // sp_instr_copen::execute().
  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), "cursor");
  }
  return c ? c->open(thd) : true;
}

void sp_instr_cpush::print(const THD *, String *str) {
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);

  size_t rsrv = SP_INSTR_UINT_MAXLEN + 7 + m_cursor_query.length + 1;

  if (cursor_name) rsrv += cursor_name->length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("cpush "), str);
  if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
  }
  qs_append(m_cursor_idx, str);

  qs_append(':', str);
  qs_append(m_cursor_query.str, m_cursor_query.length, str);
}

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cpush_rowtype::psi_info = {0, "cpush_rowtype", 0,
                                                       PSI_DOCUMENT_ME};
#endif

bool sp_instr_cpush_rowtype::on_after_expr_parsing(THD *thd) {
  m_valid = true;
  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  /*for cursor,if it has dblink table,don't need to reopen cursor to get
  struture, because alter dblink table doesn't support.*/
  if (!c->m_push_instr->is_dblink_table(thd)) is_copy_struct = true;
  return false;
}

bool sp_instr_cpush_rowtype::exec_core(THD *thd, uint *) {
  // sp_instr_cpush_rowtype::exec_core() opens the cursor (it's called from
  // sp_instr_copen::execute().

  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);

  if (!is_copy_struct) {
    if (!c || c->open(thd)) {
      my_error(ER_SP_CURSOR_FAILED, MYF(0));
      return true;
    }
    return false;
  }

  bool rc = true;
  List<Create_field> defs;
  // Used to avoid sequence add.
  m_lex->is_cursor_get_structure = true;
  Query_arena old_arena;
  thd->swap_query_arena(*thd->sp_runtime_ctx->callers_arena, &old_arena);
  if (!c || c->open(thd)) {
    my_error(ER_SP_CURSOR_FAILED, MYF(0));
    goto finish;
  }
    /*
      Create row elements on the caller arena.
      It's the same arena that was used during sp_rcontext::create().
      This puts cursor%ROWTYPE elements on the same mem_root
      where explicit ROW elements and table%ROWTYPE reside:
      - tmp.export_structure() allocates new List<Create_field> instances
        and their components (such as TYPELIBs).
      - row->row_create_items() creates new Item_field instances.
      They all are created on the same mem_root.
    */
  if (c->export_structure(thd, &defs) ||
      thd->sp_runtime_ctx->add_udt_to_sp_var_list(thd, defs))
    goto finish;

  rc = copy_structure_from_return(thd, c, &defs);

finish:
  m_lex->is_cursor_get_structure = false;
  if (c->is_open()) rc = rc || c->close();
  thd->swap_query_arena(old_arena, thd->sp_runtime_ctx->callers_arena);
  return rc;
}

bool sp_instr_cpush_rowtype::copy_structure_from_return(
    THD *thd, sp_cursor *c, List<Create_field> *defs_c) {
  sp_pcursor *pcursor = m_parsing_ctx->find_cursor_parameters(m_cursor_idx);
  if (!pcursor) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), "cursor");
    return true;
  }

  if (!(pcursor->get_table_ref() || pcursor->get_row_definition_list() ||
        pcursor->get_cursor_rowtype_offset() != -1)) {
    if (c->make_return_table(thd, defs_c, defs_c)) return true;
  } else {
    if (pcursor->get_table_ref()) {
      List<Create_field> defs;
      if (pcursor->get_table_ref()->resolve_table_rowtype_ref(thd, defs))
        return true;
      if (c->make_return_table(thd, &defs, defs_c)) return true;
    } else if (pcursor->get_row_definition_list()) {
      List<Create_field> *defs_tmp = dynamic_cast<List<Create_field> *>(
          pcursor->get_row_definition_list());
      if (c->make_return_table(thd, defs_tmp, defs_c)) return true;
    } else if (pcursor->get_cursor_rowtype_offset() != -1) {
      sp_cursor *c_return =
          thd->sp_runtime_ctx->get_cursor(pcursor->get_cursor_rowtype_offset());
      if (c_return) {
        if (c_return->m_result.get_return_table()) {
          if (c->set_return_table_from_cursor(c_return, defs_c)) return true;
        } else {
          my_error(ER_SP_CURSOR_MISMATCH, MYF(0), pcursor->str);  // unreachable
          return true;
        }
      } else {  // it's type is ref cursor
        sp_pcursor *pcursor_def = m_parsing_ctx->find_cursor_parameters(
            pcursor->get_cursor_rowtype_offset());
        if (c->set_return_table_from_pcursor(thd, pcursor_def)) return true;
      }
    }
  }
  return false;
}

void sp_instr_cpush_rowtype::cleanup_mem_root() {
  Item *item = current_thd->sp_runtime_ctx->get_item(m_for_var);
  if (item->type() != Item::ORACLE_ROWTYPE_ITEM) return;
  Item_field *item_field = down_cast<Item_field *>(item);
  if (!item_field->field->m_udt_table) return;
  item_field->field->clear_table_all_field();
  m_copy_struct_arena.free_items();
  m_copy_struct_mem_root.ClearForReuse();
}

void sp_instr_cpush_rowtype::print(const THD *, String *str) {
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);

  size_t rsrv = SP_INSTR_UINT_MAXLEN + 15 + m_cursor_query.length + 1;

  if (cursor_name) rsrv += cursor_name->length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("cpush_rowtype "), str);
  if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
  }
  qs_append(m_cursor_idx, str);

  qs_append(':', str);
  qs_append(m_cursor_query.str, m_cursor_query.length, str);
}

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_copen_for::psi_info = {0, "open_for", 0,
                                                   PSI_DOCUMENT_ME};
#endif

bool sp_instr_copen_for_sql::execute(THD *thd, uint *nextp) {
  *nextp = get_ip() + 1;
  // lex->result has been set to nullptr in sp_refcursor::open_for_sql,so it
  // must reparse.
  invalidate();
  const LEX_CSTRING query_backup = thd->query();
  if (alloc_query(thd, m_cursor_query.str, m_cursor_query.length)) return true;
  bool rc = validate_lex_and_execute_core(thd, nextp, false);
  thd->set_query(query_backup);
  return rc;
}

bool sp_instr_copen_for_sql::exec_core(THD *thd, uint *) {
  Item *item = thd->sp_runtime_ctx->get_item(m_spv_idx);
  Item_field_refcursor *item_field = dynamic_cast<Item_field_refcursor *>(item);
  Field_refcursor *field_ref = item_field->get_refcursor_field();
  if (field_ref->m_is_in_mode) {
    my_error(ER_NOT_SUPPORTED_YET, MYF(0), "change ref cursor of in mode");
    return true;
  }
  if (!field_ref->m_cursor)
    field_ref->m_cursor = std::make_shared<sp_refcursor>();
  else
    field_ref->release_cursor();

  field_ref->set_cursor_return_type();
  bool rc = field_ref->m_cursor->open_for_sql(thd);
  /*
  1.item:
    the item's m_arena is same as
    sp_instr_copen_for_sql->m_arena, but for item->xx,its
    m_arena is field_ref->m_cursor's m_arena, so it needs to cleanup here.
  2.m_lex->unit->master:
    the m_lex->unit->master->window->m_partition_items/m_order_by_items
    m_arena is same as
    sp_instr_copen_for_sql->m_arena, but for Cached_item of m_partition_items
    and Cached_item of m_order_by_items,its
    m_arena is field_ref->m_cursor's m_arena, so it needs to destroy(ci) here.
    e.g:select avg(a) keep (DENSE_RANK first ORDER BY b) OVER (partition by a)
  from t1
  */
  Item *item_arena = m_arena.item_list();
  Item *next;
  for (; item_arena; item_arena = next) {
    next = item_arena->next_free;
    item_arena->cleanup_for_refcursor();
  }
  m_lex->unit->destroy();
  m_lex->unit = nullptr;
  return rc;
}

void sp_instr_copen_for_sql::print(const THD *, String *str) {
  sp_variable *var = m_parsing_ctx->find_variable(m_spv_idx);
  size_t rsrv =
      SP_INSTR_UINT_MAXLEN + 11 + m_cursor_query.length + var->name.length + 1;

  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("open_for "), str);
  qs_append(var->name.str, var->name.length, str);
  qs_append('@', str);

  qs_append(m_spv_idx, str);
  qs_append(STRING_WITH_LEN(" "), str);

  qs_append(m_cursor_query.str, m_cursor_query.length, str);
}

bool sp_instr_copen_for_ident::execute(THD *thd, uint *nextp) {
  clear_da(thd);
  *nextp = get_ip() + 1;

  return validate_lex_and_execute_core(thd, nextp, true);
}

bool sp_instr_copen_for_ident::exec_core(THD *thd, uint *nextp) {
  *nextp = get_ip() + 1;
  Item *item = thd->sp_runtime_ctx->get_item(m_spv_idx);
  Item_field_refcursor *item_field = dynamic_cast<Item_field_refcursor *>(item);
  Field_refcursor *field_ref = item_field->get_refcursor_field();
  if (field_ref->m_is_in_mode) {
    my_error(ER_NOT_SUPPORTED_YET, MYF(0), "change ref cursor of in mode");
    return true;
  }
  if (!field_ref->m_cursor)
    field_ref->m_cursor = std::make_shared<sp_refcursor>();
  else
    field_ref->release_cursor();

  field_ref->set_cursor_return_type();
  bool rc = field_ref->m_cursor->open_for_ident(thd, m_sql_spv_idx);
  if (rc) {
    return rc;
  }
  thd->lex->set_exec_started();
  return rc;
}

void sp_instr_copen_for_ident::print(const THD *, String *str) {
  sp_variable *var_cursor = m_parsing_ctx->find_variable(m_spv_idx);
  sp_variable *var_sql = m_parsing_ctx->find_variable(m_sql_spv_idx);
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 11 + var_cursor->name.length +
                var_sql->name.length + 1;

  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("open_for "), str);
  qs_append(var_cursor->name.str, var_cursor->name.length, str);
  qs_append('@', str);
  qs_append(m_spv_idx, str);
  qs_append(STRING_WITH_LEN(" "), str);

  qs_append(var_sql->name.str, var_sql->name.length, str);
  qs_append('@', str);
  qs_append(m_sql_spv_idx, str);
}
///////////////////////////////////////////////////////////////////////////
// sp_instr_cpop implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cpop::psi_info = {0, "cpop", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_cpop::execute(THD *thd, uint *nextp) {
  thd->sp_runtime_ctx->pop_cursors(m_count);
  *nextp = get_ip() + 1;

  return false;
}

void sp_instr_cpop::print(const THD *, String *str) {
  /* cpop count */
  if (str->reserve(SP_INSTR_UINT_MAXLEN + 5)) return;
  qs_append(STRING_WITH_LEN("cpop "), str);
  qs_append(m_count, str);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_copen implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_copen::psi_info = {0, "copen", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_copen::execute(THD *thd, uint *nextp) {
  // Manipulating a CURSOR with an expression should clear DA.
  clear_da(thd);

  *nextp = get_ip() + 1;

  // Get the cursor pointer.

  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);

  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), "cursor");
    return true;
  }

  // Retrieve sp_instr_cpush instance.

  sp_instr_cpush *push_instr = c->get_push_instr();

  // Switch Statement Arena to the sp_instr_cpush object. It contains the
  // item list of the query, so new items (if any) are stored in the right
  // item list, and we can cleanup after each open.

  Query_arena *stmt_arena_saved = thd->stmt_arena;
  thd->stmt_arena = &push_instr->m_arena;

  // Switch to the cursor's lex and execute sp_instr_cpush::exec_core().
  // sp_instr_cpush::exec_core() is *not* executed during
  // sp_instr_cpush::execute(). sp_instr_cpush::exec_core() is intended to be
  // executed on cursor opening.

  bool rc = push_instr->validate_lex_and_execute_core(thd, nextp, false);

  // Cleanup the query's items.

  cleanup_items(push_instr->m_arena.item_list());

  if (!rc && push_instr->is_copy_struct) {
    // If table structure changed,it needs reopen cursor to get cursor
    // structure.
    push_instr->is_copy_struct = false;
    push_instr->m_is_copen = true;
    rc = push_instr->validate_lex_and_execute_core(thd, nextp, false);
    cleanup_items(push_instr->m_arena.item_list());
    push_instr->m_is_copen = false;
  }

  // Restore Statement Arena.

  thd->stmt_arena = stmt_arena_saved;

  return rc;
}

void sp_instr_copen::print(const THD *, String *str) {
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);

  /* copen name@offset */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 7;

  if (cursor_name) rsrv += cursor_name->length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("copen "), str);
  if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
  }
  qs_append(m_cursor_idx, str);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_cursor_copy_struct implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cursor_copy_struct::psi_info = {
    0, "cursor_copy_struct", 0, PSI_DOCUMENT_ME};
#endif

bool sp_instr_cursor_copy_struct::execute(THD *thd, uint *nextp) {
  // Manipulating a CURSOR with an expression should clear DA.
  clear_da(thd);

  *nextp = get_ip() + 1;

  // Get the cursor pointer.
  sp_pcursor *pcursor = m_parsing_ctx->find_cursor_parameters(m_cursor_idx);
  if (!pcursor) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), "cursor");
    return true;
  }

  // If it's ref cursor define.
  if (pcursor->get_cursor_spv()) {
    Item_field_refcursor *item_cursor = dynamic_cast<Item_field_refcursor *>(
        thd->sp_runtime_ctx->get_item(pcursor->get_cursor_spv()->offset));
    return item_cursor->set_cursor_rowtype_table(
        thd, thd->sp_runtime_ctx->get_item(m_var), pcursor->has_return_type(),
        pcursor->get_cursor_spv()->offset);
  }

  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0), pcursor->str);
    return true;
  }

  /* for next case,table's structure may change,so it needs reopen cursor to get
  structure. 1.TYPE ref_rs1 IS REF CURSOR RETURN cursor%rowtype; 2.cc
  cursor%rowtype 3.for i in cursor loop*/
  sp_instr_cpush *push_instr = c->get_push_instr();
  Query_arena *stmt_arena_saved = thd->stmt_arena;
  thd->stmt_arena = &push_instr->m_arena;
  push_instr->is_copy_struct = true;
  sp_instr_cpush_rowtype *push_instr_rowtype =
      down_cast<sp_instr_cpush_rowtype *>(push_instr);
  assert(push_instr_rowtype);
  push_instr_rowtype->m_for_var = m_var;
  // destroy items to avoid leave_stmt or goto_stmt in loop.
  push_instr_rowtype->cleanup_mem_root();
  bool ret = push_instr->validate_lex_and_execute_core(thd, nextp, false);
  push_instr->is_copy_struct = false;
  cleanup_items(push_instr->m_arena.item_list());
  thd->stmt_arena = stmt_arena_saved;
  if (ret) return ret;

  Item *item = thd->sp_runtime_ctx->get_item(m_var);
  Query_arena old_arena;
  Query_arena *swap_arena = m_is_cursor
                                ? &push_instr_rowtype->m_copy_struct_arena
                                : thd->sp_runtime_ctx->callers_arena;
  thd->swap_query_arena(*swap_arena, &old_arena);
  const auto x_guard = create_scope_guard([thd, old_arena, swap_arena]() {
    thd->swap_query_arena(old_arena, swap_arena);
  });
  List<Create_field> defs;
  if (c->m_result.get_return_table()->s->export_structure(thd, &defs)) {
    return true;
  }

  ret = item->modify_item_field_about_cursor(thd, &defs, c);
  return ret;
}

void sp_instr_cursor_copy_struct::print(const THD *, String *str) {
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);
  sp_variable *var = m_parsing_ctx->find_variable(m_var);

  /* cursor_copy_struct name@offset */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 20;

  if (cursor_name) rsrv += cursor_name->length + var->name.length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("cursor_copy_struct "), str);
  if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
  }
  qs_append(m_cursor_idx, str);
  qs_append(' ', str);
  qs_append(var->name.str, var->name.length, str);
  qs_append('@', str);
  qs_append(m_var, str);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_cclose implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cclose::psi_info = {0, "cclose", 0,
                                                PSI_DOCUMENT_ME};
#endif

bool sp_instr_cclose::execute(THD *thd, uint *nextp) {
  // Manipulating a CURSOR with an expression should clear DA.
  clear_da(thd);

  *nextp = get_ip() + 1;

  if (m_cursor_spv) {
    Item_field_refcursor *item = dynamic_cast<Item_field_refcursor *>(
        thd->sp_runtime_ctx->get_item(m_cursor_spv->offset));
    Field_refcursor *field = item->get_refcursor_field();
    if (!field->m_cursor || !field->m_cursor->is_defined()) {
      my_error(ER_SP_CURSOR_MISMATCH, MYF(0),
               m_cursor_spv ? m_cursor_spv->name.str : "ref cursor");
      return true;
    }
    field->set_null();
    return false;
  }

  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0),
             m_cursor_spv ? m_cursor_spv->name.str : "ref cursor");
    return true;
  }

  if (m_is_cursor) {
    c->get_push_instr()->cleanup_mem_root();
    c->cleanup_return_table_mem_root();
  }

  return c->close();
}

void sp_instr_cclose::print(const THD *, String *str) {
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);

  /* cclose name@offset */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 8;

  if (m_cursor_spv)
    rsrv += m_cursor_spv->name.length;
  else if (cursor_name)
    rsrv += cursor_name->length;

  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("cclose "), str);
  if (m_cursor_spv) {
    qs_append(m_cursor_spv->name.str, m_cursor_spv->name.length, str);
    qs_append('@', str);
    qs_append(m_cursor_spv->offset, str);
  } else if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
    qs_append(m_cursor_idx, str);
  }
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_cfetch implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cfetch::psi_info = {0, "cfetch", 0,
                                                PSI_DOCUMENT_ME};
#endif

bool sp_instr_cfetch::execute(THD *thd, uint *nextp) {
  // Manipulating a CURSOR with an expression should clear DA.
  clear_da(thd);

  *nextp = get_ip() + 1;
  if (m_cursor_spv) {
    Item_field_refcursor *item = dynamic_cast<Item_field_refcursor *>(
        thd->sp_runtime_ctx->get_item(m_cursor_spv->offset));
    Field_refcursor *field = item->get_refcursor_field();
    if (!field->m_cursor || !field->m_cursor->is_defined()) {
      my_error(ER_SP_CURSOR_MISMATCH, MYF(0),
               m_cursor_spv ? m_cursor_spv->name.str : "ref cursor");
      return true;
    }
    field->set_cursor_return_type();
    return field->m_cursor->fetch(&m_varlist);
  }
  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0),
             m_cursor_spv ? m_cursor_spv->name.str : "ref cursor");
    return true;
  }

  return c ? c->fetch(&m_varlist) : true;
}

void sp_instr_cfetch::print(const THD *, String *str) {
  List_iterator_fast<sp_variable> li(m_varlist);
  sp_variable *pv;
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);

  /* cfetch name@offset vars... */
  size_t rsrv = SP_INSTR_UINT_MAXLEN + 8;

  if (m_cursor_spv)
    rsrv += m_cursor_spv->name.length;
  else if (cursor_name)
    rsrv += cursor_name->length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("cfetch "), str);
  if (m_cursor_spv) {
    qs_append(m_cursor_spv->name.str, m_cursor_spv->name.length, str);
    qs_append('@', str);
    qs_append(m_cursor_spv->offset, str);
  } else if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
    qs_append(m_cursor_idx, str);
  }

  while ((pv = li++)) {
    if (str->reserve(pv->name.length + SP_INSTR_UINT_MAXLEN + 2)) return;
    qs_append(' ', str);
    qs_append(pv->name.str, pv->name.length, str);
    qs_append('@', str);
    qs_append(pv->offset, str);
  }
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_cfetch implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_cfetch_bulk::psi_info = {0, "cfetch", 0,
                                                     PSI_DOCUMENT_ME};
#endif

bool sp_instr_cfetch_bulk::execute(THD *thd, uint *nextp) {
  // Manipulating a CURSOR with an expression should clear DA.
  clear_da(thd);

  *nextp = get_ip() + 1;

  int count = m_row_count;
  /* m_row_count == -1 means fetch without limit n,so use
     thd->variables.select_bulk_into_batch instead.
  */
  if (m_row_count == -1) count = thd->variables.select_bulk_into_batch;
  if (m_cursor_spv) {
    Item_field_refcursor *item = dynamic_cast<Item_field_refcursor *>(
        thd->sp_runtime_ctx->get_item(m_cursor_spv->offset));
    Field_refcursor *field = item->get_refcursor_field();
    if (!field->m_cursor || !field->m_cursor->is_defined()) {
      my_error(ER_SP_CURSOR_MISMATCH, MYF(0),
               m_cursor_spv ? m_cursor_spv->name.str : "ref cursor");
      return true;
    }
    field->set_cursor_return_type();
    return field->m_cursor->fetch_bulk(&m_varlist, count);
  }

  sp_cursor *c = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  if (!c) {
    my_error(ER_SP_CURSOR_MISMATCH, MYF(0),
             m_cursor_spv ? m_cursor_spv->name.str : "ref cursor");
    return true;
  }
  thd->sp_runtime_ctx->cleanup_record_variable_row_table(
      m_varlist.head()->offset);

  return c->fetch_bulk(&m_varlist, count);
}

void sp_instr_cfetch_bulk::print(const THD *, String *str) {
  List_iterator_fast<sp_variable> li(m_varlist);
  sp_variable *pv;
  const LEX_STRING *cursor_name = m_parsing_ctx->find_cursor(m_cursor_idx);

  /* cfetch name@offset vars... */
  size_t rsrv =
      SP_INSTR_UINT_MAXLEN + 15 + std::to_string(m_row_count).length();

  if (cursor_name) rsrv += cursor_name->length;
  if (str->reserve(rsrv)) return;
  qs_append(STRING_WITH_LEN("cfetch "), str);
  if (cursor_name) {
    qs_append(cursor_name->str, cursor_name->length, str);
    qs_append('@', str);
  }
  qs_append(m_cursor_idx, str);
  while ((pv = li++)) {
    if (str->reserve(pv->name.length + SP_INSTR_UINT_MAXLEN + 2)) return;
    qs_append(' ', str);
    qs_append(pv->name.str, pv->name.length, str);
    qs_append('@', str);
    qs_append(pv->offset, str);
  }
  qs_append(STRING_WITH_LEN(" limit "), str);
  qs_append(m_row_count, str);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_error implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_error::psi_info = {0, "error", 0, PSI_DOCUMENT_ME};
#endif

void sp_instr_error::print(const THD *, String *str) {
  /* error code */
  if (str->reserve(SP_INSTR_UINT_MAXLEN + 6)) return;
  qs_append(STRING_WITH_LEN("error "), str);
  qs_append(m_errcode, str);
}

///////////////////////////////////////////////////////////////////////////
// sp_instr_set_case_expr implementation.
///////////////////////////////////////////////////////////////////////////

#ifdef HAVE_PSI_INTERFACE
PSI_statement_info sp_instr_set_case_expr::psi_info = {0, "set_case_expr", 0,
                                                       PSI_DOCUMENT_ME};
#endif

bool sp_instr_set_case_expr::exec_core(THD *thd, uint *nextp) {
  *nextp = get_ip() + 1;

  sp_rcontext *rctx = thd->sp_runtime_ctx;

  if (rctx->set_case_expr(thd, m_case_expr_id, &m_expr_item)) {
    if (!rctx->get_case_expr(m_case_expr_id)) {
      // Failed to evaluate the value, the case expression is still not
      // initialized. Set to NULL so we can continue.
      Item *null_item = new Item_null();

      if (!null_item || rctx->set_case_expr(thd, m_case_expr_id, &null_item)) {
        // If this also failed, we have to abort.
        my_error(ER_OUT_OF_RESOURCES, MYF(ME_FATALERROR));
      }
    }

    return true;
  }

  return false;
}

void sp_instr_set_case_expr::print(const THD *thd, String *str) {
  /* set_case_expr (cont) id ... */
  str->reserve(2 * SP_INSTR_UINT_MAXLEN + 18 +
               32);  // Add some extra for expr too
  qs_append(STRING_WITH_LEN("set_case_expr ("), str);
  qs_append(m_cont_dest, str);
  qs_append(STRING_WITH_LEN(") "), str);
  qs_append(m_case_expr_id, str);
  qs_append(' ', str);
  m_expr_item->print(thd, str, QT_ORDINARY);
}

uint sp_instr_set_case_expr::opt_mark(sp_head *sp, List<sp_instr> *leads) {
  m_marked = true;

  sp_instr *i = sp->get_instr(m_cont_dest);

  if (i) {
    m_cont_dest = i->opt_shortcut_jump(sp, this);
    m_cont_optdest = sp->get_instr(m_cont_dest);
  }

  sp->add_mark_lead(m_cont_dest, leads);
  return get_ip() + 1;
}

void sp_instr_set_case_expr::opt_move(uint dst, List<sp_branch_instr> *bp) {
  if (m_cont_dest > get_ip())
    bp->push_back(this);  // Forward
  else if (m_cont_optdest)
    m_cont_dest = m_cont_optdest->get_ip();  // Backward
  m_ip = dst;
}
