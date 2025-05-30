#ifndef PQ_RANGE_INCLUDED
#define PQ_RANGE_INCLUDED

/* Copyright (c) 2013, 2020, Oracle and/or its affiliates. All rights reserved.
   Copyright (c) 2022, Huawei Technologies Co., Ltd.
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

/*
enum PQ_RANGE_TYPE {
  PQ_QUICK_SELECT_NONE,
  PQ_RANGE_SELECT,
  PQ_RANGE_SELECT_DESC,
  PQ_SKIP_SCAN_SELECT,
  PQ_GROUP_MIN_MAX_SELECT,
  PQ_INDEX_MERGE_SELECT,
  PQ_ROR_INTERSECT_SELECT,
  PQ_ROR_UNION_SELECT,
  PQ_QUICK_SELECT_INVALID
};
*/
enum PQ_RANGE_TYPE {
  PQ_QUICK_SELECT_NONE,
  PQ_INDEX_RANGE_SCAN,   // INDEX_RANGE_SCAN
  PQ_INDEX_MERGE,        // INDEX_MERGE
  PQ_ROWID_UNION,        // ROWID_UNION
  PQ_ROWID_INTERSECTION  // ROWID_INTERSECTION
};

#endif /* PQ_RANGE_INCLUDED */
