/*
   Copyright (c) 2016, 2022, Oracle and/or its affiliates. All rights reserved.
   Copyright (c) 2023, GreatDB Software Co., Ltd.

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
#ifndef DD_TRIGGER_INCLUDED
#define DD_TRIGGER_INCLUDED

#include "lex_string.h"
#include "sql/trigger_def.h"  // enum_trigger_order_type

struct MEM_ROOT;
class THD;
class Trigger;
class Event_parse_data;

template <class T>
class List;

namespace dd {
class Table;

/**
  Create new trigger in the data dictionary.

  @param [in]  thd                thread handle
  @param [in]  new_trigger        Trigger object from sql-layer that describes
                                  a trigger to add in the Data Dictionary
  @param [in]  ordering_clause    Ordering property for trigger being created
  @param [in]  referenced_trigger_name  Information about trigger referenced by
                                        ordering_clause if any.


  @return Operation status
    @retval true   Failure
    @retval false  Success
*/

bool create_trigger(THD *thd, const ::Trigger *new_trigger,
                    enum_trigger_order_type ordering_clause,
                    const LEX_CSTRING &referenced_trigger_name);

/**
  Load table triggers from the data dictionary.

  @param [in]  thd                thread handle
  @param [in]  mem_root           MEM_ROOT for memory allocation
  @param [in]  schema_name        name of schema
  @param [in]  table_name         subject table name
  @param [in]  table              table object
  @param [out] triggers           pointer to the list where new Trigger
                                  objects will be inserted

  @return Operation status
    @retval true   Failure
    @retval false  Success
*/

bool load_triggers(THD *thd, MEM_ROOT *mem_root, const char *schema_name,
                   const char *table_name, const dd::Table &table,
                   List<::Trigger> *triggers);

/**
  Clone trigger from the data dictionary.

  @param [in]  mem_root           MEM_ROOT for memory allocation
  @param [in]  src_trigger        src trigger
  @param [in]  schema_name        name of schema
  @param [in]  table_name         subject table name

  @return Operation status
    @retval ::Trigger
*/
::Trigger *clone_trigger(MEM_ROOT *mem_root, ::Trigger *src_trigger,
                         const char *schema_name, const char *table_name);

/**
  Check in the data dictionary if there is any trigger associated with a table.

  @param [in]  thd                thread handle
  @param [in]  schema_name        name of schema
  @param [in]  table_name         subject table name
  @param [out] table_has_trigger  true in case there is trigger(s) for a table,
                                  else false

  @return Operation status
    @retval true   Failure
    @retval false  Success

*/

bool table_has_triggers(THD *thd, const char *schema_name,
                        const char *table_name, bool *table_has_trigger);

/**
  clone_trigger_and_set_status trigger from the data dictionary.

  @param [in]  mem_root           MEM_ROOT for memory allocation
  @param [in]  src_trigger        src trigger
  @param [in]  schema_name        name of schema
  @param [in]  table_name         subject table name
  @param [in]  parse_data         Event information obtained from parser.
  @param [in]  dd_table           dd::Table

  @return Operation status
    @retval ::Trigger
*/
bool clone_trigger_and_set_status(MEM_ROOT *mem_root, ::Trigger *src_trigger,
                                  const char *schema_name,
                                  const char *table_name,
                                  Event_parse_data *parse_data,
                                  Table *dd_table);

}  // namespace dd

#endif /* DD_TRIGGER_INCLUDED */
