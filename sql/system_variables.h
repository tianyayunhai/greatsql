/* Copyright (c) 2015, 2021, Oracle and/or its affiliates.
   Copyright (c) 2022, Huawei Technologies Co., Ltd.
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

#ifndef SYSTEM_VARIABLES_INCLUDED
#define SYSTEM_VARIABLES_INCLUDED

#include <stddef.h>
#include <sys/types.h>

#include "m_ctype.h"
#include "my_base.h"  // ha_rows
#include "my_inttypes.h"
#include "my_sqlcommand.h"
#include "my_thread_local.h"     // my_thread_id
#include "mysqld_error.h"
#include "sql/rpl_gtid.h"        // Gitd_specification
#include "sql/sql_plugin_ref.h"  // plugin_ref
#include "sql_string.h"

class MY_LOCALE;
class Time_zone;

typedef ulonglong sql_mode_t;
struct LIST;

// Values for binlog_format sysvar
enum enum_binlog_format {
  BINLOG_FORMAT_MIXED = 0,  ///< statement if safe, otherwise row - autodetected
  BINLOG_FORMAT_STMT = 1,   ///< statement-based
  BINLOG_FORMAT_ROW = 2,    ///< row-based
  BINLOG_FORMAT_UNSPEC =
      3  ///< thd_binlog_format() returns it when binlog is closed
};

// Values for rbr_exec_mode_options sysvar
enum enum_rbr_exec_mode {
  RBR_EXEC_MODE_STRICT,
  RBR_EXEC_MODE_IDEMPOTENT,
  RBR_EXEC_MODE_LAST_BIT
};

// Values for binlog_row_image sysvar
enum enum_binlog_row_image {
  /** PKE in the before image and changed columns in the after image */
  BINLOG_ROW_IMAGE_MINIMAL = 0,
  /** Whenever possible, before and after image contain all columns except
     blobs. */
  BINLOG_ROW_IMAGE_NOBLOB = 1,
  /** All columns in both before and after image. */
  BINLOG_ROW_IMAGE_FULL = 2
};

// Bits for binlog_row_value_options sysvar
enum enum_binlog_row_value_options {
  /// Store JSON updates in partial form
  PARTIAL_JSON_UPDATES = 1
};

// Values for binlog_row_metadata sysvar
enum enum_binlog_row_metadata {
  BINLOG_ROW_METADATA_MINIMAL = 0,
  BINLOG_ROW_METADATA_FULL = 1
};

// Values for transaction_write_set_extraction sysvar
enum enum_transaction_write_set_hashing_algorithm {
  HASH_ALGORITHM_OFF = 0,
  HASH_ALGORITHM_MURMUR32 = 1,
  HASH_ALGORITHM_XXHASH64 = 2
};

// Values for session_track_gtids sysvar
enum enum_session_track_gtids {
  SESSION_TRACK_GTIDS_OFF = 0,
  SESSION_TRACK_GTIDS_OWN_GTID = 1,
  SESSION_TRACK_GTIDS_ALL_GTIDS = 2
};

/** Values for use_secondary_engine sysvar. */
enum use_secondary_engine {
  SECONDARY_ENGINE_OFF = 0,
  SECONDARY_ENGINE_ON = 1,
  SECONDARY_ENGINE_FORCED = 2
};

// Values for default_table_encryption
enum enum_default_table_encryption {
  DEFAULT_TABLE_ENC_OFF = 0,
  DEFAULT_TABLE_ENC_ON = 1,
};
enum enum_udt_format_result { UDT_FORMAT_RESULT_BINARY, UDT_FORMAT_RESULT_DBA };
/**
  Values for explain_format sysvar.

  The value "TRADITIONAL_STRICT" is meant only to be used by the mtr test
  suite. With hypergraph optimizer, if explain_format value is TRADITIONAL,
  EXPLAIN without a format specifier prints in TREE format. The mtr tests were
  written *before* this traditional-tree conversion was introduced. So mtr was
  designed to just ignore the "format not supported with hypergraph" error when
  a test runs an EXPLAIN without format specifier with --hypergraph. With the
  conversion introduced, EXPLAIN without format specifier therefore would have
  output in different formats with and without the mtr --hypergraph option.  In
  order for the mtr tests to be able to continue to pass, mtr internally sets
  explain_format to TRADITIONAL_STRICT so that these statements continue to
  error out rather than print TREE format as they would do with TRADITIONAL
  format. This is a temporary stuff.  Once all tests start using TREE format,
  we will deprecate this value.
*/
enum class Explain_format_type : ulong {
  TRADITIONAL = 0,
  TRADITIONAL_STRICT = 1,
  TREE = 2,
  JSON = 3
};

/* Bits for different SQL modes modes (including ANSI mode) */
#define MODE_REAL_AS_FLOAT 1
#define MODE_PIPES_AS_CONCAT 2
#define MODE_ANSI_QUOTES 4
#define MODE_IGNORE_SPACE 8
#define MODE_NOT_USED 16
#define MODE_ONLY_FULL_GROUP_BY 32
#define MODE_NO_UNSIGNED_SUBTRACTION 64
#define MODE_NO_DIR_IN_CREATE 128

#define MODE_ORACLE (1ULL << 9)
#define MODE_ANSI 262144L  //  (1ULL << 18)
#define MODE_NO_AUTO_VALUE_ON_ZERO (MODE_ANSI * 2)
#define MODE_NO_BACKSLASH_ESCAPES (MODE_NO_AUTO_VALUE_ON_ZERO * 2)
#define MODE_STRICT_TRANS_TABLES (MODE_NO_BACKSLASH_ESCAPES * 2)
#define MODE_STRICT_ALL_TABLES (MODE_STRICT_TRANS_TABLES * 2)
/*
 * NO_ZERO_DATE, NO_ZERO_IN_DATE and ERROR_FOR_DIVISION_BY_ZERO modes are
 * removed in 5.7 and their functionality is merged with STRICT MODE.
 * However, For backward compatibility during upgrade, these modes are kept
 * but they are not used. Setting these modes in 5.7 will give warning and
 * have no effect.
 */
#define MODE_NO_ZERO_IN_DATE (MODE_STRICT_ALL_TABLES * 2)
#define MODE_NO_ZERO_DATE (MODE_NO_ZERO_IN_DATE * 2)
#define MODE_INVALID_DATES (MODE_NO_ZERO_DATE * 2)
#define MODE_ERROR_FOR_DIVISION_BY_ZERO (MODE_INVALID_DATES * 2)
#define MODE_TRADITIONAL (MODE_ERROR_FOR_DIVISION_BY_ZERO * 2)
#define MODE_HIGH_NOT_PRECEDENCE (1ULL << 29)
#define MODE_NO_ENGINE_SUBSTITUTION (MODE_HIGH_NOT_PRECEDENCE * 2)
#define MODE_PAD_CHAR_TO_FULL_LENGTH (1ULL << 31)
/*
  If this mode is set the fractional seconds which cannot fit in given fsp will
  be truncated.
*/
#define MODE_TIME_TRUNCATE_FRACTIONAL (1ULL << 32)
// sysdate_is_now
#define MODE_SYSDATE_IS_NOW (1ULL << 33)

/*
  The empty string is equal to null in MODE_EMPTYSTRING_EQUAL_NULL mode
*/
#define MODE_EMPTYSTRING_EQUAL_NULL (1ULL << 34)

#define MODE_LAST (1ULL << 35)

#define MODE_ALLOWED_MASK                                                      \
  (MODE_REAL_AS_FLOAT | MODE_PIPES_AS_CONCAT | MODE_ANSI_QUOTES |              \
   MODE_IGNORE_SPACE | MODE_NOT_USED | MODE_ONLY_FULL_GROUP_BY |               \
   MODE_NO_UNSIGNED_SUBTRACTION | MODE_NO_DIR_IN_CREATE | MODE_ANSI |          \
   MODE_NO_AUTO_VALUE_ON_ZERO | MODE_NO_BACKSLASH_ESCAPES |                    \
   MODE_STRICT_TRANS_TABLES | MODE_STRICT_ALL_TABLES | MODE_NO_ZERO_IN_DATE |  \
   MODE_NO_ZERO_DATE | MODE_INVALID_DATES | MODE_ERROR_FOR_DIVISION_BY_ZERO |  \
   MODE_TRADITIONAL | MODE_HIGH_NOT_PRECEDENCE | MODE_NO_ENGINE_SUBSTITUTION | \
   MODE_PAD_CHAR_TO_FULL_LENGTH | MODE_TIME_TRUNCATE_FRACTIONAL |              \
   MODE_ORACLE | MODE_SYSDATE_IS_NOW | MODE_EMPTYSTRING_EQUAL_NULL)

/*
  We can safely ignore and reset these obsolete mode bits while replicating:
*/
#define MODE_IGNORED_MASK                         \
  (0x00100 |  /* was: MODE_POSTGRESQL          */ \
   0x00400 |  /* was: MODE_MSSQL               */ \
   0x00800 |  /* was: MODE_DB2                 */ \
   0x01000 |  /* was: MODE_MAXDB               */ \
   0x02000 |  /* was: MODE_NO_KEY_OPTIONS      */ \
   0x04000 |  /* was: MODE_NO_TABLE_OPTIONS    */ \
   0x08000 |  /* was: MODE_NO_FIELD_OPTIONS    */ \
   0x10000 |  /* was: MODE_MYSQL323            */ \
   0x20000 |  /* was: MODE_MYSQL40             */ \
   0x10000000 /* was: MODE_NO_AUTO_CREATE_USER */ \
  )

/*
  Replication uses 8 bytes to store SQL_MODE in the binary log. The day you
  use strictly more than 64 bits by adding one more define above, you should
  contact the replication team because the replication code should then be
  updated (to store more bytes on disk).

  NOTE: When adding new SQL_MODE types, make sure to also add them to
  the scripts used for creating the MySQL system tables
  in scripts/mysql_system_tables.sql and scripts/mysql_system_tables_fix.sql
*/

/** Page fragmentation statistics */
struct fragmentation_stats_t {
  ulonglong scan_pages_contiguous;          /*!< number of contiguous InnoDB
                                              page reads inside a query */
  ulonglong scan_pages_disjointed;          /*!< number of disjointed InnoDB
                                              page reads inside a query */
  ulonglong scan_pages_total_seek_distance; /*!< total seek distance between
                                              InnoDB pages */
  ulonglong scan_data_size;                 /*!< size of data in all InnoDB
                                              pages read inside a query
                                              (in bytes) */
  ulonglong scan_deleted_recs_size;         /*!< size of deleded records in
                                              all InnoDB pages read inside a
                                              query (in bytes) */
};

class Query_errors_set {
 public:
  static constexpr uint8_t MAX_CODES_NUM = 64;
  static constexpr uint32_t MAX_TEXT_LENGTH =
      std::numeric_limits<uint32_t>::digits10 * MAX_CODES_NUM + MAX_CODES_NUM;
  static const String LOG_ALL;

 private:
  bool is_all_set;
  uint32_t codes[MAX_CODES_NUM];

  void set_all() {
    if (!is_all_set) {
      clear_all();
      is_all_set = true;
    }
  }

 public:
  void clear_all() {
    is_all_set = false;
    for (uint32_t &code : codes) {
      code = 0;
    }
  }

  static bool check(const String *str) {
    if (str == nullptr || str->is_empty()) {
      return true;
    }
    if (stringcmp(str, &LOG_ALL) == 0) {
      return true;
    }

    const char *val = str->ptr();

    for (; my_isspace(system_charset_info, *val); ++val) /* empty */
      ;

    uint8_t codes_count = 0;
    uint8_t digits_count = 0;

    for (const char *p = val; *p; ++p) {
      if (!my_isdigit(system_charset_info, *p) && *p != ',') {
        return false;
      }

      if (*p == ',' && ++codes_count == MAX_CODES_NUM) {
        my_error(ER_TOO_MANY_ERROR_CODES, MYF(0), MAX_CODES_NUM);
        return false;
      }

      if (my_isdigit(system_charset_info, *p)) {
        ++digits_count;
      }
      if ((*p == ',' || static_cast<size_t>(p - val) + 1 == str->length()) &&
          digits_count > 0) {
        long err_code = 0;
        const char *code_start =
            (*p == ',') ? p - digits_count : p - digits_count + 1;
        if (!str2int(code_start, 10, 0, LONG_MAX, &err_code)) {
          my_error(ER_TOO_BIG_ERROR_CODE, MYF(0), LONG_MAX);
          return false;
        }
        digits_count = 0;
      }
    }

    return true;
  }

  bool set_codes(const String *str) {
    if (str == nullptr || str->is_empty()) {
      clear_all();
      return true;
    }
    if (stringcmp(str, &LOG_ALL) == 0) {
      set_all();
      return true;
    }

    const char *val = str->ptr();

    for (; my_isspace(system_charset_info, *val); ++val) /* empty */
      ;

    clear_all();
    uint8_t error_index = 0;

    for (const char *p = val; *p;) {
      long err_code;
      if (!(p = str2int(p, 10, 0, LONG_MAX, &err_code))) {
        break;
      }

      if (error_index == MAX_CODES_NUM) {
        // Too many codes, should have been detected in check()
        return true;
      }

      codes[error_index] = err_code;
      ++error_index;

      while (!my_isdigit(system_charset_info, *p) && *p) {
        p++;
      }
    }

    return true;
  }

  size_t to_string(char *buf) const {
    char *p = buf;

    if (is_all_set) {
      p += sprintf(p, "%s", LOG_ALL.ptr());
    } else {
      for (int i = 0; i < MAX_CODES_NUM; ++i) {
        if (codes[i] != 0) {
          if (i > 0) {
            p += sprintf(p, ",%d", codes[i]);
          } else {
            p += sprintf(p, "%d", codes[i]);
          }
        }
      }
    }

    *p = '\0';

    return p - buf;
  }

  bool check_error_set(const uint32_t code) const {
    if (is_all_set) {
      return true;
    }

    for (const uint32_t &c : codes) {
      if (c == 0) {
        // unused slots reached
        break;
      }
      if (code == c) {
        return true;
      }
    }

    return false;
  }

  bool check_variable_set() const { return is_all_set || codes[0] != 0; }
};

struct System_variables {
  /*
    How dynamically allocated system variables are handled:

    The global_system_variables and max_system_variables are "authoritative"
    They both should have the same 'version' and 'size'.
    When attempting to access a dynamic variable, if the session version
    is out of date, then the session version is updated and realloced if
    necessary and bytes copied from global to make up for missing data.
  */
  ulong dynamic_variables_version;
  char *dynamic_variables_ptr;
  uint dynamic_variables_head;    /* largest valid variable offset */
  uint dynamic_variables_size;    /* how many bytes are in use */
  LIST *dynamic_variables_allocs; /* memory hunks for PLUGIN_VAR_MEMALLOC */

  ulonglong max_heap_table_size;
  ulonglong tmp_table_size;
  ulonglong long_query_time;
  bool end_markers_in_json;
  bool windowing_use_high_precision;
  /* A bitmap for switching optimizations on/off */
  ulonglong optimizer_switch;
  ulonglong optimizer_trace;           ///< bitmap to tune optimizer tracing
  ulonglong optimizer_trace_features;  ///< bitmap to select features to trace
  long optimizer_trace_offset;
  long optimizer_trace_limit;
  ulong optimizer_trace_max_mem_size;
  sql_mode_t sql_mode;  ///< which non-standard SQL behaviour should be enabled
  sql_mode_t shrink_sql_mode;  ///< after the specified mode is removed

  ulonglong option_bits;  ///< OPTION_xxx constants, e.g. OPTION_PROFILING
  ha_rows select_limit;
  ha_rows max_join_size;
  ulong auto_increment_increment, auto_increment_offset;
  ulong bulk_insert_buff_size;
  uint eq_range_index_dive_limit;
  uint cte_max_recursion_depth;
  ulonglong histogram_generation_max_mem_size;
  ulong join_buff_size;
  ulong lock_wait_timeout;
  ulong max_allowed_packet;
  ulong max_error_count;
  ulong max_length_for_sort_data;  ///< Unused.
  ulong max_points_in_geometry;
  ulong max_sort_length;
  ulong max_insert_delayed_threads;
  ulong min_examined_row_limit;
  ulong net_buffer_length;
  ulong net_interactive_timeout;
  ulong net_read_timeout;
  ulong net_retry_count;
  ulong net_wait_timeout;
  ulong net_write_timeout;
  ulong optimizer_prune_level;
  ulong optimizer_search_depth;
  ulong optimizer_max_subgraph_pairs;
  ulonglong parser_max_mem_size;
  ulong range_optimizer_max_mem_size;
  ulong preload_buff_size;
  ulong profiling_history_size;
  ulong read_buff_size;
  ulong read_rnd_buff_size;
  ulong div_precincrement;
  ulong sortbuff_size;
  ulong max_sp_recursion_depth;
  ulong default_week_format;
  ulong max_seeks_for_key;
  ulong range_alloc_block_size;
  ulong query_alloc_block_size;
  ulong query_prealloc_size;
  ulong query_prealloc_reuse_size;
  ulong trans_alloc_block_size;
  ulong trans_prealloc_size;
  ulong group_concat_max_len;
  ulong binlog_format;  ///< binlog format for this thd (see enum_binlog_format)
  ulong rbr_exec_mode_options;  // see enum_rbr_exec_mode
  bool binlog_direct_non_trans_update;
  ulong binlog_row_image;  // see enum_binlog_row_image
  bool binlog_trx_compression;
  ulong binlog_trx_compression_type;  // see enum_binlog_trx_compression
  uint binlog_trx_compression_level_zstd;
  ulonglong binlog_row_value_options;
  bool sql_log_bin;
  // see enum_transaction_write_set_hashing_algorithm
  ulong transaction_write_set_extraction;
  ulong completion_type;
  ulong transaction_isolation;
  ulong updatable_views_with_limit;
  uint max_user_connections;
  ulong my_aes_mode;
#ifdef SSL_GM
  ulong my_sm4_mode;
#endif
  ulong ssl_fips_mode;
  /**
    Controls what resultset metadata will be sent to the client.
    @sa enum_resultset_metadata
  */
  ulong resultset_metadata;

  /**
    In slave thread we need to know in behalf of which
    thread the query is being run to replicate temp tables properly
  */
  my_thread_id pseudo_thread_id;
  /**
    Default transaction access mode. READ ONLY (true) or READ WRITE (false).
  */
  bool transaction_read_only;
  bool low_priority_updates;
  bool new_mode;
  bool keep_files_on_create;

  bool old_alter_table;
  bool big_tables;

  plugin_ref table_plugin;
  plugin_ref temp_table_plugin;

  /* Only charset part of these variables is sensible */
  const CHARSET_INFO *character_set_filesystem;
  const CHARSET_INFO *character_set_client;
  const CHARSET_INFO *character_set_results;

  /* Both charset and collation parts of these variables are important */
  const CHARSET_INFO *collation_server;
  const CHARSET_INFO *collation_database;
  const CHARSET_INFO *collation_connection;

  /* For udt character,it will output binary char if set to binary,debug
   * char for else. */
  ulong udt_format_result;

  /* Error messages */
  MY_LOCALE *lc_messages;
  /* Locale Support */
  MY_LOCALE *lc_time_names;

  Time_zone *time_zone;
  /*
    TIMESTAMP fields are by default created with DEFAULT clauses
    implicitly without users request. This flag when set, disables
    implicit default values and expect users to provide explicit
    default clause. i.e., when set columns are defined as NULL,
    instead of NOT NULL by default.
  */
  bool explicit_defaults_for_timestamp;

  bool sysdate_is_now;
  bool binlog_rows_query_log_events;
  bool binlog_ddl_skip_rewrite;

#ifndef NDEBUG
  ulonglong query_exec_time;
  double query_exec_time_double;
#endif
  ulong log_slow_rate_limit;
  ulonglong log_slow_filter;
  ulonglong log_slow_verbosity;
  Query_errors_set log_query_errors;

  ulong innodb_io_reads;
  ulonglong innodb_io_read;
  uint64_t innodb_io_reads_wait_timer;
  uint64_t innodb_lock_que_wait_timer;
  uint64_t innodb_innodb_que_wait_timer;
  ulong innodb_page_access;

  double long_query_time_double;

  bool pseudo_replica_mode;

  Gtid_specification gtid_next;
  Gtid_set_or_null gtid_next_list;
  ulong session_track_gtids;  // see enum_session_track_gtids

  ulong max_execution_time;

  char *track_sysvars_ptr;
  bool session_track_schema;
  bool session_track_state_change;

  bool expand_fast_index_creation;

  uint threadpool_high_prio_tickets;
  ulong threadpool_high_prio_mode;

  ulong session_track_transaction_info;

  /*
    Time in seconds, after which the statistics in mysql.table/index_stats
    get invalid
  */
  ulong information_schema_stats_expiry;

  /**
    Used for the verbosity of SHOW CREATE TABLE. Currently used for displaying
    the row format in the output even if the table uses default row format.
  */
  bool show_create_table_verbosity;

  /**
    Compatibility option to mark the pre MySQL-5.6.4 temporals columns using
    the old format using comments for SHOW CREATE TABLE and in I_S.COLUMNS
    'COLUMN_TYPE' field.
  */
  bool show_old_temporals;

  bool ft_query_extra_word_chars;

  // Used for replication delay and lag monitoring
  ulonglong original_commit_timestamp;

  ulong
      internal_tmp_mem_storage_engine;  // enum_internal_tmp_mem_storage_engine

  const CHARSET_INFO *default_collation_for_utf8mb4;

  /** Used for controlling preparation of queries against secondary engine. */
  ulong use_secondary_engine;

  /**
    Used for controlling which statements to execute in a secondary
    storage engine. Only queries with an estimated cost higher than
    this value will be attempted executed in a secondary storage
    engine.
  */
  double secondary_engine_cost_threshold;

  uint secondary_engine_parallel_load_workers;

  uint secondary_engine_parallel_read_workers;

  ulong secondary_engine_read_delay_wait_mode;
  ulong secondary_engine_read_delay_time_threshold;
  ulong secondary_engine_read_delay_gtid_threshold;
  ulong secondary_engine_read_delay_wait_timeout;
  ulong secondary_engine_read_delay_level;

  /** Used for controlling Group Replication consistency guarantees */
  ulong group_replication_consistency;

  bool sql_require_primary_key;

  /**
    @sa Sys_sql_generate_invisible_primary_key
  */
  bool sql_generate_invisible_primary_key;

  /**
    @sa Sys_show_gipk_in_create_table_and_information_schema
  */
  bool show_gipk_in_create_table_and_information_schema;

  /**
    Used in replication to determine the server version of the original server
    where the transaction was executed.
  */
  uint32_t original_server_version;

  /**
    Used in replication to determine the server version of the immediate server
    in the replication topology.
  */
  uint32_t immediate_server_version;

  /**
    Used to determine if the database or tablespace should be encrypted by
    default.
  */
  ulong default_table_encryption;

  /**
    @sa Sys_var_print_identified_with_as_hex
  */
  bool print_identified_with_as_hex;

  /**
    @sa Sys_var_show_create_table_skip_secondary_engine
  */
  bool show_create_table_skip_secondary_engine;

  /**
    @sa Sys_var_generated_random_password_length
  */
  uint32_t generated_random_password_length;

  /**
    @sa Sys_var_require_row_format
  */
  bool require_row_format;
  /**
    @sa Sys_select_into_buffer_size
  */
  ulong select_into_buffer_size;
  /**
    @sa Sys_select_into_disk_sync
  */
  bool select_into_disk_sync;
  /**
    @sa Sys_select_disk_sync_delay
  */
  uint select_into_disk_sync_delay;

  /**
    @sa dblink_max_return_rows
  */
  ha_rows dblink_maxreturn_rows;
  /**
    use for select bulk collect into
  */
  uint select_bulk_into_batch;

  /**
    @sa Sys_serveroutput session level
  */
  bool serveroutput;
  ulong max_dbmsotpt_count;

  /**
    @sa Sys_terminology_use_previous
  */
  ulong terminology_use_previous;

  /**
    @sa Sys_connection_memory_limit
  */
  ulonglong conn_mem_limit;
  /**
    @sa Sys_connection_memory_chunk_size
  */
  ulong conn_mem_chunk_size;
  /**
    @sa Sys_connection_global_memory_tracking
  */
  bool conn_global_mem_tracking;

  /**
    Switch which controls whether XA transactions are detached
    (made accessible to other connections for commit/rollback)
    as part of XA PREPARE (true), or at session disconnect (false, default).
    An important side effect of setting this to true is that temporary tables
    are disallowed in XA transactions. This is necessary because temporary
    tables and their contents (and thus changes to them) is bound to
    specific connections, so they don't make sense if XA transaction is
    committed or rolled back from another connection.
   */
  bool xa_detach_on_prepare;

  /**
    @sa Sys_debug_sensitive_session_string
  */
  char *debug_sensitive_session_str;

  /**
    Used to specify the format in which the EXPLAIN statement should display
    information if the FORMAT option is not explicitly specified.
    @sa Sys_explain_format
   */
  Explain_format_type explain_format;

  // add for parallel load data
  bool gdb_parallel_load;
  uint gdb_parallel_load_workers;
  uint gdb_parallel_load_chunk_size;
  bool gdb_parallel_load_executor;  // not displayed, need delete THD after use.
                                    // inited to false by memset of THD()
  bool ora_warning_as_error;

  bool force_parallel_execute;

  ulong parallel_cost_threshold;

  ulong parallel_default_dop;

  ulong parallel_queue_timeout;

  bool pq_copy_from(System_variables leader);

  /**
    @sa dbms_profiler
  */
  uint dbms_profiler_max_units_size;
  uint dbms_profiler_max_data_size;

  /**
    lock ddl polling mode config
   */
  bool lock_ddl_polling_mode;

  /**
    Unit millisecond default 1000
 */
  ulong lock_ddl_polling_runtime;
};

/**
  Per thread status variables.
  Must be long/ulong up to last_system_status_var so that
  add_to_status/add_diff_to_status can work.
*/

struct System_status_var {
  /* IMPORTANT! See first_system_status_var definition below. */
  ulonglong created_tmp_disk_tables;
  ulonglong created_tmp_tables;
  ulonglong ha_commit_count;
  ulonglong ha_delete_count;
  ulonglong ha_read_first_count;
  ulonglong ha_read_last_count;
  ulonglong ha_read_key_count;
  ulonglong ha_read_next_count;
  ulonglong ha_read_prev_count;
  ulonglong ha_read_rnd_count;
  ulonglong ha_read_rnd_next_count;
  /*
    This number doesn't include calls to the default implementation and
    calls made by range access. The intent is to count only calls made by
    BatchedKeyAccess.
  */
  ulonglong ha_multi_range_read_init_count;
  ulonglong ha_rollback_count;
  ulonglong ha_update_count;
  ulonglong ha_write_count;
  ulonglong ha_prepare_count;
  ulonglong ha_discover_count;
  ulonglong ha_savepoint_count;
  ulonglong ha_savepoint_rollback_count;
  ulonglong ha_external_lock_count;
  ulonglong opened_tables;
  ulonglong opened_shares;
  ulonglong table_open_cache_hits;
  ulonglong table_open_cache_misses;
  ulonglong table_open_cache_overflows;
  ulonglong table_open_cache_triggers_hits;
  ulonglong table_open_cache_triggers_misses;
  ulonglong table_open_cache_triggers_overflows;
  ulonglong select_full_join_count;
  ulonglong select_full_range_join_count;
  ulonglong select_range_count;
  ulonglong select_range_check_count;
  ulonglong select_scan_count;
  ulonglong long_query_count;
  ulonglong filesort_merge_passes;
  ulonglong filesort_range_count;
  ulonglong filesort_rows;
  ulonglong filesort_scan_count;
  /* Prepared statements and binary protocol. */
  ulonglong com_stmt_prepare;
  ulonglong com_stmt_reprepare;
  ulonglong com_stmt_execute;
  ulonglong com_stmt_send_long_data;
  ulonglong com_stmt_fetch;
  ulonglong com_stmt_reset;
  ulonglong com_stmt_close;

  ulonglong bytes_received;
  ulonglong bytes_sent;

  ulonglong net_buffer_length;

  ulonglong max_execution_time_exceeded;
  ulonglong max_execution_time_set;
  ulonglong max_execution_time_set_failed;

  /* Number of statements sent from the client. */
  ulonglong questions;

  /// How many queries have been executed on a secondary storage engine.
  ulonglong secondary_engine_execution_count;

  ulong com_other;
  ulong com_stat[(uint)SQLCOM_END];

  /*
    IMPORTANT! See last_system_status_var definition below. Variables after
    'last_system_status_var' cannot be handled automatically by add_to_status()
    and add_diff_to_status().
  */
  double last_query_cost;
  ulonglong last_query_partial_plans;

  /** fragmentation statistics */
  fragmentation_stats_t fragmentation_stats;
  bool reset;
  bool pq_merge_status(System_status_var worker);
};

/*
  This must reference the LAST ulonglong variable in system_status_var that is
  used as a global counter. It marks the end of a contiguous block of counters
  that can be iteratively totaled. See add_to_status().
*/
#define LAST_STATUS_VAR secondary_engine_execution_count

/*
  This must reference the FIRST ulonglong variable in system_status_var that is
  used as a global counter. It marks the start of a contiguous block of counters
  that can be iteratively totaled.
*/
#define FIRST_STATUS_VAR created_tmp_disk_tables

/* Number of contiguous global status variables. */
const int COUNT_GLOBAL_STATUS_VARS =
    ((offsetof(System_status_var, LAST_STATUS_VAR) -
      offsetof(System_status_var, FIRST_STATUS_VAR)) /
     sizeof(ulonglong)) +
    1;

void add_diff_to_status(System_status_var *to_var, System_status_var *from_var,
                        System_status_var *dec_var);

void add_to_status(System_status_var *to_var, System_status_var *from_var);

void reset_system_status_vars(System_status_var *status_vars);

/* For Oracle private temporary table, its name must always be prefixed with
 * whatever is defined with this parameter. The default is ORA$PTT_. */
extern char *ora_private_temp_table_prefix;

#endif  // SYSTEM_VARIABLES_INCLUDED
