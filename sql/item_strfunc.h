/* Copyright (c) 2000, 2022, Oracle and/or its affiliates. All rights reserved.
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

/* This file defines all string functions */
#ifndef ITEM_STRFUNC_INCLUDED
#define ITEM_STRFUNC_INCLUDED

#include <assert.h>
#include <sys/types.h>

#include <cstdint>  // uint32_t

#include "lex_string.h"
#include "libbinlogevents/include/uuid.h"  // Uuid
#include "m_ctype.h"
#include "sql/auth/auth_common.h"

#include "my_hostname.h"  // HOSTNAME_LENGTH
#include "my_inttypes.h"
#include "my_table_map.h"
#include "my_time.h"
#include "mysql/udf_registration_types.h"
#include "mysql_com.h"
#include "mysql_time.h"
#include "sql/enum_query_type.h"
#include "sql/field.h"
#include "sql/item.h"
#include "sql/item_cmpfunc.h"    // Item_bool_func
#include "sql/item_func.h"       // Item_func
#include "sql/parse_location.h"  // POS
#include "sql/parse_tree_helpers.h"
#include "sql/regexp/regexp_engine.h"
#include "sql/sql_const.h"
#include "sql/sql_lex.h"
#include "sql/sql_parse.h"
#include "sql_string.h"
#include "template_utils.h"  // pointer_cast

class MY_LOCALE;
class PT_item_list;
class THD;
class my_decimal;
struct Parse_context;

template <class T>
class List;

CHARSET_INFO *mysqld_collation_get_by_name(
    const char *name, CHARSET_INFO *name_cs = system_charset_info);

/**
  Generate Universal Unique Identifier (UUID).

  @param  str Pointer to string which will hold the UUID.

  @return str Pointer to string which contains the UUID.
*/

String *mysql_generate_uuid(String *str);

class Item_str_func : public Item_func {
  typedef Item_func super;

 public:
  Item_str_func() : Item_func() {}

  explicit Item_str_func(const POS &pos) : super(pos) {}

  Item_str_func(Item *a) : Item_func(a) {}

  Item_str_func(const POS &pos, Item *a) : Item_func(pos, a) {}

  Item_str_func(Item *a, Item *b) : Item_func(a, b) {}

  Item_str_func(const POS &pos, Item *a, Item *b) : Item_func(pos, a, b) {}

  Item_str_func(Item *a, Item *b, Item *c) : Item_func(a, b, c) {}

  Item_str_func(const POS &pos, Item *a, Item *b, Item *c)
      : Item_func(pos, a, b, c) {}

  Item_str_func(Item *a, Item *b, Item *c, Item *d) : Item_func(a, b, c, d) {}

  Item_str_func(const POS &pos, Item *a, Item *b, Item *c, Item *d)
      : Item_func(pos, a, b, c, d) {}

  Item_str_func(Item *a, Item *b, Item *c, Item *d, Item *e)
      : Item_func(a, b, c, d, e) {}

  Item_str_func(const POS &pos, Item *a, Item *b, Item *c, Item *d, Item *e)
      : Item_func(pos, a, b, c, d, e) {}
  Item_str_func(const POS &pos, Item *a, Item *b, Item *c, Item *d, Item *e,
                Item *f)
      : Item_func(pos, a, b, c, d, e, f) {}
  explicit Item_str_func(mem_root_deque<Item *> *list) : Item_func(list) {}

  Item_str_func(const POS &pos, PT_item_list *opt_list)
      : Item_func(pos, opt_list) {}

  longlong val_int() override { return val_int_from_string(); }
  double val_real() override { return val_real_from_string(); }
  my_decimal *val_decimal(my_decimal *) override;
  bool get_date(MYSQL_TIME *ltime, my_time_flags_t fuzzydate) override {
    return get_date_from_string(ltime, fuzzydate);
  }
  bool get_time(MYSQL_TIME *ltime) override {
    return get_time_from_string(ltime);
  }
  enum Item_result result_type() const override { return STRING_RESULT; }
  void left_right_max_length(THD *thd);
  bool fix_fields(THD *thd, Item **ref) override;
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, -1)) return true;
    return false;
  }
  String *val_str_from_val_str_ascii(String *str, String *str2);

 protected:
  /**
    Calls push_warning_printf for packet overflow.
    @return error_str().
   */
  String *push_packet_overflow_warning(THD *thd, const char *func);
};

/*
  Functions that return values with ASCII repertoire
*/
class Item_str_ascii_func : public Item_str_func {
  String ascii_buf;

 public:
  Item_str_ascii_func() : Item_str_func() {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }

  Item_str_ascii_func(Item *a) : Item_str_func(a) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }
  Item_str_ascii_func(const POS &pos, Item *a) : Item_str_func(pos, a) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }

  Item_str_ascii_func(Item *a, Item *b) : Item_str_func(a, b) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }
  Item_str_ascii_func(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }

  Item_str_ascii_func(Item *a, Item *b, Item *c) : Item_str_func(a, b, c) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }
  Item_str_ascii_func(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }
  Item_str_ascii_func(const POS &pos, Item *a, Item *b, Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {
    collation.set_repertoire(MY_REPERTOIRE_ASCII);
  }

  String *val_str(String *str) override {
    return val_str_from_val_str_ascii(str, &ascii_buf);
  }
  String *val_str_ascii(String *) override = 0;
};

class Item_func_md5 final : public Item_str_ascii_func {
  String tmp_value;

 public:
  Item_func_md5(const POS &pos, Item *a) : Item_str_ascii_func(pos, a) {}
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "md5"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_sha : public Item_str_ascii_func {
 public:
  Item_func_sha(const POS &pos, Item *a) : Item_str_ascii_func(pos, a) {}
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "sha"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_sha2 : public Item_str_ascii_func {
 public:
  Item_func_sha2(const POS &pos, Item *a, Item *b)
      : Item_str_ascii_func(pos, a, b) {}
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "sha2"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_to_base64 final : public Item_str_ascii_func {
  String tmp_value;

 public:
  Item_func_to_base64(const POS &pos, Item *a) : Item_str_ascii_func(pos, a) {}
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "to_base64"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_statement_digest final : public Item_str_ascii_func {
 public:
  Item_func_statement_digest(const POS &pos, Item *query_string)
      : Item_str_ascii_func(pos, query_string) {}

  const char *func_name() const override { return "statement_digest"; }
  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return (func_arg->source == VGS_GENERATED_COLUMN);
  }

  bool resolve_type(THD *thd) override;

  String *val_str_ascii(String *) override;

 private:
  uchar *m_token_buffer{nullptr};
};

class Item_func_statement_digest_text final : public Item_str_func {
 public:
  Item_func_statement_digest_text(const POS &pos, Item *query_string)
      : Item_str_func(pos, query_string) {}

  const char *func_name() const override { return "statement_digest_text"; }

  /**
    The type is always LONGTEXT, just like the digest_text columns in
    Performance Schema
  */
  bool resolve_type(THD *thd) override;

  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return (func_arg->source == VGS_GENERATED_COLUMN);
  }
  String *val_str(String *) override;

 private:
  uchar *m_token_buffer{nullptr};
};

class Item_func_from_base64 final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_from_base64(const POS &pos, Item *a) : Item_str_func(pos, a) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "from_base64"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_aes_encrypt final : public Item_str_func {
  String tmp_value;
  typedef Item_str_func super;

 public:
  Item_func_aes_encrypt(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  Item_func_aes_encrypt(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  Item_func_aes_encrypt(const POS &pos, Item *a, Item *b, Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {}
  Item_func_aes_encrypt(const POS &pos, Item *a, Item *b, Item *c, Item *d,
                        Item *e)
      : Item_str_func(pos, a, b, c, d, e) {}
  Item_func_aes_encrypt(const POS &pos, Item *a, Item *b, Item *c, Item *d,
                        Item *e, Item *f)
      : Item_str_func(pos, a, b, c, d, e, f) {}
  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "aes_encrypt"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_aes_decrypt : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_aes_decrypt(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  Item_func_aes_decrypt(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  Item_func_aes_decrypt(const POS &pos, Item *a, Item *b, Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {}
  Item_func_aes_decrypt(const POS &pos, Item *a, Item *b, Item *c, Item *d,
                        Item *e)
      : Item_str_func(pos, a, b, c, d, e) {}
  Item_func_aes_decrypt(const POS &pos, Item *a, Item *b, Item *c, Item *d,
                        Item *e, Item *f)
      : Item_str_func(pos, a, b, c, d, e, f) {}
  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "aes_decrypt"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

#ifdef SSL_GM
class Item_func_sm4_encrypt final : public Item_str_func {
  String tmp_value;
  typedef Item_str_func super;

 public:
  Item_func_sm4_encrypt(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  Item_func_sm4_encrypt(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "sm4_encrypt"; }
};

class Item_func_sm4_decrypt : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_sm4_decrypt(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  Item_func_sm4_decrypt(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "sm4_decrypt"; }
};

class Item_func_sm2_encrypt final : public Item_str_func {
  String tmp_value;
  typedef Item_str_func super;

 public:
  Item_func_sm2_encrypt(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "sm2_encrypt"; }
};

class Item_func_sm2_decrypt : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_sm2_decrypt(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "sm2_decrypt"; }
};

class Item_func_sm3 : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_sm3(const POS &pos, Item *a) : Item_str_func(pos, a) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "sm3"; }
};

class Item_func_hmac_sm3 : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_hmac_sm3(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "hmac_sm3"; }
};
#endif

class Item_func_random_bytes : public Item_str_func {
  typedef Item_str_func super;

  /** limitation from the SSL library */
  static const ulonglong MAX_RANDOM_BYTES_BUFFER;

 public:
  Item_func_random_bytes(const POS &pos, Item *a) : Item_str_func(pos, a) {}

  bool itemize(Parse_context *pc, Item **res) override;
  bool resolve_type(THD *thd) override;
  String *val_str(String *a) override;

  const char *func_name() const override { return "random_bytes"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_concat : public Item_str_func {
  String tmp_value{"", 0, collation.collation};  // Initialize to empty
  bool m_orafun{false};                          // true from oracmp function
 public:
  Item_func_concat(const POS &pos, PT_item_list *opt_list)
      : Item_str_func(pos, opt_list) {}
  Item_func_concat(Item *a, Item *b) : Item_str_func(a, b) {}
  Item_func_concat(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  Item_func_concat(const POS &pos, Item *a, Item *b, bool from_orafun)
      : Item_func_concat(pos, a, b) {
    m_orafun = from_orafun;
  }
  // for sys_connect_by_path
  Item_func_concat(Item *a, Item *b, Item *c)
      : Item_str_func(a, b, c), m_orafun(true) {}

  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "concat"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  bool is_orafun() { return m_orafun; }
  void set_orafun(bool orafun) { m_orafun = orafun; }
  enum Functype functype() const override { return CONCAT_FUNC; }
};

class Item_func_concat_ws : public Item_str_func {
  String tmp_value{"", 0, collation.collation};  // Initialize to empty
 public:
  explicit Item_func_concat_ws(mem_root_deque<Item *> *list)
      : Item_str_func(list) {
    null_on_null = false;
  }
  Item_func_concat_ws(const POS &pos, PT_item_list *opt_list)
      : Item_str_func(pos, opt_list) {
    null_on_null = false;
  }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "concat_ws"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return CONCAT_WS_FUNC; }
};

class Item_func_reverse : public Item_str_func {
  String tmp_value;

 public:
  Item_func_reverse(Item *a) : Item_str_func(a) {}
  Item_func_reverse(const POS &pos, Item *a) : Item_str_func(pos, a) {}

  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "reverse"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return REVERSE_FUNC; }
};

class Item_func_replace : public Item_str_func {
  String tmp_value, tmp_value2;
  /// Holds result in case we need to allocate our own result buffer.
  String tmp_value_res{"", 0, &my_charset_bin};

 public:
  Item_func_replace(const POS &pos, Item *org, Item *find, Item *replace)
      : Item_str_func(pos, org, find, replace) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "replace"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return REPLACE_FUNC; }
};

class Item_func_insert : public Item_str_func {
  String tmp_value;
  /// Holds result in case we need to allocate our own result buffer.
  String tmp_value_res;

 public:
  Item_func_insert(const POS &pos, Item *org, Item *start, Item *length,
                   Item *new_str)
      : Item_str_func(pos, org, start, length, new_str) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "insert"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_str_conv : public Item_str_func {
 protected:
  uint multiply;
  my_charset_conv_case converter;
  String tmp_value;

 public:
  Item_str_conv(const POS &pos, Item *item) : Item_str_func(pos, item) {}
  String *val_str(String *) override;
  bool pq_copy_from(THD *thd, Query_block *select, Item *item) override;
};

class Item_func_lower : public Item_str_conv {
 public:
  Item_func_lower(const POS &pos, Item *item) : Item_str_conv(pos, item) {}
  const char *func_name() const override { return "lower"; }
  bool resolve_type(THD *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return LOWER_FUNC; }
};

class Item_func_upper : public Item_str_conv {
 public:
  Item_func_upper(const POS &pos, Item *item) : Item_str_conv(pos, item) {}
  const char *func_name() const override { return "upper"; }
  bool resolve_type(THD *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return UPPER_FUNC; }
};

class Item_func_left : public Item_str_func {
  String tmp_value;

 public:
  Item_func_left(const POS &pos, Item *a, Item *b) : Item_str_func(pos, a, b) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "left"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return LEFT_FUNC; }
};

class Item_func_right : public Item_str_func {
  String tmp_value;

 public:
  Item_func_right(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "right"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return RIGHT_FUNC; }
};

class Item_func_substr : public Item_str_func {
  typedef Item_str_func super;
  String tmp_value;

 public:
  Item_func_substr(Item *a, Item *b) : Item_str_func(a, b) {}
  Item_func_substr(const POS &pos, Item *a, Item *b) : super(pos, a, b) {}

  Item_func_substr(Item *a, Item *b, Item *c) : Item_str_func(a, b, c) {}
  Item_func_substr(const POS &pos, Item *a, Item *b, Item *c)
      : super(pos, a, b, c) {}

  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "substr"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return SUBSTR_FUNC; }
};

class Item_func_dump : public Item_str_func {
  typedef Item_str_func super;
  String tmp_value;

 public:
  Item_func_dump(const POS &pos, PT_item_list *a) : super(pos, a) {
    set_has_notsupported_func_true();
  }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "dump"; }
};

class Item_func_substrb : public Item_str_func {
  typedef Item_str_func super;

  String tmp_value;

 public:
  Item_func_substrb(Item *a, Item *b) : Item_str_func(a, b) {
    set_has_notsupported_func_true();
  }
  Item_func_substrb(const POS &pos, Item *a, Item *b) : super(pos, a, b) {
    set_has_notsupported_func_true();
  }

  Item_func_substrb(Item *a, Item *b, Item *c) : Item_str_func(a, b, c) {
    set_has_notsupported_func_true();
  }
  Item_func_substrb(const POS &pos, Item *a, Item *b, Item *c)
      : super(pos, a, b, c) {
    set_has_notsupported_func_true();
  }

  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "substrb"; }
};

class Item_func_get_materialized_view_definition : public Item_str_func {
  String tmp_value;

 public:
  Item_func_get_materialized_view_definition(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override {
    return "get_materialized_view_definition";
  }
};

class Item_func_substr_index final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_substr_index(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "substring_index"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_translate : public Item_str_func {
  String tmp_value, tmp_value2;
  /// Holds result in case we need to allocate our own result buffer.
  String tmp_value_res{"", 0, &my_charset_bin};

 public:
  Item_func_translate(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {
    set_nullable(true);
    set_has_notsupported_func_true();
  }

  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "translate"; }
  enum Functype functype() const override { return TRANSLATE_FUNC; }
};

class Item_func_trim : public Item_str_func {
 public:
  /**
    Why all the trim modes in this enum?
    We need to maintain parsing information, so that our print() function
    can reproduce correct messages and view definitions.
   */
  enum TRIM_MODE {
    TRIM_BOTH_DEFAULT,
    TRIM_BOTH,
    TRIM_LEADING,
    TRIM_TRAILING,
    TRIM_LTRIM,
    TRIM_RTRIM
  };

 private:
  bool oracle_mode_flag = false;
  String tmp_value;
  String remove;
  const TRIM_MODE m_trim_mode;
  const bool m_trim_leading;
  const bool m_trim_trailing;

 public:
  Item_func_trim(Item *a, Item *b, TRIM_MODE tm)
      : Item_str_func(a, b),
        m_trim_mode(tm),
        m_trim_leading(trim_leading()),
        m_trim_trailing(trim_trailing()) {}

  Item_func_trim(const POS &pos, Item *a, Item *b, TRIM_MODE tm)
      : Item_str_func(pos, a, b),
        m_trim_mode(tm),
        m_trim_leading(trim_leading()),
        m_trim_trailing(trim_trailing()) {}

  Item_func_trim(Item *a, TRIM_MODE tm)
      : Item_str_func(a),
        m_trim_mode(tm),
        m_trim_leading(trim_leading()),
        m_trim_trailing(trim_trailing()) {}

  Item_func_trim(const POS &pos, Item *a, TRIM_MODE tm)
      : Item_str_func(pos, a),
        m_trim_mode(tm),
        m_trim_leading(trim_leading()),
        m_trim_trailing(trim_trailing()) {}

  bool trim_leading() const {
    return m_trim_mode == TRIM_BOTH_DEFAULT || m_trim_mode == TRIM_BOTH ||
           m_trim_mode == TRIM_LEADING || m_trim_mode == TRIM_LTRIM;
  }

  bool trim_trailing() const {
    return m_trim_mode == TRIM_BOTH_DEFAULT || m_trim_mode == TRIM_BOTH ||
           m_trim_mode == TRIM_TRAILING || m_trim_mode == TRIM_RTRIM;
  }

  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override {
    switch (m_trim_mode) {
      case TRIM_BOTH_DEFAULT:
        return "trim";
      case TRIM_BOTH:
        return "trim";
      case TRIM_LEADING:
        return "ltrim";
      case TRIM_TRAILING:
        return "rtrim";
      case TRIM_LTRIM:
        return "ltrim";
      case TRIM_RTRIM:
        return "rtrim";
    }
    return nullptr;
  }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return TRIM_FUNC; }
};

class Item_func_ltrim final : public Item_func_trim {
 public:
  Item_func_ltrim(const POS &pos, Item *a)
      : Item_func_trim(pos, a, TRIM_LTRIM) {}
  Item_func_ltrim(const POS &pos, Item *a, Item *b)
      : Item_func_trim(pos, a, b, TRIM_LTRIM) {}

  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return LTRIM_FUNC; }
};

class Item_func_rtrim final : public Item_func_trim {
 public:
  Item_func_rtrim(const POS &pos, Item *a)
      : Item_func_trim(pos, a, TRIM_RTRIM) {}
  Item_func_rtrim(const POS &pos, Item *a, Item *b)
      : Item_func_trim(pos, a, b, TRIM_RTRIM) {}

  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return RTRIM_FUNC; }
};

class Item_func_sysconst : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_sysconst() {
    collation.set(system_charset_info, DERIVATION_SYSCONST);
  }
  explicit Item_func_sysconst(const POS &pos) : super(pos) {
    collation.set(system_charset_info, DERIVATION_SYSCONST);
  }

  Item *safe_charset_converter(THD *thd, const CHARSET_INFO *tocs) override;
  /*
    Used to create correct Item name in new converted item in
    safe_charset_converter, return string representation of this function
    call
  */
  virtual const Name_string fully_qualified_func_name() const = 0;
  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return ((func_arg->source == VGS_GENERATED_COLUMN) ||
            (func_arg->source == VGS_CHECK_CONSTRAINT));
  }
};

class Item_func_database : public Item_func_sysconst {
  typedef Item_func_sysconst super;

 public:
  explicit Item_func_database(const POS &pos) : Item_func_sysconst(pos) {}

  bool itemize(Parse_context *pc, Item **res) override;

  String *val_str(String *) override;
  bool resolve_type(THD *) override {
    set_data_type_string(uint32{MAX_FIELD_NAME});
    set_nullable(true);
    return false;
  }
  const char *func_name() const override { return "database"; }
  const Name_string fully_qualified_func_name() const override {
    return NAME_STRING("database()");
  }

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_user : public Item_func_sysconst {
  typedef Item_func_sysconst super;

 protected:
  /// True when function value is evaluated, set to false after each execution
  bool m_evaluated = false;

  /// Evaluate user name, must be called once per execution
  bool evaluate(const char *user, const char *host);
  type_conversion_status save_in_field_inner(Field *field, bool) override;

 public:
  Item_func_user() { str_value.set("", 0, system_charset_info); }
  explicit Item_func_user(const POS &pos) : super(pos) {
    str_value.set("", 0, system_charset_info);
  }

  table_map get_initial_pseudo_tables() const override {
    return INNER_TABLE_BIT;
  }

  bool itemize(Parse_context *pc, Item **res) override;

  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return true;
  }
  bool resolve_type(THD *) override {
    set_data_type_string(uint32{USERNAME_CHAR_LENGTH + HOSTNAME_LENGTH + 1U});
    return false;
  }
  void cleanup() override {
    m_evaluated = false;
    str_value.mem_free();
    super::cleanup();
  }
  const char *func_name() const override { return "user"; }
  const Name_string fully_qualified_func_name() const override {
    return NAME_STRING("user()");
  }

  String *val_str(String *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_current_user : public Item_func_user {
  typedef Item_func_user super;

  Name_resolution_context *context;

 protected:
  type_conversion_status save_in_field_inner(Field *field, bool) override;

 public:
  explicit Item_func_current_user(const POS &pos) : super(pos) {}

  bool itemize(Parse_context *pc, Item **res) override;
  const char *func_name() const override { return "current_user"; }
  const Name_string fully_qualified_func_name() const override {
    return NAME_STRING("current_user()");
  }

  String *val_str(String *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_soundex : public Item_str_func {
  String tmp_value;

 public:
  Item_func_soundex(Item *a) : Item_str_func(a) {}
  Item_func_soundex(const POS &pos, Item *a) : Item_str_func(pos, a) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "soundex"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_elt final : public Item_str_func {
 public:
  Item_func_elt(const POS &pos, PT_item_list *opt_list)
      : Item_str_func(pos, opt_list) {}
  double val_real() override;
  longlong val_int() override;
  String *val_str(String *str) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "elt"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_make_set final : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item *item;
  String tmp_str;

  Item_func_make_set(const POS &pos, Item *a, PT_item_list *opt_list)
      : Item_str_func(pos, opt_list), item(a) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *str) override;
  bool fix_fields(THD *thd, Item **ref) override {
    assert(fixed == 0);
    bool res = ((!item->fixed && item->fix_fields(thd, &item)) ||
                item->check_cols(1) || Item_func::fix_fields(thd, ref));
    set_nullable(is_nullable() || item->is_nullable());
    return res;
  }
  void split_sum_func(THD *thd, Ref_item_array ref_item_array,
                      mem_root_deque<Item *> *fields) override;
  bool resolve_type(THD *) override;
  void update_used_tables() override;
  const char *func_name() const override { return "make_set"; }

  bool walk(Item_processor processor, enum_walk walk, uchar *arg) override {
    if ((walk & enum_walk::PREFIX) && (this->*processor)(arg)) return true;
    if (item->walk(processor, walk, arg)) return true;
    for (uint i = 0; i < arg_count; i++) {
      if (args[i]->walk(processor, walk, arg)) return true;
    }
    return ((walk & enum_walk::POSTFIX) && (this->*processor)(arg));
  }

  Item *transform(Item_transformer transformer, uchar *arg) override;
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_format final : public Item_str_ascii_func {
  String tmp_str;
  MY_LOCALE *locale;

 public:
  Item_func_format(const POS &pos, Item *org, Item *dec)
      : Item_str_ascii_func(pos, org, dec) {}
  Item_func_format(const POS &pos, Item *org, Item *dec, Item *lang)
      : Item_str_ascii_func(pos, org, dec, lang) {}

  MY_LOCALE *get_locale(Item *item);
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "format"; }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_char final : public Item_str_func {
 public:
  Item_func_char(const POS &pos, PT_item_list *list)
      : Item_str_func(pos, list) {
    collation.set(&my_charset_bin);
  }
  Item_func_char(const POS &pos, PT_item_list *list, const CHARSET_INFO *cs)
      : Item_str_func(pos, list) {
    collation.set(cs);
  }

  String *val_str(String *) override;
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, -1, MYSQL_TYPE_LONGLONG)) return true;
    set_data_type_string(arg_count * 4U);
    return false;
  }
  const char *func_name() const override { return "char"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_chr final : public Item_str_func {
 public:
  Item_func_chr(const POS &pos, Item *arg) : Item_str_func(pos, arg) {
    collation.set(&my_charset_bin);
    set_has_notsupported_func_true();
  }
  Item_func_chr(const POS &pos, Item *arg, const CHARSET_INFO *cs)
      : Item_str_func(pos, arg) {
    collation.set(cs);
    set_has_notsupported_func_true();
  }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, 1, MYSQL_TYPE_LONGLONG)) return true;
    set_data_type_string(4U);
    return false;
  }
  const char *func_name() const override { return "chr"; }
};

class Item_func_repeat final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_repeat(const POS &pos, Item *arg1, Item *arg2)
      : Item_str_func(pos, arg1, arg2) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "repeat"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
  enum Functype functype() const override { return REPEAT_FUNC; }
};

class Item_func_space final : public Item_str_func {
 public:
  Item_func_space(const POS &pos, Item *arg1) : Item_str_func(pos, arg1) {}
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "space"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_rpad : public Item_str_func {
  String tmp_value, rpad_str;
  String remove;
  String tmp_value_str{"", 0, &my_charset_bin};
#define FULL_DISPLAY_LENGTH 2

 public:
  Item_func_rpad(const POS &pos, Item *arg1, Item *arg2)
      : Item_str_func(pos, arg1, arg2) {
    set_has_notsupported_func_true();
  }
  Item_func_rpad(const POS &pos, Item *arg1, Item *arg2, Item *arg3)
      : Item_str_func(pos, arg1, arg2, arg3) {
    set_has_notsupported_func_true();
  }
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "rpad"; }
  bool oracle_mode_flag = false;
  Item *pq_clone(THD *thd, Query_block *select) override;
  bool pq_copy_from(THD *thd, Query_block *select, Item *item) override;
  enum Functype functype() const override { return RPAD_FUNC; }
};

class Item_func_oracle_rpad : public Item_func_rpad {
 public:
  Item_func_oracle_rpad(const POS &pos, Item *arg1, Item *arg2)
      : Item_func_rpad(pos, arg1, arg2) {}
  Item_func_oracle_rpad(const POS &pos, Item *arg1, Item *arg2, Item *arg3)
      : Item_func_rpad(pos, arg1, arg2, arg3) {}
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "rpad_oracle"; }
};

class Item_func_lpad : public Item_str_func {
  String tmp_value, lpad_str;
  String remove;
  String tmp_value_str{"", 0, collation.collation};
  String result_tmp_value_str{"", 0, collation.collation};

 public:
  Item_func_lpad(const POS &pos, Item *arg1, Item *arg2)
      : Item_str_func(pos, arg1, arg2) {
    set_has_notsupported_func_true();
  }
  Item_func_lpad(const POS &pos, Item *arg1, Item *arg2, Item *arg3)
      : Item_str_func(pos, arg1, arg2, arg3) {
    set_has_notsupported_func_true();
  }
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "lpad"; }
  bool oracle_mode_flag = false;
  Item *pq_clone(THD *thd, Query_block *select) override;
  bool pq_copy_from(THD *thd, Query_block *select, Item *item) override;
  enum Functype functype() const override { return LPAD_FUNC; }
};

class Item_func_oracle_lpad final : public Item_func_lpad {
 public:
  Item_func_oracle_lpad(const POS &pos, Item *arg1, Item *arg2)
      : Item_func_lpad(pos, arg1, arg2) {}
  Item_func_oracle_lpad(const POS &pos, Item *arg1, Item *arg2, Item *arg3)
      : Item_func_lpad(pos, arg1, arg2, arg3) {}
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "lpad_oracle"; }
};

class Item_func_uuid_to_bin final : public Item_str_func {
  /// Buffer to store the binary result
  uchar m_bin_buf[binary_log::Uuid::BYTE_LENGTH];

 public:
  Item_func_uuid_to_bin(const POS &pos, Item *arg1)
      : Item_str_func(pos, arg1) {}
  Item_func_uuid_to_bin(const POS &pos, Item *arg1, Item *arg2)
      : Item_str_func(pos, arg1, arg2) {}
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "uuid_to_bin"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_bin_to_uuid final : public Item_str_ascii_func {
  /// Buffer to store the text result
  char m_text_buf[binary_log::Uuid::TEXT_LENGTH + 1];

 public:
  Item_func_bin_to_uuid(const POS &pos, Item *arg1)
      : Item_str_ascii_func(pos, arg1) {}
  Item_func_bin_to_uuid(const POS &pos, Item *arg1, Item *arg2)
      : Item_str_ascii_func(pos, arg1, arg2) {}
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "bin_to_uuid"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_is_uuid final : public Item_bool_func {
  typedef Item_bool_func super;

 public:
  Item_func_is_uuid(const POS &pos, Item *a) : Item_bool_func(pos, a) {}
  longlong val_int() override;
  const char *func_name() const override { return "is_uuid"; }
  bool resolve_type(THD *thd) override {
    bool res = super::resolve_type(thd);
    set_nullable(true);
    return res;
  }
};

class Item_func_conv final : public Item_str_func {
 public:
  // 64 digits plus possible '-'.
  static constexpr uint32_t CONV_MAX_LENGTH = 64U + 1U;
  Item_func_conv(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  const char *func_name() const override { return "conv"; }
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_hex : public Item_str_ascii_func {
  String tmp_value;

 public:
  Item_func_hex(const POS &pos, Item *a) : Item_str_ascii_func(pos, a) {}
  const char *func_name() const override { return "hex"; }
  String *val_str_ascii(String *) override;
  bool resolve_type(THD *thd) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_unhex final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_unhex(const POS &pos, Item *a) : Item_str_func(pos, a) {
    /* there can be bad hex strings */
    set_nullable(true);
  }
  const char *func_name() const override { return "unhex"; }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

#ifndef NDEBUG
class Item_func_like_range : public Item_str_func {
 protected:
  String min_str;
  String max_str;
  const bool is_min;

 public:
  Item_func_like_range(const POS &pos, Item *a, Item *b, bool is_min_arg)
      : Item_str_func(pos, a, b), is_min(is_min_arg) {
    set_nullable(true);
  }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, 1)) return true;
    if (param_type_is_default(thd, 1, 2, MYSQL_TYPE_LONGLONG)) return true;
    set_data_type_string(uint32{MAX_BLOB_WIDTH}, args[0]->collation);
    return false;
  }
};

class Item_func_like_range_min final : public Item_func_like_range {
 public:
  Item_func_like_range_min(const POS &pos, Item *a, Item *b)
      : Item_func_like_range(pos, a, b, true) {}
  const char *func_name() const override { return "like_range_min"; }
};

class Item_func_like_range_max final : public Item_func_like_range {
 public:
  Item_func_like_range_max(const POS &pos, Item *a, Item *b)
      : Item_func_like_range(pos, a, b, false) {}
  const char *func_name() const override { return "like_range_max"; }
};
#endif

/**
  The following types of conversions are considered safe:

  Conversion to and from "binary".
  Conversion to Unicode.
  Other kind of conversions are potentially lossy.
*/
class Item_charset_conversion : public Item_str_func {
 protected:
  /// If true, conversion is needed so do it, else allow string copy.
  bool m_charset_conversion{false};
  /// The character set we are converting to
  const CHARSET_INFO *m_cast_cs;
  /// The character set we are converting from
  const CHARSET_INFO *m_from_cs{nullptr};
  String m_tmp_value;
  /// Marks whether the underlying Item is constant and may be cached.
  bool m_use_cached_value{false};
  /// Length argument value, if any given.
  longlong m_cast_length{-1};  // a priori not used

 public:
  bool m_safe;

 protected:
  /**
    Helper for CAST and CONVERT type resolution: common logic to compute the
    maximum numbers of characters of the type of the conversion.

    @returns the maximum numbers of characters possible after the conversion
  */
  uint32 compute_max_char_length();

  bool resolve_type(THD *thd) override;

 public:
  Item_charset_conversion(THD *thd, Item *a, const CHARSET_INFO *cs_arg,
                          bool cache_if_const)
      : Item_str_func(a), m_cast_cs(cs_arg) {
    if (cache_if_const && args[0]->may_evaluate_const(thd)) {
      uint errors = 0;
      String tmp, *str = args[0]->val_str(&tmp);
      if (!str || str_value.copy(str->ptr(), str->length(), str->charset(),
                                 m_cast_cs, &errors))
        null_value = true;
      m_use_cached_value = true;
      str_value.mark_as_const();
      m_safe = (errors == 0);
    } else {
      m_use_cached_value = false;
      // Marks whether the conversion is safe
      m_safe = (args[0]->collation.collation == &my_charset_bin ||
                cs_arg == &my_charset_bin || (cs_arg->state & MY_CS_UNICODE));
    }
  }
  Item_charset_conversion(const POS &pos, Item *a, const CHARSET_INFO *cs_arg)
      : Item_str_func(pos, a), m_cast_cs(cs_arg) {}

  String *val_str(String *) override;
  longlong cast_length() { return m_cast_length; }
  const CHARSET_INFO *get_cast_cs() { return m_cast_cs; }
};

class Item_typecast_char final : public Item_charset_conversion {
 public:
  Item_typecast_char(THD *thd, Item *a, longlong length_arg,
                     const CHARSET_INFO *cs_arg)
      : Item_charset_conversion(thd, a, cs_arg, false) {
    m_cast_length = length_arg;
  }
  Item_typecast_char(const POS &pos, Item *a, longlong length_arg,
                     const CHARSET_INFO *cs_arg)
      : Item_charset_conversion(pos, a, cs_arg) {
    m_cast_length = length_arg;
  }
  enum Functype functype() const override { return TYPECAST_FUNC; }
  bool eq(const Item *item, bool binary_cmp) const override;
  const char *func_name() const override { return "cast_as_char"; }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_to_clob : public Item_charset_conversion {
 protected:
  typedef Item_charset_conversion super;

 public:
  Item_to_clob(THD *thd, const POS &pos, PT_item_list *a)
      : Item_charset_conversion(pos, a->value.at(0),
                                thd->variables.collation_database) {}
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "to_clob"; }
  String *val_str(String *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_load_file final : public Item_str_func {
  typedef Item_str_func super;

  String tmp_value;

 public:
  Item_load_file(const POS &pos, Item *a) : Item_str_func(pos, a) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  const char *func_name() const override { return "load_file"; }
  table_map get_initial_pseudo_tables() const override {
    return INNER_TABLE_BIT;
  }
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, 1)) return true;
    collation.set(&my_charset_bin, DERIVATION_COERCIBLE);
    set_data_type_blob(MAX_BLOB_WIDTH);
    set_nullable(true);
    return false;
  }
  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return true;
  }

  // prevent caching of the item value in Item_func_isnull
  table_map used_tables() const override { return (table_map)1L; }
};

class Item_func_export_set final : public Item_str_func {
 public:
  Item_func_export_set(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  Item_func_export_set(const POS &pos, Item *a, Item *b, Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {}
  Item_func_export_set(const POS &pos, Item *a, Item *b, Item *c, Item *d,
                       Item *e)
      : Item_str_func(pos, a, b, c, d, e) {}
  String *val_str(String *str) override;
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "export_set"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_quote : public Item_str_func {
  String tmp_value;

 public:
  Item_func_quote(const POS &pos, Item *a) : Item_str_func(pos, a) {}
  const char *func_name() const override { return "quote"; }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_conv_charset final : public Item_charset_conversion {
 public:
  Item_func_conv_charset(const POS &pos, Item *a, const CHARSET_INFO *cs)
      : Item_charset_conversion(pos, a, cs) {
    m_safe = false;
  }

  Item_func_conv_charset(THD *thd, Item *a, const CHARSET_INFO *cs,
                         bool cache_if_const)
      : Item_charset_conversion(thd, a, cs, cache_if_const) {
    assert(args[0]->fixed);
  }
  const char *func_name() const override { return "convert"; }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_set_collation final : public Item_str_func {
  typedef Item_str_func super;

  LEX_STRING collation_string;

 public:
  Item_func_set_collation(const POS &pos, Item *a,
                          const LEX_STRING &collation_string_arg)
      : super(pos, a, nullptr), collation_string(collation_string_arg) {}

  bool itemize(Parse_context *pc, Item **res) override;
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  bool eq(const Item *item, bool binary_cmp) const override;
  const char *func_name() const override { return "collate"; }
  enum Functype functype() const override { return COLLATE_FUNC; }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;
  Item_field *field_for_view_update() override {
    /* this function is transparent for view updating */
    return args[0]->field_for_view_update();
  }

  Item *pq_clone(THD *thd, Query_block *select) override;
  bool pq_copy_from(THD *thd, Query_block *select, Item *item) override;
  std::string get_collation_string() {
    return std::string(collation_string.str, collation_string.length);
  }
};

class Item_func_charset final : public Item_str_func {
 public:
  Item_func_charset(const POS &pos, Item *a) : Item_str_func(pos, a) {
    null_on_null = false;
  }
  String *val_str(String *) override;
  const char *func_name() const override { return "charset"; }
  bool resolve_type(THD *thd) override {
    set_data_type_string(64U, system_charset_info);
    set_nullable(false);
    return Item_str_func::resolve_type(thd);
  }

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_collation : public Item_str_func {
 public:
  Item_func_collation(const POS &pos, Item *a) : Item_str_func(pos, a) {
    null_on_null = false;
  }
  String *val_str(String *) override;
  const char *func_name() const override { return "collation"; }
  bool resolve_type(THD *thd) override {
    if (Item_str_func::resolve_type(thd)) return true;
    set_data_type_string(64U, system_charset_info);
    set_nullable(false);
    return false;
  }

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_weight_string final : public Item_str_func {
  typedef Item_str_func super;

  String tmp_value;
  uint flags;
  const uint num_codepoints;
  const uint result_length;
  Item_field *m_field_ref{nullptr};
  const bool as_binary;

 public:
  Item_func_weight_string(const POS &pos, Item *a, uint result_length_arg,
                          uint num_codepoints_arg, uint flags_arg,
                          bool as_binary_arg = false)
      : Item_str_func(pos, a),
        flags(flags_arg),
        num_codepoints(num_codepoints_arg),
        result_length(result_length_arg),
        as_binary(as_binary_arg) {
    set_has_notsupported_func_true();
  }

  bool itemize(Parse_context *pc, Item **res) override;

  const char *func_name() const override { return "weight_string"; }
  bool eq(const Item *item, bool binary_cmp) const override;
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_crc32 final : public Item_int_func {
  String value;

 public:
  Item_func_crc32(const POS &pos, Item *a) : Item_int_func(pos, a) {
    unsigned_flag = true;
  }
  const char *func_name() const override { return "crc32"; }
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, 1)) return true;
    max_length = 10;
    return false;
  }
  longlong val_int() override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_uncompressed_length final : public Item_int_func {
  String value;

 public:
  Item_func_uncompressed_length(const POS &pos, Item *a)
      : Item_int_func(pos, a) {}
  const char *func_name() const override { return "uncompressed_length"; }
  bool resolve_type(THD *thd) override {
    if (param_type_is_default(thd, 0, 1)) return true;
    max_length = 10;
    return false;
  }
  longlong val_int() override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_compress final : public Item_str_func {
  String buffer;

 public:
  Item_func_compress(const POS &pos, Item *a) : Item_str_func(pos, a) {}
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "compress"; }
  String *val_str(String *str) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_uncompress final : public Item_str_func {
  String buffer;

 public:
  Item_func_uncompress(const POS &pos, Item *a) : Item_str_func(pos, a) {}
  bool resolve_type(THD *thd) override {
    if (Item_str_func::resolve_type(thd)) return true;
    set_nullable(true);
    set_data_type_string(uint32{MAX_BLOB_WIDTH});
    return false;
  }
  const char *func_name() const override { return "uncompress"; }
  String *val_str(String *str) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_uuid final : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_uuid() : Item_str_func() {}
  explicit Item_func_uuid(const POS &pos) : Item_str_func(pos) {}

  bool itemize(Parse_context *pc, Item **res) override;
  table_map get_initial_pseudo_tables() const override {
    return RAND_TABLE_BIT;
  }
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "uuid"; }
  String *val_str(String *) override;
  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return ((func_arg->source == VGS_GENERATED_COLUMN) ||
            (func_arg->source == VGS_CHECK_CONSTRAINT));
  }

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_sys_guid final : public Item_str_func {
  typedef Item_str_func super;

 public:
  Item_func_sys_guid() : Item_str_func() {}
  explicit Item_func_sys_guid(const POS &pos) : Item_str_func(pos) {}

  bool itemize(Parse_context *pc, Item **res) override;
  table_map get_initial_pseudo_tables() const override {
    return RAND_TABLE_BIT;
  }
  bool resolve_type(THD *) override;
  const char *func_name() const override { return "sys_guid"; }
  String *val_str(String *) override;
  bool check_function_as_value_generator(uchar *checker_args) override {
    Check_function_as_value_generator_parameters *func_arg =
        pointer_cast<Check_function_as_value_generator_parameters *>(
            checker_args);
    func_arg->banned_function_name = func_name();
    return ((func_arg->source == VGS_GENERATED_COLUMN) ||
            (func_arg->source == VGS_CHECK_CONSTRAINT));
  }
};

class Item_func_start_secondary_engine_increment_load_task final
    : public Item_str_ascii_func {
  String buf1, buf2, buf3;

 public:
  Item_func_start_secondary_engine_increment_load_task(const POS &pos, Item *a,
                                                       Item *b)
      : Item_str_ascii_func(pos, a, b),
        auto_position(true),
        strict_mode(true) {}
  Item_func_start_secondary_engine_increment_load_task(const POS &pos, Item *a,
                                                       Item *b, Item *c)
      : Item_str_ascii_func(pos, a, b, c),
        auto_position(false),
        strict_mode(true) {}
  Item_func_start_secondary_engine_increment_load_task(const POS &pos, Item *a,
                                                       Item *b, Item *c,
                                                       Item *d)
      : Item_str_ascii_func(pos, a, b, c, d),
        auto_position(false),
        strict_mode(true) {}
  bool resolve_type(THD *) override;
  const char *func_name() const override {
    return "Item_func_start_secondary_engine_increment_load_task";
  }
  String *val_str_ascii(String *) override;

 private:
  bool auto_position;
  bool strict_mode;
};

class Item_func_stop_secondary_engine_increment_load_task final
    : public Item_str_ascii_func {
  String buf1, buf2;

 public:
  Item_func_stop_secondary_engine_increment_load_task(const POS &pos, Item *a,
                                                      Item *b)
      : Item_str_ascii_func(pos, a, b) {}
  bool resolve_type(THD *) override;
  const char *func_name() const override {
    return "Item_func_stop_secondary_engine_increment_load_task";
  }
  String *val_str_ascii(String *) override;
};

class Item_func_read_secondary_engine_load_gtid final
    : public Item_str_ascii_func {
  String buf1, buf2;

 public:
  Item_func_read_secondary_engine_load_gtid(const POS &pos, Item *a, Item *b)
      : Item_str_ascii_func(pos, a, b) {}
  bool resolve_type(THD *) override;
  const char *func_name() const override {
    return "Item_func_read_secondary_engine_load_gtid";
  }
  String *val_str_ascii(String *) override;
};

class Item_func_current_role final : public Item_func_sysconst {
  typedef Item_func_sysconst super;

 public:
  Item_func_current_role() : super(), value_cache_set(false) {}
  explicit Item_func_current_role(const POS &pos)
      : super(pos), value_cache_set(false) {}
  const char *func_name() const override { return "current_role"; }
  void cleanup() override;
  String *val_str(String *) override;
  bool resolve_type(THD *) override {
    set_data_type_string(MAX_BLOB_WIDTH, system_charset_info);
    return false;
  }
  const Name_string fully_qualified_func_name() const override {
    return NAME_STRING("current_role()");
  }

 protected:
  void set_current_role(THD *thd);
  /** a flag whether @ref value_cache is set or not */
  bool value_cache_set;
  /**
    @brief Cache for the result value

    Set by init(). And consumed by val_str().
    Needed to avoid re-calculation of the current_roles() in the
    course of the query.
  */
  String value_cache;
};

class Item_func_roles_graphml final : public Item_func_sysconst {
  typedef Item_func_sysconst super;

 public:
  Item_func_roles_graphml() : super(), value_cache_set(false) {}
  explicit Item_func_roles_graphml(const POS &pos)
      : super(pos), value_cache_set(false) {}
  String *val_str(String *) override;
  void cleanup() override;

  bool resolve_type(THD *) override {
    set_data_type_string(MAX_BLOB_WIDTH, system_charset_info);
    return false;
  }

  const char *func_name() const override { return "roles_graphml"; }

  const Name_string fully_qualified_func_name() const override {
    return NAME_STRING("roles_graphml()");
  }

 protected:
  bool calculate_graphml(THD *thd);
  /**
    @brief Cache for the result value

    Set by init(). And consumed by val_str().
    Needed to avoid re-calculation of the current_roles() in the
    course of the query.
  */
  String value_cache;

  /** Set to true if @ref value_cache is set */
  bool value_cache_set;
};

class Item_func_get_dd_column_privileges final : public Item_str_func {
 public:
  Item_func_get_dd_column_privileges(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    /*
      There are 14 kinds of grants, with a max length
      per privileges is 11 chars.
      So, setting max approximate to 200.
    */
    set_data_type_string(14U * 11U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "get_dd_column_privileges"; }

  String *val_str(String *) override;
};

class Item_func_get_dd_create_options final : public Item_str_func {
 public:
  Item_func_get_dd_create_options(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(false);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "get_dd_create_options"; }

  String *val_str(String *) override;

  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_get_dd_schema_options final : public Item_str_func {
 public:
  Item_func_get_dd_schema_options(const POS &pos, Item *a)
      : Item_str_func(pos, a) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256, system_charset_info);
    set_nullable(false);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "get_dd_schema_options"; }

  String *val_str(String *) override;
};

class Item_func_internal_get_comment_or_error final : public Item_str_func {
 public:
  Item_func_internal_get_comment_or_error(const POS &pos, PT_item_list *list)
      : Item_str_func(pos, list) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    /*
      maximum expected string length to be less than 2048 characters,
      which is same as size of column holding comments in dictionary,
      i.e., the mysql.tables.comment DD column.
    */
    set_data_type_string(2048U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_get_comment_or_error";
  }

  String *val_str(String *) override;
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_get_dd_tablespace_private_data final : public Item_str_func {
 public:
  Item_func_get_dd_tablespace_private_data(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    /* maximum string length of the property value is expected
    to be less than 256 characters. */
    set_data_type_string(256U);
    set_nullable(false);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "get_dd_tablespace_private_data";
  }

  String *val_str(String *) override;
};

class Item_func_get_dd_index_private_data final : public Item_str_func {
 public:
  Item_func_get_dd_index_private_data(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    /* maximum string length of the property value is expected
    to be less than 256 characters. */
    set_data_type_string(256U);
    set_nullable(false);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "get_dd_index_private_data"; }

  String *val_str(String *) override;
};

class Item_func_get_partition_nodegroup final : public Item_str_func {
 public:
  Item_func_get_partition_nodegroup(const POS &pos, Item *a)
      : Item_str_func(pos, a) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_get_partition_nodegroup";
  }

  String *val_str(String *) override;
};

class Item_func_internal_tablespace_type : public Item_str_func {
 public:
  Item_func_internal_tablespace_type(const POS &pos, Item *a, Item *b, Item *c,
                                     Item *d)
      : Item_str_func(pos, a, b, c, d) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "internal_tablespace_type"; }

  String *val_str(String *) override;
};

class Item_func_internal_tablespace_logfile_group_name : public Item_str_func {
 public:
  Item_func_internal_tablespace_logfile_group_name(const POS &pos, Item *a,
                                                   Item *b, Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_tablespace_logfile_group_name";
  }

  String *val_str(String *) override;
};

class Item_func_internal_tablespace_status : public Item_str_func {
 public:
  Item_func_internal_tablespace_status(const POS &pos, Item *a, Item *b,
                                       Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_tablespace_status";
  }
  String *val_str(String *) override;
};

class Item_func_internal_tablespace_row_format : public Item_str_func {
 public:
  Item_func_internal_tablespace_row_format(const POS &pos, Item *a, Item *b,
                                           Item *c, Item *d)
      : Item_str_func(pos, a, b, c, d) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_tablespace_row_format";
  }

  String *val_str(String *) override;
};

class Item_func_internal_tablespace_extra : public Item_str_func {
 public:
  Item_func_internal_tablespace_extra(const POS &pos, Item *a, Item *b, Item *c,
                                      Item *d)
      : Item_str_func(pos, a, b, c, d) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "internal_tablespace_extra"; }

  String *val_str(String *) override;
};

class Item_func_convert_cpu_id_mask final : public Item_str_func {
 public:
  Item_func_convert_cpu_id_mask(const POS &pos, Item *list)
      : Item_str_func(pos, list) {}

  bool resolve_type(THD *) override {
    set_nullable(false);
    set_data_type_string(1024U, &my_charset_bin);
    return false;
  }

  const char *func_name() const override { return "convert_cpu_id_mask"; }

  String *val_str(String *) override;
};

class Item_func_get_dd_property_key_value final : public Item_str_func {
 public:
  Item_func_get_dd_property_key_value(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    set_data_type_string(MAX_BLOB_WIDTH, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "get_dd_property_key_value"; }

  String *val_str(String *) override;
};

class Item_func_remove_dd_property_key final : public Item_str_func {
 public:
  Item_func_remove_dd_property_key(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    set_data_type_string(MAX_BLOB_WIDTH, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "remove_dd_property_key"; }

  String *val_str(String *) override;
};

class Item_func_convert_interval_to_user_interval final : public Item_str_func {
 public:
  Item_func_convert_interval_to_user_interval(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "convert_interval_to_user_interval";
  }

  String *val_str(String *) override;
};

class Item_func_internal_get_username final : public Item_str_func {
 public:
  Item_func_internal_get_username(const POS &pos, PT_item_list *list)
      : Item_str_func(pos, list) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    set_data_type_string(uint32(USERNAME_LENGTH + 1), system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "internal_get_username"; }

  String *val_str(String *) override;
};

class Item_func_internal_get_hostname final : public Item_str_func {
 public:
  Item_func_internal_get_hostname(const POS &pos, PT_item_list *list)
      : Item_str_func(pos, list) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    set_data_type_string(uint32(HOSTNAME_LENGTH + 1), system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override { return "internal_get_hostname"; }

  String *val_str(String *) override;
};

class Item_func_internal_get_enabled_role_json final : public Item_str_func {
 public:
  explicit Item_func_internal_get_enabled_role_json(const POS &pos)
      : Item_str_func(pos) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    set_data_type_string(uint32(MAX_BLOB_WIDTH), system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_get_enabled_role_json";
  }

  String *val_str(String *) override;
};

class Item_func_internal_get_mandatory_roles_json final : public Item_str_func {
 public:
  explicit Item_func_internal_get_mandatory_roles_json(const POS &pos)
      : Item_str_func(pos) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    set_data_type_string(uint32(MAX_BLOB_WIDTH), system_charset_info);
    set_nullable(true);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_get_mandatory_roles_json";
  }

  String *val_str(String *) override;
};

class Item_func_internal_get_dd_column_extra final : public Item_str_func {
 public:
  Item_func_internal_get_dd_column_extra(const POS &pos, PT_item_list *list)
      : Item_str_func(pos, list) {}

  enum Functype functype() const override { return DD_INTERNAL_FUNC; }
  bool resolve_type(THD *) override {
    // maximum string length of all options is expected
    // to be less than 256 characters.
    set_data_type_string(256U, system_charset_info);
    set_nullable(false);
    null_on_null = false;

    return false;
  }

  const char *func_name() const override {
    return "internal_get_dd_column_extra";
  }

  String *val_str(String *) override;
};
class Item_func_initcap : public Item_str_func {
 protected:
  uint multiply;
  String tmp_value;
  THD *thd = nullptr;

 public:
  Item_func_initcap(const POS &pos, Item *item) : Item_str_func(pos, item) {
    thd = current_thd;
    set_has_notsupported_func_true();
  }
  const char *func_name() const override { return "initcap"; }
  String *val_str(String *) override;
  bool resolve_type(THD *) override;
};

class Item_func_nchr final : public Item_str_func {
 public:
  Item_func_nchr(const POS &pos, Item *arg) : Item_str_func(pos, arg) {
    set_has_notsupported_func_true();
  }
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "nchr"; }
};
class Item_func_utl_raw_convert final : public Item_str_func {
 public:
  Item_func_utl_raw_convert(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  const char *func_name() const override { return "utl_raw_convert"; }
  bool resolve_type(THD *) override;
  String *val_str(String *) override;
};

class Item_func_to_raw final : public Item_str_func {
 public:
  Item_func_to_raw(const POS &pos, Item *a, Item *b, enum_field_types type_arg)
      : Item_str_func(pos, a, b), from_type(type_arg) {}
  const char *func_name() const override { return "to_raw"; }
  bool resolve_type(THD *) override;
  String *val_str(String *) override;

  void set_from_type(enum_field_types type) { from_type = type; }

 private:
  bool get_raw_from_data(const uchar *val, uint val_len, uchar *ptr,
                         uint copy_size, uint to_endian);

  enum_field_types from_type;
};

class Item_func_utl_encode_quoted_printable_encode final
    : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_quoted_printable_encode(const POS &pos, Item *a)
      : Item_str_func(pos, a) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override {
    return "utl_encode_quoted_printable_encode";
  }
};

class Item_func_utl_encode_quoted_printable_decode final
    : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_quoted_printable_decode(const POS &pos, Item *a)
      : Item_str_func(pos, a) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override {
    return "utl_encode_quoted_printable_decode";
  }
};

enum enum_text_encode_type {
  TEXT_ENCODE_BASE64 = 1,
  TEXT_ENCODE_QUOTED_PRINTABLE = 2,
};

class Item_func_utl_encode_text_encode final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_text_encode(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "utl_encode_text_encode"; }
};

class Item_func_utl_encode_text_decode final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_text_decode(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "utl_encode_text_decode"; }
};

/*
mimeheader encoding format
=?charset?encoding?text_encode_str?=
charset: such as utf8 gbk
encoding: can only be B or Q
text_encode_str: the string of coding result

eg:
the origin string 'aa'
base64_encode result is 'YWE='
quoted_printable result is 'aa'
so the mimeheader encoding result maybe is
=?utf8?B?YWE=?= (for base64_encode) or
=?utf8?Q?aa?= (for quoted_printable)
*/
class Item_func_utl_encode_mimeheader_encode final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_mimeheader_encode(const POS &pos, Item *a, Item *b,
                                         Item *c)
      : Item_str_func(pos, a, b, c) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override {
    return "utl_encode_mimeheader_encode";
  }
};

class Item_func_utl_encode_mimeheader_decode final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_mimeheader_decode(const POS &pos, Item *a)
      : Item_str_func(pos, a) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override {
    return "utl_encode_mimeheader_decode";
  }
};

enum enum_uuencode_type {
  UUENCODE_ALL = 1,
  UUENCODE_HEAD_BODY = 2,
  UUENCODE_BODY = 3,
  UUENCODE_BODY_TAIL = 4,
};

class Item_func_utl_encode_uuencode final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_uuencode(const POS &pos, Item *a, Item *b, Item *c,
                                Item *d)
      : Item_str_func(pos, a, b, c, d) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "utl_encode_uuencode"; }
};

class Item_func_utl_encode_uudecode final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_encode_uudecode(const POS &pos, Item *a)
      : Item_str_func(pos, a) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "utl_encode_uudecode"; }
};
class Item_func_sqlcode : public Item_int_func {
  // thd
  THD *local_thd;

 public:
  explicit Item_func_sqlcode(const POS &pos)
      : Item_int_func(pos), local_thd(nullptr) {}
  const char *func_name() const override { return "sqlcode"; }
  bool resolve_type(THD *thd) override;
  longlong val_int() override;
  void print(const THD *, String *str, enum_query_type) const override {
    str->append(func_name());
  }
};

class Item_func_sqlerrm : public Item_str_func {
  THD *local_thd;

 public:
  explicit Item_func_sqlerrm(const POS &pos)
      : Item_str_func(pos), local_thd(nullptr) {}
  Item_func_sqlerrm(const POS &pos, Item *arg)
      : Item_str_func(pos, arg), local_thd(nullptr) {}
  const char *func_name() const override { return "sqlerrm"; }
  bool resolve_type(THD *thd) override;
  String *val_str(String *) override;
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override {
    str->append(func_name());
    if (argument_count() != 0) {
      str->append('(');
      print_args(thd, str, 0, query_type);
      str->append(')');
    }
  }
};

/*for i in table.first .. table.last loop
  It's table.first.
*/
class Item_func_table_first final : public Item_str_func {
  uint m_spv_idx;

 public:
  explicit Item_func_table_first(const POS &pos, uint spv_idx)
      : Item_str_func(pos), m_spv_idx(spv_idx) {}

  String *val_str(String *val) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "table_first"; }
  void print(const THD *, String *str, enum_query_type) const override {
    str->append("first");
  }
};

/*for i in table.first .. table.last loop
  It's table.last.
*/
class Item_func_table_last final : public Item_str_func {
  uint m_spv_idx;

 public:
  explicit Item_func_table_last(const POS &pos, uint spv_idx)
      : Item_str_func(pos), m_spv_idx(spv_idx) {}

  String *val_str(String *val) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "table_last"; }
  void print(const THD *, String *str, enum_query_type) const override {
    str->append("last");
  }
};

class Item_func_utl_url_escape final : public Item_str_func {
  String tmp_value;
  std::unordered_set<char> reserved_chars = {';', '/', '?', ':', '@', '&',
                                             '=', '+', '$', ',', '[', ']'};
  std::unordered_set<char> unreserved_puncts = {'-', '_',  '.', '!', '~',
                                                '*', '\'', '(', ')'};

 public:
  Item_func_utl_url_escape(const POS &pos, Item *a, Item *b, Item *c)
      : Item_str_func(pos, a, b, c) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "utl_url_escape"; }
};

class Item_func_utl_url_unescape final : public Item_str_func {
  String tmp_value;

 public:
  Item_func_utl_url_unescape(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b) {}
  String *val_str(String *) override;
  bool resolve_type(THD *thd) override;
  const char *func_name() const override { return "utl_url_unescape"; }
};


class Item_func_rawtohex : public Item_func_hex {
 public:
  Item_func_rawtohex(const POS &pos, Item *a) : Item_func_hex(pos, a) {}
  bool resolve_type(THD *thd) override;
  String *val_str(String *str) override;
  const char *func_name() const override { return "rawtohex"; }
  Item *pq_clone(THD *thd, Query_block *select) override;
};

class Item_func_maskall : public Item_str_func {
  typedef Item_str_func super;
  bool masking;
  bool fix_mask;
  String result_buffer;
  String mask_char;

 public:
  Item_func_maskall(const POS &pos, Item *a)
      : Item_str_func(pos, a),
        masking(false),
        fix_mask(false),
        mask_char("x", 1, &my_charset_bin) {}
  Item_func_maskall(const POS &pos, Item *a, Item *b)
      : Item_str_func(pos, a, b),
        masking(false),
        fix_mask(false),
        mask_char("x", 1, &my_charset_bin) {}
  Item_func_maskall(Item *a, String *mask_char_arg)
      : Item_str_func(a),
        masking(true),
        fix_mask(true),
        mask_char("x", 1, &my_charset_bin) {
    if (mask_char_arg)
      mask_char.copy(mask_char_arg->ptr(), mask_char_arg->length(),
                     mask_char_arg->charset());
  }

  String *val_str(String *str) override;

  bool resolve_type(THD *) override;
  const char *func_name() const override { return "maskall"; }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override {
    if (masking) {
      args[0]->print(thd, str, query_type);
    } else {
      super::print(thd, str, query_type);
    }
  }
};

class Item_func_mask_inside : public Item_str_func {
  typedef Item_str_func super;
  bool masking;
  size_t start_pos{0};
  bool start_pos_fix;
  size_t end_pos{INT_MAX32};
  bool end_pos_fix;

  bool fix_mask;
  String result_buffer;
  String mask_char;

 public:
  Item_func_mask_inside(const POS &pos, PT_item_list *a)
      : Item_str_func(pos, a),
        masking(false),
        start_pos_fix(false),
        end_pos_fix(false),
        fix_mask(false),
        mask_char("x", 1, &my_charset_bin) {}

  Item_func_mask_inside(Item *a, size_t start_arg, size_t end_arg,
                        String *mask_char_arg)
      : Item_str_func(a),
        masking(true),
        start_pos(start_arg),
        start_pos_fix(true),
        end_pos(end_arg),
        end_pos_fix(true),
        fix_mask(true),
        mask_char("x", 1, &my_charset_bin) {
    if (mask_char_arg) {
      mask_char.copy(mask_char_arg->ptr(), mask_char_arg->length(),
                     mask_char_arg->charset());
    }
  }

  String *val_str(String *str) override;

  bool resolve_type(THD *) override;

  const char *func_name() const override { return "mask_inside"; }
  void print(const THD *thd, String *str,
             enum_query_type query_type) const override {
    if (masking) {
      args[0]->print(thd, str, query_type);
    } else {
      super::print(thd, str, query_type);
    }
  }
};

#endif /* ITEM_STRFUNC_INCLUDED */
