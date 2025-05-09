/* Copyright (c) 2023, GreatDB Software Co., Ltd. All rights reserved.

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
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA
*/

#include "sql/pivot.h"
#include "sql/item_sum.h"
#include "sql/parse_tree_nodes.h"
#include "sql/sql_base.h"
#include "sql/sql_lex.h"

/**
  Expand the aggregation function and replace the parameters of the aggregation
  function to make it a conditional aggregation
*/
bool Pivot::setup_pivot(THD *thd) {
  if (setup_group(thd)) return true;
  if (check_sum_func_alias()) return true;

  char buff[MAX_FIELD_WIDTH];
  String str(buff, sizeof(buff), system_charset_info);
  for (size_t i = 0; i < cond_values->value.size(); ++i) {
    /* All values in cond_values must be constant expressions */
    if (!cond_values->value[i]->const_item()) {
      my_error(ER_INVALID_PARAMETER_USE, MYF(0), "IN clause");
      return true;
    }

    for (auto it : sum_funcs->value) {
      /* Clone aggregation function */
      Item_sum *sum_func = down_cast<Item_sum *>(it->copy_or_same(thd));
      if (!sum_func) {
        my_error(ER_INVALID_GROUP_FUNC_USE, MYF(0));
        return true;
      }

      int arg_pos = sum_func->pivot_arg_idx_for_cond();
      if (arg_pos < 0) {
        my_error(ER_INVALID_GROUP_FUNC_USE, MYF(0));
        return true;
      }
      /* Constructs conditions in CASE...WHEN expressions */
      Item *cond_expr = new (thd->mem_root)
          Item_func_eq(POS(), cond_var, cond_values->value[i]);
      /* Constructs a CASE...WHEN expression */
      mem_root_deque<Item *> *when_list =
          new (thd->mem_root) mem_root_deque<Item *>(thd->mem_root);
      when_list->push_back(cond_expr);
      /**
       Use the aggregation parameter of the aggregation function as the
       expression when the aggregation condition is true
      */
      when_list->push_back(sum_func->get_arg(arg_pos));
      Item *case_func = new (thd->mem_root)
          Item_func_case(POS(), when_list, nullptr, nullptr);
      /**
       Replace aggregate parameters of aggregate functions with CASE...WHEN
       expressions
      */
      sum_func->set_arg_resolve(thd, arg_pos, case_func);

      /**
        Modify the item_name of the aggregate function
      */
      str.length(0);
      str.append(cond_values->value[i]->item_name.ptr(),
                 cond_values->value[i]->item_name.length());
      if (sum_func->item_name.is_set() &&
          !sum_func->item_name.is_autogenerated()) {
        str.append("_");
        str.append(sum_func->item_name.ptr(), sum_func->item_name.length());
      }
      sum_func->item_name.copy(str.c_ptr_safe(), str.length(),
                               system_charset_info, true);

      m_owner->fields.push_back(sum_func);
    }
  }

  return false;
}

/**
  Add implicit grouping and expand '*' in SELECT item
  Any field in the original table that does not appear in PIVOT is regarded as
  an implicit grouping field
*/
bool Pivot::setup_group(THD *thd) {
  // Search pivot field ref
  mem_root_deque<Item *> pivot_field_ref{thd->mem_root};
  cond_var->walk(&Item::collect_item_field_processor, enum_walk::POSTFIX,
                 (uchar *)&pivot_field_ref);
  for (auto it : sum_funcs->value) {
    it->walk(&Item::collect_item_field_processor, enum_walk::POSTFIX,
             (uchar *)&pivot_field_ref);
  }

  // Add implicit group
  mem_root_deque<Item *> columns(thd->mem_root);
  std::swap(columns, m_owner->fields);
  for (auto column : VisibleFields(columns)) {
    if (pivot_field_ref.end() ==
        std::find_if(pivot_field_ref.begin(), pivot_field_ref.end(),
                     [&column](const Item *field) {
                       return 0 == my_strcasecmp(system_charset_info,
                                                 column->item_name.ptr(),
                                                 field->item_name.ptr());
                     })) {
      ORDER *order =
          new (thd->mem_root) PT_order_expr(column, ORDER_NOT_RELEVANT);
      if (!order) {
        my_error(ER_OOM, MYF(0));
        return true;
      }
      order->used_alias = false;
      order->used = 0;
      m_owner->group_list.link_in_list(order, &order->next);
      m_owner->fields.push_back(column);
    }
  }

  return false;
}

/**
  Check the aliases of all aggregate functions: only one aggregate function is
  allowed without an alias
*/
bool Pivot::check_sum_func_alias() {
  bool found_no_alias = false;
  for (auto it : sum_funcs->value) {
    if (!it->item_name.is_set() || it->item_name.is_autogenerated()) {
      if (found_no_alias) {
        my_error(ER_INVALID_GROUP_FUNC_USE, MYF(0));
        return true;
      }
      found_no_alias = true;
    }
  }
  return false;
}
