/*
   Copyright (c) 2000, 2022, Oracle and/or its affiliates. All rights reserved.
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

/* sql_yacc.yy */

/**
  @defgroup Parser Parser
  @{
*/

%{
/*
Note: YYTHD is passed as an argument to yyparse(), and subsequently to yylex().
*/
#define YYP (YYTHD->m_parser_state)
#define YYLIP (& YYTHD->m_parser_state->m_lip)
#define YYPS (& YYTHD->m_parser_state->m_yacc)
#define YYCSCL (YYLIP->query_charset)
#define YYMEM_ROOT (YYTHD->mem_root)
#define YYCLIENT_NO_SCHEMA (YYTHD->get_protocol()->has_client_capability(CLIENT_NO_SCHEMA))

#define YYINITDEPTH 100
#define YYMAXDEPTH 3200                        /* Because of 64K stack */
#define Lex (YYTHD->lex)
#define Select Lex->current_query_block()
#define NUMBER_MAX_PRECISION DECIMAL_MAX_PRECISION

#include <sys/types.h>  // TODO: replace with cstdint

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <type_traits>
#include <utility>

#include "field_types.h"
#include "ft_global.h"
#include "lex_string.h"
#include "libbinlogevents/include/binlog_event.h"
#include "m_ctype.h"
#include "m_string.h"
#include "my_alloc.h"
#include "my_base.h"
#include "my_check_opt.h"
#include "my_dbug.h"
#include "my_inttypes.h"  // TODO: replace with cstdint
#include "my_sqlcommand.h"
#include "my_sys.h"
#include "my_thread_local.h"
#include "my_time.h"
#include "myisam.h"
#include "myisammrg.h"
#include "mysql/mysql_lex_string.h"
#include "mysql/plugin.h"
#include "mysql/udf_registration_types.h"
#include "mysql_com.h"
#include "mysql_time.h"
#include "mysqld_error.h"
#include "prealloced_array.h"
#include "sql/auth/auth_acls.h"
#include "sql/auth/auth_common.h"
#include "sql/binlog.h"                          // for MAX_LOG_UNIQUE_FN_EXT
#include "sql/create_field.h"
#include "sql/dd/types/abstract_table.h"         // TT_BASE_TABLE
#include "sql/dd/types/column.h"
#include "sql/derror.h"
#include "sql/event_parse_data.h"
#include "sql/field.h"
#include "sql/gis/srid.h"                    // gis::srid_t
#include "sql/handler.h"
#include "sql/item.h"
#include "sql/item_cmpfunc.h"
#include "sql/item_create.h"
#include "sql/item_func.h"
#include "sql/item_geofunc.h"
#include "sql/item_json_func.h"
#include "sql/item_regexp_func.h"
#include "sql/item_row.h"
#include "sql/item_strfunc.h"
#include "sql/item_subselect.h"
#include "sql/item_sum.h"
#include "sql/item_timefunc.h"
#include "sql-common/json_dom.h"
#include "sql-common/json_syntax_check.h"           // is_valid_json_syntax
#include "sql/key_spec.h"
#include "sql/keycaches.h"
#include "sql/lex_symbol.h"
#include "sql/lex_token.h"
#include "sql/lexer_yystype.h"
#include "sql/mdl.h"
#include "sql/mem_root_array.h"
#include "sql/mysqld.h"
#include "sql/options_mysqld.h"
#include "sql/parse_location.h"
#include "sql/parse_tree_helpers.h"
#include "sql/parse_tree_nodes.h"
#include "sql/parse_tree_node_base.h"
#include "sql/parser_yystype.h"
#include "sql/partition_element.h"
#include "sql/partition_info.h"
#include "sql/protocol.h"
#include "sql/query_options.h"
#include "sql/resourcegroups/platform/thread_attrs_api.h"
#include "sql/resourcegroups/resource_group_basic_types.h"
#include "sql/rpl_filter.h"
#include "sql/rpl_replica.h"                       // Sql_cmd_change_repl_filter
#include "sql/set_var.h"
#include "sql/sp.h"
#include "sql/sp_cache.h"
#include "sql/sp_head.h"
#include "sql/sp_instr.h"
#include "sql/sp_pcontext.h"
#include "sql/spatial.h"
#include "sql/sql_admin.h"                         // Sql_cmd_analyze/Check..._table
#include "sql/sql_alter.h"                         // Sql_cmd_alter_table*
#include "sql/sql_backup_lock.h"                   // Sql_cmd_lock_instance
#include "sql/sql_class.h"      /* Key_part_spec, enum_filetype */
#include "sql/sql_cmd_srs.h"
#include "sql/sql_connect.h"
#include "sql/sql_component.h"
#include "sql/sql_error.h"
#include "sql/sql_exchange.h"
#include "sql/sql_get_diagnostics.h"               // Sql_cmd_get_diagnostics
#include "sql/sql_handler.h"                       // Sql_cmd_handler_*
#include "sql/sql_import.h"                        // Sql_cmd_import_table
#include "sql/sql_insert.h"                        // insert_into_clause_type
#include "sql/sql_lex.h"
#include "sql/sql_list.h"
#include "sql/sql_parse.h"                        /* comp_*_creator */
#include "sql/sql_plugin.h"                      // plugin_is_ready
#include "sql/sql_profile.h"
#include "sql/sql_select.h"                      // Sql_cmd_select...
#include "sql/sql_servers.h"
#include "sql/sql_signal.h"
#include "sql/sql_table.h"                        /* primary_key_name */
#include "sql/sql_tablespace.h"                  // Sql_cmd_alter_tablespace
#include "sql/sql_trigger.h"                     // Sql_cmd_create_trigger
#include "sql/sql_udf.h"
#include "sql/system_variables.h"
#include "sql/table.h"
#include "sql/table_function.h"
#include "sql/thr_malloc.h"
#include "sql/trigger_def.h"
#include "sql/window_lex.h"
#include "sql/xa/sql_cmd_xa.h"                   // Sql_cmd_xa...
#include "sql_chars.h"
#include "sql_string.h"
#include "thr_lock.h"
#include "violite.h"
#include "sql/sql_call.h"

/* this is to get the bison compilation windows warnings out */
#ifdef _MSC_VER
/* warning C4065: switch statement contains 'default' but no 'case' labels */
#pragma warning (disable : 4065)
#endif

using std::min;
using std::max;

/// The maximum number of histogram buckets.
static const int MAX_NUMBER_OF_HISTOGRAM_BUCKETS= 1024;

/// The default number of histogram buckets when the user does not specify it
/// explicitly. A value of 100 is chosen because the gain in accuracy above this
/// point seems to be generally low.
static const int DEFAULT_NUMBER_OF_HISTOGRAM_BUCKETS= 100;

int yylex(void *yylval, void *yythd);

#define yyoverflow(A,B,C,D,E,F,G,H)           \
  {                                           \
    ulong val= *(H);                          \
    if (my_yyoverflow((B), (D), (F), &val))   \
    {                                         \
      yyerror(NULL, YYTHD, NULL, (const char*) (A));\
      return 2;                               \
    }                                         \
    else                                      \
    {                                         \
      *(H)= (YYSIZE_T)val;                    \
    }                                         \
  }

#define MYSQL_YYABORT YYABORT

#define MYSQL_YYABORT_ERROR(...)              \
  do                                          \
  {                                           \
    my_error(__VA_ARGS__);                    \
    MYSQL_YYABORT;                            \
  } while(0)

#define MYSQL_YYABORT_UNLESS(A)         \
  if (!(A))                             \
  {                                     \
    YYTHD->syntax_error();              \
    MYSQL_YYABORT;                      \
  }

#define NEW_PTN new(YYMEM_ROOT)


/**
  Parse_tree_node::contextualize() function call wrapper
*/
#define CONTEXTUALIZE(x)                                \
  do                                                    \
  {                                                     \
    std::remove_reference<decltype(*x)>::type::context_t pc(YYTHD, Select); \
    if (YYTHD->is_error() ||                                            \
        (YYTHD->lex->will_contextualize && (x)->contextualize(&pc)))    \
      MYSQL_YYABORT;                                                    \
  } while(0)

#define CONTEXTUALIZE_VIEW(x)                           \
  do                                                    \
  {                                                     \
    std::remove_reference<decltype(*x)>::type::context_t pc(YYTHD, Select); \
    if (YYTHD->is_error() ||                                            \
        (YYTHD->lex->will_contextualize && (x)->contextualize(&pc)))    \
      MYSQL_YYABORT;                                                    \
    if (pc.finalize_query_expression())                                 \
      MYSQL_YYABORT;                                                    \
  } while(0)

/**
  Item::itemize() function call wrapper
*/
#define ITEMIZE(x, y)                                                   \
  do                                                                    \
  {                                                                     \
    Parse_context pc(YYTHD, Select);                                    \
    if (YYTHD->is_error() ||                                            \
        (YYTHD->lex->will_contextualize && (x)->itemize(&pc, (y))))     \
      MYSQL_YYABORT;                                                    \
  } while(0)

/**
  Parse_tree_root::make_cmd() wrapper to raise postponed error message on OOM

  @note x may be NULL because of OOM error.
*/
#define MAKE_CMD(x)                                    \
  do                                                   \
  {                                                    \
    if (YYTHD->is_error() || Lex->make_sql_cmd(x))     \
      MYSQL_YYABORT;                                   \
  } while(0)


#ifndef NDEBUG
#define YYDEBUG 1
#else
#define YYDEBUG 0
#endif


/**
  @brief Bison callback to report a syntax/OOM error

  This function is invoked by the bison-generated parser
  when a syntax error or an out-of-memory
  condition occurs, then the parser function MYSQLparse()
  returns 1 to the caller.

  This function is not invoked when the
  parser is requested to abort by semantic action code
  by means of YYABORT or YYACCEPT macros..

  This function is not for use in semantic actions and is internal to
  the parser, as it performs some pre-return cleanup.
  In semantic actions, please use syntax_error or my_error to
  push an error into the error stack and MYSQL_YYABORT
  to abort from the parser.
*/

static
void  yyerror(YYLTYPE *location, THD *thd, Parse_tree_root **, const char *s)
{
  if (strcmp(s, "syntax error") == 0) {
    thd->syntax_error_at(*location);
  } else if (strcmp(s, "memory exhausted") == 0) {
    my_error(ER_DA_OOM, MYF(0));
  } else {
    // Find omitted error messages in the generated file (sql_yacc.cc) and fix:
    assert(false);
    my_error(ER_UNKNOWN_ERROR, MYF(0));
  }
}


#ifndef NDEBUG
#define __CONCAT_UNDERSCORED(x,y)  x ## _ ## y
#define _CONCAT_UNDERSCORED(x,y)   __CONCAT_UNDERSCORED(x,y)
void _CONCAT_UNDERSCORED(turn_parser_debug_on,yyparse)()
{
  /*
     MYSQLdebug is in sql/sql_yacc.cc, in bison generated code.
     Turning this option on is **VERY** verbose, and should be
     used when investigating a syntax error problem only.

     The syntax to run with bison traces is as follows :
     - Starting a server manually :
       mysqld --debug="d,parser_debug" ...
     - Running a test :
       mysql-test-run.pl --mysqld="--debug=d,parser_debug" ...

     The result will be in the process stderr (var/log/master.err)
   */

  extern int yydebug;
  yydebug= 1;
}
#endif

static bool is_native_function(const LEX_STRING &name)
{
  if (find_native_function_builder(name) != nullptr)
    return true;

  if (is_lex_native_function(&name))
    return true;

  return false;
}

%ifdef SQL_MODE_ORACLE

/**
  In oracle mode, variable-length types in the current parsing context
  allow unspecified length. following scenario:
  - The type in stored routine parammeter
  - The return type of stored function
*/
static bool allow_type_without_len_in_sp_decl(THD *thd) {
  sp_head *sp = thd->lex->sphead;
  if (sp) {
    /**
      Use sphead->m_parser_data.m_parameter_{start|end}_ptr or 
      sphead->m_parser_data.m_cursor_parameter_{start|end}_ptr to determine
      whether the current parsing context is a parameter list
    */
    if ((sp->m_parser_data.get_parameter_start_ptr()
         && !sp->m_parser_data.get_parameter_end_ptr()) || 
         (sp->m_parser_data.get_cursor_parameter_start_ptr()
         && !sp->m_parser_data.get_cursor_parameter_end_ptr()) ) {
      return true;
    }

    /**
      If The stored program type is function, then Use sphead->m_parser_data.{m_parameter_end|m_body_start}_ptr
      to determine whether the current parsing context is the return type
    */
    if (sp->m_type != enum_sp_type::FUNCTION) {
      return false;
    }

    return (sp->m_parser_data.get_parameter_end_ptr()
            && !sp->m_parser_data.get_body_start_ptr());
  }
  return false;
}

static PT_table_reference *gen_pivot_subquery(YYLTYPE POS, THD *YYTHD,
                                              PT_table_reference *ref,
                                              PT_pivot *pivot) {
  Query_options option;
  option.query_spec_options = 0;
  PT_select_item_list *itemLs = NEW_PTN PT_select_item_list;
  Item_asterisk *as = NEW_PTN Item_asterisk(POS, nullptr, nullptr);
  if (!as || !itemLs) return nullptr;
  itemLs->push_back(as);

  Mem_root_array_YY<PT_table_reference *> table_reference_list;
  table_reference_list.init(YYMEM_ROOT);
  if (table_reference_list.push_back(ref)) return nullptr;  // OOM

  PT_query_specification *query_spec =
      NEW_PTN PT_query_specification(option,                // select_options
                                     itemLs,                // select_item_list
                                     table_reference_list,  // from
                                     nullptr, pivot);
  if (!query_spec) return nullptr;

  PT_query_expression *query_expr =
      NEW_PTN PT_query_expression(query_spec, nullptr, nullptr);
  if (!query_expr) return nullptr;

  PT_subquery *subquery = NEW_PTN PT_subquery(POS, query_expr);
  if (!subquery) return nullptr;

  const char *ptr = nullptr;
  if (pivot->table_alias()) {
    ptr = pivot->table_alias();
  } else {
    char temp_ptr[32];
    memset(temp_ptr, 0, sizeof(temp_ptr));
    Item *tmp = NEW_PTN Item_func_uuid_short(POS);
    if (unlikely(!tmp)) return nullptr;
    longlong uuid = tmp->val_int();
    sprintf(temp_ptr, "alias_temp_%lld", uuid);
    ptr = YYTHD->strmake(temp_ptr, strlen(temp_ptr));
    if (!ptr) return nullptr;
  }

  Create_col_name_list col_nam_list;
  col_nam_list.init(YYTHD->mem_root);

  return NEW_PTN PT_derived_table(false, subquery, to_lex_cstring(ptr),
                                  &col_nam_list);
}

%endif

/**
  Helper action for a case statement (entering the CASE).
  This helper is used for both 'simple' and 'searched' cases.
  This helper, with the other case_stmt_action_..., is executed when
  the following SQL code is parsed:
<pre>
CREATE PROCEDURE proc_19194_simple(i int)
BEGIN
  DECLARE str CHAR(10);

  CASE i
    WHEN 1 THEN SET str="1";
    WHEN 2 THEN SET str="2";
    WHEN 3 THEN SET str="3";
    ELSE SET str="unknown";
  END CASE;

  SELECT str;
END
</pre>
  The actions are used to generate the following code:
<pre>
SHOW PROCEDURE CODE proc_19194_simple;
Pos     Instruction
0       set str@1 NULL
1       set_case_expr (12) 0 i@0
2       jump_if_not 5(12) (case_expr@0 = 1)
3       set str@1 _latin1'1'
4       jump 12
5       jump_if_not 8(12) (case_expr@0 = 2)
6       set str@1 _latin1'2'
7       jump 12
8       jump_if_not 11(12) (case_expr@0 = 3)
9       set str@1 _latin1'3'
10      jump 12
11      set str@1 _latin1'unknown'
12      stmt 0 "SELECT str"
</pre>

  @param thd thread handler
*/

static void case_stmt_action_case(THD *thd)
{
  LEX *lex= thd->lex;
  sp_head *sp= lex->sphead;
  sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

  sp->m_parser_data.new_cont_backpatch();

  /*
    BACKPATCH: Creating target label for the jump to
    "case_stmt_action_end_case"
    (Instruction 12 in the example)
  */

  pctx->push_label(thd, EMPTY_CSTR, sp->instructions());
}

/**
  Helper action for a case then statements.
  This helper is used for both 'simple' and 'searched' cases.
  @param lex the parser lex context
*/

static bool case_stmt_action_then(THD *thd, LEX *lex)
{
  sp_head *sp= lex->sphead;
  sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

  sp_instr_jump *i =
    new (thd->mem_root) sp_instr_jump(sp->instructions(), pctx);

  if (!i || sp->add_instr(thd, i))
    return true;

  /*
    BACKPATCH: Resolving forward jump from
    "case_stmt_action_when" to "case_stmt_action_then"
    (jump_if_not from instruction 2 to 5, 5 to 8 ... in the example)
  */

  sp->m_parser_data.do_backpatch(pctx->pop_label(), sp->instructions());

  /*
    BACKPATCH: Registering forward jump from
    "case_stmt_action_then" to "case_stmt_action_end_case"
    (jump from instruction 4 to 12, 7 to 12 ... in the example)
  */

  return sp->m_parser_data.add_backpatch_entry(i, pctx->last_label());
}

/**
  Helper action for an end case.
  This helper is used for both 'simple' and 'searched' cases.
  @param lex the parser lex context
  @param simple true for simple cases, false for searched cases
*/

static void case_stmt_action_end_case(LEX *lex, bool simple)
{
  sp_head *sp= lex->sphead;
  sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

  /*
    BACKPATCH: Resolving forward jump from
    "case_stmt_action_then" to "case_stmt_action_end_case"
    (jump from instruction 4 to 12, 7 to 12 ... in the example)
  */
  sp->m_parser_data.do_backpatch(pctx->pop_label(), sp->instructions());

  if (simple)
    pctx->pop_case_expr_id();

  sp->m_parser_data.do_cont_backpatch(sp->instructions());
}


static void init_index_hints(List<Index_hint> *hints, index_hint_type type,
                             index_clause_map clause)
{
  List_iterator<Index_hint> it(*hints);
  Index_hint *hint;
  while ((hint= it++))
  {
    hint->type= type;
    hint->clause= clause;
  }
}

bool my_yyoverflow(short **a, YYSTYPE **b, YYLTYPE **c, ulong *yystacksize);

#include "sql/parse_tree_column_attrs.h"
#include "sql/parse_tree_handler.h"
#include "sql/parse_tree_items.h"
#include "sql/parse_tree_partitions.h"

static void warn_about_deprecated_national(THD *thd)
{
  if (native_strcasecmp(national_charset_info->csname, "utf8") == 0 ||
      native_strcasecmp(national_charset_info->csname, "utf8mb3") == 0)
    push_warning(thd, ER_DEPRECATED_NATIONAL);
}

static void warn_about_deprecated_binary(THD *thd)
{
  push_deprecated_warn(thd, "BINARY as attribute of a type",
  "a CHARACTER SET clause with _bin collation");
}

static bool current_timestamp_parse(const char *cpp, size_t len,
                                        bool *is_current_timestamp, bool *is_dec_appoint) {
  // strlen("CURRENT_TIMESTAMP") = 17
  *is_current_timestamp = false;
  if (len < 17) return false;

  std::string str(cpp, 17);
  if (my_strcasecmp(system_charset_info, str.c_str(), "CURRENT_TIMESTAMP") == 0) {
    *is_current_timestamp = true;
    bool has_braces = false;
    for (size_t i = 17; i < len; i++) {
      if (cpp[i] == '(') {
        has_braces = true;
        break;
      }
    }

    *is_dec_appoint = has_braces;
  }
  
  return false;
}

%}

%start start_entry

%parse-param { class THD *YYTHD }
%parse-param { class Parse_tree_root **parse_tree }

%lex-param { class THD *YYTHD }
%pure-parser                                    /* We have threads */
/*
  1. We do not accept any reduce/reduce conflicts
  2. We should not introduce new shift/reduce conflicts any more.
*/
%ifndef SQL_MODE_ORACLE

%expect 66

%else

%expect 55

%endif

/*
   MAINTAINER:

   1) Comments for TOKENS.

   For each token, please include in the same line a comment that contains
   one or more of the following tags:

   SQL-2015-N : Non Reserved keyword as per SQL-2015 draft
   SQL-2015-R : Reserved keyword as per SQL-2015 draft
   SQL-2003-R : Reserved keyword as per SQL-2003
   SQL-2003-N : Non Reserved keyword as per SQL-2003
   SQL-1999-R : Reserved keyword as per SQL-1999
   SQL-1999-N : Non Reserved keyword as per SQL-1999
   MYSQL      : MySQL extension (unspecified)
   MYSQL-FUNC : MySQL extension, function
   INTERNAL   : Not a real token, lex optimization
   OPERATOR   : SQL operator
   FUTURE-USE : Reserved for futur use

   This makes the code grep-able, and helps maintenance.

   2) About token values

   Token values are assigned by bison, in order of declaration.

   Token values are used in query DIGESTS.
   To make DIGESTS stable, it is desirable to avoid changing token values.

   In practice, this means adding new tokens at the end of the list,
   in the current release section (8.0),
   instead of adding them in the middle of the list.

   Failing to comply with instructions below will trigger build failure,
   as this process is enforced by gen_lex_token.

   3) Instructions to add a new token:

   Add the new token at the end of the list,
   in the MySQL 8.0 section.

   4) Instructions to remove an old token:

   Do not remove the token, rename it as follows:
   %token OBSOLETE_TOKEN_<NNN> / * was: TOKEN_FOO * /
   where NNN is the token value (found in sql_yacc.h)

   For example, see OBSOLETE_TOKEN_820
*/

/*
   Tokens from MySQL 5.7, keep in alphabetical order.
*/

%token  ABORT_SYM 258                     /* INTERNAL (used in lex) */
%token  ACCESSIBLE_SYM 259
%token<lexer.keyword> ACCOUNT_SYM 260
%token<lexer.keyword> ACTION 261                /* SQL-2003-N */
%token  ADD 262                           /* SQL-2003-R */
%token<lexer.keyword> ADDDATE_SYM 263           /* MYSQL-FUNC */
%token<lexer.keyword> AFTER_SYM 264             /* SQL-2003-N */
%token<lexer.keyword> AGAINST 265
%token<lexer.keyword> AGGREGATE_SYM 266
%token<lexer.keyword> ALGORITHM_SYM 267
%token  ALL 268                           /* SQL-2003-R */
%token  ALTER 269                         /* SQL-2003-R */
%token<lexer.keyword> ALWAYS_SYM 270
%token  OBSOLETE_TOKEN_271 271            /* was: ANALYSE_SYM */
%token  ANALYZE_SYM 272
%token  AND_AND_SYM 273                   /* OPERATOR */
%token  AND_SYM 274                       /* SQL-2003-R */
%token<lexer.keyword> ANY_SYM 275               /* SQL-2003-R */
%token  AS 276                            /* SQL-2003-R */
%token  ASC 277                           /* SQL-2003-N */
%token<lexer.keyword> ASCII_SYM 278             /* MYSQL-FUNC */
%token  ASENSITIVE_SYM 279                /* FUTURE-USE */
%token<lexer.keyword> AT_SYM 280                /* SQL-2003-R */
%token<lexer.keyword> AUTOEXTEND_SIZE_SYM 281
%token<lexer.keyword> AUTO_INC 282
%token<lexer.keyword> AVG_ROW_LENGTH 283
%token<lexer.keyword> AVG_SYM 284               /* SQL-2003-N */
%token<lexer.keyword> BACKUP_SYM 285
%token  BEFORE_SYM 286                    /* SQL-2003-N */
%token<lexer.keyword> BEGIN_SYM 287             /* SQL-2003-R */
%token  BETWEEN_SYM 288                   /* SQL-2003-R */
%token  BIGINT_SYM 289                    /* SQL-2003-R */
%token  BINARY_SYM 290                    /* SQL-2003-R */
%token<lexer.keyword> BINLOG_SYM 291
%token  BIN_NUM 292
%token  BIT_AND_SYM 293                   /* MYSQL-FUNC */
%token  BIT_OR_SYM 294                    /* MYSQL-FUNC */
%token<lexer.keyword> BIT_SYM 295               /* MYSQL-FUNC */
%token  BIT_XOR_SYM 296                   /* MYSQL-FUNC */
%token  BLOB_SYM 297                      /* SQL-2003-R */
%token<lexer.keyword> BLOCK_SYM 298
%token<lexer.keyword> BOOLEAN_SYM 299           /* SQL-2003-R */
%token<lexer.keyword> BOOL_SYM 300
%token  BOTH 301                          /* SQL-2003-R */
%token<lexer.keyword> BTREE_SYM 302
%token  BY 303                            /* SQL-2003-R */
%token<lexer.keyword> BYTE_SYM 304
%token<lexer.keyword> CACHE_SYM 305
%token  CALL_SYM 306                      /* SQL-2003-R */
%token  CASCADE 307                       /* SQL-2003-N */
%token<lexer.keyword> CASCADED 308              /* SQL-2003-R */
%token  CASE_SYM 309                      /* SQL-2003-R */
%token  CAST_SYM 310                      /* SQL-2003-R */
%token<lexer.keyword> CATALOG_NAME_SYM 311      /* SQL-2003-N */
%token<lexer.keyword> CHAIN_SYM 312             /* SQL-2003-N */
%token  CHANGE 313
%token<lexer.keyword> CHANGED 314
%token<lexer.keyword> CHANNEL_SYM 315
%token<lexer.keyword> CHARSET 316
%token  CHAR_SYM 317                      /* SQL-2003-R */
%token<lexer.keyword> CHECKSUM_SYM 318
%token  CHECK_SYM 319                     /* SQL-2003-R */
%token<lexer.keyword> CIPHER_SYM 320
%token<lexer.keyword> CLASS_ORIGIN_SYM 321      /* SQL-2003-N */
%token<lexer.keyword> CLIENT_SYM 322
%token<lexer.keyword> CLOSE_SYM 323             /* SQL-2003-R */
%token<lexer.keyword> COALESCE 324              /* SQL-2003-N */
%token<lexer.keyword> CODE_SYM 325
%token  COLLATE_SYM 326                   /* SQL-2003-R */
%token<lexer.keyword> COLLATION_SYM 327         /* SQL-2003-N */
%token<lexer.keyword> COLUMNS 328
%token  COLUMN_SYM 329                    /* SQL-2003-R */
%token<lexer.keyword> COLUMN_FORMAT_SYM 330
%token<lexer.keyword> COLUMN_NAME_SYM 331       /* SQL-2003-N */
%token<lexer.keyword> COMMENT_SYM 332
%token<lexer.keyword> COMMITTED_SYM 333         /* SQL-2003-N */
%token<lexer.keyword> COMMIT_SYM 334            /* SQL-2003-R */
%token<lexer.keyword> COMPACT_SYM 335
%token<lexer.keyword> COMPLETION_SYM 336
%token<lexer.keyword> COMPRESSED_SYM 337
%token<lexer.keyword> COMPRESSION_SYM 338
%token<lexer.keyword> ENCRYPTION_SYM 339
%token<lexer.keyword> CONCURRENT 340
%token  CONDITION_SYM 341                 /* SQL-2003-R, SQL-2008-R */
%token<lexer.keyword> CONNECTION_SYM 342
%token<lexer.keyword> CONSISTENT_SYM 343
%token  CONSTRAINT 344                    /* SQL-2003-R */
%token<lexer.keyword> CONSTRAINT_CATALOG_SYM 345 /* SQL-2003-N */
%token<lexer.keyword> CONSTRAINT_NAME_SYM 346   /* SQL-2003-N */
%token<lexer.keyword> CONSTRAINT_SCHEMA_SYM 347 /* SQL-2003-N */
%token<lexer.keyword> CONTAINS_SYM 348          /* SQL-2003-N */
%token<lexer.keyword> CONTEXT_SYM 349
%token  CONTINUE_SYM 350                  /* SQL-2003-R */
%token  CONVERT_SYM 351                   /* SQL-2003-N */
%token  COUNT_SYM 352                     /* SQL-2003-N */
%token<lexer.keyword> CPU_SYM 353
%token  CREATE 354                        /* SQL-2003-R */
%token  CROSS 355                         /* SQL-2003-R */
%token  CUBE_SYM 356                      /* SQL-2003-R */
%token  CURDATE 357                       /* MYSQL-FUNC */
%token<lexer.keyword> CURRENT_SYM 358           /* SQL-2003-R */
%token  CURRENT_USER 359                  /* SQL-2003-R */
%token  CURSOR_SYM 360                    /* SQL-2003-R */
%token<lexer.keyword> CURSOR_NAME_SYM 361       /* SQL-2003-N */
%token  CURTIME 362                       /* MYSQL-FUNC */
%token  DATABASE 363
%token  DATABASES 364
%token<lexer.keyword> DATAFILE_SYM 365
%token<lexer.keyword> DATA_SYM 366              /* SQL-2003-N */
%token<lexer.keyword> DATETIME_SYM 367          /* MYSQL */
%token  DATE_ADD_INTERVAL 368             /* MYSQL-FUNC */
%token  DATE_SUB_INTERVAL 369             /* MYSQL-FUNC */
%token<lexer.keyword> DATE_SYM 370              /* SQL-2003-R */
%token  DAY_HOUR_SYM 371
%token  DAY_MICROSECOND_SYM 372
%token  DAY_MINUTE_SYM 373
%token  DAY_SECOND_SYM 374
%token<lexer.keyword> DAY_SYM 375               /* SQL-2003-R */
%token<lexer.keyword> DEALLOCATE_SYM 376        /* SQL-2003-R */
%token  DECIMAL_NUM 377
%token  DECIMAL_SYM 378                   /* SQL-2003-R */
%token  DECLARE_SYM 379                   /* SQL-2003-R */
%token  DEFAULT_SYM 380                   /* SQL-2003-R */
%token<lexer.keyword> DEFAULT_AUTH_SYM 381      /* INTERNAL */
%token<lexer.keyword> DEFINER_SYM 382
%token  DELAYED_SYM 383
%token<lexer.keyword> DELAY_KEY_WRITE_SYM 384
%token  DELETE_SYM 385                    /* SQL-2003-R */
%token  DESC 386                          /* SQL-2003-N */
%token  DESCRIBE 387                      /* SQL-2003-R */
%token  OBSOLETE_TOKEN_388 388            /* was: DES_KEY_FILE */
%token  DETERMINISTIC_SYM 389             /* SQL-2003-R */
%token<lexer.keyword> DIAGNOSTICS_SYM 390       /* SQL-2003-N */
%token<lexer.keyword> DIRECTORY_SYM 391
%token<lexer.keyword> DISABLE_SYM 392
%token<lexer.keyword> DISCARD_SYM 393           /* MYSQL */
%token<lexer.keyword> DISK_SYM 394
%token  DISTINCT 395                      /* SQL-2003-R */
%token  DIV_SYM 396
%token  DOUBLE_SYM 397                    /* SQL-2003-R */
%token<lexer.keyword> DO_SYM 398
%token  DROP 399                          /* SQL-2003-R */
%token  DUAL_SYM 400
%token<lexer.keyword> DUMPFILE 401
%token<lexer.keyword> DUPLICATE_SYM 402
%token<lexer.keyword> DYNAMIC_SYM 403           /* SQL-2003-R */
%token  EACH_SYM 404                      /* SQL-2003-R */
%token  ELSE 405                          /* SQL-2003-R */
%token  ELSEIF_SYM 406
%token<lexer.keyword> ENABLE_SYM 407
%token  ENCLOSED 408
%token<lexer.keyword> END 409                   /* SQL-2003-R */
%token<lexer.keyword> ENDS_SYM 410
%token  END_OF_INPUT 411                  /* INTERNAL */
%token<lexer.keyword> ENGINES_SYM 412
%token<lexer.keyword> ENGINE_SYM 413
%token<lexer.keyword> ENUM_SYM 414              /* MYSQL */
%token  EQ 415                            /* OPERATOR */
%token  EQUAL_SYM 416                     /* OPERATOR */
%token<lexer.keyword> ERROR_SYM 417
%token<lexer.keyword> ERRORS 418
%token  ESCAPED 419
%token<lexer.keyword> ESCAPE_SYM 420            /* SQL-2003-R */
%token<lexer.keyword> EVENTS_SYM 421
%token<lexer.keyword> EVENT_SYM 422
%token<lexer.keyword> EVERY_SYM 423             /* SQL-2003-N */
%token<lexer.keyword> EXCHANGE_SYM 424
%token<lexer.keyword> EXECUTE_SYM 425           /* SQL-2003-R */
%token  EXISTS 426                        /* SQL-2003-R */
%token  EXIT_SYM 427
%token<lexer.keyword> EXPANSION_SYM 428
%token<lexer.keyword> EXPIRE_SYM 429
%token<lexer.keyword> EXPORT_SYM 430
%token<lexer.keyword> EXTENDED_SYM 431
%token<lexer.keyword> EXTENT_SIZE_SYM 432
%token  EXTRACT_SYM 433                   /* SQL-2003-N */
%token  FALSE_SYM 434                     /* SQL-2003-R */
%token<lexer.keyword> FAST_SYM 435
%token<lexer.keyword> FAULTS_SYM 436
%token  FETCH_SYM 437                     /* SQL-2003-R */
%token<lexer.keyword> FILE_SYM 438
%token<lexer.keyword> FILE_BLOCK_SIZE_SYM 439
%token<lexer.keyword> FILTER_SYM 440
%token<lexer.keyword> FIRST_SYM 441             /* SQL-2003-N */
%token<lexer.keyword> FIXED_SYM 442
%token  FLOAT_NUM 443
%token  FLOAT_SYM 444                     /* SQL-2003-R */
%token<lexer.keyword> FLUSH_SYM 445
%token<lexer.keyword> FOLLOWS_SYM 446           /* MYSQL */
%token  FORCE_SYM 447
%token  FOREIGN 448                       /* SQL-2003-R */
%token  FOR_SYM 449                       /* SQL-2003-R */
%token<lexer.keyword> FORMAT_SYM 450
%token<lexer.keyword> FOUND_SYM 451             /* SQL-2003-R */
%token  FROM 452
%token<lexer.keyword> FULL 453                  /* SQL-2003-R */
%token  FULLTEXT_SYM 454
%token  FUNCTION_SYM 455                  /* SQL-2003-R */
%token  GE 456
%token<lexer.keyword> GENERAL 457
%token  GENERATED 458
%token<lexer.keyword> GROUP_REPLICATION 459
%token<lexer.keyword> GEOMETRYCOLLECTION_SYM 460 /* MYSQL */
%token<lexer.keyword> GEOMETRY_SYM 461
%token<lexer.keyword> GET_FORMAT 462            /* MYSQL-FUNC */
%token  GET_SYM 463                       /* SQL-2003-R */
%token<lexer.keyword> GLOBAL_SYM 464            /* SQL-2003-R */
%token  GRANT 465                         /* SQL-2003-R */
%token<lexer.keyword> GRANTS 466
%token  GROUP_SYM 467                     /* SQL-2003-R */
%token  GROUP_CONCAT_SYM 468
%token  GT_SYM 469                        /* OPERATOR */
%token<lexer.keyword> HANDLER_SYM 470
%token<lexer.keyword> HASH_SYM 471
%token  HAVING 472                        /* SQL-2003-R */
%token<lexer.keyword> HELP_SYM 473
%token  HEX_NUM 474
%token  HIGH_PRIORITY 475
%token<lexer.keyword> HOST_SYM 476
%token<lexer.keyword> HOSTS_SYM 477
%token  HOUR_MICROSECOND_SYM 478
%token  HOUR_MINUTE_SYM 479
%token  HOUR_SECOND_SYM 480
%token<lexer.keyword> HOUR_SYM 481              /* SQL-2003-R */
%token  IDENT 482
%token<lexer.keyword> IDENTIFIED_SYM 483
%token  IDENT_QUOTED 484
%token  IF 485
%token  IGNORE_SYM 486
%token<lexer.keyword> IGNORE_SERVER_IDS_SYM 487
%token<lexer.keyword> IMPORT 488
%token<lexer.keyword> INDEXES 489
%token  INDEX_SYM 490
%token  INFILE_SYM 491
%token<lexer.keyword> INITIAL_SIZE_SYM 492
%token  INNER_SYM 493                     /* SQL-2003-R */
%token  INOUT_SYM 494                     /* SQL-2003-R */
%token  INSENSITIVE_SYM 495               /* SQL-2003-R */
%token  INSERT_SYM 496                    /* SQL-2003-R */
%token<lexer.keyword> INSERT_METHOD 497
%token<lexer.keyword> INSTANCE_SYM 498
%token<lexer.keyword> INSTALL_SYM 499
%token  INTERVAL_SYM 500                  /* SQL-2003-R */
%token  INTO 501                          /* SQL-2003-R */
%token  INT_SYM 502                       /* SQL-2003-R */
%token<lexer.keyword> INVOKER_SYM 503
%token  IN_SYM 504                        /* SQL-2003-R */
%token  IO_AFTER_GTIDS 505                /* MYSQL, FUTURE-USE */
%token  IO_BEFORE_GTIDS 506               /* MYSQL, FUTURE-USE */
%token<lexer.keyword> IO_SYM 507
%token<lexer.keyword> IPC_SYM 508
%token  IS 509                            /* SQL-2003-R */
%token<lexer.keyword> ISOLATION 510             /* SQL-2003-R */
%token<lexer.keyword> ISSUER_SYM 511
%token  ITERATE_SYM 512
%token  JOIN_SYM 513                      /* SQL-2003-R */
%token  JSON_SEPARATOR_SYM 514            /* MYSQL */
%token<lexer.keyword> JSON_SYM 515              /* MYSQL */
%token  KEYS 516
%token<lexer.keyword> KEY_BLOCK_SIZE 517
%token  KEY_SYM 518                       /* SQL-2003-N */
%token  KILL_SYM 519
%token<lexer.keyword> LANGUAGE_SYM 520          /* SQL-2003-R */
%token<lexer.keyword> LAST_SYM 521              /* SQL-2003-N */
%token  LE 522                            /* OPERATOR */
%token  LEADING 523                       /* SQL-2003-R */
%token<lexer.keyword> LEAVES 524
%token  LEAVE_SYM 525
%token  LEFT 526                          /* SQL-2003-R */
%token<lexer.keyword> LESS_SYM 527
%token<lexer.keyword> LEVEL_SYM 528
%token  LEX_HOSTNAME 529
%token  LIKE 530                          /* SQL-2003-R */
%token  LIMIT 531
%token  LINEAR_SYM 532
%token  LINES 533
%token<lexer.keyword> LINESTRING_SYM 534        /* MYSQL */
%token<lexer.keyword> LIST_SYM 535
%token  LOAD 536
%token<lexer.keyword> LOCAL_SYM 537             /* SQL-2003-R */
%token  OBSOLETE_TOKEN_538 538            /* was: LOCATOR_SYM */
%token<lexer.keyword> LOCKS_SYM 539
%token  LOCK_SYM 540
%token<lexer.keyword> LOGFILE_SYM 541
%token<lexer.keyword> LOGS_SYM 542
%token  LONGBLOB_SYM 543                  /* MYSQL */
%token  LONGTEXT_SYM 544                  /* MYSQL */
%token  LONG_NUM 545
%token  LONG_SYM 546
%token  LOOP_SYM 547
%token  LOW_PRIORITY 548
%token  LT 549                            /* OPERATOR */
%token<lexer.keyword> MASTER_AUTO_POSITION_SYM 550
%token  MASTER_BIND_SYM 551
%token<lexer.keyword> MASTER_CONNECT_RETRY_SYM 552
%token<lexer.keyword> MASTER_DELAY_SYM 553
%token<lexer.keyword> MASTER_HOST_SYM 554
%token<lexer.keyword> MASTER_LOG_FILE_SYM 555
%token<lexer.keyword> MASTER_LOG_POS_SYM 556
%token<lexer.keyword> MASTER_PASSWORD_SYM 557
%token<lexer.keyword> MASTER_PORT_SYM 558
%token<lexer.keyword> MASTER_RETRY_COUNT_SYM 559
/* %token<lexer.keyword> MASTER_SERVER_ID_SYM 560 */ /* UNUSED */
%token<lexer.keyword> MASTER_SSL_CAPATH_SYM 561
%token<lexer.keyword> MASTER_TLS_VERSION_SYM 562
%token<lexer.keyword> MASTER_SSL_CA_SYM 563
%token<lexer.keyword> MASTER_SSL_CERT_SYM 564
%token<lexer.keyword> MASTER_SSL_CIPHER_SYM 565
%token<lexer.keyword> MASTER_SSL_CRL_SYM 566
%token<lexer.keyword> MASTER_SSL_CRLPATH_SYM 567
%token<lexer.keyword> MASTER_SSL_KEY_SYM 568
%token<lexer.keyword> MASTER_SSL_SYM 569
%token  MASTER_SSL_VERIFY_SERVER_CERT_SYM 570
%token<lexer.keyword> MASTER_SYM 571
%token<lexer.keyword> MASTER_USER_SYM 572
%token<lexer.keyword> MASTER_HEARTBEAT_PERIOD_SYM 573
%token  MATCH 574                         /* SQL-2003-R */
%token<lexer.keyword> MAX_CONNECTIONS_PER_HOUR 575
%token<lexer.keyword> MAX_QUERIES_PER_HOUR 576
%token<lexer.keyword> MAX_ROWS 577
%token<lexer.keyword> MAX_SIZE_SYM 578
%token  MAX_SYM 579                       /* SQL-2003-N */
%token<lexer.keyword> MAX_UPDATES_PER_HOUR 580
%token<lexer.keyword> MAX_USER_CONNECTIONS_SYM 581
%token  MAX_VALUE_SYM 582                 /* SQL-2003-N */
%token  MEDIUMBLOB_SYM 583                /* MYSQL */
%token  MEDIUMINT_SYM 584                 /* MYSQL */
%token  MEDIUMTEXT_SYM 585                /* MYSQL */
%token<lexer.keyword> MEDIUM_SYM 586
%token<lexer.keyword> MEMORY_SYM 587
%token<lexer.keyword> MERGE_SYM 588             /* SQL-2003-R */
%token<lexer.keyword> MESSAGE_TEXT_SYM 589      /* SQL-2003-N */
%token<lexer.keyword> MICROSECOND_SYM 590       /* MYSQL-FUNC */
%token<lexer.keyword> MIGRATE_SYM 591
%token  MINUTE_MICROSECOND_SYM 592
%token  MINUTE_SECOND_SYM 593
%token<lexer.keyword> MINUTE_SYM 594            /* SQL-2003-R */
%token<lexer.keyword> MIN_ROWS 595
%token  MIN_SYM 596                       /* SQL-2003-N */
%token<lexer.keyword> MODE_SYM 597
%token  MODIFIES_SYM 598                  /* SQL-2003-R */
%token<lexer.keyword> MODIFY_SYM 599
%token  MOD_SYM 600                       /* SQL-2003-N */
%token<lexer.keyword> MONTH_SYM 601             /* SQL-2003-R */
%token<lexer.keyword> MULTILINESTRING_SYM 602   /* MYSQL */
%token<lexer.keyword> MULTIPOINT_SYM 603        /* MYSQL */
%token<lexer.keyword> MULTIPOLYGON_SYM 604      /* MYSQL */
%token<lexer.keyword> MUTEX_SYM 605
%token<lexer.keyword> MYSQL_ERRNO_SYM 606
%token<lexer.keyword> NAMES_SYM 607             /* SQL-2003-N */
%token<lexer.keyword> NAME_SYM 608              /* SQL-2003-N */
%token<lexer.keyword> NATIONAL_SYM 609          /* SQL-2003-R */
%token  NATURAL 610                       /* SQL-2003-R */
%token  NCHAR_STRING 611
%token<lexer.keyword> NCHAR_SYM 612             /* SQL-2003-R */
%token<lexer.keyword> NDBCLUSTER_SYM 613
%token  NE 614                            /* OPERATOR */
%token  NEG 615
%token<lexer.keyword> NEVER_SYM 616
%token<lexer.keyword> NEW_SYM 617               /* SQL-2003-R */
%token<lexer.keyword> NEXT_SYM 618              /* SQL-2003-N */
%token<lexer.keyword> NODEGROUP_SYM 619
%token<lexer.keyword> NONE_SYM 620              /* SQL-2003-R */
%token  NOT2_SYM 621
%token  NOT_SYM 622                       /* SQL-2003-R */
%token  NOW_SYM 623
%token<lexer.keyword> NO_SYM 624                /* SQL-2003-R */
%token<lexer.keyword> NO_WAIT_SYM 625
%token  NO_WRITE_TO_BINLOG 626
%token  NULL_SYM 627                      /* SQL-2003-R */
%token  NUM 628
%token<lexer.keyword> NUMBER_SYM 629            /* SQL-2003-N */
%token  NUMERIC_SYM 630                   /* SQL-2003-R */
%token<lexer.keyword> NVARCHAR_SYM 631
%token<lexer.keyword> OFFSET_SYM 632
%token  ON_SYM 633                        /* SQL-2003-R */
%token<lexer.keyword> ONE_SYM 634
%token<lexer.keyword> ONLY_SYM 635              /* SQL-2003-R */
%token<lexer.keyword> OPEN_SYM 636              /* SQL-2003-R */
%token  OPTIMIZE 637
%token  OPTIMIZER_COSTS_SYM 638
%token<lexer.keyword> OPTIONS_SYM 639
%token  OPTION 640                        /* SQL-2003-N */
%token  OPTIONALLY 641
%token  OR2_SYM 642
%token  ORDER_SYM 643                     /* SQL-2003-R */
%token  OR_OR_SYM 644                     /* OPERATOR */
%token  OR_SYM 645                        /* SQL-2003-R */
%token  OUTER_SYM 646
%token  OUTFILE 647
%token  OUT_SYM 648                       /* SQL-2003-R */
%token<lexer.keyword> OWNER_SYM 649
%token<lexer.keyword> PACK_KEYS_SYM 650
%token<lexer.keyword> PAGE_SYM 651
%token  PARAM_MARKER 652
%token<lexer.keyword> PARSER_SYM 653
%token  OBSOLETE_TOKEN_654 654            /* was: PARSE_GCOL_EXPR_SYM */
%token<lexer.keyword> PARTIAL 655                       /* SQL-2003-N */
%token  PARTITION_SYM 656                 /* SQL-2003-R */
%token<lexer.keyword> PARTITIONS_SYM 657
%token<lexer.keyword> PARTITIONING_SYM 658
%token<lexer.keyword> PASSWORD 659
%token<lexer.keyword> PHASE_SYM 660
%token<lexer.keyword> PLUGIN_DIR_SYM 661        /* INTERNAL */
%token<lexer.keyword> PLUGIN_SYM 662
%token<lexer.keyword> PLUGINS_SYM 663
%token<lexer.keyword> POINT_SYM 664
%token<lexer.keyword> POLYGON_SYM 665           /* MYSQL */
%token<lexer.keyword> PORT_SYM 666
%token  POSITION_SYM 667                  /* SQL-2003-N */
%token<lexer.keyword> PRECEDES_SYM 668          /* MYSQL */
%token  PRECISION 669                     /* SQL-2003-R */
%token<lexer.keyword> PREPARE_SYM 670           /* SQL-2003-R */
%token<lexer.keyword> PRESERVE_SYM 671
%token<lexer.keyword> PREV_SYM 672
%token  PRIMARY_SYM 673                   /* SQL-2003-R */
%token<lexer.keyword> PRIVILEGES 674            /* SQL-2003-N */
%token  PROCEDURE_SYM 675                 /* SQL-2003-R */
%token<lexer.keyword> PROCESS 676
%token<lexer.keyword> PROCESSLIST_SYM 677
%token<lexer.keyword> PROFILE_SYM 678
%token<lexer.keyword> PROFILES_SYM 679
%token<lexer.keyword> PROXY_SYM 680
%token  PURGE 681
%token<lexer.keyword> QUARTER_SYM 682
%token<lexer.keyword> QUERY_SYM 683
%token<lexer.keyword> QUICK 684
%token  RANGE_SYM 685                     /* SQL-2003-R */
%token  READS_SYM 686                     /* SQL-2003-R */
%token<lexer.keyword> READ_ONLY_SYM 687
%token  READ_SYM 688                      /* SQL-2003-N */
%token  READ_WRITE_SYM 689
%token  REAL_SYM 690                      /* SQL-2003-R */
%token<lexer.keyword> REBUILD_SYM 691
%token<lexer.keyword> RECOVER_SYM 692
%token  OBSOLETE_TOKEN_693 693            /* was: REDOFILE_SYM */
%token<lexer.keyword> REDO_BUFFER_SIZE_SYM 694
%token<lexer.keyword> REDUNDANT_SYM 695
%token  REFERENCES 696                    /* SQL-2003-R */
%token  REGEXP 697
%token<lexer.keyword> RELAY 698
%token<lexer.keyword> RELAYLOG_SYM 699
%token<lexer.keyword> RELAY_LOG_FILE_SYM 700
%token<lexer.keyword> RELAY_LOG_POS_SYM 701
%token<lexer.keyword> RELAY_THREAD 702
%token  RELEASE_SYM 703                   /* SQL-2003-R */
%token<lexer.keyword> RELOAD 704
%token<lexer.keyword> REMOVE_SYM 705
%token  RENAME 706
%token<lexer.keyword> REORGANIZE_SYM 707
%token<lexer.keyword> REPAIR 708
%token<lexer.keyword> REPEATABLE_SYM 709        /* SQL-2003-N */
%token  REPEAT_SYM 710                    /* MYSQL-FUNC */
%token  REPLACE_SYM 711                   /* MYSQL-FUNC */
%token<lexer.keyword> REPLICATION 712
%token<lexer.keyword> REPLICATE_DO_DB 713
%token<lexer.keyword> REPLICATE_IGNORE_DB 714
%token<lexer.keyword> REPLICATE_DO_TABLE 715
%token<lexer.keyword> REPLICATE_IGNORE_TABLE 716
%token<lexer.keyword> REPLICATE_WILD_DO_TABLE 717
%token<lexer.keyword> REPLICATE_WILD_IGNORE_TABLE 718
%token<lexer.keyword> REPLICATE_REWRITE_DB 719
%token  REQUIRE_SYM 720
%token<lexer.keyword> RESET_SYM 721
%token  RESIGNAL_SYM 722                  /* SQL-2003-R */
%token<lexer.keyword> RESOURCES 723
%token<lexer.keyword> RESTORE_SYM 724
%token  RESTRICT 725
%token<lexer.keyword> RESUME_SYM 726
%token<lexer.keyword> RETURNED_SQLSTATE_SYM 727 /* SQL-2003-N */
%token<lexer.keyword> RETURNS_SYM 728           /* SQL-2003-R */
%token  RETURN_SYM 729                    /* SQL-2003-R */
%token<lexer.keyword> REVERSE_SYM 730
%token  REVOKE 731                        /* SQL-2003-R */
%token  RIGHT 732                         /* SQL-2003-R */
%token<lexer.keyword> ROLLBACK_SYM 733          /* SQL-2003-R */
%token<lexer.keyword> ROLLUP_SYM 734            /* SQL-2003-R */
%token<lexer.keyword> ROTATE_SYM 735
%token<lexer.keyword> ROUTINE_SYM 736           /* SQL-2003-N */
%token  ROWS_SYM 737                      /* SQL-2003-R */
%token<lexer.keyword> ROW_FORMAT_SYM 738
%token  ROW_SYM 739                       /* SQL-2003-R */
%token<lexer.keyword> ROW_COUNT_SYM 740         /* SQL-2003-N */
%token<lexer.keyword> RTREE_SYM 741
%token<lexer.keyword> SAVEPOINT_SYM 742         /* SQL-2003-R */
%token<lexer.keyword> SCHEDULE_SYM 743
%token<lexer.keyword> SCHEMA_NAME_SYM 744       /* SQL-2003-N */
%token  SECOND_MICROSECOND_SYM 745
%token<lexer.keyword> SECOND_SYM 746            /* SQL-2003-R */
%token<lexer.keyword> SECURITY_SYM 747          /* SQL-2003-N */
%token  SELECT_SYM 748                    /* SQL-2003-R */
%token  SENSITIVE_SYM 749                 /* FUTURE-USE */
%token  SEPARATOR_SYM 750
%token<lexer.keyword> SERIALIZABLE_SYM 751      /* SQL-2003-N */
%token<lexer.keyword> SERIAL_SYM 752
%token<lexer.keyword> SESSION_SYM 753           /* SQL-2003-N */
%token<lexer.keyword> SERVER_SYM 754
%token  OBSOLETE_TOKEN_755 755            /* was: SERVER_OPTIONS */
%token  SET_SYM 756                       /* SQL-2003-R */
%token  SET_VAR 757
%token<lexer.keyword> SHARE_SYM 758
%token  SHIFT_LEFT 759                    /* OPERATOR */
%token  SHIFT_RIGHT 760                   /* OPERATOR */
%token  SHOW 761
%token<lexer.keyword> SHUTDOWN 762
%token  SIGNAL_SYM 763                    /* SQL-2003-R */
%token<lexer.keyword> SIGNED_SYM 764
%token<lexer.keyword> SIMPLE_SYM 765            /* SQL-2003-N */
%token<lexer.keyword> SLAVE 766
%token<lexer.keyword> SLOW 767
%token  SMALLINT_SYM 768                  /* SQL-2003-R */
%token<lexer.keyword> SNAPSHOT_SYM 769
%token<lexer.keyword> SOCKET_SYM 770
%token<lexer.keyword> SONAME_SYM 771
%token<lexer.keyword> SOUNDS_SYM 772
%token<lexer.keyword> SOURCE_SYM 773
%token  SPATIAL_SYM 774
%token  SPECIFIC_SYM 775                  /* SQL-2003-R */
%token  SQLEXCEPTION_SYM 776              /* SQL-2003-R */
%token  SQLSTATE_SYM 777                  /* SQL-2003-R */
%token  SQLWARNING_SYM 778                /* SQL-2003-R */
%token<lexer.keyword> SQL_AFTER_GTIDS 779       /* MYSQL */
%token<lexer.keyword> SQL_AFTER_MTS_GAPS 780    /* MYSQL */
%token<lexer.keyword> SQL_BEFORE_GTIDS 781      /* MYSQL */
%token  SQL_BIG_RESULT 782
%token<lexer.keyword> SQL_BUFFER_RESULT 783
%token  OBSOLETE_TOKEN_784 784            /* was: SQL_CACHE_SYM */
%token  SQL_CALC_FOUND_ROWS 785
%token<lexer.keyword> SQL_NO_CACHE_SYM 786
%token  SQL_SMALL_RESULT 787
%token  SQL_SYM 788                       /* SQL-2003-R */
%token<lexer.keyword> SQL_THREAD 789
%token  SSL_SYM 790
%token<lexer.keyword> STACKED_SYM 791           /* SQL-2003-N */
%token  STARTING 792
%token<lexer.keyword> STARTS_SYM 793
%token<lexer.keyword> START_SYM 794             /* SQL-2003-R */
%token<lexer.keyword> STATS_AUTO_RECALC_SYM 795
%token<lexer.keyword> STATS_PERSISTENT_SYM 796
%token<lexer.keyword> STATS_SAMPLE_PAGES_SYM 797
%token<lexer.keyword> STATUS_SYM 798
%token  STDDEV_SAMP_SYM 799               /* SQL-2003-N */
%token  STD_SYM 800
%token<lexer.keyword> STOP_SYM 801
%token<lexer.keyword> STORAGE_SYM 802
%token  STORED_SYM 803
%token  STRAIGHT_JOIN 804
%token<lexer.keyword> STRING_SYM 805
%token<lexer.keyword> SUBCLASS_ORIGIN_SYM 806   /* SQL-2003-N */
%token<lexer.keyword> SUBDATE_SYM 807
%token<lexer.keyword> SUBJECT_SYM 808
%token<lexer.keyword> SUBPARTITIONS_SYM 809
%token<lexer.keyword> SUBPARTITION_SYM 810
%token  SUBSTRING 811                     /* SQL-2003-N */
%token  SUM_SYM 812                       /* SQL-2003-N */
%token<lexer.keyword> SUPER_SYM 813
%token<lexer.keyword> SUSPEND_SYM 814
%token<lexer.keyword> SWAPS_SYM 815
%token<lexer.keyword> SWITCHES_SYM 816
%token<lexer.keyword> SYSDATE 817
%token<lexer.keyword> TABLES 818
%token<lexer.keyword> TABLESPACE_SYM 819
%token  OBSOLETE_TOKEN_820 820            /* was: TABLE_REF_PRIORITY */
%token  TABLE_SYM 821                     /* SQL-2003-R */
%token<lexer.keyword> TABLE_CHECKSUM_SYM 822
%token<lexer.keyword> TABLE_NAME_SYM 823        /* SQL-2003-N */
%token<lexer.keyword> TEMPORARY 824             /* SQL-2003-N */
%token<lexer.keyword> TEMPTABLE_SYM 825
%token  TERMINATED 826
%token  TEXT_STRING 827
%token<lexer.keyword> TEXT_SYM 828
%token<lexer.keyword> THAN_SYM 829
%token  THEN_SYM 830                      /* SQL-2003-R */
%token<lexer.keyword> TIMESTAMP_SYM 831         /* SQL-2003-R */
%token<lexer.keyword> TIMESTAMP_ADD 832
%token<lexer.keyword> TIMESTAMP_DIFF 833
%token<lexer.keyword> TIME_SYM 834              /* SQL-2003-R */
%token  TINYBLOB_SYM 835                  /* MYSQL */
%token  TINYINT_SYM 836                   /* MYSQL */
%token  TINYTEXT_SYN 837                  /* MYSQL */
%token  TO_SYM 838                        /* SQL-2003-R */
%token  TRAILING 839                      /* SQL-2003-R */
%token<lexer.keyword> TRANSACTION_SYM 840
%token<lexer.keyword> TRIGGERS_SYM 841
%token  TRIGGER_SYM 842                   /* SQL-2003-R */
%token  TRIM 843                          /* SQL-2003-N */
%token  TRUE_SYM 844                      /* SQL-2003-R */
%token<lexer.keyword> TRUNCATE_SYM 845
%token<lexer.keyword> TYPES_SYM 846
%token<lexer.keyword> TYPE_SYM 847              /* SQL-2003-N */
%token  OBSOLETE_TOKEN_848 848            /* was:  UDF_RETURNS_SYM */
%token  ULONGLONG_NUM 849
%token<lexer.keyword> UNCOMMITTED_SYM 850       /* SQL-2003-N */
%token<lexer.keyword> UNDEFINED_SYM 851
%token  UNDERSCORE_CHARSET 852
%token<lexer.keyword> UNDOFILE_SYM 853
%token<lexer.keyword> UNDO_BUFFER_SIZE_SYM 854
%token  UNDO_SYM 855                      /* FUTURE-USE */
%token<lexer.keyword> UNICODE_SYM 856
%token<lexer.keyword> UNINSTALL_SYM 857
%token  UNION_SYM 858                     /* SQL-2003-R */
%token  UNIQUE_SYM 859
%token<lexer.keyword> UNKNOWN_SYM 860           /* SQL-2003-R */
%token  UNLOCK_SYM 861
%token  UNSIGNED_SYM 862                  /* MYSQL */
%token<lexer.keyword> UNTIL_SYM 863
%token  UPDATE_SYM 864                    /* SQL-2003-R */
%token<lexer.keyword> UPGRADE_SYM 865
%token  USAGE 866                         /* SQL-2003-N */
%token<lexer.keyword> USER 867                  /* SQL-2003-R */
%token<lexer.keyword> USE_FRM 868
%token  USE_SYM 869
%token  USING 870                         /* SQL-2003-R */
%token  UTC_DATE_SYM 871
%token  UTC_TIMESTAMP_SYM 872
%token  UTC_TIME_SYM 873
%token<lexer.keyword> VALIDATION_SYM 874        /* MYSQL */
%token  VALUES 875                        /* SQL-2003-R */
%token<lexer.keyword> VALUE_SYM 876             /* SQL-2003-R */
%token  VARBINARY_SYM 877                 /* SQL-2008-R */
%token  VARCHAR_SYM 878                   /* SQL-2003-R */
%token<lexer.keyword> VARIABLES 879
%token  VARIANCE_SYM 880
%token  VARYING 881                       /* SQL-2003-R */
%token  VAR_SAMP_SYM 882
%token<lexer.keyword> VIEW_SYM 883              /* SQL-2003-N */
%token  VIRTUAL_SYM 884
%token<lexer.keyword> WAIT_SYM 885
%token<lexer.keyword> WARNINGS 886
%token<lexer.keyword> WEEK_SYM 887
%token<lexer.keyword> WEIGHT_STRING_SYM 888
%token  WHEN_SYM 889                      /* SQL-2003-R */
%token  WHERE 890                         /* SQL-2003-R */
%token  WHILE_SYM 891
%token  WITH 892                          /* SQL-2003-R */
%token  OBSOLETE_TOKEN_893 893            /* was: WITH_CUBE_SYM */
%token  WITH_ROLLUP_SYM 894               /* INTERNAL */
%token<lexer.keyword> WITHOUT_SYM 895           /* SQL-2003-R */
%token<lexer.keyword> WORK_SYM 896              /* SQL-2003-N */
%token<lexer.keyword> WRAPPER_SYM 897
%token  WRITE_SYM 898                     /* SQL-2003-N */
%token<lexer.keyword> X509_SYM 899
%token<lexer.keyword> XA_SYM 900
%token<lexer.keyword> XID_SYM 901               /* MYSQL */
%token<lexer.keyword> XML_SYM 902
%token  XOR 903
%token  YEAR_MONTH_SYM 904
%token<lexer.keyword> YEAR_SYM 905              /* SQL-2003-R */
%token  ZEROFILL_SYM 906                  /* MYSQL */

/*
   Tokens from MySQL 8.0
*/
%token  JSON_UNQUOTED_SEPARATOR_SYM 907   /* MYSQL */
%token<lexer.keyword> PERSIST_SYM 908           /* MYSQL */
%token<lexer.keyword> ROLE_SYM 909              /* SQL-1999-R */
%token<lexer.keyword> ADMIN_SYM 910             /* SQL-2003-N */
%token<lexer.keyword> INVISIBLE_SYM 911
%token<lexer.keyword> VISIBLE_SYM 912
%token  EXCEPT_SYM 913                    /* SQL-1999-R */
%token<lexer.keyword> COMPONENT_SYM 914         /* MYSQL */
%token  RECURSIVE_SYM 915                 /* SQL-1999-R */
%token  GRAMMAR_SELECTOR_EXPR 916         /* synthetic token: starts single expr. */
%token  GRAMMAR_SELECTOR_GCOL 917       /* synthetic token: starts generated col. */
%token  GRAMMAR_SELECTOR_PART 918      /* synthetic token: starts partition expr. */
%token  GRAMMAR_SELECTOR_CTE 919             /* synthetic token: starts CTE expr. */
%token  JSON_OBJECTAGG 920                /* SQL-2015-R */
%token  JSON_ARRAYAGG 921                 /* SQL-2015-R */
%token  OF_SYM 922                        /* SQL-1999-R */
%token<lexer.keyword> SKIP_SYM 923              /* MYSQL */
%token<lexer.keyword> LOCKED_SYM 924            /* MYSQL */
%token<lexer.keyword> NOWAIT_SYM 925            /* MYSQL */
%token  GROUPING_SYM 926                  /* SQL-2011-R */
%token<lexer.keyword> PERSIST_ONLY_SYM 927      /* MYSQL */
%token<lexer.keyword> HISTOGRAM_SYM 928         /* MYSQL */
%token<lexer.keyword> BUCKETS_SYM 929           /* MYSQL */
%token<lexer.keyword> OBSOLETE_TOKEN_930 930    /* was: REMOTE_SYM */
%token<lexer.keyword> CLONE_SYM 931             /* MYSQL */
%token  CUME_DIST_SYM 932                 /* SQL-2003-R */
%token  DENSE_RANK_SYM 933                /* SQL-2003-R */
%token<lexer.keyword> EXCLUDE_SYM 934           /* SQL-2003-N */
%token  FIRST_VALUE_SYM 935               /* SQL-2011-R */
%token<lexer.keyword> FOLLOWING_SYM 936         /* SQL-2003-N */
%token  GROUPS_SYM 937                    /* SQL-2011-R */
%token  LAG_SYM 938                       /* SQL-2011-R */
%token  LAST_VALUE_SYM 939                /* SQL-2011-R */
%token  LEAD_SYM 940                      /* SQL-2011-R */
%token  NTH_VALUE_SYM 941                 /* SQL-2011-R */
%token  NTILE_SYM 942                     /* SQL-2011-R */
%token<lexer.keyword> NULLS_SYM 943             /* SQL-2003-N */
%token<lexer.keyword> OTHERS_SYM 944            /* SQL-2003-N */
%token  OVER_SYM 945                      /* SQL-2003-R */
%token  PERCENT_RANK_SYM 946              /* SQL-2003-R */
%token<lexer.keyword> PRECEDING_SYM 947         /* SQL-2003-N */
%token  RANK_SYM 948                      /* SQL-2003-R */
%token<lexer.keyword> RESPECT_SYM 949           /* SQL_2011-N */
%token  ROW_NUMBER_SYM 950                /* SQL-2003-R */
%token<lexer.keyword> TIES_SYM 951              /* SQL-2003-N */
%token<lexer.keyword> UNBOUNDED_SYM 952         /* SQL-2003-N */
%token  WINDOW_SYM 953                    /* SQL-2003-R */
%token  EMPTY_SYM 954                     /* SQL-2016-R */
%token  JSON_TABLE_SYM 955                /* SQL-2016-R */
%token<lexer.keyword> NESTED_SYM 956            /* SQL-2016-N */
%token<lexer.keyword> ORDINALITY_SYM 957        /* SQL-2003-N */
%token<lexer.keyword> PATH_SYM 958              /* SQL-2003-N */
%token<lexer.keyword> HISTORY_SYM 959           /* MYSQL */
%token<lexer.keyword> REUSE_SYM 960             /* MYSQL */
%token<lexer.keyword> SRID_SYM 961              /* MYSQL */
%token<lexer.keyword> THREAD_PRIORITY_SYM 962   /* MYSQL */
%token<lexer.keyword> RESOURCE_SYM 963          /* MYSQL */
%token  SYSTEM_SYM 964                    /* SQL-2003-R */
%token<lexer.keyword> VCPU_SYM 965              /* MYSQL */
%token<lexer.keyword> MASTER_PUBLIC_KEY_PATH_SYM 966    /* MYSQL */
%token<lexer.keyword> GET_MASTER_PUBLIC_KEY_SYM 967     /* MYSQL */
%token<lexer.keyword> RESTART_SYM 968                   /* SQL-2003-N */
%token<lexer.keyword> DEFINITION_SYM 969                /* MYSQL */
%token<lexer.keyword> DESCRIPTION_SYM 970               /* MYSQL */
%token<lexer.keyword> ORGANIZATION_SYM 971              /* MYSQL */
%token<lexer.keyword> REFERENCE_SYM 972                 /* MYSQL */
%token<lexer.keyword> ACTIVE_SYM 973                    /* MYSQL */
%token<lexer.keyword> INACTIVE_SYM 974                  /* MYSQL */
%token          LATERAL_SYM 975                   /* SQL-1999-R */
%token<lexer.keyword> ARRAY_SYM 976                     /* SQL-2003-R */
%token<lexer.keyword> MEMBER_SYM 977                    /* SQL-2003-R */
%token<lexer.keyword> OPTIONAL_SYM 978                  /* MYSQL */
%token<lexer.keyword> SECONDARY_SYM 979                 /* MYSQL */
%token<lexer.keyword> SECONDARY_ENGINE_SYM 980          /* MYSQL */
%token<lexer.keyword> SECONDARY_LOAD_SYM 981            /* MYSQL */
%token<lexer.keyword> SECONDARY_UNLOAD_SYM 982          /* MYSQL */
%token<lexer.keyword> RETAIN_SYM 983                    /* MYSQL */
%token<lexer.keyword> OLD_SYM 984                       /* SQL-2003-R */
%token<lexer.keyword> ENFORCED_SYM 985                  /* SQL-2015-N */
%token<lexer.keyword> OJ_SYM 986                        /* ODBC */
%token<lexer.keyword> NETWORK_NAMESPACE_SYM 987         /* MYSQL */
%token<lexer.keyword> RANDOM_SYM 988                    /* MYSQL */
%token<lexer.keyword> MASTER_COMPRESSION_ALGORITHM_SYM 989 /* MYSQL */
%token<lexer.keyword> MASTER_ZSTD_COMPRESSION_LEVEL_SYM 990  /* MYSQL */
%token<lexer.keyword> PRIVILEGE_CHECKS_USER_SYM 991     /* MYSQL */
%token<lexer.keyword> MASTER_TLS_CIPHERSUITES_SYM 992   /* MYSQL */
%token<lexer.keyword> REQUIRE_ROW_FORMAT_SYM 993        /* MYSQL */
%token<lexer.keyword> PASSWORD_LOCK_TIME_SYM 994        /* MYSQL */
%token<lexer.keyword> FAILED_LOGIN_ATTEMPTS_SYM 995     /* MYSQL */
%token<lexer.keyword> REQUIRE_TABLE_PRIMARY_KEY_CHECK_SYM 996 /* MYSQL */
%token<lexer.keyword> STREAM_SYM 997                    /* MYSQL */
%token<lexer.keyword> OFF_SYM 998                       /* SQL-1999-R */
%token<lexer.keyword> RETURNING_SYM 999                 /* SQL-2016-N */
/*
  Here is an intentional gap in token numbers.

  Token numbers starting 1000 till YYUNDEF are occupied by:
  1. hint terminals (see sql_hints.yy),
  2. digest special internal token numbers (see gen_lex_token.cc, PART 6).

  Note: YYUNDEF in internal to Bison. Please don't change its number, or change
  it in sync with YYUNDEF in sql_hints.yy.
*/
%token YYUNDEF 1150                /* INTERNAL (for use in the lexer) */
%token<lexer.keyword> JSON_VALUE_SYM 1151               /* SQL-2016-R */
%token<lexer.keyword> TLS_SYM 1152                      /* MYSQL */
%token<lexer.keyword> ATTRIBUTE_SYM 1153                /* SQL-2003-N */

%token<lexer.keyword> ENGINE_ATTRIBUTE_SYM 1154         /* MYSQL */
%token<lexer.keyword> SECONDARY_ENGINE_ATTRIBUTE_SYM 1155 /* MYSQL */
%token<lexer.keyword> SOURCE_CONNECTION_AUTO_FAILOVER_SYM 1156 /* MYSQL */
%token<lexer.keyword> ZONE_SYM 1157                     /* SQL-2003-N */
%token<lexer.keyword> GRAMMAR_SELECTOR_DERIVED_EXPR 1158  /* synthetic token:
                                                            starts derived
                                                            table expressions. */
%token<lexer.keyword> REPLICA_SYM 1159
%token<lexer.keyword> REPLICAS_SYM 1160
%token<lexer.keyword> ASSIGN_GTIDS_TO_ANONYMOUS_TRANSACTIONS_SYM 1161      /* MYSQL */
%token<lexer.keyword> GET_SOURCE_PUBLIC_KEY_SYM 1162           /* MYSQL */
%token<lexer.keyword> SOURCE_AUTO_POSITION_SYM 1163            /* MYSQL */
%token<lexer.keyword> SOURCE_BIND_SYM 1164                     /* MYSQL */
%token<lexer.keyword> SOURCE_COMPRESSION_ALGORITHM_SYM 1165    /* MYSQL */
%token<lexer.keyword> SOURCE_CONNECT_RETRY_SYM 1166            /* MYSQL */
%token<lexer.keyword> SOURCE_DELAY_SYM 1167                    /* MYSQL */
%token<lexer.keyword> SOURCE_HEARTBEAT_PERIOD_SYM 1168         /* MYSQL */
%token<lexer.keyword> SOURCE_HOST_SYM 1169                     /* MYSQL */
%token<lexer.keyword> SOURCE_LOG_FILE_SYM 1170                 /* MYSQL */
%token<lexer.keyword> SOURCE_LOG_POS_SYM 1171                  /* MYSQL */
%token<lexer.keyword> SOURCE_PASSWORD_SYM 1172                 /* MYSQL */
%token<lexer.keyword> SOURCE_PORT_SYM 1173                     /* MYSQL */
%token<lexer.keyword> SOURCE_PUBLIC_KEY_PATH_SYM 1174          /* MYSQL */
%token<lexer.keyword> SOURCE_RETRY_COUNT_SYM 1175              /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_SYM 1176                      /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_CA_SYM 1177                   /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_CAPATH_SYM 1178               /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_CERT_SYM 1179                 /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_CIPHER_SYM 1180               /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_CRL_SYM 1181                  /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_CRLPATH_SYM 1182              /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_KEY_SYM 1183                  /* MYSQL */
%token<lexer.keyword> SOURCE_SSL_VERIFY_SERVER_CERT_SYM 1184   /* MYSQL */
%token<lexer.keyword> SOURCE_TLS_CIPHERSUITES_SYM 1185         /* MYSQL */
%token<lexer.keyword> SOURCE_TLS_VERSION_SYM 1186              /* MYSQL */
%token<lexer.keyword> SOURCE_USER_SYM 1187                     /* MYSQL */
%token<lexer.keyword> SOURCE_ZSTD_COMPRESSION_LEVEL_SYM 1188   /* MYSQL */

%token<lexer.keyword> ST_COLLECT_SYM 1189                      /* MYSQL */
%token<lexer.keyword> KEYRING_SYM 1190                         /* MYSQL */

%token<lexer.keyword> AUTHENTICATION_SYM         1191      /* MYSQL */
%token<lexer.keyword> FACTOR_SYM                 1192      /* MYSQL */
%token<lexer.keyword> FINISH_SYM                 1193      /* SQL-2016-N */
%token<lexer.keyword> INITIATE_SYM               1194      /* MYSQL */
%token<lexer.keyword> REGISTRATION_SYM           1195      /* MYSQL */
%token<lexer.keyword> UNREGISTER_SYM             1196      /* MYSQL */
%token<lexer.keyword> INITIAL_SYM                1197      /* SQL-2016-R */
%token<lexer.keyword> CHALLENGE_RESPONSE_SYM     1198      /* MYSQL */

%token<lexer.keyword> GTID_ONLY_SYM 1199                       /* MYSQL */

%token                INTERSECT_SYM              1200 /* SQL-1992-R */

%token<lexer.keyword> BULK_SYM                   1201  /* MYSQL */
%token<lexer.keyword> URL_SYM                    1202   /* MYSQL */
%token<lexer.keyword> GENERATE_SYM               1203   /* MYSQL */

/*
   Tokens from Percona Server 5.7 and older
*/
%token<lexer.keyword> CLIENT_STATS_SYM 1301
%token CLUSTERING_SYM 1302
%token<lexer.keyword> COMPRESSION_DICTIONARY_SYM 1303
%token<lexer.keyword> INDEX_STATS_SYM 1304
%token<lexer.keyword> TABLE_STATS_SYM 1305
%token<lexer.keyword> THREAD_STATS_SYM 1306
%token<lexer.keyword> USER_STATS_SYM 1307

%token<lexer.keyword> DECODE_SYM 1360

/*
   Tokens from Percona Server 8.0
*/
%token<lexer.keyword> EFFECTIVE_SYM 1350
%token  SEQUENCE_TABLE_SYM 1351

/*
   Tokens from GreatDB
*/
%token TO_NUMBER_SYM 1361
%token <lexer.keyword> DUMP_SYM 1363
%token<lexer.keyword> ADD_MONTHS_SYM 1400
%token<lexer.keyword> MONTHS_BETWEEN 1401
%token  CLOB_SYM 1402
%token PLAN_SYM 1403
%token ROWNUM_SYM 1404
%token<lexer.keyword> CHR_ORACLE_SYM 1405
%token EQ_GT_SYM 1406
%token SUBSTRB_SYM 1407
%token<lexer.keyword> EXCEPTION_SYM 1408
%token<lexer.keyword> RAISE_SYM 1409
%token<lexer.keyword> EXCEPTION_INIT 1410
%token<lexer.keyword> PRAGMA_SYM 1411
%token<lexer.keyword> ELSIF_ORACLE_SYM 1412
%token<lexer.keyword> IMMEDIATE_SYM 1413
%token LISTAGG_SYM 1414
%token WITHIN_SYM 1415
%token<lexer.keyword> ISOPEN_SYM 1416
%token<lexer.keyword> NOTFOUND_SYM 1417
%token PERCENT_ORACLE_SYM 1418
%token DOT_DOT_SYM 1419
%token<lexer.keyword> BODY_SYM 1420     /* Oracle-R */
%token MATCHED_SYM 1423
%token MERGE_INTO_SYM 1424              /* Oracle-R */
%token<lexer.keyword> CONNECT_SYM 1425
%token PRIOR_SYM 1426
%token<lexer.keyword> NO_CYCLE_SYM 1427
%token<lexer.keyword> ROWTYPE_ORACLE_SYM 1428
%token<lexer.keyword> RAISE_APPLICATION_ERROR 1429
%token SYS_GUID_SYM 1430
%token<lexer.keyword> RECORD_SYM 1431
/* 1432 is reserved, and is ready any new keyword */
/* %token<lexer.keyword> BULK_SYM 1432 */
%token<lexer.keyword> COLLECT_SYM 1433
%token<lexer.keyword> BULK_COLLECT_SYM 1434
%token<lexer.keyword> FORALL_SYM 1435
%token<lexer.keyword> BINARY_INTEGER_SYM 1436
%token<lexer.keyword> SERVEROUTPUT_SYM 1437
%token  MINUS_SYM 1438
%token WM_CONCAT_SYM 1439
%token<lexer.keyword> PERCENT_SYM 1440
%token BEGIN_WORK_SYM 1441
%token<lexer.keyword> SYSTIMESTAMP_SYM 1442
%token<lexer.keyword> OBJECT_SYM 1443
%token VARRAY_SYM 1445
%token IN_REVERSE_SYM 1446
%token<lexer.keyword> SQLCODE_SYM 1449
%token<lexer.keyword> SQLERRM_SYM 1450
%token<lexer.keyword> PRIVATE_SYM 1451
%token<lexer.keyword> ROWCOUNT_SYM 1452
%token<lexer.keyword> SYS_REFCURSOR_SYM 1453
%token<lexer.keyword> REF_SYM 1454
%token<lexer.keyword> RAW_SYM 1455
%token OBSOLETE_TOKEN_1456 1456            /* was: FOJ_SYM */
%token RATIO_TO_REPORT_SYM 1457
%token KEEP_SYM 1458
%token <lexer.keyword> MATERIALIZED_SYM 1459
%token <lexer.keyword> BUILD_SYM 1460
%token <lexer.keyword> REFRESH_SYM 1461
%token <lexer.keyword> COMPLETE_SYM 1462
%token <lexer.keyword> DEMAND_SYM 1463
%token <lexer.keyword> DEFERRED_SYM 1464
%token BUILD_IMMEDIATE_SYM 1465
%token BUILD_DEFERRED_SYM 1466
%token REFRESH_COMPLETE_SYM 1467
%token START_WITH_SYM 1468
%token CONNECT_BY_ROOT_SYM 1469
%token CONNECT_BY_ISCYCLE_SYM 1470
%token CONNECT_BY_ISLEAF_SYM 1471
%token<lexer.keyword> GOTO_SYM 1472
%token<lexer.keyword> EXTERNAL_SYM 1473
%token<lexer.keyword> LOCATION_SYM 1474

%token<lexer.keyword> SEQUENCE_SYM 1500
%token<lexer.keyword> INCREMENT_SYM 1501
%token<lexer.keyword> MIN_VALUE_SYM 1502
%token<lexer.keyword> NO_MINVALUE_SYM 1503
%token<lexer.keyword> NO_MAXVALUE_SYM 1504
%token<lexer.keyword> CYCLE_SYM 1505
%token<lexer.keyword> NO_CACHE_SYM 1506
%token<lexer.keyword> NO_ORDER_SYM 1507
%token<lexer.keyword> SEQUENCES 1508
%token<lexer.keyword> PIVOT_SYM 1509
%token<lexer.keyword> TRACK_SYM 1510
%token<lexer.keyword> START_LSN_SYM 1511
%token<lexer.keyword> INSERTING 1512
%token<lexer.keyword> UPDATING 1513
%token<lexer.keyword> DELETING 1514
%token<lexer.keyword> BASED_SYM 1515

%token<lexer.keyword> SYNONYM_SYM   1516
%token<lexer.keyword> SYNONYMS_SYM  1517
%token<lexer.keyword> PUBLIC_SYM    1518

/*
  Precedence rules used to resolve the ambiguity when using keywords as idents
  in the case e.g.:

      SELECT TIMESTAMP'...'

  vs.

      CREATE TABLE t1 ( timestamp INT );

  The use as an ident is allowed, but must never take precedence over the use
  as an actual keyword. Hence we declare the fake token KEYWORD_USED_AS_IDENT
  to have the lowest possible precedence, KEYWORD_USED_AS_KEYWORD need only be
  a bit higher. The TEXT_STRING token is added here to resolve the ambiguity
  in the above example.
*/
%left KEYWORD_USED_AS_IDENT
%nonassoc TEXT_STRING
%left KEYWORD_USED_AS_KEYWORD
%nonassoc OFFSET_SYM
%left EMPTY_INSALL_COLS
/*
  Resolve column attribute ambiguity -- force precedence of "UNIQUE KEY" against
  simple "UNIQUE" and "KEY" attributes:
*/
%right UNIQUE_SYM KEY_SYM
%right BY NO_CYCLE_SYM
%left UNION_SYM EXCEPT_SYM MINUS_SYM
%left INTERSECT_SYM
%left CONDITIONLESS_JOIN
%left   JOIN_SYM INNER_SYM CROSS STRAIGHT_JOIN NATURAL LEFT RIGHT ON_SYM USING FULL
%left   SET_VAR
%left   OR_SYM OR2_SYM
%left   XOR
%left   AND_SYM AND_AND_SYM
%left   BETWEEN_SYM CASE_SYM WHEN_SYM THEN_SYM ELSE
%left   EQ EQUAL_SYM GE GT_SYM LE LT NE IS LIKE REGEXP IN_SYM
%left   '|'
%left   '&'
%left   SHIFT_LEFT SHIFT_RIGHT
%ifdef SQL_MODE_ORACLE
%left   '-' '+'  OR_OR_SYM
%else
%left   '-' '+'
%endif
%left   '*' '/' '%' DIV_SYM MOD_SYM
%left   '^'
%ifndef SQL_MODE_ORACLE
%left   OR_OR_SYM
%endif
%left   NEG '~'
%right  NOT_SYM NOT2_SYM
%right  BINARY_SYM COLLATE_SYM
%left  INTERVAL_SYM
%left SUBQUERY_AS_EXPR PIVOT_SYM
%left '(' ')'
%left EMPTY_FROM_CLAUSE
%right INTO VALUES

%type <lexer.lex_str>
        IDENT IDENT_QUOTED TEXT_STRING DECIMAL_NUM FLOAT_NUM NUM LONG_NUM HEX_NUM
        LEX_HOSTNAME ULONGLONG_NUM select_alias ident opt_ident ident_or_text
        role_ident role_ident_or_text
        IDENT_sys TEXT_STRING_sys TEXT_STRING_literal
        NCHAR_STRING
        BIN_NUM TEXT_STRING_filesystem ident_or_empty
        TEXT_STRING_sys_nonewline TEXT_STRING_password TEXT_STRING_hash
        TEXT_STRING_validated
        filter_wild_db_table_string
        opt_constraint_name
        ts_datafile lg_undofile /*lg_redofile*/ opt_logfile_group_name opt_ts_datafile_name
        opt_describe_column
        opt_datadir_ssl opt_enable_page_track_and_start_lsn default_encryption
        lvalue_ident
        schema
        engine_or_all
        opt_binlog_in
        table_alias_ident
        persisted_variable_ident

%type <lex_cstr>
        key_cache_name
        label_ident
        opt_table_alias
        opt_with_compression_dictionary
        opt_replace_password
        sp_opt_label
        json_attribute
        opt_channel

%type <lex_str_list> TEXT_STRING_sys_list

%type <table>
        table_ident

%type <simple_string>
        opt_db

%type <string>
        text_string opt_gconcat_separator listagg_separator
        opt_listagg_separator opt_xml_rows_identified_by

%type <num>
        lock_option
        udf_type if_exists
        opt_no_write_to_binlog
        all_or_any opt_distinct
        fulltext_options union_option
        transaction_access_mode_types
        opt_natural_language_mode opt_query_expansion
        opt_ev_status opt_ev_on_completion ev_on_completion opt_ev_comment
        ev_alter_on_schedule_completion opt_ev_rename_to opt_ev_sql_stmt
        trg_action_time trg_event trg_or_event
        view_check_option
        signed_num
        opt_ignore_unknown_user
        opt_trg_status


%type <order_direction>
        ordering_direction opt_ordering_direction

%type <num>  opt_nulls_position

/*
  Bit field of MYSQL_START_TRANS_OPT_* flags.
*/
%type <num> opt_start_transaction_option_list
%type <num> start_transaction_option_list
%type <num> start_transaction_option

%type <m_yes_no_unk>
        opt_chain opt_release

%type <m_fk_option>
        delete_option

%type <ulong_num>
        ulong_num real_ulong_num merge_insert_types
        ws_num_codepoints func_datetime_precision
        now
        opt_checksum_type
        opt_ignore_lines
        opt_profile_defs
        profile_defs
        profile_def
        factor
        opt_source_count

%type <ulonglong_number>
        ulonglong_num real_ulonglong_num size_number
        option_autoextend_size

%type <lock_type>
        replace_lock_option opt_low_priority insert_lock_option load_data_lock

%type <locked_row_action> locked_row_action opt_locked_row_action
%type <ora_locked_row_action> ora_waitn_row_action

%type <item>
        literal insert_column temporal_literal
        simple_ident expr opt_expr opt_else opt_decode_expr
        set_function_specification sum_expr
        in_sum_expr grouping_operation
        window_func_call opt_ll_default
        bool_pri
        predicate bit_expr
        table_wild simple_expr udf_expr
        expr_or_default set_expr_or_default
        geometry_function
        signed_literal now_or_signed_literal
        simple_ident_nospvar simple_ident_q simple_ident_with_plus
        field_or_var limit_option
        function_call_keyword
        function_call_nonkeyword
        function_call_generic
        function_call_conflict
        signal_allowed_expr
        simple_target_specification
        condition_number
        create_compression_dictionary_allowed_expr
        filter_db_ident
        filter_table_ident
        filter_string
        select_item
        opt_where_clause
        where_clause
        opt_having_clause
        opt_simple_limit
        null_as_literal
        literal_or_null
        signed_literal_or_null
        stable_integer
        param_or_var
        in_expression_user_variable_assignment
        rvalue_system_or_user_variable
        opt_merge_where
        opt_merge_delete
        start_with_clause
        wait_ulong_num

%type <item_string> window_name opt_existing_window_name

%type <item_num> NUM_literal
        int64_literal
        sequence_signed_NUM_literal

%type <item_list>
        when_list
        opt_filter_db_list filter_db_list
        opt_filter_table_list filter_table_list
        opt_filter_string_list filter_string_list
        opt_filter_db_pair_list filter_db_pair_list
        decode_list

%type <item_list2>
        expr_list udf_expr_list opt_udf_expr_list opt_expr_list select_item_list
        opt_paren_expr_list ident_list_arg ident_list values opt_values row_value
        insert_columns
        fields_or_vars
        opt_field_or_var_spec
        row_value_explicit
        into_all_values

%type <var_type>
        option_type opt_var_type opt_rvalue_system_variable_type opt_set_var_ident_type

%type <key_type>
        constraint_key_type opt_unique_combo_clustering unique_combo_clustering

%type <key_alg>
        index_type

%type <string_list>
        string_list using_list opt_use_partition use_partition ident_string_list
        all_or_alt_part_name_list

%type <key_part>
        key_part key_part_with_expression

%type <date_time_type> date_time_type;
%type <interval> interval interval_ora

%type <interval_time_st> interval_time_stamp interval_time_stamp_ora

%type <row_type> row_types

%type <resource_group_type> resource_group_types

%type <resource_group_vcpu_list_type>
        opt_resource_group_vcpu_list
        vcpu_range_spec_list

%type <resource_group_priority_type> opt_resource_group_priority

%type <resource_group_state_type> opt_resource_group_enable_disable

%type <resource_group_flag_type> opt_force

%type <thread_id_list_type> thread_id_list thread_id_list_options

%type <vcpu_range_type> vcpu_num_or_range

%type <tx_isolation> isolation_types

%type <ha_rkey_mode> handler_rkey_mode

%type <ha_read_mode> handler_scan_function
        handler_rkey_function

%type <cast_type> cast_type opt_returning_type

%type <lexer.keyword> ident_keyword label_keyword role_keyword
        lvalue_keyword table_alias_keyword
        ident_keywords_unambiguous
        ident_keywords_ambiguous_1_roles_and_labels
        ident_keywords_ambiguous_2_labels
        ident_keywords_ambiguous_3_roles
        ident_keywords_ambiguous_4_system_variables
        ident_keywords_ambiguous_5_not_sp_variables
        ident_keywords_ambiguous_6_not_table_alias

%type <lex_user> user_ident_or_text user create_user alter_user user_func role

%type <lex_mfa>
        identification
        identified_by_password
        identified_by_random_password
        identified_with_plugin
        identified_with_plugin_as_auth
        identified_with_plugin_by_random_password
        identified_with_plugin_by_password
        opt_initial_auth
        opt_user_registration

%type <lex_mfas> opt_create_user_with_mfa

%type <lexer.charset>
        opt_collate
        charset_name
        old_or_new_charset_name
        old_or_new_charset_name_or_default
        collation_name
        opt_load_data_charset
        UNDERSCORE_CHARSET
        ascii unicode
        default_charset default_collation

%type <boolfunc2creator> comp_op

%type <sp_suid> sp_suid

%type <num>  sp_decl_idents sp_opt_inout sp_handler_type sp_hcond_list
%type <spcondvalue> sp_cond sp_hcond sqlstate signal_value opt_signal_value
%type <spname> sp_name
%type <index_hint> index_hint_type
%type <num> index_hint_clause
%type <filetype> data_or_xml
%type <source_type> load_source_type

%type <da_condition_item_name> signal_condition_information_item_name

%type <diag_area> which_area;
%type <diag_info> diagnostics_information;
%type <stmt_info_item> statement_information_item;
%type <stmt_info_item_name> statement_information_item_name;
%type <stmt_info_list> statement_information;
%type <cond_info_item> condition_information_item;
%type <cond_info_item_name> condition_information_item_name;
%type <cond_info_list> condition_information;
%type <signal_item_list> signal_information_item_list;
%type <signal_item_list> opt_set_signal_information;

%type <trg_characteristics> trigger_follows_precedes_clause;
%type <trigger_action_order_type> trigger_action_order;

%type <xid> xid;
%type <xa_option_type> opt_join_or_resume;
%type <xa_option_type> opt_suspend;
%type <xa_option_type> opt_one_phase;

%type <is_not_empty> opt_convert_xid opt_ignore opt_linear opt_bin_mod
        opt_if_not_exists opt_temporary
        opt_grant_option opt_with_admin_option
        opt_full opt_extended
        opt_ignore_leaves
        opt_local
        opt_retain_current_password
        opt_discard_old_password
        opt_constraint_enforcement
        constraint_enforcement
        opt_not
        opt_interval
        only_or_ties
        opt_source_order
        opt_load_algorithm

%type <opt_public>      opt_public

%type <show_cmd_type> opt_show_cmd_type

/*
  A bit field of SLAVE_IO, SLAVE_SQL flags.
*/
%type <num> opt_replica_thread_option_list
%type <num> replica_thread_option_list
%type <num> replica_thread_option

%type <key_usage_element> key_usage_element

%type <key_usage_list> key_usage_list opt_key_usage_list index_hint_definition
        index_hints_list opt_index_hints_list opt_key_definition
        opt_cache_key_list

%type <order_expr> order_expr alter_order_item
        grouping_expr

%type <order_list> order_list group_list gorder_list opt_gorder_clause
      alter_order_list opt_partition_clause opt_window_order_by_clause
      opt_listagg_within_group

%type <c_str> field_length opt_field_length type_datetime_precision
        opt_place

%type <precision> precision opt_precision float_options standard_float_options ora_number_float_options

%type <charset_with_opt_binary> opt_charset_with_opt_binary

%type <limit_options> limit_options offset_fetch_limit_clause

%type <limit_clause> limit_clause opt_limit_clause

%type <fetch_limit_value> opt_fetch_value

%type <ulonglong_number> query_spec_option

%type <select_options> select_option select_option_list select_options

%type <node>
          option_value

%type <join_table> joined_table joined_table_parens

%type <table_reference_list> opt_from_clause from_clause from_tables
        table_reference_list table_reference_list_parens explicit_table

%type <olap_type> olap_opt

%type <group> opt_group_clause

%type <windows> opt_window_clause  ///< Definition of named windows
                                   ///< for the query specification
                window_definition_list

%type <window> window_definition window_spec window_spec_details window_name_or_spec
  windowing_clause   ///< Definition of unnamed window near the window function.
  opt_windowing_clause ///< For functions which can be either set or window
                       ///< functions (e.g. SUM), non-empty clause makes the difference.
  opt_keep_clause keep_clause
%type <keep_dir> keep_direction

%type <window_frame> opt_window_frame_clause

%type <frame_units> window_frame_units

%type <frame_extent> window_frame_extent window_frame_between

%type <bound> window_frame_start window_frame_bound

%type <frame_exclusion> opt_window_frame_exclusion

%type <null_treatment> opt_null_treatment

%type <lead_lag_info> opt_lead_lag_info

%type <from_first_last> opt_from_first_last

%type <order> order_clause opt_order_clause

%type <locking_clause> locking_clause

%type <locking_clause_list> locking_clause_list

%type <lock_strength> lock_strength

%type <table_reference> table_reference esc_table_reference
        table_factor single_table single_table_parens table_function

%type <bipartite_name> lvalue_variable rvalue_system_variable

%type <option_value_following_option_type> option_value_following_option_type

%type <option_value_no_option_type> option_value_no_option_type

%type <option_value_list> option_value_list option_value_list_continued

%type <start_option_value_list> start_option_value_list

%type <transaction_access_mode> transaction_access_mode
        opt_transaction_access_mode

%type <isolation_level> isolation_level opt_isolation_level

%type <transaction_characteristics> transaction_characteristics

%type <start_option_value_list_following_option_type>
        start_option_value_list_following_option_type

%type <set> set

%type <line_separators> line_term line_term_list opt_line_term

%type <field_separators> field_term field_term_list opt_field_term

%type <into_destination> into_destination into_clause opt_into_clause

%type <select_var_ident> select_var_ident

%type <select_var_list> select_var_list

%type <query_expression_body_opt_parens> query_expression_body

%type <query_expression_body>
        as_create_query_expression
        query_expression_parens
        query_expression_with_opt_locking_clauses

%type <query_primary>
        query_primary
        query_specification

%type <query_expression> query_expression

%type <subquery> subquery row_subquery table_subquery

%type <derived_table> derived_table

%type <param_marker> param_marker

%type <text_literal> text_literal

%type <top_level_node>
        alter_instance_stmt
        alter_resource_group_stmt
        alter_sequence_stmt
        alter_synonym_stmt
        alter_table_stmt
        analyze_table_stmt
        call_stmt
        check_table_stmt
        create_index_stmt
        create_resource_group_stmt
        create_role_stmt
        create_sequence_stmt
        create_srs_stmt
        create_synonym_stmt
        create_table_stmt
        delete_stmt
        describe_stmt
        do_stmt
        drop_index_stmt
        drop_resource_group_stmt
        drop_role_stmt
        drop_sequence_stmt
        drop_srs_stmt
        execute_stmt
        drop_synonym_stmt
        explain_oracle_stmt
        explain_stmt
        explainable_stmt
        handler_stmt
        insert_stmt
        insert_all_stmt
        keycache_stmt
        load_stmt
        merge_stmt
        optimize_table_stmt
        preload_stmt
        repair_table_stmt
        replace_stmt
        restart_server_stmt
        select_stmt
        select_stmt_with_into
        set_resource_group_stmt
        set_role_stmt
        show_binary_logs_stmt
        show_binlog_events_stmt
        show_character_set_stmt
        show_collation_stmt
        show_columns_stmt
        show_count_errors_stmt
        show_count_warnings_stmt
        show_create_database_stmt
        show_create_event_stmt
        show_create_function_stmt
        show_create_procedure_stmt
        show_create_sequence_stmt
        show_create_synonym_stmt
        show_create_table_stmt
        show_create_trigger_stmt
        show_create_user_stmt
        show_create_view_stmt
        show_databases_stmt
        show_engine_logs_stmt
        show_engine_mutex_stmt
        show_engine_status_stmt
        show_engines_stmt
        show_errors_stmt
        show_events_stmt
        show_function_code_stmt
        show_function_status_stmt
        show_grants_stmt
        show_keys_stmt
        show_master_status_stmt
        show_open_tables_stmt
        show_plugins_stmt
        show_privileges_stmt
        show_procedure_code_stmt
        show_procedure_status_stmt
        show_processlist_stmt
        show_profile_stmt
        show_profiles_stmt
        show_relaylog_events_stmt
        show_replica_status_stmt
        show_replicas_stmt
        show_sequences_stmt
        show_stats_stmt
        show_status_stmt
        show_synonyms_stmt
        show_table_status_stmt
        show_tables_stmt
        show_triggers_stmt
        show_variables_stmt
        show_warnings_stmt
        shutdown_stmt
        simple_statement
        truncate_stmt
        update_stmt
        show_type_status_stmt

%type <table_ident> table_ident_opt_wild

%ifndef SQL_MODE_ORACLE
%type <table_ident_list> table_alias_ref_list table_locking_list
%else
%type <table_ident_list> table_alias_ref_list
%endif


%type <simple_ident_list> simple_ident_list opt_derived_column_list

%type <num> opt_delete_options

%type <opt_delete_option> opt_delete_option

%type <column_value_pair>
        update_elem

%type <column_value_list_pair>
        update_list
        opt_insert_update_list
        insert_all_into_column_value_pair

%type <merge_when_list> merge_when_list merge_when_update merge_when_insert

%type <values_list> values_list insert_values table_value_constructor
        values_row_list

%type <insert_query_expression> insert_query_expression

%type <insert_all_into_list>  insert_all_into_list
%type <insert_all_into>   cond_insert_all_into insert_all_into


%type <column_row_value_list_pair> insert_from_constructor

%type <lexer.optimizer_hints> SELECT_SYM INSERT_SYM REPLACE_SYM UPDATE_SYM DELETE_SYM
          OPTIMIZE CALL_SYM ALTER ANALYZE_SYM CHECK_SYM LOAD CREATE
          MERGE_INTO_SYM

%type <join_type> outer_join_type natural_join_type inner_join_type

%type <user_list> user_list role_list default_role_clause opt_except_role_list

%type <alter_instance_cmd> alter_instance_action

%type <index_column_list> key_list key_list_with_expression

%type <index_options> opt_index_options index_options  opt_fulltext_index_options
          fulltext_index_options opt_spatial_index_options spatial_index_options

%type <opt_index_lock_and_algorithm> opt_index_lock_and_algorithm

%type <index_option> index_option common_index_option fulltext_index_option
          spatial_index_option
          index_type_clause
          opt_index_type_clause

%type <alter_table_algorithm> alter_algorithm_option_value
        alter_algorithm_option

%type <alter_table_lock> alter_lock_option_value alter_lock_option

%type <table_constraint_def> table_constraint_def

%type <index_name_and_type> opt_index_name_and_type

%type <visibility> visibility

%type <with_clause> with_clause opt_with_clause

%type <with_list> with_list
%type <common_table_expr> common_table_expr

%type <partition_option> part_option

%type <partition_option_list> opt_part_options part_option_list

%type <sub_part_definition> sub_part_definition

%type <sub_part_list> sub_part_list opt_sub_partition

%type <part_value_item> part_value_item

%type <part_value_item_list> part_value_item_list

%type <part_value_item_list_paren> part_value_item_list_paren part_func_max

%type <part_value_list> part_value_list

%type <part_values> part_values_in

%type <opt_part_values> opt_part_values

%type <part_definition> part_definition

%type <part_def_list> part_def_list opt_part_defs

%type <ulong_num> opt_num_subparts opt_num_parts

%type <name_list> name_list opt_name_list

%type <opt_key_algo> opt_key_algo

%type <opt_sub_part> opt_sub_part

%type <part_type_def> part_type_def

%type <partition_clause> partition_clause

%type <mi_type> mi_repair_type mi_repair_types opt_mi_repair_types
        mi_check_type mi_check_types opt_mi_check_types

%type <opt_restrict> opt_restrict;

%type <table_list> table_list opt_table_list

%type <ternary_option> ternary_option;

%type <create_table_option> create_table_option opt_default_external_dir external_table_location

%type <create_table_options> create_table_options external_table_clause

%type <space_separated_alter_table_opts> create_table_options_space_separated

%type <on_duplicate> duplicate opt_duplicate

%type <col_attr> column_attribute

%type <column_format> column_format

%type <storage_media> storage_media

%type <col_attr_list> column_attribute_list opt_column_attribute_list

%type <virtual_or_stored> opt_stored_attribute

%type <field_option> field_option field_opt_list field_options

%type <int_type> int_type

%type <type> spatial_type type

%type <numeric_type> real_type numeric_type

%type <sp_default> sp_opt_default sp_opt_param_default

%type <field_def> field_def

%type <item> check_constraint

%type <table_constraint_def> opt_references

%type <fk_options> opt_on_update_delete

%type <opt_match_clause> opt_match_clause

%type <reference_list> reference_list opt_ref_list

%type <fk_references> references

%type <column_def> column_def

%type <table_element> table_element

%type <table_element_list> table_element_list

%type <create_table_tail> opt_create_table_options_etc
        opt_create_partitioning_etc opt_duplicate_as_qe

%type <wild_or_where> opt_wild_or_where

// used by JSON_TABLE
%type <jtc_list> columns_clause columns_list
%type <jt_column> jt_column
%type <json_on_response> json_on_response on_empty on_error
%type <json_on_error_or_empty> opt_on_empty_or_error
        opt_on_empty_or_error_json_table
%type <jt_column_type> jt_column_type

%type <acl_type> opt_acl_type
%type <histogram_param> opt_histogram_update_param
%type <histogram> opt_histogram

%type <lex_cstring_list> column_list opt_column_list

%type <role_or_privilege> role_or_privilege

%type <role_or_privilege_list> role_or_privilege_list

%type <with_validation> with_validation opt_with_validation
/*%type <ts_access_mode> ts_access_mode*/

%type <alter_table_action> alter_list_item alter_table_partition_options
%type <ts_options> logfile_group_option_list opt_logfile_group_options
                   alter_logfile_group_option_list opt_alter_logfile_group_options
                   tablespace_option_list opt_tablespace_options
                   alter_tablespace_option_list opt_alter_tablespace_options
                   opt_drop_ts_options drop_ts_option_list
                   undo_tablespace_option_list opt_undo_tablespace_options

%type <alter_table_standalone_action> standalone_alter_commands

%type <algo_and_lock_and_validation>alter_commands_modifier
        alter_commands_modifier_list

%type <alter_list> alter_list opt_alter_command_list opt_alter_table_actions

%type <standalone_alter_table_action> standalone_alter_table_action

%type <assign_to_keycache> assign_to_keycache

%type <keycache_list> keycache_list

%type <adm_partition> adm_partition

%type <preload_keys> preload_keys

%type <preload_list> preload_list
%type <ts_option>
        alter_logfile_group_option
        alter_tablespace_option
        drop_ts_option
        logfile_group_option
        tablespace_option
        undo_tablespace_option
        ts_option_autoextend_size
        ts_option_comment
        ts_option_engine
        ts_option_extent_size
        ts_option_file_block_size
        ts_option_initial_size
        ts_option_max_size
        ts_option_nodegroup
        ts_option_redo_buffer_size
        ts_option_undo_buffer_size
        ts_option_wait
        ts_option_encryption
        ts_option_engine_attribute

%type <explain_options_type> opt_explain_format
%type <explain_options_type> opt_explain_options

%type <load_set_element> load_data_set_elem

%type <load_set_list> load_data_set_list opt_load_data_set_spec

%type <num> opt_array_cast
%type <sql_cmd_srs_attributes> srs_attributes

%type <insert_update_values_reference> opt_values_reference

%type <alter_tablespace_type> undo_tablespace_state

%type <query_id> opt_for_query
%type <execute_using_param> opt_execute_immediate_using;

%type <connect_by> opt_connect_clause connect_by_clause
%type <num> connect_by_opt
%type <qualified_column_ident> ora_udt_ident

%ifndef SQL_MODE_ORACLE
/* types only used in default mode are declared here */
%type <spblock> sp_decls sp_decl
%else
/* types only used in oracle mode are declared here */
%type <lex_cstr> label_ident_ora ora_table_alias
%type <spname> sp_namef udt_sp_name
%type <num> opt_exceptions_ora exception_handlers_ora
            sp_instr_addr sp_proc_stmts_ora
            trg_predicate_event
%type <spcondvalue> sp_hcond_ora signal_value_ora
%type <spblock>
        opt_sp_decl_body_list
        opt_sp_decl_handler_list
        sp_decl_body_list
        sp_decl_variable_list
        sp_decl_variable_list_anchored
        sp_decl_handler_list
        sp_decl_non_handler_list
        sp_decl_handler
        sp_decl_non_handler
        exception_handler_ora
        sp_unlabeled_control_ora
%type <top_level_node> ora_set_statement
%type <set> ora_set
%type <start_option_value_list> ora_assign_value_list
%type <option_value_list> ora_value_list_continued ora_value_list
%type <option_value_no_option_type> ora_value
%type <lexer.lex_str> ora_value_ident
        opt_routine_end_name sp_decl_ident opt_open_cursor_for_stmt
%type <lexer.keyword> ora_value_keyword sp_decl_ident_keyword
%type <bipartite_name_ora> ora_internal_variable_name
%type <plsql_cursor_attr> plsql_cursor_attr
%type <oracle_sp_for_loop_bounds> sp_for_loop_bounds
%type <oracle_sp_for_loop_index_and_bounds> sp_for_loop_index_and_bounds
%type <item> explicit_cursor_attr implicit_cursor_attr opt_bulk_limit_ora
  udf_expr_record_table_row_ora pivot_sum_expr pivot_for_clause pivot_in_expr simple_ident_without_q
  opt_trigger_even_column udt_index_expr
%type <top_level_node>
        show_create_type_stmt

%type <qualified_column_ident>
        opt_qualified_column_ident

%type <qualified_column_ident_list> column_ref_list column_locking_list
%type <item_list2> opt_parenthesized_cursor_actual_parameters
      udf_expr_record_table_param_ora udf_expr_record_table_list_ora
      pivot_sum_expr_list simple_ident_without_q_list pivot_in_clause pivot_in_expr_list
%type <oracle_Row_definition_list> row_field_definition_list row_type_body
        type_pdparams type_pdparam_list
%type <oracle_create_field_decl> row_field_definition type_pdparam
%type <ora_simple_ident_def_field> ora_simple_ident
%type <ora_simple_ident_def_list> ora_simple_ident_list
%type <ora_sp_forall_loop_def> ora_sp_forall_loop
%type <insert_query_expression> insert_record_query_expression
%type <ora_locked_row_action> ora_locked_row_action ora_opt_locked_row_action
%type <sp_decl_cursor_return> sp_decl_cursor_return
%type <create_table_options> ora_opt_create_table_options
%type <udt_table_type_def> udt_table_type
%type <is_not_empty> global_private_temporary
%type <temp_table_oc> session_or_transaction
%type <type> record_index_type sp_type_ora
%type <assignment_lex> assignment_source_lex for_loop_bound_expr
%type <lex_cstr> opt_build_mv opt_refresh_mv opt_on_mv
%type <column_value_list_pair> update_list_ora
%type <pivot> opt_pivot_clause
%endif
%%

/*
  Indentation of grammar rules:

rule: <-- starts at col 1
          rule1a rule1b rule1c <-- starts at col 11
          { <-- starts at col 11
            code <-- starts at col 13, indentation is 2 spaces
          }
        | rule2a rule2b
          {
            code
          }
        ; <-- on a line by itself, starts at col 9

  Also, please do not use any <TAB>, but spaces.
  Having a uniform indentation in this file helps
  code reviews, patches, merges, and make maintenance easier.
  Tip: grep [[:cntrl:]] sql_yacc.yy
  Thanks.
*/

start_entry:
          sql_statement
        | GRAMMAR_SELECTOR_EXPR bit_expr END_OF_INPUT
          {
            ITEMIZE($2, &$2);
            static_cast<Expression_parser_state *>(YYP)->result= $2;
          }
        | GRAMMAR_SELECTOR_PART partition_clause END_OF_INPUT
          {
            /*
              We enter here when translating partition info string into
              partition_info data structure.
            */
            CONTEXTUALIZE($2);
            static_cast<Partition_expr_parser_state *>(YYP)->result=
              &$2->part_info;
          }
        | GRAMMAR_SELECTOR_GCOL IDENT_sys '(' expr ')' END_OF_INPUT
          {
            /*
              We enter here when translating generated column info string into
              partition_info data structure.
            */

            // Check gcol expression for the "PARSE_GCOL_EXPR" prefix:
            if (!is_identifier($2, "PARSE_GCOL_EXPR"))
              MYSQL_YYABORT;

            auto gcol_info= NEW_PTN Value_generator;
            if (gcol_info == NULL)
              MYSQL_YYABORT; // OOM
            ITEMIZE($4, &$4);
            gcol_info->expr_item= $4;
            static_cast<Gcol_expr_parser_state *>(YYP)->result= gcol_info;
          }
        | GRAMMAR_SELECTOR_CTE table_subquery END_OF_INPUT
          {
            static_cast<Common_table_expr_parser_state *>(YYP)->result= $2;
          }
        | GRAMMAR_SELECTOR_DERIVED_EXPR expr END_OF_INPUT
         {
           ITEMIZE($2, &$2);
           static_cast<Derived_expr_parser_state *>(YYP)->result= $2;
         }
        ;

sql_statement:
          END_OF_INPUT
          {
            THD *thd= YYTHD;
            if (!thd->is_bootstrap_system_thread() &&
                !thd->m_parser_state->has_comment())
            {
              my_error(ER_EMPTY_QUERY, MYF(0));
              MYSQL_YYABORT;
            }
            thd->lex->sql_command= SQLCOM_EMPTY_QUERY;
            YYLIP->found_semicolon= NULL;
          }
        | simple_statement_or_begin
          {
            Lex_input_stream *lip = YYLIP;

            if (YYTHD->get_protocol()->has_client_capability(CLIENT_MULTI_QUERIES) &&
                lip->multi_statements &&
                ! lip->eof())
            {
              /*
                We found a well formed query, and multi queries are allowed:
                - force the parser to stop after the ';'
                - mark the start of the next query for the next invocation
                  of the parser.
              */
              lip->next_state= MY_LEX_END;
              lip->found_semicolon= lip->get_ptr();
            }
            else
            {
              /* Single query, terminated. */
              lip->found_semicolon= NULL;
            }
          }
          ';'
          opt_end_of_input
        | simple_statement_or_begin END_OF_INPUT
          {
            /* Single query, not terminated. */
            YYLIP->found_semicolon= NULL;
          }
        ;

opt_end_of_input:
          /* empty */
        | END_OF_INPUT
        ;

simple_statement_or_begin:
          simple_statement      { *parse_tree= $1; }
        | begin_stmt
%ifdef SQL_MODE_ORACLE
        | sp_proc_stmt_compound
%endif
        ;

/* Verb clauses, except begin_stmt and sp_proc_stmt_compound */
simple_statement:
          alter_database_stmt           { $$= nullptr; }
        | alter_event_stmt              { $$= nullptr; }
        | alter_function_stmt           { $$= nullptr; }
        | alter_instance_stmt
        | alter_logfile_stmt            { $$= nullptr; }
        | alter_procedure_stmt          { $$= nullptr; }
        | alter_resource_group_stmt
        | alter_sequence_stmt
        | alter_server_stmt             { $$= nullptr; }
        | alter_tablespace_stmt         { $$= nullptr; }
        | alter_undo_tablespace_stmt    { $$= nullptr; }
        | alter_synonym_stmt
        | alter_table_stmt
        | alter_user_stmt               { $$= nullptr; }
        | alter_view_stmt               { $$= nullptr; }
        | alter_trigger_stmt            { $$= nullptr; }
        | analyze_table_stmt
        | binlog_base64_event           { $$= nullptr; }
        | call_stmt
        | change                        { $$= nullptr; }
        | check_table_stmt
        | checksum                      { $$= nullptr; }
        | clone_stmt                    { $$= nullptr; }
        | commit                        { $$= nullptr; }
        | create                        { $$= nullptr; }
        | create_index_stmt
        | create_resource_group_stmt
        | create_role_stmt
        | create_sequence_stmt
        | create_srs_stmt
        | create_synonym_stmt
        | create_table_stmt
        | deallocate                    { $$= nullptr; }
        | delete_stmt
        | describe_stmt
        | do_stmt
        | drop_database_stmt            { $$= nullptr; }
        | drop_event_stmt               { $$= nullptr; }
        | drop_function_stmt            { $$= nullptr; }
        | drop_index_stmt
        | drop_logfile_stmt             { $$= nullptr; }
        | drop_procedure_stmt           { $$= nullptr; }
%ifdef SQL_MODE_ORACLE
        | drop_type_stmt                { $$= nullptr; }
%endif
        | drop_resource_group_stmt
        | drop_role_stmt
        | drop_sequence_stmt
        | drop_server_stmt              { $$= nullptr; }
        | drop_srs_stmt
        | drop_synonym_stmt
        | drop_tablespace_stmt          { $$= nullptr; }
        | drop_undo_tablespace_stmt     { $$= nullptr; }
        | drop_table_stmt               { $$= nullptr; }
        | drop_trigger_stmt             { $$= nullptr; }
        | drop_user_stmt                { $$= nullptr; }
        | drop_view_stmt                { $$= nullptr; }
        | execute                       { $$= nullptr; }
        | execute_stmt
        | explain_stmt
        | flush                         { $$= nullptr; }
        | get_diagnostics               { $$= nullptr; }
        | group_replication             { $$= nullptr; }
        | grant                         { $$= nullptr; }
        | handler_stmt
        | help                          { $$= nullptr; }
        | import_stmt                   { $$= nullptr; }
        | insert_stmt
        | insert_all_stmt
        | install                       { $$= nullptr; }
        | kill                          { $$= nullptr; }
        | load_stmt
        | lock                          { $$= nullptr; }
        | merge_stmt
        | optimize_table_stmt
        | keycache_stmt
        | preload_stmt
        | prepare                       { $$= nullptr; }
        | purge                         { $$= nullptr; }
        | release                       { $$= nullptr; }
        | rename                        { $$= nullptr; }
        | repair_table_stmt
        | replace_stmt
        | reset                         { $$= nullptr; }
        | resignal_stmt                 { $$= nullptr; }
        | restart_server_stmt
        | revoke                        { $$= nullptr; }
        | rollback                      { $$= nullptr; }
        | savepoint                     { $$= nullptr; }
        | select_stmt
        | set                           { $$= nullptr; CONTEXTUALIZE($1); }
        | set_resource_group_stmt
        | set_role_stmt
        | show_binary_logs_stmt
        | show_binlog_events_stmt
        | show_character_set_stmt
        | show_collation_stmt
        | show_columns_stmt
        | show_count_errors_stmt
        | show_count_warnings_stmt
        | show_create_database_stmt
        | show_create_event_stmt
        | show_create_function_stmt
%ifdef SQL_MODE_ORACLE
        | show_create_type_stmt
%endif
        | show_create_procedure_stmt
        | show_create_sequence_stmt
        | show_create_synonym_stmt
        | show_create_table_stmt
        | show_create_trigger_stmt
        | show_create_user_stmt
        | show_create_view_stmt
        | show_databases_stmt
        | show_engine_logs_stmt
        | show_engine_mutex_stmt
        | show_engine_status_stmt
        | show_engines_stmt
        | show_errors_stmt
        | show_events_stmt
        | show_function_code_stmt
        | show_function_status_stmt
        | show_grants_stmt
        | show_keys_stmt
        | show_master_status_stmt
        | show_open_tables_stmt
        | show_plugins_stmt
        | show_privileges_stmt
        | show_type_status_stmt
        | show_procedure_code_stmt
        | show_procedure_status_stmt
        | show_processlist_stmt
        | show_profile_stmt
        | show_profiles_stmt
        | show_relaylog_events_stmt
        | show_replica_status_stmt
        | show_replicas_stmt
        | show_sequences_stmt
        | show_stats_stmt
        | show_status_stmt
        | show_synonyms_stmt
        | show_table_status_stmt
        | show_tables_stmt
        | show_triggers_stmt
        | show_variables_stmt
        | show_warnings_stmt
        | shutdown_stmt
        | signal_stmt                   { $$= nullptr; }
%ifdef SQL_MODE_ORACLE
        | raise_stmt                    { $$= nullptr; }
%endif
        | start                         { $$= nullptr; }
        | start_replica_stmt            { $$= nullptr; }
        | stop_replica_stmt             { $$= nullptr; }
        | truncate_stmt
        | uninstall                     { $$= nullptr; }
        | unlock                        { $$= nullptr; }
        | update_stmt
        | use                           { $$= nullptr; }
        | xa                            { $$= nullptr; }
        ;

deallocate:
          deallocate_or_drop PREPARE_SYM ident
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->sql_command= SQLCOM_DEALLOCATE_PREPARE;
            lex->prepared_stmt_name= to_lex_cstring($3);
          }
        ;

deallocate_or_drop:
          DEALLOCATE_SYM
        | DROP
        ;

prepare:
          PREPARE_SYM ident FROM prepare_src
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->sql_command= SQLCOM_PREPARE;
            lex->prepared_stmt_name= to_lex_cstring($2);
            /*
              We don't know know at this time whether there's a password
              in prepare_src, so we err on the side of caution.  Setting
              the flag will force a rewrite which will obscure all of
              prepare_src in the "Query" log line.  We'll see the actual
              query (with just the passwords obscured, if any) immediately
              afterwards in the "Prepare" log lines anyway, and then again
              in the "Execute" log line if and when prepare_src is executed.
            */
            lex->contains_plaintext_password= true;
          }
        ;

prepare_src:
          TEXT_STRING_sys
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->prepared_stmt_code= $1;
            lex->prepared_stmt_code_is_varref= false;
          }
        | '@' ident_or_text
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->prepared_stmt_code= $2;
            lex->prepared_stmt_code_is_varref= true;
          }
        ;

execute:
          EXECUTE_SYM ident
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->sql_command= SQLCOM_EXECUTE;
            lex->prepared_stmt_name= to_lex_cstring($2);
          }
          execute_using
          {}
        ;

execute_using:
          /* nothing */
        | USING execute_var_list
        ;

execute_var_list:
          execute_var_list ',' execute_var_ident
        | execute_var_ident
        ;

execute_var_ident:
          '@' ident_or_text
          {
            LEX *lex=Lex;
            LEX_STRING *lexstr= (LEX_STRING*)sql_memdup(&$2, sizeof(LEX_STRING));
            if (!lexstr || lex->prepared_stmt_params.push_back(lexstr))
              MYSQL_YYABORT;
          }
        ;

execute_stmt:
          EXECUTE_SYM IMMEDIATE_SYM expr opt_into_clause opt_execute_immediate_using
        {
          $$= NEW_PTN PT_execute($3, $4, $5.mode, $5.param_list);
        }
        ;


opt_into_clause:
          /* empty */
          {
            $$= nullptr;
          }
        | into_clause
        ;

opt_execute_immediate_using:
          /* empty */
        {
          $$.mode= sp_variable::MODE_IN;
          $$.param_list= nullptr;
        }
        | USING expr_list
        {
          $$.mode= sp_variable::MODE_IN;
          $$.param_list= $2;
        }
        | USING IN_SYM expr_list
        {
          $$.mode= sp_variable::MODE_IN;
          $$.param_list= $3;
        }
        | USING OUT_SYM expr_list
        {
          $$.mode= sp_variable::MODE_OUT;
          $$.param_list= $3;
        }
        | USING IN_SYM OUT_SYM expr_list
        {
          $$.mode= sp_variable::MODE_INOUT;
          $$.param_list= $4;
        }
        ;

/* help */

help:
          HELP_SYM
          {
            if (Lex->sphead)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), "HELP");
              MYSQL_YYABORT;
            }
          }
          ident_or_text
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_HELP;
            lex->help_arg= $3.str;
          }
        ;

/* change master */

change_replication_source:
          MASTER_SYM
          {
            push_deprecated_warn(YYTHD, "CHANGE MASTER",
                                        "CHANGE REPLICATION SOURCE");
          }
        | REPLICATION SOURCE_SYM
        ;

change:
          CHANGE change_replication_source TO_SYM
          {
            LEX *lex = Lex;
            lex->sql_command = SQLCOM_CHANGE_MASTER;
            /*
              Clear LEX_MASTER_INFO struct. repl_ignore_server_ids is cleared
              in THD::cleanup_after_query. So it is guaranteed to be empty here.
            */
            assert(Lex->mi.repl_ignore_server_ids.empty());
            lex->mi.set_unspecified();
          }
          source_defs opt_channel
          {
            if (Lex->set_channel_name($6))
              MYSQL_YYABORT;  // OOM
          }
        | CHANGE REPLICATION FILTER_SYM
          {
            THD *thd= YYTHD;
            LEX* lex= thd->lex;
            assert(!lex->m_sql_cmd);
            lex->sql_command = SQLCOM_CHANGE_REPLICATION_FILTER;
            lex->m_sql_cmd= NEW_PTN Sql_cmd_change_repl_filter();
            if (lex->m_sql_cmd == NULL)
              MYSQL_YYABORT;
          }
          filter_defs opt_channel
          {
            if (Lex->set_channel_name($6))
              MYSQL_YYABORT;  // OOM
          }
        ;

filter_defs:
          filter_def
        | filter_defs ',' filter_def
        ;
filter_def:
          REPLICATE_DO_DB EQ opt_filter_db_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
            filter_sql_cmd->set_filter_value($3, OPT_REPLICATE_DO_DB);
          }
        | REPLICATE_IGNORE_DB EQ opt_filter_db_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
            filter_sql_cmd->set_filter_value($3, OPT_REPLICATE_IGNORE_DB);
          }
        | REPLICATE_DO_TABLE EQ opt_filter_table_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
           filter_sql_cmd->set_filter_value($3, OPT_REPLICATE_DO_TABLE);
          }
        | REPLICATE_IGNORE_TABLE EQ opt_filter_table_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
            filter_sql_cmd->set_filter_value($3, OPT_REPLICATE_IGNORE_TABLE);
          }
        | REPLICATE_WILD_DO_TABLE EQ opt_filter_string_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
            filter_sql_cmd->set_filter_value($3, OPT_REPLICATE_WILD_DO_TABLE);
          }
        | REPLICATE_WILD_IGNORE_TABLE EQ opt_filter_string_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
            filter_sql_cmd->set_filter_value($3,
                                             OPT_REPLICATE_WILD_IGNORE_TABLE);
          }
        | REPLICATE_REWRITE_DB EQ opt_filter_db_pair_list
          {
            Sql_cmd_change_repl_filter * filter_sql_cmd=
              (Sql_cmd_change_repl_filter*) Lex->m_sql_cmd;
            assert(filter_sql_cmd);
            filter_sql_cmd->set_filter_value($3, OPT_REPLICATE_REWRITE_DB);
          }
        ;
opt_filter_db_list:
          '(' ')'
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | '(' filter_db_list ')'
          {
            $$= $2;
          }
        ;

filter_db_list:
          filter_db_ident
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        | filter_db_list ',' filter_db_ident
          {
            $1->push_back($3);
            $$= $1;
          }
        ;

filter_db_ident:
          ident /* DB name */
          {
            THD *thd= YYTHD;
            Item *db_item= NEW_PTN Item_string($1.str, $1.length,
                                               thd->charset());
            $$= db_item;
          }
        ;
opt_filter_db_pair_list:
          '(' ')'
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        |'(' filter_db_pair_list ')'
          {
            $$= $2;
          }
        ;
filter_db_pair_list:
          '(' filter_db_ident ',' filter_db_ident ')'
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($2);
            $$->push_back($4);
          }
        | filter_db_pair_list ',' '(' filter_db_ident ',' filter_db_ident ')'
          {
            $1->push_back($4);
            $1->push_back($6);
            $$= $1;
          }
        ;
opt_filter_table_list:
          '(' ')'
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        |'(' filter_table_list ')'
          {
            $$= $2;
          }
        ;

filter_table_list:
          filter_table_ident
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        | filter_table_list ',' filter_table_ident
          {
            $1->push_back($3);
            $$= $1;
          }
        ;

filter_table_ident:
          schema '.' ident /* qualified table name */
          {
            THD *thd= YYTHD;
            Item_string *table_item= NEW_PTN Item_string($1.str, $1.length,
                                                         thd->charset());
            table_item->append(thd->strmake(".", 1), 1);
            table_item->append($3.str, $3.length);
            $$= table_item;
          }
        ;

opt_filter_string_list:
          '(' ')'
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        |'(' filter_string_list ')'
          {
            $$= $2;
          }
        ;

filter_string_list:
          filter_string
          {
            $$= NEW_PTN mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        | filter_string_list ',' filter_string
          {
            $1->push_back($3);
            $$= $1;
          }
        ;

filter_string:
          filter_wild_db_table_string
          {
            THD *thd= YYTHD;
            Item *string_item= NEW_PTN Item_string($1.str, $1.length,
                                                   thd->charset());
            $$= string_item;
          }
        ;

source_defs:
          source_def
        | source_defs ',' source_def
        ;

change_replication_source_auto_position:
          MASTER_AUTO_POSITION_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_AUTO_POSITION",
                                        "SOURCE_AUTO_POSITION");

          }
        | SOURCE_AUTO_POSITION_SYM
        ;

change_replication_source_host:
          MASTER_HOST_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_HOST",
                                        "SOURCE_HOST");
          }
        | SOURCE_HOST_SYM
        ;

change_replication_source_bind:
          MASTER_BIND_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_BIND",
                                        "SOURCE_BIND");

          }
        | SOURCE_BIND_SYM
        ;

change_replication_source_user:
          MASTER_USER_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_USER",
                                        "SOURCE_USER");
          }
        | SOURCE_USER_SYM
        ;

change_replication_source_password:
          MASTER_PASSWORD_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_PASSWORD",
                                        "SOURCE_PASSWORD");
          }
        | SOURCE_PASSWORD_SYM
        ;

change_replication_source_port:
          MASTER_PORT_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_PORT",
                                        "SOURCE_PORT");
          }
        | SOURCE_PORT_SYM
        ;

change_replication_source_connect_retry:
          MASTER_CONNECT_RETRY_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_CONNECT_RETRY",
                                        "SOURCE_CONNECT_RETRY");
          }
        | SOURCE_CONNECT_RETRY_SYM
        ;

change_replication_source_retry_count:
          MASTER_RETRY_COUNT_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_RETRY_COUNT",
                                        "SOURCE_RETRY_COUNT");
          }
        | SOURCE_RETRY_COUNT_SYM
        ;

change_replication_source_delay:
          MASTER_DELAY_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_DELAY",
                                        "SOURCE_DELAY");
          }
        | SOURCE_DELAY_SYM
        ;

change_replication_source_ssl:
          MASTER_SSL_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL",
                                        "SOURCE_SSL");
          }
        | SOURCE_SSL_SYM
        ;

change_replication_source_ssl_ca:
          MASTER_SSL_CA_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_CA",
                                        "SOURCE_SSL_CA");
          }
        | SOURCE_SSL_CA_SYM
        ;

change_replication_source_ssl_capath:
          MASTER_SSL_CAPATH_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_CAPATH",
                                        "SOURCE_SSL_CAPATH");
          }
        | SOURCE_SSL_CAPATH_SYM
        ;

change_replication_source_ssl_cipher:
          MASTER_SSL_CIPHER_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_CIPHER",
                                        "SOURCE_SSL_CIPHER");
          }
        | SOURCE_SSL_CIPHER_SYM
        ;

change_replication_source_ssl_crl:
          MASTER_SSL_CRL_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_CRL",
                                        "SOURCE_SSL_CRL");
          }
        | SOURCE_SSL_CRL_SYM
        ;

change_replication_source_ssl_crlpath:
          MASTER_SSL_CRLPATH_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_CRLPATH",
                                        "SOURCE_SSL_CRLPATH");
          }
        | SOURCE_SSL_CRLPATH_SYM
        ;

change_replication_source_ssl_key:
          MASTER_SSL_KEY_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_KEY",
                                        "SOURCE_SSL_KEY");
          }
        | SOURCE_SSL_KEY_SYM
        ;

change_replication_source_ssl_verify_server_cert:
          MASTER_SSL_VERIFY_SERVER_CERT_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_VERIFY_SERVER_CERT",
                                        "SOURCE_SSL_VERIFY_SERVER_CERT");
          }
        | SOURCE_SSL_VERIFY_SERVER_CERT_SYM
        ;

change_replication_source_tls_version:
          MASTER_TLS_VERSION_SYM
          {
             push_deprecated_warn(YYTHD, "MASTER_TLS_VERSION",
                                         "SOURCE_TLS_VERSION");
          }
        | SOURCE_TLS_VERSION_SYM
        ;

change_replication_source_tls_ciphersuites:
          MASTER_TLS_CIPHERSUITES_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_TLS_CIPHERSUITES",
                                        "SOURCE_TLS_CIPHERSUITES");
          }
        | SOURCE_TLS_CIPHERSUITES_SYM
        ;

change_replication_source_ssl_cert:
          MASTER_SSL_CERT_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_SSL_CERT",
                                        "SOURCE_SSL_CERT");
          }
        | SOURCE_SSL_CERT_SYM
        ;

change_replication_source_public_key:
          MASTER_PUBLIC_KEY_PATH_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_PUBLIC_KEY_PATH",
                                        "SOURCE_PUBLIC_KEY_PATH");
          }
        | SOURCE_PUBLIC_KEY_PATH_SYM
        ;

change_replication_source_get_source_public_key:
          GET_MASTER_PUBLIC_KEY_SYM
          {
            push_deprecated_warn(YYTHD, "GET_MASTER_PUBLIC_KEY",
                                        "GET_SOURCE_PUBLIC_KEY");
          }
        | GET_SOURCE_PUBLIC_KEY_SYM
        ;

change_replication_source_heartbeat_period:
          MASTER_HEARTBEAT_PERIOD_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_HEARTBEAT_PERIOD",
                                        "SOURCE_HEARTBEAT_PERIOD");
          }
        | SOURCE_HEARTBEAT_PERIOD_SYM
        ;

change_replication_source_compression_algorithm:
          MASTER_COMPRESSION_ALGORITHM_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_COMPRESSION_ALGORITHM",
                                        "SOURCE_COMPRESSION_ALGORITHM");
          }
        | SOURCE_COMPRESSION_ALGORITHM_SYM
        ;

change_replication_source_zstd_compression_level:
          MASTER_ZSTD_COMPRESSION_LEVEL_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_ZSTD_COMPRESSION_LEVEL",
                                        "SOURCE_ZSTD_COMPRESSION_LEVEL");
          }
        | SOURCE_ZSTD_COMPRESSION_LEVEL_SYM
        ;

source_def:
          change_replication_source_host EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.host = $3.str;
          }
        | NETWORK_NAMESPACE_SYM EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.network_namespace = $3.str;
          }
        | change_replication_source_bind EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.bind_addr = $3.str;
          }
        | change_replication_source_user EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.user = $3.str;
          }
        | change_replication_source_password EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.password = $3.str;
            if (strlen($3.str) > 32)
            {
              my_error(ER_CHANGE_MASTER_PASSWORD_LENGTH, MYF(0));
              MYSQL_YYABORT;
            }
            Lex->contains_plaintext_password= true;
          }
        | change_replication_source_port EQ ulong_num
          {
            Lex->mi.port = $3;
          }
        | change_replication_source_connect_retry EQ ulong_num
          {
            Lex->mi.connect_retry = $3;
          }
        | change_replication_source_retry_count EQ ulong_num
          {
            Lex->mi.retry_count= $3;
            Lex->mi.retry_count_opt= LEX_MASTER_INFO::LEX_MI_ENABLE;
          }
        | change_replication_source_delay EQ ulong_num
          {
            if ($3 > MASTER_DELAY_MAX)
            {
              const char *msg= YYTHD->strmake(@3.cpp.start, @3.cpp.end - @3.cpp.start);
              my_error(ER_MASTER_DELAY_VALUE_OUT_OF_RANGE, MYF(0),
                       msg, MASTER_DELAY_MAX);
            }
            else
              Lex->mi.sql_delay = $3;
          }
        | change_replication_source_ssl EQ ulong_num
          {
            Lex->mi.ssl= $3 ?
              LEX_MASTER_INFO::LEX_MI_ENABLE : LEX_MASTER_INFO::LEX_MI_DISABLE;
          }
        | change_replication_source_ssl_ca EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_ca= $3.str;
          }
        | change_replication_source_ssl_capath EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_capath= $3.str;
          }
        | change_replication_source_tls_version EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.tls_version= $3.str;
          }
        | change_replication_source_tls_ciphersuites EQ source_tls_ciphersuites_def
        | change_replication_source_ssl_cert EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_cert= $3.str;
          }
        | change_replication_source_ssl_cipher EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_cipher= $3.str;
          }
        | change_replication_source_ssl_key EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_key= $3.str;
          }
        | change_replication_source_ssl_verify_server_cert EQ ulong_num
          {
            Lex->mi.ssl_verify_server_cert= $3 ?
              LEX_MASTER_INFO::LEX_MI_ENABLE : LEX_MASTER_INFO::LEX_MI_DISABLE;
          }
        | change_replication_source_ssl_crl EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_crl= $3.str;
          }
        | change_replication_source_ssl_crlpath EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.ssl_crlpath= $3.str;
          }
        | change_replication_source_public_key EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.public_key_path= $3.str;
          }
        | change_replication_source_get_source_public_key EQ ulong_num
          {
            Lex->mi.get_public_key= $3 ?
              LEX_MASTER_INFO::LEX_MI_ENABLE :
              LEX_MASTER_INFO::LEX_MI_DISABLE;
          }
        | change_replication_source_heartbeat_period EQ NUM_literal
          {
            Item *num= $3;
            ITEMIZE(num, &num);

            Lex->mi.heartbeat_period= (float) num->val_real();
            if (Lex->mi.heartbeat_period > SLAVE_MAX_HEARTBEAT_PERIOD ||
                Lex->mi.heartbeat_period < 0.0)
            {
               const char format[]= "%d";
               char buf[4*sizeof(SLAVE_MAX_HEARTBEAT_PERIOD) + sizeof(format)];
               sprintf(buf, format, SLAVE_MAX_HEARTBEAT_PERIOD);
               my_error(ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE, MYF(0), buf);
               MYSQL_YYABORT;
            }
            if (Lex->mi.heartbeat_period > replica_net_timeout)
            {
              push_warning(YYTHD, Sql_condition::SL_WARNING,
                           ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MAX,
                           ER_THD(YYTHD, ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MAX));
            }
            if (Lex->mi.heartbeat_period < 0.001)
            {
              if (Lex->mi.heartbeat_period != 0.0)
              {
                push_warning(YYTHD, Sql_condition::SL_WARNING,
                             ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MIN,
                             ER_THD(YYTHD, ER_SLAVE_HEARTBEAT_VALUE_OUT_OF_RANGE_MIN));
                Lex->mi.heartbeat_period= 0.0;
              }
              Lex->mi.heartbeat_opt=  LEX_MASTER_INFO::LEX_MI_DISABLE;
            }
            Lex->mi.heartbeat_opt=  LEX_MASTER_INFO::LEX_MI_ENABLE;
          }
        | IGNORE_SERVER_IDS_SYM EQ '(' ignore_server_id_list ')'
          {
            Lex->mi.repl_ignore_server_ids_opt= LEX_MASTER_INFO::LEX_MI_ENABLE;
           }
        | change_replication_source_compression_algorithm EQ TEXT_STRING_sys
          {
            Lex->mi.compression_algorithm = $3.str;
           }
        | change_replication_source_zstd_compression_level EQ ulong_num
          {
            Lex->mi.zstd_compression_level = $3;
           }
        | change_replication_source_auto_position EQ ulong_num
          {
            Lex->mi.auto_position= $3 ?
              LEX_MASTER_INFO::LEX_MI_ENABLE :
              LEX_MASTER_INFO::LEX_MI_DISABLE;
          }
        | PRIVILEGE_CHECKS_USER_SYM EQ privilege_check_def
        | REQUIRE_ROW_FORMAT_SYM EQ ulong_num
          {
            switch($3) {
            case 0:
                Lex->mi.require_row_format =
                  LEX_MASTER_INFO::LEX_MI_DISABLE;
                break;
            case 1:
                Lex->mi.require_row_format =
                  LEX_MASTER_INFO::LEX_MI_ENABLE;
                break;
            default:
              const char* wrong_value = YYTHD->strmake(@3.raw.start, @3.raw.length());
              my_error(ER_REQUIRE_ROW_FORMAT_INVALID_VALUE, MYF(0), wrong_value);
            }
          }
        | REQUIRE_TABLE_PRIMARY_KEY_CHECK_SYM EQ table_primary_key_check_def
        | SOURCE_CONNECTION_AUTO_FAILOVER_SYM EQ real_ulong_num
          {
            switch($3) {
            case 0:
                Lex->mi.m_source_connection_auto_failover =
                  LEX_MASTER_INFO::LEX_MI_DISABLE;
                break;
            case 1:
                Lex->mi.m_source_connection_auto_failover =
                  LEX_MASTER_INFO::LEX_MI_ENABLE;
                break;
            default:
                YYTHD->syntax_error_at(@3);
                MYSQL_YYABORT;
            }
          }
        | ASSIGN_GTIDS_TO_ANONYMOUS_TRANSACTIONS_SYM EQ assign_gtids_to_anonymous_transactions_def
        | GTID_ONLY_SYM EQ real_ulong_num
          {
            switch($3) {
            case 0:
                Lex->mi.m_gtid_only =
                  LEX_MASTER_INFO::LEX_MI_DISABLE;
                break;
            case 1:
                Lex->mi.m_gtid_only =
                  LEX_MASTER_INFO::LEX_MI_ENABLE;
                break;
            default:
                YYTHD->syntax_error_at(@3,
                  "You have an error in your CHANGE REPLICATION SOURCE syntax; GTID_ONLY only accepts values 0 or 1");
                MYSQL_YYABORT;
            }
          }
        | source_file_def
        ;

ignore_server_id_list:
          /* Empty */
          | ignore_server_id
          | ignore_server_id_list ',' ignore_server_id
        ;

ignore_server_id:
          ulong_num
          {
            Lex->mi.repl_ignore_server_ids.push_back($1);
          }

privilege_check_def:
          user_ident_or_text
          {
            Lex->mi.privilege_checks_none= false;
            Lex->mi.privilege_checks_username= $1->user.str;
            Lex->mi.privilege_checks_hostname= $1->host.str;
          }
        | NULL_SYM
          {
            Lex->mi.privilege_checks_none= true;
            Lex->mi.privilege_checks_username= NULL;
            Lex->mi.privilege_checks_hostname= NULL;
          }
        ;

table_primary_key_check_def:
          STREAM_SYM
          {
            Lex->mi.require_table_primary_key_check= LEX_MASTER_INFO::LEX_MI_PK_CHECK_STREAM;
          }
        | ON_SYM
          {
            Lex->mi.require_table_primary_key_check= LEX_MASTER_INFO::LEX_MI_PK_CHECK_ON;
          }
        | OFF_SYM
          {
            Lex->mi.require_table_primary_key_check= LEX_MASTER_INFO::LEX_MI_PK_CHECK_OFF;
          }
        | GENERATE_SYM
          {
            Lex->mi.require_table_primary_key_check= LEX_MASTER_INFO::LEX_MI_PK_CHECK_GENERATE;
          }
        ;

assign_gtids_to_anonymous_transactions_def:
          OFF_SYM
          {
            Lex->mi.assign_gtids_to_anonymous_transactions_type = LEX_MASTER_INFO::LEX_MI_ANONYMOUS_TO_GTID_OFF;
          }
        | LOCAL_SYM
          {
            Lex->mi.assign_gtids_to_anonymous_transactions_type = LEX_MASTER_INFO::LEX_MI_ANONYMOUS_TO_GTID_LOCAL;
          }
        | TEXT_STRING
          {
            Lex->mi.assign_gtids_to_anonymous_transactions_type = LEX_MASTER_INFO::LEX_MI_ANONYMOUS_TO_GTID_UUID;
            Lex->mi.assign_gtids_to_anonymous_transactions_manual_uuid = $1.str;
            if (!binary_log::Uuid::is_valid($1.str, binary_log::Uuid::TEXT_LENGTH))
            {
              my_error(ER_WRONG_VALUE, MYF(0), "UUID", $1.str);
              MYSQL_YYABORT;
            }
          }
        ;


source_tls_ciphersuites_def:
          TEXT_STRING_sys_nonewline
          {
            Lex->mi.tls_ciphersuites = LEX_MASTER_INFO::SPECIFIED_STRING;
            Lex->mi.tls_ciphersuites_string= $1.str;
          }
        | NULL_SYM
          {
            Lex->mi.tls_ciphersuites = LEX_MASTER_INFO::SPECIFIED_NULL;
            Lex->mi.tls_ciphersuites_string = NULL;
          }
        ;

source_log_file:
          MASTER_LOG_FILE_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_LOG_FILE",
                                        "SOURCE_LOG_FILE");
          }
        | SOURCE_LOG_FILE_SYM
        ;

source_log_pos:
          MASTER_LOG_POS_SYM
          {
            push_deprecated_warn(YYTHD, "MASTER_LOG_POS",
                                        "SOURCE_LOG_POS");
          }
        | SOURCE_LOG_POS_SYM
        ;

source_file_def:
          source_log_file EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.log_file_name = $3.str;
          }
        | source_log_pos EQ ulonglong_num
          {
            Lex->mi.pos = $3;
            /*
               If the user specified a value < BIN_LOG_HEADER_SIZE, adjust it
               instead of causing subsequent errors.
               We need to do it in this file, because only there we know that
               MASTER_LOG_POS has been explicitely specified. On the contrary
               in change_master() (sql_repl.cc) we cannot distinguish between 0
               (MASTER_LOG_POS explicitely specified as 0) and 0 (unspecified),
               whereas we want to distinguish (specified 0 means "read the binlog
               from 0" (4 in fact), unspecified means "don't change the position
               (keep the preceding value)").
            */
            Lex->mi.pos = max<ulonglong>(BIN_LOG_HEADER_SIZE, Lex->mi.pos);
          }
        | RELAY_LOG_FILE_SYM EQ TEXT_STRING_sys_nonewline
          {
            Lex->mi.relay_log_name = $3.str;
          }
        | RELAY_LOG_POS_SYM EQ ulong_num
          {
            Lex->mi.relay_log_pos = $3;
            /* Adjust if < BIN_LOG_HEADER_SIZE (same comment as Lex->mi.pos) */
            Lex->mi.relay_log_pos = max<ulong>(BIN_LOG_HEADER_SIZE,
                                               Lex->mi.relay_log_pos);
          }
        ;

opt_channel:
          /*empty */
          { $$ = {}; }
        | FOR_SYM CHANNEL_SYM TEXT_STRING_sys_nonewline
          { $$ = to_lex_cstring($3); }
        ;

%ifdef SQL_MODE_ORACLE
opt_build_mv:
          BUILD_IMMEDIATE_SYM { $$ = to_lex_cstring("BUILD IMMEDIATE "); } 
        | BUILD_DEFERRED_SYM  { $$ = to_lex_cstring("BUILD DEFERRED "); } 
        ;

opt_refresh_mv:
          REFRESH_COMPLETE_SYM { $$ = to_lex_cstring("REFRESH COMPLETE "); } 
        ;

opt_on_mv:
          ON_SYM DEMAND_SYM { $$ = to_lex_cstring("ON DEMAND "); }
        ;
%endif

create_synonym_stmt:
          CREATE or_replace opt_public
          SYNONYM_SYM table_ident
          FOR_SYM table_ident
          {
            $$= NEW_PTN PT_create_synonym_stmt($5 /* synonym_ident */,
                                               true /* or_replace */,
                                               $3 /* is_public */,
                                               $7 /* target_ident */);
          }
          |CREATE opt_public SYNONYM_SYM table_ident FOR_SYM table_ident
          {
            $$= NEW_PTN PT_create_synonym_stmt($4 /* synonym_ident */,
                                               false /* or_replace */,
                                               $2 /* is_public */,
                                               $6 /* target_ident */);
          }
        ;

opt_public:
          /* empty */ { $$= false; }
        | PUBLIC_SYM  { $$= true; }
        ;

create_table_stmt:
          CREATE opt_temporary TABLE_SYM opt_if_not_exists table_ident
          '(' table_element_list ')' opt_create_table_options_etc
          {
            $$= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, $2, $4, $5,
                                             $7,
                                             $9.opt_create_table_options,
                                             $9.opt_partitioning,
                                             $9.on_duplicate,
                                             $9.opt_query_expression);
          }
        | CREATE opt_temporary TABLE_SYM opt_if_not_exists table_ident
          opt_create_table_options_etc
          {
            $$= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, $2, $4, $5,
                                             NULL,
                                             $6.opt_create_table_options,
                                             $6.opt_partitioning,
                                             $6.on_duplicate,
                                             $6.opt_query_expression);
          }
        | CREATE opt_temporary TABLE_SYM opt_if_not_exists table_ident
          LIKE table_ident
          {
            $$= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, $2, $4, $5, $7);
          }
        | CREATE opt_temporary TABLE_SYM opt_if_not_exists table_ident
          '(' LIKE table_ident ')'
          {
            $$= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, $2, $4, $5, $8);
          }
%ifdef SQL_MODE_ORACLE
        | CREATE opt_temporary TABLE_SYM opt_if_not_exists table_ident
          OF_SYM ora_udt_ident ora_opt_create_table_options
          {
            if($2) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),"create temporary table of.");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, $2, $4, $5, nullptr, $7,
              $8);
          }
        | CREATE global_private_temporary TABLE_SYM opt_if_not_exists
          table_ident '(' table_element_list ')' session_or_transaction
          ora_opt_create_table_options
          {
            PT_create_table_stmt *rv;
            rv= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, !$2, $4, $5,
                                             $7,
                                             $10,
                                             nullptr,  // opt_partitioning
                                             On_duplicate::ERROR,
                                             nullptr); // opt_query_expression
            // check for global/private, session/transaction, table-name
            if (rv->invalid_ora_temp_table_param($2, $9, $5->table.str)) {
              MYSQL_YYABORT;
            }
            $$= rv;
          }
        | CREATE MATERIALIZED_SYM VIEW_SYM  table_ident opt_derived_column_list opt_build_mv opt_refresh_mv opt_on_mv
          opt_create_table_options_etc 
          {

            THD *thd= YYTHD;
            LEX *lex= Lex;
            lex->set_is_materialized_view(true);
            String tmp;

            if ($5.size()){
              tmp.append('(');
              uint i=1;
              for (auto column_alias : $5)
              {
                // Report error if the column name/length is incorrect.
                if (check_column_name(column_alias.str))
                {
                  my_error(ER_WRONG_COLUMN_NAME, MYF(0), column_alias.str);
                  MYSQL_YYABORT;
                }
                tmp.append(column_alias.str,column_alias.length);
                if ( i < $5.size())
                 tmp.append(',');
                i++;
              }
              tmp.append(')');
            }
            tmp.append(' ');
            tmp.append('&');
            tmp.append($6.str, $6.length);
            tmp.append('&');
            tmp.append($7.str, $7.length);
            tmp.append('&');
            tmp.append($8.str, $8.length);
            tmp.append('\0');

            lex->create_materialized_view_info.str=
              static_cast<char *>(thd->memdup(tmp.ptr(), tmp.length()));
            lex->create_materialized_view_info.length= tmp.length();

            $$= NEW_PTN PT_create_table_stmt(YYMEM_ROOT, $1, false, false, $4,
                                             NULL,
                                             $9.opt_create_table_options,
                                             $9.opt_partitioning,
                                             $9.on_duplicate,
                                             $9.opt_query_expression,
                                             &$5);
           }

%endif
        ;

%ifdef SQL_MODE_ORACLE
ora_opt_create_table_options:
          /* empty */
          {
            $$= nullptr;
          }
        | create_table_options
          {
            $$= $1;
          }
        ;

global_private_temporary:
          GLOBAL_SYM TEMPORARY   { $$= true; }
        | PRIVATE_SYM TEMPORARY   { $$= false; }
        ;

session_or_transaction:
          /* empty */ { $$= temp_table_oc_param::TEMP_TABLE_OC_DEFAULT; }
        | ON_SYM COMMIT_SYM DROP DEFINITION_SYM
          { $$= temp_table_oc_param::TEMP_TABLE_OC_DROP_DEF; }  // default
        | ON_SYM COMMIT_SYM PRESERVE_SYM DEFINITION_SYM
          { $$= temp_table_oc_param::TEMP_TABLE_OC_PRESERVE_DEF; }
        | ON_SYM COMMIT_SYM DELETE_SYM ROWS_SYM
          { $$= temp_table_oc_param::TEMP_TABLE_OC_DELETE_ROWS; }  // default
        | ON_SYM COMMIT_SYM PRESERVE_SYM ROWS_SYM
          { $$= temp_table_oc_param::TEMP_TABLE_OC_PRESERVE_ROWS; }
%endif

create_sequence_stmt:
          CREATE SEQUENCE_SYM opt_if_not_exists table_ident sequence_options_def
          {
            $$ = NEW_PTN PT_create_sequence_stmt($3, $4);
          }
        ;

sequence_options_def:
          /* empty */
        | sequence_option_list
        ;

sequence_option_list:
          sequence_option
        | sequence_option_list sequence_option
        ;

sequence_signed_NUM_literal:
          NUM_literal { $$ = $1; }
        | '+' NUM_literal { $$= $2; }
        | '-' NUM_literal
          {
            if ($2 == NULL)
              MYSQL_YYABORT;  // OOM
            $2->max_length++;
            $$ = $2->neg();
          }
        ;

sequence_option:
          seq_start_opt
        | seq_increment_opt
        | seq_maxvalue_opt
        | seq_minvalue_opt
        | seq_cycle_opt
        | seq_cache_opt
        | seq_order_opt
        ;

seq_start_opt:
          START_WITH_SYM sequence_signed_NUM_literal
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_START) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION, MYF(0), "start with");
              MYSQL_YYABORT;
            }
            my_decimal *val = &Lex->seq_option.start_with;
            *val = *$2->val_decimal(val);
            if (val->frac) {
              my_error(ER_ONLY_INTEGERS_ALLOWED, MYF(0));
              MYSQL_YYABORT;
            }
            Lex->seq_option.option_bitmap |= Sequence_option::OPTION_TYPE_START;
          }
        ;

seq_increment_opt:
          INCREMENT_SYM BY sequence_signed_NUM_literal
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_INCREMENT) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION, MYF(0),
                       "increment by");
              MYSQL_YYABORT;
            }
            my_decimal *val = &Lex->seq_option.increment;
            *val = *$3->val_decimal(val);
            if (val->frac) {
              my_error(ER_ONLY_INTEGERS_ALLOWED, MYF(0));
              MYSQL_YYABORT;
            }
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_INCREMENT;
          }
        ;

seq_minvalue_opt:
          MIN_VALUE_SYM sequence_signed_NUM_literal
          {
            if (Lex->seq_option.option_bitmap &
                    (Sequence_option::OPTION_TYPE_MINVALUE |
                     Sequence_option::OPTION_TYPE_NOMINVALUE)) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                       "minvalue/nominvalue");
              MYSQL_YYABORT;
            }
            my_decimal *val = &Lex->seq_option.min_value;
            *val = *$2->val_decimal(val);
            if (val->frac) {
              my_error(ER_ONLY_INTEGERS_ALLOWED, MYF(0));
              MYSQL_YYABORT;
            }
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_MINVALUE;
          }
        | NO_MINVALUE_SYM
          {
            if (Lex->seq_option.option_bitmap &
                    (Sequence_option::OPTION_TYPE_MINVALUE |
                     Sequence_option::OPTION_TYPE_NOMINVALUE)) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                       "minvalue/nominvalue");
              MYSQL_YYABORT;
            }
            Lex->seq_option.min_value = gdb_seqval_invalid;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_NOMINVALUE;
          }
        ;

seq_maxvalue_opt:
          MAX_VALUE_SYM sequence_signed_NUM_literal
          {
            if (Lex->seq_option.option_bitmap &
                    (Sequence_option::OPTION_TYPE_MAXVALUE |
                     Sequence_option::OPTION_TYPE_NOMAXVALUE)) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION, MYF(0),
                          "maxvalue/nomaxvalue");
              MYSQL_YYABORT;
            }
            my_decimal *val = &Lex->seq_option.max_value;
            *val = *$2->val_decimal(val);
            if (val->frac) {
              my_error(ER_ONLY_INTEGERS_ALLOWED, MYF(0));
              MYSQL_YYABORT;
            }
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_MAXVALUE;
          }
        | NO_MAXVALUE_SYM
          {
            if (Lex->seq_option.option_bitmap &
                    (Sequence_option::OPTION_TYPE_MAXVALUE |
                     Sequence_option::OPTION_TYPE_NOMAXVALUE)) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION, MYF(0),
                          "maxvalue/nomaxvalue");
              MYSQL_YYABORT;
            }
            Lex->seq_option.max_value = gdb_seqval_invalid;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_NOMAXVALUE;
          }
        ;

seq_cycle_opt:
          CYCLE_SYM
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_CYCLEFLAG) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                          "cycle/nocycle");
              MYSQL_YYABORT;
            }
            Lex->seq_option.cycle_flag = true;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_CYCLEFLAG;
          }
        | NO_CYCLE_SYM
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_CYCLEFLAG) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                          "cycle/nocycle");
              MYSQL_YYABORT;
            }
            Lex->seq_option.cycle_flag = false;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_CYCLEFLAG;
          }
        ;

seq_cache_opt:
          CACHE_SYM ulong_num
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_CACHENUM) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                          "cache/nocache");
              MYSQL_YYABORT;
            }
            Lex->seq_option.cache_num = $2;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_CACHENUM;
          }
        | NO_CACHE_SYM
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_CACHENUM) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                          "cache/nocache");
              MYSQL_YYABORT;
            }
            Lex->seq_option.cache_num = 0;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_CACHENUM;
          }
        ;

seq_order_opt:
          ORDER_SYM
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_ORDERFLAG) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                          "order/noorder");
              MYSQL_YYABORT;
            }
            Lex->seq_option.order_flag = true;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_ORDERFLAG;
          }
        | NO_ORDER_SYM
          {
            if (Lex->seq_option.option_bitmap &
                Sequence_option::OPTION_TYPE_ORDERFLAG) {
              my_error(ER_GDB_SEQUENCE_DUPLICATE_OPTION,  MYF(0),
                          "order/noorder");
              MYSQL_YYABORT;
            }
            Lex->seq_option.order_flag = false;
            Lex->seq_option.option_bitmap |=
                Sequence_option::OPTION_TYPE_ORDERFLAG;
          }
        ;

create_role_stmt:
          CREATE ROLE_SYM opt_if_not_exists role_list
          {
            $$= NEW_PTN PT_create_role(!!$3, $4);
          }
        ;

create_resource_group_stmt:
          CREATE RESOURCE_SYM GROUP_SYM ident TYPE_SYM
          opt_equal resource_group_types
          opt_resource_group_vcpu_list opt_resource_group_priority
          opt_resource_group_enable_disable
          {
            $$= NEW_PTN PT_create_resource_group(to_lex_cstring($4), $7, $8, $9,
                                                 $10.is_default ? true :
                                                 $10.value);
          }
        ;

create:
          CREATE DATABASE opt_if_not_exists ident
          {
            Lex->create_info= YYTHD->alloc_typed<HA_CREATE_INFO>();
            if (Lex->create_info == NULL)
              MYSQL_YYABORT; // OOM
            Lex->create_info->default_table_charset= NULL;
            Lex->create_info->used_fields= 0;
          }
          opt_create_database_options
          {
            LEX *lex=Lex;
            lex->sql_command=SQLCOM_CREATE_DB;
            lex->name= $4;
            lex->create_info->options= $3 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
          }
        | CREATE view_or_trigger_or_sp_or_event
          {}
        | CREATE USER opt_if_not_exists create_user_list default_role_clause
                      require_clause connect_options
                      opt_account_lock_password_expire_options
                      opt_user_attribute
          {
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_CREATE_USER;
            lex->default_roles= $5;
            Lex->create_info= YYTHD->alloc_typed<HA_CREATE_INFO>();
            if (Lex->create_info == NULL)
              MYSQL_YYABORT; // OOM
            lex->create_info->options= $3 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
          }
        | CREATE LOGFILE_SYM GROUP_SYM ident ADD lg_undofile
          opt_logfile_group_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($7 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $7))
                MYSQL_YYABORT; /* purecov: inspected */
            }

            Lex->m_sql_cmd= NEW_PTN Sql_cmd_logfile_group{CREATE_LOGFILE_GROUP,
                                                          $4, pc, $6};
            if (!Lex->m_sql_cmd)
              MYSQL_YYABORT; /* purecov: inspected */ //OOM

            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        | CREATE TABLESPACE_SYM ident opt_ts_datafile_name
          opt_logfile_group_name opt_tablespace_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($6 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $6))
                MYSQL_YYABORT;
            }

            auto cmd= NEW_PTN Sql_cmd_create_tablespace{$3, $4, $5, pc};
            if (!cmd)
              MYSQL_YYABORT; /* purecov: inspected */ //OOM
            Lex->m_sql_cmd= cmd;
            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        | CREATE UNDO_SYM TABLESPACE_SYM ident ADD ts_datafile
          opt_undo_tablespace_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; // OOM

            if ($7 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $7))
                MYSQL_YYABORT;
            }

            auto cmd= NEW_PTN Sql_cmd_create_undo_tablespace{
              CREATE_UNDO_TABLESPACE, $4, $6, pc};
            if (!cmd)
              MYSQL_YYABORT; //OOM
            Lex->m_sql_cmd= cmd;
            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        | CREATE SERVER_SYM ident_or_text FOREIGN DATA_SYM WRAPPER_SYM
          ident_or_text OPTIONS_SYM '(' server_options_list ')'
          {
            Lex->sql_command= SQLCOM_CREATE_SERVER;
            if ($3.length == 0)
            {
              my_error(ER_WRONG_VALUE, MYF(0), "server name", "");
              MYSQL_YYABORT;
            }
            Lex->server_options.m_server_name= $3;
            Lex->server_options.set_scheme($7);
            Lex->m_sql_cmd=
              NEW_PTN Sql_cmd_create_server(&Lex->server_options);
          }
        | CREATE COMPRESSION_DICTIONARY_SYM opt_if_not_exists ident
          '(' create_compression_dictionary_allowed_expr ')'
          {
            Lex->sql_command= SQLCOM_CREATE_COMPRESSION_DICTIONARY;
            Lex->create_info= YYTHD->alloc_typed<HA_CREATE_INFO>();
            if (Lex->create_info == nullptr)
              MYSQL_YYABORT; // OOM
            Lex->create_info->options= $3 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
            Lex->ident= $4;
            Lex->create_info->zip_dict_name = $6;
          }
        ;

create_srs_stmt:
          CREATE OR_SYM REPLACE_SYM SPATIAL_SYM REFERENCE_SYM SYSTEM_SYM
          real_ulonglong_num srs_attributes
          {
            $$= NEW_PTN PT_create_srs($7, *$8, true, false);
          }
        | CREATE SPATIAL_SYM REFERENCE_SYM SYSTEM_SYM opt_if_not_exists
          real_ulonglong_num srs_attributes
          {
            $$= NEW_PTN PT_create_srs($6, *$7, false, $5);
          }
        ;

srs_attributes:
          /* empty */
          {
            $$ = NEW_PTN Sql_cmd_srs_attributes();
            if (!$$)
              MYSQL_YYABORT_ERROR(ER_DA_OOM, MYF(0)); /* purecov: inspected */
          }
        | srs_attributes NAME_SYM TEXT_STRING_sys_nonewline
          {
            if ($1->srs_name.str != nullptr)
            {
              MYSQL_YYABORT_ERROR(ER_SRS_MULTIPLE_ATTRIBUTE_DEFINITIONS, MYF(0),
                                  "NAME");
            }
            else
            {
              $1->srs_name= $3;
            }
          }
        | srs_attributes DEFINITION_SYM TEXT_STRING_sys_nonewline
          {
            if ($1->definition.str != nullptr)
            {
              MYSQL_YYABORT_ERROR(ER_SRS_MULTIPLE_ATTRIBUTE_DEFINITIONS, MYF(0),
                                  "DEFINITION");
            }
            else
            {
              $1->definition= $3;
            }
          }
        | srs_attributes ORGANIZATION_SYM TEXT_STRING_sys_nonewline
          IDENTIFIED_SYM BY real_ulonglong_num
          {
            if ($1->organization.str != nullptr)
            {
              MYSQL_YYABORT_ERROR(ER_SRS_MULTIPLE_ATTRIBUTE_DEFINITIONS, MYF(0),
                                  "ORGANIZATION");
            }
            else
            {
              $1->organization= $3;
              $1->organization_coordsys_id= $6;
            }
          }
        | srs_attributes DESCRIPTION_SYM TEXT_STRING_sys_nonewline
          {
            if ($1->description.str != nullptr)
            {
              MYSQL_YYABORT_ERROR(ER_SRS_MULTIPLE_ATTRIBUTE_DEFINITIONS, MYF(0),
                                  "DESCRIPTION");
            }
            else
            {
              $1->description= $3;
            }
          }
        ;

default_role_clause:
          /* empty */
          {
            $$= 0;
          }
        |
          DEFAULT_SYM ROLE_SYM role_list
          {
            $$= $3;
          }
        ;

create_index_stmt:
          CREATE opt_unique_combo_clustering INDEX_SYM ident opt_index_type_clause
          ON_SYM table_ident '(' key_list_with_expression ')' opt_index_options
          opt_index_lock_and_algorithm
          {
            $$= NEW_PTN PT_create_index_stmt(YYMEM_ROOT, $2, $4, $5,
                                             $7, $9, $11,
                                             $12.algo.get_or_default(),
                                             $12.lock.get_or_default());
          }
        | CREATE FULLTEXT_SYM INDEX_SYM ident ON_SYM table_ident
          '(' key_list_with_expression ')' opt_fulltext_index_options opt_index_lock_and_algorithm
          {
            $$= NEW_PTN PT_create_index_stmt(YYMEM_ROOT, KEYTYPE_FULLTEXT, $4,
                                             NULL, $6, $8, $10,
                                             $11.algo.get_or_default(),
                                             $11.lock.get_or_default());
          }
        | CREATE SPATIAL_SYM INDEX_SYM ident ON_SYM table_ident
          '(' key_list_with_expression ')' opt_spatial_index_options opt_index_lock_and_algorithm
          {
            $$= NEW_PTN PT_create_index_stmt(YYMEM_ROOT, KEYTYPE_SPATIAL, $4,
                                             NULL, $6, $8, $10,
                                             $11.algo.get_or_default(),
                                             $11.lock.get_or_default());
          }
        ;
/*
  Only a limited subset of <expr> are allowed in
  CREATE COMPRESSION_DICTIONARY.
*/
create_compression_dictionary_allowed_expr:
          text_literal
          { ITEMIZE($1, &$$); }
        | rvalue_system_or_user_variable
          { ITEMIZE($1, &$$); }
        ;

server_options_list:
          server_option
        | server_options_list ',' server_option
        ;

server_option:
          USER TEXT_STRING_sys
          {
            Lex->server_options.set_username($2);
          }
        | HOST_SYM TEXT_STRING_sys
          {
            Lex->server_options.set_host($2);
          }
        | DATABASE TEXT_STRING_sys
          {
            Lex->server_options.set_db($2);
          }
        | OWNER_SYM TEXT_STRING_sys
          {
            Lex->server_options.set_owner($2);
          }
        | PASSWORD TEXT_STRING_sys
          {
            Lex->server_options.set_password($2);
            Lex->contains_plaintext_password= true;
          }
        | SOCKET_SYM TEXT_STRING_sys
          {
            Lex->server_options.set_socket($2);
          }
        | PORT_SYM ulong_num
          {
            Lex->server_options.set_port($2);
          }
        ;

event_tail:
          EVENT_SYM opt_if_not_exists sp_name
          {
            THD *thd= YYTHD;
            LEX *lex=Lex;

            lex->stmt_definition_begin= @1.cpp.start;
            lex->create_info->options= $2 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
            if (!(lex->event_parse_data= new (thd->mem_root) Event_parse_data()))
              MYSQL_YYABORT;
            lex->event_parse_data->identifier= $3;
            lex->event_parse_data->on_completion=
                                  Event_parse_data::ON_COMPLETION_DROP;

            lex->sql_command= SQLCOM_CREATE_EVENT;
            /* We need that for disallowing subqueries */
          }
          ON_SYM SCHEDULE_SYM ev_schedule_time
          opt_ev_on_completion
          opt_ev_status
          opt_ev_comment
          DO_SYM ev_sql_stmt
          {
            /*
              sql_command is set here because some rules in ev_sql_stmt
              can overwrite it
            */
            Lex->sql_command= SQLCOM_CREATE_EVENT;
          }
        ;

ev_schedule_time:
          EVERY_SYM expr interval
          {
            ITEMIZE($2, &$2);

            Lex->event_parse_data->item_expression= $2;
            Lex->event_parse_data->interval= $3;
          }
          ev_starts
          ev_ends
        | AT_SYM expr
          {
            ITEMIZE($2, &$2);

            Lex->event_parse_data->item_execute_at= $2;
          }
        ;

opt_ev_status:
          /* empty */ { $$= 0; }
        | ENABLE_SYM
          {
            Lex->event_parse_data->status= Event_parse_data::ENABLED;
            Lex->event_parse_data->status_changed= true;
            $$= 1;
          }
        | DISABLE_SYM ON_SYM SLAVE
          {
            Lex->event_parse_data->status= Event_parse_data::SLAVESIDE_DISABLED;
            Lex->event_parse_data->status_changed= true;
            $$= 1;
          }
        | DISABLE_SYM
          {
            Lex->event_parse_data->status= Event_parse_data::DISABLED;
            Lex->event_parse_data->status_changed= true;
            $$= 1;
          }
        ;

ev_starts:
          /* empty */
          {
            Item *item= NEW_PTN Item_func_now_local(0);
            if (item == NULL)
              MYSQL_YYABORT;
            Lex->event_parse_data->item_starts= item;
          }
        | STARTS_SYM expr
          {
            ITEMIZE($2, &$2);

            Lex->event_parse_data->item_starts= $2;
          }
        ;

ev_ends:
          /* empty */
        | ENDS_SYM expr
          {
            ITEMIZE($2, &$2);

            Lex->event_parse_data->item_ends= $2;
          }
        ;

opt_ev_on_completion:
          /* empty */ { $$= 0; }
        | ev_on_completion
        ;

ev_on_completion:
          ON_SYM COMPLETION_SYM PRESERVE_SYM
          {
            Lex->event_parse_data->on_completion=
                                  Event_parse_data::ON_COMPLETION_PRESERVE;
            $$= 1;
          }
        | ON_SYM COMPLETION_SYM NOT_SYM PRESERVE_SYM
          {
            Lex->event_parse_data->on_completion=
                                  Event_parse_data::ON_COMPLETION_DROP;
            $$= 1;
          }
        ;

opt_ev_comment:
          /* empty */ { $$= 0; }
        | COMMENT_SYM TEXT_STRING_sys
          {
            Lex->event_parse_data->comment= $2;
            $$= 1;
          }
        ;

ev_sql_stmt:
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            /*
              This stops the following :
              - CREATE EVENT ... DO CREATE EVENT ...;
              - ALTER  EVENT ... DO CREATE EVENT ...;
              - CREATE EVENT ... DO ALTER EVENT DO ....;
              - CREATE PROCEDURE ... BEGIN CREATE EVENT ... END|
              This allows:
              - CREATE EVENT ... DO DROP EVENT yyy;
              - CREATE EVENT ... DO ALTER EVENT yyy;
                (the nested ALTER EVENT can have anything but DO clause)
              - ALTER  EVENT ... DO ALTER EVENT yyy;
                (the nested ALTER EVENT can have anything but DO clause)
              - ALTER  EVENT ... DO DROP EVENT yyy;
              - CREATE PROCEDURE ... BEGIN ALTER EVENT ... END|
                (the nested ALTER EVENT can have anything but DO clause)
              - CREATE PROCEDURE ... BEGIN DROP EVENT ... END|
            */
            if (lex->sphead)
            {
              my_error(ER_EVENT_RECURSION_FORBIDDEN, MYF(0));
              MYSQL_YYABORT;
            }

            sp_head *sp= sp_start_parsing(thd,
                                          enum_sp_type::EVENT,
                                          lex->event_parse_data->identifier);

            if (!sp)
              MYSQL_YYABORT;

            lex->sphead= sp;

            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
            sp->m_chistics= &lex->sp_chistics;

            /*
              Set a body start to the end of the last preprocessed token
              before ev_sql_stmt:
            */
            sp->set_body_start(thd, @0.cpp.end);
          }
          ev_sql_stmt_inner
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            sp_finish_parsing(thd);

            lex->sp_chistics.suid= SP_IS_SUID;  //always the definer!
            lex->event_parse_data->body_changed= true;
          }
        ;

%ifndef SQL_MODE_ORACLE
ev_sql_stmt_inner:
          sp_proc_stmt_statement
        | sp_proc_stmt_return
        | sp_proc_stmt_if
        | case_stmt_specification
        | sp_labeled_block
        | sp_unlabeled_block
        | sp_labeled_control
        | sp_proc_stmt_unlabeled
        | sp_proc_stmt_leave
        | sp_proc_stmt_iterate
        | sp_proc_stmt_open
        | sp_proc_stmt_fetch
        | sp_proc_stmt_close
        ;
%endif

%ifdef SQL_MODE_ORACLE
sp_namef:
          sp_name
        | ident '.' ident '.' ident
          {
            if ($1.length == 0)
            {
              my_error(ER_WRONG_DB_NAME, MYF(0), "");
              MYSQL_YYABORT;
            }
            if (!$1.str ||
                (check_and_convert_db_name(&$1, false) != Ident_name_check::OK))
              MYSQL_YYABORT;
            if (!$3.str ||
                (check_and_convert_db_name(&$3, false) != Ident_name_check::OK))
              MYSQL_YYABORT;
            if (sp_check_name(&$5))
            {
              MYSQL_YYABORT;
            }
            $$= new (YYMEM_ROOT) sp_name(to_lex_cstring($3), $5, true);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->init_qname(YYTHD);
            $$->m_pkg_db= to_lex_cstring($1);
          }
%endif

sp_name:
          ident '.' ident
          {
            if (!$1.str ||
                (check_and_convert_db_name(&$1, false) != Ident_name_check::OK))
              MYSQL_YYABORT;
            if (sp_check_name(&$3))
            {
              MYSQL_YYABORT;
            }
            $$= new (YYMEM_ROOT) sp_name(to_lex_cstring($1), $3, true);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->init_qname(YYTHD);
          }
        | ident
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            LEX_CSTRING db;
            if (sp_check_name(&$1))
            {
              MYSQL_YYABORT;
            }
            if (lex->copy_db_to(&db.str, &db.length))
              MYSQL_YYABORT;
            $$= new (YYMEM_ROOT) sp_name(db, $1, false);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->init_qname(thd);
          }
        ;

sp_a_chistics:
          /* Empty */ {}
        | sp_a_chistics sp_chistic {}
        ;

sp_c_chistics:
          /* Empty */ {}
        | sp_c_chistics sp_c_chistic {}
        ;

/* Characteristics for both create and alter */
sp_chistic:
          COMMENT_SYM TEXT_STRING_sys
          { Lex->sp_chistics.comment= to_lex_cstring($2); }
        | LANGUAGE_SYM SQL_SYM
          { /* Just parse it, we only have one language for now. */ }
        | NO_SYM SQL_SYM
          { Lex->sp_chistics.daccess= SP_NO_SQL; }
        | CONTAINS_SYM SQL_SYM
          { Lex->sp_chistics.daccess= SP_CONTAINS_SQL; }
        | READS_SYM SQL_SYM DATA_SYM
          { Lex->sp_chistics.daccess= SP_READS_SQL_DATA; }
        | MODIFIES_SYM SQL_SYM DATA_SYM
          { Lex->sp_chistics.daccess= SP_MODIFIES_SQL_DATA; }
        | sp_suid
          {}
        ;

/* Create characteristics */
sp_c_chistic:
          sp_chistic            { }
        | DETERMINISTIC_SYM     { Lex->sp_chistics.detistic= true; }
        | not DETERMINISTIC_SYM { Lex->sp_chistics.detistic= false; }
        ;

sp_suid:
          SQL_SYM SECURITY_SYM DEFINER_SYM
          {
            $$= Lex->sp_chistics.suid= SP_IS_SUID;
          }
        | SQL_SYM SECURITY_SYM INVOKER_SYM
          {
            $$= Lex->sp_chistics.suid= SP_IS_NOT_SUID;
          }
        ;

call_stmt:
%ifdef SQL_MODE_ORACLE
          CALL_SYM sp_namef opt_paren_expr_list
%else
          CALL_SYM sp_name opt_paren_expr_list
%endif
          {
            $$= NEW_PTN PT_call($1, $2, $3);
          }
        ;

opt_paren_expr_list:
            /* Empty */ { $$= NULL; }
          | '(' opt_udf_expr_list ')'
            {
              $$= $2;
            }
          ;

/* Stored FUNCTION parameter declaration list */
sp_fdparam_list:
          /* Empty */
        | sp_fdparams
        ;

sp_fdparams:
          sp_fdparams ',' sp_fdparam
        | sp_fdparam
        ;

sp_fdparam:
%ifdef SQL_MODE_ORACLE
          ident sp_type_ora opt_collate sp_opt_param_default
%else
          ident type opt_collate sp_opt_param_default
%endif
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            CONTEXTUALIZE($2);
            enum_field_types field_type= $2->type;
            const CHARSET_INFO *cs= $2->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $3, &cs))
              MYSQL_YYABORT;

            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (sp_check_name(&$1))
              MYSQL_YYABORT;

            if (pctx->find_variable($1.str, $1.length, true))
            {
              my_error(ER_SP_DUP_PARAM, MYF(0), $1.str);
              MYSQL_YYABORT;
            }

            sp_variable *spvar= pctx->add_variable(thd,
                                                   $1,
                                                   field_type,
                                                   sp_variable::MODE_IN);

            if ($4.expr != nullptr) {
              if (thd->variables.sql_mode & MODE_ORACLE)
              {
                Item *dflt_value_item=  $4.expr;
                ITEMIZE(dflt_value_item, &dflt_value_item);

                if (check_for_routine_default_parameters(thd, dflt_value_item, field_type, $2, $1.str)) {
                  MYSQL_YYABORT;
                }

                // val string
                dflt_value_item->orig_name.copy($4.expr_start, @4.raw.end - $4.expr_start,
                        system_charset_info, false);

                // var name
                dflt_value_item->item_name.copy( $1.str, $1.length,
                        system_charset_info, false);

                spvar->default_value= dflt_value_item;
              } else {
                YYTHD->syntax_error_at(@4);
                MYSQL_YYABORT;
              }
            }

            Qualified_column_ident* udt_ident = nullptr;
            auto row_type = dynamic_cast<PT_row_type*>($2);
            if (row_type) {
              udt_ident = row_type->get_udt_name();
            }

            if (spvar->field_def.init(thd, $1.str, field_type,
                                      $2->get_length(), $2->get_dec(),
                                      $2->get_type_flags(),
                                      NULL, NULL, &NULL_CSTR, 0,
                                      $2->get_interval_list(),
                                      cs ? cs : thd->variables.collation_database,
                                      $3 != nullptr, $2->get_uint_geom_type(), nullptr,
                                      nullptr, nullptr, {},
                                      dd::Column::enum_hidden_type::HT_VISIBLE,
                                      false, udt_ident))
            {
              MYSQL_YYABORT;
            }

%ifdef SQL_MODE_ORACLE
            if($2->is_sys_refcursor_type()) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "sys_refcursor type used as function param");
              MYSQL_YYABORT;
            }

            if (row_type) {
              spvar->field_def.table_type = row_type->m_table_type;
              spvar->field_def.varray_limit = row_type->m_varray_limit;
              spvar->field_def.nested_table_udt = row_type->m_nested_table_udt_tmp;
              spvar->field_def.ora_record.set_row_field_definitions(row_type->m_row_def);
              spvar->field_def.ora_record.set_row_field_table_definitions(row_type->m_row_def_table);
              spvar->field_def.ora_record.m_is_sp_param = true;
            }
%endif
            if (prepare_sp_create_field(thd,
                                        &spvar->field_def))
            {
              MYSQL_YYABORT;
            }
            spvar->field_def.field_name= spvar->name.str;
            spvar->field_def.is_nullable= true;
          }
        ;

/* Stored PROCEDURE parameter declaration list */
sp_pdparam_list:
          /* Empty */
        | sp_pdparams
        ;

sp_pdparams:
          sp_pdparams ',' sp_pdparam
        | sp_pdparam
        ;

sp_pdparam:
%ifdef SQL_MODE_ORACLE
          ident sp_opt_inout sp_type_ora opt_collate sp_opt_param_default
%else
          sp_opt_inout ident type opt_collate sp_opt_param_default
%endif
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
%ifdef SQL_MODE_ORACLE
            LEX_STRING *id= &$1;
            int *mode= &$2;
%else
            LEX_STRING *id= &$2;
            int *mode= &$1;
%endif
            if (sp_check_name(id))
              MYSQL_YYABORT;

            if (pctx->find_variable(id->str, id->length, true))
            {
              my_error(ER_SP_DUP_PARAM, MYF(0), id->str);
              MYSQL_YYABORT;
            }

            CONTEXTUALIZE($3);
            enum_field_types field_type= $3->type;
            const CHARSET_INFO *cs= $3->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $4, &cs))
              MYSQL_YYABORT;

            sp_variable *spvar= pctx->add_variable(thd,
                                                   *id,
                                                   field_type,
                                                   (sp_variable::enum_mode) *mode);

            if ($5.expr != nullptr) {
              if (thd->variables.sql_mode& MODE_ORACLE && *mode==sp_variable::MODE_IN)
              {
                Item *dflt_value_item=  $5.expr;
                ITEMIZE(dflt_value_item, &dflt_value_item);

                if (check_for_routine_default_parameters(thd, dflt_value_item, field_type, $3, id->str)) {
                  MYSQL_YYABORT;
                }

                // val string
                dflt_value_item->orig_name.copy($5.expr_start, @5.raw.end - $5.expr_start,
                        system_charset_info, false);
                // var name
                dflt_value_item->item_name.copy( id->str, id->length,
                        system_charset_info, false);
                spvar->default_value= dflt_value_item;
              } else {
                my_error(ER_SP_INVALID_DEFAULT_PARAM, MYF(0), id->str, "not IN mode");
                MYSQL_YYABORT;
              }
            }

            Qualified_column_ident* udt_ident = nullptr;
            auto row_type = dynamic_cast<PT_row_type*>($3);
            if (row_type) {
              udt_ident = row_type->get_udt_name();
            }

            if (spvar->field_def.init(thd, id->str, field_type,
                                      $3->get_length(), $3->get_dec(),
                                      $3->get_type_flags(),
                                      NULL, NULL, &NULL_CSTR, 0,
                                      $3->get_interval_list(),
                                      cs ? cs : thd->variables.collation_database,
                                      $4 != nullptr, $3->get_uint_geom_type(), nullptr,
                                      nullptr, nullptr, {},
                                      dd::Column::enum_hidden_type::HT_VISIBLE,
                                      false, udt_ident))
            {
              MYSQL_YYABORT;
            }

%ifdef SQL_MODE_ORACLE
            if($3->is_sys_refcursor_type()) {
              uint offp= 0;
              if (pctx->find_cursor(*id, &offp, false)) {
                my_error(ER_SP_DUP_CURS, MYF(0), id->str);
                MYSQL_YYABORT;
              }
              if (pctx->add_cursor_parameters(thd, *id, pctx, &offp, spvar)) {
                MYSQL_YYABORT;
              }
              spvar->field_def.ora_record.is_ref_cursor= true;
              spvar->field_def.ora_record.m_cursor_offset= offp;
            }

            if (row_type) {
              spvar->field_def.table_type = row_type->m_table_type;
              spvar->field_def.varray_limit = row_type->m_varray_limit;
              spvar->field_def.nested_table_udt = row_type->m_nested_table_udt_tmp;
              spvar->field_def.ora_record.set_row_field_definitions(row_type->m_row_def);
              spvar->field_def.ora_record.set_row_field_table_definitions(row_type->m_row_def_table);
              spvar->field_def.ora_record.m_is_sp_param = true;
            }
%endif
            if (prepare_sp_create_field(thd,
                                        &spvar->field_def))
            {
              MYSQL_YYABORT;
            }
            spvar->field_def.field_name= spvar->name.str;
            spvar->field_def.is_nullable= true;
          }
        ;

%ifdef SQL_MODE_ORACLE
sp_type_ora:
          type                { $$= $1; }
        | SYS_REFCURSOR_SYM   { $$= NEW_PTN PT_sys_refcursor_type(); }
        | IDENT_sys
          {
            sp_head *sp= YYTHD->lex->sphead;
            auto udt_ident = NEW_PTN Qualified_column_ident(to_lex_cstring(sp->m_db), to_lex_cstring($1));
            $$= NEW_PTN PT_row_type(udt_ident);
          }
%endif

sp_opt_inout:
          /* Empty */ { $$= sp_variable::MODE_IN; }
        | IN_SYM      { $$= sp_variable::MODE_IN; }
        | OUT_SYM     { $$= sp_variable::MODE_OUT; }
%ifdef SQL_MODE_ORACLE
        | IN_SYM OUT_SYM  { $$= sp_variable::MODE_INOUT; }
%else
        | INOUT_SYM   { $$= sp_variable::MODE_INOUT; }
%endif
        ;

sp_proc_stmts:
          /* Empty */ {}
        | sp_proc_stmts  sp_proc_stmt ';'
        ;

sp_proc_stmts1:
          sp_proc_stmt ';' {}
        | sp_proc_stmts1  sp_proc_stmt ';'
        ;

%ifndef SQL_MODE_ORACLE
sp_decls:
          /* Empty */
          {
            $$.vars= $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | sp_decls sp_decl ';'
          {
            /* We check for declarations out of (standard) order this way
              because letting the grammar rules reflect it caused tricky
               shift/reduce conflicts with the wrong result. (And we get
               better error handling this way.) */
            if (($2.vars || $2.conds) && ($1.curs || $1.hndlrs))
            { /* Variable or condition following cursor or handler */
              my_error(ER_SP_VARCOND_AFTER_CURSHNDLR, MYF(0));
              MYSQL_YYABORT;
            }
            if ($2.curs && $1.hndlrs)
            { /* Cursor following handler */
              my_error(ER_SP_CURSOR_AFTER_HANDLER, MYF(0));
              MYSQL_YYABORT;
            }
            $$.join($1, $2);
          }
        ;

sp_decl:
          DECLARE_SYM           /*$1*/
          sp_decl_idents        /*$2*/
          type                  /*$3*/
          opt_collate           /*$4*/
          sp_opt_default        /*$5*/
          {                     /*$6*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp->reset_lex(thd);
            lex= thd->lex;

            pctx->declare_var_boundary($2);

            CONTEXTUALIZE($3);
            enum enum_field_types var_type= $3->type;
            const CHARSET_INFO *cs= $3->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $4, &cs))
              MYSQL_YYABORT;

            uint num_vars= pctx->context_var_count();
            Item *dflt_value_item= $5.expr;

            LEX_CSTRING dflt_value_query= EMPTY_CSTR;

            if (dflt_value_item)
            {
              ITEMIZE(dflt_value_item, &dflt_value_item);
              const char *expr_start_ptr= $5.expr_start;
              if (lex->is_metadata_used())
              {
                dflt_value_query= make_string(thd, expr_start_ptr,
                                              @5.raw.end);
                if (!dflt_value_query.str)
                  MYSQL_YYABORT;
              }
            }
            else
            {
              dflt_value_item= NEW_PTN Item_null();

              if (dflt_value_item == NULL)
                MYSQL_YYABORT;
            }

            // We can have several variables in DECLARE statement.
            // We need to create an sp_instr_set instruction for each variable.

            for (uint i = num_vars-$2 ; i < num_vars ; i++)
            {
              uint var_idx= pctx->var_context2runtime(i);
              sp_variable *spvar= pctx->find_variable(var_idx);

              if (!spvar)
                MYSQL_YYABORT;

              spvar->type= var_type;
              spvar->default_value= dflt_value_item;

              if (spvar->field_def.init(thd, "", var_type,
                                        $3->get_length(), $3->get_dec(),
                                        $3->get_type_flags(),
                                        NULL, NULL, &NULL_CSTR, 0,
                                        $3->get_interval_list(),
                                        cs ? cs : thd->variables.collation_database,
                                        $4 != nullptr, $3->get_uint_geom_type(), nullptr,
                                        nullptr, nullptr, {},
                                        dd::Column::enum_hidden_type::HT_VISIBLE))
              {
                MYSQL_YYABORT;
              }

              if (prepare_sp_create_field(thd, &spvar->field_def))
                MYSQL_YYABORT;

              spvar->field_def.field_name= spvar->name.str;
              spvar->field_def.is_nullable= true;

              /* The last instruction is responsible for freeing LEX. */

              sp_instr_set *is= NEW_PTN sp_instr_set(sp->instructions(),
                                                     lex,
                                                     var_idx,
                                                     dflt_value_item,
                                                     dflt_value_query,
                                                     (i == num_vars - 1),
                                                     pctx,
                                                    &sp_rcontext_handler_local);

              if (!is || sp->add_instr(thd, is))
                MYSQL_YYABORT;
            }

            pctx->declare_var_boundary(0);
            if (sp->restore_lex(thd))
              MYSQL_YYABORT;
            $$.vars= $2;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | DECLARE_SYM ident CONDITION_SYM FOR_SYM sp_cond
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (pctx->find_condition($2, true))
            {
              my_error(ER_SP_DUP_COND, MYF(0), $2.str);
              MYSQL_YYABORT;
            }
            if(pctx->add_condition(thd, $2, $5))
              MYSQL_YYABORT;
            lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // DECLARE COND FOR
            $$.vars= $$.hndlrs= $$.curs= 0;
            $$.conds= 1;
          }
        | DECLARE_SYM sp_handler_type HANDLER_SYM FOR_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp_pcontext *parent_pctx= lex->get_sp_current_parsing_ctx();

            sp_pcontext *handler_pctx=
              parent_pctx->push_context(thd, sp_pcontext::HANDLER_SCOPE);

            sp_handler *h=
              parent_pctx->add_handler(thd, (sp_handler::enum_type) $2);

            lex->set_sp_current_parsing_ctx(handler_pctx);

            sp_instr_hpush_jump *i=
              NEW_PTN sp_instr_hpush_jump(sp->instructions(), handler_pctx, h);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            if ($2 == sp_handler::CONTINUE)
            {
              // Mark the end of CONTINUE handler scope.

              if (sp->m_parser_data.add_backpatch_entry(
                    i, handler_pctx->last_label()))
              {
                MYSQL_YYABORT;
              }
            }

            if (sp->m_parser_data.add_backpatch_entry(
                  i, handler_pctx->push_label(thd, EMPTY_CSTR, 0)))
            {
              MYSQL_YYABORT;
            }

            lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // DECL HANDLER FOR
          }
          sp_hcond_list sp_proc_stmt
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *hlab= pctx->pop_label(); /* After this hdlr */

            if ($2 == sp_handler::CONTINUE)
            {
              sp_instr_hreturn *i=
                NEW_PTN sp_instr_hreturn(sp->instructions(), pctx);

              if (!i || sp->add_instr(thd, i))
                MYSQL_YYABORT;
            }
            else
            {  /* EXIT or UNDO handler, just jump to the end of the block */
              sp_instr_hreturn *i=
                NEW_PTN sp_instr_hreturn(sp->instructions(), pctx);

              if (i == NULL ||
                  sp->add_instr(thd, i) ||
                  sp->m_parser_data.add_backpatch_entry(i, pctx->last_label()))
                MYSQL_YYABORT;
            }

            sp->m_parser_data.do_backpatch(hlab, sp->instructions());

            lex->set_sp_current_parsing_ctx(pctx->pop_context());

            $$.vars= $$.conds= $$.curs= 0;
            $$.hndlrs= 1;
          }
        | DECLARE_SYM   /*$1*/
          ident         /*$2*/
          CURSOR_SYM    /*$3*/
          FOR_SYM       /*$4*/
          {             /*$5*/
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
            sp->m_parser_data.set_current_stmt_start_ptr(@4.raw.end);
          }
          select_stmt   /*$6*/
          {             /*$7*/
            MAKE_CMD($6);

            THD *thd= YYTHD;
            LEX *cursor_lex= Lex;
            sp_head *sp= cursor_lex->sphead;

            assert(cursor_lex->sql_command == SQLCOM_SELECT);

            if (cursor_lex->result)
            {
              my_error(ER_SP_BAD_CURSOR_SELECT, MYF(0));
              MYSQL_YYABORT;
            }

            cursor_lex->m_sql_cmd->set_as_part_of_sp();
            cursor_lex->sp_lex_in_use= true;

            if (sp->restore_lex(thd))
              MYSQL_YYABORT;

            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            uint offp= 0;

            if (pctx->find_cursor($2, &offp, true))
            {
              my_error(ER_SP_DUP_CURS, MYF(0), $2.str);
              delete cursor_lex;
              MYSQL_YYABORT;
            }

            LEX_CSTRING cursor_query= EMPTY_CSTR;

            // Save the cursor_query to parse stmt includes SEQUENCE sql.
            cursor_query=
                make_string(thd,
                            sp->m_parser_data.get_current_stmt_start_ptr(),
                            @6.raw.end);

            if (!cursor_query.str)
              MYSQL_YYABORT;

            sp_instr_cpush *i=
              NEW_PTN sp_instr_cpush(sp->instructions(), pctx,
                                     cursor_lex, cursor_query,
                                     pctx->current_cursor_count());

            if (i == NULL ||
                sp->add_instr(thd, i) ||
                pctx->add_cursor($2))
            {
              MYSQL_YYABORT;
            }

            $$.vars= $$.conds= $$.hndlrs= 0;
            $$.curs= 1;
          }
        ;
%endif

sp_handler_type:
          EXIT_SYM      { $$= sp_handler::EXIT; }
        | CONTINUE_SYM  { $$= sp_handler::CONTINUE; }
        /*| UNDO_SYM      { QQ No yet } */
        ;

sp_hcond_list:
          sp_hcond_element
          { $$= 1; }
        | sp_hcond_list ',' sp_hcond_element
          { $$+= 1; }
        ;

sp_hcond_element:
          sp_hcond
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_pcontext *parent_pctx= pctx->parent_context();

            if (parent_pctx->check_duplicate_handler($1))
            {
              my_error(ER_SP_DUP_HANDLER, MYF(0));
              MYSQL_YYABORT;
            }
            else
            {
              sp_instr_hpush_jump *i=
                (sp_instr_hpush_jump *)sp->last_instruction();

              i->add_condition($1);
            }
          }
        ;

sp_cond:
          ulong_num
          { /* mysql errno */
            if ($1 == 0)
            {
              my_error(ER_WRONG_VALUE, MYF(0), "CONDITION", "0");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN sp_condition_value($1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | sqlstate
        ;

sqlstate:
          SQLSTATE_SYM opt_value TEXT_STRING_literal
          { /* SQLSTATE */

            /*
              An error is triggered:
                - if the specified string is not a valid SQLSTATE,
                - or if it represents the completion condition -- it is not
                  allowed to SIGNAL, or declare a handler for the completion
                  condition.
            */
            if (!is_sqlstate_valid(&$3) || is_sqlstate_completion($3.str))
            {
              my_error(ER_SP_BAD_SQLSTATE, MYF(0), $3.str);
              MYSQL_YYABORT;
            }
            $$= NEW_PTN sp_condition_value($3.str);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

opt_value:
          /* Empty */  {}
        | VALUE_SYM    {}
        ;

sp_hcond:
          sp_cond
          {
            $$= $1;
          }
        | ident /* CONDITION name */
          {
            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            $$= pctx->find_condition($1, false);

            if ($$ == NULL)
            {
              my_error(ER_SP_COND_MISMATCH, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
          }
        | SQLWARNING_SYM /* SQLSTATEs 01??? */
          {
            $$= NEW_PTN sp_condition_value(sp_condition_value::WARNING);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | not FOUND_SYM /* SQLSTATEs 02??? */
          {
            $$= NEW_PTN sp_condition_value(sp_condition_value::NOT_FOUND);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | SQLEXCEPTION_SYM /* All other SQLSTATEs */
          {
            $$= NEW_PTN sp_condition_value(sp_condition_value::EXCEPTION);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

signal_stmt:
          SIGNAL_SYM signal_value opt_set_signal_information
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sql_command= SQLCOM_SIGNAL;
            lex->m_sql_cmd= NEW_PTN Sql_cmd_signal($2, $3);
            if (lex->m_sql_cmd == NULL)
              MYSQL_YYABORT;
          }
        ;

signal_value:
          ident
          {
            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (!pctx)
            {
              /* SIGNAL foo cannot be used outside of stored programs */
              my_error(ER_SP_COND_MISMATCH, MYF(0), $1.str);
              MYSQL_YYABORT;
            }

            sp_condition_value *cond= pctx->find_condition($1, false);

            if (!cond)
            {
              my_error(ER_SP_COND_MISMATCH, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            if (cond->type != sp_condition_value::SQLSTATE)
            {
              my_error(ER_SIGNAL_BAD_CONDITION_TYPE, MYF(0));
              MYSQL_YYABORT;
            }
            $$= cond;
          }
        | sqlstate
          { $$= $1; }
        ;

opt_signal_value:
          /* empty */
          { $$= NULL; }
        | signal_value
          { $$= $1; }
        ;

opt_set_signal_information:
          /* empty */
          { $$= NEW_PTN Set_signal_information(); }
        | SET_SYM signal_information_item_list
          { $$= $2; }
        ;

signal_information_item_list:
          signal_condition_information_item_name EQ signal_allowed_expr
          {
            $$= NEW_PTN Set_signal_information();
            if ($$->set_item($1, $3))
              MYSQL_YYABORT;
          }
        | signal_information_item_list ','
          signal_condition_information_item_name EQ signal_allowed_expr
          {
            $$= $1;
            if ($$->set_item($3, $5))
              MYSQL_YYABORT;
          }
        ;

/*
  Only a limited subset of <expr> are allowed in SIGNAL/RESIGNAL.
*/
signal_allowed_expr:
          literal_or_null
          { ITEMIZE($1, &$$); }
        | rvalue_system_or_user_variable
          { ITEMIZE($1, &$$); }
        | simple_ident
          { ITEMIZE($1, &$$); }
        ;

/* conditions that can be set in signal / resignal */
signal_condition_information_item_name:
          CLASS_ORIGIN_SYM
          { $$= CIN_CLASS_ORIGIN; }
        | SUBCLASS_ORIGIN_SYM
          { $$= CIN_SUBCLASS_ORIGIN; }
        | CONSTRAINT_CATALOG_SYM
          { $$= CIN_CONSTRAINT_CATALOG; }
        | CONSTRAINT_SCHEMA_SYM
          { $$= CIN_CONSTRAINT_SCHEMA; }
        | CONSTRAINT_NAME_SYM
          { $$= CIN_CONSTRAINT_NAME; }
        | CATALOG_NAME_SYM
          { $$= CIN_CATALOG_NAME; }
        | SCHEMA_NAME_SYM
          { $$= CIN_SCHEMA_NAME; }
        | TABLE_NAME_SYM
          { $$= CIN_TABLE_NAME; }
        | COLUMN_NAME_SYM
          { $$= CIN_COLUMN_NAME; }
        | CURSOR_NAME_SYM
          { $$= CIN_CURSOR_NAME; }
        | MESSAGE_TEXT_SYM
          { $$= CIN_MESSAGE_TEXT; }
        | MYSQL_ERRNO_SYM
          { $$= CIN_MYSQL_ERRNO; }
        ;

resignal_stmt:
          RESIGNAL_SYM opt_signal_value opt_set_signal_information
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sql_command= SQLCOM_RESIGNAL;
            lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // RESIGNAL doesn't clear diagnostics
            lex->m_sql_cmd= NEW_PTN Sql_cmd_resignal($2, $3);
            if (lex->m_sql_cmd == NULL)
              MYSQL_YYABORT;
          }
        ;

get_diagnostics:
          GET_SYM which_area DIAGNOSTICS_SYM diagnostics_information
          {
            Diagnostics_information *info= $4;

            info->set_which_da($2);

            Lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // GET DIAGS doesn't clear them.
            Lex->sql_command= SQLCOM_GET_DIAGNOSTICS;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_get_diagnostics(info);

            if (Lex->m_sql_cmd == NULL)
              MYSQL_YYABORT;
          }
        ;

which_area:
        /* If <which area> is not specified, then CURRENT is implicit. */
          { $$= Diagnostics_information::CURRENT_AREA; }
        | CURRENT_SYM
          { $$= Diagnostics_information::CURRENT_AREA; }
        | STACKED_SYM
          { $$= Diagnostics_information::STACKED_AREA; }
        ;

diagnostics_information:
          statement_information
          {
            $$= NEW_PTN Statement_information($1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | CONDITION_SYM condition_number condition_information
          {
            $$= NEW_PTN Condition_information($2, $3);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

statement_information:
          statement_information_item
          {
            $$= NEW_PTN List<Statement_information_item>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | statement_information ',' statement_information_item
          {
            if ($1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

statement_information_item:
          simple_target_specification EQ statement_information_item_name
          {
            $$= NEW_PTN Statement_information_item($3, $1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }

simple_target_specification:
          ident
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            /*
              NOTE: lex->sphead is NULL if we're parsing something like
              'GET DIAGNOSTICS v' outside a stored program. We should throw
              ER_SP_UNDECLARED_VAR in such cases.
            */

            if (!sp)
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $1.str);
              MYSQL_YYABORT;
            }

            $$=
              create_item_for_sp_var(
                thd, to_lex_cstring($1), NULL, NULL,
                sp->m_parser_data.get_current_stmt_start_ptr(),
                @1.raw.start,
                @1.raw.end);

            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | '@' ident_or_text
          {
            $$= NEW_PTN Item_func_get_user_var(@$, $2);
            ITEMIZE($$, &$$);
          }
        ;

statement_information_item_name:
          NUMBER_SYM
          { $$= Statement_information_item::NUMBER; }
        | ROW_COUNT_SYM
          { $$= Statement_information_item::ROW_COUNT; }
        ;

/*
   Only a limited subset of <expr> are allowed in GET DIAGNOSTICS
   <condition number>, same subset as for SIGNAL/RESIGNAL.
*/
condition_number:
          signal_allowed_expr
          { $$= $1; }
        ;

condition_information:
          condition_information_item
          {
            $$= NEW_PTN List<Condition_information_item>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | condition_information ',' condition_information_item
          {
            if ($1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

condition_information_item:
          simple_target_specification EQ condition_information_item_name
          {
            $$= NEW_PTN Condition_information_item($3, $1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }

condition_information_item_name:
          CLASS_ORIGIN_SYM
          { $$= Condition_information_item::CLASS_ORIGIN; }
        | SUBCLASS_ORIGIN_SYM
          { $$= Condition_information_item::SUBCLASS_ORIGIN; }
        | CONSTRAINT_CATALOG_SYM
          { $$= Condition_information_item::CONSTRAINT_CATALOG; }
        | CONSTRAINT_SCHEMA_SYM
          { $$= Condition_information_item::CONSTRAINT_SCHEMA; }
        | CONSTRAINT_NAME_SYM
          { $$= Condition_information_item::CONSTRAINT_NAME; }
        | CATALOG_NAME_SYM
          { $$= Condition_information_item::CATALOG_NAME; }
        | SCHEMA_NAME_SYM
          { $$= Condition_information_item::SCHEMA_NAME; }
        | TABLE_NAME_SYM
          { $$= Condition_information_item::TABLE_NAME; }
        | COLUMN_NAME_SYM
          { $$= Condition_information_item::COLUMN_NAME; }
        | CURSOR_NAME_SYM
          { $$= Condition_information_item::CURSOR_NAME; }
        | MESSAGE_TEXT_SYM
          { $$= Condition_information_item::MESSAGE_TEXT; }
        | MYSQL_ERRNO_SYM
          { $$= Condition_information_item::MYSQL_ERRNO; }
        | RETURNED_SQLSTATE_SYM
          { $$= Condition_information_item::RETURNED_SQLSTATE; }
        ;

%ifdef SQL_MODE_ORACLE
/*
  Not allowed:

    ident_keywords_ambiguous_5_not_sp_variables
*/
sp_decl_ident_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_1_roles_and_labels
        | ident_keywords_ambiguous_2_labels
        | ident_keywords_ambiguous_3_roles
        | ident_keywords_ambiguous_4_system_variables
        | ident_keywords_ambiguous_6_not_table_alias
        ;


sp_decl_ident:
          IDENT_sys     { $$= $1; }
        | sp_decl_ident_keyword
          {
            THD *thd= YYTHD;
            $$.str= thd->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;
%endif

sp_decl_idents:
%ifdef SQL_MODE_ORACLE
          sp_decl_ident
%else
          ident
%endif
          {
            /* NOTE: field definition is filled in sp_decl section. */

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (pctx->find_variable($1.str, $1.length, true))
            {
              my_error(ER_SP_DUP_VAR, MYF(0), $1.str);
              MYSQL_YYABORT;
            }

            pctx->add_variable(thd,
                               $1,
                               MYSQL_TYPE_DECIMAL,
                               sp_variable::MODE_IN);
            $$= 1;
          }
        | sp_decl_idents ',' ident
          {
            /* NOTE: field definition is filled in sp_decl section. */

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (pctx->find_variable($3.str, $3.length, true))
            {
              my_error(ER_SP_DUP_VAR, MYF(0), $3.str);
              MYSQL_YYABORT;
            }

            pctx->add_variable(thd,
                               $3,
                               MYSQL_TYPE_DECIMAL,
                               sp_variable::MODE_IN);
            $$= $1 + 1;
          }
        ;

sp_opt_param_default:
        /* Empty */
          {
            $$.expr_start= NULL;
            $$.expr = NULL;
          }
        | DEFAULT_SYM now_or_signed_literal
          {
            $$.expr_start= @1.raw.end;
            $$.expr= $2;
          }
%ifdef SQL_MODE_ORACLE
        | SET_VAR now_or_signed_literal
          {
            $$.expr_start= @1.raw.end;
            $$.expr= $2;
          }
%endif
        ;

sp_opt_default:
        /* Empty */
          {
            $$.expr_start= NULL;
            $$.expr = NULL;
          }
        | DEFAULT_SYM expr
          {
            $$.expr_start= @1.raw.end;
            $$.expr= $2;
          }
%ifdef SQL_MODE_ORACLE
        | SET_VAR expr
          {
            $$.expr_start= @1.raw.end;
            $$.expr= $2;
          }
%endif
        ;

%ifndef SQL_MODE_ORACLE
sp_proc_stmt:
          sp_proc_stmt_statement
        | sp_proc_stmt_return
        | sp_proc_stmt_if
        | case_stmt_specification
        | sp_labeled_block
        | sp_unlabeled_block
        | sp_labeled_control
        | sp_proc_stmt_unlabeled
        | sp_proc_stmt_leave
        | sp_proc_stmt_iterate
        | sp_proc_stmt_open
        | sp_proc_stmt_fetch
        | sp_proc_stmt_close
        ;
%endif

sp_proc_stmt_if:
          IF
          { Lex->sphead->m_parser_data.new_cont_backpatch(); }
          sp_if END IF
          {
            sp_head *sp= Lex->sphead;

            sp->m_parser_data.do_cont_backpatch(sp->instructions());
          }
        ;

sp_proc_stmt_statement:
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
            sp->m_parser_data.set_current_stmt_start_ptr(yylloc.raw.start);
          }
          simple_statement
          {
            if ($2 != nullptr)
              MAKE_CMD($2);

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->m_flags|= sp_get_flags_for_command(lex);
            if (lex->sql_command == SQLCOM_CHANGE_DB)
            { /* "USE db" doesn't work in a procedure */
              my_error(ER_SP_BADSTATEMENT, MYF(0), "USE");
              MYSQL_YYABORT;
            }

            // Mark statement as belonging to a stored procedure:
            if (lex->m_sql_cmd != NULL)
              lex->m_sql_cmd->set_as_part_of_sp();

            /*
              Don't add an instruction for SET statements, since all
              instructions for them were already added during processing
              of "set" rule.
            */
            assert((lex->sql_command != SQLCOM_SET_OPTION &&
                         lex->sql_command != SQLCOM_SET_PASSWORD) ||
                        lex->var_list.is_empty());
            if (lex->sql_command != SQLCOM_SET_OPTION &&
                lex->sql_command != SQLCOM_SET_PASSWORD)
            {
              /* Extract the query statement from the tokenizer. */

              LEX_CSTRING query=
                make_string(thd,
                            sp->m_parser_data.get_current_stmt_start_ptr(),
                            @2.raw.end);

              if (!query.str)
                MYSQL_YYABORT;

              /* Add instruction. */

              sp_instr_stmt *i=
                NEW_PTN sp_instr_stmt(sp->instructions(), lex, query);

              if (!i || sp->add_instr(thd, i))
                MYSQL_YYABORT;
            }

            if (sp->restore_lex(thd))
              MYSQL_YYABORT;
          }
%ifdef SQL_MODE_ORACLE
        | ora_set_statement
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
            sp->m_parser_data.set_current_stmt_start_ptr(yylloc.raw.start);

            sp->m_flags|= sp_get_flags_for_command(lex);

            // Mark statement as belonging to a stored procedure:
            if (lex->m_sql_cmd != NULL)
              lex->m_sql_cmd->set_as_part_of_sp();

            assert(lex->var_list.is_empty());
            if (sp->restore_lex(thd))
              MYSQL_YYABORT;
          }
        ;
%endif
        ;

sp_proc_stmt_return:
          RETURN_SYM    /*$1*/
          {             /*$2*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr          /*$3*/
          {             /*$4*/
            ITEMIZE($3, &$3);

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            /* Extract expression string. */

            LEX_CSTRING expr_query= EMPTY_CSTR;

            const char *expr_start_ptr= @1.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @3.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }

            /* Check that this is a stored function. */

            if (sp->m_type != enum_sp_type::FUNCTION)
            {
              my_error(ER_SP_BADRETURN, MYF(0));
              MYSQL_YYABORT;
            }

            /* Indicate that we've reached RETURN statement. */

            sp->m_flags|= sp_head::HAS_RETURN;

            /* Add instruction. */

            sp_instr_freturn *i=
              NEW_PTN sp_instr_freturn(sp->instructions(), lex, $3, expr_query,
                                       sp->m_return_field_def.sql_type);

            if (i == NULL ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
%ifdef SQL_MODE_ORACLE
        | RETURN_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            if (sp->m_type != enum_sp_type::PROCEDURE)
            {
              my_error(ER_SP_BAD_RETURN_PROC, MYF(0));
              MYSQL_YYABORT;
            }

            auto *i= NEW_PTN sp_instr_preturn(sp->instructions(), lex);
            if (i == nullptr || sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
%endif
        ;

%ifndef SQL_MODE_ORACLE
sp_proc_stmt_unlabeled:
          { /* Unlabeled controls get a secret label. */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            pctx->push_label(thd,
                             EMPTY_CSTR,
                             sp->instructions());
          }
          sp_unlabeled_control
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp->m_parser_data.do_backpatch(pctx->pop_label(),
                                           sp->instructions());
          }
        ;
%endif

sp_proc_stmt_leave:
          LEAVE_SYM label_ident
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp = lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($2);

            if (! lab)
            {
              lab= pctx->find_goto_label($2, true);
              if(lab)
                my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                  "LEAVE label except in loop statement or begin end statement");
              else
                my_error(ER_SP_LILABEL_MISMATCH, MYF(0), "LEAVE", $2.str);
              MYSQL_YYABORT;
            }

            uint ip= sp->instructions();

            /*
              When jumping to a BEGIN-END block end, the target jump
              points to the block hpop/cpop cleanup instructions,
              so we should exclude the block context here.
              When jumping to something else (i.e., sp_label::ITERATION),
              there are no hpop/cpop at the jump destination,
              so we should include the block context here for cleanup.
            */
            bool exclusive= (lab->type == sp_label::BEGIN);

            size_t n= pctx->diff_handlers(lab->ctx, exclusive);

            if (n)
            {
              sp_instr_hpop *hpop= NEW_PTN sp_instr_hpop(ip++, pctx);

              if (!hpop || sp->add_instr(thd, hpop))
                MYSQL_YYABORT;
            }

            n= pctx->diff_cursors(lab->ctx, exclusive);

            if (n)
            {
              sp_instr_cpop *cpop= NEW_PTN sp_instr_cpop(ip++, pctx, n);

              if (!cpop || sp->add_instr(thd, cpop))
                MYSQL_YYABORT;
            }

            sp_instr_jump *i= NEW_PTN sp_instr_jump(ip, pctx);

            if (!i ||
                /* Jumping forward */
                sp->m_parser_data.add_backpatch_entry(i, lab) ||
                sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        ;

sp_proc_stmt_iterate:
          ITERATE_SYM label_ident
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($2);

            if (! lab || lab->type != sp_label::ITERATION)
            {
              my_error(ER_SP_LILABEL_MISMATCH, MYF(0), "ITERATE", $2.str);
              MYSQL_YYABORT;
            }

            uint ip= sp->instructions();

            /* Inclusive the dest. */
            size_t n= pctx->diff_handlers(lab->ctx, false);

            if (n)
            {
              sp_instr_hpop *hpop= NEW_PTN sp_instr_hpop(ip++, pctx);

              if (!hpop || sp->add_instr(thd, hpop))
                MYSQL_YYABORT;
            }

            /* Inclusive the dest. */
            n= pctx->diff_cursors(lab->ctx, false);

            if (n)
            {
              sp_instr_cpop *cpop= NEW_PTN sp_instr_cpop(ip++, pctx, n);

              if (!cpop || sp->add_instr(thd, cpop))
                MYSQL_YYABORT;
            }

            /* Jump back */
            sp_instr_jump *i= NEW_PTN sp_instr_jump(ip, pctx, lab->ip);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        ;

%ifndef SQL_MODE_ORACLE
sp_proc_stmt_open:
          OPEN_SYM ident
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offset= 0;

            if (! pctx->find_cursor($2, &offset, false))
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $2.str);
              MYSQL_YYABORT;
            }

            sp_instr_copen *i= NEW_PTN sp_instr_copen(sp->instructions(), pctx,
                                                      offset);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        ;

sp_proc_stmt_fetch:
          FETCH_SYM sp_opt_fetch_noise ident INTO
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offset= 0;

            if (! pctx->find_cursor($3, &offset, false))
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $3.str);
              MYSQL_YYABORT;
            }

            sp_instr_cfetch *i= NEW_PTN sp_instr_cfetch(sp->instructions(),
                                                        pctx, offset);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
          sp_fetch_list
          {}
        ;
%endif

sp_proc_stmt_close:
          CLOSE_SYM ident
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offset= 0;

            if (! pctx->find_cursor($2, &offset, false))
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $2.str);
              MYSQL_YYABORT;
            }

            sp_instr_cclose *i=
              NEW_PTN sp_instr_cclose(sp->instructions(), pctx, offset);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            sp_variable *spvar= pctx->find_variable($2.str, $2.length, false);
            if (spvar && spvar->field_def.ora_record.is_ref_cursor)
            {
              i->set_sysrefcursor_spvar(spvar);
            }
          }
        ;

%ifndef SQL_MODE_ORACLE
sp_opt_fetch_noise:
          /* Empty */
        | NEXT_SYM FROM
        | FROM
        ;
%endif

sp_fetch_list:
          ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_variable *spv;

            if (!pctx || !(spv= pctx->find_variable($1.str, $1.length, false)))
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            if(spv->field_def.ora_record.is_ref_cursor_define) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "the type of variable used in 'into list'");
              MYSQL_YYABORT;
            }
            /* An SP local variable */
            sp_instr_cfetch *i= (sp_instr_cfetch *)sp->last_instruction();

            i->add_to_varlist(spv);
          }
        | sp_fetch_list ',' ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_variable *spv;

            if (!pctx || !(spv= pctx->find_variable($3.str, $3.length, false)))
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $3.str);
              MYSQL_YYABORT;
            }

            /* An SP local variable */
            sp_instr_cfetch *i= (sp_instr_cfetch *)sp->last_instruction();

            i->add_to_varlist(spv);
          }
        ;

sp_if:
          {                     /*$1*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr                  /*$2*/
          {                     /*$3*/
            ITEMIZE($2, &$2);

            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            /* Extract expression string. */

            LEX_CSTRING expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @0.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @2.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }

            sp_instr_jump_if_not *i =
              NEW_PTN sp_instr_jump_if_not(sp->instructions(), lex,
                                           $2, expr_query);

            /* Add jump instruction. */

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(
                  i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
            if (Lex->sp_if_sp_block_init(YYTHD))
              MYSQL_YYABORT;
          }
          THEN_SYM              /*$4*/
          sp_proc_stmts1        /*$5*/
          {                     /*$6*/
            Lex->sp_if_sp_block_finalize(YYTHD);
            
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_instr_jump *i = NEW_PTN sp_instr_jump(sp->instructions(), pctx);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            sp->m_parser_data.do_backpatch(pctx->pop_label(),
                                           sp->instructions());

            sp->m_parser_data.add_backpatch_entry(
              i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions()));
          }
          sp_elseifs            /*$7*/
          {                     /*$8*/
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp->m_parser_data.do_backpatch(pctx->pop_label(),
                                           sp->instructions());
          }
        ;

%ifndef SQL_MODE_ORACLE
sp_elseifs:
          /* Empty */
        | ELSEIF_SYM sp_if
        | ELSE sp_proc_stmts1
        ;
%endif

case_stmt_specification:
          simple_case_stmt
        | searched_case_stmt
        ;

simple_case_stmt:
          CASE_SYM                      /*$1*/
          {                             /*$2*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            case_stmt_action_case(thd);

            sp->reset_lex(thd); /* For CASE-expr $3 */
          }
          expr                          /*$3*/
          {                             /*$4*/
            ITEMIZE($3, &$3);

            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            /* Extract CASE-expression string. */

            LEX_CSTRING case_expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @1.raw.end;

            if (lex->is_metadata_used())
            {
              case_expr_query= make_string(thd, expr_start_ptr, @3.raw.end);
              if (!case_expr_query.str)
                MYSQL_YYABORT;
            }

            /* Register new CASE-expression and get its id. */

            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            int case_expr_id= pctx->push_case_expr_id();

            if (case_expr_id < 0)
              MYSQL_YYABORT;

            /* Add CASE-set instruction. */

            sp_instr_set_case_expr *i=
              NEW_PTN sp_instr_set_case_expr(sp->instructions(), lex,
                                             case_expr_id, $3, case_expr_query);

            if (i == NULL ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
          simple_when_clause_list       /*$5*/
          else_clause_opt               /*$6*/
          END                           /*$7*/
          CASE_SYM                      /*$8*/
          {                             /*$9*/
            case_stmt_action_end_case(Lex, true);
          }
        ;

searched_case_stmt:
          CASE_SYM
          {
            case_stmt_action_case(YYTHD);
          }
          searched_when_clause_list
          else_clause_opt
          END
          CASE_SYM
          {
            case_stmt_action_end_case(Lex, false);
          }
        ;

simple_when_clause_list:
          simple_when_clause
        | simple_when_clause_list simple_when_clause
        ;

searched_when_clause_list:
          searched_when_clause
        | searched_when_clause_list searched_when_clause
        ;

simple_when_clause:
          WHEN_SYM                      /*$1*/
          {                             /*$2*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr                          /*$3*/
          {                             /*$4*/
            /* Simple case: <caseval> = <whenval> */

            ITEMIZE($3, &$3);

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            /* Extract expression string. */

            LEX_CSTRING when_expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @1.raw.end;

            if (lex->is_metadata_used())
            {
              when_expr_query= make_string(thd, expr_start_ptr, @3.raw.end);
              if (!when_expr_query.str)
                MYSQL_YYABORT;
            }

            /* Add CASE-when-jump instruction. */

            sp_instr_jump_case_when *i =
              NEW_PTN sp_instr_jump_case_when(sp->instructions(), lex,
                                              pctx->get_current_case_expr_id(),
                                              $3, when_expr_query);

            if (i == NULL ||
                i->on_after_expr_parsing(thd) ||
                sp->m_parser_data.add_backpatch_entry(
                  i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
          THEN_SYM                      /*$5*/
          sp_proc_stmts1                /*$6*/
          {                             /*$7*/
            if (case_stmt_action_then(YYTHD, Lex))
              MYSQL_YYABORT;
          }
        ;

searched_when_clause:
          WHEN_SYM                      /*$1*/
          {                             /*$2*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr                          /*$3*/
          {                             /*$4*/
            ITEMIZE($3, &$3);

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            /* Extract expression string. */

            LEX_CSTRING when_query= EMPTY_CSTR;
            const char *expr_start_ptr= @1.raw.end;

            if (lex->is_metadata_used())
            {
              when_query= make_string(thd, expr_start_ptr, @3.raw.end);
              if (!when_query.str)
                MYSQL_YYABORT;
            }

            /* Add jump instruction. */

            sp_instr_jump_if_not *i=
              NEW_PTN sp_instr_jump_if_not(sp->instructions(), lex, $3,
                                           when_query);

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(
                  i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
          THEN_SYM                      /*$6*/
          sp_proc_stmts1                /*$7*/
          {                             /*$8*/
            if (case_stmt_action_then(YYTHD, Lex))
              MYSQL_YYABORT;
          }
        ;

else_clause_opt:
          /* empty */
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_instr_error *i=
              NEW_PTN
                sp_instr_error(sp->instructions(), pctx, ER_SP_CASE_NOT_FOUND);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        | ELSE sp_proc_stmts1
        ;

%ifndef SQL_MODE_ORACLE
sp_labeled_control:
          label_ident ':'
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($1);

            if (lab)
            {
              my_error(ER_SP_LABEL_REDEFINE, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            else
            {
              lab= pctx->push_label(YYTHD, $1, sp->instructions());
              lab->type= sp_label::ITERATION;
            }
          }
          sp_unlabeled_control sp_opt_label
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->pop_label();

            if ($5.str)
            {
              if (my_strcasecmp(system_charset_info, $5.str, lab->name.str) != 0)
              {
                my_error(ER_SP_LABEL_MISMATCH, MYF(0), $5.str);
                MYSQL_YYABORT;
              }
            }
            sp->m_parser_data.do_backpatch(lab, sp->instructions());
          }
        ;
%endif

sp_opt_label:
          /* Empty  */  { $$= NULL_CSTR; }
        | label_ident   { $$= $1; }
        ;

%ifndef SQL_MODE_ORACLE
sp_labeled_block:
          label_ident ':'
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($1);

            if (lab)
            {
              my_error(ER_SP_LABEL_REDEFINE, MYF(0), $1.str);
              MYSQL_YYABORT;
            }

            lab= pctx->push_label(YYTHD, $1, sp->instructions());
            lab->type= sp_label::BEGIN;
          }
          sp_block_content sp_opt_label
          {
            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->pop_label();

            if ($5.str)
            {
              if (my_strcasecmp(system_charset_info, $5.str, lab->name.str) != 0)
              {
                my_error(ER_SP_LABEL_MISMATCH, MYF(0), $5.str);
                MYSQL_YYABORT;
              }
            }
          }
        ;

sp_unlabeled_block:
          { /* Unlabeled blocks get a secret label. */
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_label *lab=
              pctx->push_label(YYTHD, EMPTY_CSTR, sp->instructions());

            lab->type= sp_label::BEGIN;
          }
          sp_block_content
          {
            LEX *lex= Lex;
            lex->get_sp_current_parsing_ctx()->pop_label();
          }
        ;

sp_block_content:
          BEGIN_SYM
          {
            Lex->sp_block_init(YYTHD);
          }
          sp_decls
          sp_proc_stmts
          END
          {
            if (Lex->sp_block_finalize(YYTHD, $3))
              MYSQL_YYABORT;
          }
        ;
%endif

sp_unlabeled_control:
          LOOP_SYM
          sp_proc_stmts1 END LOOP_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_instr_jump *i= NEW_PTN sp_instr_jump(sp->instructions(), pctx,
                                                    pctx->last_label()->ip);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        | WHILE_SYM                     /*$1*/
          {                             /*$2*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr                          /*$3*/
          {                             /*$4*/
            ITEMIZE($3, &$3);

            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            /* Extract expression string. */

            LEX_CSTRING expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @1.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @3.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }

            /* Add jump instruction. */

            sp_instr_jump_if_not *i=
              NEW_PTN
                sp_instr_jump_if_not(sp->instructions(), lex, $3, expr_query);

            if (i == NULL ||
                /* Jumping forward */
                sp->m_parser_data.add_backpatch_entry(i, pctx->last_label()) ||
                sp->m_parser_data.new_cont_backpatch() ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
%ifndef SQL_MODE_ORACLE
          DO_SYM                        /*$5*/
%else
          LOOP_SYM                     /*$5*/
%endif
          sp_proc_stmts1                /*$6*/
          END                           /*$7*/
%ifndef SQL_MODE_ORACLE
          WHILE_SYM                     /*$8*/
%else
          LOOP_SYM                     /*$8*/
%endif
          {                             /*$9*/
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_instr_jump *i= NEW_PTN sp_instr_jump(sp->instructions(), pctx,
                                                    pctx->last_label()->ip);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            sp->m_parser_data.do_cont_backpatch(sp->instructions());
          }
%ifndef SQL_MODE_ORACLE
        | REPEAT_SYM                    /*$1*/
          sp_proc_stmts1                /*$2*/
          UNTIL_SYM                     /*$3*/
          {                             /*$4*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr                          /*$5*/
          {                             /*$6*/
            ITEMIZE($5, &$5);

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint ip= sp->instructions();

            /* Extract expression string. */

            LEX_CSTRING expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @3.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @5.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }

            /* Add jump instruction. */

            sp_instr_jump_if_not *i=
              NEW_PTN sp_instr_jump_if_not(ip, lex, $5, expr_query,
                                           pctx->last_label()->ip);

            if (i == NULL ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }

            /* We can shortcut the cont_backpatch here */
            i->set_cont_dest(ip + 1);
          }
          END                           /*$7*/
          REPEAT_SYM                    /*$8*/
%endif
        ;

trg_action_time:
            BEFORE_SYM
            { $$= TRG_ACTION_BEFORE; }
          | AFTER_SYM
            { $$= TRG_ACTION_AFTER; }
          ;

trg_or_event:
              trg_event
              {  $$= $1; }
%ifdef SQL_MODE_ORACLE
            | trg_event OR_SYM trg_event
              {
                if ((($1 == TRG_EVENT_INSERT) && ($3 == TRG_EVENT_UPDATE)) || (($1 == TRG_EVENT_UPDATE) && ($3 == TRG_EVENT_INSERT)))
                  $$= TRG_EVENT_INSERT_UPDATE;
                else if ((($1 == TRG_EVENT_INSERT) && ($3 == TRG_EVENT_DELETE)) || (($1 == TRG_EVENT_DELETE) && ($3 == TRG_EVENT_INSERT)))
                  $$= TRG_EVENT_INSERT_DELETE;
                else if ((($1 == TRG_EVENT_UPDATE) && ($3 == TRG_EVENT_DELETE)) || (($1 == TRG_EVENT_DELETE) && ($3 == TRG_EVENT_UPDATE)))
                  $$= TRG_EVENT_UPDATE_DELETE;
                else
                {
                    const char * errinfo= YYTHD->strmake(@1.raw.start,@3.raw.end - @1.raw.start);
                    my_error(ER_WRONG_VALUE, MYF(0), "Unsupported syntax ", errinfo);
                    MYSQL_YYABORT;
                }
              }
            | trg_event OR_SYM trg_event OR_SYM trg_event
              {
                if (($1 != $3) && ($1 != $5) && ($3 != $5))
                  $$= TRG_EVENT_INSERT_UPDATE_DELETE;
                else
                {
                    const char * errinfo= YYTHD->strmake(@1.raw.start,@5.raw.end - @1.raw.start);
                    my_error(ER_WRONG_VALUE, MYF(0), "Unsupported syntax ", errinfo);
                    MYSQL_YYABORT;
                }
              }
%endif
            ;
trg_event:
            INSERT_SYM
            { $$= TRG_EVENT_INSERT; }
          | UPDATE_SYM
            { $$= TRG_EVENT_UPDATE; }
          | DELETE_SYM
            { $$= TRG_EVENT_DELETE; }
          ;
/*
  This part of the parser contains common code for all TABLESPACE
  commands.
  CREATE TABLESPACE_SYM name ...
  ALTER TABLESPACE_SYM name ADD DATAFILE ...
  CREATE LOGFILE GROUP_SYM name ...
  ALTER LOGFILE GROUP_SYM name ADD UNDOFILE ..
  DROP TABLESPACE_SYM name
  DROP LOGFILE GROUP_SYM name
*/

opt_ts_datafile_name:
    /* empty */ { $$= { nullptr, 0}; }
    | ADD ts_datafile
      {
        $$ = $2;
      }
    ;

opt_logfile_group_name:
          /* empty */ { $$= { nullptr, 0}; }
        | USE_SYM LOGFILE_SYM GROUP_SYM ident
          {
            $$= $4;
          }
        ;

opt_tablespace_options:
          /* empty */ { $$= NULL; }
        | tablespace_option_list
        ;

tablespace_option_list:
          tablespace_option
          {
            $$= NEW_PTN Mem_root_array<PT_alter_tablespace_option_base*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        | tablespace_option_list opt_comma tablespace_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        ;

tablespace_option:
          ts_option_initial_size
        | ts_option_autoextend_size
        | ts_option_max_size
        | ts_option_extent_size
        | ts_option_nodegroup
        | ts_option_engine
        | ts_option_wait
        | ts_option_comment
        | ts_option_file_block_size
        | ts_option_encryption
        | ts_option_engine_attribute
        ;

opt_alter_tablespace_options:
          /* empty */ { $$= NULL; }
        | alter_tablespace_option_list
        ;

alter_tablespace_option_list:
          alter_tablespace_option
          {
            $$= NEW_PTN Mem_root_array<PT_alter_tablespace_option_base*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        | alter_tablespace_option_list opt_comma alter_tablespace_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        ;

alter_tablespace_option:
          ts_option_initial_size
        | ts_option_autoextend_size
        | ts_option_max_size
        | ts_option_engine
        | ts_option_wait
        | ts_option_encryption
        | ts_option_engine_attribute
        ;

opt_undo_tablespace_options:
          /* empty */ { $$= NULL; }
        | undo_tablespace_option_list
        ;

undo_tablespace_option_list:
          undo_tablespace_option
          {
            $$= NEW_PTN Mem_root_array<PT_alter_tablespace_option_base*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | undo_tablespace_option_list opt_comma undo_tablespace_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

undo_tablespace_option:
          ts_option_engine
        ;

opt_logfile_group_options:
          /* empty */ { $$= NULL; }
        | logfile_group_option_list
        ;

logfile_group_option_list:
          logfile_group_option
          {
            $$= NEW_PTN Mem_root_array<PT_alter_tablespace_option_base*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        | logfile_group_option_list opt_comma logfile_group_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        ;

logfile_group_option:
          ts_option_initial_size
        | ts_option_undo_buffer_size
        | ts_option_redo_buffer_size
        | ts_option_nodegroup
        | ts_option_engine
        | ts_option_wait
        | ts_option_comment
        ;

opt_alter_logfile_group_options:
          /* empty */ { $$= NULL; }
        | alter_logfile_group_option_list
        ;

alter_logfile_group_option_list:
          alter_logfile_group_option
          {
            $$= NEW_PTN Mem_root_array<PT_alter_tablespace_option_base*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        | alter_logfile_group_option_list opt_comma alter_logfile_group_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        ;

alter_logfile_group_option:
          ts_option_initial_size
        | ts_option_engine
        | ts_option_wait
        ;

ts_datafile:
          DATAFILE_SYM TEXT_STRING_sys { $$= $2; }
        ;

undo_tablespace_state:
          ACTIVE_SYM   { $$= ALTER_UNDO_TABLESPACE_SET_ACTIVE; }
        | INACTIVE_SYM { $$= ALTER_UNDO_TABLESPACE_SET_INACTIVE; }
        ;

lg_undofile:
          UNDOFILE_SYM TEXT_STRING_sys { $$= $2; }
        ;

ts_option_initial_size:
          INITIAL_SIZE_SYM opt_equal size_number
          {
            $$= NEW_PTN PT_alter_tablespace_option_initial_size($3);
          }
        ;

ts_option_autoextend_size:
          option_autoextend_size
          {
            $$ = NEW_PTN PT_alter_tablespace_option_autoextend_size($1);
          }
        ;

option_autoextend_size:
          AUTOEXTEND_SIZE_SYM opt_equal size_number { $$ = $3; }
	;

ts_option_max_size:
          MAX_SIZE_SYM opt_equal size_number
          {
            $$= NEW_PTN PT_alter_tablespace_option_max_size($3);
          }
        ;

ts_option_extent_size:
          EXTENT_SIZE_SYM opt_equal size_number
          {
            $$= NEW_PTN PT_alter_tablespace_option_extent_size($3);
          }
        ;

ts_option_undo_buffer_size:
          UNDO_BUFFER_SIZE_SYM opt_equal size_number
          {
            $$= NEW_PTN PT_alter_tablespace_option_undo_buffer_size($3);
          }
        ;

ts_option_redo_buffer_size:
          REDO_BUFFER_SIZE_SYM opt_equal size_number
          {
            $$= NEW_PTN PT_alter_tablespace_option_redo_buffer_size($3);
          }
        ;

ts_option_nodegroup:
          NODEGROUP_SYM opt_equal real_ulong_num
          {
            $$= NEW_PTN PT_alter_tablespace_option_nodegroup($3);
          }
        ;

ts_option_comment:
          COMMENT_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_alter_tablespace_option_comment($3);
          }
        ;

ts_option_engine:
          opt_storage ENGINE_SYM opt_equal ident_or_text
          {
            $$= NEW_PTN PT_alter_tablespace_option_engine(to_lex_cstring($4));
          }
        ;

ts_option_file_block_size:
          FILE_BLOCK_SIZE_SYM opt_equal size_number
          {
            $$= NEW_PTN PT_alter_tablespace_option_file_block_size($3);
          }
        ;

ts_option_wait:
          WAIT_SYM
          {
            $$= NEW_PTN PT_alter_tablespace_option_wait_until_completed(true);
          }
        | NO_WAIT_SYM
          {
            $$= NEW_PTN PT_alter_tablespace_option_wait_until_completed(false);
          }
        ;

ts_option_encryption:
          ENCRYPTION_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_alter_tablespace_option_encryption($3);
          }
        ;

ts_option_engine_attribute:
          ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_tablespace_engine_attribute(YYMEM_ROOT, $3);
          }
        ;

size_number:
          real_ulonglong_num { $$= $1;}
        | IDENT_sys
          {
            ulonglong number;
            uint text_shift_number= 0;
            longlong prefix_number;
            const char *start_ptr= $1.str;
            size_t str_len= $1.length;
            const char *end_ptr= start_ptr + str_len;
            int error;
            prefix_number= my_strtoll10(start_ptr, &end_ptr, &error);
            if ((start_ptr + str_len - 1) == end_ptr)
            {
              switch (end_ptr[0])
              {
                case 'g':
                case 'G':
                  text_shift_number+=10;
                  [[fallthrough]];
                case 'm':
                case 'M':
                  text_shift_number+=10;
                  [[fallthrough]];
                case 'k':
                case 'K':
                  text_shift_number+=10;
                  break;
                default:
                {
                  my_error(ER_WRONG_SIZE_NUMBER, MYF(0));
                  MYSQL_YYABORT;
                }
              }
              if (prefix_number >> 31)
              {
                my_error(ER_SIZE_OVERFLOW_ERROR, MYF(0));
                MYSQL_YYABORT;
              }
              number= prefix_number << text_shift_number;
            }
            else
            {
              my_error(ER_WRONG_SIZE_NUMBER, MYF(0));
              MYSQL_YYABORT;
            }
            $$= number;
          }
        ;

/*
  End tablespace part
*/

/*
  To avoid grammar conflicts, we introduce the next few rules in very details:
  we workaround empty rules for optional AS and DUPLICATE clauses by expanding
  them in place of the caller rule:

  opt_create_table_options_etc ::=
    create_table_options opt_create_partitioning_etc
  | opt_create_partitioning_etc

  opt_create_partitioning_etc ::=
    partitioin [opt_duplicate_as_qe] | [opt_duplicate_as_qe]

  opt_duplicate_as_qe ::=
    duplicate as_create_query_expression
  | as_create_query_expression

  as_create_query_expression ::=
    AS query_expression_with_opt_locking_clauses
  | query_expression_with_opt_locking_clauses

*/

opt_create_table_options_etc:
          create_table_options
          opt_create_partitioning_etc
          {
            $$= $2;
            $$.opt_create_table_options= $1;
          }
        | ORGANIZATION_SYM EXTERNAL_SYM '(' external_table_clause ')'
          {
            $$.opt_create_table_options= $4;
            $$.opt_partitioning= NULL;
            $$.on_duplicate= On_duplicate::ERROR;
            $$.opt_query_expression= NULL;
          }
        | opt_create_partitioning_etc
        ;

external_table_clause:
          opt_default_external_dir LOCATION_SYM '(' external_table_location ')'
          {
            auto engine= NEW_PTN PT_create_table_engine_option({STRING_WITH_LEN("dlk")});
            if(!engine) 
              MYSQL_YYABORT;
            $$= NEW_PTN Mem_root_array<PT_create_table_option *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($4)|| $$->push_back(engine))
              MYSQL_YYABORT;

            if($1) {
              if($$->push_back($1))
                MYSQL_YYABORT;
            }
          }
        ;

opt_default_external_dir:
          /* empty */ 
          {
            $$= nullptr;
          }
        | DEFAULT_SYM DIRECTORY_SYM TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_data_directory_option($3.str);
          }
        ;

external_table_location:
          TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_external_file_name($1.str);
          }
        | TEXT_STRING_sys ':' TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_external_dir_file_name($1 ,$3);
          }
        ;

opt_create_partitioning_etc:
          partition_clause opt_duplicate_as_qe
          {
            $$= $2;
            $$.opt_partitioning= $1;
          }
        | opt_duplicate_as_qe
        ;

opt_duplicate_as_qe:
          /* empty */
          {
            $$.opt_create_table_options= NULL;
            $$.opt_partitioning= NULL;
            $$.on_duplicate= On_duplicate::ERROR;
            $$.opt_query_expression= NULL;
          }
        | duplicate
          as_create_query_expression
          {
            $$.opt_create_table_options= NULL;
            $$.opt_partitioning= NULL;
            $$.on_duplicate= $1;
            $$.opt_query_expression= $2;
          }
        | as_create_query_expression
          {
            $$.opt_create_table_options= NULL;
            $$.opt_partitioning= NULL;
            $$.on_duplicate= On_duplicate::ERROR;
            $$.opt_query_expression= $1;
          }
        ;

as_create_query_expression:
          AS query_expression_with_opt_locking_clauses { $$ = $2; }
        | query_expression_with_opt_locking_clauses    { $$ = $1; }
        ;

/*
 This part of the parser is about handling of the partition information.

 It's first version was written by Mikael Ronström with lots of answers to
 questions provided by Antony Curtis.

 The partition grammar can be called from two places.
 1) CREATE TABLE ... PARTITION ..
 2) ALTER TABLE table_name PARTITION ...
*/
partition_clause:
          PARTITION_SYM BY part_type_def opt_num_parts opt_sub_part
          opt_part_defs
          {
            $$= NEW_PTN PT_partition($3, $4, $5, @6, $6);
          }
        ;

part_type_def:
          opt_linear KEY_SYM opt_key_algo '(' opt_name_list ')'
          {
            $$= NEW_PTN PT_part_type_def_key($1, $3, $5);
          }
        | opt_linear HASH_SYM '(' bit_expr ')'
          {
            $$= NEW_PTN PT_part_type_def_hash($1, @4, $4);
          }
        | RANGE_SYM '(' bit_expr ')'
          {
            $$= NEW_PTN PT_part_type_def_range_expr(@3, $3);
          }
        | RANGE_SYM COLUMNS '(' name_list ')'
          {
            $$= NEW_PTN PT_part_type_def_range_columns($4);
          }
        | LIST_SYM '(' bit_expr ')'
          {
            $$= NEW_PTN PT_part_type_def_list_expr(@3, $3);
          }
        | LIST_SYM COLUMNS '(' name_list ')'
          {
            $$= NEW_PTN PT_part_type_def_list_columns($4);
          }
        ;

opt_linear:
          /* empty */ { $$= false; }
        | LINEAR_SYM  { $$= true; }
        ;

opt_key_algo:
          /* empty */
          { $$= enum_key_algorithm::KEY_ALGORITHM_NONE; }
        | ALGORITHM_SYM EQ real_ulong_num
          {
            switch ($3) {
            case 1:
              $$= enum_key_algorithm::KEY_ALGORITHM_51;
              break;
            case 2:
              $$= enum_key_algorithm::KEY_ALGORITHM_55;
              break;
            default:
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
          }
        ;

opt_num_parts:
          /* empty */
          { $$= 0; }
        | PARTITIONS_SYM real_ulong_num
          {
            if ($2 == 0)
            {
              my_error(ER_NO_PARTS_ERROR, MYF(0), "partitions");
              MYSQL_YYABORT;
            }
            $$= $2;
          }
        ;

opt_sub_part:
          /* empty */ { $$= NULL; }
        | SUBPARTITION_SYM BY opt_linear HASH_SYM '(' bit_expr ')'
          opt_num_subparts
          {
            $$= NEW_PTN PT_sub_partition_by_hash($3, @6, $6, $8);
          }
        | SUBPARTITION_SYM BY opt_linear KEY_SYM opt_key_algo
          '(' name_list ')' opt_num_subparts
          {
            $$= NEW_PTN PT_sub_partition_by_key($3, $5, $7, $9);
          }
        ;


opt_name_list:
          /* empty */ { $$= NULL; }
        | name_list
        ;


name_list:
          ident
          {
            $$= NEW_PTN List<char>;
            if ($$ == NULL || $$->push_back($1.str))
              MYSQL_YYABORT;
          }
        | name_list ',' ident
          {
            $$= $1;
            if ($$->push_back($3.str))
              MYSQL_YYABORT;
          }
        ;

opt_num_subparts:
          /* empty */
          { $$= 0; }
        | SUBPARTITIONS_SYM real_ulong_num
          {
            if ($2 == 0)
            {
              my_error(ER_NO_PARTS_ERROR, MYF(0), "subpartitions");
              MYSQL_YYABORT;
            }
            $$= $2;
          }
        ;

opt_part_defs:
          /* empty */           { $$= NULL; }
        | '(' part_def_list ')' { $$= $2; }
        ;

part_def_list:
          part_definition
          {
            $$= NEW_PTN Mem_root_array<PT_part_definition*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | part_def_list ',' part_definition
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

part_definition:
          PARTITION_SYM ident opt_part_values opt_part_options opt_sub_partition
          {
            $$= NEW_PTN PT_part_definition(@0, $2, $3.type, $3.values, @3,
                                           $4, $5, @5);
          }
        ;

opt_part_values:
          /* empty */
          {
            $$.type= partition_type::HASH;
          }
        | VALUES LESS_SYM THAN_SYM part_func_max
          {
            $$.type= partition_type::RANGE;
            $$.values= $4;
          }
        | VALUES IN_SYM part_values_in
          {
            $$.type= partition_type::LIST;
            $$.values= $3;
          }
        ;

part_func_max:
          MAX_VALUE_SYM   { $$= NULL; }
        | part_value_item_list_paren
        ;

part_values_in:
          part_value_item_list_paren
          {
            $$= NEW_PTN PT_part_values_in_item(@1, $1);
          }
        | '(' part_value_list ')'
          {
            $$= NEW_PTN PT_part_values_in_list(@3, $2);
          }
        ;

part_value_list:
          part_value_item_list_paren
          {
            $$= NEW_PTN
              Mem_root_array<PT_part_value_item_list_paren *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | part_value_list ',' part_value_item_list_paren
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

part_value_item_list_paren:
          '('
          {
            /*
              This empty action is required because it resolves 2 reduce/reduce
              conflicts with an anonymous row expression:

              simple_expr:
                        ...
                      | '(' expr ',' expr_list ')'
            */
          }
          part_value_item_list ')'
          {
            $$= NEW_PTN PT_part_value_item_list_paren($3, @4);
          }
        ;

part_value_item_list:
          part_value_item
          {
            $$= NEW_PTN Mem_root_array<PT_part_value_item *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | part_value_item_list ',' part_value_item
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

part_value_item:
          MAX_VALUE_SYM { $$= NEW_PTN PT_part_value_item_max(@1); }
        | bit_expr      { $$= NEW_PTN PT_part_value_item_expr(@1, $1); }
        ;


opt_sub_partition:
          /* empty */           { $$= NULL; }
        | '(' sub_part_list ')' { $$= $2; }
        ;

sub_part_list:
          sub_part_definition
          {
            $$= NEW_PTN Mem_root_array<PT_subpartition *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | sub_part_list ',' sub_part_definition
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

sub_part_definition:
          SUBPARTITION_SYM ident_or_text opt_part_options
          {
            $$= NEW_PTN PT_subpartition(@1, $2.str, $3);
          }
        ;

opt_part_options:
         /* empty */ { $$= NULL; }
       | part_option_list
       ;

part_option_list:
          part_option_list part_option
          {
            $$= $1;
            if ($$->push_back($2))
              MYSQL_YYABORT; // OOM
          }
        | part_option
          {
            $$= NEW_PTN Mem_root_array<PT_partition_option *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        ;

part_option:
          TABLESPACE_SYM opt_equal ident
          { $$= NEW_PTN PT_partition_tablespace($3.str); }
        | opt_storage ENGINE_SYM opt_equal ident_or_text
          { $$= NEW_PTN PT_partition_engine(to_lex_cstring($4)); }
        | NODEGROUP_SYM opt_equal real_ulong_num
          { $$= NEW_PTN PT_partition_nodegroup($3); }
        | MAX_ROWS opt_equal real_ulonglong_num
          { $$= NEW_PTN PT_partition_max_rows($3); }
        | MIN_ROWS opt_equal real_ulonglong_num
          { $$= NEW_PTN PT_partition_min_rows($3); }
        | DATA_SYM DIRECTORY_SYM opt_equal TEXT_STRING_sys
          { $$= NEW_PTN PT_partition_data_directory($4.str); }
        | INDEX_SYM DIRECTORY_SYM opt_equal TEXT_STRING_sys
          { $$= NEW_PTN PT_partition_index_directory($4.str); }
        | COMMENT_SYM opt_equal TEXT_STRING_sys
          { $$= NEW_PTN PT_partition_comment($3.str); }
        ;

/*
 End of partition parser part
*/

alter_database_options:
          alter_database_option
        | alter_database_options alter_database_option
        ;

alter_database_option:
          create_database_option
        | READ_SYM ONLY_SYM opt_equal ternary_option
          {
            /*
              If the statement has set READ ONLY already, and we repeat the
              READ ONLY option in the statement, the option must be set to
              the same value as before, otherwise, report an error.
            */
            if ((Lex->create_info->used_fields &
                 HA_CREATE_USED_READ_ONLY) &&
                (Lex->create_info->schema_read_only !=
                    ($4 == Ternary_option::ON))) {
              my_error(ER_CONFLICTING_DECLARATIONS, MYF(0), "READ ONLY", "=0",
                  "READ ONLY", "=1");
              MYSQL_YYABORT;
            }
            Lex->create_info->schema_read_only = ($4 == Ternary_option::ON);
            Lex->create_info->used_fields |= HA_CREATE_USED_READ_ONLY;
          }
        ;

opt_create_database_options:
          /* empty */ {}
        | create_database_options {}
        ;

create_database_options:
          create_database_option {}
        | create_database_options create_database_option {}
        ;

create_database_option:
          default_collation
          {
            if (set_default_collation(Lex->create_info, $1))
              MYSQL_YYABORT;
          }
        | default_charset
          {
            if (set_default_charset(Lex->create_info, $1))
              MYSQL_YYABORT;
          }
        | default_encryption
          {
            // Validate if we have either 'y|Y' or 'n|N'
            if (my_strcasecmp(system_charset_info, $1.str, "Y") != 0 &&
                my_strcasecmp(system_charset_info, $1.str, "N") != 0) {
              my_error(ER_WRONG_VALUE, MYF(0), "argument (should be Y or N)", $1.str);
              MYSQL_YYABORT;
            }

            Lex->create_info->encrypt_type= $1;
            Lex->create_info->used_fields |= HA_CREATE_USED_DEFAULT_ENCRYPTION;
          }
        ;

opt_if_not_exists:
          /* empty */   { $$= false; }
        | IF not EXISTS { $$= true; }
        ;

or_replace:
          OR_SYM REPLACE_SYM
        ;

create_table_options_space_separated:
          create_table_option
          {
            $$= NEW_PTN Mem_root_array<PT_ddl_table_option *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | create_table_options_space_separated create_table_option
          {
            $$= $1;
            if ($$->push_back($2))
              MYSQL_YYABORT; // OOM
          }
        ;

create_table_options:
          create_table_option
          {
            $$= NEW_PTN Mem_root_array<PT_create_table_option *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | create_table_options opt_comma create_table_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

opt_comma:
          /* empty */
        | ','
        ;

create_table_option:
          ENGINE_SYM opt_equal ident_or_text
          {
            $$= NEW_PTN PT_create_table_engine_option(to_lex_cstring($3));
          }
        | SECONDARY_ENGINE_SYM opt_equal NULL_SYM
          {
            $$= NEW_PTN PT_create_table_secondary_engine_option();
          }
        | SECONDARY_ENGINE_SYM opt_equal ident_or_text
          {
            $$= NEW_PTN PT_create_table_secondary_engine_option(to_lex_cstring($3));
          }
        | MAX_ROWS opt_equal ulonglong_num
          {
            $$= NEW_PTN PT_create_max_rows_option($3);
          }
        | MIN_ROWS opt_equal ulonglong_num
          {
            $$= NEW_PTN PT_create_min_rows_option($3);
          }
        | AVG_ROW_LENGTH opt_equal ulonglong_num
          {
            // The frm-format only allocated 4 bytes for avg_row_length, and
            // there is code which assumes it can be represented as an uint,
            // so we constrain it here.
            if ($3 > std::numeric_limits<std::uint32_t>::max()) {
              YYTHD->syntax_error_at(@3,
              "The valid range for avg_row_length is [0,4294967295]. Error"
              );
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PT_create_avg_row_length_option($3);
          }
        | PASSWORD opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_password_option($3.str);
          }
        | COMMENT_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_commen_option($3);
          }
        | COMPRESSION_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_compress_option($3);
          }
        | ENCRYPTION_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_encryption_option($3);
          }
        | AUTO_INC opt_equal ulonglong_num
          {
            $$= NEW_PTN PT_create_auto_increment_option($3);
          }
        | PACK_KEYS_SYM opt_equal ternary_option
          {
            $$= NEW_PTN PT_create_pack_keys_option($3);
          }
        | STATS_AUTO_RECALC_SYM opt_equal ternary_option
          {
            $$= NEW_PTN PT_create_stats_auto_recalc_option($3);
          }
        | STATS_PERSISTENT_SYM opt_equal ternary_option
          {
            $$= NEW_PTN PT_create_stats_persistent_option($3);
          }
        | STATS_SAMPLE_PAGES_SYM opt_equal ulong_num
          {
            /* From user point of view STATS_SAMPLE_PAGES can be specified as
            STATS_SAMPLE_PAGES=N (where 0<N<=65535, it does not make sense to
            scan 0 pages) or STATS_SAMPLE_PAGES=default. Internally we record
            =default as 0. See create_frm() in sql/table.cc, we use only two
            bytes for stats_sample_pages and this is why we do not allow
            larger values. 65535 pages, 16kb each means to sample 1GB, which
            is impractical. If at some point this needs to be extended, then
            we can store the higher bits from stats_sample_pages in .frm too. */
            if ($3 == 0 || $3 > 0xffff)
            {
              YYTHD->syntax_error_at(@3,
              "The valid range for stats_sample_pages is [1, 65535]. Error");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PT_create_stats_stable_pages($3);
          }
        | STATS_SAMPLE_PAGES_SYM opt_equal DEFAULT_SYM
          {
            $$= NEW_PTN PT_create_stats_stable_pages;
          }
        | CHECKSUM_SYM opt_equal ulong_num
          {
            $$= NEW_PTN PT_create_checksum_option($3);
          }
        | TABLE_CHECKSUM_SYM opt_equal ulong_num
          {
            $$= NEW_PTN PT_create_checksum_option($3);
          }
        | DELAY_KEY_WRITE_SYM opt_equal ulong_num
          {
            $$= NEW_PTN PT_create_delay_key_write_option($3);
          }
        | ROW_FORMAT_SYM opt_equal row_types
          {
            $$= NEW_PTN PT_create_row_format_option($3);
          }
        | UNION_SYM opt_equal '(' opt_table_list ')'
          {
            $$= NEW_PTN PT_create_union_option($4);
          }
        | default_charset
          {
            $$= NEW_PTN PT_create_table_default_charset($1);
          }
        | default_collation
          {
            $$= NEW_PTN PT_create_table_default_collation($1);
          }
        | INSERT_METHOD opt_equal merge_insert_types
          {
            $$= NEW_PTN PT_create_insert_method_option($3);
          }
        | DATA_SYM DIRECTORY_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_data_directory_option($4.str);
          }
        | INDEX_SYM DIRECTORY_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_index_directory_option($4.str);
          }
        | TABLESPACE_SYM opt_equal ident
          {
            $$= NEW_PTN PT_create_tablespace_option($3.str);
          }
        | STORAGE_SYM DISK_SYM
          {
            $$= NEW_PTN PT_create_storage_option(HA_SM_DISK);
          }
        | STORAGE_SYM MEMORY_SYM
          {
            $$= NEW_PTN PT_create_storage_option(HA_SM_MEMORY);
          }
        | CONNECTION_SYM opt_equal TEXT_STRING_sys
          {
            $$= NEW_PTN PT_create_connection_option($3);
          }
        | KEY_BLOCK_SIZE opt_equal ulonglong_num
          {
            // The frm-format only allocated 2 bytes for key_block_size,
            // even if it is represented as std::uint32_t in HA_CREATE_INFO and
            // elsewhere.
            if ($3 > std::numeric_limits<std::uint16_t>::max()) {
              YYTHD->syntax_error_at(@3,
              "The valid range for key_block_size is [0,65535]. Error");
              MYSQL_YYABORT;
            }

            $$= NEW_PTN
            PT_create_key_block_size_option(static_cast<std::uint32_t>($3));
          }
        | START_SYM TRANSACTION_SYM
          {
            $$= NEW_PTN PT_create_start_transaction_option(true);
	  }
        | ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_table_engine_attribute(YYMEM_ROOT, $3);
          }
        | SECONDARY_ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_table_secondary_engine_attribute(YYMEM_ROOT, $3);
          }
        | option_autoextend_size
          {
            $$ = NEW_PTN PT_create_ts_autoextend_size_option($1);
          }
        ;

ternary_option:
          ulong_num
          {
            switch($1) {
            case 0:
                $$= Ternary_option::OFF;
                break;
            case 1:
                $$= Ternary_option::ON;
                break;
            default:
                YYTHD->syntax_error();
                MYSQL_YYABORT;
            }
          }
        | DEFAULT_SYM { $$= Ternary_option::DEFAULT; }
        ;

default_charset:
          opt_default character_set opt_equal charset_name { $$ = $4; }
        ;

default_collation:
          opt_default COLLATE_SYM opt_equal collation_name { $$ = $4;}
        ;

default_encryption:
          opt_default ENCRYPTION_SYM opt_equal TEXT_STRING_sys { $$ = $4;}
        ;

row_types:
          DEFAULT_SYM    { $$= ROW_TYPE_DEFAULT; }
        | FIXED_SYM      { $$= ROW_TYPE_FIXED; }
        | DYNAMIC_SYM    { $$= ROW_TYPE_DYNAMIC; }
        | COMPRESSED_SYM { $$= ROW_TYPE_COMPRESSED; }
        | REDUNDANT_SYM  { $$= ROW_TYPE_REDUNDANT; }
        | COMPACT_SYM    { $$= ROW_TYPE_COMPACT; }
        ;

merge_insert_types:
         NO_SYM          { $$= MERGE_INSERT_DISABLED; }
       | FIRST_SYM       { $$= MERGE_INSERT_TO_FIRST; }
       | LAST_SYM        { $$= MERGE_INSERT_TO_LAST; }
       ;

udf_type:
          STRING_SYM {$$ = (int) STRING_RESULT; }
        | REAL_SYM {$$ = (int) REAL_RESULT; }
        | DECIMAL_SYM {$$ = (int) DECIMAL_RESULT; }
        | INT_SYM {$$ = (int) INT_RESULT; }
        ;

table_element_list:
          table_element
          {
            $$= NEW_PTN Mem_root_array<PT_table_element *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | table_element_list ',' table_element
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

table_element:
          column_def            { $$= $1; }
        | table_constraint_def  { $$= $1; }
        ;

column_def:
          ident field_def opt_references
          {
            $$= NEW_PTN PT_column_def($1, $2, $3);
          }
        | ident ora_udt_ident udt_default
          {
            if(!$2->table.length && !(YYTHD->variables.sql_mode & MODE_ORACLE)) {
              YYTHD->syntax_error_at(@2);
              MYSQL_YYABORT;
            }

            PT_udt_type *udt_type= NEW_PTN PT_udt_type(Char_type::VARCHAR, $2, &my_charset_bin);
            PT_field_def *field_def= NEW_PTN PT_field_def(udt_type, nullptr);
            $$= NEW_PTN PT_column_def($1, field_def, nullptr);
          }
        ;

udt_default:
          /* empty */
        | DEFAULT_SYM NULL_SYM
        ;

ora_udt_ident:
          IDENT_sys
          {
            $$= NEW_PTN Qualified_column_ident(YYTHD->db(), to_lex_cstring($1));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | IDENT_sys '.' ident
          {
            $$= NEW_PTN Qualified_column_ident(to_lex_cstring($1), to_lex_cstring($3));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

opt_references:
          /* empty */      { $$= NULL; }
        |  references
          {
            /* Currently we ignore FK references here: */
            $$= NULL;
          }
        ;

table_constraint_def:
          key_or_index opt_index_name_and_type '(' key_list_with_expression ')'
          opt_index_options
          {
            $$= NEW_PTN PT_inline_index_definition(KEYTYPE_MULTIPLE,
                                                   $2.name, $2.type, $4, $6);
          }
        | FULLTEXT_SYM opt_key_or_index opt_ident '(' key_list_with_expression ')'
          opt_fulltext_index_options
          {
            $$= NEW_PTN PT_inline_index_definition(KEYTYPE_FULLTEXT, $3, NULL,
                                                   $5, $7);
          }
        | SPATIAL_SYM opt_key_or_index opt_ident '(' key_list_with_expression ')'
          opt_spatial_index_options
          {
            $$= NEW_PTN PT_inline_index_definition(KEYTYPE_SPATIAL, $3, NULL, $5, $7);
          }
        | opt_constraint_name constraint_key_type opt_index_name_and_type
          '(' key_list_with_expression ')' opt_index_options
          {
            if (($1.length != 0)
                 && ($2 == (KEYTYPE_CLUSTERING | KEYTYPE_MULTIPLE)))
            {
              /* Forbid "CONSTRAINT c CLUSTERING" */
              my_error(ER_SYNTAX_ERROR, MYF(0));
              MYSQL_YYABORT;
            }
            /*
              Constraint-implementing indexes are named by the constraint type
              by default.
            */
            LEX_STRING name= $3.name.str != NULL ? $3.name : $1;
            $$= NEW_PTN PT_inline_index_definition($2, name, $3.type, $5, $7);
          }
        | opt_constraint_name FOREIGN KEY_SYM opt_ident '(' key_list ')' references
          {
            $$= NEW_PTN PT_foreign_key_definition($1, $4, $6, $8.table_name,
                                                  $8.reference_list,
                                                  $8.fk_match_option,
                                                  $8.fk_update_opt,
                                                  $8.fk_delete_opt);
          }
        | opt_constraint_name check_constraint opt_constraint_enforcement
          {
            $$= NEW_PTN PT_check_constraint($1, $2, $3);
            if ($$ == nullptr) MYSQL_YYABORT; // OOM
          }
        ;

check_constraint:
          CHECK_SYM '(' expr ')' { $$= $3; }
        ;

opt_constraint_name:
          /* empty */          { $$= NULL_STR; }
        | CONSTRAINT opt_ident { $$= $2; }
        ;

opt_not:
          /* empty */  { $$= false; }
        | NOT_SYM      { $$= true; }
        ;

opt_constraint_enforcement:
          /* empty */            { $$= true; }
        | constraint_enforcement { $$= $1; }
        ;

constraint_enforcement:
          opt_not ENFORCED_SYM  { $$= !($1); }
        ;

field_def:
          type opt_column_attribute_list
          {
            $$= NEW_PTN PT_field_def($1, $2);
          }
        | type opt_collate opt_generated_always
          AS '(' expr ')'
          opt_stored_attribute opt_column_attribute_list
          {
            auto *opt_attrs= $9;
            if ($2 != NULL)
            {
              if (opt_attrs == NULL)
              {
                opt_attrs= NEW_PTN
                  Mem_root_array<PT_column_attr_base *>(YYMEM_ROOT);
              }
              auto *collation= NEW_PTN PT_collate_column_attr(@2, $2);
              if (opt_attrs == nullptr || collation == nullptr ||
                  opt_attrs->push_back(collation))
                MYSQL_YYABORT; // OOM
            }
            $$= NEW_PTN PT_generated_field_def($1, $6, $8, opt_attrs);
          }
        ;

opt_generated_always:
          /* empty */
        | GENERATED ALWAYS_SYM
        ;

opt_stored_attribute:
          /* empty */ { $$= Virtual_or_stored::VIRTUAL; }
        | VIRTUAL_SYM { $$= Virtual_or_stored::VIRTUAL; }
        | STORED_SYM  { $$= Virtual_or_stored::STORED; }
        ;

type:
          int_type opt_field_length field_options
          {
            $$= NEW_PTN PT_numeric_type(YYTHD, $1, $2, $3);
          }
        | real_type opt_precision field_options
          {
            $$= NEW_PTN PT_numeric_type(YYTHD, $1, $2.length, $2.dec, $3);
          }
        | numeric_type float_options field_options
          {
            $$= NEW_PTN PT_numeric_type(YYTHD, $1, $2.length, $2.dec, $3);
          }
        | NUMBER_SYM ora_number_float_options field_options
          {
            $$= NEW_PTN PT_numeric_type(YYTHD, Numeric_type::DECIMAL, $2.length, $2.dec, $3);
          }
        | BIT_SYM %prec KEYWORD_USED_AS_KEYWORD
          {
            $$= NEW_PTN PT_bit_type;
          }
        | BIT_SYM field_length
          {
            $$= NEW_PTN PT_bit_type($2);
          }
        | BOOL_SYM
          {
            $$= NEW_PTN PT_boolean_type;
          }
        | BOOLEAN_SYM
          {
            $$= NEW_PTN PT_boolean_type;
          }
        | CHAR_SYM field_length opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_char_type(Char_type::CHAR, $2, $3.charset,
                                     $3.force_binary);
          }
        | CHAR_SYM opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_char_type(Char_type::CHAR, $2.charset,
                                     $2.force_binary);
          }
        | nchar field_length opt_bin_mod
          {
            const CHARSET_INFO *cs= $3 ?
              get_bin_collation(national_charset_info) : national_charset_info;
            if (cs == NULL)
              MYSQL_YYABORT;
            $$= NEW_PTN PT_char_type(Char_type::CHAR, $2, cs);
            warn_about_deprecated_national(YYTHD);
          }
        | nchar opt_bin_mod
          {
            const CHARSET_INFO *cs= $2 ?
              get_bin_collation(national_charset_info) : national_charset_info;
            if (cs == NULL)
              MYSQL_YYABORT;
            $$= NEW_PTN PT_char_type(Char_type::CHAR, cs);
            warn_about_deprecated_national(YYTHD);
          }
        | BINARY_SYM field_length
          {
            $$= NEW_PTN PT_char_type(Char_type::CHAR, $2, &my_charset_bin);
          }
        | BINARY_SYM
          {
            $$= NEW_PTN PT_char_type(Char_type::CHAR, &my_charset_bin);
          }
        | varchar field_length opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_char_type(Char_type::VARCHAR, $2, $3.charset,
                                     $3.force_binary);
          }
        | nvarchar field_length opt_bin_mod
          {
            const CHARSET_INFO *cs= $3 ?
              get_bin_collation(national_charset_info) : national_charset_info;
            if (cs == NULL)
              MYSQL_YYABORT;
            $$= NEW_PTN PT_char_type(Char_type::VARCHAR, $2, cs);
            warn_about_deprecated_national(YYTHD);
          }
%ifdef SQL_MODE_ORACLE
        | varchar opt_charset_with_opt_binary
          {
            if (allow_type_without_len_in_sp_decl(YYTHD)) {
              const CHARSET_INFO *cs = $2.charset ? $2.charset : YYTHD->variables.collation_server;
              if (cs == NULL)
                MYSQL_YYABORT;
              size_t max_char_length = MAX_FIELD_VARCHARLENGTH / static_cast<std::int64_t>(cs->mbmaxlen);
              char *buf = new (YYTHD->mem_root) char[8];
              if (!buf) MYSQL_YYABORT;
              ullstr(max_char_length, buf);
              $$= NEW_PTN PT_char_type(Char_type::VARCHAR, buf, cs, $2.force_binary);
            } else {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | nvarchar opt_bin_mod
          {
            if (allow_type_without_len_in_sp_decl(YYTHD)) {
              const CHARSET_INFO *cs= $2 ?
                get_bin_collation(national_charset_info) : national_charset_info;
              if (cs == NULL)
                MYSQL_YYABORT;
              size_t max_char_length = MAX_FIELD_VARCHARLENGTH / static_cast<std::int64_t>(cs->mbmaxlen);
              char *buf = new (YYTHD->mem_root) char[8];
              if (!buf) MYSQL_YYABORT;
              ullstr(max_char_length, buf);
              $$= NEW_PTN PT_char_type(Char_type::VARCHAR, buf, cs);
              warn_about_deprecated_national(YYTHD);
            } else {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | VARBINARY_SYM
          {
            if (allow_type_without_len_in_sp_decl(YYTHD)) {
              size_t max_char_length = MAX_FIELD_VARCHARLENGTH / static_cast<std::int64_t>(my_charset_bin.mbmaxlen);
              char *buf = new (YYTHD->mem_root) char[8];
              if (!buf) MYSQL_YYABORT;
              ullstr(max_char_length, buf);
              $$= NEW_PTN PT_char_type(Char_type::VARCHAR, buf, &my_charset_bin);
            } else {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
%endif
        | VARBINARY_SYM field_length
          {
            $$= NEW_PTN PT_char_type(Char_type::VARCHAR, $2, &my_charset_bin);
          }
        | YEAR_SYM opt_field_length field_options
          {
            if ($2)
            {
              errno= 0;
              ulong length= strtoul($2, NULL, 10);
              if (errno != 0 || length != 4)
              {
                /* Only support length is 4 */
                my_error(ER_INVALID_YEAR_COLUMN_LENGTH, MYF(0), "YEAR");
                MYSQL_YYABORT;
              }
              push_deprecated_warn(YYTHD, "YEAR(4)", "YEAR");
            }
            if ($3 == UNSIGNED_FLAG)
            {
              push_warning(YYTHD, Sql_condition::SL_WARNING,
                           ER_WARN_DEPRECATED_SYNTAX_NO_REPLACEMENT,
                           ER_THD(YYTHD, ER_WARN_DEPRECATED_YEAR_UNSIGNED));
            }
            // We can ignore field length and UNSIGNED/ZEROFILL attributes here.
            $$= NEW_PTN PT_year_type;
          }
        | DATE_SYM
          {
            $$= NEW_PTN PT_date_type;
          }
        | TIME_SYM type_datetime_precision
          {
            $$= NEW_PTN PT_time_type(Time_type::TIME, $2);
          }
        | TIMESTAMP_SYM type_datetime_precision
          {
            $$= NEW_PTN PT_timestamp_type($2);
          }
        | DATETIME_SYM type_datetime_precision
          {
            $$= NEW_PTN PT_time_type(Time_type::DATETIME, $2);
          }
        | TINYBLOB_SYM
          {
            $$= NEW_PTN PT_blob_type(Blob_type::TINY, &my_charset_bin);
          }
        | BLOB_SYM opt_field_length
          {
            $$= NEW_PTN PT_blob_type($2);
          }
%ifdef SQL_MODE_ORACLE
        | RAW_SYM opt_field_length
          {
            $$= NEW_PTN PT_blob_type($2);
          }
%endif
        | spatial_type
        | MEDIUMBLOB_SYM
          {
            $$= NEW_PTN PT_blob_type(Blob_type::MEDIUM, &my_charset_bin);
          }
        | LONGBLOB_SYM
          {
            $$= NEW_PTN PT_blob_type(Blob_type::LONG, &my_charset_bin);
          }
        | LONG_SYM VARBINARY_SYM
          {
            $$= NEW_PTN PT_blob_type(Blob_type::MEDIUM, &my_charset_bin);
          }
        | LONG_SYM varchar opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_blob_type(Blob_type::MEDIUM, $3.charset,
                                     $3.force_binary);
          }
        | TINYTEXT_SYN opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_blob_type(Blob_type::TINY, $2.charset,
                                     $2.force_binary);
          }
        | TEXT_SYM opt_field_length opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_char_type(Char_type::TEXT, $2, $3.charset,
                                     $3.force_binary);
          }
        | MEDIUMTEXT_SYM opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_blob_type(Blob_type::MEDIUM, $2.charset,
                                     $2.force_binary);
          }
        | LONGTEXT_SYM opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_blob_type(Blob_type::LONG, $2.charset,
                                     $2.force_binary);
          }
        | CLOB_SYM opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_blob_type(Blob_type::LONG, $2.charset,
                                     $2.force_binary);
          }
        | ENUM_SYM '(' string_list ')' opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_enum_type($3, $5.charset, $5.force_binary);
          }
        | SET_SYM '(' string_list ')' opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_set_type($3, $5.charset, $5.force_binary);
          }
        | LONG_SYM opt_charset_with_opt_binary
          {
            $$= NEW_PTN PT_blob_type(Blob_type::MEDIUM, $2.charset,
                                     $2.force_binary);
          }
        | SERIAL_SYM
          {
            $$= NEW_PTN PT_serial_type;
          }
        | JSON_SYM
          {
            $$= NEW_PTN PT_json_type;
          }
        ;

spatial_type:
          GEOMETRY_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_GEOMETRY); }
        | GEOMETRYCOLLECTION_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_GEOMETRYCOLLECTION); }
        | POINT_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_POINT); }
        | MULTIPOINT_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_MULTIPOINT); }
        | LINESTRING_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_LINESTRING); }
        | MULTILINESTRING_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_MULTILINESTRING); }
        | POLYGON_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_POLYGON); }
        | MULTIPOLYGON_SYM
          { $$= NEW_PTN PT_spacial_type(Field::GEOM_MULTIPOLYGON); }
        ;

nchar:
          NCHAR_SYM {}
        | NATIONAL_SYM CHAR_SYM {}
        ;

varchar:
          CHAR_SYM VARYING {}
        | VARCHAR_SYM {}
        ;

nvarchar:
          NATIONAL_SYM VARCHAR_SYM {}
        | NVARCHAR_SYM {}
        | NCHAR_SYM VARCHAR_SYM {}
        | NATIONAL_SYM CHAR_SYM VARYING {}
        | NCHAR_SYM VARYING {}
        ;

int_type:
          INT_SYM       { $$=Int_type::INT; }
        | TINYINT_SYM   { $$=Int_type::TINYINT; }
        | SMALLINT_SYM  { $$=Int_type::SMALLINT; }
        | MEDIUMINT_SYM { $$=Int_type::MEDIUMINT; }
        | BIGINT_SYM    { $$=Int_type::BIGINT; }
        ;

real_type:
          REAL_SYM
          {
            $$= YYTHD->variables.sql_mode & MODE_REAL_AS_FLOAT ?
              Numeric_type::FLOAT : Numeric_type::DOUBLE;
          }
        | DOUBLE_SYM opt_PRECISION
          { $$= Numeric_type::DOUBLE; }
        ;

opt_PRECISION:
          /* empty */
        | PRECISION
        ;

numeric_type:
          FLOAT_SYM   { $$= Numeric_type::FLOAT; }
        | DECIMAL_SYM { $$= Numeric_type::DECIMAL; }
        | NUMERIC_SYM { $$= Numeric_type::DECIMAL; }
        | FIXED_SYM   { $$= Numeric_type::DECIMAL; }
        ;

standard_float_options:
          /* empty */
          {
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | field_length
          {
            $$.length = $1;
            $$.dec = nullptr;
          }
        ;

float_options:
          /* empty */
          {
            $$.length= NULL;
            $$.dec= NULL;
          }
        | field_length
          {
            $$.length= $1;
            $$.dec= NULL;
          }
        | precision
        ;

ora_number_float_options:
          /* empty */ %prec KEYWORD_USED_AS_KEYWORD
          {
            $$.length= "65";
            $$.dec= "30";
          }
        | '(' '*' ')'
          {
            $$.length= "65";
            $$.dec= "30";
          }
        | '(' '*' ',' NUM ')'
          {
            $$.length= "38";
            $$.dec= $4.str;
          }
        | '(' NUM ')'
          {
            $$.length= $2.str;
            $$.dec= NULL;
          }
        | precision
        ;

precision:
          '(' NUM ',' NUM ')'
          {
            $$.length= $2.str;
            $$.dec= $4.str;
          }
        ;


type_datetime_precision:
          /* empty */                { $$= NULL; }
        | '(' NUM ')'                { $$= $2.str; }
        ;

func_datetime_precision:
          /* empty */                { $$= 0; }
        | '(' ')'                    { $$= 0; }
        | '(' NUM ')'
           {
             int error;
             $$= (ulong) my_strtoll10($2.str, NULL, &error);
           }
        ;

field_options:
          /* empty */ { $$ = 0; }
        | field_opt_list
        ;

field_opt_list:
          field_opt_list field_option
          {
            $$ = $1 | $2;
          }
        | field_option
        ;

field_option:
          SIGNED_SYM   { $$ = 0; } // TODO: remove undocumented ignored syntax
        | UNSIGNED_SYM { $$ = UNSIGNED_FLAG; }
        | ZEROFILL_SYM {
            $$ = ZEROFILL_FLAG;
            push_warning(YYTHD, Sql_condition::SL_WARNING,
                         ER_WARN_DEPRECATED_SYNTAX_NO_REPLACEMENT,
                         ER_THD(YYTHD, ER_WARN_DEPRECATED_ZEROFILL));
          }
        ;

field_length:
          '(' LONG_NUM ')'      { $$= $2.str; }
        | '(' ULONGLONG_NUM ')' { $$= $2.str; }
        | '(' DECIMAL_NUM ')'   { $$= $2.str; }
        | '(' NUM ')'           { $$= $2.str; };

opt_field_length:
          /* empty */  { $$= NULL; /* use default length */ }
        | field_length
        ;

opt_precision:
          /* empty */
          {
            $$.length= NULL;
            $$.dec = NULL;
          }
        | precision
        ;

opt_column_attribute_list:
          /* empty */ { $$= NULL; }
        | column_attribute_list
        ;

column_attribute_list:
          column_attribute_list column_attribute
          {
            $$= $1;
            if ($2 == nullptr)
              MYSQL_YYABORT; // OOM

            if ($2->has_constraint_enforcement()) {
              // $2 is `[NOT] ENFORCED`
              if ($1->back()->set_constraint_enforcement(
                      $2->is_constraint_enforced())) {
                // $1 is not `CHECK(...)`
                YYTHD->syntax_error_at(@2);
                MYSQL_YYABORT;
              }
            } else {
              if ($$->push_back($2))
                MYSQL_YYABORT; // OOM
            }
          }
        | column_attribute
          {
            if ($1 == nullptr)
              MYSQL_YYABORT; // OOM

            if ($1->has_constraint_enforcement()) {
              // [NOT] ENFORCED doesn't follow the CHECK clause
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }

            $$=
              NEW_PTN Mem_root_array<PT_column_attr_base *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        ;

column_attribute:
          NULL_SYM
          {
            $$= NEW_PTN PT_null_column_attr;
          }
        | not NULL_SYM
          {
            $$= NEW_PTN PT_not_null_column_attr;
          }
        | not SECONDARY_SYM
          {
            $$= NEW_PTN PT_secondary_column_attr;
          }
        | DEFAULT_SYM now_or_signed_literal
          {
            $$= NEW_PTN PT_default_column_attr($2);
          }
        | DEFAULT_SYM '(' expr ')'
          {
            $$= NEW_PTN PT_generated_default_val_column_attr($3);
          }
        | ON_SYM UPDATE_SYM now
          {
            $$= NEW_PTN PT_on_update_column_attr(static_cast<uint8>($3));
          }
        | AUTO_INC
          {
            $$= NEW_PTN PT_auto_increment_column_attr;
          }
        | SERIAL_SYM DEFAULT_SYM VALUE_SYM
          {
            $$= NEW_PTN PT_serial_default_value_column_attr;
          }
        | opt_primary KEY_SYM
          {
            $$= NEW_PTN PT_primary_key_column_attr;
          }
        | UNIQUE_SYM
          {
            $$= NEW_PTN PT_unique_combo_clustering_key_column_attr(KEYTYPE_UNIQUE);
          }
        | UNIQUE_SYM KEY_SYM
          {
            $$= NEW_PTN PT_unique_combo_clustering_key_column_attr(KEYTYPE_UNIQUE);
          }
        | CLUSTERING_SYM
          {
            $$= NEW_PTN PT_unique_combo_clustering_key_column_attr(KEYTYPE_CLUSTERING);
          }
        | CLUSTERING_SYM KEY_SYM
          {
            $$= NEW_PTN PT_unique_combo_clustering_key_column_attr(KEYTYPE_CLUSTERING);
          }
        | COMMENT_SYM TEXT_STRING_sys
        {
            $$= NEW_PTN PT_comment_column_attr(to_lex_cstring($2));
        }
        | COLLATE_SYM collation_name
          {
            $$= NEW_PTN PT_collate_column_attr(@2, $2);
          }
        | COLUMN_FORMAT_SYM column_format
          {
            $$= NEW_PTN PT_column_format_column_attr($2, null_lex_cstr);
          }
        | COLUMN_FORMAT_SYM COMPRESSED_SYM opt_with_compression_dictionary
          {
            $$= NEW_PTN PT_column_format_column_attr(COLUMN_FORMAT_TYPE_COMPRESSED, $3);
          }
        | STORAGE_SYM storage_media
          {
            $$= NEW_PTN PT_storage_media_column_attr($2);
          }
        | SRID_SYM real_ulonglong_num
          {
            if ($2 > std::numeric_limits<gis::srid_t>::max())
            {
              my_error(ER_DATA_OUT_OF_RANGE, MYF(0), "SRID", "SRID");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PT_srid_column_attr(static_cast<gis::srid_t>($2));
          }
        | opt_constraint_name check_constraint
          /* See the next branch for [NOT] ENFORCED. */
          {
            $$= NEW_PTN PT_check_constraint_column_attr($1, $2);
          }
        | constraint_enforcement
          /*
            This branch is needed to workaround the need of a lookahead of 2 for
            the grammar:

             { [NOT] NULL | CHECK(...) [NOT] ENFORCED } ...

            Note: the column_attribute_list rule rejects all unexpected
                  [NOT] ENFORCED sequences.
          */
          {
            $$ = NEW_PTN PT_constraint_enforcement_attr($1);
          }
        | ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_column_engine_attribute(YYMEM_ROOT, $3);
          }
        | SECONDARY_ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_column_secondary_engine_attribute(YYMEM_ROOT, $3);
          }
        | visibility
          {
            $$ = NEW_PTN PT_column_visibility_attr($1);
          }
        ;

opt_with_compression_dictionary:
          /* empty */ { $$= null_lex_cstr; }
        | WITH COMPRESSION_DICTIONARY_SYM ident
          {
            $$= to_lex_cstring($3);
          }
        ;

column_format:
          DEFAULT_SYM { $$= COLUMN_FORMAT_TYPE_DEFAULT; }
        | FIXED_SYM   { $$= COLUMN_FORMAT_TYPE_FIXED; }
        | DYNAMIC_SYM { $$= COLUMN_FORMAT_TYPE_DYNAMIC; }
        ;

storage_media:
          DEFAULT_SYM { $$= HA_SM_DEFAULT; }
        | DISK_SYM    { $$= HA_SM_DISK; }
        | MEMORY_SYM  { $$= HA_SM_MEMORY; }
        ;

now:
          NOW_SYM func_datetime_precision
          {
            $$= $2;
          }
        | SYSTIMESTAMP_SYM optional_braces
          {
            $$= 6;
          }
        | SYSTIMESTAMP_SYM '(' NUM ')'
        {
          int error;
          $$= (ulong) my_strtoll10($3.str, NULL, &error);
        }
%ifdef SQL_MODE_ORACLE
        | SYSDATE { $$= 6; }
        | SYSDATE '(' ')' { $$= 6; }
        | SYSDATE '(' NUM ')'
           {
             int error;
             $$= (ulong) my_strtoll10($3.str, NULL, &error);
           }
%endif
        ;

now_or_signed_literal:
          now
          {
            uint8 dec = static_cast<uint8>($1);
            bool is_current_timestmap = false;
            bool is_dec_appoint = false;
            current_timestamp_parse(@1.cpp.start, @1.cpp.length(),
                                    &is_current_timestmap, &is_dec_appoint);

            auto item = NEW_PTN Item_func_now_local(@$, dec);
            if (item == NULL)
              MYSQL_YYABORT;
            item->is_current_timestmap = is_current_timestmap;
            item->is_dec_appoint = is_dec_appoint;
            $$=item;
          }
        | signed_literal_or_null
        ;

character_set:
          CHAR_SYM SET_SYM
        | CHARSET
        ;

charset_name:
          ident_or_text
          {
            if (!($$=get_charset_by_csname($1.str,MY_CS_PRIMARY,MYF(0))))
            {
              my_error(ER_UNKNOWN_CHARACTER_SET, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            YYLIP->warn_on_deprecated_charset($$, $1.str);
          }
        | BINARY_SYM { $$= &my_charset_bin; }
        ;

opt_load_data_charset:
          /* Empty */ { $$= NULL; }
        | character_set charset_name { $$ = $2; }
        ;

old_or_new_charset_name:
          ident_or_text
          {
            if (!($$=get_charset_by_csname($1.str,MY_CS_PRIMARY,MYF(0))) &&
                !($$=get_old_charset_by_name($1.str)))
            {
              my_error(ER_UNKNOWN_CHARACTER_SET, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
          }
        | BINARY_SYM { $$= &my_charset_bin; }
        ;

old_or_new_charset_name_or_default:
          old_or_new_charset_name { $$=$1;   }
        | DEFAULT_SYM    { $$=NULL; }
        ;

collation_name:
          ident_or_text
          {
            if (!($$= mysqld_collation_get_by_name($1.str)))
              MYSQL_YYABORT;
            YYLIP->warn_on_deprecated_collation($$);
          }
        | BINARY_SYM { $$= &my_charset_bin; }
        ;

opt_collate:
          /* empty */                { $$ = nullptr; }
        | COLLATE_SYM collation_name { $$ = $2; }
        ;

opt_default:
          /* empty */ {}
        | DEFAULT_SYM {}
        ;


ascii:
          ASCII_SYM        {
          push_deprecated_warn(YYTHD, "ASCII", "CHARACTER SET charset_name");
          $$= &my_charset_latin1;
        }
        | BINARY_SYM ASCII_SYM {
            warn_about_deprecated_binary(YYTHD);
            push_deprecated_warn(YYTHD, "ASCII", "CHARACTER SET charset_name");
            $$= &my_charset_latin1_bin;
        }
        | ASCII_SYM BINARY_SYM {
            push_deprecated_warn(YYTHD, "ASCII", "CHARACTER SET charset_name");
            warn_about_deprecated_binary(YYTHD);
            $$= &my_charset_latin1_bin;
        }
        ;

unicode:
          UNICODE_SYM
          {
            push_deprecated_warn(YYTHD, "UNICODE", "CHARACTER SET charset_name");
            if (!($$= get_charset_by_csname("ucs2", MY_CS_PRIMARY,MYF(0))))
            {
              my_error(ER_UNKNOWN_CHARACTER_SET, MYF(0), "ucs2");
              MYSQL_YYABORT;
            }
          }
        | UNICODE_SYM BINARY_SYM
          {
            push_deprecated_warn(YYTHD, "UNICODE", "CHARACTER SET charset_name");
            warn_about_deprecated_binary(YYTHD);
            if (!($$= mysqld_collation_get_by_name("ucs2_bin")))
              MYSQL_YYABORT;
          }
        | BINARY_SYM UNICODE_SYM
          {
            warn_about_deprecated_binary(YYTHD);
            push_deprecated_warn(YYTHD, "UNICODE", "CHARACTER SET charset_name");
            if (!($$= mysqld_collation_get_by_name("ucs2_bin")))
              my_error(ER_UNKNOWN_COLLATION, MYF(0), "ucs2_bin");
          }
        ;

opt_charset_with_opt_binary:
          /* empty */
          {
            $$.charset= NULL;
            $$.force_binary= false;
          }
        | ascii
          {
            $$.charset= $1;
            $$.force_binary= false;
          }
        | unicode
          {
            $$.charset= $1;
            $$.force_binary= false;
          }
        | BYTE_SYM
          {
            $$.charset= &my_charset_bin;
            $$.force_binary= false;
          }
        | character_set charset_name opt_bin_mod
          {
            $$.charset= $3 ? get_bin_collation($2) : $2;
            if ($$.charset == NULL)
              MYSQL_YYABORT;
            $$.force_binary= false;
          }
        | BINARY_SYM
          {
            warn_about_deprecated_binary(YYTHD);
            $$.charset= NULL;
            $$.force_binary= true;
          }
        | BINARY_SYM character_set charset_name
          {
            warn_about_deprecated_binary(YYTHD);
            $$.charset= get_bin_collation($3);
            if ($$.charset == NULL)
              MYSQL_YYABORT;
            $$.force_binary= false;
          }
        ;

opt_bin_mod:
          /* empty */ { $$= false; }
        | BINARY_SYM {
            warn_about_deprecated_binary(YYTHD);
            $$= true;
          }
        ;

ws_num_codepoints:
        '(' real_ulong_num
        {
          if ($2 == 0)
          {
            YYTHD->syntax_error();
            MYSQL_YYABORT;
          }
        }
        ')'
        { $$= $2; }
        ;

opt_primary:
          /* empty */
        | PRIMARY_SYM
        ;

references:
          REFERENCES
          table_ident
          opt_ref_list
          opt_match_clause
          opt_on_update_delete
          {
            $$.table_name= $2;
            $$.reference_list= $3;
            $$.fk_match_option= $4;
            $$.fk_update_opt= $5.fk_update_opt;
            $$.fk_delete_opt= $5.fk_delete_opt;
          }
        ;

opt_ref_list:
          /* empty */      { $$= NULL; }
        | '(' reference_list ')' { $$= $2; }
        ;

reference_list:
          reference_list ',' ident
          {
            $$= $1;
            auto key= NEW_PTN Key_part_spec(to_lex_cstring($3), 0, ORDER_ASC);
            if (key == NULL || $$->push_back(key))
              MYSQL_YYABORT;
          }
        | ident
          {
            $$= NEW_PTN List<Key_part_spec>;
            auto key= NEW_PTN Key_part_spec(to_lex_cstring($1), 0, ORDER_ASC);
            if ($$ == NULL || key == NULL || $$->push_back(key))
              MYSQL_YYABORT;
          }
        ;

opt_match_clause:
          /* empty */      { $$= FK_MATCH_UNDEF; }
        | MATCH FULL       { $$= FK_MATCH_FULL; }
        | MATCH PARTIAL    { $$= FK_MATCH_PARTIAL; }
        | MATCH SIMPLE_SYM { $$= FK_MATCH_SIMPLE; }
        ;

opt_on_update_delete:
          /* empty */
          {
            $$.fk_update_opt= FK_OPTION_UNDEF;
            $$.fk_delete_opt= FK_OPTION_UNDEF;
          }
        | ON_SYM UPDATE_SYM delete_option
          {
            $$.fk_update_opt= $3;
            $$.fk_delete_opt= FK_OPTION_UNDEF;
          }
        | ON_SYM DELETE_SYM delete_option
          {
            $$.fk_update_opt= FK_OPTION_UNDEF;
            $$.fk_delete_opt= $3;
          }
        | ON_SYM UPDATE_SYM delete_option
          ON_SYM DELETE_SYM delete_option
          {
            $$.fk_update_opt= $3;
            $$.fk_delete_opt= $6;
          }
        | ON_SYM DELETE_SYM delete_option
          ON_SYM UPDATE_SYM delete_option
          {
            $$.fk_update_opt= $6;
            $$.fk_delete_opt= $3;
          }
        ;

delete_option:
          RESTRICT      { $$= FK_OPTION_RESTRICT; }
        | CASCADE       { $$= FK_OPTION_CASCADE; }
        | SET_SYM NULL_SYM  { $$= FK_OPTION_SET_NULL; }
        | NO_SYM ACTION { $$= FK_OPTION_NO_ACTION; }
        | SET_SYM DEFAULT_SYM { $$= FK_OPTION_DEFAULT;  }
        ;

constraint_key_type:
          PRIMARY_SYM KEY_SYM { $$= KEYTYPE_PRIMARY; }
        | unique_combo_clustering opt_key_or_index { $$= $1; }

        ;

key_or_index:
          KEY_SYM {}
        | INDEX_SYM {}
        ;

opt_key_or_index:
          /* empty */ {}
        | key_or_index
        ;

keys_or_index:
          KEYS {}
        | INDEX_SYM {}
        | INDEXES {}
        ;

opt_unique_combo_clustering:
          /* empty */  { $$= KEYTYPE_MULTIPLE; }
        | unique_combo_clustering
        ;

unique_combo_clustering:
          UNIQUE_SYM
          {
            $$= KEYTYPE_UNIQUE;
          }
        | UNIQUE_SYM KEY_SYM
          {
            $$= KEYTYPE_UNIQUE;
          }
        | CLUSTERING_SYM
          {
            $$= static_cast<keytype>(KEYTYPE_MULTIPLE | KEYTYPE_CLUSTERING);
          }
        | CLUSTERING_SYM KEY_SYM
          {
            $$= static_cast<keytype>(KEYTYPE_MULTIPLE | KEYTYPE_CLUSTERING);
          }
        | UNIQUE_SYM CLUSTERING_SYM
          {
            $$= static_cast<keytype>(KEYTYPE_UNIQUE | KEYTYPE_CLUSTERING);
          }
        | UNIQUE_SYM CLUSTERING_SYM KEY_SYM
          {
            $$= static_cast<keytype>(KEYTYPE_UNIQUE | KEYTYPE_CLUSTERING);
          }
        | CLUSTERING_SYM UNIQUE_SYM
          {
            $$= static_cast<keytype>(KEYTYPE_UNIQUE | KEYTYPE_CLUSTERING);
          }
        | CLUSTERING_SYM UNIQUE_SYM KEY_SYM
          {
            $$= static_cast<keytype>(KEYTYPE_UNIQUE | KEYTYPE_CLUSTERING);
          }

opt_fulltext_index_options:
          /* Empty. */ { $$.init(YYMEM_ROOT); }
        | fulltext_index_options
        ;

fulltext_index_options:
          fulltext_index_option
          {
            $$.init(YYMEM_ROOT);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | fulltext_index_options fulltext_index_option
          {
            if ($1.push_back($2))
              MYSQL_YYABORT; // OOM
            $$= $1;
          }
        ;

fulltext_index_option:
          common_index_option
        | WITH PARSER_SYM IDENT_sys
          {
            LEX_CSTRING plugin_name= {$3.str, $3.length};
            if (!plugin_is_ready(plugin_name, MYSQL_FTPARSER_PLUGIN))
            {
              my_error(ER_FUNCTION_NOT_DEFINED, MYF(0), $3.str);
              MYSQL_YYABORT;
            }
            else
              $$= NEW_PTN PT_fulltext_index_parser_name(to_lex_cstring($3));
          }
        ;

opt_spatial_index_options:
          /* Empty. */ { $$.init(YYMEM_ROOT); }
        | spatial_index_options
        ;

spatial_index_options:
          spatial_index_option
          {
            $$.init(YYMEM_ROOT);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | spatial_index_options spatial_index_option
          {
            if ($1.push_back($2))
              MYSQL_YYABORT; // OOM
            $$= $1;
          }
        ;

spatial_index_option:
          common_index_option
        ;

opt_index_options:
          /* Empty. */ { $$.init(YYMEM_ROOT); }
        | index_options
        ;

index_options:
          index_option
          {
            $$.init(YYMEM_ROOT);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | index_options index_option
          {
            if ($1.push_back($2))
              MYSQL_YYABORT; // OOM
            $$= $1;
          }
        ;

index_option:
          common_index_option { $$= $1; }
        | index_type_clause { $$= $1; }
        ;

// These options are common for all index types.
common_index_option:
          KEY_BLOCK_SIZE opt_equal ulong_num { $$= NEW_PTN PT_block_size($3); }
        | COMMENT_SYM TEXT_STRING_sys
          {
            $$= NEW_PTN PT_index_comment(to_lex_cstring($2));
          }
        | visibility
          {
            $$= NEW_PTN PT_index_visibility($1);
          }
        | ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_index_engine_attribute(YYMEM_ROOT, $3);
          }
        | SECONDARY_ENGINE_ATTRIBUTE_SYM opt_equal json_attribute
          {
            $$ = make_index_secondary_engine_attribute(YYMEM_ROOT, $3);
          }
        ;

/*
  The syntax for defining an index is:

    ... INDEX [index_name] [USING|TYPE] <index_type> ...

  The problem is that whereas USING is a reserved word, TYPE is not. We can
  still handle it if an index name is supplied, i.e.:

    ... INDEX type TYPE <index_type> ...

  here the index's name is unmbiguously 'type', but for this:

    ... INDEX TYPE <index_type> ...

  it's impossible to know what this actually mean - is 'type' the name or the
  type? For this reason we accept the TYPE syntax only if a name is supplied.
*/
opt_index_name_and_type:
          opt_ident                  { $$= {$1, NULL}; }
        | opt_ident USING index_type { $$= {$1, NEW_PTN PT_index_type($3)}; }
        | ident TYPE_SYM index_type  { $$= {$1, NEW_PTN PT_index_type($3)}; }
        ;

opt_index_type_clause:
          /* empty */                { $$ = nullptr; }
        | index_type_clause
        ;

index_type_clause:
          USING index_type    { $$= NEW_PTN PT_index_type($2); }
        | TYPE_SYM index_type { $$= NEW_PTN PT_index_type($2); }
        ;

visibility:
          VISIBLE_SYM { $$= true; }
        | INVISIBLE_SYM { $$= false; }
        ;

index_type:
          BTREE_SYM { $$= HA_KEY_ALG_BTREE; }
        | RTREE_SYM { $$= HA_KEY_ALG_RTREE; }
        | HASH_SYM  { $$= HA_KEY_ALG_HASH; }
        ;

key_list:
          key_list ',' key_part
          {
            if ($1->push_back($3))
              MYSQL_YYABORT; // OOM
            $$= $1;
          }
        | key_part
          {
            // The order is ignored.
            $$= NEW_PTN List<PT_key_part_specification>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        ;

key_part:
          ident opt_ordering_direction
          {
            $$= NEW_PTN PT_key_part_specification(to_lex_cstring($1), $2, 0);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | ident '(' NUM ')' opt_ordering_direction
          {
            int key_part_length= atoi($3.str);
            if (!key_part_length)
            {
              my_error(ER_KEY_PART_0, MYF(0), $1.str);
            }
            $$= NEW_PTN PT_key_part_specification(to_lex_cstring($1), $5,
                                                  key_part_length);
            if ($$ == NULL)
              MYSQL_YYABORT; /* purecov: deadcode */
          }
        ;

key_list_with_expression:
          key_list_with_expression ',' key_part_with_expression
          {
            if ($1->push_back($3))
              MYSQL_YYABORT; /* purecov: deadcode */
            $$= $1;
          }
        | key_part_with_expression
          {
            // The order is ignored.
            $$= NEW_PTN List<PT_key_part_specification>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; /* purecov: deadcode */
          }
        ;

key_part_with_expression:
          key_part
        | '(' expr ')' opt_ordering_direction
          {
            $$= NEW_PTN PT_key_part_specification($2, $4);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

opt_ident:
          /* empty */ { $$= NULL_STR; }
        | ident
        ;

string_list:
          text_string
          {
            $$= NEW_PTN List<String>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | string_list ',' text_string
          {
            if ($$->push_back($3))
              MYSQL_YYABORT;
          }
        ;

alter_sequence_stmt:
          ALTER SEQUENCE_SYM table_ident sequence_option_list
          {
            $$ = NEW_PTN PT_alter_sequence_stmt($3);
          }
        ;

alter_synonym_stmt:
          ALTER opt_public SYNONYM_SYM table_ident
          {
            $$= NEW_PTN PT_alter_synonym_stmt($4 /* synonym_ident */,
                                              $2 /* is_public */);
          }
        ;

/*
** Alter table
*/

alter_table_stmt:
          ALTER TABLE_SYM table_ident opt_alter_table_actions
          {
            $$= NEW_PTN PT_alter_table_stmt(
                  YYMEM_ROOT,
                  $1,
                  $3,
                  $4.actions,
                  $4.flags.algo.get_or_default(),
                  $4.flags.lock.get_or_default(),
                  $4.flags.validation.get_or_default());
          }
        | ALTER TABLE_SYM table_ident standalone_alter_table_action
          {
            $$= NEW_PTN PT_alter_table_standalone_stmt(
                  YYMEM_ROOT,
                  $1,
                  $3,
                  $4.action,
                  $4.flags.algo.get_or_default(),
                  $4.flags.lock.get_or_default(),
                  $4.flags.validation.get_or_default());
          }
        ;

alter_database_stmt:
          ALTER DATABASE ident_or_empty
          {
            Lex->create_info= YYTHD->alloc_typed<HA_CREATE_INFO>();
            if (Lex->create_info == NULL)
              MYSQL_YYABORT; // OOM
            Lex->create_info->default_table_charset= NULL;
            Lex->create_info->used_fields= 0;
          }
          alter_database_options
          {
            LEX *lex=Lex;
            lex->sql_command=SQLCOM_ALTER_DB;
            lex->name= $3;
            if (lex->name.str == NULL &&
                lex->copy_db_to(&lex->name.str, &lex->name.length))
              MYSQL_YYABORT;
          }
        ;

alter_procedure_stmt:
          ALTER PROCEDURE_SYM sp_name
          {
            LEX *lex= Lex;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_DROP_SP, MYF(0), "PROCEDURE");
              MYSQL_YYABORT;
            }
            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
          sp_a_chistics
          {
            LEX *lex=Lex;

            lex->sql_command= SQLCOM_ALTER_PROCEDURE;
            lex->spname= $3;
          }
        ;

alter_function_stmt:
          ALTER FUNCTION_SYM sp_name
          {
            LEX *lex= Lex;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_DROP_SP, MYF(0), "FUNCTION");
              MYSQL_YYABORT;
            }
            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
          sp_a_chistics
          {
            LEX *lex=Lex;

            lex->sql_command= SQLCOM_ALTER_FUNCTION;
            lex->spname= $3;
          }
        ;

alter_view_stmt:
          ALTER view_algorithm definer_opt
          {
            LEX *lex= Lex;

            if (lex->sphead)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), "ALTER VIEW");
              MYSQL_YYABORT;
            }
            lex->create_view_mode= enum_view_create_mode::VIEW_ALTER;
          }
          view_tail
          {}
        | ALTER definer_opt
          /*
            We have two separate rules for ALTER VIEW rather that
            optional view_algorithm above, to resolve the ambiguity
            with the ALTER EVENT below.
          */
          {
            LEX *lex= Lex;

            if (lex->sphead)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), "ALTER VIEW");
              MYSQL_YYABORT;
            }
            lex->create_view_algorithm= VIEW_ALGORITHM_UNDEFINED;
            lex->create_view_mode= enum_view_create_mode::VIEW_ALTER;
          }
          view_tail
          {}
        ;

opt_trg_status:
        ENABLE_SYM
          {
            Lex->event_parse_data->status= Event_parse_data::ENABLED;
            Lex->event_parse_data->status_changed= true;
            $$= 1;
          }
        | DISABLE_SYM
          {
            Lex->event_parse_data->status= Event_parse_data::DISABLED;
            Lex->event_parse_data->status_changed= true;
            $$= 1;
          }
        ;

alter_trigger_stmt:
          ALTER TRIGGER_SYM sp_name
          {
            /*
              If it had to be supported spname had to be added to
              Event_parse_data.
            */

            if (!(Lex->event_parse_data= new (YYTHD->mem_root) Event_parse_data()))
              MYSQL_YYABORT;
            Lex->sql_command= SQLCOM_ALTER_TRIGGER;
            Lex->drop_if_exists= 0;
            Lex->spname= $3;
            Lex->m_sql_cmd= new (YYTHD->mem_root) Sql_cmd_alter_trigger();
          }
          opt_trg_status
        ;

alter_event_stmt:
          ALTER definer_opt EVENT_SYM sp_name
          {
            /*
              It is safe to use Lex->spname because
              ALTER EVENT xxx RENATE TO yyy DO ALTER EVENT RENAME TO
              is not allowed. Lex->spname is used in the case of RENAME TO
              If it had to be supported spname had to be added to
              Event_parse_data.
            */

            if (!(Lex->event_parse_data= new (YYTHD->mem_root) Event_parse_data()))
              MYSQL_YYABORT;
            Lex->event_parse_data->identifier= $4;

            Lex->sql_command= SQLCOM_ALTER_EVENT;
          }
          ev_alter_on_schedule_completion
          opt_ev_rename_to
          opt_ev_status
          opt_ev_comment
          opt_ev_sql_stmt
          {
            if (!($6 || $7 || $8 || $9 || $10))
            {
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            /*
              sql_command is set here because some rules in ev_sql_stmt
              can overwrite it
            */
            Lex->sql_command= SQLCOM_ALTER_EVENT;
          }
        ;

alter_logfile_stmt:
          ALTER LOGFILE_SYM GROUP_SYM ident ADD lg_undofile
          opt_alter_logfile_group_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($7 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $7))
                MYSQL_YYABORT; /* purecov: inspected */
            }

            Lex->m_sql_cmd= NEW_PTN Sql_cmd_logfile_group{ALTER_LOGFILE_GROUP,
                                                          $4, pc, $6};
            if (!Lex->m_sql_cmd)
              MYSQL_YYABORT; /* purecov: inspected */ //OOM

            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }

alter_tablespace_stmt:
          ALTER TABLESPACE_SYM ident ADD ts_datafile
          opt_alter_tablespace_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($6 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $6))
                MYSQL_YYABORT; /* purecov: inspected */
            }

            Lex->m_sql_cmd= NEW_PTN Sql_cmd_alter_tablespace_add_datafile{$3, $5, pc};
            if (!Lex->m_sql_cmd)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        | ALTER TABLESPACE_SYM ident DROP ts_datafile
          opt_alter_tablespace_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($6 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $6))
                MYSQL_YYABORT; /* purecov: inspected */
            }

            Lex->m_sql_cmd=
              NEW_PTN Sql_cmd_alter_tablespace_drop_datafile{$3, $5, pc};
            if (!Lex->m_sql_cmd)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        | ALTER TABLESPACE_SYM ident RENAME TO_SYM ident
          {
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_alter_tablespace_rename{$3, $6};
            if (!Lex->m_sql_cmd)
              MYSQL_YYABORT; // OOM

            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        | ALTER TABLESPACE_SYM ident alter_tablespace_option_list
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; // OOM

            if ($4 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $4))
                MYSQL_YYABORT;
            }

            Lex->m_sql_cmd=
              NEW_PTN Sql_cmd_alter_tablespace{$3, pc};
            if (!Lex->m_sql_cmd)
              MYSQL_YYABORT; // OOM

            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        ;

alter_undo_tablespace_stmt:
          ALTER UNDO_SYM TABLESPACE_SYM ident SET_SYM undo_tablespace_state
          opt_undo_tablespace_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; // OOM

            if ($7 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $7))
                MYSQL_YYABORT;
            }

            auto cmd= NEW_PTN Sql_cmd_alter_undo_tablespace{
              ALTER_UNDO_TABLESPACE, $4,
              {nullptr, 0}, pc, $6};
            if (!cmd)
              MYSQL_YYABORT; //OOM
            Lex->m_sql_cmd= cmd;
            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        ;

alter_server_stmt:
          ALTER SERVER_SYM ident_or_text OPTIONS_SYM '(' server_options_list ')'
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_ALTER_SERVER;
            lex->server_options.m_server_name= $3;
            lex->m_sql_cmd=
              NEW_PTN Sql_cmd_alter_server(&Lex->server_options);
          }
        ;

alter_user_stmt:
          alter_user_command alter_user_list require_clause
          connect_options opt_account_lock_password_expire_options
          opt_user_attribute
        | alter_user_command user_func identified_by_random_password
          opt_replace_password opt_retain_current_password
          {
            $2->first_factor_auth_info = *$3;

            if ($4.str != nullptr) {
              $2->current_auth = $4;
              $2->uses_replace_clause = true;
            }
            $2->discard_old_password = false;
            $2->retain_current_password = $5;
          }
        | alter_user_command user_func identified_by_password
          opt_replace_password opt_retain_current_password
          {
            $2->first_factor_auth_info = *$3;

            if ($4.str != nullptr) {
              $2->current_auth = $4;
              $2->uses_replace_clause = true;
            }
            $2->discard_old_password = false;
            $2->retain_current_password = $5;
          }
        | alter_user_command user_func DISCARD_SYM OLD_SYM PASSWORD
          {
            $2->discard_old_password = true;
            $2->retain_current_password = false;
          }
        | alter_user_command user DEFAULT_SYM ROLE_SYM ALL
          {
            List<LEX_USER> *users= new (YYMEM_ROOT) List<LEX_USER>;
            if (users == NULL || users->push_back($2))
              MYSQL_YYABORT;
            List<LEX_USER> *role_list= new (YYMEM_ROOT) List<LEX_USER>;
            auto *tmp=
                NEW_PTN PT_alter_user_default_role(Lex->drop_if_exists,
                                                   users, role_list,
                                                   role_enum::ROLE_ALL);
              MAKE_CMD(tmp);
          }
        | alter_user_command user DEFAULT_SYM ROLE_SYM NONE_SYM
          {
            List<LEX_USER> *users= new (YYMEM_ROOT) List<LEX_USER>;
            if (users == NULL || users->push_back($2))
              MYSQL_YYABORT;
            List<LEX_USER> *role_list= new (YYMEM_ROOT) List<LEX_USER>;
            auto *tmp=
                NEW_PTN PT_alter_user_default_role(Lex->drop_if_exists,
                                                   users, role_list,
                                                   role_enum::ROLE_NONE);
              MAKE_CMD(tmp);
          }
        | alter_user_command user DEFAULT_SYM ROLE_SYM role_list
          {
            List<LEX_USER> *users= new (YYMEM_ROOT) List<LEX_USER>;
            if (users == NULL || users->push_back($2))
              MYSQL_YYABORT;
            auto *tmp=
              NEW_PTN PT_alter_user_default_role(Lex->drop_if_exists,
                                                 users, $5,
                                                 role_enum::ROLE_NAME);
            MAKE_CMD(tmp);
          }
        | alter_user_command user opt_user_registration
          {
            if ($2->mfa_list.push_back($3))
              MYSQL_YYABORT;  // OOM
            LEX *lex=Lex;
            lex->users_list.push_front ($2);
          }
        | alter_user_command user_func opt_user_registration
          {
            if ($2->mfa_list.push_back($3))
              MYSQL_YYABORT;  // OOM
          }
        ;

opt_replace_password:
          /* empty */                       { $$ = LEX_CSTRING{nullptr, 0}; }
        | REPLACE_SYM TEXT_STRING_password  { $$ = to_lex_cstring($2); }
        ;

alter_resource_group_stmt:
          ALTER RESOURCE_SYM GROUP_SYM ident opt_resource_group_vcpu_list
          opt_resource_group_priority opt_resource_group_enable_disable
          opt_force
          {
            $$= NEW_PTN PT_alter_resource_group(to_lex_cstring($4),
                                                $5, $6, $7, $8);
          }
        ;

alter_user_command:
          ALTER USER if_exists
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_ALTER_USER;
            lex->drop_if_exists= $3;
          }
        ;

opt_user_attribute:
          /* empty */
          {
            LEX *lex= Lex;
            lex->alter_user_attribute =
              enum_alter_user_attribute::ALTER_USER_COMMENT_NOT_USED;
          }
        | ATTRIBUTE_SYM TEXT_STRING_literal
          {
            LEX *lex= Lex;
            lex->alter_user_attribute =
              enum_alter_user_attribute::ALTER_USER_ATTRIBUTE;
            lex->alter_user_comment_text = $2;
          }
        | COMMENT_SYM TEXT_STRING_literal
          {
            LEX *lex= Lex;
            lex->alter_user_attribute =
              enum_alter_user_attribute::ALTER_USER_COMMENT;
            lex->alter_user_comment_text = $2;
          }
        ;
opt_account_lock_password_expire_options:
          /* empty */ {}
        | opt_account_lock_password_expire_option_list
        ;

opt_account_lock_password_expire_option_list:
          opt_account_lock_password_expire_option
        | opt_account_lock_password_expire_option_list opt_account_lock_password_expire_option
        ;

opt_account_lock_password_expire_option:
          ACCOUNT_SYM UNLOCK_SYM
          {
            LEX *lex=Lex;
            lex->alter_password.update_account_locked_column= true;
            lex->alter_password.account_locked= false;
          }
        | ACCOUNT_SYM LOCK_SYM
          {
            LEX *lex=Lex;
            lex->alter_password.update_account_locked_column= true;
            lex->alter_password.account_locked= true;
          }
        | PASSWORD EXPIRE_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.expire_after_days= 0;
            lex->alter_password.update_password_expired_column= true;
            lex->alter_password.update_password_expired_fields= true;
            lex->alter_password.use_default_password_lifetime= true;
          }
        | PASSWORD EXPIRE_SYM INTERVAL_SYM real_ulong_num DAY_SYM
          {
            LEX *lex= Lex;
            if ($4 == 0 || $4 > UINT_MAX16)
            {
              char buf[MAX_BIGINT_WIDTH + 1];
              snprintf(buf, sizeof(buf), "%lu", $4);
              my_error(ER_WRONG_VALUE, MYF(0), "DAY", buf);
              MYSQL_YYABORT;
            }
            lex->alter_password.expire_after_days= $4;
            lex->alter_password.update_password_expired_column= false;
            lex->alter_password.update_password_expired_fields= true;
            lex->alter_password.use_default_password_lifetime= false;
          }
        | PASSWORD EXPIRE_SYM NEVER_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.expire_after_days= 0;
            lex->alter_password.update_password_expired_column= false;
            lex->alter_password.update_password_expired_fields= true;
            lex->alter_password.use_default_password_lifetime= false;
          }
        | PASSWORD EXPIRE_SYM DEFAULT_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.expire_after_days= 0;
            lex->alter_password.update_password_expired_column= false;
            Lex->alter_password.update_password_expired_fields= true;
            lex->alter_password.use_default_password_lifetime= true;
          }
        | PASSWORD HISTORY_SYM real_ulong_num
          {
            LEX *lex= Lex;
            lex->alter_password.password_history_length= $3;
            lex->alter_password.update_password_history= true;
            lex->alter_password.use_default_password_history= false;
          }
        | PASSWORD HISTORY_SYM DEFAULT_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.password_history_length= 0;
            lex->alter_password.update_password_history= true;
            lex->alter_password.use_default_password_history= true;
          }
        | PASSWORD REUSE_SYM INTERVAL_SYM real_ulong_num DAY_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.password_reuse_interval= $4;
            lex->alter_password.update_password_reuse_interval= true;
            lex->alter_password.use_default_password_reuse_interval= false;
          }
        | PASSWORD REUSE_SYM INTERVAL_SYM DEFAULT_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.password_reuse_interval= 0;
            lex->alter_password.update_password_reuse_interval= true;
            lex->alter_password.use_default_password_reuse_interval= true;
          }
        | PASSWORD REQUIRE_SYM CURRENT_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.update_password_require_current=
                Lex_acl_attrib_udyn::YES;
          }
        | PASSWORD REQUIRE_SYM CURRENT_SYM DEFAULT_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.update_password_require_current=
                Lex_acl_attrib_udyn::DEFAULT;
          }
        | PASSWORD REQUIRE_SYM CURRENT_SYM OPTIONAL_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.update_password_require_current=
                Lex_acl_attrib_udyn::NO;
          }
        | FAILED_LOGIN_ATTEMPTS_SYM real_ulong_num
          {
            LEX *lex= Lex;
            if ($2 > INT_MAX16) {
              char buf[MAX_BIGINT_WIDTH + 1];
              snprintf(buf, sizeof(buf), "%lu", $2);
              my_error(ER_WRONG_VALUE, MYF(0), "FAILED_LOGIN_ATTEMPTS", buf);
              MYSQL_YYABORT;
            }
            lex->alter_password.update_failed_login_attempts= true;
            lex->alter_password.failed_login_attempts= $2;
          }
        | PASSWORD_LOCK_TIME_SYM real_ulong_num
          {
            LEX *lex= Lex;
            if ($2 > INT_MAX16) {
              char buf[MAX_BIGINT_WIDTH + 1];
              snprintf(buf, sizeof(buf), "%lu", $2);
              my_error(ER_WRONG_VALUE, MYF(0), "PASSWORD_LOCK_TIME", buf);
              MYSQL_YYABORT;
            }
            lex->alter_password.update_password_lock_time= true;
            lex->alter_password.password_lock_time= $2;
          }
        | PASSWORD_LOCK_TIME_SYM UNBOUNDED_SYM
          {
            LEX *lex= Lex;
            lex->alter_password.update_password_lock_time= true;
            lex->alter_password.password_lock_time= -1;
          }
        ;

connect_options:
          /* empty */ {}
        | WITH connect_option_list
        ;

connect_option_list:
          connect_option_list connect_option {}
        | connect_option {}
        ;

connect_option:
          MAX_QUERIES_PER_HOUR ulong_num
          {
            LEX *lex=Lex;
            lex->mqh.questions=$2;
            lex->mqh.specified_limits|= USER_RESOURCES::QUERIES_PER_HOUR;
          }
        | MAX_UPDATES_PER_HOUR ulong_num
          {
            LEX *lex=Lex;
            lex->mqh.updates=$2;
            lex->mqh.specified_limits|= USER_RESOURCES::UPDATES_PER_HOUR;
          }
        | MAX_CONNECTIONS_PER_HOUR ulong_num
          {
            LEX *lex=Lex;
            lex->mqh.conn_per_hour= $2;
            lex->mqh.specified_limits|= USER_RESOURCES::CONNECTIONS_PER_HOUR;
          }
        | MAX_USER_CONNECTIONS_SYM ulong_num
          {
            LEX *lex=Lex;
            lex->mqh.user_conn= $2;
            lex->mqh.specified_limits|= USER_RESOURCES::USER_CONNECTIONS;
          }
        ;

user_func:
          USER '(' ')'
          {
            /* empty LEX_USER means current_user */
            LEX_USER *curr_user;
            if (!(curr_user= LEX_USER::alloc(YYTHD)))
              MYSQL_YYABORT;

            Lex->users_list.push_back(curr_user);
            $$= curr_user;
          }
        ;

ev_alter_on_schedule_completion:
          /* empty */ { $$= 0;}
        | ON_SYM SCHEDULE_SYM ev_schedule_time { $$= 1; }
        | ev_on_completion { $$= 1; }
        | ON_SYM SCHEDULE_SYM ev_schedule_time ev_on_completion { $$= 1; }
        ;

opt_ev_rename_to:
          /* empty */ { $$= 0;}
        | RENAME TO_SYM sp_name
          {
            /*
              Use lex's spname to hold the new name.
              The original name is in the Event_parse_data object
            */
            Lex->spname= $3;
            $$= 1;
          }
        ;

opt_ev_sql_stmt:
          /* empty*/ { $$= 0;}
        | DO_SYM ev_sql_stmt { $$= 1; }
        ;

ident_or_empty:
          /* empty */ { $$.str= 0; $$.length= 0; }
        | ident { $$= $1; }
        ;

opt_alter_table_actions:
          opt_alter_command_list
        | opt_alter_command_list alter_table_partition_options
          {
            $$= $1;
            if ($$.actions == NULL)
            {
              $$.actions= NEW_PTN Mem_root_array<PT_ddl_table_option *>(YYMEM_ROOT);
              if ($$.actions == NULL)
                MYSQL_YYABORT; // OOM
            }
            if ($$.actions->push_back($2))
              MYSQL_YYABORT; // OOM
          }
        ;

standalone_alter_table_action:
          standalone_alter_commands
          {
            $$.flags.init();
            $$.action= $1;
          }
        | alter_commands_modifier_list ',' standalone_alter_commands
          {
            $$.flags= $1;
            $$.action= $3;
          }
        ;

alter_table_partition_options:
          partition_clause
          {
            $$= NEW_PTN PT_alter_table_partition_by($1);
          }
        | REMOVE_SYM PARTITIONING_SYM
          {
            $$= NEW_PTN PT_alter_table_remove_partitioning;
          }
        ;

opt_alter_command_list:
          /* empty */
          {
            $$.flags.init();
            $$.actions= NULL;
          }
        | alter_commands_modifier_list
          {
            $$.flags= $1;
            $$.actions= NULL;
          }
        | alter_list
        | alter_commands_modifier_list ',' alter_list
          {
            $$.flags= $1;
            $$.flags.merge($3.flags);
            $$.actions= $3.actions;
          }
        ;

standalone_alter_commands:
          DISCARD_SYM TABLESPACE_SYM
          {
            $$= NEW_PTN PT_alter_table_discard_tablespace;
          }
        | IMPORT TABLESPACE_SYM
          {
            $$= NEW_PTN PT_alter_table_import_tablespace;
          }
/*
  This part was added for release 5.1 by Mikael Ronström.
  From here we insert a number of commands to manage the partitions of a
  partitioned table such as adding partitions, dropping partitions,
  reorganising partitions in various manners. In future releases the list
  will be longer.
*/
        | ADD PARTITION_SYM opt_no_write_to_binlog
          {
            $$= NEW_PTN PT_alter_table_add_partition($3);
          }
        | ADD PARTITION_SYM opt_no_write_to_binlog '(' part_def_list ')'
          {
            $$= NEW_PTN PT_alter_table_add_partition_def_list($3, $5);
          }
        | ADD PARTITION_SYM opt_no_write_to_binlog PARTITIONS_SYM real_ulong_num
          {
            $$= NEW_PTN PT_alter_table_add_partition_num($3, $5);
          }
        | DROP PARTITION_SYM ident_string_list
          {
            $$= NEW_PTN PT_alter_table_drop_partition(*$3);
          }
        | REBUILD_SYM PARTITION_SYM opt_no_write_to_binlog
          all_or_alt_part_name_list
          {
            $$= NEW_PTN PT_alter_table_rebuild_partition($3, $4);
          }
        | OPTIMIZE PARTITION_SYM opt_no_write_to_binlog
          all_or_alt_part_name_list
          {
            $$= NEW_PTN PT_alter_table_optimize_partition($3, $4);
          }
        | ANALYZE_SYM PARTITION_SYM opt_no_write_to_binlog
          all_or_alt_part_name_list
          {
            $$= NEW_PTN PT_alter_table_analyze_partition($3, $4);
          }
        | CHECK_SYM PARTITION_SYM all_or_alt_part_name_list opt_mi_check_types
          {
            $$= NEW_PTN PT_alter_table_check_partition($3,
                                                       $4.flags, $4.sql_flags);
          }
        | REPAIR PARTITION_SYM opt_no_write_to_binlog
          all_or_alt_part_name_list
          opt_mi_repair_types
          {
            $$= NEW_PTN PT_alter_table_repair_partition($3, $4,
                                                        $5.flags, $5.sql_flags);
          }
        | COALESCE PARTITION_SYM opt_no_write_to_binlog real_ulong_num
          {
            $$= NEW_PTN PT_alter_table_coalesce_partition($3, $4);
          }
        | TRUNCATE_SYM PARTITION_SYM all_or_alt_part_name_list
          {
            $$= NEW_PTN PT_alter_table_truncate_partition($3);
          }
        | REORGANIZE_SYM PARTITION_SYM opt_no_write_to_binlog
          {
            $$= NEW_PTN PT_alter_table_reorganize_partition($3);
          }
        | REORGANIZE_SYM PARTITION_SYM opt_no_write_to_binlog
          ident_string_list INTO '(' part_def_list ')'
          {
            $$= NEW_PTN PT_alter_table_reorganize_partition_into($3, *$4, $7);
          }
        | EXCHANGE_SYM PARTITION_SYM ident
          WITH TABLE_SYM table_ident opt_with_validation
          {
            $$= NEW_PTN PT_alter_table_exchange_partition($3, $6, $7);
          }
        | DISCARD_SYM PARTITION_SYM all_or_alt_part_name_list
          TABLESPACE_SYM
          {
            $$= NEW_PTN PT_alter_table_discard_partition_tablespace($3);
          }
        | IMPORT PARTITION_SYM all_or_alt_part_name_list
          TABLESPACE_SYM
          {
            $$= NEW_PTN PT_alter_table_import_partition_tablespace($3);
          }
        | SECONDARY_LOAD_SYM
          {
            $$= NEW_PTN PT_alter_table_secondary_load;
          }
        | SECONDARY_UNLOAD_SYM
          {
            $$= NEW_PTN PT_alter_table_secondary_unload;
          }
        ;

opt_with_validation:
          /* empty */ { $$= Alter_info::ALTER_VALIDATION_DEFAULT; }
        | with_validation
        ;

with_validation:
          WITH VALIDATION_SYM
          {
            $$= Alter_info::ALTER_WITH_VALIDATION;
          }
        | WITHOUT_SYM VALIDATION_SYM
          {
            $$= Alter_info::ALTER_WITHOUT_VALIDATION;
          }
        ;

all_or_alt_part_name_list:
          ALL                   { $$= NULL; }
        | ident_string_list
        ;

/*
  End of management of partition commands
*/

alter_list:
          alter_list_item
          {
            $$.flags.init();
            $$.actions= NEW_PTN Mem_root_array<PT_ddl_table_option *>(YYMEM_ROOT);
            if ($$.actions == NULL || $$.actions->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | alter_list ',' alter_list_item
          {
            if ($$.actions->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        | alter_list ',' alter_commands_modifier
          {
            $$.flags.merge($3);
          }
        | create_table_options_space_separated
          {
            $$.flags.init();
            $$.actions= $1;
          }
        | alter_list ',' create_table_options_space_separated
          {
            for (auto *option : *$3)
            {
              if ($1.actions->push_back(option))
                MYSQL_YYABORT; // OOM
            }
          }
        ;

alter_commands_modifier_list:
          alter_commands_modifier
        | alter_commands_modifier_list ',' alter_commands_modifier
          {
            $$= $1;
            $$.merge($3);
          }
        ;

alter_list_item:
          ADD opt_column ident field_def opt_references opt_place
          {
            $$= NEW_PTN PT_alter_table_add_column($3, $4, $5, $6);
          }
%ifdef SQL_MODE_ORACLE
        | ADD opt_column ident ora_udt_ident
          {
            PT_udt_type *udt_type= NEW_PTN PT_udt_type(Char_type::VARCHAR, $4, &my_charset_bin);
            PT_field_def *field_def= NEW_PTN PT_field_def(udt_type, nullptr);
            $$= NEW_PTN PT_alter_table_add_column($3, field_def, nullptr, nullptr);
          }
%endif
        | ADD opt_column '(' table_element_list ')'
          {
            $$= NEW_PTN PT_alter_table_add_columns($4);
          }
        | ADD table_constraint_def
          {
            $$= NEW_PTN PT_alter_table_add_constraint($2);
          }
        | CHANGE opt_column ident ident field_def opt_place
          {
            $$= NEW_PTN PT_alter_table_change_column($3, $4, $5, $6);
          }
        | MODIFY_SYM opt_column ident field_def opt_place
          {
            $$= NEW_PTN PT_alter_table_change_column($3, $4, $5);
          }
        | DROP opt_column ident opt_restrict
          {
            // Note: opt_restrict ($4) is ignored!
            $$= NEW_PTN PT_alter_table_drop_column($3.str);
          }
        | DROP FOREIGN KEY_SYM ident
          {
            $$= NEW_PTN PT_alter_table_drop_foreign_key($4.str);
          }
        | DROP PRIMARY_SYM KEY_SYM
          {
            $$= NEW_PTN PT_alter_table_drop_key(primary_key_name);
          }
        | DROP key_or_index ident
          {
            $$= NEW_PTN PT_alter_table_drop_key($3.str);
          }
        | DROP CHECK_SYM ident
          {
            $$= NEW_PTN PT_alter_table_drop_check_constraint($3.str);
          }
        | DROP CONSTRAINT ident
          {
            $$= NEW_PTN PT_alter_table_drop_constraint($3.str);
          }
        | DISABLE_SYM KEYS
          {
            $$= NEW_PTN PT_alter_table_enable_keys(false);
          }
        | ENABLE_SYM KEYS
          {
            $$= NEW_PTN PT_alter_table_enable_keys(true);
          }
        | ALTER opt_column ident SET_SYM DEFAULT_SYM signed_literal_or_null
          {
            $$= NEW_PTN PT_alter_table_set_default($3.str, $6);
          }
        |  ALTER opt_column ident SET_SYM DEFAULT_SYM '(' expr ')'
          {
            $$= NEW_PTN PT_alter_table_set_default($3.str, $7);
          }
        | ALTER opt_column ident DROP DEFAULT_SYM
          {
            $$= NEW_PTN PT_alter_table_set_default($3.str, NULL);
          }

        | ALTER opt_column ident SET_SYM visibility
          {
            $$= NEW_PTN PT_alter_table_column_visibility($3.str, $5);
          }
        | ALTER INDEX_SYM ident visibility
          {
            $$= NEW_PTN PT_alter_table_index_visible($3.str, $4);
          }
        | ALTER CHECK_SYM ident constraint_enforcement
          {
            $$ = NEW_PTN PT_alter_table_enforce_check_constraint($3.str, $4);
          }
        | ALTER CONSTRAINT ident constraint_enforcement
          {
            $$ = NEW_PTN PT_alter_table_enforce_constraint($3.str, $4);
          }
        | RENAME opt_to table_ident
          {
            $$= NEW_PTN PT_alter_table_rename($3);
          }
        | RENAME key_or_index ident TO_SYM ident
          {
            $$= NEW_PTN PT_alter_table_rename_key($3.str, $5.str);
          }
        | RENAME COLUMN_SYM ident TO_SYM ident
          {
            $$= NEW_PTN PT_alter_table_rename_column($3.str, $5.str);
          }
        | CONVERT_SYM TO_SYM character_set charset_name opt_collate
          {
            $$= NEW_PTN PT_alter_table_convert_to_charset($4, $5);
          }
        | CONVERT_SYM TO_SYM character_set DEFAULT_SYM opt_collate
          {
            $$ = NEW_PTN PT_alter_table_convert_to_charset(
                YYTHD->variables.collation_database,
                $5 ? $5 : YYTHD->variables.collation_database);
          }
        | FORCE_SYM
          {
            $$= NEW_PTN PT_alter_table_force;
          }
        | ORDER_SYM BY alter_order_list
          {
            $$= NEW_PTN PT_alter_table_order($3);
          }
        ;

alter_commands_modifier:
          alter_algorithm_option
          {
            $$.init();
            $$.algo.set($1);
          }
        | alter_lock_option
          {
            $$.init();
            $$.lock.set($1);
          }
        | with_validation
          {
            $$.init();
            $$.validation.set($1);
          }
        ;

opt_index_lock_and_algorithm:
          /* Empty. */ { $$.init(); }
        | alter_lock_option
          {
            $$.init();
            $$.lock.set($1);
          }
        | alter_algorithm_option
          {
            $$.init();
            $$.algo.set($1);
          }
        | alter_lock_option alter_algorithm_option
          {
            $$.init();
            $$.lock.set($1);
            $$.algo.set($2);
          }
        | alter_algorithm_option alter_lock_option
          {
            $$.init();
            $$.algo.set($1);
            $$.lock.set($2);
          }
        ;

alter_algorithm_option:
          ALGORITHM_SYM opt_equal alter_algorithm_option_value { $$= $3; }
        ;

alter_algorithm_option_value:
          DEFAULT_SYM
          {
            $$= Alter_info::ALTER_TABLE_ALGORITHM_DEFAULT;
          }
        | ident
          {
            if (is_identifier($1, "INPLACE"))
              $$= Alter_info::ALTER_TABLE_ALGORITHM_INPLACE;
            else if (is_identifier($1, "INSTANT"))
              $$= Alter_info::ALTER_TABLE_ALGORITHM_INSTANT;
            else if (is_identifier($1, "COPY"))
              $$= Alter_info::ALTER_TABLE_ALGORITHM_COPY;
            else
            {
              my_error(ER_UNKNOWN_ALTER_ALGORITHM, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
          }
        ;

alter_lock_option:
          LOCK_SYM opt_equal alter_lock_option_value { $$= $3; }
        ;

alter_lock_option_value:
          DEFAULT_SYM
          {
            $$= Alter_info::ALTER_TABLE_LOCK_DEFAULT;
          }
        | ident
          {
            if (is_identifier($1, "NONE"))
              $$= Alter_info::ALTER_TABLE_LOCK_NONE;
            else if (is_identifier($1, "SHARED"))
              $$= Alter_info::ALTER_TABLE_LOCK_SHARED;
            else if (is_identifier($1, "EXCLUSIVE"))
              $$= Alter_info::ALTER_TABLE_LOCK_EXCLUSIVE;
            else
            {
              my_error(ER_UNKNOWN_ALTER_LOCK, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
          }
        ;

opt_column:
          /* empty */
        | COLUMN_SYM
        ;

opt_ignore:
          /* empty */ { $$= false; }
        | IGNORE_SYM  { $$= true; }
        ;

opt_restrict:
          /* empty */ { $$= DROP_DEFAULT; }
        | RESTRICT    { $$= DROP_RESTRICT; }
        | CASCADE     { $$= DROP_CASCADE; }
        ;

opt_place:
          /* empty */           { $$= NULL; }
        | AFTER_SYM ident       { $$= $2.str; }
        | FIRST_SYM             { $$= first_keyword; }
        ;

opt_to:
          /* empty */ {}
        | TO_SYM {}
        | EQ {}
        | AS {}
        ;

group_replication:
          group_replication_start opt_group_replication_start_options
        | STOP_SYM GROUP_REPLICATION
          {
            LEX *lex = Lex;
            lex->sql_command = SQLCOM_STOP_GROUP_REPLICATION;
          }
        ;

group_replication_start:
          START_SYM GROUP_REPLICATION
          {
            LEX *lex = Lex;
            lex->slave_connection.reset();
            lex->sql_command = SQLCOM_START_GROUP_REPLICATION;
          }
        ;

opt_group_replication_start_options:
          /* empty */
        | group_replication_start_options
        ;

group_replication_start_options:
          group_replication_start_option
        | group_replication_start_options ',' group_replication_start_option
        ;

group_replication_start_option:
          group_replication_user
        | group_replication_password
        | group_replication_plugin_auth
        ;

group_replication_user:
          USER EQ TEXT_STRING_sys_nonewline
          {
            Lex->slave_connection.user = $3.str;
            if ($3.length == 0)
            {
              my_error(ER_GROUP_REPLICATION_USER_EMPTY_MSG, MYF(0));
              MYSQL_YYABORT;
            }
          }
        ;

group_replication_password:
          PASSWORD EQ TEXT_STRING_sys_nonewline
          {
            Lex->slave_connection.password = $3.str;
            Lex->contains_plaintext_password = true;
            if ($3.length > 32)
            {
              my_error(ER_GROUP_REPLICATION_PASSWORD_LENGTH, MYF(0));
              MYSQL_YYABORT;
            }
          }
        ;

group_replication_plugin_auth:
          DEFAULT_AUTH_SYM EQ TEXT_STRING_sys_nonewline
          {
            Lex->slave_connection.plugin_auth= $3.str;
          }
        ;

replica:
        SLAVE { Lex->set_replication_deprecated_syntax_used(); }
      | REPLICA_SYM
      ;

stop_replica_stmt:
          STOP_SYM replica opt_replica_thread_option_list opt_channel
          {
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_SLAVE_STOP;
            lex->type = 0;
            lex->slave_thd_opt= $3;
            if (lex->is_replication_deprecated_syntax_used())
              push_deprecated_warn(YYTHD, "STOP SLAVE", "STOP REPLICA");
            if (lex->set_channel_name($4))
              MYSQL_YYABORT;  // OOM
          }
        ;

start_replica_stmt:
          START_SYM replica opt_replica_thread_option_list
          {
            LEX *lex=Lex;
            /* Clean previous replica connection values */
            lex->slave_connection.reset();
            lex->sql_command = SQLCOM_SLAVE_START;
            lex->type = 0;
            /* We'll use mi structure for UNTIL options */
            lex->mi.set_unspecified();
            lex->slave_thd_opt= $3;
            if (lex->is_replication_deprecated_syntax_used())
              push_deprecated_warn(YYTHD, "START SLAVE", "START REPLICA");
          }
          opt_replica_until
          opt_user_option opt_password_option
          opt_default_auth_option opt_plugin_dir_option
          {
            /*
              It is not possible to set user's information when
              one is trying to start the SQL Thread.
            */
            if ((Lex->slave_thd_opt & SLAVE_SQL) == SLAVE_SQL &&
                (Lex->slave_thd_opt & SLAVE_IO) != SLAVE_IO &&
                (Lex->slave_connection.user ||
                 Lex->slave_connection.password ||
                 Lex->slave_connection.plugin_auth ||
                 Lex->slave_connection.plugin_dir))
            {
              my_error(ER_SQLTHREAD_WITH_SECURE_SLAVE, MYF(0));
              MYSQL_YYABORT;
            }
          }
          opt_channel
          {
            if (Lex->set_channel_name($11))
              MYSQL_YYABORT;  // OOM
          }
        ;

start:
          START_SYM TRANSACTION_SYM opt_start_transaction_option_list
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_BEGIN;
            /* READ ONLY and READ WRITE are mutually exclusive. */
            if (($3 & MYSQL_START_TRANS_OPT_READ_WRITE) &&
                ($3 & MYSQL_START_TRANS_OPT_READ_ONLY))
            {
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            lex->start_transaction_opt= $3;
          }
        ;

opt_start_transaction_option_list:
          /* empty */
          {
            $$= 0;
          }
        | start_transaction_option_list
          {
            $$= $1;
          }
        ;

start_transaction_option_list:
          start_transaction_option
          {
            $$= $1;
          }
        | start_transaction_option_list ',' start_transaction_option
          {
            $$= $1 | $3;
          }
        ;

start_transaction_option:
          WITH CONSISTENT_SYM SNAPSHOT_SYM
          {
            $$= MYSQL_START_TRANS_OPT_WITH_CONS_SNAPSHOT;
          }
        | WITH CONSISTENT_SYM SNAPSHOT_SYM FROM SESSION_SYM expr
          {
            ITEMIZE($6, &$6);

            $$= MYSQL_START_TRANS_OPT_WITH_CONS_SNAPSHOT;
            Lex->donor_transaction_id= $6;
          }
        | READ_SYM ONLY_SYM
          {
            $$= MYSQL_START_TRANS_OPT_READ_ONLY;
          }
        | READ_SYM WRITE_SYM
          {
            $$= MYSQL_START_TRANS_OPT_READ_WRITE;
          }
        ;

opt_user_option:
          {
            /* empty */
          }
        | USER EQ TEXT_STRING_sys
          {
            Lex->slave_connection.user= $3.str;
          }
        ;

opt_password_option:
          {
            /* empty */
          }
        | PASSWORD EQ TEXT_STRING_sys
          {
            Lex->slave_connection.password= $3.str;
            Lex->contains_plaintext_password= true;
          }

opt_default_auth_option:
          {
            /* empty */
          }
        | DEFAULT_AUTH_SYM EQ TEXT_STRING_sys
          {
            Lex->slave_connection.plugin_auth= $3.str;
          }
        ;

opt_plugin_dir_option:
          {
            /* empty */
          }
        | PLUGIN_DIR_SYM EQ TEXT_STRING_sys
          {
            Lex->slave_connection.plugin_dir= $3.str;
          }
        ;

opt_replica_thread_option_list:
          /* empty */
          {
            $$= 0;
          }
        | replica_thread_option_list
          {
            $$= $1;
          }
        ;

replica_thread_option_list:
          replica_thread_option
          {
            $$= $1;
          }
        | replica_thread_option_list ',' replica_thread_option
          {
            $$= $1 | $3;
          }
        ;

replica_thread_option:
          SQL_THREAD
          {
            $$= SLAVE_SQL;
          }
        | RELAY_THREAD
          {
            $$= SLAVE_IO;
          }
        ;

opt_replica_until:
          /*empty*/
          {
            LEX *lex= Lex;
            lex->mi.slave_until= false;
          }
        | UNTIL_SYM replica_until
          {
            LEX *lex=Lex;
            if (((lex->mi.log_file_name || lex->mi.pos) &&
                lex->mi.gtid) ||
               ((lex->mi.relay_log_name || lex->mi.relay_log_pos) &&
                lex->mi.gtid) ||
                !((lex->mi.log_file_name && lex->mi.pos) ||
                  (lex->mi.relay_log_name && lex->mi.relay_log_pos) ||
                  lex->mi.gtid ||
                  lex->mi.until_after_gaps) ||
                /* SQL_AFTER_MTS_GAPS is meaningless in combination */
                /* with any other coordinates related options       */
                ((lex->mi.log_file_name || lex->mi.pos || lex->mi.relay_log_name
                  || lex->mi.relay_log_pos || lex->mi.gtid)
                 && lex->mi.until_after_gaps))
            {
               my_error(ER_BAD_SLAVE_UNTIL_COND, MYF(0));
               MYSQL_YYABORT;
            }
            lex->mi.slave_until= true;
          }
        ;

replica_until:
          source_file_def
        | replica_until ',' source_file_def
        | SQL_BEFORE_GTIDS EQ TEXT_STRING_sys
          {
            Lex->mi.gtid= $3.str;
            Lex->mi.gtid_until_condition= LEX_MASTER_INFO::UNTIL_SQL_BEFORE_GTIDS;
          }
        | SQL_AFTER_GTIDS EQ TEXT_STRING_sys
          {
            Lex->mi.gtid= $3.str;
            Lex->mi.gtid_until_condition= LEX_MASTER_INFO::UNTIL_SQL_AFTER_GTIDS;
          }
        | SQL_AFTER_MTS_GAPS
          {
            Lex->mi.until_after_gaps= true;
          }
        ;

checksum:
          CHECKSUM_SYM table_or_tables table_list opt_checksum_type
          {
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_CHECKSUM;
            /* Will be overriden during execution. */
            YYPS->m_lock_type= TL_UNLOCK;
            if (Select->add_tables(YYTHD, $3, TL_OPTION_UPDATING,
                                   YYPS->m_lock_type, YYPS->m_mdl_type))
              MYSQL_YYABORT;
            Lex->check_opt.flags= $4;
          }
        ;

opt_checksum_type:
          /* empty */   { $$= 0; }
        | QUICK         { $$= T_QUICK; }
        | EXTENDED_SYM  { $$= T_EXTEND; }
        ;

repair_table_stmt:
          REPAIR opt_no_write_to_binlog table_or_tables
          table_list opt_mi_repair_types
          {
            $$= NEW_PTN PT_repair_table_stmt(YYMEM_ROOT, $2, $4,
                                             $5.flags, $5.sql_flags);
          }
        ;

opt_mi_repair_types:
          /* empty */ { $$.flags = T_MEDIUM; $$.sql_flags= 0; }
        | mi_repair_types
        ;

mi_repair_types:
          mi_repair_type
        | mi_repair_types mi_repair_type
          {
            $$.flags= $1.flags | $2.flags;
            $$.sql_flags= $1.sql_flags | $2.sql_flags;
          }
        ;

mi_repair_type:
          QUICK        { $$.flags= T_QUICK;  $$.sql_flags= 0; }
        | EXTENDED_SYM { $$.flags= T_EXTEND; $$.sql_flags= 0; }
        | USE_FRM      { $$.flags= 0;        $$.sql_flags= TT_USEFRM; }
        ;

analyze_table_stmt:
          ANALYZE_SYM opt_no_write_to_binlog table_or_tables table_list
          opt_histogram
          {
            if ($5.param) {
              $$= NEW_PTN PT_analyze_table_stmt(YYMEM_ROOT, $1, $2, $4,
                                                $5.command, $5.param->num_buckets,
                                                $5.columns, $5.param->data);
            } else {
              $$= NEW_PTN PT_analyze_table_stmt(YYMEM_ROOT, $1, $2, $4,
                                                $5.command, 0,
                                                $5.columns, {nullptr, 0});
            }
          }
        ;

opt_histogram_update_param:
          /* empty */
          {
            $$.num_buckets= DEFAULT_NUMBER_OF_HISTOGRAM_BUCKETS;
            $$.data= { nullptr, 0 };
          }
        | WITH NUM BUCKETS_SYM
          {
            int error;
            longlong num= my_strtoll10($2.str, nullptr, &error);
            MYSQL_YYABORT_UNLESS(error <= 0);

            if (num < 1 || num > MAX_NUMBER_OF_HISTOGRAM_BUCKETS)
            {
              my_error(ER_DATA_OUT_OF_RANGE, MYF(0), "Number of buckets",
                       "ANALYZE TABLE");
              MYSQL_YYABORT;
            }

            $$.num_buckets= num;
            $$.data= { nullptr, 0 };
          }
        | USING DATA_SYM TEXT_STRING_literal
          {
            $$.num_buckets= 0;
            $$.data= $3;
          }
        ;

opt_histogram:
          /* empty */
          {
            $$.command= Sql_cmd_analyze_table::Histogram_command::NONE;
            $$.columns= nullptr;
            $$.param= nullptr;
          }
        | UPDATE_SYM HISTOGRAM_SYM ON_SYM ident_string_list opt_histogram_update_param
          {
            $$.command=
              Sql_cmd_analyze_table::Histogram_command::UPDATE_HISTOGRAM;
            $$.columns= $4;
            $$.param= NEW_PTN YYSTYPE::Histogram_param($5);
            if ($$.param == nullptr)
              MYSQL_YYABORT; // OOM
          }
        | DROP HISTOGRAM_SYM ON_SYM ident_string_list
          {
            $$.command=
              Sql_cmd_analyze_table::Histogram_command::DROP_HISTOGRAM;
            $$.columns= $4;
            $$.param = nullptr;
          }
        ;

binlog_base64_event:
          BINLOG_SYM TEXT_STRING_sys
          {
            Lex->sql_command = SQLCOM_BINLOG_BASE64_EVENT;
            Lex->binlog_stmt_arg= $2;
          }
        ;

check_table_stmt:
          CHECK_SYM table_or_tables table_list opt_mi_check_types
          {
            $$= NEW_PTN PT_check_table_stmt(YYMEM_ROOT, $1, $3,
                                            $4.flags, $4.sql_flags);
          }
        ;

opt_mi_check_types:
          /* empty */ { $$.flags = T_MEDIUM; $$.sql_flags= 0; }
        | mi_check_types
        ;

mi_check_types:
          mi_check_type
        | mi_check_type mi_check_types
          {
            $$.flags= $1.flags | $2.flags;
            $$.sql_flags= $1.sql_flags | $2.sql_flags;
          }
        ;

mi_check_type:
          QUICK
          { $$.flags= T_QUICK;              $$.sql_flags= 0; }
        | FAST_SYM
          { $$.flags= T_FAST;               $$.sql_flags= 0; }
        | MEDIUM_SYM
          { $$.flags= T_MEDIUM;             $$.sql_flags= 0; }
        | EXTENDED_SYM
          { $$.flags= T_EXTEND;             $$.sql_flags= 0; }
        | CHANGED
          { $$.flags= T_CHECK_ONLY_CHANGED; $$.sql_flags= 0; }
        | FOR_SYM UPGRADE_SYM
          { $$.flags= 0;                    $$.sql_flags= TT_FOR_UPGRADE; }
        ;

optimize_table_stmt:
          OPTIMIZE opt_no_write_to_binlog table_or_tables table_list
          {
            $$= NEW_PTN PT_optimize_table_stmt(YYMEM_ROOT, $1, $2, $4);
          }
        ;

opt_no_write_to_binlog:
          /* empty */ { $$= 0; }
        | NO_WRITE_TO_BINLOG { $$= 1; }
        | LOCAL_SYM { $$= 1; }
        ;

rename:
          RENAME table_or_tables
          {
            Lex->sql_command= SQLCOM_RENAME_TABLE;
          }
          table_to_table_list
          {}
        | RENAME USER rename_list
          {
            Lex->sql_command = SQLCOM_RENAME_USER;
          }
        ;

rename_list:
          user TO_SYM user
          {
            if (Lex->users_list.push_back($1) || Lex->users_list.push_back($3))
              MYSQL_YYABORT;
          }
        | rename_list ',' user TO_SYM user
          {
            if (Lex->users_list.push_back($3) || Lex->users_list.push_back($5))
              MYSQL_YYABORT;
          }
        ;

table_to_table_list:
          table_to_table
        | table_to_table_list ',' table_to_table
        ;

table_to_table:
          table_ident TO_SYM table_ident
          {
            LEX *lex=Lex;
            Query_block *sl= Select;
            if (!sl->add_table_to_list(lex->thd, $1,NULL,TL_OPTION_UPDATING,
                                       TL_IGNORE, MDL_EXCLUSIVE) ||
                !sl->add_table_to_list(lex->thd, $3,NULL,TL_OPTION_UPDATING,
                                       TL_IGNORE, MDL_EXCLUSIVE))
              MYSQL_YYABORT;
          }
        ;

keycache_stmt:
          CACHE_SYM INDEX_SYM keycache_list IN_SYM key_cache_name
          {
            $$= NEW_PTN PT_cache_index_stmt(YYMEM_ROOT, $3, $5);
          }
        | CACHE_SYM INDEX_SYM table_ident adm_partition opt_cache_key_list
          IN_SYM key_cache_name
          {
            $$= NEW_PTN PT_cache_index_partitions_stmt(YYMEM_ROOT,
                                                       $3, $4, $5, $7);
          }
        ;

keycache_list:
          assign_to_keycache
          {
            $$= NEW_PTN Mem_root_array<PT_assign_to_keycache *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | keycache_list ',' assign_to_keycache
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

assign_to_keycache:
          table_ident opt_cache_key_list
          {
            $$= NEW_PTN PT_assign_to_keycache($1, $2);
          }
        ;

key_cache_name:
          ident    { $$= to_lex_cstring($1); }
        | DEFAULT_SYM { $$ = default_key_cache_base; }
        ;

preload_stmt:
          LOAD INDEX_SYM INTO CACHE_SYM
          table_ident adm_partition opt_cache_key_list opt_ignore_leaves
          {
            $$= NEW_PTN PT_load_index_partitions_stmt(YYMEM_ROOT, $5,$6, $7, $8);
          }
        | LOAD INDEX_SYM INTO CACHE_SYM preload_list
          {
            $$= NEW_PTN PT_load_index_stmt(YYMEM_ROOT, $1, $5);
          }
        ;

preload_list:
          preload_keys
          {
            $$= NEW_PTN Mem_root_array<PT_preload_keys *>(YYMEM_ROOT);
            if ($$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | preload_list ',' preload_keys
          {
            $$= $1;
            if ($$ == NULL || $$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

preload_keys:
          table_ident opt_cache_key_list opt_ignore_leaves
          {
            $$= NEW_PTN PT_preload_keys($1, $2, $3);
          }
        ;

adm_partition:
          PARTITION_SYM '(' all_or_alt_part_name_list ')'
          {
            $$= NEW_PTN PT_adm_partition($3);
          }
        ;

opt_cache_key_list:
          /* empty */ { $$= NULL; }
        | key_or_index '(' opt_key_usage_list ')'
          {
            init_index_hints($3, INDEX_HINT_USE,
                             old_mode ? INDEX_HINT_MASK_JOIN
                                      : INDEX_HINT_MASK_ALL);
            $$= $3;
          }
        ;

opt_ignore_leaves:
          /* empty */       { $$= false; }
        | IGNORE_SYM LEAVES { $$= true; }
        ;

select_stmt:
          query_expression
          {
            $$ = NEW_PTN PT_select_stmt($1);
          }
        | query_expression locking_clause_list
          {
            $$ = NEW_PTN PT_select_stmt(NEW_PTN PT_locking($1, $2),
                                        nullptr, true);
          }
        | select_stmt_with_into
        ;

/*
  MySQL has a syntax extension that allows into clauses in any one of two
  places. They may appear either before the from clause or at the end. All in
  a top-level select statement. This extends the standard syntax in two
  ways. First, we don't have the restriction that the result can contain only
  one row: the into clause might be INTO OUTFILE/DUMPFILE in which case any
  number of rows is allowed. Hence MySQL does not have any special case for
  the standard's <select statement: single row>. Secondly, and this has more
  severe implications for the parser, it makes the grammar ambiguous, because
  in a from-clause-less select statement with an into clause, it is not clear
  whether the into clause is the leading or the trailing one.

  While it's possible to write an unambiguous grammar, it would force us to
  duplicate the entire <select statement> syntax all the way down to the <into
  clause>. So instead we solve it by writing an ambiguous grammar and use
  precedence rules to sort out the shift/reduce conflict.

  The problem is when the parser has seen SELECT <select list>, and sees an
  INTO token. It can now either shift it or reduce what it has to a table-less
  query expression. If it shifts the token, it will accept seeing a FROM token
  next and hence the INTO will be interpreted as the leading INTO. If it
  reduces what it has seen to a table-less select, however, it will interpret
  INTO as the trailing into. But what if the next token is FROM? Obviously,
  we want to always shift INTO. We do this by two precedence declarations: We
  make the INTO token right-associative, and we give it higher precedence than
  an empty from clause, using the artificial token EMPTY_FROM_CLAUSE.

  The remaining problem is that now we allow the leading INTO anywhere, when
  it should be allowed on the top level only. We solve this by manually
  throwing parse errors whenever we reduce a nested query expression if it
  contains an into clause.
*/
select_stmt_with_into:
          '(' select_stmt_with_into ')'
          {
            $$ = $2;
          }
        | query_expression into_clause
          {
            $$ = NEW_PTN PT_select_stmt($1, $2);
          }
        | query_expression into_clause locking_clause_list
          {
            $$ = NEW_PTN PT_select_stmt(NEW_PTN PT_locking($1, $3), $2, true);
          }
        | query_expression locking_clause_list into_clause
          {
            $$ = NEW_PTN PT_select_stmt(NEW_PTN PT_locking($1, $2), $3);
          }
        ;

/**
  A <query_expression> within parentheses can be used as an <expr>. Now,
  because both a <query_expression> and an <expr> can appear syntactically
  within any number of parentheses, we get an ambiguous grammar: Where do the
  parentheses belong? Techically, we have to tell Bison by which rule to
  reduce the extra pair of parentheses. We solve it in a somewhat tedious way
  by defining a query_expression so that it can't have enclosing
  parentheses. This forces us to be very explicit about exactly where we allow
  parentheses; while the standard defines only one rule for <query expression>
  parentheses, we have to do it in several places. But this is a blessing in
  disguise, as we are able to define our syntax in a more fine-grained manner,
  and this is necessary in order to support some MySQL extensions, for example
  as in the last two sub-rules here.

  Even if we define a query_expression not to have outer parentheses, we still
  get a shift/reduce conflict for the <subquery> rule, but we solve this by
  using an artifical token SUBQUERY_AS_EXPR that has less priority than
  parentheses. This ensures that the parser consumes as many parentheses as it
  can, and only when that fails will it try to reduce, and by then it will be
  clear from the lookahead token whether we have a subquery or just a
  query_expression within parentheses. For example, if the lookahead token is
  UNION it's just a query_expression within parentheses and the parentheses
  don't mean it's a subquery. If the next token is PLUS, we know it must be an
  <expr> and the parentheses really mean it's a subquery.

  A word about CTE's: The rules below are duplicated, one with a with_clause
  and one without, instead of using a single rule with an opt_with_clause. The
  reason we do this is because it would make Bison try to cram both rules into
  a single state, where it would have to decide whether to reduce a with_clause
  before seeing the rest of the input. This way we force Bison to parse the
  entire query expression before trying to reduce.
*/
query_expression:
          query_expression_body
          opt_order_clause
          opt_limit_clause
          {
            $$ = NEW_PTN PT_query_expression($1.body, $2, $3);
          }
        | with_clause
          query_expression_body
          opt_order_clause
          opt_limit_clause
          {
            $$= NEW_PTN PT_query_expression($1, $2.body, $3, $4);
          }
        ;

query_expression_body:
          query_primary
          {
            $$ = {$1, false};
          }
        | query_expression_parens %prec SUBQUERY_AS_EXPR
          {
            $$ = {$1, true};
          }
        | query_expression_body UNION_SYM union_option query_expression_body
          {
            $$ = {NEW_PTN PT_union($1.body, $3, $4.body, $4.is_parenthesized),
                  false};
          }
        | query_expression_body EXCEPT_SYM union_option query_expression_body
          {
            $$ = {NEW_PTN PT_except($1.body, $3, $4.body, $4.is_parenthesized),
                  false};
          }
        | query_expression_body INTERSECT_SYM union_option query_expression_body
          {
            $$ = {NEW_PTN PT_intersect($1.body, $3, $4.body, $4.is_parenthesized),
                  false};
          }
        | query_expression_body MINUS_SYM query_expression_body
          {
            $$ = {NEW_PTN PT_except($1.body, true, $3.body, $3.is_parenthesized),
                  false};
          }
        ;

query_expression_parens:
          '(' query_expression_parens ')'                       { $$ = $2; }
        | '(' query_expression_with_opt_locking_clauses')'      { $$ = $2; }
        ;

query_primary:
          query_specification
          {
            // Bison doesn't get polymorphism.
            $$= $1;
          }
        | table_value_constructor
          {
            $$= NEW_PTN PT_table_value_constructor($1);
          }
        | explicit_table
          {
            auto item_list= NEW_PTN PT_select_item_list;
            auto asterisk= NEW_PTN Item_asterisk(@$, nullptr, nullptr);
            if (item_list == nullptr || asterisk == nullptr ||
                item_list->push_back(asterisk))
              MYSQL_YYABORT;
            $$= NEW_PTN PT_explicit_table({}, item_list, $1);
          }
        ;

query_specification:
          SELECT_SYM
          select_options
          select_item_list
          into_clause
          opt_from_clause
          opt_where_clause
          opt_connect_clause
          opt_group_clause
          opt_having_clause
          opt_window_clause
          {
            $$= NEW_PTN PT_query_specification(
                                      $1,  // SELECT_SYM
                                      $2,  // select_options
                                      $3,  // select_item_list
                                      $4,  // into_clause
                                      $5,  // from
                                      $6,  // where
                                      $7,  // connect by
                                      $8,  // group
                                      $9,  // having
                                      $10,  // windows
                                      @5.raw.is_empty()); // implicit FROM
          }
        | SELECT_SYM
          select_options
          select_item_list
          opt_from_clause
          opt_where_clause
          opt_connect_clause
          opt_group_clause
          opt_having_clause
          opt_window_clause
          {
            $$= NEW_PTN PT_query_specification(
                                      $1,  // SELECT_SYM
                                      $2,  // select_options
                                      $3,  // select_item_list
                                      NULL,// no INTO clause
                                      $4,  // from
                                      $5,  // where
                                      $6,  // connect by
                                      $7,  // group
                                      $8,  // having
                                      $9,  // windows
                                      @4.raw.is_empty()); // implicit FROM
          }
        ;

opt_from_clause:
          /* Empty. */ %prec EMPTY_FROM_CLAUSE { $$.init(YYMEM_ROOT); }
        | from_clause
        ;

from_clause:
          FROM from_tables { $$= $2; }
        ;

from_tables:
          DUAL_SYM { $$.init(YYMEM_ROOT); }
        | table_reference_list
        ;

table_reference_list:
          table_reference
          {
            $$.init(YYMEM_ROOT);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | table_reference_list ',' table_reference
          {
            $$= $1;
            if ($$.push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

table_value_constructor:
          VALUES values_row_list
          {
            $$= $2;
          }
        ;

explicit_table:
          TABLE_SYM table_ident
          {
            $$.init(YYMEM_ROOT);
            auto table= NEW_PTN
                PT_table_factor_table_ident($2, nullptr, NULL_CSTR, nullptr);
            if ($$.push_back(table))
              MYSQL_YYABORT; // OOM
          }
        ;

select_options:
          /* empty*/
          {
            $$.query_spec_options= 0;
          }
        | select_option_list
        ;

select_option_list:
          select_option_list select_option
          {
            if ($$.merge($1, $2))
              MYSQL_YYABORT;
          }
        | select_option
        ;

select_option:
          query_spec_option
          {
            $$.query_spec_options= $1;
          }
        | SQL_NO_CACHE_SYM
          {
            push_deprecated_warn_no_replacement(YYTHD, "SQL_NO_CACHE");
            /* Ignored since MySQL 8.0. */
            $$.query_spec_options= 0;
          }
        ;

locking_clause_list:
          locking_clause_list locking_clause
          {
            $$= $1;
            if ($$->push_back($2))
              MYSQL_YYABORT; // OOM
          }
        | locking_clause
          {
            $$= NEW_PTN PT_locking_clause_list(YYTHD->mem_root);
            if ($$ == nullptr || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        ;

locking_clause:
          FOR_SYM lock_strength opt_locked_row_action
          {
            $$= NEW_PTN PT_query_block_locking_clause($2, $3);
          }
%ifndef SQL_MODE_ORACLE
        | FOR_SYM lock_strength table_locking_list opt_locked_row_action
          {
            $$= NEW_PTN PT_table_locking_clause($2, $3, $4);
          }
%endif
        | LOCK_SYM IN_SYM SHARE_SYM MODE_SYM
          {
            $$= NEW_PTN PT_query_block_locking_clause(Lock_strength::SHARE);
          }
%ifdef SQL_MODE_ORACLE
        | FOR_SYM UPDATE_SYM column_locking_list ora_opt_locked_row_action
          {
            $$= NEW_PTN PT_column_locking_clause(Lock_strength::UPDATE, $3, $4);
          }
%endif
        | FOR_SYM UPDATE_SYM ora_waitn_row_action
          {
            Mem_root_array_YY<Qualified_column_ident *> cl;
            cl.init(YYMEM_ROOT);
            $$= NEW_PTN PT_column_locking_clause(Lock_strength::UPDATE, cl, $3);
          }
        ;

lock_strength:
          UPDATE_SYM { $$= Lock_strength::UPDATE; }
        | SHARE_SYM  { $$= Lock_strength::SHARE; }
        ;

%ifndef SQL_MODE_ORACLE
table_locking_list:
          OF_SYM table_alias_ref_list { $$= $2; }
        ;

%else
column_locking_list:
          OF_SYM column_ref_list { $$= $2; }
        ;

column_ref_list:
          opt_qualified_column_ident
          {
            $$.init(YYMEM_ROOT);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | column_ref_list ',' opt_qualified_column_ident
          {
            $$= $1;
            if ($$.push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

ora_opt_locked_row_action:
          /* Empty */ { $$= NEW_PTN Locked_row_action_ora(Locked_row_action::WAIT,false,nullptr); }
        | ora_locked_row_action
        ;

ora_locked_row_action:
          SKIP_SYM LOCKED_SYM { $$= NEW_PTN Locked_row_action_ora(Locked_row_action::SKIP,false,nullptr); }
        | NOWAIT_SYM { $$= NEW_PTN Locked_row_action_ora(Locked_row_action::NOWAIT,false,nullptr); }
        | ora_waitn_row_action { $$= $1;}
        ;
%endif

ora_waitn_row_action:
          WAIT_SYM wait_ulong_num
          {
            $$= NEW_PTN Locked_row_action_ora(Locked_row_action::WAIT,true,$2);
          }
        ;

wait_ulong_num:
          ULONGLONG_NUM
          {
            $$= NEW_PTN Item_uint(@$, $1.str, $1.length);
          }
        | LONG_NUM
          {
            $$= NEW_PTN Item_uint(@$, $1.str, $1.length);
          }
        | NUM
          {
            $$= NEW_PTN Item_uint(@$, $1.str, $1.length);
          }
        ;

opt_locked_row_action:
          /* Empty */ { $$= Locked_row_action::WAIT; }
        | locked_row_action
        ;

locked_row_action:
          SKIP_SYM LOCKED_SYM { $$= Locked_row_action::SKIP; }
        | NOWAIT_SYM { $$= Locked_row_action::NOWAIT; }
        ;

select_item_list:
          select_item_list ',' select_item
          {
            if ($1 == NULL || $1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        | select_item
          {
            $$= NEW_PTN PT_select_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | '*'
          {
            Item *item = NEW_PTN Item_asterisk(@$, nullptr, nullptr);
            $$ = NEW_PTN PT_select_item_list;
            if ($$ == nullptr || item == nullptr || $$->push_back(item))
              MYSQL_YYABORT;
          }
        ;

select_item:
          table_wild { $$= $1; }
        | expr select_alias
          {
            $$= NEW_PTN PTI_expr_with_alias(@$, $1, @1.cpp, to_lex_cstring($2));
          }
        ;


select_alias:
          /* empty */ { $$=null_lex_str;} %prec KEYWORD_USED_AS_IDENT
        | AS ident { $$=$2; }
        | AS TEXT_STRING_validated { $$=$2; }
        | ident { $$=$1; }
        | TEXT_STRING_validated { $$=$1; }
        ;

optional_braces:
          /* empty */ {}
        | '(' ')' {}
        ;

/* all possible expressions */
expr:
          expr or expr %prec OR_SYM
          {
            $$= flatten_associative_operator<Item_cond_or,
                                             Item_func::COND_OR_FUNC>(
                                                 YYMEM_ROOT, @$, $1, $3);
          }
        | expr XOR expr %prec XOR
          {
            /* XOR is a proprietary extension */
            $$ = NEW_PTN Item_func_xor(@$, $1, $3);
          }
        | expr and expr %prec AND_SYM
          {
            $$= flatten_associative_operator<Item_cond_and,
                                             Item_func::COND_AND_FUNC>(
                                                 YYMEM_ROOT, @$, $1, $3);
          }
        | NOT_SYM expr %prec NOT_SYM
          {
            $$= NEW_PTN PTI_truth_transform(@$, $2, Item::BOOL_NEGATED);
          }
        | bool_pri IS TRUE_SYM %prec IS
          {
            $$= NEW_PTN PTI_truth_transform(@$, $1, Item::BOOL_IS_TRUE);
          }
        | bool_pri IS not TRUE_SYM %prec IS
          {
            $$= NEW_PTN PTI_truth_transform(@$, $1, Item::BOOL_NOT_TRUE);
          }
        | bool_pri IS FALSE_SYM %prec IS
          {
            $$= NEW_PTN PTI_truth_transform(@$, $1, Item::BOOL_IS_FALSE);
          }
        | bool_pri IS not FALSE_SYM %prec IS
          {
            $$= NEW_PTN PTI_truth_transform(@$, $1, Item::BOOL_NOT_FALSE);
          }
        | bool_pri IS UNKNOWN_SYM %prec IS
          {
            $$= NEW_PTN Item_func_isnull(@$, $1);
          }
        | bool_pri IS not UNKNOWN_SYM %prec IS
          {
            $$= NEW_PTN Item_func_isnotnull(@$, $1);
          }
        | bool_pri %prec SET_VAR
%ifdef SQL_MODE_ORACLE
        | explicit_cursor_attr
        | implicit_cursor_attr
%endif
        ;

bool_pri:
          bool_pri IS NULL_SYM %prec IS
          {
            $$= NEW_PTN Item_func_isnull(@$, $1);
          }
        | bool_pri IS not NULL_SYM %prec IS
          {
            $$= NEW_PTN Item_func_isnotnull(@$, $1);
          }
        | bool_pri comp_op predicate
          {
            $$= NEW_PTN PTI_comp_op(@$, $1, $2, $3);
          }
        | bool_pri comp_op all_or_any table_subquery %prec EQ
          {
            if ($2 == &comp_equal_creator)
              /*
                We throw this manual parse error rather than split the rule
                comp_op into a null-safe and a non null-safe rule, since doing
                so would add a shift/reduce conflict. It's actually this rule
                and the ones referencing it that cause all the conflicts, but
                we still don't want the count to go up.
              */
              YYTHD->syntax_error_at(@2);
            $$= NEW_PTN PTI_comp_op_all(@$, $1, $2, $3, $4);
          }
        | bool_pri comp_op all_or_any '(' expr ')'
          {
            if ($2 == &comp_equal_creator)
              YYTHD->syntax_error_at(@2);

            $$= NEW_PTN PTI_comp_op(@$, $1, $2, $5);
          }
        | bool_pri comp_op all_or_any '(' expr ',' expr_list ')'
          {
            if ($2 == &comp_equal_creator)
              YYTHD->syntax_error_at(@2);
            if($7 == NULL || $7->push_front($5))
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_comp_op_all_any(@$, $1, $2, $3, $7);
          }
        | predicate %prec SET_VAR
        ;

predicate:
          bit_expr IN_SYM table_subquery
          {
            $$= NEW_PTN Item_in_subselect(@$, $1, $3);
          }
        | bit_expr not IN_SYM table_subquery
          {
            Item *item= NEW_PTN Item_in_subselect(@$, $1, $4);
            $$= NEW_PTN PTI_truth_transform(@$, item, Item::BOOL_NEGATED);
          }
        | bit_expr IN_SYM '(' expr ')'
          {
            $$= NEW_PTN PTI_handle_sql2003_note184_exception(@$, $1, true, $4);
          }
        | bit_expr IN_SYM '(' expr ',' expr_list ')'
          {
            if ($6 == NULL || $6->push_front($4) || $6->push_front($1))
              MYSQL_YYABORT;

            $$= NEW_PTN Item_func_in(@$, $6, false);
          }
        | bit_expr not IN_SYM '(' expr ')'
          {
            $$= NEW_PTN PTI_handle_sql2003_note184_exception(@$, $1, false, $5);
          }
        | bit_expr not IN_SYM '(' expr ',' expr_list ')'
          {
            if ($7 == nullptr)
              MYSQL_YYABORT;
            $7->push_front($5);
            $7->value.push_front($1);

            $$= NEW_PTN Item_func_in(@$, $7, true);
          }
        | bit_expr MEMBER_SYM opt_of '(' simple_expr ')'
          {
            $$= NEW_PTN Item_func_member_of(@$, $1, $5);
          }
        | bit_expr BETWEEN_SYM bit_expr AND_SYM predicate
          {
            $$= NEW_PTN Item_func_between(@$, $1, $3, $5, false);
          }
        | bit_expr not BETWEEN_SYM bit_expr AND_SYM predicate
          {
            $$= NEW_PTN Item_func_between(@$, $1, $4, $6, true);
          }
        | bit_expr SOUNDS_SYM LIKE bit_expr
          {
            Item *item1= NEW_PTN Item_func_soundex(@$, $1);
            Item *item4= NEW_PTN Item_func_soundex(@$, $4);
            if ((item1 == NULL) || (item4 == NULL))
              MYSQL_YYABORT;
            $$= NEW_PTN Item_func_eq(@$, item1, item4);
          }
%ifdef SQL_MODE_ORACLE
        | bit_expr LIKE bit_expr
          {
            $$ = NEW_PTN Item_func_like(@$, $1, $3);
          }
        | bit_expr LIKE bit_expr ESCAPE_SYM bit_expr %prec LIKE
          {
            $$ = NEW_PTN Item_func_like(@$, $1, $3, $5);
          }
        | bit_expr not LIKE bit_expr
          {
            auto item = NEW_PTN Item_func_like(@$, $1, $4);
            $$ = NEW_PTN Item_func_not(@$, item);
          }
        | bit_expr not LIKE bit_expr ESCAPE_SYM bit_expr %prec LIKE
          {
            auto item = NEW_PTN Item_func_like(@$, $1, $4, $6);
            $$ = NEW_PTN Item_func_not(@$, item);
          }

%else
        | bit_expr LIKE simple_expr
          {
            $$ = NEW_PTN Item_func_like(@$, $1, $3);
          }
        | bit_expr LIKE simple_expr ESCAPE_SYM simple_expr %prec LIKE
          {
            $$ = NEW_PTN Item_func_like(@$, $1, $3, $5);
          }
        | bit_expr not LIKE simple_expr
          {
            auto item = NEW_PTN Item_func_like(@$, $1, $4);
            $$ = NEW_PTN Item_func_not(@$, item);
          }
        | bit_expr not LIKE simple_expr ESCAPE_SYM simple_expr %prec LIKE
          {
            auto item = NEW_PTN Item_func_like(@$, $1, $4, $6);
            $$ = NEW_PTN Item_func_not(@$, item);
          }
%endif
        | bit_expr REGEXP bit_expr
          {
            auto args= NEW_PTN PT_item_list;
            args->push_back($1);
            args->push_back($3);

            $$= NEW_PTN Item_func_regexp_like(@1, args);
          }
        | bit_expr not REGEXP bit_expr
          {
            auto args= NEW_PTN PT_item_list;
            args->push_back($1);
            args->push_back($4);
            Item *item= NEW_PTN Item_func_regexp_like(@$, args);
            $$= NEW_PTN PTI_truth_transform(@$, item, Item::BOOL_NEGATED);
          }
        | bit_expr %prec SET_VAR
        ;

opt_of:
          OF_SYM
        |
        ;

bit_expr:
          bit_expr '|' bit_expr %prec '|'
          {
            $$= NEW_PTN Item_func_bit_or(@$, $1, $3);
          }
        | bit_expr '&' bit_expr %prec '&'
          {
            $$= NEW_PTN Item_func_bit_and(@$, $1, $3);
          }
        | bit_expr SHIFT_LEFT bit_expr %prec SHIFT_LEFT
          {
            $$= NEW_PTN Item_func_shift_left(@$, $1, $3);
          }
        | bit_expr SHIFT_RIGHT bit_expr %prec SHIFT_RIGHT
          {
            $$= NEW_PTN Item_func_shift_right(@$, $1, $3);
          }
%ifdef SQL_MODE_ORACLE
        | bit_expr OR_OR_SYM bit_expr  %prec OR_OR_SYM
          {
            $$= NEW_PTN Item_func_concat(@$, $1, $3, true);
          }
%endif
        | bit_expr '+' bit_expr %prec '+'
          {
            $$= NEW_PTN Item_func_plus(@$, $1, $3);
          }
        | bit_expr '-' bit_expr %prec '-'
          {
            $$= NEW_PTN Item_func_minus(@$, $1, $3);
          }
        | bit_expr '+' INTERVAL_SYM expr interval %prec '+'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $1, $4, $5, 0);
          }
        | bit_expr '+' '(' INTERVAL_SYM expr interval ')' %prec '+'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $1, $5, $6, 0);
          }
        | bit_expr '-' INTERVAL_SYM expr interval %prec '-'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $1, $4, $5, 1);
          }
        | bit_expr '-' '(' INTERVAL_SYM expr interval ')' %prec '-'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $1, $5, $6, 1);
          }
        | bit_expr '*' bit_expr %prec '*'
          {
            $$= NEW_PTN Item_func_mul(@$, $1, $3);
          }
        | bit_expr '/' bit_expr %prec '/'
          {
            $$= NEW_PTN Item_func_div(@$, $1,$3);
          }
        | bit_expr '%' bit_expr %prec '%'
          {
            $$= NEW_PTN Item_func_mod(@$, $1,$3);
          }
        | bit_expr DIV_SYM bit_expr %prec DIV_SYM
          {
            $$= NEW_PTN Item_func_div_int(@$, $1,$3);
          }
        | bit_expr MOD_SYM bit_expr %prec MOD_SYM
          {
            $$= NEW_PTN Item_func_mod(@$, $1, $3);
          }
        | bit_expr '^' bit_expr
          {
            $$= NEW_PTN Item_func_bit_xor(@$, $1, $3);
          }
        | simple_expr %prec SET_VAR
        ;

or:
          OR_SYM
       | OR2_SYM
       ;

and:
          AND_SYM
       | AND_AND_SYM
         {
           push_deprecated_warn(YYTHD, "&&", "AND");
         }
       ;

not:
          NOT_SYM
        | NOT2_SYM
        ;

not2:
          '!' { push_deprecated_warn(YYTHD, "!", "NOT"); }
        | NOT2_SYM
        ;

comp_op:
          EQ     { $$ = &comp_eq_creator; }
        | EQUAL_SYM { $$ = &comp_equal_creator; }
        | GE     { $$ = &comp_ge_creator; }
        | GT_SYM { $$ = &comp_gt_creator; }
        | LE     { $$ = &comp_le_creator; }
        | LT     { $$ = &comp_lt_creator; }
        | NE     { $$ = &comp_ne_creator; }
        ;

all_or_any:
          ALL     { $$ = 1; }
        | ANY_SYM { $$ = 0; }
        ;

simple_expr:
          simple_ident_with_plus
        | simple_ident
        | function_call_keyword
        | function_call_nonkeyword
        | function_call_generic
        | function_call_conflict
        | simple_expr COLLATE_SYM ident_or_text %prec NEG
          {
            $$= NEW_PTN Item_func_set_collation(@$, $1, $3);
          }
        | literal_or_null
        | param_marker { $$= $1; }
        | rvalue_system_or_user_variable
        | in_expression_user_variable_assignment
        | set_function_specification
        | window_func_call
%ifndef SQL_MODE_ORACLE
        | simple_expr OR_OR_SYM simple_expr
          {
            $$= NEW_PTN Item_func_concat(@$, $1, $3, true);
          }
%endif
        | PRIOR_SYM simple_expr  %prec NEG
          {
            $$= NEW_PTN Item_func_prior(@$,$2);
          }
        | CONNECT_BY_ROOT_SYM simple_expr %prec NEG
          {
            $$= NEW_PTN Item_connect_by_func_root(@$,$2);
          }
        | '+' simple_expr %prec NEG
          {
            $$= $2; // TODO: do we really want to ignore unary '+' before any kind of literals?
          }
        | '-' simple_expr %prec NEG
          {
            $$= NEW_PTN Item_func_neg(@$, $2);
          }
        | '~' simple_expr %prec NEG
          {
            $$= NEW_PTN Item_func_bit_neg(@$, $2);
          }
        | not2 simple_expr %prec NEG
          {
            $$= NEW_PTN PTI_truth_transform(@$, $2, Item::BOOL_NEGATED);
          }
        | row_subquery
          {
            $$= NEW_PTN PTI_singlerow_subselect(@$, $1);
          }
        | '(' expr ')' { $$= $2; }
        | '(' expr ',' expr_list ')'
          {
            $$= NEW_PTN Item_row(@$, $2, $4->value);
          }
        | ROW_SYM '(' expr ',' expr_list ')'
          {
            $$= NEW_PTN Item_row(@$, $3, $5->value);
          }
        | EXISTS table_subquery
          {
            $$= NEW_PTN PTI_exists_subselect(@$, $2);
          }
        | '{' ident expr '}'
          {
            $$= NEW_PTN PTI_odbc_date(@$, $2, $3);
          }
        | MATCH ident_list_arg AGAINST '(' bit_expr fulltext_options ')'
          {
            $$= NEW_PTN Item_func_match(@$, $2, $5, $6);
          }
        | BINARY_SYM simple_expr %prec NEG
          {
            push_deprecated_warn(YYTHD, "BINARY expr", "CAST");
            $$= create_func_cast(YYTHD, @2, $2, ITEM_CAST_CHAR, &my_charset_bin);
          }
        | CAST_SYM '(' expr AS cast_type opt_array_cast ')'
          {
            $$= create_func_cast(YYTHD, @3, $3, $5, $6);
          }
        | CAST_SYM '(' expr AT_SYM LOCAL_SYM AS cast_type opt_array_cast ')'
          {
            my_error(ER_NOT_SUPPORTED_YET, MYF(0), "AT LOCAL");
          }
        | CAST_SYM '(' expr AT_SYM TIME_SYM ZONE_SYM opt_interval
          TEXT_STRING_literal AS DATETIME_SYM type_datetime_precision ')'
          {
            Cast_type cast_type{ITEM_CAST_DATETIME, nullptr, nullptr, $11};
            auto datetime_factor =
                NEW_PTN Item_func_at_time_zone(@3, $3, $8.str, $7);
            $$ = create_func_cast(YYTHD, @3, datetime_factor, cast_type, false);
          }
        | CASE_SYM opt_expr when_list opt_else END
          {
            $$= NEW_PTN Item_func_case(@$, $3, $2, $4 );
          }
        | DECODE_SYM '(' expr decode_list opt_decode_expr ')'
          {
            $$= NEW_PTN Item_func_case(@$, $4, $3, $5, 1);
          }
        | CONVERT_SYM '(' expr ',' cast_type ')'
          {
            $$= create_func_cast(YYTHD, @3, $3, $5, false);
          }
        | CONVERT_SYM '(' expr USING charset_name ')'
          {
            $$= NEW_PTN Item_func_conv_charset(@$, $3,$5);
          }
        | TO_NUMBER_SYM '(' expr ')'
          {
            $$= create_func_to_number(YYTHD, @3, $3);
          }
        | TO_NUMBER_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_typeto_format_number(@$, $3,$5);
          }
        | DEFAULT_SYM '(' simple_ident ')'
          {
            $$= NEW_PTN Item_default_value(@$, $3);
          }
        | VALUES '(' simple_ident_nospvar ')'
          {
            $$= NEW_PTN Item_insert_value(@$, $3);
          }
        | INTERVAL_SYM expr interval '+' expr %prec INTERVAL_SYM
          /* we cannot put interval before - */
          {
            $$= NEW_PTN Item_date_add_interval(@$, $5, $2, $3, 0);
          }
        | '(' INTERVAL_SYM expr interval ')' '+' expr %prec INTERVAL_SYM
          /* we cannot put interval before - */
          {
            $$= NEW_PTN Item_date_add_interval(@$, $7, $3, $4, 0);
          }
        | simple_ident JSON_SEPARATOR_SYM TEXT_STRING_literal
          {
            Item_string *path=
              NEW_PTN Item_string(@$, $3.str, $3.length,
                                  YYTHD->variables.collation_connection);
            $$= NEW_PTN Item_func_json_extract(YYTHD, @$, $1, path);
          }
        | simple_ident JSON_UNQUOTED_SEPARATOR_SYM TEXT_STRING_literal
          {
            Item_string *path=
              NEW_PTN Item_string(@$, $3.str, $3.length,
                                  YYTHD->variables.collation_connection);
            Item *extr= NEW_PTN Item_func_json_extract(YYTHD, @$, $1, path);
            $$= NEW_PTN Item_func_json_unquote(@$, extr);
          }
        ;

opt_array_cast:
        /* empty */ { $$= false; }
        | ARRAY_SYM { $$= true; }
        ;

/*
  Function call syntax using official SQL 2003 keywords.
  Because the function name is an official token,
  a dedicated grammar rule is needed in the parser.
  There is no potential for conflicts
*/
function_call_keyword:
          CHAR_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_char(@$, $3);
          }
        | CHAR_SYM '(' expr_list USING charset_name ')'
          {
            $$= NEW_PTN Item_func_char(@$, $3, $5);
          }
        | CHR_ORACLE_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_chr(@$, $3);
          }
        | CHR_ORACLE_SYM '(' expr USING charset_name ')'
          {
            $$= NEW_PTN Item_func_chr(@$, $3, $5);
          }
        | CURRENT_USER optional_braces
          {
            $$= NEW_PTN Item_func_current_user(@$);
          }
        | DATE_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_typecast_date(@$, $3);
          }
        | DAY_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_dayofmonth(@$, $3);
          }
        | HOUR_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_hour(@$, $3);
          }
        | INSERT_SYM '(' expr ',' expr ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_insert(@$, $3, $5, $7, $9);
          }
        | INTERVAL_SYM '(' expr ',' expr ')' %prec INTERVAL_SYM
          {
            $$= NEW_PTN Item_func_interval(@$, YYMEM_ROOT, $3, $5);
          }
        | INTERVAL_SYM '(' expr ',' expr ',' expr_list ')' %prec INTERVAL_SYM
          {
            $$= NEW_PTN Item_func_interval(@$, YYMEM_ROOT, $3, $5, $7);
          }
        | JSON_VALUE_SYM '(' simple_expr ',' text_literal
          opt_returning_type opt_on_empty_or_error ')'
          {
            $$= create_func_json_value(YYTHD, @3, $3, $5, $6,
                                       $7.empty.type, $7.empty.default_string,
                                       $7.error.type, $7.error.default_string);
          }
        | LEFT '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_left(@$, $3, $5);
          }
        | MINUTE_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_minute(@$, $3);
          }
        | MONTH_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_month(@$, $3);
          }
        | RIGHT '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_right(@$, $3, $5);
          }
        | SECOND_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_second(@$, $3);
          }
        | TIME_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_typecast_time(@$, $3);
          }
        | TIMESTAMP_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_typecast_datetime(@$, $3);
          }
        | TIMESTAMP_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_add_time(@$, $3, $5, 1, 0);
          }
        | TRIM '(' expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $3,
                                       Item_func_trim::TRIM_BOTH_DEFAULT);
          }
        | TRIM '(' LEADING expr FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $6, $4,
                                       Item_func_trim::TRIM_LEADING);
          }
        | TRIM '(' TRAILING expr FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $6, $4,
                                       Item_func_trim::TRIM_TRAILING);
          }
        | TRIM '(' BOTH expr FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $6, $4, Item_func_trim::TRIM_BOTH);
          }
        | TRIM '(' LEADING FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $5, Item_func_trim::TRIM_LEADING);
          }
        | TRIM '(' TRAILING FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $5, Item_func_trim::TRIM_TRAILING);
          }
        | TRIM '(' BOTH FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $5, Item_func_trim::TRIM_BOTH);
          }
        | TRIM '(' expr FROM expr ')'
          {
            $$= NEW_PTN Item_func_trim(@$, $5, $3,
                                       Item_func_trim::TRIM_BOTH_DEFAULT);
          }
        | USER '(' ')'
          {
            $$= NEW_PTN Item_func_user(@$);
          }
        | YEAR_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_year(@$, $3);
          }
        | ROWNUM_SYM
          {
            $$= NEW_PTN Item_func_rownum(@$);
          }
        | CONNECT_BY_ISCYCLE_SYM
          {
            $$= NEW_PTN Item_connect_by_func_iscycle(@$);
          }
        | CONNECT_BY_ISLEAF_SYM
          {
            $$= NEW_PTN Item_connect_by_func_isleaf(@$);
          }
%ifdef SQL_MODE_ORACLE
        | SQLCODE_SYM
          {
            $$= NEW_PTN Item_func_sqlcode(@$);
          }
        | SQLERRM_SYM
          {
            $$= NEW_PTN Item_func_sqlerrm(@$);
          }
        | SQLERRM_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_sqlerrm(@$, $3);
          }
%endif
        ;

/*
  Function calls using non reserved keywords, with special syntaxic forms.
  Dedicated grammar rules are needed because of the syntax,
  but also have the potential to cause incompatibilities with other
  parts of the language.
  MAINTAINER:
  The only reasons a function should be added here are:
  - for compatibility reasons with another SQL syntax (CURDATE),
  - for typing reasons (GET_FORMAT)
  Any other 'Syntaxic sugar' enhancements should be *STRONGLY*
  discouraged.
*/
function_call_nonkeyword:
          ADDDATE_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $3, $5, INTERVAL_DAY, 0);
          }
        | ADDDATE_SYM '(' expr ',' INTERVAL_SYM expr interval ')'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $3, $6, $7, 0);
          }
        | ADD_MONTHS_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_add_months(@$, $3, $5);
            if (unlikely($$ == NULL))
              MYSQL_YYABORT;
          }
        | CURDATE optional_braces
          {
            $$= NEW_PTN Item_func_curdate_local(@$);
          }
        | CURTIME func_datetime_precision
          {
            $$= NEW_PTN Item_func_curtime_local(@$, static_cast<uint8>($2));
          }
        | DATE_ADD_INTERVAL '(' expr ',' INTERVAL_SYM expr interval ')'
          %prec INTERVAL_SYM
          {
            $$= NEW_PTN Item_date_add_interval(@$, $3, $6, $7, 0);
          }
        | DATE_SUB_INTERVAL '(' expr ',' INTERVAL_SYM expr interval ')'
          %prec INTERVAL_SYM
          {
            $$= NEW_PTN Item_date_add_interval(@$, $3, $6, $7, 1);
          }
        | DUMP_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_dump(@$, $3);
          }
        | EXTRACT_SYM '(' interval FROM expr ')'
          {
            $$= NEW_PTN Item_extract(@$,  $3, $5);
          }
        | GET_FORMAT '(' date_time_type  ',' expr ')'
          {
            $$= NEW_PTN Item_func_get_format(@$, $3, $5);
          }
        | now
          {
            uint8 dec = static_cast<uint8>($1);
            bool is_current_timestmap = false;
            bool is_dec_appoint = false;
            current_timestamp_parse(@1.cpp.start, @1.cpp.length(),
                                    &is_current_timestmap, &is_dec_appoint);

            auto item = NEW_PTN PTI_function_call_nonkeyword_now(@$, dec);
            if (item == NULL)
              MYSQL_YYABORT;

            item->is_current_timestmap = is_current_timestmap;
            item->is_dec_appoint = is_dec_appoint;
            $$=item;
          }
        | POSITION_SYM '(' bit_expr IN_SYM expr ')'
          {
            $$= NEW_PTN Item_func_locate(@$, $5,$3);
          }
        | SUBDATE_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $3, $5, INTERVAL_DAY, 1);
          }
        | SUBDATE_SYM '(' expr ',' INTERVAL_SYM expr interval ')'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $3, $6, $7, 1);
          }
        | SUBSTRING '(' expr ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_substr(@$, $3,$5,$7);
          }
        | SUBSTRING '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_substr(@$, $3,$5);
          }
%ifndef SQL_MODE_ORACLE
        | SUBSTRING '(' expr FROM expr FOR_SYM expr ')'
          {
            $$= NEW_PTN Item_func_substr(@$, $3,$5,$7);
          }
        | SUBSTRING '(' expr FROM expr ')'
          {
            $$= NEW_PTN Item_func_substr(@$, $3,$5);
          }
%endif
        | SUBSTRB_SYM '(' expr ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_substrb(@$, $3,$5,$7);
          }
        | SUBSTRB_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_substrb(@$, $3,$5);
          }
        | SUBSTRB_SYM '(' expr FROM expr FOR_SYM expr ')'
          {
            $$= NEW_PTN Item_func_substrb(@$, $3,$5,$7);
          }
        | SUBSTRB_SYM '(' expr FROM expr ')'
          {
            $$= NEW_PTN Item_func_substrb(@$, $3,$5);
          }
        | SYS_GUID_SYM '(' ')'
          {
            $$= NEW_PTN Item_func_sys_guid(@$);
          }
%ifndef SQL_MODE_ORACLE
        | SYSDATE  func_datetime_precision
          {
            $$= NEW_PTN PTI_function_call_nonkeyword_sysdate(@$, static_cast<uint8>($2));
          }
%endif
        | TIMESTAMP_ADD '(' interval_time_stamp ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_date_add_interval(@$, $7, $5, $3, 0);
          }
        | TIMESTAMP_DIFF '(' interval_time_stamp ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_timestamp_diff(@$, $5,$7,$3);
          }
%ifdef SQL_MODE_ORACLE
        | trg_predicate_event opt_trigger_even_column
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            if (!sp || (sp->m_type != enum_sp_type::TRIGGER) 
                || ($1 != TRG_EVENT_UPDATE && $2!= nullptr))
            {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PTI_function_call_nonkeyword_trigger_event_is(@$, NEW_PTN Item_int(@$, $1),$2);
          }
%endif
        | UTC_DATE_SYM optional_braces
          {
            $$= NEW_PTN Item_func_curdate_utc(@$);
          }
        | UTC_TIME_SYM func_datetime_precision
          {
            $$= NEW_PTN Item_func_curtime_utc(@$, static_cast<uint8>($2));
          }
        | UTC_TIMESTAMP_SYM func_datetime_precision
          {
            $$= NEW_PTN Item_func_now_utc(@$, static_cast<uint8>($2));
          }
        ;

// JSON_VALUE's optional JSON returning clause.
opt_returning_type:
          // The default returning type is CHAR(512). (The max length of 512
          // is chosen so that the returned values are not handled as BLOBs
          // internally. See CONVERT_IF_BIGGER_TO_BLOB.)
          {
            $$= {ITEM_CAST_CHAR, nullptr, "512", nullptr};
          }
        | RETURNING_SYM cast_type
          {
            $$= $2;
          }
        ;
/*
  Functions calls using a non reserved keyword, and using a regular syntax.
  Because the non reserved keyword is used in another part of the grammar,
  a dedicated rule is needed here.
*/
function_call_conflict:
          ASCII_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_ascii(@$, $3);
          }
        | CHARSET '(' expr ')'
          {
            $$= NEW_PTN Item_func_charset(@$, $3);
          }
        | COALESCE '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_coalesce(@$, $3);
          }
        | COLLATION_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_collation(@$, $3);
          }
        | DATABASE '(' ')'
          {
            $$= NEW_PTN Item_func_database(@$);
          }
        | IF '(' expr ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_if(@$, $3,$5,$7);
          }
        | FORMAT_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_format(@$, $3, $5);
          }
        | FORMAT_SYM '(' expr ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_format(@$, $3, $5, $7);
          }
        | MICROSECOND_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_microsecond(@$, $3);
          }
        | MOD_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_mod(@$, $3, $5);
          }
        | MONTHS_BETWEEN '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_months_between(@$, $5, $3);
          }
        | QUARTER_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_quarter(@$, $3);
          }
        | REPEAT_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_repeat(@$, $3,$5);
          }
        | REPLACE_SYM '(' expr ',' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_replace(@$, $3,$5,$7);
          }
%ifdef SQL_MODE_ORACLE
        | REPLACE_SYM '(' expr ',' expr ')'
          {
            Item *replace_string= NEW_PTN Item_string("",0,YYTHD->charset());
            $$= NEW_PTN Item_func_replace(@$, $3, $5, replace_string);
          }
%endif
        | REVERSE_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_reverse(@$, $3);
          }
        | ROW_COUNT_SYM '(' ')'
          {
            $$= NEW_PTN Item_func_row_count(@$);
          }
        | TRUNCATE_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_round(@$, $3,$5,1);
          }
        | WEEK_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_week(@$, $3, NULL);
          }
        | WEEK_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_week(@$, $3, $5);
          }
        | WEIGHT_STRING_SYM '(' expr ')'
          {
            $$= NEW_PTN Item_func_weight_string(@$, $3, 0, 0, 0);
          }
        | WEIGHT_STRING_SYM '(' expr AS CHAR_SYM ws_num_codepoints ')'
          {
            $$= NEW_PTN Item_func_weight_string(@$, $3, 0, $6, 0);
          }
        | WEIGHT_STRING_SYM '(' expr AS BINARY_SYM ws_num_codepoints ')'
          {
            $$= NEW_PTN Item_func_weight_string(@$, $3, 0, $6, 0, true);
          }
        | WEIGHT_STRING_SYM '(' expr ',' ulong_num ',' ulong_num ',' ulong_num ')'
          {
            $$= NEW_PTN Item_func_weight_string(@$, $3, $5, $7, $9);
          }
        | geometry_function
        ;

geometry_function:
          GEOMETRYCOLLECTION_SYM '(' opt_expr_list ')'
          {
            $$= NEW_PTN Item_func_spatial_collection(@$, $3,
                        Geometry::wkb_geometrycollection,
                        Geometry::wkb_point);
          }
        | LINESTRING_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_spatial_collection(@$, $3,
                        Geometry::wkb_linestring,
                        Geometry::wkb_point);
          }
        | MULTILINESTRING_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_spatial_collection(@$, $3,
                        Geometry::wkb_multilinestring,
                        Geometry::wkb_linestring);
          }
        | MULTIPOINT_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_spatial_collection(@$, $3,
                        Geometry::wkb_multipoint,
                        Geometry::wkb_point);
          }
        | MULTIPOLYGON_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_spatial_collection(@$, $3,
                        Geometry::wkb_multipolygon,
                        Geometry::wkb_polygon);
          }
        | POINT_SYM '(' expr ',' expr ')'
          {
            $$= NEW_PTN Item_func_point(@$, $3,$5);
          }
        | POLYGON_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_spatial_collection(@$, $3,
                        Geometry::wkb_polygon,
                        Geometry::wkb_linestring);
          }
        ;

/*
  Regular function calls.
  The function name is *not* a token, and therefore is guaranteed to not
  introduce side effects to the language in general.
  MAINTAINER:
  All the new functions implemented for new features should fit into
  this category. The place to implement the function itself is
  in sql/item_create.cc
*/
function_call_generic:
          IDENT_sys '(' opt_udf_expr_list ')'
          {
            $$= NEW_PTN PTI_function_call_generic_ident_sys(@1, $1, $3);
          }
        | ident '.' ident '(' opt_expr_list ')'
          {
            $$= NEW_PTN PTI_function_call_generic_2d(@$, $1, $3, $5);
          }
%ifdef SQL_MODE_ORACLE
        | ident '.' ident '.' IDENT_sys '(' opt_expr_list ')'
          {
            if ($1.length == 0)
            {
              my_error(ER_WRONG_DB_NAME, MYF(0), "");
              MYSQL_YYABORT;
            }
            if (!$1.str ||
                (check_and_convert_db_name(&$1, false) != Ident_name_check::OK))
              MYSQL_YYABORT;
            PTI_function_call_generic_2d *item=
                NEW_PTN PTI_function_call_generic_2d(@$, $3, $5, $7);
            if (item) item->m_pkg_db = to_lex_cstring($1);
            $$= item;
          }
        | IDENT_sys '(' opt_udf_expr_list ')' '.' ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (!sp)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_variable *spvar= pctx->find_variable($1.str, $1.length, false);
            if (!spvar)
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            if(!spvar->field_def.ora_record.row_field_table_definitions() ||
            spvar->field_def.ora_record.is_record_table_define)
            {
              my_error(ER_SP_MISMATCH_RECORD_VAR, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            if(!$3 || $3->elements() != 1){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "empty parameter or more than one parameter with table type");
              MYSQL_YYABORT;
            }
            // It's var(1).ident.
            PTI_udf_expr *item_expr = dynamic_cast<PTI_udf_expr *>($3->value.front());
            Item *item_int= nullptr;
            ITEMIZE(item_expr, &item_int);
            ora_simple_ident_def *def= new (YYMEM_ROOT) ora_simple_ident_def($1, item_int);
            List<ora_simple_ident_def> *list= new (YYMEM_ROOT) List<ora_simple_ident_def>;
            if (list->push_back(def))
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_nd(@$, list, $6.str);
          }
        | IDENT_sys '(' opt_udf_expr_list ')' '.' ora_simple_ident_list ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (!sp)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            if(!$3 || $3->elements() != 1){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "empty parameter or more than one parameter with table type");
              MYSQL_YYABORT;
            }
            PTI_udf_expr *item_expr = dynamic_cast<PTI_udf_expr *>($3->value.front());
            Item *item_int= nullptr;
            ITEMIZE(item_expr, &item_int);
            ora_simple_ident_def *def= NEW_PTN ora_simple_ident_def($1, item_int);
            if ($6->push_front(def))
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_nd(@$, $6, $7.str);
          }
%endif
        ;

fulltext_options:
          opt_natural_language_mode opt_query_expansion
          { $$= $1 | $2; }
        | IN_SYM BOOLEAN_SYM MODE_SYM
          {
            $$= FT_BOOL;
            DBUG_EXECUTE_IF("simulate_bug18831513",
                            {
                              THD *thd= YYTHD;
                              if (thd->sp_runtime_ctx)
                                YYTHD->syntax_error();
                            });
          }
        ;

opt_natural_language_mode:
          /* nothing */                         { $$= FT_NL; }
        | IN_SYM NATURAL LANGUAGE_SYM MODE_SYM  { $$= FT_NL; }
        ;

opt_query_expansion:
          /* nothing */                         { $$= 0;         }
        | WITH QUERY_SYM EXPANSION_SYM          { $$= FT_EXPAND; }
        ;

opt_udf_expr_list:
        /* empty */     { $$= NULL; }
        | udf_expr_list { $$= $1; }
%ifdef SQL_MODE_ORACLE
        | udf_expr_record_table_list_ora { $$= $1; }
%endif
        ;

udf_expr_list:
          udf_expr
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | udf_expr_list ',' udf_expr
          {
            if ($1 == NULL || $1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

%ifndef SQL_MODE_ORACLE
udf_expr:
          expr select_alias
          {
            $$= NEW_PTN PTI_udf_expr(@$, $1, $2, @1.cpp);
          }
%else
udf_expr:
          expr
          {
            $$= NEW_PTN PTI_udf_expr(@$, $1, NULL_STR, @1.cpp);
          }
        | ident EQ_GT_SYM expr
          {
            $$= NEW_PTN PTI_udf_expr(@$, $3, $1, @3.cpp);
          }
        ;

udf_expr_record_table_list_ora:
          udf_expr_record_table_param_ora
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1->value[0]) || $$->push_back($1->value[1]))
              MYSQL_YYABORT;
            $$->m_has_assignment_list= true;
          }
        | udf_expr_record_table_list_ora ',' udf_expr_record_table_param_ora
          {
            if ($1 == NULL || $1->push_back($3->value[0]) || $$->push_back($3->value[1]))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

udf_expr_record_table_param_ora:
          udf_expr_record_table_row_ora EQ_GT_SYM expr
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1) || $$->push_back($3))
              MYSQL_YYABORT;
          }
        ;

udf_expr_record_table_row_ora:
          text_literal
          {
            /*
              When emptystring_equal_null mode empty string set to null
            */
            THD *thd= YYTHD;
            if ((thd->variables.sql_mode & MODE_EMPTYSTRING_EQUAL_NULL) && $1->is_empty())
              $$= NEW_PTN Item_null(@$);
            else
              $$= $1;
          }
        | NUM_literal  { $$= $1; }
        | '-' NUM_literal
          {
            if ($2 == NULL)
              MYSQL_YYABORT; // OOM
            $2->max_length++;
            $$= $2->neg();
          }
        ;
%endif

set_function_specification:
          sum_expr
        | grouping_operation
        ;

sum_expr:
          AVG_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            if ($5 != NULL && $6 == NULL) {
              window = $5;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
            }

            $$= NEW_PTN Item_sum_avg(@$, $3, false, window);
          }
        | AVG_SYM '(' DISTINCT in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($6 != NULL) {
              $6->set_has_keep_clause(true);
            }
            if ($6 != NULL && $7 == NULL) {
              window = $6;
            } else if ($6 == NULL && $7 != NULL) {
              window = $7;
            } else if ($6 != NULL && $7 != NULL) {
              if($7->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@7);
                MYSQL_YYABORT;
              }
              $6->set_partition_list($7->get_partition_list());
              $6->set_has_keep_over_clause(true);
              window = $6;
            }

            $$= NEW_PTN Item_sum_avg(@$, $4, true, window);
          }
        | BIT_AND_SYM  '(' in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_and(@$, $3, $5);
          }
        | BIT_OR_SYM  '(' in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_or(@$, $3, $5);
          }
        | JSON_ARRAYAGG '(' in_sum_expr ')' opt_windowing_clause
          {
            auto wrapper = make_unique_destroy_only<Json_wrapper>(YYMEM_ROOT);
            if (wrapper == nullptr) YYABORT;
            unique_ptr_destroy_only<Json_array> array{::new (YYMEM_ROOT)
                                                          Json_array};
            if (array == nullptr) YYABORT;
            $$ = NEW_PTN Item_sum_json_array(@$, $3, $5, std::move(wrapper),
                                             std::move(array));
          }
        | JSON_OBJECTAGG '(' in_sum_expr ',' in_sum_expr ')' opt_windowing_clause
          {
            auto wrapper = make_unique_destroy_only<Json_wrapper>(YYMEM_ROOT);
            if (wrapper == nullptr) YYABORT;
            unique_ptr_destroy_only<Json_object> object{::new (YYMEM_ROOT)
                                                            Json_object};
            if (object == nullptr) YYABORT;
            $$ = NEW_PTN Item_sum_json_object(
                @$, $3, $5, $7, std::move(wrapper), std::move(object));
          }
        | ST_COLLECT_SYM '(' in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_collect(@$, $3, $5, false);
          }
        | ST_COLLECT_SYM '(' DISTINCT in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_collect(@$, $4, $6, true );
          }
        | BIT_XOR_SYM  '(' in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_xor(@$, $3, $5);
          }
        | COUNT_SYM '(' opt_all '*' ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($6 != NULL) {
              $6->set_has_keep_clause(true);
            }
            if ($6 != NULL && $7 == NULL) {
              window = $6;
            } else if ($6 == NULL && $7 != NULL) {
              window = $7;
            } else if ($6 != NULL && $7 != NULL) {
              if($7->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@7);
                MYSQL_YYABORT;
              }
              $6->set_partition_list($7->get_partition_list());
              $6->set_has_keep_over_clause(true);
              window = $6;
            }

            $$= NEW_PTN PTI_count_sym(@$, window);
          }
        | COUNT_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            if ($5 != NULL && $6 == NULL) {
              window = $5;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
            }

            $$= NEW_PTN Item_sum_count(@$, $3, window);
          }
        | COUNT_SYM '(' DISTINCT expr_list ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($6 != NULL) {
              $6->set_has_keep_clause(true);
            }
            if ($6 != NULL && $7 == NULL) {
              window = $6;
            } else if ($6 == NULL && $7 != NULL) {
              window = $7;
            } else if ($6 != NULL && $7 != NULL) {
              if($7->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@7);
                MYSQL_YYABORT;
              }
              $6->set_partition_list($7->get_partition_list());
              $6->set_has_keep_over_clause(true);
              window = $6;
            }

            $$= new Item_sum_count(@$, $4, window);
          }
        | MIN_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            PT_window* window = NULL;
            if ($5 != NULL && $6 == NULL) {
              window = $5;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
            }

            $$= NEW_PTN Item_sum_min(@$, $3, window);
          }
        /*
          According to ANSI SQL, DISTINCT is allowed and has
          no sense inside MIN and MAX grouping functions; so MIN|MAX(DISTINCT ...)
          is processed like an ordinary MIN | MAX()
        */
        | MIN_SYM '(' DISTINCT in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($6 != NULL) {
              $6->set_has_keep_clause(true);
            }
            if ($6 != NULL && $7 == NULL) {
              window = $6;
            } else if ($6 == NULL && $7 != NULL) {
              window = $7;
            } else if ($6 != NULL && $7 != NULL) {
              if($7->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@7);
                MYSQL_YYABORT;
              }
              $6->set_partition_list($7->get_partition_list());
              $6->set_has_keep_over_clause(true);
              window = $6;
            }

            $$= NEW_PTN Item_sum_min(@$, $4, window);
          }
        | MAX_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            if ($5 != NULL && $6 == NULL) {
              window = $5;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
            }

            $$= NEW_PTN Item_sum_max(@$, $3, window);
          }
        | MAX_SYM '(' DISTINCT in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($6 != NULL) {
              $6->set_has_keep_clause(true);
            }
            if ($6 != NULL && $7 == NULL) {
              window = $6;
            } else if ($6 == NULL && $7 != NULL) {
              window = $7;
            } else if ($6 != NULL && $7 != NULL) {
              if($7->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@7);
                MYSQL_YYABORT;
              }
              $6->set_partition_list($7->get_partition_list());
              $6->set_has_keep_over_clause(true);
              window = $6;
            }

            $$= NEW_PTN Item_sum_max(@$, $4, window);
          }
        | STD_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            int sample = 0;
            PT_window* window = NULL;
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            if ($5 != NULL && $6 == NULL) {
              window = $5;
              sample = 1;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
              sample = 1;
            }

            $$= NEW_PTN Item_sum_std(@$, $3, sample, window);
          }
        | VARIANCE_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            int sample = 0;
            PT_window* window = NULL;
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            if ($5 != NULL && $6 == NULL) {
              window = $5;
              sample = 1;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
              sample = 1;
            }

            $$= NEW_PTN Item_sum_variance(@$, $3, sample, window);
          }
        | STDDEV_SAMP_SYM '(' in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_std(@$, $3, 1, $5);
          }
        | VAR_SAMP_SYM '(' in_sum_expr ')' opt_windowing_clause
          {
            $$= NEW_PTN Item_sum_variance(@$, $3, 1, $5);
          }
        | SUM_SYM '(' in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($5 != NULL) {
              $5->set_has_keep_clause(true);
            }
            if ($5 != NULL && $6 == NULL) {
              window = $5;
            } else if ($5 == NULL && $6 != NULL) {
              window = $6;
            } else if ($5 != NULL && $6 != NULL) {
              if($6->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@6);
                MYSQL_YYABORT;
              }
              $5->set_partition_list($6->get_partition_list());
              $5->set_has_keep_over_clause(true);
              window = $5;
            }

            $$= NEW_PTN Item_sum_sum(@$, $3, false, window);
          }
        | SUM_SYM '(' DISTINCT in_sum_expr ')' opt_keep_clause opt_windowing_clause
          {
            PT_window* window = NULL;
            if ($6 != NULL) {
              $6->set_has_keep_clause(true);
            }
            if ($6 != NULL && $7 == NULL) {
              window = $6;
            } else if ($6 == NULL && $7 != NULL) {
              window = $7;
            } else if ($6 != NULL && $7 != NULL) {
              if($7->get_order_list() != NULL) {
                YYTHD->syntax_error_at(@7);
                MYSQL_YYABORT;
              }
              $6->set_partition_list($7->get_partition_list());
              $6->set_has_keep_over_clause(true);
              window = $6;
            }

            $$= NEW_PTN Item_sum_sum(@$, $4, true, window);
          }
        | GROUP_CONCAT_SYM '(' opt_distinct
          expr_list opt_gorder_clause
          opt_gconcat_separator
          ')' opt_windowing_clause
          {
            // inherit or reference window spec is checked elsewhere.
            if ($8 && $8->effective_order_by()) {
              my_error(ER_CLAUSE_IN_LISTAGG_NOT_ALLOWED, MYF(0), "ORDER BY",
               "group_concat");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN Item_func_group_concat(@$, $3, $4, $5, $6, $8);
          }
        | LISTAGG_SYM '(' opt_distinct expr opt_listagg_separator ')'
          opt_listagg_within_group opt_windowing_clause
          {
            // inherit or reference window spec is checked elsewhere.
            if ($8 && $8->effective_order_by()) {
              my_error(ER_CLAUSE_IN_LISTAGG_NOT_ALLOWED, MYF(0), "ORDER BY",
               "listagg");
              MYSQL_YYABORT;
            }

            PT_item_list *el= NEW_PTN PT_item_list;
            if (el == NULL || el->push_back($4))
              MYSQL_YYABORT;

            $$= NEW_PTN Item_func_group_concat(@$, $3, el, $7, $5, $8, 1);
          }
        | WM_CONCAT_SYM '(' opt_distinct
          expr_list opt_gorder_clause
          opt_gconcat_separator
          ')' opt_windowing_clause
          {
            if ($5 != nullptr && $8 && $8->effective_order_by()) {
              my_error(ER_CLAUSE_IN_LISTAGG_NOT_ALLOWED, MYF(0), "ORDER BY",
               "wm_concat");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN Item_func_group_concat(@$, $3, $4, $5, $6, $8, 2);
          }
        ;

window_func_call:       // Window functions which do not exist as set functions
          ROW_NUMBER_SYM '(' ')' windowing_clause
          {
            $$=  NEW_PTN Item_row_number(@$, $4);
          }
        | RANK_SYM '(' ')' windowing_clause
          {
            $$= NEW_PTN Item_rank(@$, false, $4);
          }
        | DENSE_RANK_SYM '(' ')' windowing_clause
          {
            $$= NEW_PTN Item_rank(@$, true, $4);
          }
        | CUME_DIST_SYM '(' ')' windowing_clause
          {
            $$=  NEW_PTN Item_cume_dist(@$, $4);
          }
        | PERCENT_RANK_SYM '(' ')' windowing_clause
          {
            $$= NEW_PTN Item_percent_rank(@$, $4);
          }
        | NTILE_SYM '(' stable_integer ')' windowing_clause
          {
            $$=NEW_PTN Item_ntile(@$, $3, $5);
          }
        | LEAD_SYM '(' expr opt_lead_lag_info ')' opt_null_treatment windowing_clause
          {
            PT_item_list *args= NEW_PTN PT_item_list;
            if (args == NULL || args->push_back($3))
              MYSQL_YYABORT; // OOM
            if ($4.offset != NULL && args->push_back($4.offset))
              MYSQL_YYABORT; // OOM
            if ($4.default_value != NULL && args->push_back($4.default_value))
              MYSQL_YYABORT; // OOM
            $$= NEW_PTN Item_lead_lag(@$, true, args, $6, $7);
          }
        | LAG_SYM '(' expr opt_lead_lag_info ')' opt_null_treatment windowing_clause
          {
            PT_item_list *args= NEW_PTN PT_item_list;
            if (args == NULL || args->push_back($3))
              MYSQL_YYABORT; // OOM
            if ($4.offset != NULL && args->push_back($4.offset))
              MYSQL_YYABORT; // OOM
            if ($4.default_value != NULL && args->push_back($4.default_value))
              MYSQL_YYABORT; // OOM
            $$= NEW_PTN Item_lead_lag(@$, false, args, $6, $7);
          }
        | FIRST_VALUE_SYM '(' expr ')' opt_null_treatment windowing_clause
          {
            $$= NEW_PTN Item_first_last_value(@$, true, $3, $5, $6);
          }
        | LAST_VALUE_SYM  '(' expr ')' opt_null_treatment windowing_clause
          {
            $$= NEW_PTN Item_first_last_value(@$, false, $3, $5, $6);
          }
        | NTH_VALUE_SYM '(' expr ',' simple_expr ')' opt_from_first_last opt_null_treatment windowing_clause
          {
            PT_item_list *args= NEW_PTN PT_item_list;
            if (args == NULL ||
                args->push_back($3) ||
                args->push_back($5))
              MYSQL_YYABORT;
            $$= NEW_PTN Item_nth_value(@$, args, $7 == NFL_FROM_LAST, $8, $9);
          }
%ifdef SQL_MODE_ORACLE
        | RATIO_TO_REPORT_SYM '(' expr ')' opt_null_treatment windowing_clause
          {
            if(!$6 || $6->get_order_list() || !$6->frame()
              || !$6->frame()->m_originally_absent
              || $6->is_reference() || $6->inherit_from() || $5 != enum_null_treatment::NT_NONE) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                        "this usage with RATIO_TO_REPORT function");
              MYSQL_YYABORT;
            }
            $$= NEW_PTN Item_ratio_to_report_value(@$, $3, $6);
          }
%endif
        ;

opt_lead_lag_info:
          /* Nothing */
          {
            $$.offset= NULL;
            $$.default_value= NULL;
          }
        | ',' stable_integer opt_ll_default
          {
            $$.offset= $2;
            $$.default_value= $3;
          }
        ;

/*
  The stable_integer nonterminal symbol is not really constant, but constant
  for the duration of an execution.
*/
stable_integer:
          int64_literal  { $$ = $1; }
        | param_or_var
        ;

param_or_var:
          param_marker { $$ = $1; }
        | ident        { $$ = NEW_PTN PTI_int_splocal(@$, to_lex_cstring($1)); }
        | '@' ident_or_text     { $$ = NEW_PTN PTI_user_variable(@$, $2); }
        ;

opt_ll_default:
          /* Nothing */
          {
            $$= NULL;
          }
        | ',' expr
          {
            $$= $2;
          }
        ;

opt_null_treatment:
          /* Nothing */
          {
            $$= NT_NONE;
          }
        | RESPECT_SYM NULLS_SYM
          {
            $$= NT_RESPECT_NULLS;
          }
        | IGNORE_SYM NULLS_SYM
          {
            $$= NT_IGNORE_NULLS;
          }
        ;


opt_from_first_last:
          /* Nothing */
          {
            $$= NFL_NONE;
          }
        | FROM FIRST_SYM
          {
            $$= NFL_FROM_FIRST;
          }
        | FROM LAST_SYM
          {
            $$= NFL_FROM_LAST;
          }
        ;

opt_windowing_clause:
          /* Nothing */
          {
            $$= NULL;
          }
        | windowing_clause
          {
            $$= $1;
          }
        ;

opt_keep_clause:
          {
            $$ = NULL;
          }
        | keep_clause
          {
            $$ = $1;
          }

keep_clause:
          KEEP_SYM '(' DENSE_RANK_SYM keep_direction ORDER_SYM BY order_list ')'
          {
            auto start_bound = NEW_PTN PT_border(WBT_UNBOUNDED_PRECEDING);
            auto end_bound = NEW_PTN PT_border(WBT_CURRENT_ROW);
            auto bounds = NEW_PTN PT_borders(start_bound, end_bound);
            auto frame = NEW_PTN PT_frame(WFU_RANGE, bounds, nullptr);
            frame->m_originally_absent= true;
            $$ = NEW_PTN PT_window($4, NULL, $7, frame); 
          }
        ;

keep_direction:
          FIRST_SYM { $$ = KEEP_DIR_FIRST; }
        | LAST_SYM { $$ = KEEP_DIR_LAST; }
        ;

windowing_clause:
          OVER_SYM window_name_or_spec
          {
            $$= $2;
          }
        ;

window_name_or_spec:
          window_name
          {
            $$= NEW_PTN PT_window($1);
          }
        | window_spec
          {
            $$= $1;
          }
        ;

window_name:
          ident
          {
            $$= NEW_PTN Item_string($1.str, $1.length, YYTHD->charset());
          }
        ;

window_spec:
          '(' window_spec_details ')'
          {
            $$= $2;
          }
        ;

window_spec_details:
           opt_existing_window_name
           opt_partition_clause
           opt_window_order_by_clause
           opt_window_frame_clause
           {
             auto frame= $4;
             if (!frame) // build an equivalent frame spec
             {
               auto start_bound= NEW_PTN PT_border(WBT_UNBOUNDED_PRECEDING);
               auto end_bound= NEW_PTN PT_border($3 ? WBT_CURRENT_ROW :
                 WBT_UNBOUNDED_FOLLOWING);
               auto bounds= NEW_PTN PT_borders(start_bound, end_bound);
               frame= NEW_PTN PT_frame(WFU_RANGE, bounds, nullptr);
               frame->m_originally_absent= true;
             }
             $$= NEW_PTN PT_window($2, $3, frame, $1);
           }
         ;

opt_existing_window_name:
          /* Nothing */
          {
            $$= NULL;
          }
        | window_name
          {
            $$= $1;
          }
        ;

opt_partition_clause:
          /* Nothing */
          {
            $$= NULL;
          }
        | PARTITION_SYM BY group_list
          {
            $$= $3;
          }
        ;

opt_window_order_by_clause:
          /* Nothing */
          {
            $$= NULL;
          }
        | ORDER_SYM BY order_list
          {
            $$= $3;
          }
        ;

opt_window_frame_clause:
          /* Nothing*/
          {
            $$= NULL;
          }
        | window_frame_units
          window_frame_extent
          opt_window_frame_exclusion
          {
            $$= NEW_PTN PT_frame($1, $2, $3);
          }
        ;

window_frame_extent:
          window_frame_start
          {
            auto end_bound= NEW_PTN PT_border(WBT_CURRENT_ROW);
            $$= NEW_PTN PT_borders($1, end_bound);
          }
        | window_frame_between
          {
            $$= $1;
          }
        ;

window_frame_start:
          UNBOUNDED_SYM PRECEDING_SYM
          {
            $$= NEW_PTN PT_border(WBT_UNBOUNDED_PRECEDING);
          }
        | NUM_literal PRECEDING_SYM
          {
            $$= NEW_PTN PT_border(WBT_VALUE_PRECEDING, $1);
          }
        | param_marker PRECEDING_SYM
          {
            $$= NEW_PTN PT_border(WBT_VALUE_PRECEDING, $1);
          }
        | INTERVAL_SYM expr interval PRECEDING_SYM
          {
            $$= NEW_PTN PT_border(WBT_VALUE_PRECEDING, $2, $3);
          }
        | CURRENT_SYM ROW_SYM
          {
            $$= NEW_PTN PT_border(WBT_CURRENT_ROW);
          }
        ;

window_frame_between:
          BETWEEN_SYM window_frame_bound AND_SYM window_frame_bound
          {
            $$= NEW_PTN PT_borders($2, $4);
          }
        ;

window_frame_bound:
          window_frame_start
          {
            $$= $1;
          }
        | UNBOUNDED_SYM FOLLOWING_SYM
          {
            $$= NEW_PTN PT_border(WBT_UNBOUNDED_FOLLOWING);
          }
        | NUM_literal FOLLOWING_SYM
          {
            $$= NEW_PTN PT_border(WBT_VALUE_FOLLOWING, $1);
          }
        | param_marker FOLLOWING_SYM
          {
            $$= NEW_PTN PT_border(WBT_VALUE_FOLLOWING, $1);
          }
        | INTERVAL_SYM expr interval FOLLOWING_SYM
          {
            $$= NEW_PTN PT_border(WBT_VALUE_FOLLOWING, $2, $3);
          }
        ;

opt_window_frame_exclusion:
          /* Nothing */
          {
            $$= NULL;
          }
        | EXCLUDE_SYM CURRENT_SYM ROW_SYM
          {
            $$= NEW_PTN PT_exclusion(WFX_CURRENT_ROW);
          }
        | EXCLUDE_SYM GROUP_SYM
          {
            $$= NEW_PTN PT_exclusion(WFX_GROUP);
          }
        | EXCLUDE_SYM TIES_SYM
          {
            $$= NEW_PTN PT_exclusion(WFX_TIES);
          }
        | EXCLUDE_SYM NO_SYM OTHERS_SYM
          { $$= NEW_PTN PT_exclusion(WFX_NO_OTHERS);
          }
        ;

window_frame_units:
          ROWS_SYM    { $$= WFU_ROWS; }
        | RANGE_SYM   { $$= WFU_RANGE; }
        | GROUPS_SYM  { $$= WFU_GROUPS; }
        ;

grouping_operation:
          GROUPING_SYM '(' expr_list ')'
          {
            $$= NEW_PTN Item_func_grouping(@$, $3);
          }
        ;

in_expression_user_variable_assignment:
          '@' ident_or_text SET_VAR expr
          {
            push_warning(YYTHD, Sql_condition::SL_WARNING,
                         ER_WARN_DEPRECATED_SYNTAX,
                         ER_THD(YYTHD, ER_WARN_DEPRECATED_USER_SET_EXPR));
            $$ = NEW_PTN PTI_variable_aux_set_var(@$, $2, $4);
          }
        ;

rvalue_system_or_user_variable:
          '@' ident_or_text
          {
            $$ = NEW_PTN PTI_user_variable(@$, $2);
          }
        | '@' '@' opt_rvalue_system_variable_type rvalue_system_variable
          {
            $$ = NEW_PTN PTI_get_system_variable(@$, $3,
                                                 @4, $4.prefix, $4.name);
          }
        ;

opt_distinct:
          /* empty */ { $$ = 0; }
        | ALL         { $$ = 0; }
        | DISTINCT    { $$ = 1; }
        ;

opt_gconcat_separator:
          /* empty */
          {
            $$= NEW_PTN String(",", 1, &my_charset_latin1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | SEPARATOR_SYM text_string { $$ = $2; }
        ;

opt_listagg_separator:
          {
            $$= NEW_PTN String("", 0, &my_charset_latin1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | ',' listagg_separator
          { $$= $2; }
        ;

listagg_separator:
        text_string { $$ = $1; }
        | NUM
          {
            $$= NEW_PTN String($1.str, $1.length, &my_charset_latin1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | '-' NUM
          {
            const char *separator= YYTHD->strmake(@1.raw.start, @2.raw.end - @1.raw.start);
            $$= NEW_PTN String(separator, @2.raw.end - @1.raw.start, &my_charset_latin1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | DECIMAL_NUM
          {
            $$= NEW_PTN String($1.str, $1.length, &my_charset_latin1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | '-' DECIMAL_NUM
          {
            const char *separator= YYTHD->strmake(@1.raw.start, @2.raw.end - @1.raw.start);
            $$= NEW_PTN String(separator, @2.raw.end - @1.raw.start, &my_charset_latin1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

opt_listagg_within_group:
          /* empty */               { $$= NULL; }
        | WITHIN_SYM GROUP_SYM '(' opt_gorder_clause ')'
          {
            if ($4 == nullptr) {
              my_error(ER_ORDER_BY_MISSING, MYF(0));
              MYSQL_YYABORT;
            }
            $$= $4;
          }
        ;

opt_gorder_clause:
          /* empty */               { $$= NULL; }
        | ORDER_SYM BY gorder_list  { $$= $3; }
        ;

gorder_list:
          gorder_list ',' order_expr
          {
            $1->push_back($3);
            $$= $1;
          }
        | order_expr
          {
            $$= NEW_PTN PT_gorder_list();
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        ;

in_sum_expr:
          opt_all expr
          {
            $$= NEW_PTN PTI_in_sum_expr(@1, $2);
          }
        ;

cast_type:
          BINARY_SYM opt_field_length
          {
            $$.target= ITEM_CAST_CHAR;
            $$.charset= &my_charset_bin;
            $$.length= $2;
            $$.dec= NULL;
          }
        | CHAR_SYM opt_field_length opt_charset_with_opt_binary
          {
            $$.target= ITEM_CAST_CHAR;
            $$.length= $2;
            $$.dec= NULL;
            if ($3.force_binary)
            {
              // Bugfix: before this patch we ignored [undocumented]
              // collation modifier in the CAST(expr, CHAR(...) BINARY) syntax.
              // To restore old behavior just remove this "if ($3...)" branch.

              $$.charset= get_bin_collation($3.charset ? $3.charset :
                  YYTHD->variables.collation_connection);
              if ($$.charset == NULL)
                MYSQL_YYABORT;
            }
            else
              $$.charset= $3.charset;
          }
        | VARCHAR_SYM opt_field_length opt_charset_with_opt_binary
          {
            $$.target= ITEM_CAST_CHAR;
            $$.length= $2;
            $$.dec= NULL;
            if ($3.force_binary)
            {
              $$.charset= get_bin_collation($3.charset ? $3.charset :
                  YYTHD->variables.collation_connection);
              if ($$.charset == NULL)
                MYSQL_YYABORT;
            }
            else
              $$.charset= $3.charset;
          }
        | nchar opt_field_length
          {
            $$.target= ITEM_CAST_CHAR;
            $$.charset= national_charset_info;
            $$.length= $2;
            $$.dec= NULL;
            warn_about_deprecated_national(YYTHD);
          }
        | nvarchar opt_field_length
          {
            $$.target= ITEM_CAST_CHAR;
            $$.charset= national_charset_info;
            $$.length= $2;
            $$.dec= NULL;
            warn_about_deprecated_national(YYTHD);
          }
        | SIGNED_SYM
          {
            $$.target= ITEM_CAST_SIGNED_INT;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | SIGNED_SYM INT_SYM
          {
            $$.target= ITEM_CAST_SIGNED_INT;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | UNSIGNED_SYM
          {
            $$.target= ITEM_CAST_UNSIGNED_INT;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | UNSIGNED_SYM INT_SYM
          {
            $$.target= ITEM_CAST_UNSIGNED_INT;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | DATE_SYM
          {
            $$.target= ITEM_CAST_DATE;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | YEAR_SYM
          {
            $$.target= ITEM_CAST_YEAR;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | TIME_SYM type_datetime_precision
          {
            $$.target= ITEM_CAST_TIME;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= $2;
          }
        | DATETIME_SYM type_datetime_precision
          {
            $$.target= ITEM_CAST_DATETIME;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= $2;
          }
        | DECIMAL_SYM float_options
          {
            $$.target=ITEM_CAST_DECIMAL;
            $$.charset= NULL;
            $$.length= $2.length;
            $$.dec= $2.dec;
          }
        | NUMBER_SYM ora_number_float_options
          {
            $$.target= ITEM_CAST_DECIMAL;
            $$.charset= NULL;
            $$.length= $2.length;
            $$.dec= $2.dec;
          }
        | JSON_SYM
          {
            $$.target=ITEM_CAST_JSON;
            $$.charset= NULL;
            $$.length= NULL;
            $$.dec= NULL;
          }
        | real_type
          {
            $$.target = ($1 == Numeric_type::DOUBLE) ?
              ITEM_CAST_DOUBLE : ITEM_CAST_FLOAT;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | FLOAT_SYM standard_float_options
          {
            $$.target = ITEM_CAST_FLOAT;
            $$.charset = nullptr;
            $$.length = $2.length;
            $$.dec = nullptr;
          }
        | POINT_SYM
          {
            $$.target = ITEM_CAST_POINT;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | LINESTRING_SYM
          {
            $$.target = ITEM_CAST_LINESTRING;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | POLYGON_SYM
          {
            $$.target = ITEM_CAST_POLYGON;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | MULTIPOINT_SYM
          {
            $$.target = ITEM_CAST_MULTIPOINT;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | MULTILINESTRING_SYM
          {
            $$.target = ITEM_CAST_MULTILINESTRING;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | MULTIPOLYGON_SYM
          {
            $$.target = ITEM_CAST_MULTIPOLYGON;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        | GEOMETRYCOLLECTION_SYM
          {
            $$.target = ITEM_CAST_GEOMETRYCOLLECTION;
            $$.charset = nullptr;
            $$.length = nullptr;
            $$.dec = nullptr;
          }
        ;

opt_expr_list:
          /* empty */ { $$= NULL; }
        | expr_list
        ;

expr_list:
          expr
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | expr_list ',' expr
          {
            if ($1 == NULL || $1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

ident_list_arg:
          ident_list          { $$= $1; }
        | '(' ident_list ')'  { $$= $2; }
        ;

ident_list:
          simple_ident
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | ident_list ',' simple_ident
          {
            if ($1 == NULL || $1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

opt_expr:
          /* empty */    { $$= NULL; }
        | expr           { $$= $1; }
        ;

opt_else:
          /* empty */  { $$= NULL; }
        | ELSE expr    { $$= $2; }
        ;

opt_decode_expr:
          /* empty */  { $$= NULL; }
        |',' expr      { $$= $2; }
        ;

when_list:
          WHEN_SYM expr THEN_SYM expr
          {
            $$= new (YYMEM_ROOT) mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($2);
            $$->push_back($4);
          }
        | when_list WHEN_SYM expr THEN_SYM expr
          {
            $1->push_back($3);
            $1->push_back($5);
            $$= $1;
          }
        ;

table_reference:
%ifndef SQL_MODE_ORACLE
          table_factor { $$= $1; }
        | joined_table { $$= $1; }
        | '{' OJ_SYM esc_table_reference '}'
          {
            /*
              The ODBC escape syntax for Outer Join.

              All productions from table_factor and joined_table can be escaped,
              not only the '{LEFT | RIGHT} [OUTER] JOIN' syntax.
            */
            $$ = $3;
          }
        ;
%else
          table_factor opt_pivot_clause
          {
            if (!$2) { $$= $1; }
            else {
              $$ = gen_pivot_subquery(@$, YYTHD, $1, $2);
            }
          }
        | joined_table opt_pivot_clause
          {
            if (!$2) { $$= $1; }
            else {
              $$ = gen_pivot_subquery(@$, YYTHD, $1, $2);
            }
          }
        | '{' OJ_SYM esc_table_reference '}' opt_pivot_clause
          {
            /*
              The ODBC escape syntax for Outer Join.

              All productions from table_factor and joined_table can be escaped,
              not only the '{LEFT | RIGHT} [OUTER] JOIN' syntax.
            */
            if (!$5) { $$= $3; }
            else {
              $$ = gen_pivot_subquery(@$, YYTHD, $3, $5);
            }
          }
        ;
%endif

esc_table_reference:
          table_factor { $$= $1; }
        | joined_table { $$= $1; }
        ;

%ifdef SQL_MODE_ORACLE
opt_pivot_clause:
          /* empty */ %prec KEYWORD_USED_AS_IDENT { $$= NULL; }
        | PIVOT_SYM '(' pivot_sum_expr_list pivot_for_clause pivot_in_clause ')' opt_table_alias
          {
            $$ = NEW_PTN PT_pivot(YYTHD->mem_root, $3, $4, $5, $7);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }

pivot_sum_expr_list:
          pivot_sum_expr_list ',' pivot_sum_expr
          {
            if ($$->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        | pivot_sum_expr
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        ;

pivot_sum_expr:
          sum_expr select_alias
          {
            $$= NEW_PTN PTI_expr_with_alias(@$, $1, @1.cpp, to_lex_cstring($2));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

pivot_for_clause:
          FOR_SYM '(' simple_ident_without_q ',' simple_ident_without_q_list ')'
          {
            $$= NEW_PTN Item_row(@$, $3, $5->value);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | FOR_SYM '(' simple_ident_without_q ')'
          {
            $$= $3;
          }
        | FOR_SYM simple_ident_without_q
          {
            $$= $2;
          }
        ;

simple_ident_without_q_list:
          simple_ident_without_q
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | simple_ident_without_q_list ',' simple_ident_without_q
          {
            if ($1 == NULL || $1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

simple_ident_without_q:
          ident
          {
            $$= NEW_PTN PTI_simple_ident_ident(@$, to_lex_cstring($1));
            if (NULL == $$)
              MYSQL_YYABORT;
          }

pivot_in_clause:
          IN_SYM '(' pivot_in_expr_list ')' {$$ = $3; }
        ;

pivot_in_expr_list:
          pivot_in_expr_list ',' pivot_in_expr
          {
            if ($$->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        | pivot_in_expr
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        ;

pivot_in_expr:
          expr select_alias
          {
            $$= NEW_PTN PTI_expr_with_alias(@$, $1, @1.cpp, to_lex_cstring($2));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;
%endif

decode_list:
          ',' expr ',' expr
          {
            $$ = new (YYMEM_ROOT) mem_root_deque<Item *>(YYMEM_ROOT);
            if ($$ == NULL)
                MYSQL_YYABORT;
            $$->push_back($2);
            $$->push_back($4);
          }
        | decode_list ',' expr ',' expr
          {
            $1->push_back($3);
            $1->push_back($5);
            $$=$1;
          }
        ;

/*
  Join operations are normally left-associative, as in

    t1 JOIN t2 ON t1.a = t2.a JOIN t3 ON t3.a = t2.a

  This is equivalent to

    (t1 JOIN t2 ON t1.a = t2.a) JOIN t3 ON t3.a = t2.a

  They can also be right-associative without parentheses, e.g.

    t1 JOIN t2 JOIN t3 ON t2.a = t3.a ON t1.a = t2.a

  Which is equivalent to

    t1 JOIN (t2 JOIN t3 ON t2.a = t3.a) ON t1.a = t2.a

  In MySQL, JOIN and CROSS JOIN mean the same thing, i.e.:

  - A join without a <join specification> is the same as a cross join.
  - A cross join with a <join specification> is the same as an inner join.

  For the join operation above, this means that the parser can't know until it
  has seen the last ON whether `t1 JOIN t2` was a cross join or not. The only
  way to solve the abiguity is to keep shifting the tokens on the stack, and
  not reduce until the last ON is seen. We tell Bison this by adding a fake
  token CONDITIONLESS_JOIN which has lower precedence than all tokens that
  would continue the join. These are JOIN_SYM, INNER_SYM, CROSS,
  STRAIGHT_JOIN, NATURAL, LEFT, RIGHT, ON and USING. This way the automaton
  only reduces to a cross join unless no other interpretation is
  possible. This gives a right-deep join tree for join *with* conditions,into
  which is what is expected.

  The challenge here is that t1 JOIN t2 *could* have been a cross join, we
  just don't know it until afterwards. So if the query had been

    t1 JOIN t2 JOIN t3 ON t2.a = t3.a

  we will first reduce `t2 JOIN t3 ON t2.a = t3.a` to a <table_reference>,
  which is correct, but a problem arises when reducing t1 JOIN
  <table_reference>. If we were to do that, we'd get a right-deep tree. The
  solution is to build the tree downwards instead of upwards, as is normally
  done. This concept may seem outlandish at first, but it's really quite
  simple. When the semantic action for table_reference JOIN table_reference is
  executed, the parse tree is (please pardon the ASCII graphic):

                       JOIN ON t2.a = t3.a
                      /    \
                     t2    t3

  Now, normally we'd just add the cross join node on top of this tree, as:

                    JOIN
                   /    \
                 t1    JOIN ON t2.a = t3.a
                      /    \
                     t2    t3

  This is not the meaning of the query, however. The cross join should be
  addded at the bottom:


                       JOIN ON t2.a = t3.a
                      /    \
                    JOIN    t3
                   /    \
                  t1    t2

  There is only one rule to pay attention to: If the right-hand side of a
  cross join is a join tree, find its left-most leaf (which is a table
  name). Then replace this table name with a cross join of the left-hand side
  of the top cross join, and the right hand side with the original table.

  Natural joins are also syntactically conditionless, but we need to make sure
  that they are never right associative. We handle them in their own rule
  natural_join, which is left-associative only. In this case we know that
  there is no join condition to wait for, so we can reduce immediately.
*/
joined_table:
          table_reference inner_join_type table_reference ON_SYM expr
          {
            $$= NEW_PTN PT_joined_table_on($1, @2, $2, $3, $5);
          }
        | table_reference inner_join_type table_reference USING
          '(' using_list ')'
          {
            $$= NEW_PTN PT_joined_table_using($1, @2, $2, $3, $6);
          }
        | table_reference outer_join_type table_reference ON_SYM expr
          {
            $$= NEW_PTN PT_joined_table_on($1, @2, $2, $3, $5);
          }
        | table_reference outer_join_type table_reference USING '(' using_list ')'
          {
            if($2 == JTT_FULL) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                        "FULL JOIN with USING clause");
              MYSQL_YYABORT;
            }

            $$= NEW_PTN PT_joined_table_using($1, @2, $2, $3, $6);
          }
        | table_reference inner_join_type table_reference
          %prec CONDITIONLESS_JOIN
          {
            auto this_cross_join= NEW_PTN PT_cross_join($1, @2, $2, NULL);

            if ($3 == NULL)
              MYSQL_YYABORT; // OOM

            $$= $3->add_cross_join(this_cross_join);
          }
        | table_reference natural_join_type table_factor
          {
            $$= NEW_PTN PT_joined_table_using($1, @2, $2, $3);
          }
        ;

natural_join_type:
          NATURAL opt_inner JOIN_SYM       { $$= JTT_NATURAL_INNER; }
        | NATURAL RIGHT opt_outer JOIN_SYM { $$= JTT_NATURAL_RIGHT; }
        | NATURAL LEFT opt_outer JOIN_SYM  { $$= JTT_NATURAL_LEFT; }
        ;

inner_join_type:
          JOIN_SYM                         { $$= JTT_INNER; }
        | INNER_SYM JOIN_SYM               { $$= JTT_INNER; }
        | CROSS JOIN_SYM                   { $$= JTT_INNER; }
        | STRAIGHT_JOIN                    { $$= JTT_STRAIGHT_INNER; }

outer_join_type:
          LEFT opt_outer JOIN_SYM          { $$= JTT_LEFT; }
        | RIGHT opt_outer JOIN_SYM         { $$= JTT_RIGHT; }
        | FULL opt_outer JOIN_SYM          { $$= JTT_FULL; }
        ;

opt_inner:
          /* empty */
        | INNER_SYM
        ;

opt_outer:
          /* empty */
        | OUTER_SYM
        ;

/*
  table PARTITION (list of partitions), reusing using_list instead of creating
  a new rule for partition_list.
*/
opt_use_partition:
          /* empty */ { $$= NULL; }
        | use_partition
        ;

use_partition:
          PARTITION_SYM '(' using_list ')'
          {
            $$= $3;
          }
        ;

/**
  MySQL has a syntax extension where a comma-separated list of table
  references is allowed as a table reference in itself, for instance

    SELECT * FROM (t1, t2) JOIN t3 ON 1

  which is not allowed in standard SQL. The syntax is equivalent to

    SELECT * FROM (t1 CROSS JOIN t2) JOIN t3 ON 1

  We call this rule table_reference_list_parens.

  A <table_factor> may be a <single_table>, a <subquery>, a <derived_table>, a
  <joined_table>, or the bespoke <table_reference_list_parens>, each of those
  enclosed in any number of parentheses. This makes for an ambiguous grammar
  since a <table_factor> may also be enclosed in parentheses. We get around
  this by designing the grammar so that a <table_factor> does not have
  parentheses, but all the sub-cases of it have their own parentheses-rules,
  i.e. <single_table_parens>, <joined_table_parens> and
  <table_reference_list_parens>. It's a bit tedious but the grammar is
  unambiguous and doesn't have shift/reduce conflicts.
*/
table_factor:
          single_table
        | single_table_parens
        | derived_table { $$ = $1; }
        | joined_table_parens
          { $$= NEW_PTN PT_table_factor_joined_table($1); }
        | table_reference_list_parens
          { $$= NEW_PTN PT_table_reference_list_parens($1); }
        | table_function { $$ = $1; }
        ;

table_reference_list_parens:
          '(' table_reference_list_parens ')' { $$= $2; }
        | '(' table_reference_list ',' table_reference ')'
          {
            $$= $2;
            if ($$.push_back($4))
              MYSQL_YYABORT; // OOM
          }
        ;

single_table_parens:
          '(' single_table_parens ')' { $$= $2; }
        | '(' single_table ')' { $$= $2; }
        ;

single_table:
          table_ident opt_use_partition opt_table_alias opt_key_definition
          {
            $$= NEW_PTN PT_table_factor_table_ident($1, $2, $3, $4);
          }
        ;

joined_table_parens:
          '(' joined_table_parens ')' { $$= $2; }
        | '(' joined_table ')' { $$= $2; }
        ;

derived_table:
          table_subquery opt_table_alias opt_derived_column_list
          {
            /*
              The alias is actually not optional at all, but being MySQL we
              are friendly and give an informative error message instead of
              just 'syntax error'.
            */
            if ($2.str == nullptr){
              char temp_ptr[32];
              memset(temp_ptr,0,sizeof(temp_ptr));
              Item *tmp = NEW_PTN Item_func_uuid_short(@$);
              if (unlikely(tmp == NULL))
                MYSQL_YYABORT;
              longlong uuid = tmp->val_int();

              sprintf(temp_ptr,"alias_temp_%lld",uuid);
              const char * ptr = YYTHD->strmake(temp_ptr, strlen(temp_ptr));
              if (ptr == NULL)
                MYSQL_YYABORT;
              $2 = to_lex_cstring(ptr);
            }

            $$= NEW_PTN PT_derived_table(false, $1, $2, &$3);
          }
        | LATERAL_SYM table_subquery opt_table_alias opt_derived_column_list
          {
            if ($3.str == nullptr)
              my_message(ER_DERIVED_MUST_HAVE_ALIAS,
                         ER_THD(YYTHD, ER_DERIVED_MUST_HAVE_ALIAS), MYF(0));

            $$= NEW_PTN PT_derived_table(true, $2, $3, &$4);
          }
        ;

table_function:
          JSON_TABLE_SYM '(' expr ',' text_literal columns_clause ')'
          opt_table_alias
          {
            // Alias isn't optional, follow derived's behavior
            if ($8 == NULL_CSTR)
            {
              my_message(ER_TF_MUST_HAVE_ALIAS,
                         ER_THD(YYTHD, ER_TF_MUST_HAVE_ALIAS), MYF(0));
              MYSQL_YYABORT;
            }

            $$= NEW_PTN PT_table_factor_function($3, $5, $6, to_lex_string($8));
          }
        | SEQUENCE_TABLE_SYM '(' expr ')' opt_table_alias
          {
            // Alias isn't optional, follow derived's behavior
            if ($5 == NULL_CSTR)
            {
              my_message(ER_TF_MUST_HAVE_ALIAS,
                         ER_THD(YYTHD, ER_TF_MUST_HAVE_ALIAS), MYF(0));
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PT_table_sequence_function($3, $5);
          }
%ifdef SQL_MODE_ORACLE
        | TABLE_SYM '(' expr ')' ora_table_alias
          {
            $$= NEW_PTN PT_table_udt_function($3, $5);
          }
        ;

ora_table_alias:
          /* empty */
          {
            Item *tmp = NEW_PTN Item_func_uuid_short(@$);
            if (unlikely(tmp == NULL))
              MYSQL_YYABORT;
            longlong uuid = tmp->val_int();

            char temp_ptr[32];
            snprintf(temp_ptr, sizeof(temp_ptr), "udt_table_%lld", uuid);
            const char * ptr = YYTHD->strmake(temp_ptr, strlen(temp_ptr));
            if (ptr == NULL)
              MYSQL_YYABORT;
            $$ = to_lex_cstring(ptr);
          }
        | table_alias_ident { $$ = to_lex_cstring($1); }
        ;
%endif

columns_clause:
          COLUMNS '(' columns_list ')'
          {
            $$= $3;
          }
        ;

columns_list:
          jt_column
          {
            $$= NEW_PTN Mem_root_array<PT_json_table_column *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | columns_list ',' jt_column
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

jt_column:
          ident FOR_SYM ORDINALITY_SYM
          {
            $$= NEW_PTN PT_json_table_column_for_ordinality($1);
          }
        | ident type opt_collate jt_column_type PATH_SYM text_literal
          opt_on_empty_or_error_json_table
          {
            auto column = make_unique_destroy_only<Json_table_column>(
                YYMEM_ROOT, $4, $6, $7.error.type, $7.error.default_string,
                $7.empty.type, $7.empty.default_string);
            if (column == nullptr) MYSQL_YYABORT;  // OOM
            $$ = NEW_PTN PT_json_table_column_with_path(std::move(column), $1,
                                                        $2, $3);
          }
        | NESTED_SYM PATH_SYM text_literal columns_clause
          {
            $$= NEW_PTN PT_json_table_column_with_nested_path($3, $4);
          }
        ;

jt_column_type:
          {
            $$= enum_jt_column::JTC_PATH;
          }
        | EXISTS
          {
            $$= enum_jt_column::JTC_EXISTS;
          }
        ;

// The optional ON EMPTY and ON ERROR clauses for JSON_TABLE and
// JSON_VALUE. If both clauses are specified, the ON EMPTY clause
// should come before the ON ERROR clause.
opt_on_empty_or_error:
          /* empty */
          {
            $$.empty = {Json_on_response_type::IMPLICIT, nullptr};
            $$.error = {Json_on_response_type::IMPLICIT, nullptr};
          }
        | on_empty
          {
            $$.empty = $1;
            $$.error = {Json_on_response_type::IMPLICIT, nullptr};
          }
        | on_error
          {
            $$.error = $1;
            $$.empty = {Json_on_response_type::IMPLICIT, nullptr};
          }
        | on_empty on_error
          {
            $$.empty = $1;
            $$.error = $2;
          }
        ;

// JSON_TABLE extends the syntax by allowing ON ERROR to come before ON EMPTY.
opt_on_empty_or_error_json_table:
          opt_on_empty_or_error { $$ = $1; }
        | on_error on_empty
          {
            push_warning(
              YYTHD, Sql_condition::SL_WARNING, ER_WARN_DEPRECATED_SYNTAX,
              ER_THD(YYTHD, ER_WARN_DEPRECATED_JSON_TABLE_ON_ERROR_ON_EMPTY));
            $$.error = $1;
            $$.empty = $2;
          }
        ;

on_empty:
          json_on_response ON_SYM EMPTY_SYM     { $$= $1; }
        ;
on_error:
          json_on_response ON_SYM ERROR_SYM     { $$= $1; }
        ;
json_on_response:
          ERROR_SYM
          {
            $$ = {Json_on_response_type::ERROR, nullptr};
          }
        | NULL_SYM
          {
            $$ = {Json_on_response_type::NULL_VALUE, nullptr};
          }
        | DEFAULT_SYM signed_literal
          {
            $$ = {Json_on_response_type::DEFAULT, $2};
          }
        ;

index_hint_clause:
          /* empty */
          {
            $$= old_mode ?  INDEX_HINT_MASK_JOIN : INDEX_HINT_MASK_ALL;
          }
        | FOR_SYM JOIN_SYM      { $$= INDEX_HINT_MASK_JOIN;  }
        | FOR_SYM ORDER_SYM BY  { $$= INDEX_HINT_MASK_ORDER; }
        | FOR_SYM GROUP_SYM BY  { $$= INDEX_HINT_MASK_GROUP; }
        ;

index_hint_type:
          FORCE_SYM  { $$= INDEX_HINT_FORCE; }
        | IGNORE_SYM { $$= INDEX_HINT_IGNORE; }
        ;

index_hint_definition:
          index_hint_type key_or_index index_hint_clause
          '(' key_usage_list ')'
          {
            init_index_hints($5, $1, $3);
            $$= $5;
          }
        | USE_SYM key_or_index index_hint_clause
          '(' opt_key_usage_list ')'
          {
            init_index_hints($5, INDEX_HINT_USE, $3);
            $$= $5;
          }
       ;

index_hints_list:
          index_hint_definition
        | index_hints_list index_hint_definition
          {
            $2->concat($1);
            $$= $2;
          }
        ;

opt_index_hints_list:
          /* empty */ { $$= NULL; }
        | index_hints_list
        ;

opt_key_definition:
          opt_index_hints_list
        ;

opt_key_usage_list:
          /* empty */
          {
            $$= NEW_PTN List<Index_hint>;
            Index_hint *hint= NEW_PTN Index_hint(NULL, 0);
            if ($$ == NULL || hint == NULL || $$->push_front(hint))
              MYSQL_YYABORT;
          }
        | key_usage_list
        ;

key_usage_element:
          ident
          {
            $$= NEW_PTN Index_hint($1.str, $1.length);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | PRIMARY_SYM
          {
            $$= NEW_PTN Index_hint(STRING_WITH_LEN("PRIMARY"));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

key_usage_list:
          key_usage_element
          {
            $$= NEW_PTN List<Index_hint>;
            if ($$ == NULL || $$->push_front($1))
              MYSQL_YYABORT;
          }
        | key_usage_list ',' key_usage_element
          {
            if ($$->push_front($3))
              MYSQL_YYABORT;
          }
        ;

using_list:
          ident_string_list
        ;

ident_string_list:
          ident
          {
            $$= NEW_PTN List<String>;
            String *s= NEW_PTN String(const_cast<const char *>($1.str),
                                               $1.length,
                                               system_charset_info);
            if ($$ == NULL || s == NULL || $$->push_back(s))
              MYSQL_YYABORT;
          }
        | ident_string_list ',' ident
          {
            String *s= NEW_PTN String(const_cast<const char *>($3.str),
                                               $3.length,
                                               system_charset_info);
            if (s == NULL || $1->push_back(s))
              MYSQL_YYABORT;
            $$= $1;
          }
        ;

interval_real_ulong_num:
          real_ulong_num
          {
            if ($1 >= 9) {
              char buf[MAX_BIGINT_WIDTH + 1];
              snprintf(buf, sizeof(buf), "%lu", $1);
              my_error(ER_WRONG_VALUE, MYF(0), "precision was not between 0 ~ 9", buf);
              MYSQL_YYABORT;
            }
          }

interval_ora:
          interval_time_stamp TO_SYM  interval_time_stamp
          {
            if($1 == INTERVAL_MINUTE && $3 == INTERVAL_SECOND)
              $$=INTERVAL_MINUTE_SECOND;
            else if($1 == INTERVAL_HOUR && $3 == INTERVAL_MINUTE)
              $$=INTERVAL_HOUR_MINUTE;
            else if($1 == INTERVAL_HOUR && $3 == INTERVAL_SECOND)
              $$=INTERVAL_HOUR_SECOND;
            else if($1 == INTERVAL_HOUR && $3 == INTERVAL_MICROSECOND)
              $$=INTERVAL_HOUR_MICROSECOND;
            else if($1 == INTERVAL_DAY && $3 == INTERVAL_HOUR)
              $$=INTERVAL_DAY_HOUR;
            else if($1 == INTERVAL_DAY && $3 == INTERVAL_MINUTE)
              $$=INTERVAL_DAY_MINUTE;
            else if($1 == INTERVAL_DAY && $3 == INTERVAL_SECOND)
              $$=INTERVAL_DAY_SECOND;
            else if($1 == INTERVAL_YEAR && $3 == INTERVAL_MONTH)
              $$=INTERVAL_YEAR_MONTH;
            else
            {
              const char * errinfo= YYTHD->strmake(@1.raw.start,@3.raw.end - @1.raw.start);
              my_error(ER_WRONG_VALUE, MYF(0), "Unsupported syntax ", errinfo);
              MYSQL_YYABORT;
            }
          }
        ;

interval_time_stamp_ora:
          MICROSECOND_SYM '(' interval_real_ulong_num ')' { $$=INTERVAL_MICROSECOND; }
        | SECOND_SYM '(' interval_real_ulong_num ')' { $$=INTERVAL_SECOND; }
        | SECOND_SYM '(' interval_real_ulong_num ',' interval_real_ulong_num ')' { $$=INTERVAL_SECOND; }
        | MINUTE_SYM '(' interval_real_ulong_num ')' { $$=INTERVAL_MINUTE; }
        | HOUR_SYM '(' interval_real_ulong_num ')'   { $$=INTERVAL_HOUR; }
        | DAY_SYM '(' interval_real_ulong_num ')'    { $$=INTERVAL_DAY; }
        | MONTH_SYM '(' interval_real_ulong_num ')'  { $$=INTERVAL_MONTH; }
        | YEAR_SYM '(' interval_real_ulong_num ')'   { $$=INTERVAL_YEAR; }

interval:
          interval_time_stamp    {}
        | DAY_HOUR_SYM           { $$=INTERVAL_DAY_HOUR; }
        | DAY_MICROSECOND_SYM    { $$=INTERVAL_DAY_MICROSECOND; }
        | DAY_MINUTE_SYM         { $$=INTERVAL_DAY_MINUTE; }
        | DAY_SECOND_SYM         { $$=INTERVAL_DAY_SECOND; }
        | HOUR_MICROSECOND_SYM   { $$=INTERVAL_HOUR_MICROSECOND; }
        | HOUR_MINUTE_SYM        { $$=INTERVAL_HOUR_MINUTE; }
        | HOUR_SECOND_SYM        { $$=INTERVAL_HOUR_SECOND; }
        | MINUTE_MICROSECOND_SYM { $$=INTERVAL_MINUTE_MICROSECOND; }
        | MINUTE_SECOND_SYM      { $$=INTERVAL_MINUTE_SECOND; }
        | SECOND_MICROSECOND_SYM { $$=INTERVAL_SECOND_MICROSECOND; }
        | YEAR_MONTH_SYM         { $$=INTERVAL_YEAR_MONTH; }
        | interval_ora           {}
        ;

interval_time_stamp:
          DAY_SYM         { $$=INTERVAL_DAY; }
        | WEEK_SYM        { $$=INTERVAL_WEEK; }
        | HOUR_SYM        { $$=INTERVAL_HOUR; }
        | MINUTE_SYM      { $$=INTERVAL_MINUTE; }
        | MONTH_SYM       { $$=INTERVAL_MONTH; }
        | QUARTER_SYM     { $$=INTERVAL_QUARTER; }
        | SECOND_SYM      { $$=INTERVAL_SECOND; }
        | MICROSECOND_SYM { $$=INTERVAL_MICROSECOND; }
        | YEAR_SYM        { $$=INTERVAL_YEAR; }
        | interval_time_stamp_ora {}
        ;

date_time_type:
          DATE_SYM  {$$= MYSQL_TIMESTAMP_DATE; }
        | TIME_SYM  {$$= MYSQL_TIMESTAMP_TIME; }
        | TIMESTAMP_SYM {$$= MYSQL_TIMESTAMP_DATETIME; }
        | DATETIME_SYM  {$$= MYSQL_TIMESTAMP_DATETIME; }
        ;

opt_as:
          /* empty */
        | AS
        ;

opt_table_alias:
          /* empty */  { $$ = NULL_CSTR; }
        | opt_as table_alias_ident { $$ = to_lex_cstring($2); }
        ;

opt_all:
          /* empty */
        | ALL
        ;

opt_where_clause:
          /* empty */   { $$ = nullptr; }
        | where_clause
        ;

where_clause:
          WHERE expr    { $$ = NEW_PTN PTI_where(@2, $2); }
        ;

opt_connect_clause:
          /* empty */   { $$ = nullptr; }
        | connect_by_clause
          {
            $$= $1;
          }
        ;

start_with_clause:
          START_WITH_SYM expr { $$= NEW_PTN PTI_start_with(@2, $2); }
        ;

connect_by_clause:
           start_with_clause connect_by_opt expr
          {
            $$= NEW_PTN PT_connect_by($1, $3, $2);
          }
        | connect_by_opt expr start_with_clause
          {
            $$= NEW_PTN PT_connect_by($3, $2, $1);
          }
        | connect_by_opt expr
          {
            $$= NEW_PTN PT_connect_by(nullptr, $2, $1);
          }
        ;

connect_by_opt:
          CONNECT_SYM BY NO_CYCLE_SYM
          {
            $$= 1;
          }
        | CONNECT_SYM BY
          {
            $$= 0;
          }
        ;

opt_having_clause:
          /* empty */ { $$= NULL; }
        | HAVING expr
          {
            $$= new PTI_having(@$, $2);
          }
        ;

with_clause:
          WITH with_list
          {
            $$= NEW_PTN PT_with_clause($2, false);
          }
        | WITH RECURSIVE_SYM with_list
          {
            $$= NEW_PTN PT_with_clause($3, true);
          }
        | WITH sf_tail ';'
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if (lex->spname->m_explicit_name)
            {
              /*
                Don't allow the following syntax:
                with function avoids the <db>.function format
                Only in the current session,the current DB is valid
              */
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                        "with function avoids the <db>.function format.");
              MYSQL_YYABORT;
            }

            if (lex->sp_chistics.suid == SP_IS_DEFAULT_SUID)
              lex->sp_chistics.suid = SP_IS_NOT_SUID;
            if (lex->sp_chistics.suid != SP_IS_NOT_SUID) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0), "not INVOKER");
              MYSQL_YYABORT;
            }

            /*
             fake empty database name in case this is inserted into cache.
            */
            lex->spname->m_explicit_name = true;
            lex->spname->m_db = EMPTY_CSTR;
            lex->spname->init_qname(thd);

            lex->sphead->m_sql_mode = thd->variables.sql_mode;
            /*
             to bypass some check
            */
            lex->sphead->m_fake_synonym = true;
            lex->sphead->set_sp_cache_version(sp_cache_version());

            lex->m_with_func = true;
          }
        ;

with_list:
          with_list ',' common_table_expr
          {
            if ($1->push_back($3))
              MYSQL_YYABORT;
          }
        | common_table_expr
          {
            $$= NEW_PTN PT_with_list(YYTHD->mem_root);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;    /* purecov: inspected */
          }
        ;

common_table_expr:
          ident opt_derived_column_list AS table_subquery
          {
            LEX_STRING subq_text;
            subq_text.length= @4.cpp.length();
            subq_text.str= YYTHD->strmake(@4.cpp.start, subq_text.length);
            if (subq_text.str == NULL)
              MYSQL_YYABORT;   /* purecov: inspected */
            uint subq_text_offset= @4.cpp.start - YYLIP->get_cpp_buf();
            $$= NEW_PTN PT_common_table_expr($1, subq_text, subq_text_offset,
                                             $4, &$2, YYTHD->mem_root);
            if ($$ == NULL)
              MYSQL_YYABORT;   /* purecov: inspected */
          }
        ;

opt_derived_column_list:
          /* empty */
          {
            /*
              Because () isn't accepted by the rule of
              simple_ident_list, we can use an empty array to
              designates that the parenthesised list was omitted.
            */
            $$.init(YYTHD->mem_root);
          }
        | '(' simple_ident_list ')'
          {
            $$= $2;
          }
        ;

simple_ident_list:
          ident
          {
            $$.init(YYTHD->mem_root);
            if ($$.push_back(to_lex_cstring($1)))
              MYSQL_YYABORT; /* purecov: inspected */
          }
        | simple_ident_list ',' ident
          {
            $$= $1;
            if ($$.push_back(to_lex_cstring($3)))
              MYSQL_YYABORT;  /* purecov: inspected */
          }
        ;

opt_window_clause:
          /* Nothing */
          {
            $$= NULL;
          }
        | WINDOW_SYM window_definition_list
          {
            $$= $2;
          }
        ;

window_definition_list:
          window_definition
          {
            $$= NEW_PTN PT_window_list();
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | window_definition_list ',' window_definition
          {
            if ($1->push_back($3))
              MYSQL_YYABORT; // OOM
            $$= $1;
          }
        ;

window_definition:
          window_name AS window_spec
          {
            $$= $3;
            if ($$ == NULL)
              MYSQL_YYABORT; // OOM
            $$->set_name($1);
          }
        ;

/*
   group by statement in select
*/

opt_group_clause:
          /* empty */ { $$= NULL; }
        | GROUP_SYM BY group_list olap_opt
          {
            $$= NEW_PTN PT_group($3, $4);
          }
        ;

group_list:
          group_list ',' grouping_expr
          {
            $1->push_back($3);
            $$= $1;
          }
        | grouping_expr
          {
            $$= NEW_PTN PT_order_list();
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        ;


olap_opt:
          /* empty */   { $$= UNSPECIFIED_OLAP_TYPE; }
        | WITH_ROLLUP_SYM { $$= ROLLUP_TYPE; }
            /*
              'WITH ROLLUP' is needed for backward compatibility,
              and cause LALR(2) conflicts.
              This syntax is not standard.
              MySQL syntax: GROUP BY col1, col2, col3 WITH ROLLUP
              SQL-2003: GROUP BY ... ROLLUP(col1, col2, col3)
            */
        ;

/*
  Order by statement in ALTER TABLE
*/

alter_order_list:
          alter_order_list ',' alter_order_item
          {
            $$= $1;
            $$->push_back($3);
          }
        | alter_order_item
          {
            $$= NEW_PTN PT_order_list();
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        ;

alter_order_item:
          simple_ident_nospvar opt_ordering_direction
          {
            $$= NEW_PTN PT_order_expr($1, $2);
          }
        ;

opt_order_clause:
          /* empty */ { $$= NULL; }
        | order_clause
        ;

order_clause:
          ORDER_SYM BY order_list
          {
            $$= NEW_PTN PT_order($3);
          }
        ;

order_list:
          order_list ',' order_expr
          {
            $1->push_back($3);
            $$= $1;
          }
        | order_expr
          {
            $$= NEW_PTN PT_order_list();
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->push_back($1);
          }
        ;

opt_ordering_direction:
          /* empty */ { $$= ORDER_NOT_RELEVANT; }
        | ordering_direction
        ;

ordering_direction:
          ASC         { $$= ORDER_ASC; }
        | DESC        { $$= ORDER_DESC; }
        ;

opt_nulls_position:
          /* empty */
          {
%ifdef SQL_MODE_ORACLE
            $$= NULLS_POS_ORACLE;
%else
            $$= NULLS_POS_MYSQL;
%endif
          }
        | NULLS_SYM FIRST_SYM { $$= NULLS_POS_FIRST; }
        | NULLS_SYM LAST_SYM { $$= NULLS_POS_LAST; }
        ;

opt_limit_clause:
          /* empty */ { $$= NULL; }
        | limit_clause
        ;

limit_clause:
          LIMIT limit_options
          {
            $$= NEW_PTN PT_limit_clause($2);
          }
        | offset_fetch_limit_clause
          {
            $$= NEW_PTN PT_limit_clause($1);
          }
        ;

limit_options:
          limit_option
          {
            $$.limit= $1;
            $$.opt_offset= NULL;
            $$.is_offset_first= 0;
            $$.percent= false;
            $$.ties= false;
          }
        | limit_option ',' limit_option
          {
            $$.limit= $3;
            $$.opt_offset= $1;
            $$.is_offset_first= 1;
            $$.percent= false;
            $$.ties= false;
          }
        | limit_option OFFSET_SYM limit_option
          {
            $$.limit= $1;
            $$.opt_offset= $3;
            $$.is_offset_first= 0;
            $$.percent= false;
            $$.ties= false;
          }
        ;

offset_fetch_limit_clause:
          OFFSET_SYM
          bit_expr
          row_or_rows
          {
            $$.opt_offset= $2;
            $$.is_offset_first= 2;
            $$.ties= false;
            $$.percent= false;
            $$.limit= nullptr;
          }
        | FETCH_SYM
          first_or_next
          opt_fetch_value
          only_or_ties
          {
            $$.limit= $3.limit;
            $$.opt_offset= nullptr;
            $$.is_offset_first= 2;
            $$.percent= $3.percent;
            $$.ties= $4;
          }
        | OFFSET_SYM
          bit_expr
          row_or_rows
          FETCH_SYM
          first_or_next
          opt_fetch_value
          only_or_ties
          {
            $$.limit= $6.limit;
            $$.opt_offset= $2;
            $$.is_offset_first= 2;
            $$.percent= $6.percent;
            $$.ties= $7;
          }
        ;

opt_fetch_value:
          row_or_rows
          {
            $$.limit= NEW_PTN Item_uint(1);
            $$.percent= false;
          }
        | bit_expr row_or_rows
          {
            $$.limit = $1;
            $$.percent= false;
          }
        | bit_expr PERCENT_SYM row_or_rows
          {
            $$.limit = $1;
            $$.percent= true;
          }
        ;

first_or_next:
          FIRST_SYM
        | NEXT_SYM

row_or_rows:
          ROW_SYM
        | ROWS_SYM
        ;

only_or_ties:
          ONLY_SYM
          {
            $$=false;
          }
        | WITH TIES_SYM
          {
            $$=true;
          }
        ;

limit_option:
          ident
          {
            $$= NEW_PTN PTI_limit_option_ident(@$, to_lex_cstring($1));
          }
        | param_marker
          {
            $$= NEW_PTN PTI_limit_option_param_marker(@$, $1);
          }
        | ULONGLONG_NUM
          {
            $$= NEW_PTN Item_uint(@$, $1.str, $1.length);
          }
        | LONG_NUM
          {
            $$= NEW_PTN Item_uint(@$, $1.str, $1.length);
          }
        | NUM
          {
            $$= NEW_PTN Item_uint(@$, $1.str, $1.length);
          }
        ;

opt_simple_limit:
          /* empty */        { $$= NULL; }
        | LIMIT limit_option { $$= $2; }
        ;

ulong_num:
          NUM           { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | HEX_NUM       { $$= (ulong) my_strtoll($1.str, (char**) 0, 16); }
        | LONG_NUM      { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | ULONGLONG_NUM { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | DECIMAL_NUM   { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | FLOAT_NUM     { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        ;

real_ulong_num:
          NUM           { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | HEX_NUM       { $$= (ulong) my_strtoll($1.str, (char**) 0, 16); }
        | LONG_NUM      { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | ULONGLONG_NUM { int error; $$= (ulong) my_strtoll10($1.str, nullptr, &error); }
        | dec_num_error { MYSQL_YYABORT; }
        ;

ulonglong_num:
          NUM           { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | ULONGLONG_NUM { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | LONG_NUM      { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | DECIMAL_NUM   { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | FLOAT_NUM     { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        ;

real_ulonglong_num:
          NUM           { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | HEX_NUM       { $$= (ulonglong) my_strtoll($1.str, (char**) 0, 16); }
        | ULONGLONG_NUM { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | LONG_NUM      { int error; $$= (ulonglong) my_strtoll10($1.str, nullptr, &error); }
        | dec_num_error { MYSQL_YYABORT; }
        ;

dec_num_error:
          dec_num
          { YYTHD->syntax_error(ER_ONLY_INTEGERS_ALLOWED); }
        ;

dec_num:
          DECIMAL_NUM
        | FLOAT_NUM
        ;

select_var_list:
          select_var_list ',' select_var_ident
          {
            $$= $1;
            if ($$ == NULL || $$->push_back($3))
              MYSQL_YYABORT;
          }
        | select_var_ident
          {
            $$= NEW_PTN PT_select_var_list(@$);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        ;

select_var_ident:
          '@' ident_or_text
          {
            $$= NEW_PTN PT_select_var($2);
          }
        | ident_or_text
          {
            $$= NEW_PTN PT_select_sp_var($1);
          }
        ;

into_clause:
          INTO into_destination
          {
            $$= $2;
          }
%ifdef SQL_MODE_ORACLE
        | BULK_COLLECT_SYM INTO select_var_list
          {
            if ($3->value.size() != 1)
            {
              my_error(ER_WRONG_PARAMCOUNT_TO_BULK, MYF(0));
              MYSQL_YYABORT;
            }
            $$= $3;
            $$->is_bulk_into= true;
          }
%endif
        ;

into_destination:
          OUTFILE TEXT_STRING_filesystem
          opt_load_data_charset
          opt_field_term opt_line_term
          {
            $$= NEW_PTN PT_into_destination_outfile(@$, $2, $3, $4, $5);
          }
        | DUMPFILE TEXT_STRING_filesystem
          {
            $$= NEW_PTN PT_into_destination_dumpfile(@$, $2);
          }
        | select_var_list { $$= $1; }
        ;

/*
  DO statement
*/

do_stmt:
          DO_SYM select_item_list
          {
            $$= NEW_PTN PT_select_stmt(SQLCOM_DO,
                  NEW_PTN PT_query_expression(
                    NEW_PTN PT_query_specification({}, $2)));
          }
        ;

drop_synonym_stmt:
          DROP opt_public SYNONYM_SYM table_ident
          {
            $$= NEW_PTN PT_drop_synonym_stmt($4 /* synonym_ident */,
                                             $2 /* is_public */);
          }
        ;

/*
  Drop : delete tables or index or user or role
*/

drop_table_stmt:
          DROP opt_temporary table_or_tables if_exists table_list opt_restrict
          {
            // Note: opt_restrict ($6) is ignored!
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_DROP_TABLE;
            lex->drop_temporary= $2;
            lex->drop_if_exists= $4;
            YYPS->m_lock_type= TL_UNLOCK;
            YYPS->m_mdl_type= MDL_EXCLUSIVE;
            if (Select->add_tables(YYTHD, $5, TL_OPTION_UPDATING,
                                   YYPS->m_lock_type, YYPS->m_mdl_type))
              MYSQL_YYABORT;
          }
%ifdef SQL_MODE_ORACLE
        | DROP global_private_temporary table_or_tables if_exists table_list opt_restrict
          {
            // Note: opt_restrict ($6) is ignored!
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_DROP_TABLE;
            // for global temporary table, instance/meta will be dropped.
            lex->drop_temporary= !$2;
            lex->drop_if_exists= $4;
            YYPS->m_lock_type= TL_UNLOCK;
            YYPS->m_mdl_type= MDL_EXCLUSIVE;
            if (Select->add_tables(YYTHD, $5, TL_OPTION_UPDATING,
                                   YYPS->m_lock_type, YYPS->m_mdl_type))
              MYSQL_YYABORT;
          }
        | DROP MATERIALIZED_SYM VIEW_SYM if_exists table_list opt_restrict
          {
            // Note: opt_restrict ($6) is ignored!
            LEX *lex=Lex;
            lex->set_is_materialized_view(true);
            lex->sql_command = SQLCOM_DROP_TABLE;
            lex->drop_temporary= false;
            lex->drop_if_exists= $4;
            YYPS->m_lock_type= TL_UNLOCK;
            YYPS->m_mdl_type= MDL_EXCLUSIVE;
            if (Select->add_tables(YYTHD, $5, TL_OPTION_UPDATING,
                                   YYPS->m_lock_type, YYPS->m_mdl_type))
              MYSQL_YYABORT;
          }
%endif
        ;

drop_sequence_stmt:
          DROP SEQUENCE_SYM if_exists table_ident
          {
            LEX *lex=Lex;
            lex->drop_if_exists= $3;
            $$ = NEW_PTN PT_drop_sequence_stmt($4);
          }
        ;

drop_index_stmt:
          DROP INDEX_SYM ident ON_SYM table_ident opt_index_lock_and_algorithm
          {
            $$= NEW_PTN PT_drop_index_stmt(YYMEM_ROOT, $3.str, $5,
                                           $6.algo.get_or_default(),
                                           $6.lock.get_or_default());
          }
        ;

drop_database_stmt:
          DROP DATABASE if_exists ident
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_DROP_DB;
            lex->drop_if_exists=$3;
            lex->name= $4;
          }
        ;

drop_function_stmt:
          DROP FUNCTION_SYM if_exists ident '.' ident
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_name *spname;
            if ($4.str &&
                (check_and_convert_db_name(&$4, false) != Ident_name_check::OK))
               MYSQL_YYABORT;
            if (sp_check_name(&$6))
               MYSQL_YYABORT;
            if (lex->sphead)
            {
              my_error(ER_SP_NO_DROP_SP, MYF(0), "FUNCTION");
              MYSQL_YYABORT;
            }
            lex->sql_command = SQLCOM_DROP_FUNCTION;
            lex->drop_if_exists= $3;
            spname= new (YYMEM_ROOT) sp_name(to_lex_cstring($4), $6, true);
            if (spname == NULL)
              MYSQL_YYABORT;
            spname->init_qname(thd);
            lex->spname= spname;
          }
        | DROP FUNCTION_SYM if_exists ident
          {
            /*
              Unlike DROP PROCEDURE, "DROP FUNCTION ident" should work
              even if there is no current database. In this case it
              applies only to UDF.
              Hence we can't merge rules for "DROP FUNCTION ident.ident"
              and "DROP FUNCTION ident" into one "DROP FUNCTION sp_name"
              rule. sp_name assumes that database name should be always
              provided - either explicitly or implicitly.
            */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            LEX_STRING db= NULL_STR;
            sp_name *spname;
            if (lex->sphead)
            {
              my_error(ER_SP_NO_DROP_SP, MYF(0), "FUNCTION");
              MYSQL_YYABORT;
            }
            if (thd->db().str && lex->copy_db_to(&db.str, &db.length))
              MYSQL_YYABORT;
            if (sp_check_name(&$4))
               MYSQL_YYABORT;
            lex->sql_command = SQLCOM_DROP_FUNCTION;
            lex->drop_if_exists= $3;
            spname= new (YYMEM_ROOT) sp_name(to_lex_cstring(db), $4, false);
            if (spname == NULL)
              MYSQL_YYABORT;
            spname->init_qname(thd);
            lex->spname= spname;
          }
        ;

drop_resource_group_stmt:
          DROP RESOURCE_SYM GROUP_SYM ident opt_force
          {
            $$= NEW_PTN PT_drop_resource_group(to_lex_cstring($4), $5);
          }
         ;

drop_procedure_stmt:
          DROP PROCEDURE_SYM if_exists sp_name
          {
            LEX *lex=Lex;
            if (lex->sphead)
            {
              my_error(ER_SP_NO_DROP_SP, MYF(0), "PROCEDURE");
              MYSQL_YYABORT;
            }
            lex->sql_command = SQLCOM_DROP_PROCEDURE;
            lex->drop_if_exists= $3;
            lex->spname= $4;
          }
        ;

%ifdef SQL_MODE_ORACLE
drop_type_stmt:
          DROP TYPE_SYM if_exists sp_name
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_DROP_TYPE;
            if (lex->sphead)
            {
              my_error(ER_SP_NO_DROP_SP, MYF(0), "TYPE");
              MYSQL_YYABORT;
            }
            lex->drop_if_exists= $3;
            lex->spname= $4;
          }
        ;

%endif

drop_user_stmt:
          DROP USER if_exists user_list
          {
             LEX *lex=Lex;
             lex->sql_command= SQLCOM_DROP_USER;
             lex->drop_if_exists= $3;
             lex->users_list= *$4;
          }
        ;

drop_view_stmt:
          DROP VIEW_SYM if_exists table_list opt_restrict
          {
            // Note: opt_restrict ($5) is ignored!
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_DROP_VIEW;
            lex->drop_if_exists= $3;
            YYPS->m_lock_type= TL_UNLOCK;
            YYPS->m_mdl_type= MDL_EXCLUSIVE;
            if (Select->add_tables(YYTHD, $4, TL_OPTION_UPDATING,
                                   YYPS->m_lock_type, YYPS->m_mdl_type))
              MYSQL_YYABORT;
          }
        ;

drop_event_stmt:
          DROP EVENT_SYM if_exists sp_name
          {
            Lex->drop_if_exists= $3;
            Lex->spname= $4;
            Lex->sql_command = SQLCOM_DROP_EVENT;
          }
        ;

drop_trigger_stmt:
          DROP TRIGGER_SYM if_exists sp_name
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_DROP_TRIGGER;
            lex->drop_if_exists= $3;
            lex->spname= $4;
            Lex->m_sql_cmd= new (YYTHD->mem_root) Sql_cmd_drop_trigger();
          }
        ;

drop_tablespace_stmt:
          DROP TABLESPACE_SYM ident opt_drop_ts_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($4 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $4))
                MYSQL_YYABORT; /* purecov: inspected */
            }

            auto cmd= NEW_PTN Sql_cmd_drop_tablespace{$3, pc};
            if (!cmd)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
            Lex->m_sql_cmd= cmd;
            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }

drop_undo_tablespace_stmt:
          DROP UNDO_SYM TABLESPACE_SYM ident opt_undo_tablespace_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; // OOM

            if ($5 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $5))
                MYSQL_YYABORT;
            }

            auto cmd= NEW_PTN Sql_cmd_drop_undo_tablespace{
              DROP_UNDO_TABLESPACE, $4, {nullptr, 0},  pc};
            if (!cmd)
              MYSQL_YYABORT; // OOM
            Lex->m_sql_cmd= cmd;
            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }
        ;

drop_logfile_stmt:
          DROP LOGFILE_SYM GROUP_SYM ident opt_drop_ts_options
          {
            auto pc= NEW_PTN Alter_tablespace_parse_context{YYTHD};
            if (pc == NULL)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM

            if ($5 != NULL)
            {
              if (YYTHD->is_error() || contextualize_array(pc, $5))
                MYSQL_YYABORT; /* purecov: inspected */
            }

            auto cmd= NEW_PTN Sql_cmd_logfile_group{DROP_LOGFILE_GROUP,
                                                    $4, pc};
            if (!cmd)
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
            Lex->m_sql_cmd= cmd;
            Lex->sql_command= SQLCOM_ALTER_TABLESPACE;
          }

        ;

drop_server_stmt:
          DROP SERVER_SYM if_exists ident_or_text
          {
            Lex->sql_command = SQLCOM_DROP_SERVER;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_drop_server($4, $3);
          }
        | DROP COMPRESSION_DICTIONARY_SYM if_exists ident
          {
            Lex->sql_command= SQLCOM_DROP_COMPRESSION_DICTIONARY;
            Lex->drop_if_exists= $3;
            Lex->ident= $4;
          }
        ;

drop_srs_stmt:
          DROP SPATIAL_SYM REFERENCE_SYM SYSTEM_SYM if_exists real_ulonglong_num
          {
            $$= NEW_PTN PT_drop_srs($6, $5);
          }
        ;

drop_role_stmt:
          DROP ROLE_SYM if_exists role_list
          {
            $$= NEW_PTN PT_drop_role($3, $4);
          }
        ;

table_list:
          table_ident
          {
            $$= NEW_PTN Mem_root_array<Table_ident *>(YYMEM_ROOT);
            if ($$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | table_list ',' table_ident
          {
            $$= $1;
            if ($$ == NULL || $$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

table_alias_ref_list:
          table_ident_opt_wild
          {
            $$.init(YYMEM_ROOT);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | table_alias_ref_list ',' table_ident_opt_wild
          {
            $$= $1;
            if ($$.push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

if_exists:
          /* empty */ { $$= 0; }
        | IF EXISTS { $$= 1; }
        ;

opt_ignore_unknown_user:
          /* empty */ { $$= 0; }
        | IGNORE_SYM UNKNOWN_SYM USER { $$= 1; }
        ;

opt_temporary:
          /* empty */ { $$= false; }
        | TEMPORARY   { $$= true; }
        ;

opt_drop_ts_options:
        /* empty*/ { $$= NULL; }
      | drop_ts_option_list
      ;

drop_ts_option_list:
          drop_ts_option
          {
            $$= NEW_PTN Mem_root_array<PT_alter_tablespace_option_base*>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        | drop_ts_option_list opt_comma drop_ts_option
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; /* purecov: inspected */ // OOM
          }
        ;

drop_ts_option:
          ts_option_engine
        | ts_option_wait
        ;
/*
** Insert : add new data to table
*/

insert_stmt:
          INSERT_SYM                   /* #1 */
          insert_lock_option           /* #2 */
          opt_ignore                   /* #3 */
          opt_INTO                     /* #4 */
          table_ident                  /* #5 */
          opt_use_partition            /* #6 */
          insert_from_constructor      /* #7 */
          opt_values_reference         /* #8 */
          opt_insert_update_list       /* #9 */
          {
            DBUG_EXECUTE_IF("bug29614521_simulate_oom",
                             DBUG_SET("+d,simulate_out_of_memory"););
            $$= NEW_PTN PT_insert(false, $1, $2, $3, $5, $6,
                                  $7.column_list, $7.row_value_list,
                                  NULL,
                                  $8.table_alias, $8.column_list,
                                  $9.column_list, $9.value_list);
            DBUG_EXECUTE_IF("bug29614521_simulate_oom",
                            DBUG_SET("-d,bug29614521_simulate_oom"););
          }
        | INSERT_SYM                   /* #1 */
          insert_lock_option           /* #2 */
          opt_ignore                   /* #3 */
          opt_INTO                     /* #4 */
          table_ident                  /* #5 */
          opt_use_partition            /* #6 */
          SET_SYM                      /* #7 */
          update_list                  /* #8 */
          opt_values_reference         /* #9 */
          opt_insert_update_list       /* #10 */
          {
            PT_insert_values_list *one_row= NEW_PTN PT_insert_values_list(YYMEM_ROOT);
            if (one_row == NULL || one_row->push_back(&$8.value_list->value))
              MYSQL_YYABORT; // OOM
            $$= NEW_PTN PT_insert(false, $1, $2, $3, $5, $6,
                                  $8.column_list, one_row,
                                  NULL,
                                  $9.table_alias, $9.column_list,
                                  $10.column_list, $10.value_list);
          }
        | INSERT_SYM                   /* #1 */
          insert_lock_option           /* #2 */
          opt_ignore                   /* #3 */
          opt_INTO                     /* #4 */
          table_ident                  /* #5 */
          opt_use_partition            /* #6 */
          insert_query_expression      /* #7 */
          opt_insert_update_list       /* #8 */
          {
            $$= NEW_PTN PT_insert(false, $1, $2, $3, $5, $6,
                                  $7.column_list, NULL,
                                  $7.insert_query_expression,
                                  NULL_CSTR, NULL,
                                  $8.column_list, $8.value_list);
          }
%ifdef SQL_MODE_ORACLE
        | INSERT_SYM                   /* #1 */
          insert_lock_option           /* #2 */
          opt_ignore                   /* #3 */
          opt_INTO                     /* #4 */
          table_ident                  /* #5 */
          opt_use_partition            /* #6 */
          VALUES                       /* #7 */
          insert_record_query_expression/* #8 */
          {
            $$= NEW_PTN PT_insert(false, $1, $2, $3, $5, $6,
                                  $8.column_list, NULL,
                                  $8.insert_query_expression,
                                  NULL_CSTR, NULL,
                                  nullptr, nullptr,true);
          }
%endif
        ;

replace_stmt:
          REPLACE_SYM                   /* #1 */
          replace_lock_option           /* #2 */
          opt_INTO                      /* #3 */
          table_ident                   /* #4 */
          opt_use_partition             /* #5 */
          insert_from_constructor       /* #6 */
          {
            $$= NEW_PTN PT_insert(true, $1, $2, false, $4, $5,
                                  $6.column_list, $6.row_value_list,
                                  NULL,
                                  NULL_CSTR, NULL,
                                  NULL, NULL);
          }
        | REPLACE_SYM                   /* #1 */
          replace_lock_option           /* #2 */
          opt_INTO                      /* #3 */
          table_ident                   /* #4 */
          opt_use_partition             /* #5 */
          SET_SYM                       /* #6 */
          update_list                   /* #7 */
          {
            PT_insert_values_list *one_row= NEW_PTN PT_insert_values_list(YYMEM_ROOT);
            if (one_row == NULL || one_row->push_back(&$7.value_list->value))
              MYSQL_YYABORT; // OOM
            $$= NEW_PTN PT_insert(true, $1, $2, false, $4, $5,
                                  $7.column_list, one_row,
                                  NULL,
                                  NULL_CSTR, NULL,
                                  NULL, NULL);
          }
        | REPLACE_SYM                   /* #1 */
          replace_lock_option           /* #2 */
          opt_INTO                      /* #3 */
          table_ident                   /* #4 */
          opt_use_partition             /* #5 */
          insert_query_expression       /* #6 */
          {
            $$= NEW_PTN PT_insert(true, $1, $2, false, $4, $5,
                                  $6.column_list, NULL,
                                  $6.insert_query_expression,
                                  NULL_CSTR, NULL,
                                  NULL, NULL);
          }
        ;

insert_all_stmt:
          INSERT_SYM                   /* #1 */
          insert_lock_option           /* #2 */
          ALL                          /* #3 */
          insert_all_into_list         /* #4 */
          query_expression             /* #5 */
          {
            $$= NEW_PTN PT_insert_all($1, $2, $4.insert_list, $5, false,
                                      $4.clause_type == INSERT_INTO_UNCONDITION);
          }
%ifdef SQL_MODE_ORACLE
        | INSERT_SYM                   /* #1 */
          insert_lock_option           /* #2 */
          FIRST_SYM                    /* #3 */
          insert_all_into_list         /* #4 */
          query_expression             /* #5 */
          {
            if ($4.clause_type == INSERT_INTO_UNCONDITION) {
              my_error(ER_INSERT_FIRST_WITHOUT_WHEN, MYF(0));
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PT_insert_all($1, $2, $4.insert_list, $5, true, false);
          }
%endif
        ;

insert_all_into_list:
          insert_all_into_list cond_insert_all_into
          {
            if ($1.clause_type == INSERT_INTO_UNCONDITION) {
              // if the previous one is unconditional clause,
              // all following clauses should be unconditional.
              if ($2->clause_type != INSERT_INTO_UNCONDITION) {
                my_error(ER_INSERT_ALL_WHEN_ELSE_NOT_ALLOW, MYF(0));
                MYSQL_YYABORT;
              }
            } else if ($1.clause_type == INSERT_INTO_WHEN) {
              // if the previous one is WHEN clause,
              // only WHEN or ELSE clause is allowed.
              if ($2->clause_type == INSERT_INTO_UNCONDITION) {
                $2->clause_type = INSERT_INTO_WHEN;
              }
            } else if ($1.clause_type == INSERT_INTO_ELSE) {
              // if the previous one is ELSE clause,
              // no other clause should follow.
              if ($2->clause_type == INSERT_INTO_UNCONDITION) {
                $2->clause_type = INSERT_INTO_ELSE;
              } else {
                if ($2->clause_type == INSERT_INTO_ELSE)
                  my_error(ER_INSERT_ALL_ELSE_TWICE, MYF(0));
                else
                  my_error(ER_INSERT_ALL_WHEN_AFTER_ELSE_NOT_ALLOW, MYF(0));
                MYSQL_YYABORT;
              }
            }
            if ($1.insert_list == nullptr || $1.insert_list->push_back($2)) {
              MYSQL_YYABORT;
            }
            $$= $1;
            $$.clause_type = $2->clause_type;
          }
          | cond_insert_all_into
          {
              $$.insert_list=
                  NEW_PTN Mem_root_array<PT_insert_all_into *> (YYMEM_ROOT);
              if ($$.insert_list == nullptr || $$.insert_list->push_back($1)) {
                MYSQL_YYABORT;
              }
              $$.clause_type= $1->clause_type;
          }
        ;

cond_insert_all_into:
          insert_all_into
          {
            // unconditional insert-into-clause
            $$= $1;
            $$->clause_type = INSERT_INTO_UNCONDITION;
            $$->opt_when = nullptr;
          }
        | WHEN_SYM expr THEN_SYM insert_all_into
          {
            // WHEN insert-into-clause
            $$= $4;
            $$->clause_type = INSERT_INTO_WHEN;
            $$->opt_when = $2;
          }
        | ELSE insert_all_into
          {
            // ELSE insert-into-clause
            $$= $2;
            $$->clause_type = INSERT_INTO_ELSE;
            $$->opt_when = nullptr;
          }
        ;

insert_all_into:
          INTO
          table_ident
          opt_use_partition
          insert_all_into_column_value_pair
          {
            $$= NEW_PTN PT_insert_all_into($2, $3, $4.column_list,
                                           $4.value_list);
            if ($$ == nullptr) {
              MYSQL_YYABORT;
            }
          }
          ;

insert_all_into_column_value_pair:
        /* empty */ %prec EMPTY_INSALL_COLS
        {
          $$.column_list= NEW_PTN PT_item_list;
          Item *item = NEW_PTN Item_asterisk(@$, nullptr, nullptr);
          if (item == nullptr) {
            MYSQL_YYABORT;
          }
          $$.value_list=  NEW_PTN PT_item_list;
          if ($$.value_list == nullptr || $$.value_list->push_back(item)) {
            MYSQL_YYABORT;
          }
        }
        | '(' insert_columns ')'
        {
          $$.column_list= $2;
          Item *item = NEW_PTN Item_asterisk(@$, nullptr, nullptr);
          if (item == nullptr) {
            MYSQL_YYABORT;
          }
          $$.value_list= NEW_PTN PT_item_list;
          if ($$.value_list == nullptr || $$.value_list->push_back(item)) {
            MYSQL_YYABORT;
          }
        }
        | VALUES '(' into_all_values ')'
        {
          $$.column_list=  NEW_PTN PT_item_list;
          if ($$.column_list == nullptr) {
            MYSQL_YYABORT;
          }
          $$.value_list= $3;
        }
        | '(' insert_columns ')' VALUES '(' into_all_values ')'
        {
            $$.column_list= $2;
            $$.value_list= $6;
        }
        ;

into_all_values:
          into_all_values ',' select_item
          {
            if ($1== NULL || $1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
      | select_item
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        ;


insert_lock_option:
          /* empty */   { $$= TL_WRITE_CONCURRENT_DEFAULT; }
        | LOW_PRIORITY  { $$= TL_WRITE_LOW_PRIORITY; }
        | DELAYED_SYM
        {
          $$= TL_WRITE_CONCURRENT_DEFAULT;

          push_warning_printf(YYTHD, Sql_condition::SL_WARNING,
                              ER_WARN_LEGACY_SYNTAX_CONVERTED,
                              ER_THD(YYTHD, ER_WARN_LEGACY_SYNTAX_CONVERTED),
                              "INSERT DELAYED", "INSERT");
        }
        | HIGH_PRIORITY { $$= TL_WRITE; }
        ;

replace_lock_option:
          opt_low_priority { $$= $1; }
        | DELAYED_SYM
        {
          $$= TL_WRITE_DEFAULT;

          push_warning_printf(YYTHD, Sql_condition::SL_WARNING,
                              ER_WARN_LEGACY_SYNTAX_CONVERTED,
                              ER_THD(YYTHD, ER_WARN_LEGACY_SYNTAX_CONVERTED),
                              "REPLACE DELAYED", "REPLACE");
        }
        ;

opt_INTO:
          /* empty */
        | INTO
        ;

insert_from_constructor:
          insert_values
          {
            $$.column_list= NEW_PTN PT_item_list;
            $$.row_value_list= $1;
          }
        | '(' ')' insert_values
          {
            $$.column_list= NEW_PTN PT_item_list;
            $$.row_value_list= $3;
          }
        | '(' insert_columns ')' insert_values
          {
            $$.column_list= $2;
            $$.row_value_list= $4;
          }
        ;

insert_query_expression:
          query_expression_with_opt_locking_clauses
          {
            $$.column_list= NEW_PTN PT_item_list;
            $$.insert_query_expression= $1;
          }
        | '(' ')' query_expression_with_opt_locking_clauses
          {
            $$.column_list= NEW_PTN PT_item_list;
            if ($$.column_list == nullptr) {
              MYSQL_YYABORT;
            }
            $$.insert_query_expression= $3;
          }
        | '(' insert_columns ')' query_expression_with_opt_locking_clauses
          {
            $$.column_list= $2;
            $$.insert_query_expression= $4;
          }
        ;

%ifdef SQL_MODE_ORACLE
insert_record_query_expression:
          ident '('   /* #1 */
          ident ')'   /* #3 */
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            if (!sp || (sp->m_type != enum_sp_type::PROCEDURE &&
            sp->m_type != enum_sp_type::FUNCTION) || !pctx)
            {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            sp_variable *spvar= pctx->find_variable($3.str, $3.length, true);
            if (!spvar)
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $3.str);
              MYSQL_YYABORT;
            }
            if(!spvar->field_def.ora_record.is_forall_loop_var)
            {
              my_error(ER_WRONG_PARAMCOUNT_TO_TYPE_TABLE, MYF(0), $3.str);
              MYSQL_YYABORT;
            }
            sp_variable *spvar_table= pctx->find_variable($1.str, $1.length, false);
            if(!spvar_table || !spvar_table->field_def.ora_record.row_field_table_definitions() ||
            spvar_table->field_def.ora_record.is_record_table_define)
            {
              my_error(ER_SP_MISMATCH_RECORD_VAR, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            if(spvar_table->field_def.ora_record.index_length > 0) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "forall SQL with associative arrays with VARCHAR2 key");
              MYSQL_YYABORT;
            }
            $$.column_list= NEW_PTN PT_item_list;
            Query_options option;
            option.query_spec_options= 0;
            PT_select_item_list *itemLs= NEW_PTN PT_select_item_list;
            // select * from table;
            Item_asterisk *as = NEW_PTN Item_asterisk(@$, nullptr, nullptr);
            itemLs->push_back(as);
            Mem_root_array_YY<PT_table_reference *> table_reference_list;
            table_reference_list.init(YYMEM_ROOT);
            PT_table_record_function *record= NEW_PTN PT_table_record_function($1, $3);
            if (table_reference_list.push_back(record))
              MYSQL_YYABORT; // OOM
            $$.insert_query_expression= NEW_PTN PT_query_specification(
                                      option,  // select_options
                                      itemLs,  // select_item_list
                                      table_reference_list,  // from
                                      nullptr
                                      );
          }
        ;
%endif

insert_columns:
          insert_columns ',' insert_column
          {
            if ($$->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        | insert_column
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        ;

insert_values:
          value_or_values values_list
          {
            $$= $2;
          }
        ;

query_expression_with_opt_locking_clauses:
          query_expression                      { $$ = $1; }
        | query_expression locking_clause_list
          {
            $$ = NEW_PTN PT_locking($1, $2);
          }
        ;

value_or_values:
          VALUE_SYM
        | VALUES
        ;

values_list:
          values_list ','  row_value
          {
            if ($$->push_back(&$3->value))
              MYSQL_YYABORT;
          }
        | row_value
          {
            $$= NEW_PTN PT_insert_values_list(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back(&$1->value))
              MYSQL_YYABORT;
          }
        ;


values_row_list:
          values_row_list ',' row_value_explicit
          {
            if ($$->push_back(&$3->value))
              MYSQL_YYABORT;
          }
        | row_value_explicit
          {
            $$= NEW_PTN PT_insert_values_list(YYMEM_ROOT);
            if ($$ == nullptr || $$->push_back(&$1->value))
              MYSQL_YYABORT;
          }
        ;

equal:
          EQ
        | SET_VAR
        ;

opt_equal:
          /* empty */
        | equal
        ;

row_value:
          '(' opt_values ')' { $$= $2; }
        ;

row_value_explicit:
          ROW_SYM '(' opt_values ')' { $$= $3; }
        ;

opt_values:
          /* empty */
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | values
        ;

values:
          values ','  expr_or_default
          {
            if ($1->push_back($3))
              MYSQL_YYABORT;
            $$= $1;
          }
        | expr_or_default
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        ;

expr_or_default:
          expr
        | DEFAULT_SYM
          {
            $$= NEW_PTN Item_default_value(@$);
          }
        ;

opt_values_reference:
          /* empty */
          {
            $$.table_alias = NULL_CSTR;
            $$.column_list = NULL;
          }
        | AS ident opt_derived_column_list
          {
            $$.table_alias = to_lex_cstring($2);
            /* The column list object is short-lived, requiring duplication. */
            void *column_list_raw_mem= YYTHD->memdup(&($3), sizeof($3));
            if (!column_list_raw_mem)
              MYSQL_YYABORT; // OOM
            $$.column_list =
              static_cast<Create_col_name_list *>(column_list_raw_mem);
          }
        ;

opt_insert_update_list:
          /* empty */
          {
            $$.value_list= NULL;
            $$.column_list= NULL;
          }
        | ON_SYM DUPLICATE_SYM KEY_SYM UPDATE_SYM update_list
          {
            $$= $5;
          }
        ;

/* Update rows in a table */

update_stmt:
          opt_with_clause
          UPDATE_SYM            /* #1 */
          opt_low_priority      /* #2 */
          opt_ignore            /* #3 */
          table_reference_list  /* #4 */
          SET_SYM               /* #5 */
%ifndef SQL_MODE_ORACLE
          update_list           /* #6 */
%else
          update_list_ora       /* #6 */
%endif
          opt_where_clause      /* #7 */
          opt_order_clause      /* #8 */
          opt_simple_limit      /* #9 */
          {
            $$= NEW_PTN PT_update($1, $2, $3, $4, $5, $7.column_list, $7.value_list,
                                  $8, $9, $10);
          }
        ;

merge_stmt:
          opt_with_clause       // #1
          MERGE_INTO_SYM        // #2
          single_table          // #3
          USING                 // #4
          table_reference       // #5
          ON_SYM                // #6
          '('                   // #7
          expr                  // #8
          ')'                   // #9
          merge_when_list       // #10
          {
            // both update and insert don't exist, throw syntax error.
            if (!$10->update_column_list && !$10->update_value_list &&
                !$10->insert_row_value_list) {
              // missing when-clause.
              YYTHD->syntax_error_at(@10);
              MYSQL_YYABORT;
            }

            // if merge_when_update is missing, set to empty list.
            if (!$10->update_column_list)
              $10->update_column_list= NEW_PTN PT_item_list;
            if (!$10->update_value_list)
              $10->update_value_list= NEW_PTN PT_item_list;

            // convert
            //   single_table USING table_reference ON '(' expr ')'
            // into
            //   single_table RIGHT OUTER JOIN table_reference ON '(' expr ')'
            // and use it as table_reference_list
            PT_joined_table *jt;
            jt= NEW_PTN PT_joined_table_on($3, @6, JTT_RIGHT, $5, $8);

            Mem_root_array_YY<PT_table_reference *> trl;
            trl.init(YYMEM_ROOT);
            if (trl.push_back(jt))
              MYSQL_YYABORT;

            PT_update *upd;
            upd= NEW_PTN PT_update($1, $2, TL_WRITE_DEFAULT, false, trl,
                                  $10->update_column_list, $10->update_value_list,
                                  nullptr, nullptr, nullptr);

            upd->set_merge_params($10->insert_column_list,
                                  $10->insert_row_value_list,
                                  $10->update_where, $10->insert_where,
                                  $10->update_delete);
            $$= upd;
          }
        ;

merge_when_list:
          merge_when_update
          {
            $$= $1;
          }
        | merge_when_insert
          {
            $$= $1;
          }
        | merge_when_list merge_when_update
          {
            if ($1->update_column_list || $1->update_value_list) {
              // merge_when_update twice
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            $1->update_column_list= $2->update_column_list;
            $1->update_value_list= $2->update_value_list;
            $1->update_where= $2->update_where;
            $1->update_delete= $2->update_delete;
            $$= $1;
          }
        | merge_when_list merge_when_insert
          {
            if ($1->insert_row_value_list) {
              // merge_when_update twice
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            $1->insert_column_list= $2->insert_column_list;
            $1->insert_row_value_list= $2->insert_row_value_list;
            $1->insert_where= $2->insert_where;
            $$= $1;
          }
        ;

merge_when_update:
          WHEN_SYM MATCHED_SYM THEN_SYM
          UPDATE_SYM            // #4
          SET_SYM               // #5
          update_list           // #6
          opt_merge_where       // #7
          opt_merge_delete      // #8
          {
            $$= NEW_PTN PT_merge_when_list($6.column_list, $6.value_list, $7,
                                           $8);
          }
        ;

opt_merge_where:
          /* empty */   { $$= nullptr; }
        | WHERE expr    { $$= $2; }
        ;

opt_merge_delete:
          /* empty */              { $$= nullptr; }
        | DELETE_SYM WHERE expr    { $$= $3; }
        ;

merge_when_insert:
          WHEN_SYM NOT_SYM MATCHED_SYM THEN_SYM
          INSERT_SYM            // #5
          value_or_values       // #6
          row_value             // #7
          opt_merge_where       // #8
          {
            // why not use insert_values ?
            // only one row_value is supported in 'merge-into' syntax
            PT_insert_values_list *values_list;
            values_list= NEW_PTN PT_insert_values_list(YYMEM_ROOT);
            if (values_list == NULL || values_list->push_back(&$7->value))
              MYSQL_YYABORT;
            $$= NEW_PTN PT_merge_when_list(NEW_PTN PT_item_list, values_list,
                                           $8);
          }
        | WHEN_SYM NOT_SYM MATCHED_SYM THEN_SYM
          INSERT_SYM            // #5
          '(' insert_columns ')'        // . #7 .
          value_or_values       // #9
          row_value             // #10
          opt_merge_where       // #11
          {
            // why not use insert_values ?
            // only one row_value is supported in 'merge-into' syntax
            PT_insert_values_list *values_list;
            values_list= NEW_PTN PT_insert_values_list(YYMEM_ROOT);
            if (values_list == NULL || values_list->push_back(&$10->value))
              MYSQL_YYABORT;

            $$= NEW_PTN PT_merge_when_list($7, values_list, $11);
          }
        ;

opt_with_clause:
          /* empty */ { $$= NULL; }
        | with_clause { $$= $1; }
        ;

update_list:
          update_list ',' update_elem
          {
            $$= $1;
            if ($$.column_list->push_back($3.column) ||
                $$.value_list->push_back($3.value))
              MYSQL_YYABORT; // OOM
          }
        | update_elem
          {
            $$.column_list= NEW_PTN PT_item_list;
            $$.value_list= NEW_PTN PT_item_list;
            if ($$.column_list == NULL || $$.value_list == NULL ||
                $$.column_list->push_back($1.column) ||
                $$.value_list->push_back($1.value))
              MYSQL_YYABORT; // OOM
          }
        ;

%ifdef SQL_MODE_ORACLE
update_list_ora:
          update_list { $$= $1; }
        | opt_field_or_var_spec equal expr_or_default
          {
            if(!$1){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                        "update set with empty variable.");
              MYSQL_YYABORT;
            }
            if($3->type() == Item::DEFAULT_VALUE_ITEM){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                        "update set with DEFAULT variable.");
              MYSQL_YYABORT;
            }
            $$.value_list= NEW_PTN PT_item_list;
            $$.column_list= $1;
            Item_row *row= dynamic_cast<Item_row *>($3);
            if(row){
              for (uint i = 0; i < row->cols(); i++) {
                if($$.value_list->push_back(row->element_index(i)))
                  MYSQL_YYABORT;
              }
            } else {
              $$.value_list->push_back($3);
            }
          }
%endif
        ;

update_elem:
          simple_ident_nospvar equal expr_or_default
          {
            $$.column= $1;
            $$.value= $3;
          }
        ;

opt_low_priority:
          /* empty */ { $$= TL_WRITE_DEFAULT; }
        | LOW_PRIORITY { $$= TL_WRITE_LOW_PRIORITY; }
        ;

/* Delete rows from a table */

delete_stmt:
          opt_with_clause
          DELETE_SYM
          opt_delete_options
          FROM
          table_ident
          opt_table_alias
          opt_use_partition
          opt_where_clause
          opt_order_clause
          opt_simple_limit
          {
            $$= NEW_PTN PT_delete($1, $2, $3, $5, $6, $7, $8, $9, $10);
          }
        | opt_with_clause
          DELETE_SYM
          opt_delete_options
          table_alias_ref_list
          FROM
          table_reference_list
          opt_where_clause
          {
            $$= NEW_PTN PT_delete($1, $2, $3, $4, $6, $7);
          }
        | opt_with_clause
          DELETE_SYM
          opt_delete_options
          FROM
          table_alias_ref_list
          USING
          table_reference_list
          opt_where_clause
          {
            $$= NEW_PTN PT_delete($1, $2, $3, $5, $7, $8);
          }
%ifdef SQL_MODE_ORACLE
        | opt_with_clause
          DELETE_SYM
          opt_delete_options
          table_ident
          opt_table_alias
          opt_use_partition
          opt_where_clause
          opt_order_clause
          opt_simple_limit
          {
            $$= NEW_PTN PT_delete($1, $2, $3, $4, $5, $6, $7, $8, $9);
          }
%endif
        ;

opt_wild:
          /* empty */
        | '.' '*'
        ;

opt_delete_options:
          /* empty */                          { $$= 0; }
        | opt_delete_option opt_delete_options { $$= $1 | $2; }
        ;

opt_delete_option:
          QUICK        { $$= DELETE_QUICK; }
        | LOW_PRIORITY { $$= DELETE_LOW_PRIORITY; }
        | IGNORE_SYM   { $$= DELETE_IGNORE; }
        ;

truncate_stmt:
          TRUNCATE_SYM opt_table table_ident
          {
            $$= NEW_PTN PT_truncate_table_stmt($3);
          }
        ;

opt_table:
          /* empty */
        | TABLE_SYM
        ;

opt_profile_defs:
          /* empty */   { $$ = 0; }
        | profile_defs
        ;

profile_defs:
          profile_def
        | profile_defs ',' profile_def  { $$ = $1 | $3; }
        ;

profile_def:
          CPU_SYM                   { $$ = PROFILE_CPU; }
        | MEMORY_SYM                { $$ = PROFILE_MEMORY; }
        | BLOCK_SYM IO_SYM          { $$ = PROFILE_BLOCK_IO; }
        | CONTEXT_SYM SWITCHES_SYM  { $$ = PROFILE_CONTEXT; }
        | PAGE_SYM FAULTS_SYM       { $$ = PROFILE_PAGE_FAULTS; }
        | IPC_SYM                   { $$ = PROFILE_IPC; }
        | SWAPS_SYM                 { $$ = PROFILE_SWAPS; }
        | SOURCE_SYM                { $$ = PROFILE_SOURCE; }
        | ALL                       { $$ = PROFILE_ALL; }
        ;

opt_for_query:
          /* empty */   { $$ = 0; }
        | FOR_SYM QUERY_SYM NUM
          {
            int error;
            $$ = static_cast<my_thread_id>(my_strtoll10($3.str, NULL, &error));
            if (error != 0)
              MYSQL_YYABORT;
          }
        ;

/* SHOW statements */

show_databases_stmt:
           SHOW DATABASES opt_wild_or_where
           {
             $$ = NEW_PTN PT_show_databases(@$, $3.wild, $3.where);
           }

show_sequences_stmt:
          SHOW opt_show_cmd_type SEQUENCES opt_db opt_wild_or_where
          {
            auto *p= NEW_PTN PT_show_sequences(@$, $2, $4, $5.wild, $5.where);
            MAKE_CMD(p);
          }
        ;

show_synonyms_stmt:
          SHOW SYNONYMS_SYM
          {
            auto *p= NEW_PTN PT_show_synonyms(@$);
            MAKE_CMD(p);
          }
        ;

show_tables_stmt:
          SHOW opt_show_cmd_type TABLES opt_db opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_tables(@$, $2, $4, $5.wild, $5.where);
          }
        ;

show_triggers_stmt:
          SHOW opt_full TRIGGERS_SYM opt_db opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_triggers(@$, $2, $4, $5.wild, $5.where);
          }
        ;

show_events_stmt:
          SHOW EVENTS_SYM opt_db opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_events(@$, $3, $4.wild, $4.where);
          }
        ;

show_table_status_stmt:
          SHOW TABLE_SYM STATUS_SYM opt_db opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_table_status(@$, $4, $5.wild, $5.where);
          }
        ;

show_open_tables_stmt:
          SHOW OPEN_SYM TABLES opt_db opt_wild_or_where
          {
             $$ = NEW_PTN PT_show_open_tables(@$, $4, $5.wild, $5.where);
          }
        ;

show_plugins_stmt:
          SHOW PLUGINS_SYM
          {
            $$ = NEW_PTN PT_show_plugins(@$);
          }
        ;

show_engine_logs_stmt:
          SHOW ENGINE_SYM engine_or_all LOGS_SYM
          {
            $$ = NEW_PTN PT_show_engine_logs(@$, $3);
          }
        ;

show_engine_mutex_stmt:
          SHOW ENGINE_SYM engine_or_all MUTEX_SYM
          {
            $$ = NEW_PTN PT_show_engine_mutex(@$, $3);
          }
        ;

show_engine_status_stmt:
          SHOW ENGINE_SYM engine_or_all STATUS_SYM
          {
            $$ = NEW_PTN PT_show_engine_status(@$, $3);
          }
        ;

show_columns_stmt:
          SHOW                  /* 1 */
          opt_show_cmd_type     /* 2 */
          COLUMNS               /* 3 */
          from_or_in            /* 4 */
          table_ident           /* 5 */
          opt_db                /* 6 */
          opt_wild_or_where     /* 7 */
          {
            // TODO: error if table_ident is <db>.<table> and opt_db is set.
            if ($6)
              $5->change_db($6);

            $$ = NEW_PTN PT_show_fields(@$, $2, $5, $7.wild, $7.where);
          }
        ;

show_binary_logs_stmt:
          SHOW master_or_binary LOGS_SYM
          {
            $$ = NEW_PTN PT_show_binlogs(@$);
          }
        ;

show_replicas_stmt:
          SHOW SLAVE HOSTS_SYM
          {
            Lex->set_replication_deprecated_syntax_used();
            push_deprecated_warn(YYTHD, "SHOW SLAVE HOSTS", "SHOW REPLICAS");

            $$ = NEW_PTN PT_show_replicas(@$);
          }
        | SHOW REPLICAS_SYM
          {
            $$ = NEW_PTN PT_show_replicas(@$);
          }
        ;

show_binlog_events_stmt:
          SHOW BINLOG_SYM EVENTS_SYM opt_binlog_in binlog_from opt_limit_clause
          {
            $$ = NEW_PTN PT_show_binlog_events(@$, $4, $6);
          }
        ;

show_relaylog_events_stmt:
          SHOW RELAYLOG_SYM EVENTS_SYM opt_binlog_in binlog_from opt_limit_clause
          opt_channel
          {
            $$ = NEW_PTN PT_show_relaylog_events(@$, $4, $6, $7);
          }
        ;

show_keys_stmt:
          SHOW                  /* #1 */
          opt_extended          /* #2 */
          keys_or_index         /* #3 */
          from_or_in            /* #4 */
          table_ident           /* #5 */
          opt_db                /* #6 */
          opt_where_clause      /* #7 */
          {
            // TODO: error if table_ident is <db>.<table> and opt_db is set.
            if ($6)
              $5->change_db($6);

            $$ = NEW_PTN PT_show_keys(@$, $2, $5, $7);
          }
        ;

show_engines_stmt:
          SHOW opt_storage ENGINES_SYM
          {
            $$ = NEW_PTN PT_show_engines(@$);
          }
        ;

show_count_warnings_stmt:
          SHOW COUNT_SYM '(' '*' ')' WARNINGS
          {
            $$ = NEW_PTN PT_show_count_warnings(@$);
          }
        ;

show_count_errors_stmt:
          SHOW COUNT_SYM '(' '*' ')' ERRORS
          {
            $$ = NEW_PTN PT_show_count_errors(@$);
          }
        ;

show_warnings_stmt:
          SHOW WARNINGS opt_limit_clause
          {
            $$ = NEW_PTN PT_show_warnings(@$, $3);
          }
        ;

show_errors_stmt:
          SHOW ERRORS opt_limit_clause
          {
            $$ = NEW_PTN PT_show_errors(@$, $3);
          }
        ;

show_profiles_stmt:
          SHOW PROFILES_SYM
          {
            push_warning_printf(YYTHD, Sql_condition::SL_WARNING,
                                ER_WARN_DEPRECATED_SYNTAX,
                                ER_THD(YYTHD, ER_WARN_DEPRECATED_SYNTAX),
                                "SHOW PROFILES", "Performance Schema");
            $$ = NEW_PTN PT_show_profiles(@$);
          }
        ;

show_profile_stmt:
          SHOW PROFILE_SYM opt_profile_defs opt_for_query opt_limit_clause
          {
            $$ = NEW_PTN PT_show_profile(@$, $3, $4, $5);
          }
        ;

show_status_stmt:
          SHOW opt_var_type STATUS_SYM opt_wild_or_where
          {
             $$ = NEW_PTN PT_show_status(@$, $2, $4.wild, $4.where);
          }
        ;

show_processlist_stmt:
          SHOW opt_full PROCESSLIST_SYM
          {
            $$ = NEW_PTN PT_show_processlist(@$, $2);
          }
        ;

show_variables_stmt:
          SHOW opt_var_type VARIABLES opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_variables(@$, $2, $4.wild, $4.where);
          }
        ;

show_character_set_stmt:
          SHOW character_set opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_charsets(@$, $3.wild, $3.where);
          }
        ;

show_collation_stmt:
          SHOW COLLATION_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_collations(@$, $3.wild, $3.where);
          }
        ;

show_privileges_stmt:
          SHOW PRIVILEGES
          {
            $$ = NEW_PTN PT_show_privileges(@$);
          }
        ;

show_grants_stmt:
          SHOW GRANTS
          {
            $$ = NEW_PTN PT_show_grants(@$, nullptr, nullptr, false);
          }
        | SHOW GRANTS FOR_SYM user
          {
            $$ = NEW_PTN PT_show_grants(@$, $4, nullptr, false);
          }
        | SHOW GRANTS FOR_SYM user USING user_list
          {
            $$ = NEW_PTN PT_show_grants(@$, $4, $6, false);
          }
        | SHOW EFFECTIVE_SYM GRANTS
          {
            $$ = NEW_PTN PT_show_grants(@$, nullptr, nullptr, true);
          }
        | SHOW EFFECTIVE_SYM GRANTS FOR_SYM user
          {
            $$ = NEW_PTN PT_show_grants(@$, $5, nullptr, true);
          }
        | SHOW EFFECTIVE_SYM GRANTS FOR_SYM user USING user_list
          {
            $$ = NEW_PTN PT_show_grants(@$, $5, $7, true);
          }
        ;

show_create_database_stmt:
          SHOW CREATE DATABASE opt_if_not_exists ident
          {
            $$ = NEW_PTN PT_show_create_database(@$, $4, $5);
          }
        ;

show_create_sequence_stmt:
          SHOW CREATE SEQUENCE_SYM table_ident
          {
            auto *tmp= NEW_PTN PT_show_create_sequence(@$, $4);
            MAKE_CMD(tmp);
          }
        ;

show_create_synonym_stmt:
          SHOW CREATE opt_public SYNONYM_SYM table_ident
          {
            auto *tmp= NEW_PTN PT_show_create_synonym(@$, $3, $5);
            MAKE_CMD(tmp);
          }
        ;

show_create_table_stmt:
          SHOW CREATE TABLE_SYM table_ident
          {
            $$ = NEW_PTN PT_show_create_table(@$, $4);
          }
%ifdef SQL_MODE_ORACLE
        | SHOW CREATE MATERIALIZED_SYM VIEW_SYM table_ident
          {
            LEX *lex=Lex;
            lex->set_is_materialized_view(true);
            $$ = NEW_PTN PT_show_create_table(@$, $5);
          }
%endif
        ;

show_create_view_stmt:
          SHOW CREATE VIEW_SYM table_ident
          {
            $$ = NEW_PTN PT_show_create_view(@$, $4);
          }
        |  SHOW CREATE VIEW_SYM ATTRIBUTE_SYM table_ident
          {
            $$ = NEW_PTN PT_show_create_view(@$, $5);
            Lex->create_force_view_mode = true;
          }
        ;

show_master_status_stmt:
          SHOW MASTER_SYM STATUS_SYM
          {
            $$ = NEW_PTN PT_show_master_status(@$);
          }
        ;

show_replica_status_stmt:
          SHOW replica STATUS_SYM opt_channel
          {
            if (Lex->is_replication_deprecated_syntax_used())
              push_deprecated_warn(YYTHD, "SHOW SLAVE STATUS", "SHOW REPLICA STATUS");
            $$ = NEW_PTN PT_show_replica_status(@$, $4);
          }
        ;
show_stats_stmt:
          SHOW CLIENT_STATS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_client_stats(@$, $3.wild, $3.where);
          }
        | SHOW USER_STATS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_user_stats(@$, $3.wild, $3.where);
          }
        | SHOW THREAD_STATS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_thread_stats(@$, $3.wild, $3.where);
          }
        | SHOW TABLE_STATS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_table_stats(@$, $3.wild, $3.where);
          }
        | SHOW INDEX_STATS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_index_stats(@$, $3.wild, $3.where);
          }
        ;

show_create_procedure_stmt:
          SHOW CREATE PROCEDURE_SYM sp_name
          {
            $$ = NEW_PTN PT_show_create_procedure(@$, $4);
          }
        ;

show_create_function_stmt:
          SHOW CREATE FUNCTION_SYM sp_name
          {
            $$ = NEW_PTN PT_show_create_function(@$, $4);
          }
        ;

%ifdef SQL_MODE_ORACLE
show_create_type_stmt:
          SHOW CREATE TYPE_SYM sp_name
          {
            $$ = NEW_PTN PT_show_create_type(@$, $4);
          }
        ;
%endif

show_create_trigger_stmt:
          SHOW CREATE TRIGGER_SYM sp_name
          {
            $$ = NEW_PTN PT_show_create_trigger(@$, $4);
          }
        ;

show_procedure_status_stmt:
          SHOW PROCEDURE_SYM STATUS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_status_proc(@$, $4.wild, $4.where);
          }
        ;

show_function_status_stmt:
          SHOW FUNCTION_SYM STATUS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_status_func(@$, $4.wild, $4.where);
          }
        ;

show_type_status_stmt:
          SHOW TYPE_SYM STATUS_SYM opt_wild_or_where
          {
            $$ = NEW_PTN PT_show_status_type(@$, $4.wild, $4.where);
          }
        ;

show_procedure_code_stmt:
%ifdef SQL_MODE_ORACLE
          SHOW PROCEDURE_SYM CODE_SYM sp_namef
%else
          SHOW PROCEDURE_SYM CODE_SYM sp_name
%endif
          {
            $$ = NEW_PTN PT_show_procedure_code(@$, $4);
          }
        ;

show_function_code_stmt:
%ifdef SQL_MODE_ORACLE
          SHOW FUNCTION_SYM CODE_SYM sp_namef
%else
          SHOW FUNCTION_SYM CODE_SYM sp_name
%endif
          {
            $$ = NEW_PTN PT_show_function_code(@$, $4);
          }
        ;

show_create_event_stmt:
          SHOW CREATE EVENT_SYM sp_name
          {
            $$ = NEW_PTN PT_show_create_event(@$, $4);
          }
        ;

show_create_user_stmt:
          SHOW CREATE USER user
          {
            $$ = NEW_PTN PT_show_create_user(@$, $4);
          }
        ;

engine_or_all:
          ident_or_text
        | ALL           { $$ = {}; }
        ;

master_or_binary:
          MASTER_SYM
        | BINARY_SYM
        ;

opt_storage:
          /* empty */
        | STORAGE_SYM
        ;

opt_db:
          /* empty */  { $$= 0; }
        | from_or_in ident { $$= $2.str; }
        ;

opt_full:
          /* empty */ { $$= 0; }
        | FULL        { $$= 1; }
        ;

opt_extended:
          /* empty */   { $$= 0; }
        | EXTENDED_SYM  { $$= 1; }
        ;

opt_show_cmd_type:
          /* empty */          { $$= Show_cmd_type::STANDARD; }
        | FULL                 { $$= Show_cmd_type::FULL_SHOW; }
        | EXTENDED_SYM         { $$= Show_cmd_type::EXTENDED_SHOW; }
        | EXTENDED_SYM FULL    { $$= Show_cmd_type::EXTENDED_FULL_SHOW; }
        ;

from_or_in:
          FROM
        | IN_SYM
        ;

opt_binlog_in:
          /* empty */            { $$ = {}; }
        | IN_SYM TEXT_STRING_sys { $$ = $2; }
        ;

binlog_from:
          /* empty */        { Lex->mi.pos = 4; /* skip magic number */ }
        | FROM ulonglong_num { Lex->mi.pos = $2; }
        ;

opt_wild_or_where:
          /* empty */                   { $$ = {}; }
        | LIKE TEXT_STRING_literal      { $$ = { $2, {} }; }
        | where_clause                  { $$ = { {}, $1 }; }
        ;

/* A Oracle compatible synonym for show */
describe_stmt:
          describe_command table_ident opt_describe_column
          {
            $$= NEW_PTN PT_show_fields(@$, Show_cmd_type::STANDARD, $2, $3);
          }
        ;

explain_stmt:
          describe_command opt_explain_options explainable_stmt
          {
            $$= NEW_PTN PT_explain($2.explain_format_type, $2.is_analyze,
                                   $2.is_explicit, $3);
          }
        | describe_command opt_explain_options  PLAN_SYM FOR_SYM explain_oracle_stmt
          {
            $$= NEW_PTN PT_explain($2.explain_format_type, $2.is_analyze,
                                   $2.is_explicit, $5);
          }
        ;

explain_oracle_stmt:
          select_stmt
        | insert_stmt
        | insert_all_stmt
        | replace_stmt
        | update_stmt
        | merge_stmt
        | delete_stmt
        | CONNECTION_SYM real_ulong_num
          {
            $$= NEW_PTN PT_explain_for_connection(static_cast<my_thread_id>($2));
          }
        ;

explainable_stmt:
          select_stmt
        | insert_stmt
        | insert_all_stmt
        | replace_stmt
        | update_stmt
        | merge_stmt
        | delete_stmt
        | FOR_SYM CONNECTION_SYM real_ulong_num
          {
            $$= NEW_PTN PT_explain_for_connection(static_cast<my_thread_id>($3));
          }
        ;

describe_command:
          DESC
        | DESCRIBE
        ;

opt_explain_format:
          /* empty */
          {
            $$.is_explicit = false;
            $$.explain_format_type = YYTHD->variables.explain_format;
          }
        | FORMAT_SYM EQ ident_or_text
          {
            $$.is_explicit = true;
            if (is_identifier($3, "JSON"))
              $$.explain_format_type = Explain_format_type::JSON;
            else if (is_identifier($3, "TRADITIONAL"))
              $$.explain_format_type = Explain_format_type::TRADITIONAL;
            else if (is_identifier($3, "TREE"))
              $$.explain_format_type = Explain_format_type::TREE;
            else {
              // This includes even TRADITIONAL_STRICT. Since this value is
              // only meant for mtr infrastructure temporarily, we don't want
              // the user to explicitly use this value in EXPLAIN statements.
              // This results in having one less place to deprecate from.
              my_error(ER_UNKNOWN_EXPLAIN_FORMAT, MYF(0), $3.str);
              MYSQL_YYABORT;
            }
          }

opt_explain_options:
          ANALYZE_SYM opt_explain_format
          {
            $$ = $2;
            $$.is_analyze = true;
          }
        | opt_explain_format
          {
            $$ = $1;
            $$.is_analyze = false;
          }
        ;

opt_describe_column:
          /* empty */ { $$= LEX_STRING{ nullptr, 0 }; }
        | text_string
          {
            if ($1 != nullptr)
              $$= $1->lex_string();
          }
        | ident
        ;


/* flush things */

flush:
          FLUSH_SYM opt_no_write_to_binlog
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_FLUSH;
            lex->type= 0;
            lex->no_write_to_binlog= $2;
          }
          flush_options
          {}
        ;

flush_options:
          table_or_tables opt_table_list
          {
            Lex->type|= REFRESH_TABLES;
            /*
              Set type of metadata and table locks for
              FLUSH TABLES table_list [WITH READ LOCK].
            */
            YYPS->m_lock_type= TL_READ_NO_INSERT;
            YYPS->m_mdl_type= MDL_SHARED_HIGH_PRIO;
            if (Select->add_tables(YYTHD, $2, TL_OPTION_UPDATING,
                                   YYPS->m_lock_type, YYPS->m_mdl_type))
              MYSQL_YYABORT;
          }
          opt_flush_lock {}
        | flush_options_list
        ;

opt_flush_lock:
          /* empty */ {}
        | WITH READ_SYM LOCK_SYM
          {
            Table_ref *tables= Lex->query_tables;
            Lex->type|= REFRESH_READ_LOCK;
            for (; tables; tables= tables->next_global)
            {
              tables->mdl_request.set_type(MDL_SHARED_NO_WRITE);
              /* Don't try to flush views. */
              tables->required_type= dd::enum_table_type::BASE_TABLE;
              tables->open_type= OT_BASE_ONLY;      /* Ignore temporary tables. */
            }
          }
        | FOR_SYM
          {
            if (Lex->query_tables == NULL) // Table list can't be empty
            {
              YYTHD->syntax_error(ER_NO_TABLES_USED);
              MYSQL_YYABORT;
            }
          }
          EXPORT_SYM
          {
            Table_ref *tables= Lex->query_tables;
            Lex->type|= REFRESH_FOR_EXPORT;
            for (; tables; tables= tables->next_global)
            {
              tables->mdl_request.set_type(MDL_SHARED_NO_WRITE);
              /* Don't try to flush views. */
              tables->required_type= dd::enum_table_type::BASE_TABLE;
              tables->open_type= OT_BASE_ONLY;      /* Ignore temporary tables. */
            }
          }
        ;

flush_options_list:
          flush_options_list ',' flush_option
        | flush_option
          {}
        ;

flush_option:
          ERROR_SYM LOGS_SYM
          { Lex->type|= REFRESH_ERROR_LOG; }
        | ENGINE_SYM LOGS_SYM
          { Lex->type|= REFRESH_ENGINE_LOG; }
        | GENERAL LOGS_SYM
          { Lex->type|= REFRESH_GENERAL_LOG; }
        | SLOW LOGS_SYM
          { Lex->type|= REFRESH_SLOW_LOG; }
        | BINARY_SYM LOGS_SYM
          { Lex->type|= REFRESH_BINARY_LOG; }
        | RELAY LOGS_SYM opt_channel
          {
            Lex->type|= REFRESH_RELAY_LOG;
            if (Lex->set_channel_name($3))
              MYSQL_YYABORT;  // OOM
          }
        | HOSTS_SYM
          { Lex->type|= REFRESH_HOSTS; }
        | PRIVILEGES
          { Lex->type|= REFRESH_GRANT; }
        | LOGS_SYM
          { Lex->type|= REFRESH_LOG; }
        | STATUS_SYM
          { Lex->type|= REFRESH_STATUS; }
        | CLIENT_STATS_SYM
          { Lex->type|= REFRESH_CLIENT_STATS; }
        | USER_STATS_SYM
          { Lex->type|= REFRESH_USER_STATS; }
        | THREAD_STATS_SYM
          { Lex->type|= REFRESH_THREAD_STATS; }
        | TABLE_STATS_SYM
          { Lex->type|= REFRESH_TABLE_STATS; }
        | INDEX_STATS_SYM
          { Lex->type|= REFRESH_INDEX_STATS; }
        | RESOURCES
          { Lex->type|= REFRESH_USER_RESOURCES; }
        | OPTIMIZER_COSTS_SYM
          { Lex->type|= REFRESH_OPTIMIZER_COSTS; }
        | MEMORY_SYM PROFILE_SYM
          { Lex->type|= DUMP_MEMORY_PROFILE; }
        ;

opt_table_list:
          /* empty */  { $$= NULL; }
        | table_list
        ;

reset:
          RESET_SYM
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_RESET; lex->type=0;
          }
          reset_options
          {}
        | RESET_SYM PERSIST_SYM opt_if_exists_ident
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_RESET;
            lex->type|= REFRESH_PERSIST;
            lex->option_type= OPT_PERSIST;
          }
        ;

reset_options:
          reset_options ',' reset_option
        | reset_option
        ;

opt_if_exists_ident:
          /* empty */
          {
            LEX *lex=Lex;
            lex->drop_if_exists= false;
            lex->name= NULL_STR;
          }
        | if_exists persisted_variable_ident
          {
            LEX *lex=Lex;
            lex->drop_if_exists= $1;
            lex->name= $2;
          }
        ;

persisted_variable_ident:
          ident
        | ident '.' ident
          {
            const LEX_STRING prefix = $1;
            const LEX_STRING suffix = $3;
            $$.length = prefix.length + 1 + suffix.length + 1;
            $$.str = static_cast<char *>(YYTHD->alloc($$.length));
            if ($$.str == nullptr) YYABORT;  // OOM
            strxnmov($$.str, $$.length, prefix.str, ".", suffix.str, nullptr);
          }
        | DEFAULT_SYM '.' ident
          {
            const LEX_CSTRING prefix{STRING_WITH_LEN("default")};
            const LEX_STRING suffix = $3;
            $$.length = prefix.length + 1 + suffix.length + 1;
            $$.str = static_cast<char *>(YYTHD->alloc($$.length));
            if ($$.str == nullptr) YYABORT;  // OOM
            strxnmov($$.str, $$.length, prefix.str, ".", suffix.str, nullptr);
          }
        ;

reset_option:
          SLAVE
            {
              Lex->type|= REFRESH_SLAVE;
              Lex->set_replication_deprecated_syntax_used();
              push_deprecated_warn(YYTHD, "RESET SLAVE", "RESET REPLICA");
            }
          opt_replica_reset_options opt_channel
          {
            if (Lex->set_channel_name($4))
              MYSQL_YYABORT;  // OOM
          }
        | REPLICA_SYM
          { Lex->type|= REFRESH_REPLICA; }
          opt_replica_reset_options opt_channel
          {
          if (Lex->set_channel_name($4))
            MYSQL_YYABORT;  // OOM
          }
        | MASTER_SYM
          {
            Lex->type|= REFRESH_MASTER;
            /*
              Reset Master should acquire global read lock
              in order to avoid any parallel transaction commits
              while the reset operation is going on.

              *Only if* the thread is not already acquired the global
              read lock, server will acquire global read lock
              during the operation and release it at the
              end of the reset operation.
            */
            if (!(YYTHD)->global_read_lock.is_acquired())
              Lex->type|= REFRESH_TABLES | REFRESH_READ_LOCK;
          }
          source_reset_options
        ;

opt_replica_reset_options:
          /* empty */ { Lex->reset_slave_info.all= false; }
        | ALL         { Lex->reset_slave_info.all= true; }
        ;

source_reset_options:
          /* empty */ {}
        | TO_SYM real_ulonglong_num
          {
            if ($2 == 0 || $2 > MAX_ALLOWED_FN_EXT_RESET_MASTER)
            {
              my_error(ER_RESET_MASTER_TO_VALUE_OUT_OF_RANGE, MYF(0),
                       $2, MAX_ALLOWED_FN_EXT_RESET_MASTER);
              MYSQL_YYABORT;
            }
            else
              Lex->next_binlog_file_nr = $2;
          }
        ;

purge:
          PURGE
          {
            LEX *lex=Lex;
            lex->type=0;
            lex->sql_command = SQLCOM_PURGE;
          }
          purge_options
          {}
        ;

purge_options:
          master_or_binary LOGS_SYM purge_option
        ;

purge_option:
          TO_SYM TEXT_STRING_sys
          {
            Lex->to_log = $2.str;
          }
        | BEFORE_SYM expr
          {
            ITEMIZE($2, &$2);

            LEX *lex= Lex;
            lex->purge_value_list.clear();
            lex->purge_value_list.push_front($2);
            lex->sql_command= SQLCOM_PURGE_BEFORE;
          }
        ;

/* kill threads */

kill:
          KILL_SYM kill_option expr
          {
            ITEMIZE($3, &$3);

            LEX *lex=Lex;
            lex->kill_value_list.clear();
            lex->kill_value_list.push_front($3);
            lex->sql_command= SQLCOM_KILL;
          }
        ;

kill_option:
          /* empty */ { Lex->type= 0; }
        | CONNECTION_SYM { Lex->type= 0; }
        | QUERY_SYM      { Lex->type= ONLY_KILL_QUERY; }
        ;

/* change database */

use:
          USE_SYM ident
          {
            LEX *lex=Lex;
            lex->sql_command=SQLCOM_CHANGE_DB;
            lex->query_block->db= $2.str;
          }
        ;

/* import, export of files */

load_stmt:
          LOAD                          /*  1 */
          data_or_xml                   /*  2 */
          load_data_lock                /*  3 */
          opt_from_keyword              /*  4 */
          opt_local                     /*  5 */
          load_source_type              /*  6 */
          TEXT_STRING_filesystem        /*  7 */
          opt_source_count              /*  8 */
          opt_source_order              /*  9 */
          opt_duplicate                 /* 10 */
          INTO                          /* 11 */
          TABLE_SYM                     /* 12 */
          table_ident                   /* 13 */
          opt_use_partition             /* 14 */
          opt_load_data_charset         /* 15 */
          opt_xml_rows_identified_by    /* 16 */
          opt_field_term                /* 17 */
          opt_line_term                 /* 18 */
          opt_ignore_lines              /* 19 */
          opt_field_or_var_spec         /* 20 */
          opt_load_data_set_spec        /* 21 */
          opt_load_algorithm            /* 22 */
          {
            $$= NEW_PTN PT_load_table($2,  // data_or_xml
                                      $3,  // load_data_lock
                                      $5,  // opt_local
                                      $6,  // source type
                                      $7,  // TEXT_STRING_filesystem
                                      $8,  // opt_source_count
                                      $9,  // opt_source_order
                                      $10, // opt_duplicate
                                      $13, // table_ident
                                      $14, // opt_use_partition
                                      $15, // opt_load_data_charset
                                      $16, // opt_xml_rows_identified_by
                                      $17, // opt_field_term
                                      $18, // opt_line_term
                                      $19, // opt_ignore_lines
                                      $20, // opt_field_or_var_spec
                                      $21.set_var_list,// opt_load_data_set_spec
                                      $21.set_expr_list,
                                      $21.set_expr_str_list,
                                      $22, // opt_load_algorithm
                                      $1); // hints for enable parallel load
          }
        ;

data_or_xml:
          DATA_SYM{ $$= FILETYPE_CSV; }
        | XML_SYM { $$= FILETYPE_XML; }
        ;

opt_local:
          /* empty */ { $$= false; }
        | LOCAL_SYM   { $$= true; }
        ;

opt_from_keyword:
          /* empty */ {}
        | FROM        {}
        ;

load_data_lock:
          /* empty */ { $$= TL_WRITE_DEFAULT; }
        | CONCURRENT  { $$= TL_WRITE_CONCURRENT_INSERT; }
        | LOW_PRIORITY { $$= TL_WRITE_LOW_PRIORITY; }
        ;

load_source_type:
          INFILE_SYM { $$ = LOAD_SOURCE_FILE; }
        | URL_SYM    { $$ = LOAD_SOURCE_URL; }
     // | S3_SYM     { $$ = LOAD_SOURCE_S3; }
        ;

opt_source_count:
          /* empty */   { $$= 0; }
        | COUNT_SYM NUM { $$= atol($2.str); }
        | IDENT_sys NUM
          {
            // COUNT can be key word or identifier based on SQL mode
            if (my_strcasecmp(system_charset_info, $1.str, "count") != 0) {
              YYTHD->syntax_error_at(@1, "COUNT expected");
              YYABORT;
            }
            $$= atol($2.str);
          }
        ;

opt_source_order:
          /* empty */  { $$= false; }
        | IN_SYM PRIMARY_SYM KEY_SYM ORDER_SYM { $$= true; }
        ;

opt_duplicate:
          /* empty */ { $$= On_duplicate::ERROR; }
        | duplicate
        ;

duplicate:
          REPLACE_SYM { $$= On_duplicate::REPLACE_DUP; }
        | IGNORE_SYM  { $$= On_duplicate::IGNORE_DUP; }
        ;

opt_field_term:
          /* empty */             { $$.cleanup(); }
        | COLUMNS field_term_list { $$= $2; }
        ;

field_term_list:
          field_term_list field_term
          {
            $$= $1;
            $$.merge_field_separators($2);
          }
        | field_term
        ;

field_term:
          TERMINATED BY text_string
          {
            $$.cleanup();
            $$.field_term= $3;
          }
        | OPTIONALLY ENCLOSED BY text_string
          {
            $$.cleanup();
            $$.enclosed= $4;
            $$.opt_enclosed= 1;
          }
        | ENCLOSED BY text_string
          {
            $$.cleanup();
            $$.enclosed= $3;
          }
        | ESCAPED BY text_string
          {
            $$.cleanup();
            $$.escaped= $3;
          }
        ;

opt_line_term:
          /* empty */          { $$.cleanup(); }
        | LINES line_term_list { $$= $2; }
        ;

line_term_list:
          line_term_list line_term
          {
            $$= $1;
            $$.merge_line_separators($2);
          }
        | line_term
        ;

line_term:
          TERMINATED BY text_string
          {
            $$.cleanup();
            $$.line_term= $3;
          }
        | STARTING BY text_string
          {
            $$.cleanup();
            $$.line_start= $3;
          }
        ;

opt_xml_rows_identified_by:
          /* empty */                            { $$= nullptr; }
        | ROWS_SYM IDENTIFIED_SYM BY text_string { $$= $4; }
        ;

opt_ignore_lines:
          /* empty */                   { $$= 0; }
        | IGNORE_SYM NUM lines_or_rows  { $$= atol($2.str); }
        ;

lines_or_rows:
          LINES
        | ROWS_SYM
        ;

opt_field_or_var_spec:
          /* empty */            { $$= nullptr; }
        | '(' fields_or_vars ')' { $$= $2; }
        | '(' ')'                { $$= nullptr; }
        ;

fields_or_vars:
          fields_or_vars ',' field_or_var
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        | field_or_var
          {
            $$= NEW_PTN PT_item_list;
            if ($$ == nullptr || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        ;

field_or_var:
          simple_ident_nospvar
        | '@' ident_or_text
          {
            $$= NEW_PTN Item_user_var_as_out_param(@$, $2);
          }
        ;

opt_load_data_set_spec:
          /* empty */                { $$= {nullptr, nullptr, nullptr}; }
        | SET_SYM load_data_set_list { $$= $2; }
        ;

load_data_set_list:
          load_data_set_list ',' load_data_set_elem
          {
            $$= $1;
            if ($$.set_var_list->push_back($3.set_var) ||
                $$.set_expr_list->push_back($3.set_expr) ||
                $$.set_expr_str_list->push_back($3.set_expr_str))
              MYSQL_YYABORT; // OOM
          }
        | load_data_set_elem
          {
            $$.set_var_list= NEW_PTN PT_item_list;
            if ($$.set_var_list == nullptr ||
                $$.set_var_list->push_back($1.set_var))
              MYSQL_YYABORT; // OOM

            $$.set_expr_list= NEW_PTN PT_item_list;
            if ($$.set_expr_list == nullptr ||
                $$.set_expr_list->push_back($1.set_expr))
              MYSQL_YYABORT; // OOM

            $$.set_expr_str_list= NEW_PTN List<String>;
            if ($$.set_expr_str_list == nullptr ||
                $$.set_expr_str_list->push_back($1.set_expr_str))
              MYSQL_YYABORT; // OOM
          }
        ;

load_data_set_elem:
          simple_ident_nospvar equal expr_or_default
          {
            size_t length= @3.cpp.end - @2.cpp.start;

            if ($3 == nullptr)
              MYSQL_YYABORT; // OOM
            $3->item_name.copy(@2.cpp.start, length, YYTHD->charset());

            $$.set_var= $1;
            $$.set_expr= $3;
            $$.set_expr_str= NEW_PTN String(@2.cpp.start,
                                            length,
                                            YYTHD->charset());
            if ($$.set_expr_str == nullptr)
              MYSQL_YYABORT; // OOM
          }
        ;

opt_load_algorithm:
          /* empty */               { $$ = false; }
        | ALGORITHM_SYM EQ BULK_SYM { $$ = true; }
        ;

/* Common definitions */

text_literal:
          TEXT_STRING
          {
            $$= NEW_PTN PTI_text_literal_text_string(@$,
                YYTHD->m_parser_state->m_lip.text_string_is_7bit(), $1);
          }
        | NCHAR_STRING
          {
            $$= NEW_PTN PTI_text_literal_nchar_string(@$,
                YYTHD->m_parser_state->m_lip.text_string_is_7bit(), $1);
            warn_about_deprecated_national(YYTHD);
          }
        | UNDERSCORE_CHARSET TEXT_STRING
          {
            $$= NEW_PTN PTI_text_literal_underscore_charset(@$,
                YYTHD->m_parser_state->m_lip.text_string_is_7bit(), $1, $2);
          }
        | text_literal TEXT_STRING_literal
          {
            $$= NEW_PTN PTI_text_literal_concat(@$,
                YYTHD->m_parser_state->m_lip.text_string_is_7bit(), $1, $2);
          }
        ;

text_string:
          TEXT_STRING_literal
          {
            $$= NEW_PTN String($1.str, $1.length,
                               YYTHD->variables.collation_connection);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | HEX_NUM
          {
            LEX_CSTRING s= Item_hex_string::make_hex_str($1.str, $1.length);
            $$= NEW_PTN String(s.str, s.length, &my_charset_bin);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | BIN_NUM
          {
            LEX_CSTRING s= Item_bin_string::make_bin_str($1.str, $1.length);
            $$= NEW_PTN String(s.str, s.length, &my_charset_bin);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

param_marker:
          PARAM_MARKER
          {
            auto *i= NEW_PTN Item_param(@$, YYMEM_ROOT,
                                        (uint) (@1.raw.start - YYLIP->get_buf()));
            if (i == NULL)
              MYSQL_YYABORT;
            auto *lex= Lex;
            /*
              If we are not re-parsing a CTE definition, this is a
              real parameter, so add it to param_list.
            */
            if (!lex->reparse_common_table_expr_at &&
                lex->param_list.push_back(i))
              MYSQL_YYABORT;
            $$= i;
          }
        ;

signed_literal:
          literal
        | '+' NUM_literal { $$= $2; }
        | '-' NUM_literal
          {
            if ($2 == NULL)
              MYSQL_YYABORT; // OOM
            $2->max_length++;
            $$= $2->neg();
          }
        ;

signed_literal_or_null:
          signed_literal
        | null_as_literal
        ;

null_as_literal:
          NULL_SYM
          {
            Lex_input_stream *lip= YYLIP;
            /*
              For the digest computation, in this context only,
              NULL is considered a literal, hence reduced to '?'
              REDUCE:
                TOK_GENERIC_VALUE := NULL_SYM
            */
            lip->reduce_digest_token(TOK_GENERIC_VALUE, NULL_SYM);
            $$= NEW_PTN Item_null(@$);
          }
        ;

literal:
          text_literal
          {
            /*
              When emptystring_equal_null mode empty string set to null
            */
            THD *thd= YYTHD;
            if ((thd->variables.sql_mode & MODE_EMPTYSTRING_EQUAL_NULL) && $1->is_empty())
              $$= NEW_PTN Item_null(@$);
            else
              $$= $1;
          }
        | NUM_literal  { $$= $1; }
        | temporal_literal
        | FALSE_SYM
          {
            $$= NEW_PTN Item_func_false(@$);
          }
        | TRUE_SYM
          {
            $$= NEW_PTN Item_func_true(@$);
          }
        | HEX_NUM
          {
            $$= NEW_PTN Item_hex_string(@$, $1);
          }
        | BIN_NUM
          {
            $$= NEW_PTN Item_bin_string(@$, $1);
          }
        | UNDERSCORE_CHARSET HEX_NUM
          {
            $$= NEW_PTN PTI_literal_underscore_charset_hex_num(@$, $1, $2);
          }
        | UNDERSCORE_CHARSET BIN_NUM
          {
            $$= NEW_PTN PTI_literal_underscore_charset_bin_num(@$, $1, $2);
          }
        ;

literal_or_null:
          literal
        | null_as_literal
        ;

NUM_literal:
          int64_literal
        | DECIMAL_NUM
          {
            $$= NEW_PTN Item_decimal(@$, $1.str, $1.length, YYCSCL);
          }
        | FLOAT_NUM
          {
            $$= NEW_PTN Item_float(@$, $1.str, $1.length);
          }
        ;

/*
  int64_literal if for unsigned exact integer literals in a range of
  [0 .. 2^64-1].
*/
int64_literal:
          NUM           { $$ = NEW_PTN Item_int(@$, $1); }
        | LONG_NUM      { $$ = NEW_PTN Item_int(@$, $1); }
        | ULONGLONG_NUM { $$ = NEW_PTN Item_uint(@$, $1.str, $1.length); }
        ;


temporal_literal:
        DATE_SYM TEXT_STRING
          {
            $$= NEW_PTN PTI_temporal_literal(@$, $2, MYSQL_TYPE_DATE, YYCSCL);
          }
        | TIME_SYM TEXT_STRING
          {
            $$= NEW_PTN PTI_temporal_literal(@$, $2, MYSQL_TYPE_TIME, YYCSCL);
          }
        | TIMESTAMP_SYM TEXT_STRING
          {
            $$= NEW_PTN PTI_temporal_literal(@$, $2, MYSQL_TYPE_DATETIME, YYCSCL);
          }
        ;

opt_interval:
          /* empty */   { $$ = false; }
        | INTERVAL_SYM  { $$ = true; }
        ;


/**********************************************************************
** Creating different items.
**********************************************************************/

insert_column:
          simple_ident_nospvar
        ;

table_wild:
          ident '.' '*'
          {
            $$ = NEW_PTN Item_asterisk(@$, nullptr, $1.str);
          }
        | ident '.' ident '.' '*'
          {
            if (check_and_convert_db_name(&$1, false) != Ident_name_check::OK)
              MYSQL_YYABORT;
            auto schema_name = YYCLIENT_NO_SCHEMA ? nullptr : $1.str;
            $$ = NEW_PTN Item_asterisk(@$, schema_name, $3.str);
          }
        ;

order_expr:
          expr opt_ordering_direction opt_nulls_position
          {
            $$= NEW_PTN PT_order_expr($1, $2);
            $$->nulls_pos= enum_nulls_position($3);
          }
        ;

grouping_expr:
          expr
          {
            $$= NEW_PTN PT_order_expr($1, ORDER_NOT_RELEVANT);
          }
        ;

simple_ident_with_plus:
          IDENT_sys'(' '+' ')'
          {
            $$= NEW_PTN PTI_simple_ident_ident(@$, to_lex_cstring($1));
            $$->outer_joined = true;
          }
        | ident '.' ident '(' '+' ')'
          {
            $$= NEW_PTN PTI_simple_ident_q_2d(@$, $1.str, $3.str);
            $$->outer_joined = true;
          }
%ifndef SQL_MODE_ORACLE
        | ident '.' ident '.' ident '(' '+' ')'
          {
            if (check_and_convert_db_name(&$1, false) != Ident_name_check::OK)
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_3d(@$, $1.str, $3.str, $5.str);
            $$->outer_joined = true;
          }
%else
        | ident '.' ident '.' IDENT_sys '(' '+' ')'
          {
            if (check_and_convert_db_name(&$1, false) != Ident_name_check::OK)
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_3d(@$, $1.str, $3.str, $5.str);
            $$->outer_joined = true;
          }
%endif
        ;

simple_ident:
          ident
          {
            $$= NEW_PTN PTI_simple_ident_ident(@$, to_lex_cstring($1));
          }
        | simple_ident_q
        ;

simple_ident_nospvar:
          ident
          {
            $$= NEW_PTN PTI_simple_ident_nospvar_ident(@$, $1);
          }
        | simple_ident_q
        ;

simple_ident_q:
          ident '.' ident
          {
%ifdef SQL_MODE_ORACLE
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (sp && sp->m_type == enum_sp_type::TRIGGER &&
                sp->m_trg_chistics.trigger_when_expr &&
                (!my_strcasecmp(system_charset_info, $1.str, "NEW") &&
                 !my_strcasecmp(system_charset_info, $1.str, "OLD"))) {
              my_error(ER_ERROR_IN_TRIGGER_BODY, MYF(0), sp->name(), YYTHD->strmake(@1.raw.start, @3.raw.end - @1.raw.start));
              MYSQL_YYABORT;
            }
%endif
            $$= NEW_PTN PTI_simple_ident_q_2d(@$, $1.str, $3.str);
          }
        | ident '.' ident '.' ident
          {
            if (check_and_convert_db_name(&$1, false) != Ident_name_check::OK)
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_3d(@$, $1.str, $3.str, $5.str);
          }
%ifdef SQL_MODE_ORACLE
        | ':' ident '.' ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (!sp)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            else if (sp->m_type != enum_sp_type::TRIGGER)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), YYTHD->strmake(@1.raw.start, @4.raw.end - @1.raw.start));
              MYSQL_YYABORT;
            } 
            else if (sp->m_trg_chistics.trigger_when_expr)
            {
              my_error(ER_ERROR_IN_TRIGGER_BODY, MYF(0), sp->name(), YYTHD->strmake(@1.raw.start, @4.raw.end - @1.raw.start));
              MYSQL_YYABORT;
            }
            $$= NEW_PTN PTI_simple_ident_q_2d(@$, $2.str, $4.str);
          }
        | ident '.' ident  '(' opt_expr_list ')' '.' ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (!sp)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            if(!$5 || $5->elements() != 1){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "empty parameter or more than one parameter with table type");
              MYSQL_YYABORT;
            }
            Item *item_int = $5->value.front();
            ITEMIZE(item_int, &item_int);
            ora_simple_ident_def *def_db= NEW_PTN ora_simple_ident_def($1, nullptr);
            List<ora_simple_ident_def> *list= new (YYMEM_ROOT) List<ora_simple_ident_def>;
            if (list->push_back(def_db))
              MYSQL_YYABORT;
            ora_simple_ident_def *def_table= NEW_PTN ora_simple_ident_def($3, item_int);
            if (list->push_back(def_table))
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_nd(@$, list, $8.str);
          }
        | ident '.' ident '.' ora_simple_ident_list ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (!sp)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            ora_simple_ident_def *def_table= NEW_PTN ora_simple_ident_def($3, nullptr);
            if ($5->push_front(def_table))
              MYSQL_YYABORT;
            ora_simple_ident_def *def_db= NEW_PTN ora_simple_ident_def($1, nullptr);
            if ($5->push_front(def_db))
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_nd(@$, $5, $6.str);
          }
        | ident '.' ident  '(' opt_expr_list ')' '.' ora_simple_ident_list ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (!sp)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            if(!$5 || $5->elements() != 1){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "empty parameter or more than one parameter with table type");
              MYSQL_YYABORT;
            }
            Item *item_int = $5->value.front();
            ITEMIZE(item_int, &item_int);
            ora_simple_ident_def *def_table= NEW_PTN ora_simple_ident_def($3, item_int);
            if ($8->push_front(def_table))
              MYSQL_YYABORT;
            ora_simple_ident_def *def_db= NEW_PTN ora_simple_ident_def($1, nullptr);
            if ($8->push_front(def_db))
              MYSQL_YYABORT;
            $$= NEW_PTN PTI_simple_ident_q_nd(@$, $8, $9.str);
          }
%endif
        ;

table_ident:
          ident
          {
            $$= NEW_PTN Table_ident(to_lex_cstring($1));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | ident '.' ident
          {
            auto schema_name = YYCLIENT_NO_SCHEMA ? LEX_CSTRING{}
                                                  : to_lex_cstring($1.str);
            $$= NEW_PTN Table_ident(schema_name, to_lex_cstring($3));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

table_ident_opt_wild:
          ident opt_wild
          {
            $$= NEW_PTN Table_ident(to_lex_cstring($1));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | ident '.' ident opt_wild
          {
            $$= NEW_PTN Table_ident(YYTHD->get_protocol(),
                                    to_lex_cstring($1),
                                    to_lex_cstring($3), 0);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

IDENT_sys:
          IDENT { $$= $1; }
        | IDENT_QUOTED
          {
            THD *thd= YYTHD;

            if (thd->charset_is_system_charset)
            {
              const CHARSET_INFO *cs= system_charset_info;
              int dummy_error;
              size_t wlen= cs->cset->well_formed_len(cs, $1.str,
                                                     $1.str+$1.length,
                                                     $1.length, &dummy_error);
              if (wlen < $1.length)
              {
                ErrConvString err($1.str, $1.length, &my_charset_bin);
                my_error(ER_INVALID_CHARACTER_STRING, MYF(0),
                         cs->csname, err.ptr());
                MYSQL_YYABORT;
              }
              $$= $1;
            }
            else
            {
              if (thd->convert_string(&$$, system_charset_info,
                                  $1.str, $1.length, thd->charset()))
                MYSQL_YYABORT;
            }
          }
        ;

TEXT_STRING_sys_nonewline:
          TEXT_STRING_sys
          {
            if (!strcont($1.str, "\n"))
              $$= $1;
            else
            {
              my_error(ER_WRONG_VALUE, MYF(0), "argument contains not-allowed LF", $1.str);
              MYSQL_YYABORT;
            }
          }
        ;

filter_wild_db_table_string:
          TEXT_STRING_sys_nonewline
          {
            if (strcont($1.str, "."))
              $$= $1;
            else
            {
              my_error(ER_INVALID_RPL_WILD_TABLE_FILTER_PATTERN, MYF(0));
              MYSQL_YYABORT;
            }
          }
        ;

TEXT_STRING_sys:
          TEXT_STRING
          {
            THD *thd= YYTHD;

            if (thd->charset_is_system_charset)
              $$= $1;
            else
            {
              if (thd->convert_string(&$$, system_charset_info,
                                  $1.str, $1.length, thd->charset()))
                MYSQL_YYABORT;
            }
          }
        ;

TEXT_STRING_literal:
          TEXT_STRING
          {
            THD *thd= YYTHD;

            if (thd->charset_is_collation_connection)
              $$= $1;
            else
            {
              if (thd->convert_string(&$$, thd->variables.collation_connection,
                                  $1.str, $1.length, thd->charset()))
                MYSQL_YYABORT;
            }
          }
        ;

TEXT_STRING_filesystem:
          TEXT_STRING
          {
            THD *thd= YYTHD;

            if (thd->charset_is_character_set_filesystem)
              $$= $1;
            else
            {
              if (thd->convert_string(&$$,
                                      thd->variables.character_set_filesystem,
                                      $1.str, $1.length, thd->charset()))
                MYSQL_YYABORT;
            }
          }
        ;

TEXT_STRING_password:
          TEXT_STRING
        ;

TEXT_STRING_hash:
          TEXT_STRING_sys
        | HEX_NUM
          {
            $$= to_lex_string(Item_hex_string::make_hex_str($1.str, $1.length));
          }
        ;

TEXT_STRING_validated:
          TEXT_STRING
          {
            THD *thd= YYTHD;

            if (thd->charset_is_system_charset)
              $$= $1;
            else
            {
              if (thd->convert_string(&$$, system_charset_info,
                                  $1.str, $1.length, thd->charset(), true))
                MYSQL_YYABORT;
            }
          }
        ;

ident:
          IDENT_sys    { $$=$1; }
        | ident_keyword
          {
            THD *thd= YYTHD;
            $$.str= thd->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;

role_ident:
          IDENT_sys
        | role_keyword
          {
            $$.str= YYTHD->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;

label_ident:
          IDENT_sys    { $$=to_lex_cstring($1); }
        | label_keyword
          {
            THD *thd= YYTHD;
            $$.str= thd->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;

lvalue_ident:
          IDENT_sys
        | lvalue_keyword
          {
            $$.str= YYTHD->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;

table_alias_ident:
          IDENT_sys
        | table_alias_keyword
          {
            $$.str= YYTHD->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;

ident_or_text:
%ifndef SQL_MODE_ORACLE
          ident           { $$=$1;}
%else
          sp_decl_ident   { $$=$1;}
%endif
        | TEXT_STRING_sys { $$=$1;}
        | LEX_HOSTNAME { $$=$1;}
        ;

role_ident_or_text:
          role_ident
        | TEXT_STRING_sys
        | LEX_HOSTNAME
        ;

user_ident_or_text:
          ident_or_text
          {
            if (!($$= LEX_USER::alloc(YYTHD, &$1, NULL)))
              MYSQL_YYABORT;
          }
        | ident_or_text '@' ident_or_text
          {
            if (!($$= LEX_USER::alloc(YYTHD, &$1, &$3)))
              MYSQL_YYABORT;
          }
        ;

user:
          user_ident_or_text
          {
            $$=$1;
          }
        | CURRENT_USER optional_braces
          {
            if (!($$= LEX_USER::alloc(YYTHD)))
              MYSQL_YYABORT;
            /*
              empty LEX_USER means current_user and
              will be handled in the  get_current_user() function
              later
            */
          }
        ;

role:
          role_ident_or_text
          {
            if (!($$= LEX_USER::alloc(YYTHD, &$1, NULL)))
              MYSQL_YYABORT;
          }
        | role_ident_or_text '@' ident_or_text
          {
            if (!($$= LEX_USER::alloc(YYTHD, &$1, &$3)))
              MYSQL_YYABORT;
          }
        ;

schema:
%ifndef SQL_MODE_ORACLE
          ident
%else
          sp_decl_ident
%endif
          {
            $$ = $1;
            if (check_and_convert_db_name(&$$, false) != Ident_name_check::OK)
              MYSQL_YYABORT;
          }
        ;

/*
  Non-reserved keywords are allowed as unquoted identifiers in general.

  OTOH, in a few particular cases statement-specific rules are used
  instead of `ident_keyword` to avoid grammar ambiguities:

    * `label_keyword` for SP label names
    * `role_keyword` for role names
    * `lvalue_keyword` for variable prefixes and names in left sides of
                       assignments in SET statements
    * `ora_value_keyword` like lvalue_keyword in oracle_mode
    * `sp_decl_ident_keyword` in oracle_mode sp declare values
    * `table_alias_keyword` for alias table name

  Normally, new non-reserved words should be added to the
  the rule `ident_keywords_unambiguous`. If they cause grammar conflicts, try
  one of `ident_keywords_ambiguous_...` rules instead.
*/
ident_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_1_roles_and_labels
        | ident_keywords_ambiguous_2_labels
        | ident_keywords_ambiguous_3_roles
        | ident_keywords_ambiguous_4_system_variables
        | ident_keywords_ambiguous_5_not_sp_variables
        | ident_keywords_ambiguous_6_not_table_alias
        ;

/*
  These non-reserved words cannot be used as role names and SP label names:
*/
ident_keywords_ambiguous_1_roles_and_labels:
          EXECUTE_SYM
        | RESTART_SYM
        | SHUTDOWN
        ;

/*
  These non-reserved keywords cannot be used as unquoted SP label names:
*/
ident_keywords_ambiguous_2_labels:
          ASCII_SYM
        | BYTE_SYM
        | CHARSET
        | COMMENT_SYM
        | COMPRESSION_DICTIONARY_SYM
        | CONTAINS_SYM
        | LANGUAGE_SYM
        | NO_SYM
        | SIGNED_SYM
        | SLAVE
        | UNICODE_SYM
%ifndef SQL_MODE_ORACLE
        | BEGIN_SYM
        | CACHE_SYM
        | CHECKSUM_SYM
        | CLONE_SYM
        | COMMIT_SYM
        | DEALLOCATE_SYM
        | DO_SYM
        | END
        | FLUSH_SYM
        | FOLLOWS_SYM
        | HANDLER_SYM
        | HELP_SYM
        | IMPORT
        | INSTALL_SYM
        | PRECEDES_SYM
        | PREPARE_SYM
        | REPAIR
        | RESET_SYM
        | ROLLBACK_SYM
        | SAVEPOINT_SYM
        | START_SYM
        | STOP_SYM
        | TRUNCATE_SYM
        | UNINSTALL_SYM
        | XA_SYM
%endif
        ;

/*
  Keywords that we allow for labels in SPs in the unquoted form.
  Any keyword that is allowed to begin a statement or routine characteristics
  must be in `ident_keywords_ambiguous_2_labels` above, otherwise
  we get (harmful) shift/reduce conflicts.

  Not allowed:

    ident_keywords_ambiguous_1_roles_and_labels
    ident_keywords_ambiguous_2_labels
*/
label_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_3_roles
        | ident_keywords_ambiguous_4_system_variables
        | ident_keywords_ambiguous_5_not_sp_variables
        | ident_keywords_ambiguous_6_not_table_alias
        ;

/*
  These non-reserved keywords cannot be used as unquoted role names:
*/
ident_keywords_ambiguous_3_roles:
          EVENT_SYM
        | FILE_SYM
        | NONE_SYM
        | PROCESS
        | PROXY_SYM
        | RELOAD
        | REPLICATION
        | RESOURCE_SYM
        | SUPER_SYM
        ;

/*
  These are the non-reserved keywords which may be used for unquoted
  identifiers everywhere without introducing grammar conflicts:
*/
ident_keywords_unambiguous:
          ACTION
        | ACCOUNT_SYM
        | ACTIVE_SYM
        | ADDDATE_SYM
        | ADMIN_SYM
        | AFTER_SYM
        | AGAINST
        | AGGREGATE_SYM
        | ALGORITHM_SYM
        | ALWAYS_SYM
        | ANY_SYM
        | ARRAY_SYM
        | AT_SYM
        | ATTRIBUTE_SYM
        | AUTHENTICATION_SYM
        | AUTOEXTEND_SIZE_SYM
        | AUTO_INC
        | AVG_ROW_LENGTH
        | AVG_SYM
        | BACKUP_SYM
        | BASED_SYM
        | BINARY_INTEGER_SYM
        | BINLOG_SYM
        | BIT_SYM %prec KEYWORD_USED_AS_IDENT
        | BLOCK_SYM
%ifndef SQL_MODE_ORACLE
        | BODY_SYM
%endif
        | BOOLEAN_SYM
        | BOOL_SYM
        | BTREE_SYM
        | BUCKETS_SYM
        | BUILD_SYM
        | BULK_SYM
        | CASCADED
        | CATALOG_NAME_SYM
        | CHAIN_SYM
        | CHALLENGE_RESPONSE_SYM
        | CHANGED
        | CHANNEL_SYM
        | CIPHER_SYM
        | CLASS_ORIGIN_SYM
        | CLIENT_SYM
        | CLIENT_STATS_SYM
        | CLOSE_SYM
        | COALESCE
        | CODE_SYM
        | COLLATION_SYM
        | COLLECT_SYM
        | COLUMNS
        | COLUMN_FORMAT_SYM
        | COLUMN_NAME_SYM
        | COMMITTED_SYM
        | COMPACT_SYM
        | COMPLETION_SYM
        | COMPONENT_SYM
        | COMPLETE_SYM
        | COMPRESSED_SYM
        | COMPRESSION_SYM
        | CONCURRENT
        | CONNECTION_SYM
        | CONSISTENT_SYM
        | CONSTRAINT_CATALOG_SYM
        | CONSTRAINT_NAME_SYM
        | CONSTRAINT_SCHEMA_SYM
        | CONTEXT_SYM
        | CPU_SYM
        | CURRENT_SYM /* not reserved in MySQL per WL#2111 specification */
        | CURSOR_NAME_SYM
        | CYCLE_SYM
        | DATAFILE_SYM
        | DATA_SYM
        | DATETIME_SYM
        | DATE_SYM %prec KEYWORD_USED_AS_IDENT
        | DAY_SYM
        | DEFAULT_AUTH_SYM
        | DEFERRED_SYM
        | DEFINER_SYM
        | DEFINITION_SYM
        | DELAY_KEY_WRITE_SYM
        | DEMAND_SYM
        | DESCRIPTION_SYM
        | DIAGNOSTICS_SYM
        | DIRECTORY_SYM
        | DISABLE_SYM
        | DISCARD_SYM
        | DISK_SYM
        | DUMPFILE
        | DUPLICATE_SYM
        | DYNAMIC_SYM
        | EFFECTIVE_SYM
        | ENABLE_SYM
        | ENCRYPTION_SYM
        | ENDS_SYM
        | ENFORCED_SYM
        | ENGINES_SYM
        | ENGINE_SYM
        | ENGINE_ATTRIBUTE_SYM
        | ENUM_SYM
        | ERRORS
        | ERROR_SYM
        | ESCAPE_SYM
        | EVENTS_SYM
        | EVERY_SYM
        | EXCHANGE_SYM
        | EXCLUDE_SYM
        | EXPANSION_SYM
        | EXPIRE_SYM
        | EXPORT_SYM
        | EXTENDED_SYM
        | EXTENT_SIZE_SYM
        | EXTERNAL_SYM
        | FACTOR_SYM
        | FAILED_LOGIN_ATTEMPTS_SYM
        | FAST_SYM
        | FAULTS_SYM
        | FILE_BLOCK_SIZE_SYM
        | FILTER_SYM
        | FINISH_SYM
%ifndef SQL_MODE_ORACLE
        | FIRST_SYM
%endif
        | FIXED_SYM
        | FOLLOWING_SYM
        | FORMAT_SYM
        | FORALL_SYM
        | FOUND_SYM
        | GENERAL
        | GENERATE_SYM
        | GEOMETRYCOLLECTION_SYM
        | GEOMETRY_SYM
        | GET_FORMAT
        | GET_MASTER_PUBLIC_KEY_SYM
        | GET_SOURCE_PUBLIC_KEY_SYM
        | GRANTS
        | GROUP_REPLICATION
        | GTID_ONLY_SYM
        | HASH_SYM
        | HISTOGRAM_SYM
        | HISTORY_SYM
        | HOSTS_SYM
        | HOST_SYM
        | HOUR_SYM
        | IDENTIFIED_SYM
        | IGNORE_SERVER_IDS_SYM
        | INACTIVE_SYM
        | INCREMENT_SYM
        | INDEX_STATS_SYM
        | INDEXES
        | INITIAL_SIZE_SYM
        | INITIAL_SYM
        | INITIATE_SYM
        | INSERT_METHOD
        | INSTANCE_SYM
        | INVISIBLE_SYM
        | INVOKER_SYM
        | IO_SYM
        | IPC_SYM
        | ISOLATION
        | ISSUER_SYM
        | JSON_SYM
        | JSON_VALUE_SYM
        | KEY_BLOCK_SIZE
        | KEYRING_SYM
        | LAST_SYM
        | LEAVES
        | LESS_SYM
        | LEVEL_SYM
        | LINESTRING_SYM
        | LIST_SYM
        | LOCATION_SYM
        | LOCKED_SYM
        | LOCKS_SYM
        | LOGFILE_SYM
        | LOGS_SYM
        | MASTER_AUTO_POSITION_SYM
        | MASTER_COMPRESSION_ALGORITHM_SYM
        | MASTER_CONNECT_RETRY_SYM
        | MASTER_DELAY_SYM
        | MASTER_HEARTBEAT_PERIOD_SYM
        | MASTER_HOST_SYM
        | NETWORK_NAMESPACE_SYM
        | MASTER_LOG_FILE_SYM
        | MASTER_LOG_POS_SYM
        | MASTER_PASSWORD_SYM
        | MASTER_PORT_SYM
        | MASTER_PUBLIC_KEY_PATH_SYM
        | MASTER_RETRY_COUNT_SYM
        | MASTER_SSL_CAPATH_SYM
        | MASTER_SSL_CA_SYM
        | MASTER_SSL_CERT_SYM
        | MASTER_SSL_CIPHER_SYM
        | MASTER_SSL_CRLPATH_SYM
        | MASTER_SSL_CRL_SYM
        | MASTER_SSL_KEY_SYM
        | MASTER_SSL_SYM
        | MASTER_SYM
        | MASTER_TLS_CIPHERSUITES_SYM
        | MASTER_TLS_VERSION_SYM
        | MASTER_USER_SYM
        | MASTER_ZSTD_COMPRESSION_LEVEL_SYM
        | MATERIALIZED_SYM
        | MAX_CONNECTIONS_PER_HOUR
        | MAX_QUERIES_PER_HOUR
        | MAX_ROWS
        | MAX_SIZE_SYM
        | MAX_UPDATES_PER_HOUR
        | MAX_USER_CONNECTIONS_SYM
        | MEDIUM_SYM
        | MEMBER_SYM
        | MEMORY_SYM
        | MERGE_SYM
        | MESSAGE_TEXT_SYM
        | MICROSECOND_SYM
        | MIGRATE_SYM
        | MINUTE_SYM
        | MIN_ROWS
        | MIN_VALUE_SYM
        | MODE_SYM
        | MODIFY_SYM
        | MONTH_SYM
        | MULTILINESTRING_SYM
        | MULTIPOINT_SYM
        | MULTIPOLYGON_SYM
        | MUTEX_SYM
        | MYSQL_ERRNO_SYM
        | NAMES_SYM %prec KEYWORD_USED_AS_IDENT
        | NAME_SYM
        | NATIONAL_SYM
        | NCHAR_SYM
        | NDBCLUSTER_SYM
        | NESTED_SYM
        | NEVER_SYM
        | NEW_SYM
        | NEXT_SYM
        | NODEGROUP_SYM
        | NOWAIT_SYM
        | NO_CACHE_SYM
        | NO_CYCLE_SYM
        | NO_MAXVALUE_SYM
        | NO_MINVALUE_SYM
        | NO_ORDER_SYM
        | NO_WAIT_SYM
        | NULLS_SYM
        | NUMBER_SYM
        | NVARCHAR_SYM
        | OBJECT_SYM
        | OFF_SYM
        | OJ_SYM
        | OLD_SYM
        | ONE_SYM
        | ONLY_SYM
        | OPEN_SYM
        | OPTIONAL_SYM
        | OPTIONS_SYM
        | ORDINALITY_SYM
        | ORGANIZATION_SYM
        | OWNER_SYM
        | PACK_KEYS_SYM
%ifndef SQL_MODE_ORACLE
        | PIVOT_SYM
        | REVERSE_SYM
        | RAW_SYM
%endif
        | PAGE_SYM
        | PARSER_SYM
        | PARTIAL
        | PARTITIONING_SYM
        | PARTITIONS_SYM
        | PASSWORD %prec KEYWORD_USED_AS_IDENT
        | PASSWORD_LOCK_TIME_SYM
        | PATH_SYM
        | PERCENT_SYM
        | PHASE_SYM
        | PLUGINS_SYM
        | PLUGIN_DIR_SYM
        | PLUGIN_SYM
        | POINT_SYM
        | POLYGON_SYM
        | PORT_SYM
        | PRECEDING_SYM
        | PRESERVE_SYM
        | PREV_SYM
        | PRIVILEGES
        | PRIVILEGE_CHECKS_USER_SYM
        | PROCESSLIST_SYM
        | PROFILES_SYM
        | PROFILE_SYM
        | PUBLIC_SYM
        | QUARTER_SYM
        | QUERY_SYM
        | QUICK
        | RANDOM_SYM
        | READ_ONLY_SYM
        | REBUILD_SYM
        | RECORD_SYM
        | RECOVER_SYM
        | REDO_BUFFER_SIZE_SYM
        | REDUNDANT_SYM
        | REF_SYM
        | REFERENCE_SYM
        | REGISTRATION_SYM
        | REFRESH_SYM
        | RELAY
        | RELAYLOG_SYM
        | RELAY_LOG_FILE_SYM
        | RELAY_LOG_POS_SYM
        | RELAY_THREAD
        | REMOVE_SYM
        | ASSIGN_GTIDS_TO_ANONYMOUS_TRANSACTIONS_SYM
        | REORGANIZE_SYM
        | REPEATABLE_SYM
        | REPLICAS_SYM
        | REPLICATE_DO_DB
        | REPLICATE_DO_TABLE
        | REPLICATE_IGNORE_DB
        | REPLICATE_IGNORE_TABLE
        | REPLICATE_REWRITE_DB
        | REPLICATE_WILD_DO_TABLE
        | REPLICATE_WILD_IGNORE_TABLE
        | REPLICA_SYM
        | REQUIRE_ROW_FORMAT_SYM
        | REQUIRE_TABLE_PRIMARY_KEY_CHECK_SYM
        | RESOURCES
        | RESPECT_SYM
        | RESTORE_SYM
        | RESUME_SYM
        | RETAIN_SYM
        | RETURNED_SQLSTATE_SYM
        | RETURNING_SYM
        | RETURNS_SYM
        | REUSE_SYM
        | ROLE_SYM
        | ROLLUP_SYM
        | ROTATE_SYM
        | ROUTINE_SYM
        | ROW_COUNT_SYM
        | ROW_FORMAT_SYM
        | RTREE_SYM
        | SCHEDULE_SYM
        | SCHEMA_NAME_SYM
        | SECONDARY_ENGINE_SYM
        | SECONDARY_ENGINE_ATTRIBUTE_SYM
        | SECONDARY_LOAD_SYM
        | SECONDARY_SYM
        | SECONDARY_UNLOAD_SYM
        | SECOND_SYM
        | SECURITY_SYM
        | SEQUENCES
        | SEQUENCE_SYM
        | SERIALIZABLE_SYM
        | SERIAL_SYM
        | SERVER_SYM
        | SERVEROUTPUT_SYM
        | SHARE_SYM
        | SIMPLE_SYM
        | SKIP_SYM
        | SLOW
        | SNAPSHOT_SYM
        | SOCKET_SYM
        | SONAME_SYM
        | SOUNDS_SYM
        | SOURCE_AUTO_POSITION_SYM
        | SOURCE_BIND_SYM
        | SOURCE_COMPRESSION_ALGORITHM_SYM
        | SOURCE_CONNECTION_AUTO_FAILOVER_SYM
        | SOURCE_CONNECT_RETRY_SYM
        | SOURCE_DELAY_SYM
        | SOURCE_HEARTBEAT_PERIOD_SYM
        | SOURCE_HOST_SYM
        | SOURCE_LOG_FILE_SYM
        | SOURCE_LOG_POS_SYM
        | SOURCE_PASSWORD_SYM
        | SOURCE_PORT_SYM
        | SOURCE_PUBLIC_KEY_PATH_SYM
        | SOURCE_RETRY_COUNT_SYM
        | SOURCE_SSL_CAPATH_SYM
        | SOURCE_SSL_CA_SYM
        | SOURCE_SSL_CERT_SYM
        | SOURCE_SSL_CIPHER_SYM
        | SOURCE_SSL_CRLPATH_SYM
        | SOURCE_SSL_CRL_SYM
        | SOURCE_SSL_KEY_SYM
        | SOURCE_SSL_SYM
        | SOURCE_SSL_VERIFY_SERVER_CERT_SYM
        | SOURCE_SYM
        | SOURCE_TLS_CIPHERSUITES_SYM
        | SOURCE_TLS_VERSION_SYM
        | SOURCE_USER_SYM
        | SOURCE_ZSTD_COMPRESSION_LEVEL_SYM
%ifndef SQL_MODE_ORACLE
        | SQLCODE_SYM
        | SQLERRM_SYM
%endif
        | SQL_AFTER_GTIDS
        | SQL_AFTER_MTS_GAPS
        | SQL_BEFORE_GTIDS
        | SQL_BUFFER_RESULT
        | SQL_NO_CACHE_SYM
        | SQL_THREAD
        | SRID_SYM
        | STACKED_SYM
        | START_LSN_SYM
        | STARTS_SYM
        | STATS_AUTO_RECALC_SYM
        | STATS_PERSISTENT_SYM
        | STATS_SAMPLE_PAGES_SYM
        | STATUS_SYM
        | STORAGE_SYM
        | STREAM_SYM
        | STRING_SYM
        | ST_COLLECT_SYM
        | SUBCLASS_ORIGIN_SYM
        | SUBDATE_SYM
        | SUBJECT_SYM
        | SUBPARTITIONS_SYM
        | SUBPARTITION_SYM
        | SUSPEND_SYM
        | SWAPS_SYM
        | SWITCHES_SYM
        | SYNONYM_SYM
        | SYNONYMS_SYM
        | TABLES
        | TABLESPACE_SYM
        | TABLE_CHECKSUM_SYM
        | TABLE_NAME_SYM
        | TABLE_STATS_SYM
        | TEMPORARY
        | TEMPTABLE_SYM
        | TEXT_SYM
        | THAN_SYM
        | THREAD_PRIORITY_SYM
        | THREAD_STATS_SYM
        | TIES_SYM
        | TIMESTAMP_ADD
        | TIMESTAMP_DIFF
        | TIMESTAMP_SYM %prec KEYWORD_USED_AS_IDENT
        | TIME_SYM %prec KEYWORD_USED_AS_IDENT
        | TLS_SYM
        | TRACK_SYM
        | TRANSACTION_SYM
        | TRIGGERS_SYM
        | TYPES_SYM
        | UNBOUNDED_SYM
        | UNCOMMITTED_SYM
        | UNDEFINED_SYM
        | UNDOFILE_SYM
        | UNDO_BUFFER_SIZE_SYM
        | UNKNOWN_SYM
        | UNREGISTER_SYM
        | UNTIL_SYM
        | UPGRADE_SYM
        | URL_SYM
        | USER
        | USER_STATS_SYM
        | USE_FRM
        | VALIDATION_SYM
        | VALUE_SYM
        | VARIABLES
        | VCPU_SYM
        | VIEW_SYM
        | VISIBLE_SYM
        | WAIT_SYM
        | WARNINGS
        | WEEK_SYM
        | WEIGHT_STRING_SYM
        | WITHOUT_SYM
        | WORK_SYM
        | WRAPPER_SYM
        | X509_SYM
        | XID_SYM
        | XML_SYM
        | YEAR_SYM
        | ZONE_SYM
%ifndef SQL_MODE_ORACLE
        | EXCEPTION_SYM
        | RAISE_SYM
        | RAISE_APPLICATION_ERROR
        | OTHERS_SYM
        | BULK_COLLECT_SYM
        | ROWTYPE_ORACLE_SYM
        | NOTFOUND_SYM
        | ISOPEN_SYM
        | ELSIF_ORACLE_SYM
        | PRAGMA_SYM
        | EXCEPTION_INIT
        | INSERTING
        | UPDATING
        | DELETING
%endif
        | ROWCOUNT_SYM
        ;

/*
  In sp it can't be used as a variable,but can be other ident
  such as table name,column name,table alias and so on.
*/
ident_keywords_ambiguous_5_not_sp_variables:
          TYPE_SYM
        | GOTO_SYM
        ;

/*
  Non-reserved keywords that we allow for unquoted role names:

  Not allowed:

    ident_keywords_ambiguous_1_roles_and_labels
    ident_keywords_ambiguous_3_roles
*/
role_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_2_labels
        | ident_keywords_ambiguous_4_system_variables
        | ident_keywords_ambiguous_5_not_sp_variables
        | ident_keywords_ambiguous_6_not_table_alias
        ;

/*
  Non-reserved words allowed for unquoted unprefixed variable names and
  unquoted variable prefixes in the left side of assignments in SET statements:

  Not allowed:

    ident_keywords_ambiguous_4_system_variables
*/
lvalue_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_1_roles_and_labels
        | ident_keywords_ambiguous_2_labels
        | ident_keywords_ambiguous_3_roles
        | ident_keywords_ambiguous_5_not_sp_variables
        | ident_keywords_ambiguous_6_not_table_alias
        ;

/*
  These non-reserved keywords cannot be used as unquoted unprefixed
  variable names and unquoted variable prefixes in the left side of
  assignments in SET statements:
*/
ident_keywords_ambiguous_4_system_variables:
          GLOBAL_SYM
        | LOCAL_SYM
        | PERSIST_SYM
        | PERSIST_ONLY_SYM
        | SESSION_SYM
        ;

/*
  Non-reserved keywords that we allow for unquoted table alias:
  Not allowed:

    ident_keywords_ambiguous_6_not_table_alias
*/
table_alias_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_1_roles_and_labels
        | ident_keywords_ambiguous_2_labels
        | ident_keywords_ambiguous_3_roles
        | ident_keywords_ambiguous_4_system_variables
        | ident_keywords_ambiguous_5_not_sp_variables
        ;

ident_keywords_ambiguous_6_not_table_alias:
          OFFSET_SYM
        | FULL
        ;

/*
  SQLCOM_SET_OPTION statement.

  Note that to avoid shift/reduce conflicts, we have separate rules for the
  first option listed in the statement.
*/

set:
          SET_SYM start_option_value_list
          {
            $$= NEW_PTN PT_set(@1, $2);
          }
        | SET_SYM SERVEROUTPUT_SYM ON_SYM
          {
            $$= Lex->dbmsotpt_set_serveroutput(YYTHD, true, @1, @2);
          }

        | SET_SYM SERVEROUTPUT_SYM OFF_SYM
          {
            $$= Lex->dbmsotpt_set_serveroutput(YYTHD, false, @1, @2);
          }
        ;

// Start of option value list
start_option_value_list:
          option_value_no_option_type option_value_list_continued
          {
            $$= NEW_PTN PT_start_option_value_list_no_type($1, @1, $2);
          }
        | TRANSACTION_SYM transaction_characteristics
          {
            $$= NEW_PTN PT_start_option_value_list_transaction($2, @2);
          }
        | option_type start_option_value_list_following_option_type
          {
            $$= NEW_PTN PT_start_option_value_list_type($1, $2);
          }
        | PASSWORD equal TEXT_STRING_password opt_replace_password opt_retain_current_password
          {
            $$= NEW_PTN PT_option_value_no_option_type_password($3.str, $4.str,
                                                                $5,
                                                                false,
                                                                @4);
          }
        | PASSWORD TO_SYM RANDOM_SYM opt_replace_password opt_retain_current_password
          {
            // RANDOM PASSWORD GENERATION AND RETURN RESULT SET...
            $$= NEW_PTN PT_option_value_no_option_type_password($3.str, $4.str,
                                                                $5,
                                                                true,
                                                                @4);
          }
        | PASSWORD FOR_SYM user equal TEXT_STRING_password opt_replace_password opt_retain_current_password
          {
            $$= NEW_PTN PT_option_value_no_option_type_password_for($3, $5.str,
                                                                    $6.str,
                                                                    $7,
                                                                    false,
                                                                    @6);
          }
        | PASSWORD FOR_SYM user TO_SYM RANDOM_SYM opt_replace_password opt_retain_current_password
          {
            // RANDOM PASSWORD GENERATION AND RETURN RESULT SET...
            $$= NEW_PTN PT_option_value_no_option_type_password_for($3, $5.str,
                                                                    $6.str,
                                                                    $7,
                                                                    true,
                                                                    @6);
          }
        ;

set_role_stmt:
          SET_SYM ROLE_SYM role_list
          {
            $$= NEW_PTN PT_set_role($3);
          }
        | SET_SYM ROLE_SYM NONE_SYM
          {
            $$= NEW_PTN PT_set_role(role_enum::ROLE_NONE);
            Lex->sql_command= SQLCOM_SET_ROLE;
          }
        | SET_SYM ROLE_SYM DEFAULT_SYM
          {
            $$= NEW_PTN PT_set_role(role_enum::ROLE_DEFAULT);
            Lex->sql_command= SQLCOM_SET_ROLE;
          }
        | SET_SYM DEFAULT_SYM ROLE_SYM role_list TO_SYM role_list
          {
            $$= NEW_PTN PT_alter_user_default_role(false, $6, $4,
                                                    role_enum::ROLE_NAME);
          }
        | SET_SYM DEFAULT_SYM ROLE_SYM NONE_SYM TO_SYM role_list
          {
            $$= NEW_PTN PT_alter_user_default_role(false, $6, NULL,
                                                   role_enum::ROLE_NONE);
          }
        | SET_SYM DEFAULT_SYM ROLE_SYM ALL TO_SYM role_list
          {
            $$= NEW_PTN PT_alter_user_default_role(false, $6, NULL,
                                                   role_enum::ROLE_ALL);
          }
        | SET_SYM ROLE_SYM ALL opt_except_role_list
          {
            $$= NEW_PTN PT_set_role(role_enum::ROLE_ALL, $4);
            Lex->sql_command= SQLCOM_SET_ROLE;
          }
        ;

opt_except_role_list:
          /* empty */          { $$= NULL; }
        | EXCEPT_SYM role_list { $$= $2; }
        ;

set_resource_group_stmt:
          SET_SYM RESOURCE_SYM GROUP_SYM ident
          {
            $$= NEW_PTN PT_set_resource_group(to_lex_cstring($4), nullptr);
          }
        | SET_SYM RESOURCE_SYM GROUP_SYM ident FOR_SYM thread_id_list_options
          {
            $$= NEW_PTN PT_set_resource_group(to_lex_cstring($4), $6);
          }
       ;

thread_id_list:
          real_ulong_num
          {
            $$= NEW_PTN Mem_root_array<ulonglong>(YYMEM_ROOT);
            if ($$ == nullptr || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | thread_id_list opt_comma real_ulong_num
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

thread_id_list_options:
         thread_id_list { $$= $1; }
       ;

// Start of option value list, option_type was given
start_option_value_list_following_option_type:
          option_value_following_option_type option_value_list_continued
          {
            $$=
              NEW_PTN PT_start_option_value_list_following_option_type_eq($1,
                                                                          @1,
                                                                          $2);
          }
        | TRANSACTION_SYM transaction_characteristics
          {
            $$= NEW_PTN
              PT_start_option_value_list_following_option_type_transaction($2,
                                                                           @2);
          }
        ;

// Remainder of the option value list after first option value.
option_value_list_continued:
          /* empty */           { $$= NULL; }
        | ',' option_value_list { $$= $2; }
        ;

// Repeating list of option values after first option value.
option_value_list:
          option_value
          {
            $$= NEW_PTN PT_option_value_list_head(@0, $1, @1);
          }
        | option_value_list ',' option_value
          {
            $$= NEW_PTN PT_option_value_list($1, @2, $3, @3);
          }
        ;

// Wrapper around option values following the first option value in the stmt.
option_value:
          option_type option_value_following_option_type
          {
            $$= NEW_PTN PT_option_value_type($1, $2);
          }
        | option_value_no_option_type { $$= $1; }
        ;

option_type:
          GLOBAL_SYM  { $$=OPT_GLOBAL; }
        | PERSIST_SYM { $$=OPT_PERSIST; }
        | PERSIST_ONLY_SYM { $$=OPT_PERSIST_ONLY; }
        | LOCAL_SYM   { $$=OPT_SESSION; }
        | SESSION_SYM { $$=OPT_SESSION; }
        ;

opt_var_type:
          /* empty */ { $$=OPT_SESSION; }
        | GLOBAL_SYM  { $$=OPT_GLOBAL; }
        | LOCAL_SYM   { $$=OPT_SESSION; }
        | SESSION_SYM { $$=OPT_SESSION; }
        ;

opt_rvalue_system_variable_type:
          /* empty */     { $$=OPT_DEFAULT; }
        | GLOBAL_SYM '.'  { $$=OPT_GLOBAL; }
        | LOCAL_SYM '.'   { $$=OPT_SESSION; }
        | SESSION_SYM '.' { $$=OPT_SESSION; }
        ;

opt_set_var_ident_type:
          /* empty */     { $$=OPT_DEFAULT; }
        | PERSIST_SYM '.' { $$=OPT_PERSIST; }
        | PERSIST_ONLY_SYM '.' {$$=OPT_PERSIST_ONLY; }
        | GLOBAL_SYM '.'  { $$=OPT_GLOBAL; }
        | LOCAL_SYM '.'   { $$=OPT_SESSION; }
        | SESSION_SYM '.' { $$=OPT_SESSION; }
         ;

// Option values with preceding option_type.
option_value_following_option_type:
          lvalue_variable equal set_expr_or_default
          {
            $$ = NEW_PTN PT_set_scoped_system_variable(
                @1, $1.prefix, $1.name, $3);
          }
        ;

// Option values without preceding option_type.
option_value_no_option_type:
          lvalue_variable equal set_expr_or_default
          {
            $$ = NEW_PTN PT_set_variable(@1, $1.prefix, $1.name, nullptr, @3, $3);
          }
        | '@' ident_or_text equal expr
          {
            $$= NEW_PTN PT_option_value_no_option_type_user_var($2, $4);
          }
        | '@' '@' opt_set_var_ident_type lvalue_variable equal
          set_expr_or_default
          {
            $$ = NEW_PTN PT_set_system_variable(
                $3, @4, $4.prefix, $4.name, $6);
          }
        | character_set old_or_new_charset_name_or_default
          {
            $$= NEW_PTN PT_option_value_no_option_type_charset($2);
          }
        | NAMES_SYM equal expr
          {
            /*
              Bad syntax, always fails with an error
            */
            $$= NEW_PTN PT_option_value_no_option_type_names(@2);
          }
        | NAMES_SYM charset_name opt_collate
          {
            $$= NEW_PTN PT_set_names($2, $3);
          }
        | NAMES_SYM DEFAULT_SYM
          {
            $$ = NEW_PTN PT_set_names(nullptr, nullptr);
          }
        ;

lvalue_variable:
          lvalue_ident
          {
            $$ = Bipartite_name{{}, to_lex_cstring($1)};
          }
        | lvalue_ident '.' ident
          {
            /*
              Reject names prefixed by `GLOBAL.`, `LOCAL.`, or `SESSION.` --
              if one of those prefixes is there then we are parsing something
              like `GLOBAL.GLOBAL.foo` or `LOCAL.SESSION.bar` etc.
            */
            if (check_reserved_words($1.str)) {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            $$ = Bipartite_name{to_lex_cstring($1), to_lex_cstring($3)};
          }
        | DEFAULT_SYM '.' ident
          {
            $$ = Bipartite_name{{STRING_WITH_LEN("default")}, to_lex_cstring($3)};
          }
        ;

rvalue_system_variable:
          ident_or_text
          {
            $$ = Bipartite_name{{}, to_lex_cstring($1)};
          }
        | ident_or_text '.' ident
          {
            // disallow "SELECT @@global.global.variable"
            if (check_reserved_words($1.str)) {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            $$ = Bipartite_name{to_lex_cstring($1), to_lex_cstring($3)};
          }
        ;

transaction_characteristics:
          transaction_access_mode opt_isolation_level
          {
            $$= NEW_PTN PT_transaction_characteristics($1, $2);
          }
        | isolation_level opt_transaction_access_mode
          {
            $$= NEW_PTN PT_transaction_characteristics($1, $2);
          }
        ;

transaction_access_mode:
          transaction_access_mode_types
          {
            $$= NEW_PTN PT_transaction_access_mode($1);
          }
        ;

opt_transaction_access_mode:
          /* empty */                 { $$= NULL; }
        | ',' transaction_access_mode { $$= $2; }
        ;

isolation_level:
          ISOLATION LEVEL_SYM isolation_types
          {
            $$= NEW_PTN PT_isolation_level($3);
          }
        ;

opt_isolation_level:
          /* empty */         { $$= NULL; }
        | ',' isolation_level { $$= $2; }
        ;

transaction_access_mode_types:
          READ_SYM ONLY_SYM { $$= true; }
        | READ_SYM WRITE_SYM { $$= false; }
        ;

isolation_types:
          READ_SYM UNCOMMITTED_SYM { $$= ISO_READ_UNCOMMITTED; }
        | READ_SYM COMMITTED_SYM   { $$= ISO_READ_COMMITTED; }
        | REPEATABLE_SYM READ_SYM  { $$= ISO_REPEATABLE_READ; }
        | SERIALIZABLE_SYM         { $$= ISO_SERIALIZABLE; }
        ;

set_expr_or_default:
          expr
        | DEFAULT_SYM { $$= NULL; }
        | ON_SYM
          {
            $$= NEW_PTN Item_string(@$, "ON", 2, system_charset_info);
          }
        | ALL
          {
            $$= NEW_PTN Item_string(@$, "ALL", 3, system_charset_info);
          }
        | BINARY_SYM
          {
            $$= NEW_PTN Item_string(@$, "binary", 6, system_charset_info);
          }
        | ROW_SYM
          {
            $$= NEW_PTN Item_string(@$, "ROW", 3, system_charset_info);
          }
        | SYSTEM_SYM
          {
            $$= NEW_PTN Item_string(@$, "SYSTEM", 6, system_charset_info);
          }
        | FORCE_SYM
          {
            $$= NEW_PTN Item_string(@$, "FORCE", 5, system_charset_info);
          }
        ;

/* Lock function */

lock:
          LOCK_SYM lock_variant
          {
            if (Lex->sphead)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), "LOCK");
              MYSQL_YYABORT;
            }
          }
        ;

lock_variant:
        TABLES FOR_SYM BACKUP_SYM
          {
            Lex->sql_command= SQLCOM_LOCK_TABLES_FOR_BACKUP;
          }
        | table_or_tables
          {
            Lex->sql_command= SQLCOM_LOCK_TABLES;
          }
          table_lock_list
          {}
        | INSTANCE_SYM FOR_SYM BACKUP_SYM
          {
            Lex->sql_command= SQLCOM_LOCK_INSTANCE;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_lock_instance();
            if (Lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT; // OOM
          }
        ;

table_or_tables:
          TABLE_SYM
        | TABLES
        ;

table_lock_list:
          table_lock
        | table_lock_list ',' table_lock
        ;

table_lock:
          table_ident opt_table_alias lock_option
          {
            thr_lock_type lock_type= (thr_lock_type) $3;
            enum_mdl_type mdl_lock_type;

            if (lock_type >= TL_WRITE_ALLOW_WRITE)
            {
              /* LOCK TABLE ... WRITE/LOW_PRIORITY WRITE */
              mdl_lock_type= MDL_SHARED_NO_READ_WRITE;
            }
            else if (lock_type == TL_READ)
            {
              /* LOCK TABLE ... READ LOCAL */
              mdl_lock_type= MDL_SHARED_READ;
            }
            else
            {
              /* LOCK TABLE ... READ */
              mdl_lock_type= MDL_SHARED_READ_ONLY;
            }

            if (!Select->add_table_to_list(YYTHD, $1, $2.str, 0, lock_type,
                                           mdl_lock_type))
              MYSQL_YYABORT;
          }
        ;

lock_option:
          READ_SYM               { $$= TL_READ_NO_INSERT; }
        | WRITE_SYM              { $$= TL_WRITE_DEFAULT; }
        | LOW_PRIORITY WRITE_SYM
          {
            $$= TL_WRITE_LOW_PRIORITY;
            push_deprecated_warn(YYTHD, "LOW_PRIORITY WRITE", "WRITE");
          }
        | READ_SYM LOCAL_SYM     { $$= TL_READ; }
        ;

unlock:
          UNLOCK_SYM unlock_variant
          {
            if (Lex->sphead)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), "UNLOCK");
              MYSQL_YYABORT;
            }
          }
	;

unlock_variant:
          INSTANCE_SYM
          {
            Lex->sql_command= SQLCOM_UNLOCK_INSTANCE;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_unlock_instance();
            if (Lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT; // OOM
          }
        | table_or_tables
          {
            Lex->sql_command= SQLCOM_UNLOCK_TABLES;
          }
        ;


shutdown_stmt:
          SHUTDOWN
          {
            Lex->sql_command= SQLCOM_SHUTDOWN;
            $$= NEW_PTN PT_shutdown();
          }
        ;

restart_server_stmt:
          RESTART_SYM
          {
            $$= NEW_PTN PT_restart_server();
          }
        ;

alter_instance_stmt:
          ALTER INSTANCE_SYM alter_instance_action
          {
            Lex->sql_command= SQLCOM_ALTER_INSTANCE;
            $$= $3;
          }

alter_instance_action:
          ROTATE_SYM ident_or_text MASTER_SYM KEY_SYM
          {
            if (is_identifier($2, "INNODB"))
            {
              $$= NEW_PTN PT_alter_instance(ROTATE_INNODB_MASTER_KEY, EMPTY_CSTR);
            }
            else if (is_identifier($2, "BINLOG"))
            {
              $$= NEW_PTN PT_alter_instance(ROTATE_BINLOG_MASTER_KEY, EMPTY_CSTR);
            }
            else
            {
              YYTHD->syntax_error_at(@2);
              MYSQL_YYABORT;
            }
          }
        | RELOAD TLS_SYM
          {
            $$ = NEW_PTN PT_alter_instance(ALTER_INSTANCE_RELOAD_TLS_ROLLBACK_ON_ERROR, to_lex_cstring("mysql_main"));
          }
        | RELOAD TLS_SYM NO_SYM ROLLBACK_SYM ON_SYM ERROR_SYM
          {
            $$ = NEW_PTN PT_alter_instance(ALTER_INSTANCE_RELOAD_TLS, to_lex_cstring("mysql_main"));
          }
        | RELOAD TLS_SYM FOR_SYM CHANNEL_SYM ident {
            $$ = NEW_PTN PT_alter_instance(ALTER_INSTANCE_RELOAD_TLS_ROLLBACK_ON_ERROR, to_lex_cstring($5));
          }
        | RELOAD TLS_SYM FOR_SYM CHANNEL_SYM ident NO_SYM ROLLBACK_SYM ON_SYM ERROR_SYM {
            $$ = NEW_PTN PT_alter_instance(ALTER_INSTANCE_RELOAD_TLS, to_lex_cstring($5));
          }
        | ENABLE_SYM ident ident
          {
            if (!is_identifier($2, "INNODB"))
            {
              YYTHD->syntax_error_at(@2);
              MYSQL_YYABORT;
            }

            if (!is_identifier($3, "REDO_LOG"))
            {
              YYTHD->syntax_error_at(@3);
              MYSQL_YYABORT;
            }
            $$ = NEW_PTN PT_alter_instance(ALTER_INSTANCE_ENABLE_INNODB_REDO, EMPTY_CSTR);
          }
        | DISABLE_SYM ident ident
          {
            if (!is_identifier($2, "INNODB"))
            {
              YYTHD->syntax_error_at(@2);
              MYSQL_YYABORT;
            }

            if (!is_identifier($3, "REDO_LOG"))
            {
              YYTHD->syntax_error_at(@3);
              MYSQL_YYABORT;
            }
            $$ = NEW_PTN PT_alter_instance(ALTER_INSTANCE_DISABLE_INNODB_REDO, EMPTY_CSTR);
          }
        | RELOAD KEYRING_SYM {
            $$ = NEW_PTN PT_alter_instance(RELOAD_KEYRING, EMPTY_CSTR);
          }
        ;

/*
** Handler: direct access to ISAM functions
*/

handler_stmt:
          HANDLER_SYM table_ident OPEN_SYM opt_table_alias
          {
            $$= NEW_PTN PT_handler_open($2, $4);
          }
        | HANDLER_SYM ident CLOSE_SYM
          {
            $$= NEW_PTN PT_handler_close(to_lex_cstring($2));
          }
        | HANDLER_SYM           /* #1 */
          ident                 /* #2 */
          READ_SYM              /* #3 */
          handler_scan_function /* #4 */
          opt_where_clause      /* #5 */
          opt_limit_clause      /* #6 */
          {
            $$= NEW_PTN PT_handler_table_scan(to_lex_cstring($2), $4, $5, $6);
          }
        | HANDLER_SYM           /* #1 */
          ident                 /* #2 */
          READ_SYM              /* #3 */
          ident                 /* #4 */
          handler_rkey_function /* #5 */
          opt_where_clause      /* #6 */
          opt_limit_clause      /* #7 */
          {
            $$= NEW_PTN PT_handler_index_scan(to_lex_cstring($2),
                                              to_lex_cstring($4), $5, $6, $7);
          }
        | HANDLER_SYM           /* #1 */
          ident                 /* #2 */
          READ_SYM              /* #3 */
          ident                 /* #4 */
          handler_rkey_mode     /* #5 */
          '(' values ')'        /* #6,#7,#8 */
          opt_where_clause      /* #9 */
          opt_limit_clause      /* #10 */
          {
            $$= NEW_PTN PT_handler_index_range_scan(to_lex_cstring($2),
                                                    to_lex_cstring($4),
                                                    $5, $7, $9, $10);
          }
        ;

handler_scan_function:
          FIRST_SYM { $$= enum_ha_read_modes::RFIRST; }
        | NEXT_SYM  { $$= enum_ha_read_modes::RNEXT;  }
        ;

handler_rkey_function:
          FIRST_SYM { $$= enum_ha_read_modes::RFIRST; }
        | NEXT_SYM  { $$= enum_ha_read_modes::RNEXT;  }
        | PREV_SYM  { $$= enum_ha_read_modes::RPREV;  }
        | LAST_SYM  { $$= enum_ha_read_modes::RLAST;  }
        ;

handler_rkey_mode:
          EQ     { $$=HA_READ_KEY_EXACT;   }
        | GE     { $$=HA_READ_KEY_OR_NEXT; }
        | LE     { $$=HA_READ_KEY_OR_PREV; }
        | GT_SYM { $$=HA_READ_AFTER_KEY;   }
        | LT     { $$=HA_READ_BEFORE_KEY;  }
        ;

/* GRANT / REVOKE */

revoke:
          REVOKE if_exists role_or_privilege_list FROM user_list opt_ignore_unknown_user
          {
            Lex->grant_if_exists = $2;
            Lex->ignore_unknown_user = $6;
            auto *tmp= NEW_PTN PT_revoke_roles($3, $5);
            MAKE_CMD(tmp);
          }
        | REVOKE if_exists role_or_privilege_list ON_SYM opt_acl_type grant_ident FROM user_list opt_ignore_unknown_user
          {
            LEX *lex= Lex;
            lex->grant_if_exists = $2;
            Lex->ignore_unknown_user = $9;
            if (apply_privileges(YYTHD, *$3))
              MYSQL_YYABORT;
            lex->sql_command= (lex->grant == GLOBAL_ACLS) ? SQLCOM_REVOKE_ALL
                                                          : SQLCOM_REVOKE;
            if ($5 != Acl_type::TABLE && !lex->columns.is_empty())
            {
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            lex->type= static_cast<ulong>($5);
            lex->users_list= *$8;
          }
        | REVOKE if_exists ALL opt_privileges
          {
            Lex->grant_if_exists = $2;
            Lex->all_privileges= 1;
            Lex->grant= GLOBAL_ACLS;
          }
          ON_SYM opt_acl_type grant_ident FROM user_list opt_ignore_unknown_user
          {
            LEX *lex= Lex;
            lex->sql_command= (lex->grant == (GLOBAL_ACLS & ~GRANT_ACL)) ?
                                                            SQLCOM_REVOKE_ALL
                                                          : SQLCOM_REVOKE;
            if ($7 != Acl_type::TABLE && !lex->columns.is_empty())
            {
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            lex->type= static_cast<ulong>($7);
            lex->users_list= *$10;
            lex->ignore_unknown_user = $11;
          }
        | REVOKE if_exists ALL opt_privileges ',' GRANT OPTION FROM user_list opt_ignore_unknown_user
          {
            Lex->grant_if_exists = $2;
            Lex->ignore_unknown_user = $10;
            Lex->sql_command = SQLCOM_REVOKE_ALL;
            Lex->users_list= *$9;
          }
        | REVOKE if_exists PROXY_SYM ON_SYM user FROM user_list opt_ignore_unknown_user
          {
            LEX *lex= Lex;
            lex->grant_if_exists = $2;
            lex->ignore_unknown_user = $8;
            lex->sql_command= SQLCOM_REVOKE;
            lex->users_list= *$7;
            lex->users_list.push_front ($5);
            lex->type= TYPE_ENUM_PROXY;
          }
        ;

grant:
          GRANT role_or_privilege_list TO_SYM user_list opt_with_admin_option
          {
            auto *tmp= NEW_PTN PT_grant_roles($2, $4, $5);
            MAKE_CMD(tmp);
          }
        | GRANT role_or_privilege_list ON_SYM opt_acl_type grant_ident TO_SYM user_list
          grant_options opt_grant_as
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_GRANT;
            if (apply_privileges(YYTHD, *$2))
              MYSQL_YYABORT;

            if ($4 != Acl_type::TABLE && !lex->columns.is_empty())
            {
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            lex->type= static_cast<ulong>($4);
            lex->users_list= *$7;
          }
        | GRANT ALL opt_privileges
          {
            Lex->all_privileges= 1;
            Lex->grant= GLOBAL_ACLS;
          }
          ON_SYM opt_acl_type grant_ident TO_SYM user_list grant_options opt_grant_as
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_GRANT;
            if ($6 != Acl_type::TABLE && !lex->columns.is_empty())
            {
              YYTHD->syntax_error();
              MYSQL_YYABORT;
            }
            lex->type= static_cast<ulong>($6);
            lex->users_list= *$9;
          }
        | GRANT PROXY_SYM ON_SYM user TO_SYM user_list opt_grant_option
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_GRANT;
            if ($7)
              lex->grant |= GRANT_ACL;
            lex->users_list= *$6;
            lex->users_list.push_front ($4);
            lex->type= TYPE_ENUM_PROXY;
          }
        ;

opt_acl_type:
          /* Empty */   { $$= Acl_type::TABLE; }
        | TABLE_SYM     { $$= Acl_type::TABLE; }
        | FUNCTION_SYM  { $$= Acl_type::FUNCTION; }
        | PROCEDURE_SYM { $$= Acl_type::PROCEDURE; }
%ifdef SQL_MODE_ORACLE
        | TYPE_SYM   { $$= Acl_type::TYPE; }
%endif
        ;

opt_privileges:
          /* empty */
        | PRIVILEGES
        ;

role_or_privilege_list:
          role_or_privilege
          {
            $$= NEW_PTN Mem_root_array<PT_role_or_privilege *>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | role_or_privilege_list ',' role_or_privilege
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

role_or_privilege:
          role_ident_or_text opt_column_list
          {
            if ($2 == NULL)
              $$= NEW_PTN PT_role_or_dynamic_privilege(@1, $1);
            else
              $$= NEW_PTN PT_dynamic_privilege(@1, $1);
          }
        | role_ident_or_text '@' ident_or_text
          { $$= NEW_PTN PT_role_at_host(@1, $1, $3); }
        | SELECT_SYM opt_column_list
          { $$= NEW_PTN PT_static_privilege(@1, SELECT_ACL, $2); }
        | INSERT_SYM opt_column_list
          { $$= NEW_PTN PT_static_privilege(@1, INSERT_ACL, $2); }
        | UPDATE_SYM opt_column_list
          { $$= NEW_PTN PT_static_privilege(@1, UPDATE_ACL, $2); }
        | REFERENCES opt_column_list
          { $$= NEW_PTN PT_static_privilege(@1, REFERENCES_ACL, $2); }
        | DELETE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, DELETE_ACL); }
        | USAGE
          { $$= NEW_PTN PT_static_privilege(@1, 0); }
        | INDEX_SYM
          { $$= NEW_PTN PT_static_privilege(@1, INDEX_ACL); }
        | ALTER
          { $$= NEW_PTN PT_static_privilege(@1, ALTER_ACL); }
        | CREATE
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_ACL); }
        | DROP
          { $$= NEW_PTN PT_static_privilege(@1, DROP_ACL); }
        | EXECUTE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, EXECUTE_ACL); }
        | RELOAD
          { $$= NEW_PTN PT_static_privilege(@1, RELOAD_ACL); }
        | SHUTDOWN
          { $$= NEW_PTN PT_static_privilege(@1, SHUTDOWN_ACL); }
        | PROCESS
          { $$= NEW_PTN PT_static_privilege(@1, PROCESS_ACL); }
        | FILE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, FILE_ACL); }
        | GRANT OPTION
          {
            $$= NEW_PTN PT_static_privilege(@1, GRANT_ACL);
            Lex->grant_privilege= true;
          }
        | SHOW DATABASES
          { $$= NEW_PTN PT_static_privilege(@1, SHOW_DB_ACL); }
        | SUPER_SYM
          {
            /* DEPRECATED */
            $$= NEW_PTN PT_static_privilege(@1, SUPER_ACL);
            if (Lex->grant != GLOBAL_ACLS)
            {
              /*
                 An explicit request was made for the SUPER priv id
              */
              push_warning(Lex->thd, Sql_condition::SL_WARNING,
                           ER_WARN_DEPRECATED_SYNTAX,
                           "The SUPER privilege identifier is deprecated");
            }
          }
        | CREATE TEMPORARY TABLES
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_TMP_ACL); }
        | LOCK_SYM TABLES
          { $$= NEW_PTN PT_static_privilege(@1, LOCK_TABLES_ACL); }
        | REPLICATION SLAVE
          { $$= NEW_PTN PT_static_privilege(@1, REPL_SLAVE_ACL); }
        | REPLICATION CLIENT_SYM
          { $$= NEW_PTN PT_static_privilege(@1, REPL_CLIENT_ACL); }
        | CREATE VIEW_SYM
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_VIEW_ACL); }
        | SHOW VIEW_SYM
          { $$= NEW_PTN PT_static_privilege(@1, SHOW_VIEW_ACL); }
        | CREATE ROUTINE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_PROC_ACL); }
        | ALTER ROUTINE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, ALTER_PROC_ACL); }
        | CREATE USER
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_USER_ACL); }
        | EVENT_SYM
          { $$= NEW_PTN PT_static_privilege(@1, EVENT_ACL); }
        | TRIGGER_SYM
          { $$= NEW_PTN PT_static_privilege(@1, TRIGGER_ACL); }
        | CREATE TABLESPACE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_TABLESPACE_ACL); }
        | CREATE ROLE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, CREATE_ROLE_ACL); }
        | DROP ROLE_SYM
          { $$= NEW_PTN PT_static_privilege(@1, DROP_ROLE_ACL); }
        ;

opt_with_admin_option:
          /* empty */           { $$= false; }
        | WITH ADMIN_SYM OPTION { $$= true; }
        ;

opt_and:
          /* empty */
        | AND_SYM
        ;

require_list:
          require_list_element opt_and require_list
        | require_list_element
        ;

require_list_element:
          SUBJECT_SYM TEXT_STRING
          {
            LEX *lex=Lex;
            if (lex->x509_subject)
            {
              my_error(ER_DUP_ARGUMENT, MYF(0), "SUBJECT");
              MYSQL_YYABORT;
            }
            lex->x509_subject=$2.str;
          }
        | ISSUER_SYM TEXT_STRING
          {
            LEX *lex=Lex;
            if (lex->x509_issuer)
            {
              my_error(ER_DUP_ARGUMENT, MYF(0), "ISSUER");
              MYSQL_YYABORT;
            }
            lex->x509_issuer=$2.str;
          }
        | CIPHER_SYM TEXT_STRING
          {
            LEX *lex=Lex;
            if (lex->ssl_cipher)
            {
              my_error(ER_DUP_ARGUMENT, MYF(0), "CIPHER");
              MYSQL_YYABORT;
            }
            lex->ssl_cipher=$2.str;
          }
        ;

grant_ident:
          '*'
          {
            LEX *lex= Lex;
            size_t dummy;
            if (lex->copy_db_to(&lex->current_query_block()->db, &dummy))
              MYSQL_YYABORT;
            if (lex->grant == GLOBAL_ACLS)
              lex->grant = DB_OP_ACLS;
            else if (lex->columns.elements)
            {
              my_error(ER_ILLEGAL_GRANT_FOR_TABLE, MYF(0));
              MYSQL_YYABORT;
            }
          }
        | schema '.' '*'
          {
            LEX *lex= Lex;
            lex->current_query_block()->db = $1.str;
            if (lex->grant == GLOBAL_ACLS)
              lex->grant = DB_OP_ACLS;
            else if (lex->columns.elements)
            {
              my_error(ER_ILLEGAL_GRANT_FOR_TABLE, MYF(0));
              MYSQL_YYABORT;
            }
          }
        | '*' '.' '*'
          {
            LEX *lex= Lex;
            lex->current_query_block()->db = NULL;
            if (lex->grant == GLOBAL_ACLS)
              lex->grant= GLOBAL_ACLS & ~GRANT_ACL;
            else if (lex->columns.elements)
            {
              my_error(ER_ILLEGAL_GRANT_FOR_TABLE, MYF(0));
              MYSQL_YYABORT;
            }
          }
%ifndef SQL_MODE_ORACLE
        | ident
%else
        | sp_decl_ident
%endif
          {
            auto tmp = NEW_PTN Table_ident(to_lex_cstring($1));
            if (tmp == NULL)
              MYSQL_YYABORT;
            LEX *lex=Lex;
            if (!lex->current_query_block()->add_table_to_list(lex->thd, tmp, NULL,
                                                        TL_OPTION_UPDATING))
              MYSQL_YYABORT;
            if (lex->grant == GLOBAL_ACLS)
              lex->grant =  TABLE_OP_ACLS;
          }
        | schema '.' ident
          {
            auto schema_name = YYCLIENT_NO_SCHEMA ? LEX_CSTRING{}
                                                  : to_lex_cstring($1.str);
            auto tmp = NEW_PTN Table_ident(schema_name, to_lex_cstring($3));
            if (tmp == NULL)
              MYSQL_YYABORT;
            LEX *lex=Lex;
            if (!lex->current_query_block()->add_table_to_list(lex->thd, tmp, NULL,
                                                        TL_OPTION_UPDATING))
              MYSQL_YYABORT;
            if (lex->grant == GLOBAL_ACLS)
              lex->grant =  TABLE_OP_ACLS;
          }
        ;

user_list:
          user
          {
            $$= new (YYMEM_ROOT) List<LEX_USER>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | user_list ',' user
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT;
          }
        ;

role_list:
          role
          {
            $$= new (YYMEM_ROOT) List<LEX_USER>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | role_list ',' role
          {
            $$= $1;
            if ($$->push_back($3))
              MYSQL_YYABORT;
          }
        ;

opt_retain_current_password:
          /* empty */   { $$= false; }
        | RETAIN_SYM CURRENT_SYM PASSWORD { $$= true; }
        ;

opt_discard_old_password:
          /* empty */   { $$= false; }
        | DISCARD_SYM OLD_SYM PASSWORD { $$= true; }


opt_user_registration:
          factor INITIATE_SYM REGISTRATION_SYM
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->nth_factor= $1;
            m->init_registration= true;
            m->requires_registration= true;
            $$ = m;
          }
        | factor UNREGISTER_SYM
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->nth_factor= $1;
            m->unregister= true;
            $$ = m;
          }
        | factor FINISH_SYM REGISTRATION_SYM SET_SYM CHALLENGE_RESPONSE_SYM AS TEXT_STRING_hash
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->nth_factor= $1;
            m->finish_registration= true;
            m->requires_registration= true;
            m->challenge_response= to_lex_cstring($7);
            $$ = m;
          }
        ;

create_user:
          user identification opt_create_user_with_mfa
          {
            $$ = $1;
            $$->first_factor_auth_info = *$2;
            if ($$->add_mfa_identifications($3.mfa2, $3.mfa3))
              MYSQL_YYABORT;  // OOM
          }
        | user identified_with_plugin opt_initial_auth
          {
            $$= $1;
            /* set $3 as first factor auth method */
            $3->nth_factor = 1;
            $3->passwordless = false;
            $$->first_factor_auth_info = *$3;
            /* set $2 as second factor auth method */
            $2->nth_factor = 2;
            $2->passwordless = true;
            if ($$->mfa_list.push_back($2))
              MYSQL_YYABORT;  // OOM
            $$->with_initial_auth = true;
          }
        | user opt_create_user_with_mfa
          {
            $$ = $1;
            if ($$->add_mfa_identifications($2.mfa2, $2.mfa3))
              MYSQL_YYABORT;  // OOM
          }
        ;

opt_create_user_with_mfa:
          /* empty */                                   { $$ = {}; }
        | AND_SYM identification
          {
            $2->nth_factor = 2;
            $$ = {$2, nullptr};
          }
        | AND_SYM identification AND_SYM identification
          {
            $2->nth_factor = 2;
            $4->nth_factor = 3;
            $$ = {$2, $4};
          }
        ;

identification:
          identified_by_password
        | identified_by_random_password
        | identified_with_plugin
        | identified_with_plugin_as_auth
        | identified_with_plugin_by_password
        | identified_with_plugin_by_random_password
        ;

identified_by_password:
          IDENTIFIED_SYM BY TEXT_STRING_password
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->auth = to_lex_cstring($3);
            m->uses_identified_by_clause = true;
            $$ = m;
            Lex->contains_plaintext_password= true;
          }
        ;

identified_by_random_password:
          IDENTIFIED_SYM BY RANDOM_SYM PASSWORD
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->auth = EMPTY_CSTR;
            m->has_password_generator = true;
            m->uses_identified_by_clause = true;
            $$ = m;
            Lex->contains_plaintext_password = true;
          }
        ;

identified_with_plugin:
          IDENTIFIED_SYM WITH ident_or_text
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->plugin = to_lex_cstring($3);
            m->auth = EMPTY_CSTR;
            m->uses_identified_by_clause = false;
            m->uses_identified_with_clause = true;
            $$ = m;
          }
        ;

identified_with_plugin_as_auth:
          IDENTIFIED_SYM WITH ident_or_text AS TEXT_STRING_hash
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->plugin = to_lex_cstring($3);
            m->auth = to_lex_cstring($5);
            m->uses_authentication_string_clause = true;
            m->uses_identified_with_clause = true;
            $$ = m;
          }
        ;

identified_with_plugin_by_password:
          IDENTIFIED_SYM WITH ident_or_text BY TEXT_STRING_password
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->plugin = to_lex_cstring($3);
            m->auth = to_lex_cstring($5);
            m->uses_identified_by_clause = true;
            m->uses_identified_with_clause = true;
            $$ = m;
            Lex->contains_plaintext_password= true;
          }
        ;

identified_with_plugin_by_random_password:
          IDENTIFIED_SYM WITH ident_or_text BY RANDOM_SYM PASSWORD
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->plugin = to_lex_cstring($3);
            m->uses_identified_by_clause = true;
            m->uses_identified_with_clause = true;
            m->has_password_generator = true;
            $$ = m;
            Lex->contains_plaintext_password= true;
          }
        ;

opt_initial_auth:
          INITIAL_SYM AUTHENTICATION_SYM identified_by_random_password
           {
            $$ = $3;
            $3->passwordless = true;
            $3->nth_factor = 2;
          }
        | INITIAL_SYM AUTHENTICATION_SYM identified_with_plugin_as_auth
          {
            $$ = $3;
            $3->passwordless = true;
            $3->nth_factor = 2;
          }
        | INITIAL_SYM AUTHENTICATION_SYM identified_by_password
          {
            $$ = $3;
            $3->passwordless = true;
            $3->nth_factor = 2;
          }
        ;

alter_user:
          user identified_by_password
          REPLACE_SYM TEXT_STRING_password
          opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->current_auth = to_lex_cstring($4);
            $1->uses_replace_clause = true;
            $1->discard_old_password = false;
            $1->retain_current_password = $5;
          }
        | user identified_with_plugin_by_password
          REPLACE_SYM TEXT_STRING_password
          opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->current_auth = to_lex_cstring($4);
            $1->uses_replace_clause = true;
            $1->discard_old_password = false;
            $1->retain_current_password = $5;
          }
        | user identified_by_password opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->discard_old_password = false;
            $1->retain_current_password = $3;
          }
        | user identified_by_random_password opt_retain_current_password
           {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->discard_old_password = false;
            $1->retain_current_password = $3;
          }
        | user identified_by_random_password
          REPLACE_SYM TEXT_STRING_password
          opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->uses_replace_clause = true;
            $1->discard_old_password = false;
            $1->retain_current_password = $5;
            $1->current_auth = to_lex_cstring($4);
          }
        | user identified_with_plugin
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->discard_old_password = false;
            $1->retain_current_password = false;
          }
        | user identified_with_plugin_as_auth opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->discard_old_password = false;
            $1->retain_current_password = $3;
          }
        | user identified_with_plugin_by_password opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->discard_old_password = false;
            $1->retain_current_password = $3;
          }
        | user identified_with_plugin_by_random_password
          opt_retain_current_password
          {
            $$ = $1;
            $1->first_factor_auth_info = *$2;
            $1->discard_old_password= false;
            $1->retain_current_password= $3;
          }
        | user opt_discard_old_password
          {
            $$ = $1;
            $1->discard_old_password = $2;
            $1->retain_current_password = false;
          }
        | user ADD factor identification
          {
            $4->nth_factor = $3;
            $4->add_factor = true;
            if ($1->add_mfa_identifications($4))
              MYSQL_YYABORT;  // OOM
            $$ = $1;
           }
        | user ADD factor identification ADD factor identification
          {
            if ($3 == $6) {
              my_error(ER_MFA_METHODS_IDENTICAL, MYF(0));
              MYSQL_YYABORT;
            } else if ($3 > $6) {
              my_error(ER_MFA_METHODS_INVALID_ORDER, MYF(0), $6, $3);
              MYSQL_YYABORT;
            }
            $4->nth_factor = $3;
            $4->add_factor = true;
            $7->nth_factor = $6;
            $7->add_factor = true;
            if ($1->add_mfa_identifications($4, $7))
              MYSQL_YYABORT;  // OOM
            $$ = $1;
          }
        | user MODIFY_SYM factor identification
          {
            $4->nth_factor = $3;
            $4->modify_factor = true;
            if ($1->add_mfa_identifications($4))
              MYSQL_YYABORT;  // OOM
            $$ = $1;
           }
        | user MODIFY_SYM factor identification MODIFY_SYM factor identification
          {
            if ($3 == $6) {
              my_error(ER_MFA_METHODS_IDENTICAL, MYF(0));
              MYSQL_YYABORT;
            }
            $4->nth_factor = $3;
            $4->modify_factor = true;
            $7->nth_factor = $6;
            $7->modify_factor = true;
            if ($1->add_mfa_identifications($4, $7))
              MYSQL_YYABORT;  // OOM
            $$ = $1;
          }
        | user DROP factor
          {
            LEX_MFA *m = NEW_PTN LEX_MFA;
            if (m == nullptr)
              MYSQL_YYABORT;  // OOM
            m->nth_factor = $3;
            m->drop_factor = true;
            if ($1->add_mfa_identifications(m))
              MYSQL_YYABORT;  // OOM
            $$ = $1;
           }
        | user DROP factor DROP factor
          {
            if ($3 == $5) {
              my_error(ER_MFA_METHODS_IDENTICAL, MYF(0));
              MYSQL_YYABORT;
            }
            LEX_MFA *m1 = NEW_PTN LEX_MFA;
            if (m1 == nullptr)
              MYSQL_YYABORT;  // OOM
            m1->nth_factor = $3;
            m1->drop_factor = true;
            LEX_MFA *m2 = NEW_PTN LEX_MFA;
            if (m2 == nullptr)
              MYSQL_YYABORT;  // OOM
            m2->nth_factor = $5;
            m2->drop_factor = true;
            if ($1->add_mfa_identifications(m1, m2))
              MYSQL_YYABORT;  // OOM
            $$ = $1;
           }
         ;

factor:
          NUM FACTOR_SYM
          {
            if (my_strcasecmp(system_charset_info, $1.str, "2") == 0) {
              $$ = 2;
            } else if (my_strcasecmp(system_charset_info, $1.str, "3") == 0) {
              $$ = 3;
            } else {
               my_error(ER_WRONG_VALUE, MYF(0), "nth factor", $1.str);
               MYSQL_YYABORT;
            }
          }
        ;

create_user_list:
          create_user
          {
            if (Lex->users_list.push_back($1))
              MYSQL_YYABORT;
          }
        | create_user_list ',' create_user
          {
            if (Lex->users_list.push_back($3))
              MYSQL_YYABORT;
          }
        ;

alter_user_list:
       alter_user
         {
            if (Lex->users_list.push_back($1))
              MYSQL_YYABORT;
         }
       | alter_user_list ',' alter_user
          {
            if (Lex->users_list.push_back($3))
              MYSQL_YYABORT;
          }
        ;

opt_column_list:
          /* empty */        { $$= NULL; }
        | '(' column_list ')' { $$= $2; }
        ;

column_list:
          ident
          {
            $$= NEW_PTN Mem_root_array<LEX_CSTRING>(YYMEM_ROOT);
            if ($$ == NULL || $$->push_back(to_lex_cstring($1)))
              MYSQL_YYABORT; // OOM
          }
        | column_list ',' ident
          {
            $$= $1;
            if ($$->push_back(to_lex_cstring($3)))
              MYSQL_YYABORT; // OOM
          }
        ;

require_clause:
          /* empty */
        | REQUIRE_SYM require_list
          {
            Lex->ssl_type=SSL_TYPE_SPECIFIED;
          }
        | REQUIRE_SYM SSL_SYM
          {
            Lex->ssl_type=SSL_TYPE_ANY;
          }
        | REQUIRE_SYM X509_SYM
          {
            Lex->ssl_type=SSL_TYPE_X509;
          }
        | REQUIRE_SYM NONE_SYM
          {
            Lex->ssl_type=SSL_TYPE_NONE;
          }
        ;

grant_options:
          /* empty */ {}
        | WITH GRANT OPTION
          { Lex->grant |= GRANT_ACL;}
        ;

opt_grant_option:
          /* empty */       { $$= false; }
        | WITH GRANT OPTION { $$= true; }
        ;
opt_with_roles:
          /* empty */
          { Lex->grant_as.role_type = role_enum::ROLE_NONE; }
        | WITH ROLE_SYM role_list
          { Lex->grant_as.role_type = role_enum::ROLE_NAME;
            Lex->grant_as.role_list = $3;
          }
        | WITH ROLE_SYM ALL opt_except_role_list
          {
            Lex->grant_as.role_type = role_enum::ROLE_ALL;
            Lex->grant_as.role_list = $4;
          }
        | WITH ROLE_SYM NONE_SYM
          { Lex->grant_as.role_type = role_enum::ROLE_NONE; }
        | WITH ROLE_SYM DEFAULT_SYM
          { Lex->grant_as.role_type = role_enum::ROLE_DEFAULT; }

opt_grant_as:
          /* empty */
          { Lex->grant_as.grant_as_used = false; }
        | AS user opt_with_roles
          {
            Lex->grant_as.grant_as_used = true;
            Lex->grant_as.user = $2;
          }

begin_stmt:
          BEGIN_SYM
          {
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_BEGIN;
            lex->start_transaction_opt= 0;
          }
        | BEGIN_WORK_SYM
          {
            LEX *lex=Lex;
            lex->sql_command = SQLCOM_BEGIN;
            lex->start_transaction_opt= 0;
          }
        ;

opt_work:
          /* empty */ {}
        | WORK_SYM  {}
        ;

opt_chain:
          /* empty */
          { $$= TVL_UNKNOWN; }
        | AND_SYM NO_SYM CHAIN_SYM { $$= TVL_NO; }
        | AND_SYM CHAIN_SYM        { $$= TVL_YES; }
        ;

opt_release:
          /* empty */
          { $$= TVL_UNKNOWN; }
        | RELEASE_SYM        { $$= TVL_YES; }
        | NO_SYM RELEASE_SYM { $$= TVL_NO; }
;

opt_savepoint:
          /* empty */ {}
        | SAVEPOINT_SYM {}
        ;

commit:
          COMMIT_SYM opt_work opt_chain opt_release
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_COMMIT;
            /* Don't allow AND CHAIN RELEASE. */
            MYSQL_YYABORT_UNLESS($3 != TVL_YES || $4 != TVL_YES);
            lex->tx_chain= $3;
            lex->tx_release= $4;
          }
        ;

rollback:
          ROLLBACK_SYM opt_work opt_chain opt_release
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_ROLLBACK;
            /* Don't allow AND CHAIN RELEASE. */
            MYSQL_YYABORT_UNLESS($3 != TVL_YES || $4 != TVL_YES);
            lex->tx_chain= $3;
            lex->tx_release= $4;
          }
        | ROLLBACK_SYM opt_work
          TO_SYM opt_savepoint ident
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_ROLLBACK_TO_SAVEPOINT;
            lex->ident= $5;
          }
        ;

savepoint:
          SAVEPOINT_SYM ident
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_SAVEPOINT;
            lex->ident= $2;
          }
        ;

release:
          RELEASE_SYM SAVEPOINT_SYM ident
          {
            LEX *lex=Lex;
            lex->sql_command= SQLCOM_RELEASE_SAVEPOINT;
            lex->ident= $3;
          }
        ;

/*
   UNIONS : glue selects together
*/


union_option:
          /* empty */ { $$=1; }
        | DISTINCT  { $$=1; }
        | ALL       { $$=0; }
        ;

row_subquery:
          subquery
        ;

table_subquery:
          subquery
        ;

subquery:
          query_expression_parens %prec SUBQUERY_AS_EXPR
          {
            $$= NEW_PTN PT_subquery(@$, $1);
          }
        ;

query_spec_option:
          STRAIGHT_JOIN       { $$= SELECT_STRAIGHT_JOIN; }
        | HIGH_PRIORITY       { $$= SELECT_HIGH_PRIORITY; }
        | DISTINCT            { $$= SELECT_DISTINCT; }
        | SQL_SMALL_RESULT    { $$= SELECT_SMALL_RESULT; }
        | SQL_BIG_RESULT      { $$= SELECT_BIG_RESULT; }
        | SQL_BUFFER_RESULT   { $$= OPTION_BUFFER_RESULT; }
        | SQL_CALC_FOUND_ROWS {
            push_warning(YYTHD, Sql_condition::SL_WARNING,
                         ER_WARN_DEPRECATED_SYNTAX,
                         ER_THD(YYTHD, ER_WARN_DEPRECATED_SQL_CALC_FOUND_ROWS));
            $$= OPTION_FOUND_ROWS;
          }
        | ALL                 { $$= SELECT_ALL; }
        ;

/**************************************************************************

 CREATE VIEW | TRIGGER | PROCEDURE statements.

**************************************************************************/

init_lex_create_info:
          /* empty */
          {
            // Initialize context for 'CREATE view_or_trigger_or_sp_or_event'
            Lex->create_info= YYTHD->alloc_typed<HA_CREATE_INFO>();
            if (Lex->create_info == NULL)
              MYSQL_YYABORT; // OOM
          }
        ;

view_or_trigger_or_sp_or_event:
          definer init_lex_create_info definer_tail
          {}
        | no_definer init_lex_create_info no_definer_tail
          {}
        | view_algorithm definer_opt init_lex_create_info view_tail
          {}
        | or_replace view_algorithm definer_opt init_lex_create_info view_tail
          { Lex->create_view_mode= enum_view_create_mode::VIEW_CREATE_OR_REPLACE; }
        | or_replace no_definer init_lex_create_info routine_no_definer_tail
          { Lex->create_sp_mode= enum_sp_create_mode::SP_CREATE_OR_REPLACE; }
        | or_replace definer init_lex_create_info routine_definer_tail
          { Lex->create_sp_mode= enum_sp_create_mode::SP_CREATE_OR_REPLACE; }
        | or_replace definer_opt init_lex_create_info view_tail
          { Lex->create_view_mode= enum_view_create_mode::VIEW_CREATE_OR_REPLACE; }
        | FORCE_SYM definer init_lex_create_info view_tail
          { Lex->create_force_view_mode = true; }
        | FORCE_SYM no_definer init_lex_create_info view_tail
          { Lex->create_force_view_mode = true; }
        | or_replace FORCE_SYM definer_opt init_lex_create_info view_tail
          { Lex->create_view_mode= enum_view_create_mode::VIEW_CREATE_OR_REPLACE;
            Lex->create_force_view_mode = true;
          }
        | or_replace definer_opt init_lex_create_info trigger_tail
          {
            if(Lex->create_info->options & HA_LEX_CREATE_IF_NOT_EXISTS)
            {
              my_error(ER_NOT_SUPPORTED_YET,MYF(0),"USING 'OR REPLACE' together with 'IF NOT EXISTS'");
              MYSQL_YYABORT;
            }
            Lex->create_sp_mode= enum_sp_create_mode::SP_CREATE_OR_REPLACE;
          }
        ;

definer_tail:
          view_tail
        | trigger_tail
        | sp_tail
        | sf_tail
        | event_tail
%ifdef SQL_MODE_ORACLE
        | type_tail
%endif
        ;

no_definer_tail:
          view_tail
        | trigger_tail
        | sp_tail
        | sf_tail
        | udf_tail
        | event_tail
%ifdef SQL_MODE_ORACLE
        | type_tail
%endif
        ;

routine_definer_tail:
          sp_tail
        | sf_tail
%ifdef SQL_MODE_ORACLE
        | type_tail
%endif
        ;

routine_no_definer_tail:
          sp_tail
        | sf_tail
        | udf_tail
%ifdef SQL_MODE_ORACLE
        | type_tail
%endif
        ;

/**************************************************************************

 DEFINER clause support.

**************************************************************************/

definer_opt:
          no_definer
        | definer
        ;

no_definer:
          /* empty */
          {
            /*
              We have to distinguish missing DEFINER-clause from case when
              CURRENT_USER specified as definer explicitly in order to properly
              handle CREATE TRIGGER statements which come to replication thread
              from older master servers (i.e. to create non-suid trigger in this
              case).
            */
            YYTHD->lex->definer= 0;
          }
        ;

definer:
          DEFINER_SYM EQ user
          {
            YYTHD->lex->definer= get_current_user(YYTHD, $3);
          }
        ;

/**************************************************************************

 CREATE VIEW statement parts.

**************************************************************************/

view_algorithm:
          ALGORITHM_SYM EQ UNDEFINED_SYM
          { Lex->create_view_algorithm= VIEW_ALGORITHM_UNDEFINED; }
        | ALGORITHM_SYM EQ MERGE_SYM
          { Lex->create_view_algorithm= VIEW_ALGORITHM_MERGE; }
        | ALGORITHM_SYM EQ TEMPTABLE_SYM
          { Lex->create_view_algorithm= VIEW_ALGORITHM_TEMPTABLE; }
        ;

view_suid:
          /* empty */
          { Lex->create_view_suid= VIEW_SUID_DEFAULT; }
        | SQL_SYM SECURITY_SYM DEFINER_SYM
          { Lex->create_view_suid= VIEW_SUID_DEFINER; }
        | SQL_SYM SECURITY_SYM INVOKER_SYM
          { Lex->create_view_suid= VIEW_SUID_INVOKER; }
        ;

view_tail:
          view_suid VIEW_SYM table_ident opt_derived_column_list
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->sql_command= SQLCOM_CREATE_VIEW;
            /* first table in list is target VIEW name */
            if (!lex->query_block->add_table_to_list(thd, $3, NULL,
                                                    TL_OPTION_UPDATING,
                                                    TL_IGNORE,
                                                    MDL_EXCLUSIVE))
              MYSQL_YYABORT;
            lex->query_tables->open_strategy= Table_ref::OPEN_STUB;
            thd->parsing_system_view= lex->query_tables->is_system_view;
            if ($4.size())
            {
              for (auto column_alias : $4)
              {
                // Report error if the column name/length is incorrect.
                if (check_column_name(column_alias.str))
                {
                  my_error(ER_WRONG_COLUMN_NAME, MYF(0), column_alias.str);
                  MYSQL_YYABORT;
                }
              }
              /*
                The $4 object is short-lived (its 'm_array' is not);
                so we have to duplicate it, and then we can store a
                pointer.
              */
              void *rawmem= thd->memdup(&($4), sizeof($4));
              if (!rawmem)
                MYSQL_YYABORT; /* purecov: inspected */
              lex->query_tables->
                set_derived_column_names(static_cast<Create_col_name_list* >(rawmem));
            }
          }
          AS view_query_block
        ;

view_query_block:
          query_expression_with_opt_locking_clauses view_check_option
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            lex->parsing_options.allows_variable= false;
            lex->parsing_options.allows_select_into= false;

            /*
              In CREATE VIEW v ... the m_table_list initially contains
              here a table entry for the destination "table" `v'.
              Backup it and clean the table list for the processing of
              the query expression and push `v' back to the beginning of the
              m_table_list finally.

              @todo: Don't save the CREATE destination table in
                     Query_block::m_table_list and remove this backup & restore.

              The following work only with the local list, the global list
              is created correctly in this case
            */
            SQL_I_List<Table_ref> save_list;
            Query_block * const save_query_block= Select;
            save_query_block->m_table_list.save_and_clear(&save_list);

            CONTEXTUALIZE_VIEW($1);

            /*
              The following work only with the local list, the global list
              is created correctly in this case
            */
            save_query_block->m_table_list.push_front(&save_list);

            Lex->create_view_check= $2;

            /*
              It's simpler to use @$ to grab the whole rule text, OTOH  it's
              also simple to lose something that way when changing this rule,
              so let use explicit @1 and @2 to memdup this view definition:
            */
            const size_t len= @2.cpp.end - @1.cpp.start;
            lex->create_view_query_block.str=
              static_cast<char *>(thd->memdup(@1.cpp.start, len));
            lex->create_view_query_block.length= len;
            trim_whitespace(thd->charset(), &lex->create_view_query_block);

            lex->parsing_options.allows_variable= true;
            lex->parsing_options.allows_select_into= true;
          }
        ;

view_check_option:
          /* empty */                     { $$= VIEW_CHECK_NONE; }
        | WITH CHECK_SYM OPTION           { $$= VIEW_CHECK_CASCADED; }
        | WITH CASCADED CHECK_SYM OPTION  { $$= VIEW_CHECK_CASCADED; }
        | WITH LOCAL_SYM CHECK_SYM OPTION { $$= VIEW_CHECK_LOCAL; }
        ;

/**************************************************************************

 CREATE TRIGGER statement parts.

**************************************************************************/

trigger_action_order:
            FOLLOWS_SYM
            { $$= TRG_ORDER_FOLLOWS; }
          | PRECEDES_SYM
            { $$= TRG_ORDER_PRECEDES; }
          ;

trigger_follows_precedes_clause:
            /* empty */
            {
              $$.ordering_clause= TRG_ORDER_NONE;
              $$.anchor_trigger_name= NULL_CSTR;
            }
          |
            trigger_action_order ident_or_text
            {
              $$.ordering_clause= $1;
              $$.anchor_trigger_name= { $2.str, $2.length };
            }
          ;

trigger_tail:
          TRIGGER_SYM                     /* $1 */
          opt_if_not_exists               /* $2 */
          sp_name                         /* $3 */
          trg_action_time                 /* $4 */
          trg_or_event                    /* $5 */
          ON_SYM                          /* $6 */
          table_ident                     /* $7 */
          FOR_SYM                         /* $8 */
          EACH_SYM                        /* $9 */
          ROW_SYM                         /* $10 */
          trigger_follows_precedes_clause /* $11 */
          {                               /* $12 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_RECURSIVE_CREATE, MYF(0), "TRIGGER");
              MYSQL_YYABORT;
            }

            sp_head *sp= sp_start_parsing(thd, enum_sp_type::TRIGGER, $3);

            if (!sp)
              MYSQL_YYABORT;

            sp->m_trg_chistics.action_time= (enum enum_trigger_action_time_type) $4;
            sp->m_trg_chistics.event= (enum enum_trigger_event_type) $5;
            sp->m_trg_chistics.ordering_clause= $11.ordering_clause;
            sp->m_trg_chistics.anchor_trigger_name= $11.anchor_trigger_name;

            lex->stmt_definition_begin= @1.cpp.start;
            lex->create_info->options= $2 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
            lex->ident.str= const_cast<char *>(@7.cpp.start);
            lex->ident.length= @9.cpp.start - @7.cpp.start;

            lex->sphead= sp;
            lex->spname= $3;

            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
            sp->m_chistics= &lex->sp_chistics;
            sp->set_body_start(thd, @11.cpp.end);
          }
          sp_proc_stmt                    /* $13 */
          {                               /* $14 */
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            sp_finish_parsing(thd);

            lex->sql_command= SQLCOM_CREATE_TRIGGER;

            if (sp->is_not_allowed_in_function("trigger"))
              MYSQL_YYABORT;

            /*
              We have to do it after parsing trigger body, because some of
              sp_proc_stmt alternatives are not saving/restoring LEX, so
              lex->query_tables can be wiped out.
            */
            if (!lex->query_block->add_table_to_list(thd, $7,
                                                    nullptr,
                                                    TL_OPTION_UPDATING,
                                                    TL_READ_NO_INSERT,
                                                    MDL_SHARED_NO_WRITE))
              MYSQL_YYABORT;

            Lex->m_sql_cmd= new (YYTHD->mem_root) Sql_cmd_create_trigger();
          }
        ;

%ifdef SQL_MODE_ORACLE

type_tail:
          TYPE_SYM /* $1 */
          sp_name /* $2 */
          {                     /*$3*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
          sp_tail_is /* $4 */
          {          /* $5 */
            THD *thd= YYTHD;
            sp_ora_type *type = nullptr;
            if (!(type= sp_start_type_parsing(thd,
                                                 enum_sp_type::TYPE,
                                                 $2)))
              MYSQL_YYABORT;
            thd->lex->sql_command= SQLCOM_CREATE_TYPE;
            thd->lex->sphead= type;
          }
          type_object
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            if(sp->check_for_type_table())
              MYSQL_YYABORT;
          }
        ;

type_object:
          OBJECT_SYM /* $1 */
          '('        /*$2*/
          {          /*$3*/
            Lex->sphead->m_parser_data.set_parameter_start_ptr(@2.cpp.end);
          }
          type_pdparam_list       /*$4*/
          ')'                   /*$5*/
          sp_c_chistics /* $6 */
          {   /* $7 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp->m_chistics= &Lex->sp_chistics;
            if(sp->m_chistics && sp->m_chistics->comment.str) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),"create type with comment");
              MYSQL_YYABORT;
            }
            sp->m_parser_data.set_parameter_end_ptr(@5.cpp.start);
            sp->set_body_start(thd, yylloc.cpp.end);
            sp_finish_parsing(thd);
          }
        | udt_table_type /* $1 */
          OF_SYM udt_sp_name
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp->m_chistics= &Lex->sp_chistics;
            sp->type= $1->type;
            sp->size_limit= $1->size_limit;
            sp->udt_table_db = to_lex_string($3->m_db);
            sp->nested_table_udt= $3->m_name;
            sp->m_parser_data.set_parameter_start_ptr(@3.cpp.end);
            sp->m_parser_data.set_parameter_end_ptr(@3.cpp.end);
            sp->set_body_start(thd, yylloc.cpp.end);
            sp_finish_parsing(thd);
          }
        | udt_table_type /* $1 */
          OF_SYM type
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp->m_chistics= &Lex->sp_chistics;
            sp->type= $1->type;
            sp->size_limit= $1->size_limit;
            // make variable
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            LEX_STRING id= to_lex_string(to_lex_cstring("column_value"));
            CONTEXTUALIZE($3);
            enum_field_types field_type= $3->type;
            sp_variable *spvar= pctx->add_variable(thd, id, field_type,
                                                   sp_variable::MODE_IN);

            if (spvar->field_def.init(thd, "", field_type,
                                      $3->get_length(), $3->get_dec(),
                                      $3->get_type_flags(),
                                      NULL, NULL, &NULL_CSTR, 0,
                                      $3->get_interval_list(),
                                      thd->variables.collation_database,
                                      false, $3->get_uint_geom_type(), nullptr,
                                      nullptr, nullptr, {},
                                      dd::Column::enum_hidden_type::HT_VISIBLE))
            {
              MYSQL_YYABORT;
            }

            if (prepare_sp_create_field(thd,
                                        &spvar->field_def))
            {
              MYSQL_YYABORT;
            }
            spvar->field_def.field_name= spvar->name.str;
            spvar->field_def.is_nullable= true;

            sp->m_parser_data.set_parameter_start_ptr(@2.cpp.end);
            sp->m_parser_data.set_parameter_end_ptr(@3.cpp.end);
            sp->set_body_start(thd, yylloc.cpp.end);
            sp_finish_parsing(thd);
          }
        ;

udt_table_type:
          VARRAY_SYM '(' int64_literal ')'
          {
            Item_int *item = dynamic_cast<Item_int *>($3);
            $$= NEW_PTN Udt_table_type(enum_udt_table_of_type::TYPE_VARRAY, item->value);
          }
        | TABLE_SYM { $$= NEW_PTN Udt_table_type(enum_udt_table_of_type::TYPE_TABLE, 0); }
        ;

udt_sp_name:
          ident '.' IDENT_sys
          {
            if (!$1.str ||
                (check_and_convert_db_name(&$1, false) != Ident_name_check::OK))
              MYSQL_YYABORT;
            if (sp_check_name(&$3))
            {
              MYSQL_YYABORT;
            }
            $$= new (YYMEM_ROOT) sp_name(to_lex_cstring($1), $3, true);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->init_qname(YYTHD);
          }
        | IDENT_sys
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            LEX_CSTRING db;
            if (sp_check_name(&$1))
            {
              MYSQL_YYABORT;
            }
            if (lex->copy_db_to(&db.str, &db.length))
              MYSQL_YYABORT;
            $$= new (YYMEM_ROOT) sp_name(db, $1, false);
            if ($$ == NULL)
              MYSQL_YYABORT;
            $$->init_qname(thd);
          }
        ;

/* Stored TYPE parameter declaration list */
type_pdparam_list:
          type_pdparams
          {
            $$= $1;
          }
        ;

type_pdparams:
          type_pdparams ',' type_pdparam
          {
            if (($$= $1)->append_uniq(YYMEM_ROOT, $3))
              MYSQL_YYABORT;
          }
        | type_pdparam
          {
            if (!($$= Row_definition_list::make(YYMEM_ROOT, $1)))
              MYSQL_YYABORT;
          }
        ;

type_pdparam:
          type_pdparam_def
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_variable *spvar = pctx->get_last_context_variable();

            if (!spvar)
              MYSQL_YYABORT;
            spvar->field_def.field_name= spvar->name.str;
            $$= &spvar->field_def;
          }
        ;

type_pdparam_def:
          ident type opt_collate
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            LEX_STRING *id= &$1;
            if (sp_check_name(id))
              MYSQL_YYABORT;

            if (pctx->find_variable(id->str, id->length, true))
            {
              my_error(ER_SP_DUP_PARAM, MYF(0), id->str);
              MYSQL_YYABORT;
            }

            CONTEXTUALIZE($2);
            enum_field_types field_type= $2->type;
            if(field_type == enum_field_types::MYSQL_TYPE_TINY_BLOB ||
                field_type == enum_field_types::MYSQL_TYPE_MEDIUM_BLOB ||
                field_type == enum_field_types::MYSQL_TYPE_LONG_BLOB ||
                field_type == enum_field_types::MYSQL_TYPE_BLOB ||
                field_type == enum_field_types::MYSQL_TYPE_GEOMETRY ||
                field_type == enum_field_types::MYSQL_TYPE_JSON) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0), "udf type with Blob type");
              MYSQL_YYABORT;
            }
            const CHARSET_INFO *cs= $2->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $3, &cs))
              MYSQL_YYABORT;

            sp_variable *spvar= pctx->add_variable(thd,
                                                   *id,
                                                   field_type,
                                                   sp_variable::MODE_IN);

            if (spvar->field_def.init(thd, "", field_type,
                                      $2->get_length(), $2->get_dec(),
                                      $2->get_type_flags(),
                                      NULL, NULL, &NULL_CSTR, 0,
                                      $2->get_interval_list(),
                                      cs ? cs : thd->variables.collation_database,
                                      $3 != nullptr, $2->get_uint_geom_type(), nullptr,
                                      nullptr, nullptr, {},
                                      dd::Column::enum_hidden_type::HT_VISIBLE))
            {
              MYSQL_YYABORT;
            }

            if (prepare_sp_create_field(thd,
                                        &spvar->field_def))
            {
              MYSQL_YYABORT;
            }
            spvar->field_def.field_name= spvar->name.str;
            spvar->field_def.is_nullable= true;
          }
        ;

opt_routine_end_name:
          // Empty
          { $$= NULL_STR; }
        | ident
          { $$= $1; }
        ;
%endif

%ifndef SQL_MODE_ORACLE
/**************************************************************************

 CREATE FUNCTION | PROCEDURE statements parts.

**************************************************************************/

udf_tail:
          AGGREGATE_SYM         /* $1 */
          FUNCTION_SYM          /* $2 */
          opt_if_not_exists     /* $3 */
          ident                 /* $4 */
          RETURNS_SYM           /* $5 */
          udf_type              /* $6 */
          SONAME_SYM            /* $7 */
          TEXT_STRING_sys       /* $8 */
          {                     /* $9 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            if (is_native_function($4))
            {
              if($3)
              {
                /*
                  IF NOT EXISTS clause is unsupported when creating a UDF with
                  the same name as a native function
                */
                my_error(ER_IF_NOT_EXISTS_UNSUPPORTED_UDF_NATIVE_FCT_NAME_COLLISION, MYF(0), $4.str);
              }
              else
                my_error(ER_NATIVE_FCT_NAME_COLLISION, MYF(0), $4.str);
              MYSQL_YYABORT;
            }
            lex->sql_command = SQLCOM_CREATE_FUNCTION;
            lex->udf.type= UDFTYPE_AGGREGATE;
            lex->stmt_definition_begin= @2.cpp.start;
            lex->create_info->options= $3 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
            lex->udf.name = $4;
            lex->udf.returns=(Item_result) $6;
            lex->udf.dl=$8.str;
          }
        | FUNCTION_SYM          /* $1 */
          opt_if_not_exists     /* $2 */
          ident                 /* $3 */
          RETURNS_SYM           /* $4 */
          udf_type              /* $5 */
          SONAME_SYM            /* $6 */
          TEXT_STRING_sys       /* $7 */
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            if (is_native_function($3))
            {
              if($2)
              {
                /*
                  IF NOT EXISTS clause is unsupported when creating a UDF with
                  the same name as a native function
                */
                my_error(ER_IF_NOT_EXISTS_UNSUPPORTED_UDF_NATIVE_FCT_NAME_COLLISION, MYF(0), $3.str);
              }
              else
                my_error(ER_NATIVE_FCT_NAME_COLLISION, MYF(0), $3.str);
              MYSQL_YYABORT;
            }
            lex->sql_command = SQLCOM_CREATE_FUNCTION;
            lex->udf.type= UDFTYPE_FUNCTION;
            lex->stmt_definition_begin= @1.cpp.start;
            lex->create_info->options= $2 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
            lex->udf.name = $3;
            lex->udf.returns=(Item_result) $5;
            lex->udf.dl=$7.str;
          }
        ;

sf_tail:
          FUNCTION_SYM          /* $1 */
          opt_if_not_exists     /* $2 */
          sp_name               /* $3 */
          '('                   /* $4 */
          {                     /* $5 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->stmt_definition_begin= @1.cpp.start;
            lex->spname= $3;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_RECURSIVE_CREATE, MYF(0), "FUNCTION");
              MYSQL_YYABORT;
            }


            sp_head *sp= sp_start_parsing(thd, enum_sp_type::FUNCTION, lex->spname);

            if (!sp)
              MYSQL_YYABORT;

            lex->sphead= sp;
            if (lex->create_info)
              lex->create_info->options= $2 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;

            sp->m_parser_data.set_parameter_start_ptr(@4.cpp.end);
          }
          sp_fdparam_list       /* $6 */
          ')'                   /* $7 */
          {                     /* $8 */
            Lex->sphead->m_parser_data.set_parameter_end_ptr(@7.cpp.start);
          }
          RETURNS_SYM           /* $9 */
          type                  /* $10 */
          opt_collate           /* $11 */
          {                     /* $12 */
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            CONTEXTUALIZE($10);
            enum_field_types field_type= $10->type;
            const CHARSET_INFO *cs= $10->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $11, &cs))
              MYSQL_YYABORT;

            /*
              This was disabled in 5.1.12. See bug #20701
              When collation support in SP is implemented, then this test
              should be removed.
            */
            if ((field_type == MYSQL_TYPE_STRING || field_type == MYSQL_TYPE_VARCHAR)
                && ($10->get_type_flags() & BINCMP_FLAG))
            {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0), "return value collation");
              MYSQL_YYABORT;
            }

            if (sp->m_return_field_def.init(YYTHD, "", field_type,
                                            $10->get_length(), $10->get_dec(),
                                            $10->get_type_flags(), NULL, NULL, &NULL_CSTR, 0,
                                            $10->get_interval_list(),
                                            cs ? cs : YYTHD->variables.collation_database,
                                            $11 != nullptr, $10->get_uint_geom_type(), nullptr,
                                            nullptr, nullptr, {},
                                            dd::Column::enum_hidden_type::HT_VISIBLE))
            {
              MYSQL_YYABORT;
            }

            if (prepare_sp_create_field(YYTHD,
                                        &sp->m_return_field_def))
              MYSQL_YYABORT;

            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
          sp_c_chistics         /* $13 */
          {                     /* $14 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sphead->m_chistics= &lex->sp_chistics;
            lex->sphead->set_body_start(thd, yylloc.cpp.start);
          }
          sp_proc_stmt          /* $15 */
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            if (sp->is_not_allowed_in_function("function"))
              MYSQL_YYABORT;

            sp_finish_parsing(thd);

            lex->sql_command= SQLCOM_CREATE_SPFUNCTION;

            if (!(sp->m_flags & sp_head::HAS_RETURN))
            {
              my_error(ER_SP_NORETURN, MYF(0), sp->m_qname.str);
              MYSQL_YYABORT;
            }

            if (is_native_function(sp->m_name))
            {
              /*
                This warning will be printed when
                [1] A client query is parsed,
                [2] A stored function is loaded by db_load_routine.
                Printing the warning for [2] is intentional, to cover the
                following scenario:
                - A user define a SF 'foo' using MySQL 5.N
                - An application uses select foo(), and works.
                - MySQL 5.{N+1} defines a new native function 'foo', as
                part of a new feature.
                - MySQL 5.{N+1} documentation is updated, and should mention
                that there is a potential incompatible change in case of
                existing stored function named 'foo'.
                - The user deploys 5.{N+1}. At this point, 'select foo()'
                means something different, and the user code is most likely
                broken (it's only safe if the code is 'select db.foo()').
                With a warning printed when the SF is loaded (which has to occur
                before the call), the warning will provide a hint explaining
                the root cause of a later failure of 'select foo()'.
                With no warning printed, the user code will fail with no
                apparent reason.
                Printing a warning each time db_load_routine is executed for
                an ambiguous function is annoying, since that can happen a lot,
                but in practice should not happen unless there *are* name
                collisions.
                If a collision exists, it should not be silenced but fixed.
              */
              push_warning_printf(thd,
                                  Sql_condition::SL_NOTE,
                                  ER_NATIVE_FCT_NAME_COLLISION,
                                  ER_THD(thd, ER_NATIVE_FCT_NAME_COLLISION),
                                  sp->m_name.str);
            }
          }
        ;

sp_tail:
          PROCEDURE_SYM         /*$1*/
          opt_if_not_exists     /*$2*/
          sp_name               /*$3*/
          {                     /*$4*/
            THD *thd= YYTHD;
            LEX *lex= Lex;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_RECURSIVE_CREATE, MYF(0), "PROCEDURE");
              MYSQL_YYABORT;
            }

            lex->stmt_definition_begin= @1.cpp.start;

            sp_head *sp= sp_start_parsing(thd, enum_sp_type::PROCEDURE, $3);

            if (!sp)
              MYSQL_YYABORT;

            lex->sphead= sp;
            lex->create_info->options= $2 ? HA_LEX_CREATE_IF_NOT_EXISTS : 0;
          }
          '('                   /*$5*/
          {                     /*$6*/
            Lex->sphead->m_parser_data.set_parameter_start_ptr(@5.cpp.end);
          }
          sp_pdparam_list       /*$7*/
          ')'                   /*$8*/
          {                     /*$9*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sphead->m_parser_data.set_parameter_end_ptr(@8.cpp.start);
            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
          sp_c_chistics         /*$10*/
          {                     /*$11*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sphead->m_chistics= &lex->sp_chistics;
            lex->sphead->set_body_start(thd, yylloc.cpp.start);
          }
          sp_proc_stmt          /*$12*/
          {                     /*$13*/
            THD *thd= YYTHD;
            LEX *lex= Lex;

            sp_finish_parsing(thd);

            lex->sql_command= SQLCOM_CREATE_PROCEDURE;
          }
        ;
%endif

/*************************************************************************/

xa:
          XA_SYM begin_or_start xid opt_join_or_resume
          {
            Lex->sql_command = SQLCOM_XA_START;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_xa_start($3, $4);
          }
        | XA_SYM END xid opt_suspend
          {
            Lex->sql_command = SQLCOM_XA_END;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_xa_end($3, $4);
          }
        | XA_SYM PREPARE_SYM xid
          {
            Lex->sql_command = SQLCOM_XA_PREPARE;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_xa_prepare($3);
          }
        | XA_SYM COMMIT_SYM xid opt_one_phase
          {
            Lex->sql_command = SQLCOM_XA_COMMIT;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_xa_commit($3, $4);
          }
        | XA_SYM ROLLBACK_SYM xid
          {
            Lex->sql_command = SQLCOM_XA_ROLLBACK;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_xa_rollback($3);
          }
        | XA_SYM RECOVER_SYM opt_convert_xid
          {
            Lex->sql_command = SQLCOM_XA_RECOVER;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_xa_recover($3);
          }
        ;

opt_convert_xid:
          /* empty */ { $$= false; }
         | CONVERT_SYM XID_SYM { $$= true; }

xid:
          text_string
          {
            MYSQL_YYABORT_UNLESS($1->length() <= MAXGTRIDSIZE);
            XID *xid;
            if (!(xid= (XID *)YYTHD->alloc(sizeof(XID))))
              MYSQL_YYABORT;
            xid->set(1L, $1->ptr(), $1->length(), 0, 0);
            $$= xid;
          }
          | text_string ',' text_string
          {
            MYSQL_YYABORT_UNLESS($1->length() <= MAXGTRIDSIZE &&
                                 $3->length() <= MAXBQUALSIZE);
            XID *xid;
            if (!(xid= (XID *)YYTHD->alloc(sizeof(XID))))
              MYSQL_YYABORT;
            xid->set(1L, $1->ptr(), $1->length(), $3->ptr(), $3->length());
            $$= xid;
          }
          | text_string ',' text_string ',' ulong_num
          {
            // check for overwflow of xid format id
            bool format_id_overflow_detected= ($5 > LONG_MAX);

            MYSQL_YYABORT_UNLESS($1->length() <= MAXGTRIDSIZE &&
                                 $3->length() <= MAXBQUALSIZE
                                 && !format_id_overflow_detected);

            XID *xid;
            if (!(xid= (XID *)YYTHD->alloc(sizeof(XID))))
              MYSQL_YYABORT;
            xid->set($5, $1->ptr(), $1->length(), $3->ptr(), $3->length());
            $$= xid;
          }
        ;

begin_or_start:
          BEGIN_SYM {}
        | START_SYM {}
        ;

opt_join_or_resume:
          /* nothing */ { $$= XA_NONE;        }
        | JOIN_SYM      { $$= XA_JOIN;        }
        | RESUME_SYM    { $$= XA_RESUME;      }
        ;

opt_one_phase:
          /* nothing */     { $$= XA_NONE;        }
        | ONE_SYM PHASE_SYM { $$= XA_ONE_PHASE;   }
        ;

opt_suspend:
          /* nothing */
          { $$= XA_NONE;        }
        | SUSPEND_SYM
          { $$= XA_SUSPEND;     }
        | SUSPEND_SYM FOR_SYM MIGRATE_SYM
          { $$= XA_FOR_MIGRATE; }
        ;

install:
          INSTALL_SYM PLUGIN_SYM ident SONAME_SYM TEXT_STRING_sys
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_INSTALL_PLUGIN;
            lex->m_sql_cmd= new (YYMEM_ROOT) Sql_cmd_install_plugin(to_lex_cstring($3), $5);
          }
        | INSTALL_SYM COMPONENT_SYM TEXT_STRING_sys_list
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_INSTALL_COMPONENT;
            lex->m_sql_cmd= new (YYMEM_ROOT) Sql_cmd_install_component($3);
          }
        ;

uninstall:
          UNINSTALL_SYM PLUGIN_SYM ident
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_UNINSTALL_PLUGIN;
            lex->m_sql_cmd= new (YYMEM_ROOT) Sql_cmd_uninstall_plugin(to_lex_cstring($3));
          }
       | UNINSTALL_SYM COMPONENT_SYM TEXT_STRING_sys_list
          {
            LEX *lex= Lex;
            lex->sql_command= SQLCOM_UNINSTALL_COMPONENT;
            lex->m_sql_cmd= new (YYMEM_ROOT) Sql_cmd_uninstall_component($3);
          }
        ;

TEXT_STRING_sys_list:
          TEXT_STRING_sys
          {
            $$.init(YYTHD->mem_root);
            if ($$.push_back($1))
              MYSQL_YYABORT; // OOM
          }
        | TEXT_STRING_sys_list ',' TEXT_STRING_sys
          {
            $$= $1;
            if ($$.push_back($3))
              MYSQL_YYABORT; // OOM
          }
        ;

import_stmt:
          IMPORT TABLE_SYM FROM TEXT_STRING_sys_list
          {
            LEX *lex= Lex;
            lex->m_sql_cmd=
              new (YYTHD->mem_root) Sql_cmd_import_table($4);
            if (lex->m_sql_cmd == NULL)
              MYSQL_YYABORT;
            lex->sql_command= SQLCOM_IMPORT;
          }
        ;

/**************************************************************************

Clone local/remote replica statements.

**************************************************************************/
clone_stmt:
          CLONE_SYM LOCAL_SYM
          DATA_SYM DIRECTORY_SYM opt_equal TEXT_STRING_filesystem
          {
            Lex->sql_command= SQLCOM_CLONE;
            Lex->m_sql_cmd= NEW_PTN Sql_cmd_clone(to_lex_cstring($6));
            if (Lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT;
            
          } opt_enable_page_track_and_start_lsn;
        | CLONE_SYM INSTANCE_SYM FROM user ':' ulong_num
          IDENTIFIED_SYM BY TEXT_STRING_sys
          opt_datadir_ssl
          {
            Lex->sql_command= SQLCOM_CLONE;
            /* Reject space characters around ':' */
            if (@6.raw.start - @4.raw.end != 1) {
              YYTHD->syntax_error_at(@5);
              MYSQL_YYABORT;
            }
            $4->first_factor_auth_info.auth = to_lex_cstring($9);
            $4->first_factor_auth_info.uses_identified_by_clause = true;
            Lex->contains_plaintext_password= true;

            Lex->m_sql_cmd= NEW_PTN Sql_cmd_clone($4, $6, to_lex_cstring($10));

            if (Lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT;
          } opt_enable_page_track_and_start_lsn
          ;

opt_enable_page_track_and_start_lsn:
          /* empty */
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_lsn(0);
          }
        | ENABLE_SYM PAGE_SYM TRACK_SYM
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_enable_page_track();
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_lsn(0);
            if((((Sql_cmd_clone*)Lex->m_sql_cmd)->data_dir()).length == 0){
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | START_LSN_SYM opt_equal ulonglong_num
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_lsn($3);
            if((((Sql_cmd_clone*)Lex->m_sql_cmd)->data_dir()).length == 0){
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | ENABLE_SYM PAGE_SYM TRACK_SYM START_LSN_SYM opt_equal ulonglong_num
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_enable_page_track();
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_lsn($6);
            if((((Sql_cmd_clone*)Lex->m_sql_cmd)->data_dir()).length == 0){
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | START_LSN_SYM opt_equal ulonglong_num ENABLE_SYM PAGE_SYM TRACK_SYM
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_lsn($3);
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_enable_page_track();
            if((((Sql_cmd_clone*)Lex->m_sql_cmd)->data_dir()).length == 0){
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | INCREMENT_SYM BASED_SYM DIRECTORY_SYM opt_equal TEXT_STRING_filesystem ENABLE_SYM PAGE_SYM TRACK_SYM
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_dir(to_lex_cstring($5));
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_enable_page_track();
            if((((Sql_cmd_clone*)Lex->m_sql_cmd)->data_dir()).length == 0){
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        | ENABLE_SYM PAGE_SYM TRACK_SYM INCREMENT_SYM BASED_SYM DIRECTORY_SYM opt_equal TEXT_STRING_filesystem
          {
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_based_dir(to_lex_cstring($8));
            ((Sql_cmd_clone*)Lex->m_sql_cmd)->set_enable_page_track();
            if((((Sql_cmd_clone*)Lex->m_sql_cmd)->data_dir()).length == 0){
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
          }
        ;

opt_datadir_ssl:
          opt_ssl
          {
            $$= null_lex_str;
          }
        | DATA_SYM DIRECTORY_SYM opt_equal TEXT_STRING_filesystem opt_ssl
          {
            $$= $4;
          }
        ;

opt_ssl:
          /* empty */
          {
            Lex->ssl_type= SSL_TYPE_NOT_SPECIFIED;
          }
        | REQUIRE_SYM SSL_SYM
          {
            Lex->ssl_type= SSL_TYPE_SPECIFIED;
          }
        | REQUIRE_SYM NO_SYM SSL_SYM
          {
            Lex->ssl_type= SSL_TYPE_NONE;
          }
        ;

resource_group_types:
          USER { $$= resourcegroups::Type::USER_RESOURCE_GROUP; }
        | SYSTEM_SYM { $$= resourcegroups::Type::SYSTEM_RESOURCE_GROUP; }
        ;

opt_resource_group_vcpu_list:
          /* empty */
          {
            /* Make an empty list. */
            $$= NEW_PTN Mem_root_array<resourcegroups::Range>(YYMEM_ROOT);
            if ($$ == nullptr)
              MYSQL_YYABORT;
          }
        | VCPU_SYM opt_equal vcpu_range_spec_list { $$= $3; }
        ;

vcpu_range_spec_list:
          vcpu_num_or_range
          {
            resourcegroups::Range r($1.start, $1.end);
            $$= NEW_PTN Mem_root_array<resourcegroups::Range>(YYMEM_ROOT);
            if ($$ == nullptr || $$->push_back(r))
              MYSQL_YYABORT;
          }
        | vcpu_range_spec_list opt_comma vcpu_num_or_range
          {
            resourcegroups::Range r($3.start, $3.end);
            $$= $1;
            if ($$ == nullptr || $$->push_back(r))
              MYSQL_YYABORT;
          }
        ;

vcpu_num_or_range:
          NUM
          {
            auto cpu_id= my_strtoull($1.str, nullptr, 10);
            $$.start= $$.end=
              static_cast<resourcegroups::platform::cpu_id_t>(cpu_id);
            assert($$.start == cpu_id); // truncation check
          }
        | NUM '-' NUM
          {
            auto start= my_strtoull($1.str, nullptr, 10);
            $$.start= static_cast<resourcegroups::platform::cpu_id_t>(start);
            assert($$.start == start); // truncation check

            auto end= my_strtoull($3.str, nullptr, 10);
            $$.end= static_cast<resourcegroups::platform::cpu_id_t>(end);
            assert($$.end == end); // truncation check
          }
        ;

signed_num:
          NUM     { $$= static_cast<int>(my_strtoll($1.str, nullptr, 10)); }
        | '-' NUM { $$= -static_cast<int>(my_strtoll($2.str, nullptr, 10)); }
        ;

opt_resource_group_priority:
          /* empty */ { $$.is_default= true; }
        | THREAD_PRIORITY_SYM opt_equal signed_num
          {
            $$.is_default= false;
            $$.value= $3;
          }
        ;

opt_resource_group_enable_disable:
          /* empty */ { $$.is_default= true; }
        | ENABLE_SYM
          {
            $$.is_default= false;
            $$.value= true;
          }
        | DISABLE_SYM
          {
            $$.is_default= false;
            $$.value= false;
          }
        ;

opt_force:
          /* empty */ { $$= false; }
        | FORCE_SYM   { $$= true; }
        ;


json_attribute:
          TEXT_STRING_sys
          {
            if ($1.str[0] != '\0') {
              size_t eoff = 0;
              std::string emsg;
              if (!is_valid_json_syntax($1.str, $1.length, &eoff, &emsg,
                  JsonDocumentDefaultDepthHandler)) {
                my_error(ER_INVALID_JSON_ATTRIBUTE, MYF(0),
                         emsg.c_str(), eoff, $1.str+eoff);
                MYSQL_YYABORT;
              }
            }
            $$ = to_lex_cstring($1);
          }
        ;

%ifdef SQL_MODE_ORACLE
for_loop_statements:
          LOOP_SYM
          sp_proc_stmts1 END LOOP_SYM
          { }
        ;

sp_for_loop_index_and_bounds:
          ident sp_for_loop_bounds
          {
            uint var_offset= 0;
            Item_splocal *cursor_var_item= nullptr;
            bool rc= Lex->ora_sp_for_loop_index_and_bounds(YYTHD, $1, $2, &var_offset, @1.raw.start, @1.raw.end, &cursor_var_item);
            if(rc){
              MYSQL_YYABORT;
            }
            $$= NEW_PTN Oracle_sp_for_loop_index_and_bounds(*$2,$1,cursor_var_item,var_offset,
            @1.raw.start, @1.raw.end);
            if (!$$)
              MYSQL_YYABORT_ERROR(ER_DA_OOM, MYF(0)); /* purecov: inspected */
          }
        ;

sp_for_loop_bounds:
          IN_SYM                      /*$1*/
          for_loop_bound_expr
          {
            Item_func *item_func= dynamic_cast<Item_func *>($2->get_item());
            Item *expr= item_func ? item_func->arguments()[0] : nullptr;
            PTI_function_call_generic_ident_sys *function=
              dynamic_cast<PTI_function_call_generic_ident_sys *>(expr);
            PTI_singlerow_subselect *subselect=
              dynamic_cast<PTI_singlerow_subselect *>(expr);
            PTI_simple_ident_ident *var=
              dynamic_cast<PTI_simple_ident_ident *>(expr);
            if(!expr || (!function && !subselect && !var)) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "for loop use the expression, only support cursor sql");
              MYSQL_YYABORT;
            }
            LEX_STRING name_result= NULL_STR;
            uint offset = 0;
            Lex->sphead->setup_sp_assignment_lex(YYTHD, $2);
            if(function || var) {  // for var in cursor
              ITEMIZE(expr, &expr);
              Item_func_cursor *item_func_tmp= dynamic_cast<Item_func_cursor *>(expr);
              Item_func_sp *item_func_sp= dynamic_cast<Item_func_sp *>(expr);
              LEX_STRING ident= item_func_tmp ? item_func_tmp->get_cursor_name() :
                var ? to_lex_string(var->get_ident()) :
                item_func_sp ? item_func_sp->get_sp_name()->m_name : NULL_STR;
              if(!ident.str) {
                my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                  "for loop use the expression, only support cursor sql");
                MYSQL_YYABORT;
              }
              if (unlikely(Lex->sp_for_loop_bounds_set_cursor(YYTHD, ident, nullptr,
                &offset, $2, item_func_tmp ? item_func_tmp->arguments() : nullptr,
                item_func_tmp ? item_func_tmp->argument_count() : 0)))
                MYSQL_YYABORT;
              name_result= ident;
              /* The sp_assignment_lex's plugins are not used in sp_lex_instr,
                so must release here. */
              Lex->release_plugins();
              if (Lex->sphead->restore_lex(YYTHD))
                MYSQL_YYABORT;
            }
            if(subselect) {  // for i in (select_stmt)
              PT_select_stmt *select= NEW_PTN
                PT_select_stmt(subselect->get_subselect()->query_primary());
              MAKE_CMD(select);
              LEX_STRING cursor_ident = NULL_STR;
              Item *tmp = NEW_PTN Item_func_uuid_short(@$);
              if (unlikely(Lex->sp_for_cursor_in_loop(YYTHD, tmp, @2.raw.start,
                @2.raw.end-1, &offset, &cursor_ident)))
                MYSQL_YYABORT;
              name_result= cursor_ident;
            }
            $$= NEW_PTN Oracle_sp_for_loop_bounds(offset,name_result,true,0,$2,nullptr,subselect ? true:false);
            if (!$$)
              MYSQL_YYABORT_ERROR(ER_DA_OOM, MYF(0));
          }
        | IN_SYM               /*$1*/
          for_loop_bound_expr  /*$2*/
          DOT_DOT_SYM          /*$3*/
          for_loop_bound_expr  /*$4*/
          {
            // for var in num .. num
            Item_func *item_func= dynamic_cast<Item_func *>($2->get_item());
            Item *expr= item_func ? item_func->arguments()[0] : nullptr;
            PTI_singlerow_subselect *subselect=
              dynamic_cast<PTI_singlerow_subselect *>(expr);
            if(subselect) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "select stmt used in 'for in expr .. expr loop' sql");
              MYSQL_YYABORT;
            }
            LEX_STRING empty_str= to_lex_string(EMPTY_CSTR);
            $$= NEW_PTN Oracle_sp_for_loop_bounds(0,empty_str,false,1,$2,$4);
            if (!$$)
              MYSQL_YYABORT_ERROR(ER_DA_OOM, MYF(0)); /* purecov: inspected */
          }
        | IN_REVERSE_SYM        /*$1*/
          for_loop_bound_expr
          DOT_DOT_SYM          /*$3*/
          for_loop_bound_expr
          {
            // for var in reverse num .. num
            Item_func *item_func= dynamic_cast<Item_func *>($2->get_item());
            Item *expr= item_func ? item_func->arguments()[0] : nullptr;
            PTI_singlerow_subselect *subselect=
              dynamic_cast<PTI_singlerow_subselect *>(expr);
            if(subselect) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "select stmt used in 'for in reverse expr .. expr loop' sql");
              MYSQL_YYABORT;
            }
            LEX_STRING empty_str= to_lex_string(EMPTY_CSTR);
            $$= NEW_PTN Oracle_sp_for_loop_bounds(0,empty_str,false,-1,$2,$4);
            if (!$$)
              MYSQL_YYABORT_ERROR(ER_DA_OOM, MYF(0)); /* purecov: inspected */
          }
        ;

assignment_source_lex:
          {
            if (unlikely(!($$= NEW_PTN
                           sp_assignment_lex(YYTHD, Lex))))
              MYSQL_YYABORT;
          }
        ;

for_loop_bound_expr:
          assignment_source_lex
          {
            Lex->sphead->setup_sp_assignment_lex(YYTHD, $1);
          }
          expr
          {
            $$= $1;
            $$->sp_lex_in_use= true;
            Item *i0= NEW_PTN Item_int_0(@$);
            Item *round2= NEW_PTN Item_func_ora_round(@$, $3, i0, false);
            $$->set_item(round2);
            $$->set_value_query(@3.raw.start, @3.raw.end);
            if (unlikely($$->sphead->restore_lex(YYTHD)))
              MYSQL_YYABORT;
          }
        ;

sp_unlabeled_control_ora:
          sp_unlabeled_control
          {
            $$.init();
          }
        | FOR_SYM                       /*$1*/
          {                             /*$2*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
            sp_head *sp= lex->sphead;
            sp->reset_lex(thd);
          }
          sp_for_loop_index_and_bounds      /*$3*/
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            Item *expr = nullptr;
            if($3->is_cursor){
              uint offset= 0;
              if (! pctx->find_cursor($3->cursor_name, &offset, false))
              {
                my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $3->cursor_name.str);
                MYSQL_YYABORT;
              }
              if ( ! (expr = pctx->make_item_plsql_cursor_attr(thd, to_lex_cstring($3->cursor_name.str), offset)))
                MYSQL_YYABORT;
            } else {
              Item *tmp = NEW_PTN Item_func_uuid_short(@$);
              if (unlikely(tmp == NULL))
                MYSQL_YYABORT;
              Item *item_upper= nullptr;
              if(Lex->make_temp_upper_bound_variable_and_set(YYTHD, tmp,
                $3->direction > 0 , $3->from,
                $3->jump_condition, &item_upper, $3->cursor_var))
                MYSQL_YYABORT;
              if ( ! (expr = pctx->make_item_plsql_sp_for_loop_attr(thd, $3->direction, $3->cursor_var_item, item_upper)))
                MYSQL_YYABORT;
            }

            pctx->set_for_loop_to_label($3, sp->instructions());

            sp_instr_jump_if_not *i=
              NEW_PTN sp_instr_jump_if_not(sp->instructions(),
              lex, expr,EMPTY_CSTR);

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                sp->m_parser_data.new_cont_backpatch() ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
          for_loop_statements  /*$5*/ //loop..end loop
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offset= 0;
            if(lex->sp_continue_loop(thd, &offset, pctx->find_label_current_loop_start()))
              MYSQL_YYABORT;

            $$.init();
            if($3->is_cursor){
              $$.curs= 1;
              $$.vars= offset;
            }
            sp_label *lab= pctx->pop_label();

            sp_instr_jump *i_jump= NEW_PTN sp_instr_jump(sp->instructions(), pctx,lab->ip);
            if (!i_jump || sp->add_instr(thd, i_jump))
              MYSQL_YYABORT;

            sp->m_parser_data.do_backpatch(lab,
                                            sp->instructions());

            sp->m_parser_data.do_cont_backpatch(sp->instructions());
            Lex->set_sp_current_parsing_ctx(pctx->pop_context());
          }
        ;

sp_proc_stmt_compound:
          sp_block_ora
          {
            LEX *lex= Lex;
            sp_finish_parsing(YYTHD);
            lex->sql_command= SQLCOM_COMPOUND;
            lex->m_sql_cmd= NEW_PTN Sql_cmd_compound(lex->sphead);
            if (lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT;
          }
        ;

label_ident_ora:
          SHIFT_LEFT label_ident SHIFT_RIGHT
          {
            if (unlikely(Lex->sp_push_goto_label(YYTHD, $2)))
              MYSQL_YYABORT;
            $$= $2;
          }

sp_block_ora:
          BEGIN_SYM                /* $1 */
          {                        /* $2 */
              if(!Lex->sphead) {
              sp_head *sp= sp_start_parsing(YYTHD, enum_sp_type::PROCEDURE,nullptr);
              if (sp == nullptr)
                MYSQL_YYABORT;
              Lex->sphead= sp;
              memset(&Lex->sp_chistics, 0, sizeof(st_sp_chistics));
              sp->m_chistics= &Lex->sp_chistics;
              sp->m_chistics->suid = SP_IS_NOT_SUID;
              sp->set_body_start(YYTHD, @1.cpp.start);
              Lex->stmt_definition_begin= @1.cpp.start;
            }
            if (Lex->sp_block_begin_label(YYTHD))
              MYSQL_YYABORT;
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
            if (Lex->sp_exception_declarations(YYTHD))
              MYSQL_YYABORT;
          }
          sp_proc_stmts_ora        /* $3 */
          END
          {
            if (Lex->sp_block_finalize(YYTHD, $3))
              MYSQL_YYABORT;
            if (Lex->sp_block_end_label(YYTHD))
              MYSQL_YYABORT;
          }
        | DECLARE_SYM               /* $1 */
          {                         /* $2 */
            if(!Lex->sphead) {
              sp_head *sp= sp_start_parsing(YYTHD, enum_sp_type::PROCEDURE,nullptr);
              if (sp == nullptr)
                MYSQL_YYABORT;
              Lex->sphead= sp;
              memset(&Lex->sp_chistics, 0, sizeof(st_sp_chistics));
              sp->m_chistics= &Lex->sp_chistics;
              sp->m_chistics->suid = SP_IS_NOT_SUID;
              Lex->sphead->set_body_start(YYTHD, @1.cpp.start);
              Lex->stmt_definition_begin= @1.cpp.start;
            }
            if (Lex->sp_block_begin_label(YYTHD))
              MYSQL_YYABORT;
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
          }
          opt_sp_decl_body_list     /* $3 */
          BEGIN_SYM                 /* $4 */
          {                         /* $5 */
            if (Lex->sp_exception_declarations(YYTHD))
              MYSQL_YYABORT;
          }
          sp_proc_stmts_ora          /* $6 */
          END
          {
            $3.hndlrs+= $6;
            if (Lex->sp_block_finalize(YYTHD, $3))
              MYSQL_YYABORT;
            if (Lex->sp_block_end_label(YYTHD))
              MYSQL_YYABORT;
          }
        | label_ident_ora
          {
            if(!Lex->sphead) {
              sp_head *sp= sp_start_parsing(YYTHD, enum_sp_type::PROCEDURE,nullptr);
              if (sp == nullptr)
                MYSQL_YYABORT;
              Lex->sphead= sp;
              memset(&Lex->sp_chistics, 0, sizeof(st_sp_chistics));
              sp->m_chistics= &Lex->sp_chistics;
              sp->m_chistics->suid = SP_IS_NOT_SUID;
              sp->set_body_start(YYTHD, @1.cpp.start);
              Lex->stmt_definition_begin= @1.cpp.start;
            }
            if (Lex->sp_block_begin_label(YYTHD, $1))
            MYSQL_YYABORT;
          }
          BEGIN_SYM                /* $3 */
          {
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
            if (Lex->sp_exception_declarations(YYTHD))
              MYSQL_YYABORT;
          }
          sp_proc_stmts_ora        /* $5 */
          END                      /* $6 */
          {                        /* $7 */
            if (Lex->sp_block_finalize(YYTHD, $5))
              MYSQL_YYABORT;
          }
          sp_opt_label             /* $8 */
          {
            if (Lex->sp_block_end_label(YYTHD, $8))
              MYSQL_YYABORT;
          }
        | label_ident_ora  /* 1 */
          {                /* 2 */
            if(!Lex->sphead) {
              sp_head *sp= sp_start_parsing(YYTHD, enum_sp_type::PROCEDURE,nullptr);
              if (sp == nullptr)
                MYSQL_YYABORT;
              Lex->sphead= sp;
              memset(&Lex->sp_chistics, 0, sizeof(st_sp_chistics));
              sp->m_chistics= &Lex->sp_chistics;
              sp->m_chistics->suid = SP_IS_NOT_SUID;
              sp->set_body_start(YYTHD, @1.cpp.start);
              Lex->stmt_definition_begin= @1.cpp.start;
            }
            if (Lex->sp_block_begin_label(YYTHD, $1))
            MYSQL_YYABORT;
          }
          DECLARE_SYM    /* 3 */
          {              /* 4 */
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
          }
          opt_sp_decl_body_list  /* 5 */
          BEGIN_SYM              /* 6 */
          {                      /* 7 */
            if (Lex->sp_exception_declarations(YYTHD))
              MYSQL_YYABORT;
          }
          sp_proc_stmts_ora  /* 8 */
          END                /* 9 */
          {                  /* 10 */
            $5.hndlrs+= $8;
            if (Lex->sp_block_finalize(YYTHD, $5))
              MYSQL_YYABORT;
          }
          sp_opt_label        /* 11 */
          {
            if (Lex->sp_block_end_label(YYTHD, $11))
              MYSQL_YYABORT;
          }
        ;

sp_proc_stmts_ora:
          sp_instr_addr
          sp_proc_stmts
          {
            if (Lex->sp_exception_section(YYTHD, $1))
              MYSQL_YYABORT;
          }
          opt_exceptions_ora
          {
            if (Lex->sp_exception_finalize(YYTHD, $1, $4))
              MYSQL_YYABORT;
            $$= $4;
          }
        ;

sp_instr_addr:
          /* empty */ { $$= Lex->sphead->instructions(); }
        ;

opt_exceptions_ora:
          /* empty */ { $$= 0; }
        | EXCEPTION_SYM exception_handlers_ora { $$= $2; }
        ;

exception_handlers_ora:
          exception_handler_ora { $$= 1; }
        | exception_handlers_ora exception_handler_ora { $$+= 1; }
        ;

exception_handler_ora:
          WHEN_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *parent_pctx= lex->get_sp_current_parsing_ctx();

            sp_pcontext *handler_pctx=
              parent_pctx->push_context(thd, sp_pcontext::HANDLER_SCOPE);

            sp_handler *h=
              parent_pctx->add_handler(thd, sp_handler::EXIT);

            lex->set_sp_current_parsing_ctx(handler_pctx);

            sp_instr_hpush_jump *i=
              NEW_PTN sp_instr_hpush_jump(sp->instructions(), handler_pctx, h);
            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;
            if (sp->m_parser_data.add_backpatch_entry(
                  i, handler_pctx->push_label(thd, EMPTY_CSTR, 0)))
              MYSQL_YYABORT;

            sp->m_parser_data.set_parsing_sp_in_exception(true);
            lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // DECL HANDLER FOR
          }
          sp_hcond_list_ora
          THEN_SYM
          sp_proc_stmts1
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *hlab= pctx->pop_label();
            sp_instr_hreturn *i=
              NEW_PTN sp_instr_hreturn(sp->instructions(), pctx);
            if (i == nullptr ||
                sp->add_instr(thd, i) ||
                sp->m_parser_data.add_backpatch_entry(i, pctx->last_label()))
              MYSQL_YYABORT;

            sp->m_parser_data.set_parsing_sp_in_exception(false);

            sp->m_parser_data.do_backpatch(hlab, sp->instructions());
            // push handler_pctx
            lex->set_sp_current_parsing_ctx(pctx->pop_context());

            $$.vars= $$.conds= $$.curs= 0;
            $$.hndlrs= 1;
          }
        ;

sp_hcond_list_ora:
          sp_hcond_ora
        | sp_hcond_list_ora OR_SYM sp_hcond_ora
        | OTHERS_SYM
          {
            auto others= NEW_PTN sp_condition_value(sp_condition_value::EXCEPTION);
            if (others==nullptr)
              MYSQL_YYABORT;
            sp_instr_hpush_jump *i=
                (sp_instr_hpush_jump *)Lex->sphead->last_instruction();
            i->add_condition(others);
          }
        ;

sp_hcond_ora:
          ident
          {
            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            if(pctx->declared_or_predefined_condition($1, lex->sphead->last_instruction()))
              MYSQL_YYABORT;
          }
        ;

ev_sql_stmt_inner:
          sp_proc_stmt
        ;

sp_proc_stmt:
          sp_trigger_stmt_when_ora
        | sp_block_ora
        | sp_labeled_control
        | sp_proc_stmt_unlabeled
        | label_ident_ora sp_label_stmt
        | sp_label_stmt
        ;

sp_label_stmt:
          sp_proc_stmt_statement
        | sp_proc_stmt_return
        | sp_proc_stmt_if
        | case_stmt_specification
        | sp_proc_stmt_leave
        | sp_proc_stmt_iterate
        | sp_proc_stmt_open_ora
        | sp_proc_stmt_fetch_ora
        | sp_proc_stmt_close
        | sp_proc_stmt_exit_oracle
        | ora_sp_forall_loop_ora
        | sp_proc_stmt_goto_oracle
        | sp_proc_stmt_continue_oracle
        ;

sp_proc_stmt_goto_oracle:
          GOTO_SYM label_ident
          {
            if (unlikely(Lex->sp_goto_statement(YYTHD, $2)))
              MYSQL_YYABORT;
          }
        ;

raise_stmt:
          RAISE_SYM
          {
            /*only in exception stmt */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            lex->sql_command= SQLCOM_RESIGNAL;
            if(!lex->sphead) {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }

            if (!lex->sphead->m_parser_data.is_parsing_sp_exception()) {
              my_error(ER_RAISE_NOT_IN_EXCEPTION, MYF(0));
              MYSQL_YYABORT;
            }

            auto empty_info= NEW_PTN Set_signal_information();
            if (empty_info == nullptr)
              MYSQL_YYABORT;

            lex->m_sql_cmd= NEW_PTN Sql_cmd_resignal(nullptr, empty_info);
            if (lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT;
          }
        | RAISE_SYM signal_value_ora
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if(!lex->sphead) {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            lex->sql_command= SQLCOM_SIGNAL;
            auto empty_info= NEW_PTN Set_signal_information();
            if (empty_info == nullptr)
              MYSQL_YYABORT;

            lex->m_sql_cmd= NEW_PTN Sql_cmd_signal($2, empty_info);
            // must use in procedure or function
            if (lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT;
          }
        | RAISE_APPLICATION_ERROR '(' ulong_num ',' literal ')'
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if(!lex->sphead) {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            lex->sql_command= SQLCOM_SIGNAL;
            auto info= NEW_PTN Set_signal_information();
            if (info == nullptr)
              MYSQL_YYABORT;
            auto message= $5;
            ITEMIZE(message, &message);
            if(info->set_item(enum_condition_item_name::CIN_MESSAGE_TEXT,message))
              MYSQL_YYABORT;
            auto cond= NEW_PTN sp_oracle_condition_value();
            if (cond == nullptr)
              MYSQL_YYABORT;
            cond->set_redirect_err_to_user_defined($3);
            lex->m_sql_cmd= NEW_PTN Sql_cmd_signal(cond, info);
            // must use in procedure or function
            if (lex->m_sql_cmd == nullptr)
              MYSQL_YYABORT;
          }
        ;

signal_value_ora:
      ident
      {
        LEX *lex= Lex;
        sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

        if (!pctx)
        {
          /* SIGNAL foo cannot be used outside of stored programs */
          my_error(ER_SP_COND_MISMATCH, MYF(0), $1.str);
          MYSQL_YYABORT;
        }
        sp_condition_value *cond= pctx->find_declared_or_predefined_condition($1);
        if (!cond)
        {
          my_error(ER_SP_COND_MISMATCH, MYF(0), $1.str);
          MYSQL_YYABORT;
        }
        if (cond->sql_state[0] == '\0')
        {
          my_error(ER_RAISE_BAD_CONDITION, MYF(0), $1.str);
          MYSQL_YYABORT;
        }
        $$= cond;
      }
      ;

udf_tail:
          AGGREGATE_SYM FUNCTION_SYM ident
          RETURNS_SYM udf_type SONAME_SYM TEXT_STRING_sys
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if (is_native_function($3))
            {
              my_error(ER_NATIVE_FCT_NAME_COLLISION, MYF(0),
                       $3.str);
              MYSQL_YYABORT;
            }
            lex->sql_command = SQLCOM_CREATE_FUNCTION;
            lex->udf.type= UDFTYPE_AGGREGATE;
            lex->stmt_definition_begin= @2.cpp.start;
            lex->udf.name = $3;
            lex->udf.returns=(Item_result) $5;
            lex->udf.dl=$7.str;
          }
        | FUNCTION_SYM ident
          RETURNS_SYM udf_type SONAME_SYM TEXT_STRING_sys
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if (is_native_function($2))
            {
              my_error(ER_NATIVE_FCT_NAME_COLLISION, MYF(0),
                       $2.str);
              MYSQL_YYABORT;
            }
            lex->sql_command = SQLCOM_CREATE_FUNCTION;
            lex->udf.type= UDFTYPE_FUNCTION;
            lex->stmt_definition_begin= @1.cpp.start;
            lex->udf.name = $2;
            lex->udf.returns=(Item_result) $4;
            lex->udf.dl=$6.str;
          }
        ;

/* Some codes for sp routine rules such as sf_tail, sp_tail, are just a reorder or reconstructing
 * of their counterpart in default mode, with most comments removed. You may refer to the codes
 * above this comment for better understanding.
*/
sf_tail:
          FUNCTION_SYM                       /* $1 */
          sp_name                            /* $2 */
          {                                  /* $3 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->stmt_definition_begin= @1.cpp.start;
            lex->spname= $2;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_RECURSIVE_CREATE, MYF(0), "FUNCTION");
              MYSQL_YYABORT;
            }

            sp_head *sp= sp_start_parsing(thd, enum_sp_type::FUNCTION, lex->spname);

            if (!sp)
              MYSQL_YYABORT;

            lex->sphead= sp;
          }
          opt_sp_parenthesized_fdparam_list  /* $4 */
          RETURN_SYM                         /* $5 */
          sp_type_ora                        /* $6 */
          opt_collate                        /* $7 */
          {                                  /* $8 */
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            CONTEXTUALIZE($6);
            enum_field_types field_type= $6->type;
            const CHARSET_INFO *cs= $6->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $7, &cs))
              MYSQL_YYABORT;

            if ((field_type == MYSQL_TYPE_STRING || field_type == MYSQL_TYPE_VARCHAR)
                && ($6->get_type_flags() & BINCMP_FLAG))
            {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0), "return value collation");
              MYSQL_YYABORT;
            }

            Qualified_column_ident* udt_ident = nullptr;
            auto row_type = dynamic_cast<PT_row_type*>($6);
            if (row_type) {
              udt_ident = row_type->get_udt_name();
              if (row_type->m_table_type == 0 || row_type->m_table_type == 1) {
                my_error(ER_NOT_SUPPORTED_YET, MYF(0), "return udt of collation type");
                MYSQL_YYABORT;
              }
              field_type = MYSQL_TYPE_VARCHAR;
            }
            if (sp->m_return_field_def.init(YYTHD, "", field_type,
                                            $6->get_length(), $6->get_dec(),
                                            $6->get_type_flags(), NULL, NULL, &NULL_CSTR, 0,
                                            $6->get_interval_list(),
                                            cs ? cs : YYTHD->variables.collation_database,
                                            $7 != nullptr, $6->get_uint_geom_type(), nullptr,
                                            nullptr, nullptr, {},
                                            dd::Column::enum_hidden_type::HT_VISIBLE,
                                            false, udt_ident))
            {
              MYSQL_YYABORT;
            }

            sp->m_return_field_def.ora_record.is_ref_cursor= $6->is_sys_refcursor_type();
            sp->m_return_field_def.ora_record.m_cursor_offset=
              $6->is_sys_refcursor_type() ? 0 : -1;
            if (row_type) {
              sp->m_return_field_def.table_type = row_type->m_table_type;
              sp->m_return_field_def.varray_limit = row_type->m_varray_limit;
              sp->m_return_field_def.nested_table_udt = row_type->m_nested_table_udt_tmp;
              sp->m_return_field_def.ora_record.set_row_field_definitions(row_type->m_row_def);
              sp->m_return_field_def.ora_record.set_row_field_table_definitions(row_type->m_row_def_table);
            }
            if (prepare_sp_create_field(YYTHD,
                                        &sp->m_return_field_def))
              MYSQL_YYABORT;

            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
          sp_c_chistics                       /* $9 */
          {                                   /* $10 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sphead->m_chistics= &lex->sp_chistics;
            lex->sphead->set_body_start(thd, yylloc.cpp.start);
          }
          sp_tail_is                         /* $11 */
          sp_body                            /* $12 */
          {                                  /* $13 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            if (sp->is_not_allowed_in_function("function"))
              MYSQL_YYABORT;

            sp_finish_parsing(thd);
            lex->sql_command= SQLCOM_CREATE_SPFUNCTION;

            if (!(sp->m_flags & sp_head::HAS_RETURN))
            {
              my_error(ER_SP_NORETURN, MYF(0), sp->m_qname.str);
              MYSQL_YYABORT;
            }

            if (is_native_function(sp->m_name))
            {
              push_warning_printf(thd,
                                  Sql_condition::SL_NOTE,
                                  ER_NATIVE_FCT_NAME_COLLISION,
                                  ER_THD(thd, ER_NATIVE_FCT_NAME_COLLISION),
                                  sp->m_name.str);
            }
          }
        ;

sp_tail:
          PROCEDURE_SYM                      /* $1 */
          sp_name                            /* $2 */
          {                                  /* $3 */
            THD *thd= YYTHD;
            LEX *lex= Lex;

            if (lex->sphead)
            {
              my_error(ER_SP_NO_RECURSIVE_CREATE, MYF(0), "PROCEDURE");
              MYSQL_YYABORT;
            }

            lex->stmt_definition_begin= @2.cpp.start;

            sp_head *sp= sp_start_parsing(thd, enum_sp_type::PROCEDURE, $2);

            if (!sp)
              MYSQL_YYABORT;

            lex->sphead= sp;

          }
          opt_sp_parenthesized_pdparam_list  /* $4 */
          sp_c_chistics                      /* $5 */
          {                                  /* $6 */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sphead->m_chistics= &lex->sp_chistics;
            lex->sphead->set_body_start(thd, yyloc.cpp.start);
          }
          sp_tail_is                         /* $7 */
          sp_body                            /* $8 */
          {                                  /* $9 */
            THD *thd= YYTHD;
            LEX *lex= Lex;

            sp_finish_parsing(thd);
            lex->sql_command= SQLCOM_CREATE_PROCEDURE;
          }
        ;

/* params list for FUNCTIONS */

opt_sp_parenthesized_fdparam_list:
          sp_parenthesized_fdparam_list
        | sp_no_param
        ;

sp_parenthesized_fdparam_list:
          '('
           {
             Lex->sphead->m_parser_data.set_parameter_start_ptr(@1.cpp.end);
           }
           sp_fdparam_list
          ')'
           {
             Lex->sphead->m_parser_data.set_parameter_end_ptr(@4.cpp.start);
           }
        ;

opt_sp_parenthesized_pdparam_list:
          sp_parenthesized_pdparam_list
        | sp_no_param
          {
            memset(&Lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
        ;

sp_parenthesized_pdparam_list:
          '('
          {
            Lex->sphead->m_parser_data.set_parameter_start_ptr(@1.cpp.end);
          }
          sp_pdparam_list
          ')'
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;

            lex->sphead->m_parser_data.set_parameter_end_ptr(@4.cpp.start);
            memset(&lex->sp_chistics, 0, sizeof(st_sp_chistics));
          }
        ;

sp_no_param:
          {
            Lex->sphead->m_parser_data.set_parameter_start_ptr(
              YYLIP->get_cpp_tok_start());
            Lex->sphead->m_parser_data.set_parameter_end_ptr(
              YYLIP->get_cpp_tok_start());
          }
        ;

sp_tail_is:
          IS
        | AS
        ;

sp_body:
          {
            if (Lex->sp_block_begin_label(YYTHD))
              MYSQL_YYABORT;
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
          }
          opt_sp_decl_body_list
          BEGIN_SYM
          {
            if (Lex->sp_exception_declarations(YYTHD))
              MYSQL_YYABORT;
          }
          sp_proc_stmts_ora
          END opt_routine_end_name
          {
            $2.hndlrs+= $5;
            if (Lex->sp_block_finalize(YYTHD, $2))
              MYSQL_YYABORT;
            if (Lex->sp_block_end_label(YYTHD))
              MYSQL_YYABORT;
            if (Lex->sphead->check_routine_end_name($7))
              MYSQL_YYABORT;
          }
        ;

opt_sp_decl_body_list:
          /* Empty */
          { $$.init(); }
        | sp_decl_body_list { $$= $1; }
        ;

sp_decl_body_list:
          sp_decl_non_handler_list
          opt_sp_decl_handler_list
          {
            $$.join($1, $2);
          }
        | sp_decl_handler_list
        ;

sp_decl_non_handler_list:
          sp_decl_non_handler ';' { $$= $1; }
        | sp_decl_non_handler_list sp_decl_non_handler ';'
          {
            $$.join($1, $2);
          }
        ;

opt_sp_decl_handler_list:
          /* Empty */
          { $$.init(); }
        | sp_decl_handler_list
        ;

sp_decl_handler_list:
          sp_decl_handler ';' { $$= $1; }
        | sp_decl_handler_list sp_decl_handler ';'
          {
            $$.join($1, $2);
          }
        ;

sp_decl_handler:
          sp_handler_type HANDLER_SYM FOR_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp_pcontext *parent_pctx= lex->get_sp_current_parsing_ctx();

            sp_pcontext *handler_pctx=
              parent_pctx->push_context(thd, sp_pcontext::HANDLER_SCOPE);

            sp_handler *h=
              parent_pctx->add_handler(thd, (sp_handler::enum_type) $1);

            lex->set_sp_current_parsing_ctx(handler_pctx);

            sp_instr_hpush_jump *i=
              NEW_PTN sp_instr_hpush_jump(sp->instructions(), handler_pctx, h);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            if ($1 == sp_handler::CONTINUE)
            {
              // Mark the end of CONTINUE handler scope.

              if (sp->m_parser_data.add_backpatch_entry(
                    i, handler_pctx->last_label()))
              {
                MYSQL_YYABORT;
              }
            }

            if (sp->m_parser_data.add_backpatch_entry(
                  i, handler_pctx->push_label(thd, EMPTY_CSTR, 0)))
            {
              MYSQL_YYABORT;
            }

            lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // DECL HANDLER FOR
          }
          sp_hcond_list sp_proc_stmt
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *hlab= pctx->pop_label();

            if ($1 == sp_handler::CONTINUE)
            {
              sp_instr_hreturn *i=
                NEW_PTN sp_instr_hreturn(sp->instructions(), pctx);

              if (!i || sp->add_instr(thd, i))
                MYSQL_YYABORT;
            }
            else
            {  /* EXIT or UNDO handler, just jump to the end of the block */
              sp_instr_hreturn *i=
                NEW_PTN sp_instr_hreturn(sp->instructions(), pctx);

              if (i == NULL ||
                  sp->add_instr(thd, i) ||
                  sp->m_parser_data.add_backpatch_entry(i, pctx->last_label()))
                MYSQL_YYABORT;
            }

            sp->m_parser_data.do_backpatch(hlab, sp->instructions());

            lex->set_sp_current_parsing_ctx(pctx->pop_context());

            $$.vars= $$.conds= $$.curs= 0;
            $$.hndlrs= 1;
          }
        ;

opt_parenthesized_cursor_formal_parameters:
          /* Empty */
        | '('
           {
             Lex->sphead->m_parser_data.set_cursor_parameter_start_ptr(@1.cpp.end);
           }
           sp_fdparams
          ')'
           {
             Lex->sphead->m_parser_data.set_cursor_parameter_end_ptr(@4.cpp.start);
           }
        ;

sp_decl_cursor_return:
          /* Empty */ { $$= NULL; }
        | RETURN_SYM opt_qualified_column_ident PERCENT_ORACLE_SYM TYPE_SYM
          {
            $$= NEW_PTN Sp_decl_cursor_return(NULL_STR, $2, 2);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | RETURN_SYM opt_qualified_column_ident PERCENT_ORACLE_SYM ROWTYPE_ORACLE_SYM
          {
            $$= NEW_PTN Sp_decl_cursor_return(NULL_STR, $2, 1);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | RETURN_SYM sp_decl_ident
          {
            $$= NEW_PTN Sp_decl_cursor_return($2, nullptr, 0);
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

sp_decl_non_handler:
          sp_decl_variable_list
        | ident CONDITION_SYM FOR_SYM sp_cond
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (pctx->find_condition($1, true))
            {
              my_error(ER_SP_DUP_COND, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            if(pctx->add_condition(thd, $1, $4))
              MYSQL_YYABORT;
            lex->keep_diagnostics= DA_KEEP_DIAGNOSTICS; // DECLARE COND FOR
            $$.vars= $$.hndlrs= $$.curs= 0;
            $$.conds= 1;
          }
        | CURSOR_SYM  /*$1*/
          ident       /*$2*/
          {           /*$3*/
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
          }
          opt_parenthesized_cursor_formal_parameters  /*$4*/
          {/*$5*/
            Lex->sphead->m_parser_data.set_cursor_parameter_start_ptr(nullptr);
            Lex->sphead->m_parser_data.set_cursor_parameter_end_ptr(nullptr);
          }
          sp_decl_cursor_return  /*$6*/
          IS   /*$7*/
          {     /*$8*/
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
            sp->m_parser_data.set_current_stmt_start_ptr(@7.raw.end);
          }
          select_stmt   /*$9*/
          {
            MAKE_CMD($9);

            THD *thd= YYTHD;
            LEX *cursor_lex= Lex;
            sp_head *sp= cursor_lex->sphead;

            assert(cursor_lex->sql_command == SQLCOM_SELECT);

            if (cursor_lex->result)
            {
              my_error(ER_SP_BAD_CURSOR_SELECT, MYF(0));
              MYSQL_YYABORT;
            }

            cursor_lex->m_sql_cmd->set_as_part_of_sp();
            cursor_lex->sp_lex_in_use= true;
            sp_pcontext *pctx= cursor_lex->get_sp_current_parsing_ctx();

            if (sp->restore_lex(thd))
              MYSQL_YYABORT;

            if (Lex->sp_block_finalize(thd))
              MYSQL_YYABORT;

            LEX *lex= Lex;
            sp_pcontext *pctx_new= lex->get_sp_current_parsing_ctx();
            uint offp= 0;

            if (pctx_new->find_cursor($2, &offp, true))
            {
              my_error(ER_SP_DUP_CURS, MYF(0), $2.str);
              delete cursor_lex;
              MYSQL_YYABORT;
            }

            LEX_CSTRING cursor_query= EMPTY_CSTR;

            cursor_query=
              make_string(thd,
                            sp->m_parser_data.get_current_stmt_start_ptr(),
                            @9.raw.end);

            if (!cursor_query.str)
              MYSQL_YYABORT;

            uint off= 0;
            sp_instr_cpush_rowtype *i=
              NEW_PTN sp_instr_cpush_rowtype(sp->instructions(), pctx,
                                     cursor_lex, cursor_query,
                                     pctx_new->current_cursor_count());

            if (i == NULL ||
                sp->add_instr(thd, i) ||
                pctx_new->add_cursor_parameters(thd, $2, pctx, &off, nullptr))
            {
              MYSQL_YYABORT;
            }
            if($6 && Lex->set_static_cursor_with_return_type(thd, $6, off, $2)) {
              MYSQL_YYABORT;
            }
            $$.vars= $$.conds= $$.hndlrs= 0;
            $$.curs= 1;
          }
        | ident EXCEPTION_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            if (pctx->find_condition($1, true))
            {
              my_error(ER_SP_DUP_COND, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            auto exception_cond= NEW_PTN sp_oracle_condition_value();
            if (!exception_cond || pctx->add_condition(thd, $1, exception_cond))
              MYSQL_YYABORT;
            $$.vars= $$.hndlrs= $$.curs= 0;
            $$.conds= 1;
          }
        | PRAGMA_SYM EXCEPTION_INIT '(' ident ',' ulong_num ')'
          {
            if ($6 == 0)
            {
              my_error(ER_WRONG_VALUE, MYF(0), "CONDITION", "0");
              MYSQL_YYABORT;
            }

            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            auto cond = pctx->find_condition($4, true);
            if (cond == nullptr)
            {
              my_error(ER_WRONG_VALUE, MYF(0),"EXCEPTION_INIT", $4.str);
              MYSQL_YYABORT;
            }

            if (cond->m_is_user_defined) {
              auto ora_cond = static_cast<sp_oracle_condition_value*>(cond);
              ora_cond->set_redirect_err_to_user_defined($6);
            } else {
               my_error(ER_WRONG_VALUE, MYF(0),"EXCEPTION_INIT", $4.str);
              MYSQL_YYABORT;
            }
            $$.vars= $$.hndlrs= $$.curs= $$.conds= 0;
          }
        ;

sp_decl_variable_list:
          sp_decl_idents
          type
          opt_collate
          sp_opt_default
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp->reset_lex(thd);
            lex= thd->lex;

            pctx->declare_var_boundary($1);

            CONTEXTUALIZE($2);
            enum enum_field_types var_type= $2->type;
            const CHARSET_INFO *cs= $2->get_charset();
            if (merge_sp_var_charset_and_collation(cs, $3, &cs))
              MYSQL_YYABORT;

            uint num_vars= pctx->context_var_count();
            Item *dflt_value_item= $4.expr;

            LEX_CSTRING dflt_value_query= EMPTY_CSTR;

            if (dflt_value_item)
            {
              ITEMIZE(dflt_value_item, &dflt_value_item);
              const char *expr_start_ptr= $4.expr_start;
              if (lex->is_metadata_used())
              {
                dflt_value_query= make_string(thd, expr_start_ptr,
                                              @4.raw.end);
                if (!dflt_value_query.str)
                  MYSQL_YYABORT;
              }
            }
            else
            {
              dflt_value_item= NEW_PTN Item_null();

              if (dflt_value_item == NULL)
                MYSQL_YYABORT;
            }

            // Create an sp_instr_set instruction for each variable.
            uint nvars= $1;
            for (uint i = 0; i < nvars; i++) {
              sp_variable *spvar = pctx->get_last_context_variable((uint)nvars - 1 - i);

              if (!spvar)
                MYSQL_YYABORT;

              spvar->type= var_type;
              spvar->default_value= dflt_value_item;

              if (spvar->field_def.init(thd, "", var_type,
                                        $2->get_length(), $2->get_dec(),
                                        $2->get_type_flags(),
                                        NULL, NULL, &NULL_CSTR, 0,
                                        $2->get_interval_list(),
                                        cs ? cs : thd->variables.collation_database,
                                        $3 != nullptr, $2->get_uint_geom_type(), nullptr,
                                        nullptr, nullptr, {},
                                        dd::Column::enum_hidden_type::HT_VISIBLE))
              {
                MYSQL_YYABORT;
              }

              if (prepare_sp_create_field(thd, &spvar->field_def))
                MYSQL_YYABORT;

              spvar->field_def.field_name= spvar->name.str;
              spvar->field_def.is_nullable= true;

              /* The last instruction is responsible for freeing LEX. */
              sp_instr_set *is= NEW_PTN sp_instr_set(sp->instructions(),
                                                     lex,
                                                     spvar->offset,
                                                     dflt_value_item,
                                                     dflt_value_query,
                                                     (i == num_vars - 1),
                                                     pctx,
                                                     &sp_rcontext_handler_local);

              if (!is || sp->add_instr(thd, is))
                MYSQL_YYABORT;
            }

            pctx->declare_var_boundary(0);
            if (sp->restore_lex(thd))
              MYSQL_YYABORT;

            $$.vars= $1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | sp_decl_variable_list_anchored
          {
            $$.vars= $1.vars;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | TYPE_SYM sp_decl_ident IS
          RECORD_SYM
          {           /*$5*/
            Lex->sphead->reset_lex(YYTHD);
          }
          row_type_body
          {
            if (Lex->sphead->restore_lex(YYTHD))
              MYSQL_YYABORT;
            if (unlikely(Lex->sp_variable_declarations_row_finalize(YYTHD, $2, $6)))
              MYSQL_YYABORT;
            $$.vars= 1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | TYPE_SYM sp_decl_ident IS
          TABLE_SYM OF_SYM
          IDENT_sys  /*$6*/
          record_index_type /*$7*/
          {
            if (unlikely(Lex->sp_variable_declarations_type_table_finalize(YYTHD, $2, $6,
              $7->get_length(), $7->get_type_flags() ? false : true)))
              MYSQL_YYABORT;
            $$.vars= 1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | TYPE_SYM sp_decl_ident IS
          TABLE_SYM OF_SYM
          type /*$6*/
          record_index_type /*$7*/
          {
            if (unlikely(Lex->sp_variable_declarations_type_table_type_finalize(YYTHD, $2, $6,
              $7->get_length(), $7->get_type_flags() ? false : true)))
              MYSQL_YYABORT;
            $$.vars= 1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | TYPE_SYM sp_decl_ident IS
          TABLE_SYM OF_SYM
          opt_qualified_column_ident PERCENT_ORACLE_SYM ROWTYPE_ORACLE_SYM /*$6*/
          record_index_type /*$9*/
          {
            if (unlikely(Lex->sp_variable_declarations_type_table_rowtype_finalize(YYTHD, $2, $6,
              $9->get_length(), $9->get_type_flags() ? false : true)))
              MYSQL_YYABORT;
            $$.vars= 1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | sp_decl_idents IDENT_sys sp_opt_default
          {
            Lex->sphead->reset_lex(YYTHD);

            Item *dflt_value_item= $3.expr;
            LEX_CSTRING dflt_value_query= EMPTY_CSTR;
            if (dflt_value_item)
            {
              const char *expr_start_ptr= $3.expr_start;
              if (Lex->is_metadata_used())
              {
                dflt_value_query= make_string(YYTHD, expr_start_ptr,
                                              @3.raw.end);
                if (!dflt_value_query.str)
                  MYSQL_YYABORT;
              }
            }
            if (unlikely(Lex->sp_variable_declarations_record_finalize(YYTHD, $1, $2,
              dflt_value_item, dflt_value_query)))
              MYSQL_YYABORT;
            if (Lex->sphead->restore_lex(YYTHD))
              MYSQL_YYABORT;
            $$.vars= $1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | sp_decl_ident SYS_REFCURSOR_SYM
          {
            THD *thd = YYTHD;
            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offp= 0;
            if (pctx->find_cursor($1, &offp, false)) {
              my_error(ER_SP_DUP_CURS, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            // Add the cursor to variable list to separate out the ref cursor and normal cursor.
            sp_variable *spvar =
                pctx->add_variable(thd, $1, MYSQL_TYPE_DECIMAL, sp_variable::MODE_IN);

            if (spvar->field_def.init(
                    thd, $1.str, MYSQL_TYPE_NULL, nullptr, nullptr, 0, NULL, NULL, &NULL_CSTR,
                    0, nullptr, thd->variables.collation_database, false, 0, nullptr,
                    nullptr, nullptr, {}, dd::Column::enum_hidden_type::HT_VISIBLE)) {
              MYSQL_YYABORT;
            }

            if (prepare_sp_create_field(thd, &spvar->field_def)) {
              MYSQL_YYABORT;
            }
            spvar->field_def.ora_record.is_ref_cursor = true;
            spvar->field_def.ora_record.m_cursor_offset= offp;
            if (pctx->add_cursor_parameters(thd, $1, pctx, &offp, spvar)) {
              MYSQL_YYABORT;
            }
            $$.vars= 1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        | TYPE_SYM sp_decl_ident IS
          REF_SYM CURSOR_SYM sp_decl_cursor_return
          {
            if (unlikely(Lex->sp_variable_declarations_type_refcursor_finalize(YYTHD, $2, $6)))
              MYSQL_YYABORT;
            $$.vars= 1;
            $$.conds= $$.hndlrs= $$.curs= 0;
          }
        ;

record_index_type:
          /* empty */ { $$= NEW_PTN PT_numeric_type(YYTHD, Int_type::INT, NULL, UNSIGNED_FLAG); }
        | INDEX_SYM BY BINARY_INTEGER_SYM
          { $$= NEW_PTN PT_numeric_type(YYTHD, Int_type::INT, NULL, 0); }
        | INDEX_SYM BY INT_SYM
          { $$= NEW_PTN PT_numeric_type(YYTHD, Int_type::INT, NULL, 0); }
        | INDEX_SYM BY VARCHAR_SYM field_length
          { $$= NEW_PTN PT_char_type(Char_type::VARCHAR, $4, &my_charset_bin); }

row_field_definition:
          IDENT_sys type sp_opt_default
          {
            Item *dflt_value_item= $3.expr;
            if (!dflt_value_item)
            {
              dflt_value_item= NEW_PTN Item_null();

              if (dflt_value_item == NULL)
                MYSQL_YYABORT;
            }
            Create_field *cdf = NEW_PTN Create_field();
            const CHARSET_INFO *cs= $2->get_charset();
            if (cdf->init(
                    YYTHD, $1.str, $2->type, $2->get_length(), $2->get_dec(),
                    $2->get_type_flags(), NULL, NULL, &NULL_CSTR, 0,
                    $2->get_interval_list(), cs ? cs : YYTHD->variables.collation_database,
                    false, $2->get_uint_geom_type(), nullptr, nullptr, nullptr,
                    {}, dd::Column::enum_hidden_type::HT_VISIBLE)) {
              MYSQL_YYABORT;
            }
            cdf->ora_record.record_default_value = dflt_value_item;
            if (prepare_sp_create_field(YYTHD, cdf)) {
              MYSQL_YYABORT;
            }
            $$= cdf;
          }
        | IDENT_sys IDENT_sys sp_opt_default
          {
            Item *dflt_value_item= $3.expr;
            LEX_CSTRING dflt_value_query= EMPTY_CSTR;
            if (dflt_value_item)
            {
              const char *expr_start_ptr= $3.expr_start;
              if (Lex->is_metadata_used())
              {
                dflt_value_query= make_string(YYTHD, expr_start_ptr,
                                              @3.raw.end);
                if (!dflt_value_query.str)
                  MYSQL_YYABORT;
              }
            }
            Create_field *cdf = nullptr;
            if (!(cdf = Lex->sp_variable_declarations_definition_in_record(YYTHD, $1, $2,
              dflt_value_item)))
              MYSQL_YYABORT;
            $$= cdf;
          }
        ;

row_field_definition_list:
          row_field_definition
          {
            if (!($$= Row_definition_list::make(YYMEM_ROOT, $1)))
              MYSQL_YYABORT;
          }
        | row_field_definition_list ',' row_field_definition
          {
            if (($$= $1)->append_uniq(YYMEM_ROOT, $3))
              MYSQL_YYABORT;
          }
        ;

row_type_body:
          '(' row_field_definition_list ')'
          {
            $$= $2;
            $$->set_number(1);
          }
        ;

ora_simple_ident:
          IDENT_sys '.'
          {
            $$= new (YYMEM_ROOT) ora_simple_ident_def($1, nullptr);
          }
        | IDENT_sys '(' opt_expr_list ')' '.'
          {
            if(!$3 || $3->elements() != 1){
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "empty parameter or more than one parameter with table type");
              MYSQL_YYABORT;
            }
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp->reset_lex(thd);
            Item *item_int = $3->value.front();
            ITEMIZE(item_int, &item_int);
            if(sp->restore_lex(thd)) MYSQL_YYABORT;
            $$= new (YYMEM_ROOT) ora_simple_ident_def($1, item_int);
          }
        ;

ora_simple_ident_list:
          ora_simple_ident
          {
            $$= new (YYMEM_ROOT) List<ora_simple_ident_def>;
            if ($$ == NULL || $$->push_back($1))
              MYSQL_YYABORT;
          }
        | ora_simple_ident_list ora_simple_ident
          {
            $$= $1;
            if ($$->push_back($2))
              MYSQL_YYABORT;
          }
        ;

ora_set_statement:
          ora_set { $$= nullptr; CONTEXTUALIZE($1); }
        ;

ora_set:
          ora_assign_value_list
          {
            $$= NEW_PTN PT_set(@1, $1);
          }
        ;

ora_assign_value_list:
          ora_value ora_value_list_continued
          {
            $$= NEW_PTN PT_start_option_value_list_no_type($1, @1, $2);
          }
        ;

ora_value_list_continued:
          { $$= nullptr; }   //Empty
        | ',' ora_value_list { $$= $2; }
        ;

ora_value_list:
          ora_value
          {
            $$= NEW_PTN PT_option_value_list_head(@0, $1, @1);
          }
        | ora_value_list ',' ora_value
          {
            $$= NEW_PTN PT_option_value_list($1, @2, $3, @3);
          }
        ;

ora_value:
          ora_internal_variable_name
          SET_VAR
          set_expr_or_default
          {
            $$ = NEW_PTN PT_set_variable(@1, $1->bipartite_name.prefix,
            $1->bipartite_name.name, $1->medium, @3, $3, true);
          }
        ;

udt_index_expr:
          {
            YYTHD->lex->sphead->reset_lex(YYTHD);
          }
          expr
          {
            ITEMIZE($2, &$2);
            if(YYTHD->lex->sphead->restore_lex(YYTHD)) MYSQL_YYABORT;
            $$= $2;
          }
        ;

ora_internal_variable_name:
          ora_value_ident
          {
            Bipartite_name bipartite_name{{}, to_lex_cstring($1)};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, nullptr);
          }
        | ora_value_ident '.' ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (sp && (sp->m_type == enum_sp_type::TRIGGER))
            {
              my_error(ER_ERROR_IN_TRIGGER_BODY, MYF(0), sp->name(), YYTHD->strmake(@1.raw.start, @3.raw.end - @1.raw.start));
              MYSQL_YYABORT;
            }
            /*
              Reject names prefixed by `GLOBAL.`, `LOCAL.`, or `SESSION.` --
              if one of those prefixes is there then we are parsing something
              like `GLOBAL.GLOBAL.foo` or `LOCAL.SESSION.bar` etc.
            */
            if (check_reserved_words($1.str)) {
              YYTHD->syntax_error_at(@1);
              MYSQL_YYABORT;
            }
            Bipartite_name bipartite_name{to_lex_cstring($1), to_lex_cstring($3)};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, nullptr);
          }
        | ':' ora_value_ident '.' ident
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            if (sp->m_type != enum_sp_type::TRIGGER)
            {
              my_error(ER_SP_BADSTATEMENT, MYF(0), YYTHD->strmake(@1.raw.start, @4.raw.end - @1.raw.start));
              MYSQL_YYABORT;
            }
            Bipartite_name bipartite_name{to_lex_cstring($2), to_lex_cstring($4)};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, nullptr);
          }
        | ora_value_ident '(' udt_index_expr ')'
          {
            ora_simple_ident_def *def= NEW_PTN ora_simple_ident_def($1, $3);
            List<ora_simple_ident_def> *def_list= new (YYMEM_ROOT) List<ora_simple_ident_def>;
            if(def_list->push_front(def)) MYSQL_YYABORT;
            Bipartite_name bipartite_name{{}, {}};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, def_list);
          }
        | ora_value_ident '(' udt_index_expr ')' '.' ident
          {
            ora_simple_ident_def *def= NEW_PTN ora_simple_ident_def($1, $3);
            List<ora_simple_ident_def> *def_list= new (YYMEM_ROOT) List<ora_simple_ident_def>;
            if(def_list->push_front(def)) MYSQL_YYABORT;
            Bipartite_name bipartite_name{{}, to_lex_cstring($6)};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, def_list);
          }
        | ora_value_ident '.' ora_simple_ident_list ident
          {
            ora_simple_ident_def *def= NEW_PTN ora_simple_ident_def($1, nullptr);
            if($3->push_front(def)) MYSQL_YYABORT;
            Bipartite_name bipartite_name{{}, to_lex_cstring($4)};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, $3);
          }
        | ora_value_ident '(' udt_index_expr ')' '.' ora_simple_ident_list ident
          {
            ora_simple_ident_def *def= NEW_PTN ora_simple_ident_def($1, $3);
            if($6->push_front(def)) MYSQL_YYABORT;
            Bipartite_name bipartite_name{{}, to_lex_cstring($7)};
            $$ = NEW_PTN Bipartite_name_ora(bipartite_name, $6);
          }
        ;

ora_value_ident:
          IDENT_sys
        | ora_value_keyword
          {
            $$.str= YYTHD->strmake($1.str, $1.length);
            if ($$.str == NULL)
              MYSQL_YYABORT;
            $$.length= $1.length;
          }
        ;

ora_value_keyword:
          ident_keywords_unambiguous
        | ident_keywords_ambiguous_2_labels
        | ident_keywords_ambiguous_3_roles
        | ident_keywords_ambiguous_5_not_sp_variables
        | ident_keywords_ambiguous_6_not_table_alias
        ;

sp_elseifs:
          /* Empty */
        | ELSIF_ORACLE_SYM sp_if
        | ELSE
          {
            if (Lex->sp_if_sp_block_init(YYTHD))
              MYSQL_YYABORT;
          }
          sp_proc_stmts1
          {
            Lex->sp_if_sp_block_finalize(YYTHD);
          }
        ;

sp_proc_stmt_exit_oracle:
          EXIT_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp = lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label_current_loop_start();
            if (! lab)
            {
              my_error(ER_SP_LILABEL_MISMATCH, MYF(0), "EXIT", "");
              MYSQL_YYABORT;
            }

            sp_instr_jump *i= NEW_PTN sp_instr_jump(sp->instructions(), pctx);

            if (!i ||
                // Jumping forward
                sp->m_parser_data.add_backpatch_entry(i, lab) ||
                sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        | EXIT_SYM label_ident
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp = lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($2);

            if (! lab || lab->type != sp_label::ITERATION)
            {
              my_error(ER_SP_LILABEL_MISMATCH, MYF(0), "EXIT", $2.str);
              MYSQL_YYABORT;
            }

            sp_instr_jump *i= NEW_PTN sp_instr_jump(sp->instructions(), pctx);

            if (!i ||
                // Jumping forward
                sp->m_parser_data.add_backpatch_entry(i, lab) ||
                sp->add_instr(thd, i))
              MYSQL_YYABORT;
          }
        | EXIT_SYM
          WHEN_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr
          {
            ITEMIZE($4, &$4);
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label_current_loop_start();
            if (! lab || lab->type != sp_label::ITERATION)
            {
              my_error(ER_SP_LILABEL_MISMATCH, MYF(0), "EXIT", "");
              MYSQL_YYABORT;
            }

            // Extract expression string.

            LEX_CSTRING expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @3.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @4.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }
            sp_instr_jump_if_not *i=
              NEW_PTN sp_instr_jump_if_not(sp->instructions(), lex,
                                           $4, expr_query);

            // Add jump instruction.

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                //sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
            sp_instr_jump *i_jump_end= NEW_PTN sp_instr_jump(sp->instructions(), pctx);

            if (!i_jump_end ||
                // Jumping forward
                sp->m_parser_data.add_backpatch_entry(i_jump_end, lab) ||
                sp->add_instr(thd, i_jump_end))
              MYSQL_YYABORT;

            sp->m_parser_data.do_backpatch(pctx->pop_label(), sp->instructions());
          }
        | EXIT_SYM
          label_ident
          WHEN_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr
          {
            ITEMIZE($5, &$5);
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($2);
            if (! lab || lab->type != sp_label::ITERATION)
            {
              my_error(ER_SP_LILABEL_MISMATCH, MYF(0), "EXIT", $2.str);
              MYSQL_YYABORT;
            }
            // Extract expression string.

            LEX_CSTRING expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @4.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @5.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }
            sp_instr_jump_if_not *i=
              NEW_PTN sp_instr_jump_if_not(sp->instructions(), lex,
                                           $5, expr_query);

            // Add jump instruction.

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                //sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
            sp_instr_jump *i_jump_end= NEW_PTN sp_instr_jump(sp->instructions(), pctx);

            if (!i_jump_end ||
                // Jumping forward
                sp->m_parser_data.add_backpatch_entry(i_jump_end, lab) ||
                sp->add_instr(thd, i_jump_end))
              MYSQL_YYABORT;

            sp->m_parser_data.do_backpatch(pctx->pop_label(), sp->instructions());
          }
        ;

sp_proc_stmt_continue_oracle:
          CONTINUE_SYM
          {
            if (unlikely(Lex->sp_continue_statement(YYTHD, NULL_CSTR)))
              MYSQL_YYABORT;
          }
        | CONTINUE_SYM label_ident
          {
            if (unlikely(Lex->sp_continue_statement(YYTHD, $2)))
              MYSQL_YYABORT;
          }
        | CONTINUE_SYM WHEN_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr
          {
            ITEMIZE($4, &$4);
            if (unlikely(Lex->sp_continue_when_statement(YYTHD, NULL_CSTR, $4, @3.raw.end, @4.raw.end)))
              MYSQL_YYABORT;
          }
        | CONTINUE_SYM label_ident WHEN_SYM
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
          }
          expr /*5*/
          {
            ITEMIZE($5, &$5);
            if (unlikely(Lex->sp_continue_when_statement(YYTHD, $2, $5, @4.raw.end, @5.raw.end)))
              MYSQL_YYABORT;
          }
        ;

plsql_cursor_attr:
          ISOPEN_SYM    { $$= plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_ISOPEN; }
        | FOUND_SYM     { $$= plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_FOUND; }
        | NOTFOUND_SYM  { $$= plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_NOTFOUND; }
        | ROWCOUNT_SYM  { $$= plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_ROWCOUNT; }
        ;

explicit_cursor_attr:
          ident PERCENT_ORACLE_SYM plsql_cursor_attr
          {
            LEX *lex= Lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_head *sp= lex->sphead;
            uint offset= 0;
            if (!sp || !pctx || !pctx->find_cursor($1, &offset, false))
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            sp_pcursor *pc = pctx->find_cursor_parameters(offset);
            if(!pc)
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            switch ($3) {
              case plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_ISOPEN:
                $$= NEW_PTN Item_func_cursor_isopen(to_lex_cstring($1.str), offset, pc->get_cursor_spv());
                break;
              case plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_FOUND:
                $$= NEW_PTN Item_func_cursor_found(to_lex_cstring($1.str), offset, pc->get_cursor_spv());
                break;
              case plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_NOTFOUND:
                $$= NEW_PTN Item_func_cursor_notfound(to_lex_cstring($1.str), offset, pc->get_cursor_spv());
                break;
              case plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_ROWCOUNT:
                $$= NEW_PTN Item_func_cursor_rowcount(@$, to_lex_cstring($1.str), offset, pc->get_cursor_spv());
                break;              
              default:
                YYTHD->syntax_error_at(@3);
                MYSQL_YYABORT;
            }
          }
        ;

implicit_cursor_attr:
          SQL_SYM PERCENT_ORACLE_SYM plsql_cursor_attr
          {
            LEX *lex= Lex;
            if (!lex || !lex->sphead)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }

            switch ($3) {
              case plsql_cursor_attr_type::PLSQL_CURSOR_ATTR_ROWCOUNT:
                $$= NEW_PTN Item_func_implicit_cursor_rowcount(@$);
                break;
              default:
                YYTHD->syntax_error_at(@3);
                MYSQL_YYABORT;
            }
          }

sp_labeled_control:
          label_ident_ora
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->find_label($1);

            if (lab)
            {
              my_error(ER_SP_LABEL_REDEFINE, MYF(0), $1.str);
              MYSQL_YYABORT;
            }
            else
            {
              lab= pctx->push_label(YYTHD, $1, sp->instructions());
              lab->type= sp_label::ITERATION;
            }
          }
          sp_unlabeled_control_ora sp_opt_label
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_label *lab= pctx->pop_label();

            if ($4.str)
            {
              if (my_strcasecmp(system_charset_info, $4.str, lab->name.str) != 0)
              {
                my_error(ER_SP_LABEL_MISMATCH, MYF(0), $4.str);
                MYSQL_YYABORT;
              }
            }
            sp->m_parser_data.do_backpatch(lab, sp->instructions());

            if($3.curs == 1)
            {
              if(lex->close_ref_cursor(YYTHD, $3.vars))
                MYSQL_YYABORT;
            }
          }
        ;

sp_proc_stmt_unlabeled:
          { /* Unlabeled controls get a secret label. */
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_label *lab=pctx->push_label(thd,
                             EMPTY_CSTR,
                             sp->instructions());
            /*For sp_proc_stmt_exit_oracle and sp_pcontext::find_label_current_loop_start*/
            lab->type= sp_label::ITERATION;
          }
          sp_unlabeled_control_ora
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp->m_parser_data.do_backpatch(pctx->pop_label(),
                                           sp->instructions());
            // When the loop is end,it must close the cursor.
            if($2.curs == 1)
            {
              if(lex->close_ref_cursor(YYTHD, $2.vars))
                MYSQL_YYABORT;
            }
          }
        ;

opt_qualified_column_ident:
          sp_decl_ident
          {
            $$= NEW_PTN Qualified_column_ident(to_lex_cstring($1));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | sp_decl_ident '.' ident
          {
            $$= NEW_PTN Qualified_column_ident(to_lex_cstring($1), to_lex_cstring($3));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        | sp_decl_ident '.' ident '.' ident
          {
            $$= NEW_PTN Qualified_column_ident(to_lex_cstring($1), to_lex_cstring($3), to_lex_cstring($5));
            if ($$ == NULL)
              MYSQL_YYABORT;
          }
        ;

sp_decl_variable_list_anchored:
          sp_decl_idents
          opt_qualified_column_ident PERCENT_ORACLE_SYM TYPE_SYM
          {
            if (unlikely(Lex->sp_variable_declarations_with_ref_finalize(YYTHD, $1, $2)))
              MYSQL_YYABORT;
            $$.init();
            $$.vars= $1;
          }
        | sp_decl_idents
          opt_qualified_column_ident PERCENT_ORACLE_SYM ROWTYPE_ORACLE_SYM
          {
            if (unlikely(Lex->sp_variable_declarations_rowtype_finalize(YYTHD, $1, $2)))
              MYSQL_YYABORT;
            $$.init();
            $$.vars= $1;
          }
        ;

sp_proc_stmt_fetch_ora:
          FETCH_SYM  /*$1*/
          ident      /*$2*/
          INTO       /*$3*/
          {          /*$4*/
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offset= 0;

            if (! pctx->find_cursor($2, &offset, false))
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $2.str);
              MYSQL_YYABORT;
            }

            sp_instr_cfetch *i= NEW_PTN sp_instr_cfetch(sp->instructions(),
                                                        pctx, offset);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            sp_variable *spvar= pctx->find_variable($2.str, $2.length, false);
            if (spvar && spvar->field_def.ora_record.is_ref_cursor)
            {
              i->set_sysrefcursor_spvar(spvar);
            }
          }
          sp_fetch_list
          {}
        | FETCH_SYM  /*$1*/
          ident      /*$2*/
          BULK_COLLECT_SYM
          INTO       /*$4*/
          {
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            uint offset= 0;

            if (! pctx->find_cursor($2, &offset, false))
            {
              my_error(ER_SP_CURSOR_MISMATCH, MYF(0), $2.str);
              MYSQL_YYABORT;
            }

            sp_instr_cfetch_bulk *i= NEW_PTN sp_instr_cfetch_bulk(sp->instructions(),
                                                        pctx, offset);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            sp_variable *spvar= pctx->find_variable($2.str, $2.length, false);
            if (spvar && spvar->field_def.ora_record.is_ref_cursor)
            {
              i->set_sysrefcursor_spvar(spvar);
            }
          }
          ident /*$6*/
          opt_bulk_limit_ora /*$7*/
          {
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_variable *spv;

            if (!pctx || !(spv= pctx->find_variable($6.str, $6.length, false)))
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $6.str);
              MYSQL_YYABORT;
            }
            if (!spv->field_def.ora_record.row_field_table_definitions() ||
            spv->field_def.ora_record.is_record_define) {
              my_error(ER_SP_MISMATCH_RECORD_TABLE_VAR, MYF(0), $6.str);
              MYSQL_YYABORT;
            }
            if(spv->field_def.ora_record.is_ref_cursor) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                "the type of variable used in 'into list'");
              MYSQL_YYABORT;
            }
            if (!spv->field_def.ora_record.row_field_table_definitions() ||
            spv->field_def.ora_record.is_record_define) {
              my_error(ER_SP_MISMATCH_RECORD_TABLE_VAR, MYF(0), $6.str);
              MYSQL_YYABORT;
            }
            /* An SP local variable */
            sp_instr_cfetch_bulk *i= (sp_instr_cfetch_bulk *)sp->last_instruction();
            i->add_to_varlist(spv);
            if($7) {
              Item_int *item = dynamic_cast<Item_int *>($7);
              i->set_row_count(item->value);
            } else
              i->set_row_count(-1);
          }
        ;

opt_bulk_limit_ora:
          /* empty */        { $$= NULL; }
        | LIMIT int64_literal { $$= $2; }
        ;

sp_proc_stmt_open_ora:
          OPEN_SYM
          ident
          {           /*$3*/
            Lex->sphead->reset_lex(YYTHD);
          }
          opt_parenthesized_cursor_actual_parameters
          {
            if (unlikely(Lex->sp_open_cursor(YYTHD, $2, $4)))
              MYSQL_YYABORT;
            if (Lex->sphead->restore_lex(YYTHD))
              MYSQL_YYABORT;
          }
        | OPEN_SYM
          ident       /*$2*/
          FOR_SYM     /*$3*/
          {           /*$4*/
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
            sp->m_parser_data.set_current_stmt_start_ptr(@3.raw.end);
          }
          opt_open_cursor_for_stmt /*$5*/
          {
            if (unlikely(Lex->sp_open_cursor_for(YYTHD, $5, $2, @5.raw.end)))
              MYSQL_YYABORT;
          }
        ;

opt_parenthesized_cursor_actual_parameters:
          /* Empty */    { $$= NULL; }
        | '(' opt_udf_expr_list ')'
          {
            if($2 != NULL){
              uint param_count =$2->elements();
              $$= NEW_PTN PT_item_list;
              for (uint idx = 0; idx<param_count; idx++) {
                Item *prm = $2->value.at(idx);
                ITEMIZE(prm, &prm);
                if ($$->push_back(prm))
                  MYSQL_YYABORT;
              }
            } else {
              $$= NULL;
            }

          }
        ;

opt_open_cursor_for_stmt:
          ora_value_ident
          {
            $$= $1;
          }
        | select_stmt
          {
            MAKE_CMD($1);
            if (Lex->result)
            {
              my_error(ER_SP_BAD_CURSOR_SELECT, MYF(0));
              MYSQL_YYABORT;
            }
            $$= NULL_STR;
          }
        ;

ora_sp_forall_loop:
          FORALL_SYM   /*$1*/
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            if (Lex->sp_block_init(YYTHD))
              MYSQL_YYABORT;
            sp_head *sp= lex->sphead;
            sp->reset_lex(thd);
          }
          sp_for_loop_index_and_bounds
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp_head *sp= lex->sphead;
            if($3->is_cursor) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                      "cursor used in forall loop");
              MYSQL_YYABORT;
            }
            if($3->direction == -1) {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),
                      "reverse used in forall loop");
              MYSQL_YYABORT;
            }
            sp_variable *spvar_ident_i =
                pctx->find_variable($3->cursor_var.str, $3->cursor_var.length, false);
            if (!spvar_ident_i)
            {
              my_error(ER_SP_UNDECLARED_VAR, MYF(0), $3->cursor_var.str);
              MYSQL_YYABORT;
            }
            spvar_ident_i->field_def.ora_record.is_forall_loop_var = true;
            Item *tmp = NEW_PTN Item_func_uuid_short(@$);
            if (unlikely(tmp == NULL))
              MYSQL_YYABORT;
            Item *item_upper= nullptr;
            if(Lex->make_temp_upper_bound_variable_and_set(YYTHD, tmp,
              $3->direction > 0 , $3->from,
              $3->jump_condition, &item_upper, $3->cursor_var))
              MYSQL_YYABORT;
            Item *expr= nullptr;
            if ( ! (expr = pctx->make_item_plsql_sp_for_loop_attr(thd, $3->direction,
              $3->cursor_var_item, item_upper)))
              MYSQL_YYABORT;

            sp_instr_jump_if_not *i=
              NEW_PTN sp_instr_jump_if_not(sp->instructions(),
              lex, expr,EMPTY_CSTR);

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                sp->m_parser_data.new_cont_backpatch() ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
            Lex->sphead->reset_lex(thd);
          }
          insert_stmt  /*$5*/
          {
            PT_insert *insert= dynamic_cast<PT_insert *>($5);
            if(!insert->is_forall_insert)
            {
              my_error(ER_NOT_SUPPORTED_YET, MYF(0),"this value in forall statment");
              MYSQL_YYABORT;
            }
            MAKE_CMD($5);
            LEX_CSTRING query = make_string(
                YYTHD, @5.raw.start, @5.raw.end);

            if (!query.str) MYSQL_YYABORT;
            $$= NEW_PTN Ora_sp_forall_loop($3->cursor_var,$3->start_ident_pos,$3->end_ident_pos,query);
            if (!$$)
              MYSQL_YYABORT_ERROR(ER_DA_OOM, MYF(0)); /* purecov: inspected */
          }
        ;

ora_sp_forall_loop_ora:
          ora_sp_forall_loop
          {
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp->m_flags|= sp_get_flags_for_command(lex);

            if (sp->m_type != enum_sp_type::PROCEDURE && sp->m_type != enum_sp_type::FUNCTION)
            {
              my_error(ER_SP_BAD_USE_PROC, MYF(0));
              MYSQL_YYABORT;
            }
            if(lex->m_sql_cmd != nullptr)
              lex->m_sql_cmd->set_as_part_of_sp();
            if (unlikely(Lex->ora_sp_forall_loop_insert_value(thd,
              $1->query,$1->ident_i,$1->start,$1->end)))
                MYSQL_YYABORT;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            Lex->set_sp_current_parsing_ctx(pctx->pop_context());
          }
        ;

trg_predicate_event:
            INSERTING
            { $$= TRG_EVENT_INSERT; }
          | UPDATING
            { $$= TRG_EVENT_UPDATE; }
          | DELETING
            { $$= TRG_EVENT_DELETE; }
          ;

opt_trigger_even_column:
             /* empty */ { $$= NULL;}
          | '(' bit_expr ')' { $$= $2; }
          ;

sp_trigger_stmt_when_ora:
          WHEN_SYM
          { Lex->sphead->m_parser_data.new_cont_backpatch(); }
          sp_trigger_when
          {
            sp_head *sp= Lex->sphead;

            sp->m_parser_data.do_cont_backpatch(sp->instructions());
          }
        ;

sp_trigger_when:
          {                     /*$1*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;

            sp->reset_lex(thd);
            sp->m_trg_chistics.trigger_when_expr= true;
          }
          '(' expr ')'          /*$2 $3 $4*/
          {                     /*$5*/
            THD *thd= YYTHD;
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();
            sp->m_trg_chistics.trigger_when_expr= false;

            ITEMIZE($3, &$3);

            /* Extract expression string. */

            LEX_CSTRING expr_query= EMPTY_CSTR;
            const char *expr_start_ptr= @0.raw.end;

            if (lex->is_metadata_used())
            {
              expr_query= make_string(thd, expr_start_ptr, @3.raw.end);
              if (!expr_query.str)
                MYSQL_YYABORT;
            }

            sp_instr_jump_if_not *i =
              NEW_PTN sp_instr_jump_if_not(sp->instructions(), lex,
                                           $3, expr_query);

            /* Add jump instruction. */

            if (i == NULL ||
                sp->m_parser_data.add_backpatch_entry(
                  i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions())) ||
                sp->m_parser_data.add_cont_backpatch_entry(i) ||
                sp->add_instr(thd, i) ||
                sp->restore_lex(thd))
            {
              MYSQL_YYABORT;
            }
          }
          sp_block_ora /*$6*/
          {                     /*$7*/
            THD *thd= YYTHD;
            LEX *lex= thd->lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp_instr_jump *i = NEW_PTN sp_instr_jump(sp->instructions(), pctx);

            if (!i || sp->add_instr(thd, i))
              MYSQL_YYABORT;

            sp->m_parser_data.do_backpatch(pctx->pop_label(),
                                           sp->instructions());

            sp->m_parser_data.add_backpatch_entry(
              i, pctx->push_label(thd, EMPTY_CSTR, sp->instructions()));
          }
          {                     /*$8*/
            LEX *lex= Lex;
            sp_head *sp= lex->sphead;
            sp_pcontext *pctx= lex->get_sp_current_parsing_ctx();

            sp->m_parser_data.do_backpatch(pctx->pop_label(),
                                           sp->instructions());
          }
        ;

%endif
/**
  @} (end of group Parser)
*/
