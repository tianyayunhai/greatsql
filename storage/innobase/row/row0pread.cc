/*****************************************************************************

Copyright (c) 2018, 2021, Oracle and/or its affiliates.
Copyright (c) 2022, Huawei Technologies Co., Ltd.
Copyright (c) 2023, 2025, GreatDB Software Co., Ltd.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License, version 2.0, as published by the
Free Software Foundation.

This program is also distributed with certain software (including but not
limited to OpenSSL) that is licensed under separate terms, as designated in a
particular file or component or in included license documentation. The authors
of MySQL hereby grant you an additional permission to link the program and
your derivative works with the separately licensed software that they have
included with MySQL.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License, version 2.0,
for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc.,
51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA

*****************************************************************************/

/** @file row/row0pread.cc
Parallel read implementation

Created 2018-01-27 by Sunny Bains */

#include <array>
#include <utility>

#include "btr0pcur.h"
#include "dict0dict.h"
#include "lock0lock.h"
#include "os0thread-create.h"
#include "row0mysql.h"
#include "row0pread.h"
#include "row0row.h"
#include "row0sel.h"
#include "row0vers.h"
#include "ut0new.h"

#ifdef UNIV_PFS_THREAD
mysql_pfs_key_t parallel_read_thread_key;
#endif /* UNIV_PFS_THREAD */

ICP_RESULT row_search_idx_cond_check(
    byte *mysql_rec,          /*!< out: record
                              in MySQL format (invalid unless
                              prebuilt->idx_cond == true and
                              we return ICP_MATCH) */
    row_prebuilt_t *prebuilt, /*!< in/out: prebuilt struct
                              for the table handle */
    const rec_t *rec,         /*!< in: InnoDB record */
    const ulint *offsets);    /*!< in: rec_get_offsets() */

std::atomic_size_t Parallel_reader::s_active_threads{};

/** Tree depth at which we decide to split blocks further. */
static constexpr size_t SPLIT_THRESHOLD{3};

/** No. of pages to scan, in the case of large tables, before the check for
trx interrupted is made as the call is expensive. */
static constexpr size_t TRX_IS_INTERRUPTED_PROBE{50000};

size_t Parallel_reader::MAX_THREADS = 256;
size_t Parallel_reader::MAX_TOTAL_THREADS =
    (MAX_THREADS + MAX_RESERVED_THREADS);

std::string Parallel_reader::Scan_range::to_string() const {
  std::ostringstream os;

  os << "m_start: ";
  if (m_start != nullptr) {
    m_start->print(os);
  } else {
    os << "null";
  }
  os << ", m_end: ";
  if (m_end != nullptr) {
    m_end->print(os);
  } else {
    os << "null";
  }
  return (os.str());
}

Parallel_reader::Scan_ctx::Iter::~Iter() {
  if (m_heap == nullptr) {
    return;
  }

  if (m_pcur != nullptr) {
    m_pcur->free_rec_buf();
    /* Created with placement new on the heap. */
    call_destructor(m_pcur);
  }

  mem_heap_free(m_heap);
  m_heap = nullptr;
}

Parallel_reader::Ctx::~Ctx() {
  if (m_blob_heap) mem_heap_free(m_blob_heap);

  if (m_heap) mem_heap_free(m_heap);
}

Parallel_reader::Scan_ctx::~Scan_ctx() {}

Parallel_reader::~Parallel_reader() {
  mutex_destroy(&m_mutex);
  os_event_destroy(m_event);
  if (!m_sync) {
    release_unused_threads(m_n_threads);
  }
  for (auto thread_ctx : m_thread_ctxs) {
    if (thread_ctx != nullptr) {
      ut::delete_(thread_ctx);
    }
  }
}

size_t Parallel_reader::available_threads(size_t n_required,
                                          bool use_reserved) {
  auto max_threads = MAX_THREADS;
  constexpr auto SEQ_CST = std::memory_order_seq_cst;
  auto active = s_active_threads.fetch_add(n_required, SEQ_CST);

  if (use_reserved) {
    max_threads += MAX_RESERVED_THREADS;
  }

  if (active < max_threads) {
    const auto available = max_threads - active;

    if (n_required <= available) {
      return n_required;
    } else {
      const auto release = n_required - available;
      const auto o = s_active_threads.fetch_sub(release, SEQ_CST);
      ut_a(o >= release);
      return available;
    }
  }

  const auto o = s_active_threads.fetch_sub(n_required, SEQ_CST);
  ut_a(o >= n_required);

  return 0;
}

void Parallel_reader::Scan_ctx::index_s_lock() {
  if (m_s_locks.fetch_add(1, std::memory_order_acquire) == 0) {
    auto index = m_config.m_index;
    /* The latch can be unlocked by a thread that didn't originally lock it. */
    rw_lock_s_lock_gen(dict_index_get_lock(index), true, UT_LOCATION_HERE);
  }
}

void Parallel_reader::Scan_ctx::index_s_unlock() {
  if (m_s_locks.fetch_sub(1, std::memory_order_acquire) == 1) {
    auto index = m_config.m_index;
    /* The latch can be unlocked by a thread that didn't originally lock it. */
    rw_lock_s_unlock_gen(dict_index_get_lock(index), true);
  }
}

dberr_t Parallel_reader::Ctx::split() {
  ut_ad(m_range.first->m_tuple == nullptr ||
        dtuple_validate(m_range.first->m_tuple));
  ut_ad(m_range.second->m_tuple == nullptr ||
        dtuple_validate(m_range.second->m_tuple));

  /* Setup the sub-range. */
  Scan_range scan_range(m_range.first->m_tuple, m_range.second->m_tuple);

  /* S lock so that the tree structure doesn't change while we are
  figuring out the sub-trees to scan. */
  m_scan_ctx->index_s_lock();

  Parallel_reader::Scan_ctx::Ranges ranges{};
  m_scan_ctx->partition(scan_range, ranges, 1);

  if (!ranges.empty()) {
    ranges.back().second = m_range.second;
  }

  dberr_t err{DB_SUCCESS};

  /* Create the partitioned scan execution contexts. */
  for (auto &range : ranges) {
    err = m_scan_ctx->create_context(range, false);

    if (err != DB_SUCCESS) {
      break;
    }
  }

  if (err != DB_SUCCESS) {
    m_scan_ctx->set_error_state(err);
  }

  m_scan_ctx->index_s_unlock();

  return err;
}

Parallel_reader::Parallel_reader(size_t max_threads)
    : m_max_threads(max_threads),
      m_n_threads(max_threads),
      m_ctxs(),
      m_sync(max_threads == 0),
      m_trx_for_slow_log(innobase_get_trx_for_slow_log()) {
  m_n_completed = 0;

  m_force_start_thread_for_ap_async_fetch = false;
  m_greatdb_ap_reverse_fetch = false;

  mutex_create(LATCH_ID_PARALLEL_READ, &m_mutex);

  m_event = os_event_create();
  m_sig_count = os_event_reset(m_event);
}

Parallel_reader::Scan_ctx::Scan_ctx(Parallel_reader *reader, size_t id,
                                    trx_t *trx,
                                    const Parallel_reader::Config &config,
                                    F &&f)
    : m_id(id), m_config(config), m_trx(trx), m_f(f), m_reader(reader) {}

/** Persistent cursor wrapper around btr_pcur_t */
class PCursor {
 public:
  /** Constructor.
  @param[in,out] pcur           Persistent cursor in use.
  @param[in] mtr                Mini-transaction used by the persistent cursor.
  @param[in] read_level         Read level where the block should be present. */
  PCursor(btr_pcur_t *pcur, mtr_t *mtr, size_t read_level)
      : m_mtr(mtr), m_pcur(pcur), m_read_level(read_level) {}

  /**
    Restore position of cursor created from Scan_ctx::Range object.
    Adjust it if starting record of range has been purged.
  */
  void restore_position_for_range() noexcept {
    /*
      Restore position on the record or its predecessor if the record
      was purged meanwhile. In the latter case we need to adjust position by
      moving one step forward as predecessor belongs to another range.

      We rely on return value from restore_position() to detect this scenario.
      This can be done when saved position points to user record which is
      always the case for saved start of Scan_ctx::Range.
    */
    ut_ad(m_pcur->m_rel_pos == BTR_PCUR_ON);

    if (!m_pcur->restore_position(BTR_SEARCH_LEAF, m_mtr, UT_LOCATION_HERE)) {
      page_cur_move_to_next(m_pcur->get_page_cur());
    }
  }

  /** Create a savepoint and commit the mini-transaction.*/
  void savepoint() noexcept;

  /** Resume from savepoint. */
  void resume() noexcept;
  /** Check if there are threads waiting on the index latch. Yield the latch
  so that other threads can progress. */
  void yield();
  void yield_prev();

  /** Move to the next block.
  @param[in]  index             Index being traversed.
  @return DB_SUCCESS or error code. */
  [[nodiscard]] dberr_t move_to_next_block(dict_index_t *index);

  dberr_t move_to_prev_block(dict_index_t *index)
      MY_ATTRIBUTE((warn_unused_result));

  /** Restore the cursor position. */
  void restore_position() noexcept {
    constexpr auto MODE = BTR_SEARCH_LEAF;
    const auto relative = m_pcur->m_rel_pos;
    auto equal = m_pcur->restore_position(MODE, m_mtr, UT_LOCATION_HERE);

#ifdef UNIV_DEBUG
    if (m_pcur->m_pos_state == BTR_PCUR_IS_POSITIONED_OPTIMISTIC) {
      ut_ad(m_pcur->m_rel_pos == BTR_PCUR_BEFORE ||
            m_pcur->m_rel_pos == BTR_PCUR_AFTER);
    } else {
      ut_ad(m_pcur->m_pos_state == BTR_PCUR_IS_POSITIONED);
      ut_ad((m_pcur->m_rel_pos == BTR_PCUR_ON) == m_pcur->is_on_user_rec());
    }
#endif /* UNIV_DEBUG */

    switch (relative) {
      case BTR_PCUR_ON:
        if (!equal) {
          page_cur_move_to_next(m_pcur->get_page_cur());
        }
        break;

      case BTR_PCUR_UNSET:
      case BTR_PCUR_BEFORE_FIRST_IN_TREE:
        ut_error;
        break;

      case BTR_PCUR_AFTER:
      case BTR_PCUR_AFTER_LAST_IN_TREE:
        break;

      case BTR_PCUR_BEFORE:
        /* For non-optimistic restoration:
        The position is now set to the record before pcur->old_rec.

        For optimistic restoration:
        The position also needs to take the previous search_mode into
        consideration. */
        switch (m_pcur->m_pos_state) {
          case BTR_PCUR_IS_POSITIONED_OPTIMISTIC:
            m_pcur->m_pos_state = BTR_PCUR_IS_POSITIONED;
            /* The cursor always moves "up" ie. in ascending order. */
            break;

          case BTR_PCUR_IS_POSITIONED:
            if (m_pcur->is_on_user_rec()) {
              m_pcur->move_to_next(m_mtr);
            }
            break;

          case BTR_PCUR_NOT_POSITIONED:
          case BTR_PCUR_WAS_POSITIONED:
            ut_error;
        }
        break;
    }
  }

  /** @return the current page cursor. */
  [[nodiscard]] page_cur_t *get_page_cursor() noexcept {
    return m_pcur->get_page_cur();
  }

  /** Restore from a saved position. Sets position the next user record
  in the tree if it is cursor pointing to supremum that was saved.
  @return DB_SUCCESS or error code. */
  [[nodiscard]] dberr_t restore_from_savepoint() noexcept;

  /** Move to the first user rec on the next page. */
  [[nodiscard]] dberr_t move_to_next_block_user_rec() noexcept;

  /** @return true if cursor is after last on page. */
  [[nodiscard]] bool is_after_last_on_page() const noexcept {
    return m_pcur->is_after_last_on_page();
  }

  /** @return Level where the cursor is intended. */
  size_t read_level() const noexcept { return m_read_level; }

  void move_to_up_block(dict_index_t *index, const dtuple_t *up_limit_entry) {
    m_pcur->reset();
    m_pcur->init(m_read_level);

    if (nullptr != up_limit_entry) {
      m_pcur->open_no_init(index, up_limit_entry, PAGE_CUR_L, BTR_SEARCH_LEAF,
                           false, m_mtr, UT_LOCATION_HERE);
    } else {
      m_pcur->open_at_side(false, index, BTR_SEARCH_LEAF, false, m_read_level,
                           m_mtr);
    }

    m_pcur->set_fetch_type(Page_fetch::SCAN);
  }

  rec_t *set_cur_page_first() {
    page_cur_t *page_cur = get_page_cursor();
    rec_t *cur_rec = page_cur_get_rec(page_cur);
    buf_block_t *block = page_cur_get_block(page_cur);
    page_cur_set_before_first(block, page_cur);
    rec_t *infi_rec = page_cur_get_rec(page_cur);
    if (cur_rec != infi_rec) {
      page_cur_move_to_next(page_cur);
    } else {
      cur_rec = nullptr;
    }

    return cur_rec;
  }

  /** Move to the left block.
  @param[in]  index             Index being traversed.
  @return DB_SUCCESS or error code. */
  [[nodiscard]] dberr_t move_to_left_block(const dict_index_t *index
                                           [[maybe_unused]]) {
    page_no_t prev_page_no =
        btr_page_get_prev(page_cur_get_page(get_page_cursor()), m_mtr);
    if (FIL_NULL == prev_page_no) {
      return DB_END_OF_INDEX;
    }
    m_pcur->move_before_first_on_page();
    m_pcur->move_backward_from_page(m_mtr);
    prev_page_no =
        btr_page_get_prev(page_cur_get_page(get_page_cursor()), m_mtr);
    if (FIL_NULL == prev_page_no) {
      return DB_END_OF_INDEX;
    }

    page_cur_t *page_cur = get_page_cursor();
    buf_block_t *block = page_cur_get_block(page_cur);
    page_cur_set_before_first(block, page_cur);

    /* Skip the infimum record. */
    page_cur_move_to_next(page_cur);

    return DB_SUCCESS;
  }

 private:
  /** Mini-transaction. */
  mtr_t *m_mtr{};

  /** Persistent cursor. */
  btr_pcur_t *m_pcur{};

  /** Level where the cursor is positioned or need to be positioned in case of
  restore. */
  size_t m_read_level{};

  /** Indicates that savepoint created for cursor corresponds to supremum. */
  bool m_supremum_saved{};
};

buf_block_t *Parallel_reader::Scan_ctx::block_get_s_latched(
    const page_id_t &page_id, mtr_t *mtr, size_t line) const {
  /* We never scan undo tablespaces. */
  ut_a(!fsp_is_undo_tablespace(page_id.space()));

  auto block =
      buf_page_get_gen(page_id, m_config.m_page_size, RW_S_LATCH, nullptr,
                       Page_fetch::SCAN, {__FILE__, line}, mtr);

  buf_block_dbg_add_level(block, SYNC_TREE_NODE);

  return (block);
}

void PCursor::savepoint() noexcept {
  /* The below code will not work correctly in all cases if we are to take
  savepoint of cursor pointing to infimum.

  If savepoint is taken for such a cursor, in optimistic restore case we
  might not detect situation when after mini-trancation commit/latches
  release concurrent merge from the previous page or concurrent update of
  the last record on the previous page, which doesn't fit into it, has
  moved records over infimum (see MySQL bugs #114248 and #115518).
  As result scan will revisit these records, which can cause, for example,
  ALTER TABLE failing with a duplicate key error.

  Luckily, at the moment, savepoint is taken only when cursor points
  to a user record (when we do save/restore from Parallel_reader::Ctx::m_f
  callback which processes records) or to the supremum (when we do save/
  restore from Parallel_reader::m_finish_callback end-of-page callback or
  before switching to next page in move_to_next_block()). */
  ut_ad(!m_pcur->is_before_first_on_page());

  /* If we are taking savepoint for cursor pointing to supremum we are doing
  one step back. This is necessary to prevent situation when concurrent
  merge from the next page, which happens after we commit mini-transaction/
  release latches moves records over supremum to the current page.
  In this case the optimistic restore of cursor pointing to supremum will
  result in cursor pointing to supremum, which means moved records will
  be incorrectly skipped by the scan. */
  m_supremum_saved = m_pcur->is_after_last_on_page();
  if (m_supremum_saved) {
    m_pcur->move_to_prev_on_page();
    // Only root page can be empty and we are not supposed to get here
    // in this case.
    ut_ad(!m_pcur->is_before_first_on_page());
  }

  /* Thanks to the above we can say that we are saving position of last user
  record which have processed/ which corresponds to last key value we have
  processed. */
  m_pcur->store_position(m_mtr);

  m_mtr->commit();
}

void PCursor::resume() noexcept {
  m_mtr->start();

  m_mtr->set_log_mode(MTR_LOG_NO_REDO);

  /* Restore position on the record, or its predecessor if the record
  was purged meanwhile. In extreme case this can be infimum record of
  the first page in the tree. However, this can never be a supremum
  record on a page, since we always move cursor one step back when
  savepoint() is called for infimum record.

  We can be in either of the two situations:

  1) We do save/restore from Parallel_reader:::Ctx::m_f callback for
  record processing. In this case we saved position of user-record for
  which callback was invoked originally, and which we already consider
  as processed. In theory, such record is not supposed be purged as our
  transaction holds read view on it. But in practice, it doesn't matter
  - even if the record was purged then our cursor will still point to
  last processed user record in the tree after its restoration.
  And Parallel_reader:::Ctx::m_f callback execution is always followed by
  page_cur_move_to_next() call, which moves our cursor to the next record
  and this record has not been processed yet.

  2) We do save/restore from the Parallel_reader::m_finish_callback
  end-of-page callback or from move_to_next_block() before switching
  the page. In this case our cursor was positioned on supremum record
  before savepoint() call.
  Th savepoint() call raised m_supremum_saved flag and saved the position
  of the user record which preceded the supremum, i.e. the last user record
  which was processed.
  After the below call to restore_position() the cursor will point to
  the latter record, or, if it has been purged meanwhile, its closest
  non-purged predecessor (in extreme case this can be infimum of the first
  page in the tree!).
  By moving to the successor of the saved record we position the cursor
  either to supremum record (which means we restored original cursor
  position and can continue switch to the next page as usual) or to
  some user record which our scan have not processed yet (for example,
  this record might have been moved from the next page due to page
  merge or simply inserted to our page concurrently).
  The latter case is detected by caller by doing !is_after_last_on_page()
  check and instead of doing switch to the next page we continue processing
  from the restored user record. */

  m_pcur->restore_position(BTR_SEARCH_LEAF, m_mtr, UT_LOCATION_HERE);

  ut_ad(!m_pcur->is_after_last_on_page());

  if (m_supremum_saved) m_pcur->move_to_next_on_page();
}

void PCursor::yield_prev() {
  /* We should always yield on a block boundary. */
  ut_ad(m_pcur->is_before_first_on_page());

  /* Store the cursor position on the first user record on the page. */
  m_pcur->move_to_next_on_page();

  restore_position();

  m_mtr->commit();

  /* Yield so that another thread can proceed. */
  std::this_thread::yield();

  m_mtr->start();

  m_mtr->set_log_mode(MTR_LOG_NO_REDO);

  /* Restore position on the record, or its predecessor if the record
  was purged meanwhile. */

  m_pcur->restore_position(BTR_SEARCH_LEAF, m_mtr, UT_LOCATION_HERE);

  if (!m_pcur->is_before_first_on_page()) {
    /* Move to the successor of the saved record. */
    m_pcur->move_to_prev_on_page();
  }
}

dberr_t PCursor::move_to_next_block_user_rec() noexcept {
  auto cur = m_pcur->get_page_cur();
  const auto next_page_no = btr_page_get_next(page_cur_get_page(cur), m_mtr);

  if (next_page_no == FIL_NULL) {
    m_mtr->commit();
    return DB_END_OF_INDEX;
  }

  auto block = page_cur_get_block(cur);
  const auto &page_id = block->page.id;

  DEBUG_SYNC_C("parallel_reader_next_block");

  /* We never scan undo tablespaces. */
  ut_a(!fsp_is_undo_tablespace(page_id.space()));

  if (m_read_level == 0) {
    block = buf_page_get_gen(page_id_t(page_id.space(), next_page_no),
                             block->page.size, RW_S_LATCH, nullptr,
                             Page_fetch::SCAN, UT_LOCATION_HERE, m_mtr);
  } else {
    /* Read IO should be waited for. But s-latch should be nowait,
    to avoid deadlock opportunity completely. */
    block = buf_page_get_gen(page_id_t(page_id.space(), next_page_no),
                             block->page.size, RW_NO_LATCH, nullptr,
                             Page_fetch::SCAN, UT_LOCATION_HERE, m_mtr);
    bool success = buf_page_get_known_nowait(
        RW_S_LATCH, block, Cache_hint::KEEP_OLD, __FILE__, __LINE__, m_mtr);
    btr_leaf_page_release(block, RW_NO_LATCH, m_mtr);

    if (!success) {
      return DB_LOCK_NOWAIT;
    }
  }

  buf_block_dbg_add_level(block, SYNC_TREE_NODE);

  btr_leaf_page_release(page_cur_get_block(cur), RW_S_LATCH, m_mtr);

  page_cur_set_before_first(block, cur);

  /* Skip the infimum record. */
  page_cur_move_to_next(cur);

  /* Page can't be empty unless it is a root page. */
  ut_ad(!page_cur_is_after_last(cur));

  return DB_SUCCESS;
}

dberr_t PCursor::restore_from_savepoint() noexcept {
  resume();

  /* We should not get cursor pointing to supremum when restoring cursor
  which has pointed to user record from the Parallel_reader:::Ctx::m_f
  callback. Otherwise the below call to move_to_next_block_user_rec()
  will position the cursor to the first user record on the next page
  and then calling code will do page_cur_move_to_next() right after
  that. Which means that one record will be incorrectly skipped by
  our scan. Luckily, this always holds with current code. */
  ut_ad(m_supremum_saved || !m_pcur->is_after_last_on_page());

  /* Move to the next user record in the index tree if we are at supremum.
  Even though this looks awkward from the proper layering point of view,
  and ideally should have been done on the same code level as iteration
  over records, doing this here, actually, a) allows to avoid scenario in
  which savepoint/mini-transaction commit and latch release/restore happen
  for the same page twice - first time in page-end callback and then in
  move_to_next_block() call, b) handles a hypotetical situation when
  the index was reduced to the empty root page while latches were released
  by detecting it and bailing out early (it is important for us to bail out
  and not try to call savepoint() method in this case). */
  return (!m_pcur->is_after_last_on_page()) ? DB_SUCCESS
                                            : move_to_next_block_user_rec();
}

dberr_t Parallel_reader::Thread_ctx::restore_from_savepoint() noexcept {
  /* If read_level != 0, might return DB_LOCK_NOWAIT error. */
  ut_ad(m_pcursor->read_level() == 0);
  return m_pcursor->restore_from_savepoint();
}

void Parallel_reader::Thread_ctx::savepoint() noexcept {
  m_pcursor->savepoint();
}

dberr_t PCursor::move_to_next_block(dict_index_t *index) {
  ut_ad(m_pcur->is_after_last_on_page());
  dberr_t err = DB_SUCCESS;

  if (rw_lock_get_waiters(dict_index_get_lock(index))) {
    /* There are waiters on the index tree lock. Store and restore
    the cursor position, and yield so that scanning a large table
    will not starve other threads. */

    /* We should always yield on a block boundary. */
    ut_ad(m_pcur->is_after_last_on_page());

    savepoint();

    /* Yield so that another thread can proceed. */
    std::this_thread::yield();

    err = restore_from_savepoint();
  } else {
    err = move_to_next_block_user_rec();
  }

  int n_retries [[maybe_unused]] = 0;
  while (err == DB_LOCK_NOWAIT) {
    /* We should restore the cursor from index root page,
    to avoid deadlock opportunity. */
    ut_ad(m_read_level != 0);

    savepoint();

    /* Forces to restore from index root. */
    m_pcur->m_block_when_stored.clear();

    err = restore_from_savepoint();

    n_retries++;
    ut_ad(n_retries < 10);
  }

  return err;
}

dberr_t PCursor::move_to_prev_block(dict_index_t *index) {
  ut_ad(m_pcur->is_before_first_on_page());

  if (rw_lock_get_waiters(dict_index_get_lock(index))) {
    /* There are waiters on the index tree lock. Store and restore
    the cursor position, and yield so that scanning a large table
    will not starve other threads. */

    yield_prev();

    /* It's possible that the restore places the cursor in the middle of
    the block. We need to account for that too. */

    if (m_pcur->is_on_user_rec()) {
      return (DB_SUCCESS);
    }
  }

  auto cur = m_pcur->get_page_cur();

  auto prev_page_no = btr_page_get_prev(page_cur_get_page(cur), m_mtr);

  if (prev_page_no == FIL_NULL) {
    m_mtr->commit();

    return (DB_END_OF_INDEX);
  }

  m_pcur->move_backward_from_page(m_mtr);

  /* Skip the supremum record. */
  page_cur_move_to_prev(cur);

  /* Page can't be empty unless it is a root page. */
  ut_ad(!page_cur_is_before_first(cur));

  return (DB_SUCCESS);
}

bool Parallel_reader::Scan_ctx::check_visibility(
    const rec_t *&rec, ulint *&offsets, mem_heap_t *&heap, mtr_t *mtr, Ctx *ctx,
    rec_t *&out_clust_rec, ulint *&out_clust_offsets) {
  const auto table_name = m_config.m_index->table->name;

  ut_ad(!m_trx || m_trx->read_view == nullptr ||
        MVCC::is_view_active(m_trx->read_view));

  if (!m_trx) {
    /* Do nothing */
  } else if (m_trx->read_view != nullptr) {
    auto view = m_trx->read_view;

    if (m_config.m_index->is_clustered()) {
      trx_id_t rec_trx_id;

      if (m_config.m_index->trx_id_offset > 0) {
        rec_trx_id = trx_read_trx_id(rec + m_config.m_index->trx_id_offset);
      } else {
        rec_trx_id = row_get_rec_trx_id(rec, m_config.m_index, offsets);
      }

      if (m_trx->isolation_level > TRX_ISO_READ_UNCOMMITTED &&
          !view->changes_visible(rec_trx_id, table_name)) {
        rec_t *old_vers;

        row_vers_build_for_consistent_read(rec, mtr, m_config.m_index, &offsets,
                                           view, &heap, heap, &old_vers,
                                           nullptr, nullptr);

        rec = old_vers;

        if (rec == nullptr) {
          return (false);
        }
      }
    } else {
      if (m_config.is_greatdb_ap_read_sec_index()) {
        out_clust_rec = nullptr;
        out_clust_offsets = nullptr;

        trx_id_t max_trx_id = page_get_max_trx_id(page_align(rec));
        if (m_config.m_is_need_cluster_rec) {
          /** here, try to retrieve the cluster rec and judge the visibility */
          auto is_sec_visible =
              ctx->sec_index_visibilty_checker.get_cluster_rec(
                  m_trx, ctx, rec, offsets, out_clust_rec, out_clust_offsets);

          if (!is_sec_visible) {
            return false;
          }

        } else {
          /** this is just for data visibility */
          if (!view->sees(max_trx_id)) {
            mem_heap_t *vers_heap = ctx->m_thread_ctx->get_vers_heap();
            bool is_sec_visible =
                ctx->sec_index_visibilty_checker.judge_sec_visibility(
                    m_trx, ctx, rec, offsets, vers_heap);
            mem_heap_empty(vers_heap);

            /** sec_index_visibilty_checker maybe cache some information which
             * located in the heap; but the empty operation is not caused the
             * problem since we only use the value, not access the content.
             */
            if (!is_sec_visible) {
              return false;
            }
          }
        }

      } else {
        auto max_trx_id = page_get_max_trx_id(page_align(rec));

        ut_ad(max_trx_id > 0);

        if (!view->sees(max_trx_id)) {
          /* FIXME: This is not sufficient. We may need to read in the cluster
          index record to be 100% sure. */
          return (false);
        }
      }
    }
  }

  if (rec_get_deleted_flag(rec, m_config.m_is_compact)) {
    /* This record was deleted in the latest committed version, or it was
    deleted and then reinserted-by-update before purge kicked in. Skip it. */
    return (false);
  }

  ut_ad(!m_trx || m_trx->isolation_level == TRX_ISO_READ_UNCOMMITTED ||
        !rec_offs_any_null_extern(m_config.m_index, rec, offsets));

  return (true);
}

bool Parallel_reader::Scan_ctx::check_sec_visibility(const rec_t *rec,
                                                     ulint *sec_offsets,
                                                     mem_heap_t *vers_heap) {
  ut_a(vers_heap);
  bool is_sec_visible = true;
  trx_id_t page_max_trx_id = page_get_max_trx_id(page_align(rec));

  ut_a(page_max_trx_id);

  /** fast path to check */
  if (m_trx->read_view->sees(page_max_trx_id)) {
    return is_sec_visible;
  }

  srv_sec_rec_cluster_reads.fetch_add(1, std::memory_order_relaxed);

  mtr_t temp_mtr;
  btr_pcur_t *cluster_pcur = nullptr;
  ulint *cluster_offsets = nullptr;
  dtuple_t *cluster_ref = nullptr;
  ulint cluster_ref_len = 0;
  const rec_t *cluster_rec = nullptr;
  rec_t *old_vers = nullptr;
  dict_index_t *cluster_index = m_config.m_index->table->first_index();

  cluster_pcur =
      static_cast<btr_pcur_t *>(mem_heap_zalloc(vers_heap, sizeof(btr_pcur_t)));
  cluster_pcur->reset();
  temp_mtr.start();
  temp_mtr.set_log_mode(MTR_LOG_NO_REDO);

  cluster_ref_len = dict_index_get_n_unique(cluster_index);

  cluster_ref = dtuple_create(vers_heap, cluster_ref_len);

  dict_index_copy_types(cluster_ref, cluster_index, cluster_ref_len);

  row_build_row_ref_in_tuple(cluster_ref, rec, m_config.m_index, sec_offsets);

  cluster_pcur->open_no_init(cluster_index, cluster_ref, PAGE_CUR_LE,
                             BTR_SEARCH_LEAF, 0, &temp_mtr, UT_LOCATION_HERE);

  cluster_rec = cluster_pcur->get_rec();

  do {
    if (!page_rec_is_user_rec(cluster_rec) ||
        cluster_pcur->get_low_match() < cluster_ref_len) {
      /** can't find the cluster rec */
      is_sec_visible = false;
      break;
    }

    is_sec_visible = true;
    /** for record trx id */
    cluster_offsets =
        rec_get_offsets(cluster_rec, cluster_index, nullptr, ULINT_UNDEFINED,
                        UT_LOCATION_HERE, &vers_heap);

    if (m_trx && m_trx->isolation_level > TRX_ISO_READ_UNCOMMITTED &&
        !lock_clust_rec_cons_read_sees(cluster_rec, cluster_index,
                                       cluster_offsets,
                                       trx_get_read_view(m_trx))) {
      dberr_t err = row_vers_build_for_consistent_read(
          cluster_rec, &temp_mtr, cluster_index, &cluster_offsets,
          trx_get_read_view(m_trx), &vers_heap, vers_heap, &old_vers, nullptr,
          nullptr);

      if (DB_SUCCESS != err) {
        ut_ad(nullptr == old_vers);
        is_sec_visible = false;
        break;
      } else {
        ut_ad(nullptr != old_vers);
        is_sec_visible = true;
      }

    } else {
      is_sec_visible = true;
    }

  } while (false);

  cluster_pcur->reset();

  if (temp_mtr.is_active()) {
    temp_mtr.commit();
  }

  return is_sec_visible;
}

/** we don't cache the cluster record here */
bool Parallel_reader::Sec_index_visibilty_checker_t::get_cluster_rec(
    trx_t *trx, Parallel_reader::Ctx *ctx, const rec_t *sec_rec,
    ulint *sec_offsets, rec_t *&clust_rec, ulint *&clust_offset) {
  bool is_sec_visible = true;

  srv_sec_rec_cluster_reads.fetch_add(1, std::memory_order_relaxed);
  clust_rec = nullptr;
  clust_offset = nullptr;

  mtr_t temp_mtr;
  btr_pcur_t *cluster_pcur = nullptr;
  ulint *local_cluster_offsets = nullptr;
  dtuple_t *cluster_ref = nullptr;
  ulint cluster_ref_len = 0;
  const rec_t *local_cluster_rec = nullptr;
  rec_t *old_vers = nullptr;
  dict_index_t *cluster_index =
      ctx->m_scan_ctx->m_config.m_index->table->first_index();

  cluster_pcur = static_cast<btr_pcur_t *>(
      mem_heap_zalloc(m_tmp_mem_heap, sizeof(btr_pcur_t)));
  cluster_pcur->reset();
  temp_mtr.start();
  temp_mtr.set_log_mode(MTR_LOG_NO_REDO);

  cluster_ref_len = dict_index_get_n_unique(cluster_index);

  cluster_ref = dtuple_create(m_tmp_mem_heap, cluster_ref_len);

  dict_index_copy_types(cluster_ref, cluster_index, cluster_ref_len);

  row_build_row_ref_in_tuple(cluster_ref, sec_rec,
                             ctx->m_scan_ctx->m_config.m_index, sec_offsets);

  cluster_pcur->open_no_init(cluster_index, cluster_ref, PAGE_CUR_LE,
                             BTR_SEARCH_LEAF, 0, &temp_mtr, UT_LOCATION_HERE);

  local_cluster_rec = cluster_pcur->get_rec();

  do {
    if (!page_rec_is_user_rec(local_cluster_rec) ||
        cluster_pcur->get_low_match() < cluster_ref_len) {
      /** does not find the cluster rec */
      is_sec_visible = false;
      break;
    }

    is_sec_visible = true;
    /** for record trx id used by cons_read_sees.
     *  and use the tmp mem heap for offsets
     */
    local_cluster_offsets =
        rec_get_offsets(local_cluster_rec, cluster_index, nullptr,
                        ULINT_UNDEFINED, UT_LOCATION_HERE, &m_tmp_mem_heap);

    if (trx && trx->isolation_level > TRX_ISO_READ_UNCOMMITTED &&
        !lock_clust_rec_cons_read_sees(local_cluster_rec, cluster_index,
                                       local_cluster_offsets,
                                       trx_get_read_view(trx))) {
      page_t *page = nullptr;
      ulint cache_page_offset = 0;
      lsn_t page_lsn = 0;
      space_id_t space_id = 0;
      page_no_t page_no = 0;
      bool use_cache = false;

      cache_page_offset = page_offset(local_cluster_rec);

      page = page_align(local_cluster_rec);
      page_lsn = mach_read_from_8(page + FIL_PAGE_LSN);
      page_no = mach_read_from_4(page + FIL_PAGE_OFFSET);
      space_id = mach_read_from_4(page + FIL_PAGE_SPACE_ID);

      if ((cache_page_offset == m_cached_page_offset) &&
          (page_lsn == cached_lsn) && (page_no == cached_page_no) &&
          (space_id == cached_space_id)) {
        use_cache = true;
      }

      if (!use_cache) {
        /** cache has become invalid, make sure not used in next time  */
        cached_lsn = 0;
        mem_heap_empty(m_cache_mem_heap);

        dberr_t err = row_vers_build_for_consistent_read(
            local_cluster_rec, &temp_mtr, cluster_index, &local_cluster_offsets,
            trx_get_read_view(trx), &m_tmp_mem_heap, m_cache_mem_heap,
            &old_vers, nullptr, nullptr);

        if (DB_SUCCESS != err) {
          ut_ad(nullptr == old_vers);
          is_sec_visible = false;
          break;
        } else {
          /** cache assignment here */
          cached_clust_rec = local_cluster_rec;
          m_cached_page_offset = cache_page_offset;
          cached_old_vers = old_vers;
          cached_lsn = page_lsn;
          cached_page_no = page_no;
          cached_space_id = space_id;
          ut_ad(nullptr != old_vers);
          is_sec_visible = true;
          /** here we need keep the offset, since the old_vers already on the
           * correct heap */

          m_cache_offsets = static_cast<ulint *>(mem_heap_alloc(
              m_cache_mem_heap,
              rec_offs_get_n_alloc(local_cluster_offsets) * sizeof(ulint)));
          ut_memcpy(
              m_cache_offsets, local_cluster_offsets,
              rec_offs_get_n_alloc(local_cluster_offsets) * sizeof(ulint));

          /** ready, return now */
          clust_rec = old_vers;
          clust_offset = m_cache_offsets;

          break;
        }
      } else {
        /** output the cache vers and offsets */
        ut_a(0 != m_cache_offsets);
        is_sec_visible = true;
        clust_rec = cached_old_vers;
        clust_offset = m_cache_offsets;
      }
    } else {
      /** invalidate the cache: indicate no cache item here. */
      cached_lsn = 0;
      mem_heap_empty(m_cache_mem_heap);

      is_sec_visible = true;
      byte *buf = nullptr;
      buf = static_cast<byte *>(mem_heap_alloc(
          m_cache_mem_heap, rec_offs_size(local_cluster_offsets)));
      clust_rec = rec_copy(buf, local_cluster_rec, local_cluster_offsets);

      clust_offset = static_cast<ulint *>(mem_heap_alloc(
          m_cache_mem_heap,
          rec_offs_get_n_alloc(local_cluster_offsets) * sizeof(ulint)));

      ut_memcpy(clust_offset, local_cluster_offsets,
                rec_offs_get_n_alloc(local_cluster_offsets) * sizeof(ulint));
    }

  } while (false);

  cluster_pcur->reset();

  if (temp_mtr.is_active()) {
    temp_mtr.commit();
  }

  mem_heap_empty(m_tmp_mem_heap);

  return is_sec_visible;
}

bool Parallel_reader::Sec_index_visibilty_checker_t::judge_sec_visibility(
    trx_t *trx, Parallel_reader::Ctx *ctx, const rec_t *sec_rec,
    ulint *sec_offsets, mem_heap_t *vers_heap) {
  bool is_sec_visible = true;

  srv_sec_rec_cluster_reads.fetch_add(1, std::memory_order_relaxed);

  mtr_t temp_mtr;
  btr_pcur_t *cluster_pcur = nullptr;
  ulint *cluster_offsets = nullptr;
  dtuple_t *cluster_ref = nullptr;
  ulint cluster_ref_len = 0;
  const rec_t *cluster_rec = nullptr;
  rec_t *old_vers = nullptr;
  dict_index_t *cluster_index =
      ctx->m_scan_ctx->m_config.m_index->table->first_index();

  cluster_pcur =
      static_cast<btr_pcur_t *>(mem_heap_zalloc(vers_heap, sizeof(btr_pcur_t)));
  cluster_pcur->reset();
  temp_mtr.start();
  temp_mtr.set_log_mode(MTR_LOG_NO_REDO);

  cluster_ref_len = dict_index_get_n_unique(cluster_index);

  cluster_ref = dtuple_create(vers_heap, cluster_ref_len);

  dict_index_copy_types(cluster_ref, cluster_index, cluster_ref_len);

  row_build_row_ref_in_tuple(cluster_ref, sec_rec,
                             ctx->m_scan_ctx->m_config.m_index, sec_offsets);

  cluster_pcur->open_no_init(cluster_index, cluster_ref, PAGE_CUR_LE,
                             BTR_SEARCH_LEAF, 0, &temp_mtr, UT_LOCATION_HERE);

  cluster_rec = cluster_pcur->get_rec();

  do {
    if (!page_rec_is_user_rec(cluster_rec) ||
        cluster_pcur->get_low_match() < cluster_ref_len) {
      /** can't find the cluster rec */
      is_sec_visible = false;
      break;
    }

    is_sec_visible = true;
    /** for record trx id used by cons_read_sees */
    cluster_offsets =
        rec_get_offsets(cluster_rec, cluster_index, nullptr, ULINT_UNDEFINED,
                        UT_LOCATION_HERE, &vers_heap);

    if (trx && trx->isolation_level > TRX_ISO_READ_UNCOMMITTED &&
        !lock_clust_rec_cons_read_sees(cluster_rec, cluster_index,
                                       cluster_offsets,
                                       trx_get_read_view(trx))) {
      page_t *page = nullptr;
      ulint cache_page_offset = 0;
      lsn_t page_lsn = 0;
      space_id_t space_id = 0;
      page_no_t page_no = 0;
      bool use_cache = false;

      cache_page_offset = page_offset(cluster_rec);
      page = page_align(cluster_rec);
      page_lsn = mach_read_from_8(page + FIL_PAGE_LSN);
      page_no = mach_read_from_4(page + FIL_PAGE_OFFSET);
      space_id = mach_read_from_4(page + FIL_PAGE_SPACE_ID);

      if ((m_cached_page_offset == cache_page_offset) &&
          (page_lsn == cached_lsn) && (page_no == cached_page_no) &&
          (space_id == cached_space_id)) {
        use_cache = true;
      }

      if (!use_cache) {
        cached_lsn = 0;

        dberr_t err = row_vers_build_for_consistent_read(
            cluster_rec, &temp_mtr, cluster_index, &cluster_offsets,
            trx_get_read_view(trx), &vers_heap, vers_heap, &old_vers, nullptr,
            nullptr);

        if (DB_SUCCESS != err) {
          ut_ad(nullptr == old_vers);
          is_sec_visible = false;
          break;
        } else {
          cached_clust_rec = cluster_rec;
          m_cached_page_offset = cache_page_offset;
          cached_old_vers = old_vers;
          cached_lsn = page_lsn;
          cached_page_no = page_no;
          cached_space_id = space_id;
          ut_ad(nullptr != old_vers);
          is_sec_visible = true;
          break;
        }
      } else {
        ut_a(nullptr != cached_clust_rec);
        is_sec_visible = true;
      }
    }

  } while (false);

  cluster_pcur->reset();

  if (temp_mtr.is_active()) {
    temp_mtr.commit();
  }

  return is_sec_visible;
}

dberr_t Parallel_reader::Scan_ctx::find_visible_record(
    byte *buf, const rec_t *&rec, const rec_t *&clust_rec, ulint *&offsets,
    ulint *&clust_offsets, mem_heap_t *&heap, mtr_t *mtr,
    row_prebuilt_t *prebuilt) {
  const auto table_name = m_config.m_index->table->name;
  ut_ad(m_trx->read_view == nullptr || MVCC::is_view_active(m_trx->read_view));
  if (prebuilt != nullptr) {
    prebuilt->pq_requires_clust_rec = false;
  }
  if (m_trx->read_view != nullptr) {
    auto view = m_trx->read_view;

    if (m_config.m_index->is_clustered()) {
      trx_id_t rec_trx_id;

      if (m_config.m_index->trx_id_offset > 0) {
        rec_trx_id = trx_read_trx_id(rec + m_config.m_index->trx_id_offset);
      } else {
        rec_trx_id = row_get_rec_trx_id(rec, m_config.m_index, offsets);
      }

      if (m_trx->isolation_level > TRX_ISO_READ_UNCOMMITTED &&
          !view->changes_visible(rec_trx_id, table_name)) {
        rec_t *old_vers = nullptr;

        row_vers_build_for_consistent_read(rec, mtr, m_config.m_index, &offsets,
                                           view, &heap, heap, &old_vers,
                                           nullptr, nullptr);

        rec = old_vers;
        if (rec == nullptr) {
          return DB_NOT_FOUND;
        }
      }
    } else {
      /* Secondary index scan not supported yet. */
      auto max_trx_id = page_get_max_trx_id(page_align(rec));
      ut_ad(max_trx_id > 0);

      if (!view->sees(max_trx_id) ||
          (prebuilt && prebuilt->need_to_access_clustered)) {
        if (prebuilt) {
          if (prebuilt->idx_cond) {
            switch (row_search_idx_cond_check(buf, prebuilt, rec, offsets)) {
              case ICP_NO_MATCH:
                return DB_NOT_FOUND;
              case ICP_OUT_OF_RANGE:
                return DB_END_OF_RANGE;
              case ICP_MATCH:
                break;
            }
          }
          if (prebuilt->sel_graph == nullptr) row_prebuild_sel_graph(prebuilt);

          Row_sel_get_clust_rec_for_mysql row_sel_get_clust_rec_for_mysql;
          que_thr_t *thr = que_fork_get_first_thr(prebuilt->sel_graph);

          prebuilt->pq_requires_clust_rec = true;
          int err = row_sel_get_clust_rec_for_mysql(
              prebuilt, m_config.m_index, rec, thr, &clust_rec, &clust_offsets,
              &heap, NULL, mtr, nullptr);

          if (err != DB_SUCCESS)
            return DB_NOT_FOUND;
          else {
            if (clust_rec == NULL) {
              /* The record did not exist in the read view */
              ut_ad(prebuilt->select_lock_type == LOCK_NONE);

              return DB_NOT_FOUND;
            } else if (rec_get_deleted_flag(clust_rec, m_config.m_is_compact)) {
              /* The record is delete marked: we can skip it */
              return DB_NOT_FOUND;
            } else {
              return DB_SUCCESS;
            }
          }
        } else
          return DB_NOT_FOUND;
      }
    }
  } else if (srv_read_only_mode && /** innodb_read_only */
             (prebuilt &&
              prebuilt->need_to_access_clustered && /** secondary index and
                                                       non-covered index */
              !m_config.m_index->is_clustered())) {
    if (prebuilt->idx_cond) {
      switch (row_search_idx_cond_check(buf, prebuilt, rec, offsets)) {
        case ICP_NO_MATCH:
          return DB_NOT_FOUND;
        case ICP_OUT_OF_RANGE:
          return DB_END_OF_RANGE;
        case ICP_MATCH:
          break;
      }
    }

    if (prebuilt->sel_graph == nullptr) row_prebuild_sel_graph(prebuilt);

    que_thr_t *thr = que_fork_get_first_thr(prebuilt->sel_graph);
    prebuilt->pq_requires_clust_rec = true;
    Row_sel_get_clust_rec_for_mysql row_sel_get_clust_rec_for_mysql;
    int err = row_sel_get_clust_rec_for_mysql(prebuilt, m_config.m_index, rec,
                                              thr, &clust_rec, &clust_offsets,
                                              &heap, NULL, mtr, nullptr);

    if (err != DB_SUCCESS)
      return DB_NOT_FOUND;
    else {
      if (clust_rec == NULL) {
        /* The record did not exist in the read view */
        ut_ad(prebuilt->select_lock_type == LOCK_NONE);

        return DB_NOT_FOUND;
      } else if (rec_get_deleted_flag(clust_rec, m_config.m_is_compact)) {
        /* The record is delete marked: we can skip it */
        return DB_NOT_FOUND;
      } else {
        return DB_SUCCESS;
      }
    }
  }

  if (rec_get_deleted_flag(rec, m_config.m_is_compact)) {
    /* This record was deleted in the latest committed version, or it was
    deleted and then reinserted-by-update before purge kicked in. Skip it. */
    return DB_NOT_FOUND;
  }

  return DB_SUCCESS;
}

void Parallel_reader::Scan_ctx::copy_row(const rec_t *rec, Iter *iter) const {
  iter->m_offsets =
      rec_get_offsets(rec, m_config.m_index, nullptr, ULINT_UNDEFINED,
                      UT_LOCATION_HERE, &iter->m_heap);

  /* Copy the row from the page to the scan iterator. The copy should use
  memory from the iterator heap because the scan iterator owns the copy. */
  auto rec_len = rec_offs_size(iter->m_offsets);

  auto copy_rec = static_cast<rec_t *>(mem_heap_alloc(iter->m_heap, rec_len));

  memcpy(copy_rec, rec, rec_len);

  iter->m_rec = copy_rec;

  auto tuple = row_rec_to_index_entry_low(iter->m_rec, m_config.m_index,
                                          iter->m_offsets, iter->m_heap);

  ut_ad(dtuple_validate(tuple));

  /* We have copied the entire record but we only need to compare the
  key columns when we check for boundary conditions. */
  const auto n_compare = dict_index_get_n_unique_in_tree(m_config.m_index);

  dtuple_set_n_fields_cmp(tuple, n_compare);

  iter->m_tuple = tuple;
}

std::shared_ptr<Parallel_reader::Scan_ctx::Iter>
Parallel_reader::Scan_ctx::create_persistent_cursor(
    const page_cur_t &page_cursor, mtr_t *mtr) const {
  ut_ad(index_s_own());

  std::shared_ptr<Iter> iter = std::make_shared<Iter>();

  iter->m_heap = mem_heap_create(sizeof(btr_pcur_t) + (srv_page_size / 16),
                                 UT_LOCATION_HERE);

  auto rec = page_cursor.rec;

  const bool is_infimum = page_rec_is_infimum(rec);

  if (is_infimum) {
    rec = page_rec_get_next(rec);
  }

  if (page_rec_is_supremum(rec)) {
    /* Empty page, only root page can be empty. */
    ut_a(!is_infimum ||
         page_cursor.block->page.id.page_no() == m_config.m_index->page);
    return (iter);
  }

  void *ptr = mem_heap_alloc(iter->m_heap, sizeof(btr_pcur_t));

  ::new (ptr) btr_pcur_t();

  iter->m_pcur = reinterpret_cast<btr_pcur_t *>(ptr);

  iter->m_pcur->init(m_config.m_read_level);

  /* Make a copy of the rec. */
  copy_row(rec, iter.get());

  iter->m_pcur->open_on_user_rec(page_cursor, PAGE_CUR_GE,
                                 BTR_ALREADY_S_LATCHED | BTR_SEARCH_LEAF);

  ut_ad(btr_page_get_level(buf_block_get_frame(iter->m_pcur->get_block())) ==
        m_config.m_read_level);

  iter->m_pcur->store_position(mtr);
  iter->m_pcur->set_fetch_type(Page_fetch::SCAN);

  return (iter);
}

bool Parallel_reader::Ctx::move_to_next_node(PCursor *pcursor) {
  IF_DEBUG(auto cur = m_range.first->m_pcur->get_page_cur();)

  auto err = pcursor->move_to_next_block(const_cast<dict_index_t *>(index()));

  if (err != DB_SUCCESS) {
    ut_a(err == DB_END_OF_INDEX);
    return false;
  } else {
    /* Page can't be empty unless it is a root page. */
    ut_ad(!page_cur_is_after_last(cur));
    ut_ad(!page_cur_is_before_first(cur));
    return true;
  }
}

dberr_t Parallel_reader::Ctx::read_record(uchar *buf,
                                          row_prebuilt_t *prebuilt) {
  mtr_t mtr;
  btr_pcur_t *pcur;

  dberr_t err{DB_SUCCESS};
  dberr_t err1{DB_SUCCESS};
  int ret{0};
  const rec_t *clust_rec = nullptr;
  const rec_t *rec = nullptr;
  const rec_t *result_rec = nullptr;
  ulint *offsets = offsets_;
  ulint *clust_offsets = clust_offsets_;

  if (start_read) {
    rec_offs_init(offsets_);
    rec_offs_init(clust_offsets_);
    start_read = false;
  }

  mtr.start();
  mtr.set_log_mode(MTR_LOG_NO_REDO);

  auto &from =
      m_scan_ctx->m_config.m_pq_reverse_scan ? m_range.second : m_range.first;
  pcur = from->m_pcur;

  PCursor pcursor(pcur, &mtr, m_scan_ctx->m_config.m_read_level);
  pcursor.restore_position();

  const auto &end_tuple = m_scan_ctx->m_config.m_pq_reverse_scan
                              ? m_range.first->m_tuple
                              : m_range.second->m_tuple;
  auto index = m_scan_ctx->m_config.m_index;
  auto cur = pcur->get_page_cur();
  dict_index_t *clust_index = index->table->first_index();

  if (m_blob_heap == nullptr)
    m_blob_heap = mem_heap_create(srv_page_size, UT_LOCATION_HERE);
  if (m_heap == nullptr)
    m_heap = mem_heap_create(srv_page_size / 4, UT_LOCATION_HERE);

  if (!m_scan_ctx->m_config.m_pq_reverse_scan && page_cur_is_after_last(cur)) {
    // pcur point to last record, move to next block
    mem_heap_empty(m_heap);
    offsets = offsets_;
    rec_offs_init(offsets_);

    err = pcursor.move_to_next_block(index);
    if (err != DB_SUCCESS) {
      ut_a(!mtr.is_active());
      return err;
    }
    ut_ad(!page_cur_is_before_first(cur));
  } else if (m_scan_ctx->m_config.m_pq_reverse_scan &&
             page_cur_is_before_first(cur)) {
    // pcur point to first record, move to prev block
    mem_heap_empty(m_heap);
    offsets = offsets_;
    rec_offs_init(offsets_);

    err = pcursor.move_to_prev_block(index);
    if (err != DB_SUCCESS) {
      ut_a(!mtr.is_active());
      return err;
    }
    ut_ad(!page_cur_is_after_last(cur));
  }

  // 1. read record
  rec = page_cur_get_rec(cur);
  offsets = rec_get_offsets(rec, index, offsets, ULINT_UNDEFINED,
                            UT_LOCATION_HERE, &m_heap);
  clust_offsets = rec_get_offsets(rec, index, clust_offsets, ULINT_UNDEFINED,
                                  UT_LOCATION_HERE, &m_heap);

  // 2. find visible version record
  err1 = m_scan_ctx->find_visible_record(buf, rec, clust_rec, offsets,
                                         clust_offsets, m_heap, &mtr, prebuilt);

  if (err1 == DB_END_OF_RANGE) {
    err = DB_END_OF_RANGE;
    goto func_exit;
  }

  if (err1 != DB_NOT_FOUND) {
    // 3. check range boundary
    m_block = page_cur_get_block(cur);
    if (rec != nullptr && end_tuple != nullptr) {
      if (!m_scan_ctx->m_config.m_index->is_clustered() &&
          prebuilt->need_to_access_clustered)
        ret = ((dtuple_t *)end_tuple)
                  ->compare(clust_rec, index, clust_index, clust_offsets);
      else
        ret = end_tuple->compare(rec, index, offsets);

      /* Note: The range creation doesn't use MVCC. Therefore it's possible
      that the range boundary entry could have been deleted. */
      if ((!m_scan_ctx->m_config.m_pq_reverse_scan && ret <= 0) ||
          (m_scan_ctx->m_config.m_pq_reverse_scan && ret >= 0)) {
        m_scan_ctx->m_reader->ctx_completed_inc();
        err = DB_END_OF_RANGE;
        goto func_exit;
      }
    }

    // 4. convert record to mysql format
    if (prebuilt->pq_requires_clust_rec) {
      result_rec = clust_rec;
      if (!row_sel_store_mysql_rec(buf, prebuilt, clust_rec, nullptr, true,
                                   clust_index, prebuilt->index, clust_offsets,
                                   false, nullptr, m_blob_heap))
        err = DB_ERROR;
    } else {
      result_rec = rec;
      if (!row_sel_store_mysql_rec(buf, prebuilt, rec, nullptr,
                                   m_scan_ctx->m_config.m_index->is_clustered(),
                                   index, prebuilt->index, offsets, false,
                                   nullptr, m_blob_heap))
        err = DB_ERROR;
    }
    if (prebuilt->clust_index_was_generated) {
      pq_row_sel_store_row_id_to_prebuilt(
          prebuilt, result_rec, result_rec == rec ? index : clust_index,
          result_rec == rec ? offsets : clust_offsets);
    }
  } else {
    err = DB_NOT_FOUND;
    goto next_record;
  }

next_record:
  if (!m_scan_ctx->m_config.m_pq_reverse_scan)
    page_cur_move_to_next(cur);
  else
    page_cur_move_to_prev(cur);

func_exit:
  pcur->store_position(&mtr);
  ut_a(mtr.is_active());
  mtr.commit();

  return err;
}

dberr_t Parallel_reader::Ctx::traverse() {
  /* Take index lock if the requested read level is on a non-leaf level as the
  index lock is required to access non-leaf page.  */
  if (m_scan_ctx->m_config.m_read_level != 0) {
    m_scan_ctx->index_s_lock();
  }

  mtr_t mtr;
  mtr.start();
  mtr.set_log_mode(MTR_LOG_NO_REDO);

  auto &from = m_range.first;

  PCursor pcursor(from->m_pcur, &mtr, m_scan_ctx->m_config.m_read_level);
  pcursor.restore_position_for_range();

  dberr_t err{DB_SUCCESS};

  m_thread_ctx->m_pcursor = &pcursor;

  err = traverse_recs(&pcursor, &mtr);

  if (mtr.is_active()) {
    mtr.commit();
  }

  m_thread_ctx->m_pcursor = nullptr;

  if (m_scan_ctx->m_config.m_read_level != 0) {
    m_scan_ctx->index_s_unlock();
  }

  return (err);
}

dberr_t Parallel_reader::Ctx::traverse_recs(PCursor *pcursor, mtr_t *mtr) {
  bool need_check_start = false;
  const auto &end_tuple = m_range.second->m_tuple;
  auto heap = mem_heap_create(srv_page_size / 4, UT_LOCATION_HERE);
  auto index = m_scan_ctx->m_config.m_index;

  m_start = true;

  dberr_t err{DB_SUCCESS};

  if (m_scan_ctx->m_reader->m_start_callback) {
    /* Page start. */
    m_thread_ctx->m_state = State::PAGE;
    err = m_scan_ctx->m_reader->m_start_callback(m_thread_ctx);
  }

  bool call_end_page{true};
  auto cur = pcursor->get_page_cursor();

  if (m_range.first->m_iter_for_greatdb_range &&
      m_range.first->m_is_first_range) {
    need_check_start = true;
  }

  while (err == DB_SUCCESS) {
    if (page_cur_is_after_last(cur)) {
      call_end_page = false;

      if (m_scan_ctx->m_reader->m_finish_callback) {
        /* End of page. */
        m_thread_ctx->m_state = State::PAGE;
        err = m_scan_ctx->m_reader->m_finish_callback(m_thread_ctx);
        if (err != DB_SUCCESS) {
          break;
        }
      }

      mem_heap_empty(heap);

      if (!(m_n_pages % TRX_IS_INTERRUPTED_PROBE) &&
          trx_is_interrupted(trx())) {
        err = DB_INTERRUPTED;
        break;
      }

      if (is_error_set()) {
        break;
      }

      /* Note: The page end callback (above) can save and restore the cursor.
      The restore can end up in the middle of a page. */
      if (pcursor->is_after_last_on_page() && !move_to_next_node(pcursor)) {
        break;
      }

      ++m_n_pages;
      m_first_rec = true;

      call_end_page = true;

      if (m_scan_ctx->m_reader->m_start_callback) {
        /* Page start. */
        m_thread_ctx->m_state = State::PAGE;
        err = m_scan_ctx->m_reader->m_start_callback(m_thread_ctx);
        if (err != DB_SUCCESS) {
          break;
        }
      }
    }

    ulint offsets_[REC_OFFS_NORMAL_SIZE];
    ulint *offsets = offsets_;

    rec_offs_init(offsets_);

    const rec_t *rec = page_cur_get_rec(cur);
    offsets = rec_get_offsets(rec, index, offsets, ULINT_UNDEFINED,
                              UT_LOCATION_HERE, &heap);

    if (m_range.first->m_iter_for_greatdb_range &&
        m_range.first->m_is_first_range &&
        m_scan_ctx->m_config.m_scan_range.m_start && need_check_start) {
      // m_scan_ctx->m_config.m_scan_range.m_range_start_flag
      int ret = m_scan_ctx->m_config.m_scan_range.m_start->compare(rec, index,
                                                                   offsets);
      if (ret > 0) {
        page_cur_move_to_next(cur);
        continue;
      } else if (0 == ret) {
        if (ha_rkey_function::HA_READ_AFTER_KEY ==
            m_scan_ctx->m_config.m_scan_range.m_range_start_flag) {
          page_cur_move_to_next(cur);
          need_check_start = false;
          continue;
        } else {
          need_check_start = false;
        }
      } else {
        need_check_start = false;
      }
    }

    if (end_tuple != nullptr) {
      ut_ad(rec != nullptr);

      /* Key value of a record can change only if the record is deleted or if
      it's updated. An update is essentially a delete + insert. So in both
      the cases we just delete mark the record and the original key value is
      preserved on the page.

      Since the range creation is based on the key values and the key value do
      not ever change the, latest (non-MVCC) version of the record should always
      tell us correctly whether we're within the range or outside of it. */
      auto ret = end_tuple->compare(rec, index, offsets);

      /* Note: The range creation doesn't use MVCC. Therefore it's possible
      that the range boundary entry could have been deleted. */
      if (ret <= 0) {
        if (!m_range.second->m_is_last_range) {
          break;
        } else {
          if (0 == ret) {
            if (m_scan_ctx->m_config.m_scan_range.m_range_end_flag ==
                HA_READ_BEFORE_KEY) {
              break;
            }
          } else {
            break;
          }
        }
      }
    }

    bool skip{};
    rec_t *clust_rec{nullptr};
    ulint *clust_rec_offsets{nullptr};
    if (page_is_leaf(cur->block->frame)) {
      skip = !m_scan_ctx->check_visibility(rec, offsets, heap, mtr, this,
                                           clust_rec, clust_rec_offsets);
    }

    if (!skip) {
      if (sec_need_clust_rec()) {
        m_rec = clust_rec;
        m_offsets = clust_rec_offsets;
      } else {
        m_rec = rec;
        m_offsets = offsets;
      }
      /** this is the block of current traversing index */
      m_block = cur->block;

      err = m_scan_ctx->m_f(this);

      if (err != DB_SUCCESS) {
        break;
      }

      m_start = false;
    }

    m_first_rec = false;

    page_cur_move_to_next(cur);
  }

  if (err != DB_SUCCESS) {
    m_scan_ctx->set_error_state(err);
  }

  mem_heap_free(heap);

  if (call_end_page && m_scan_ctx->m_reader->m_finish_callback) {
    /* Page finished. */
    m_thread_ctx->m_state = State::PAGE;
    auto cb_err = m_scan_ctx->m_reader->m_finish_callback(m_thread_ctx);

    if (cb_err != DB_SUCCESS && !m_scan_ctx->is_error_set()) {
      err = cb_err;
    }
  }

  return (err);
}

dberr_t Parallel_reader::Ctx::traverse_desc() {
  dberr_t err{DB_SUCCESS};
  /* Take index lock if the requested read level is on a non-leaf level as the
  index lock is required to access non-leaf page.  */
  if (m_scan_ctx->m_config.m_read_level != 0) {
    m_scan_ctx->index_s_lock();
  }

  mtr_t mtr;
  mtr.start();
  mtr.set_log_mode(MTR_LOG_NO_REDO);

  auto &from = m_range.first;

  PCursor pcursor(from->m_pcur, &mtr, m_scan_ctx->m_config.m_read_level);

  pcursor.move_to_up_block(m_scan_ctx->m_config.m_index,
                           m_range.second->m_tuple);

  rec_t *first_rec = pcursor.set_cur_page_first();
  if (nullptr == first_rec) {
    err = pcursor.move_to_left_block(index());
    if (DB_SUCCESS != err) {
      goto END;
    }
  }

  m_thread_ctx->m_pcursor = &pcursor;

  err = traverse_recs_desc(&pcursor, &mtr, first_rec);
END:
  if (mtr.is_active()) {
    mtr.commit();
  }

  m_thread_ctx->m_pcursor = nullptr;

  if (m_scan_ctx->m_config.m_read_level != 0) {
    m_scan_ctx->index_s_unlock();
  }

  return (err);
}

dberr_t Parallel_reader::Ctx::traverse_recs_desc(PCursor *pcursor, mtr_t *mtr,
                                                 rec_t *end_rec) {
  std::vector<std::tuple<rec_t *, ulint *>> m_page_recs;
  const dtuple_t *start_tuple = m_range.first->m_tuple;
  auto heap = mem_heap_create(srv_page_size, UT_LOCATION_HERE);
  auto index = this->index();
  dberr_t err{DB_SUCCESS};

  bool is_reach_end = false;
  bool move_switch_page = false;

  bool is_reach_start = false;

  m_start = true;

  if (nullptr == end_rec) {
    is_reach_end = true;
  }

  if (m_scan_ctx->m_reader->m_start_callback) {
    /* Page start. */
    m_thread_ctx->m_state = State::PAGE;
    err = m_scan_ctx->m_reader->m_start_callback(m_thread_ctx);
  }

  bool call_end_page{true};
  auto cur = pcursor->get_page_cursor();

  m_page_recs.reserve(1024);

  while (err == DB_SUCCESS) {
    if (page_cur_is_after_last(cur) || move_switch_page) {
      move_switch_page = false;
      call_end_page = false;

      if (m_scan_ctx->m_reader->m_finish_callback) {
        /* End of page. */
        m_thread_ctx->m_state = State::PAGE;
        err = m_scan_ctx->m_reader->m_finish_callback(m_thread_ctx);
        if (err != DB_SUCCESS) {
          break;
        }
      }

      if (!m_page_recs.empty()) {
        /** need callback to handle the data */

        m_block = cur->block;

        for (auto it = m_page_recs.rbegin(); it != m_page_recs.rend(); ++it) {
          m_rec = std::get<0>(*it);
          m_offsets = std::get<1>(*it);
          err = m_scan_ctx->m_f(this);
          if (DB_SUCCESS != err) {
            break;
          }
        }
        m_page_recs.clear();
        if (DB_SUCCESS != err) {
          break;
        }
      }

      /** this is the last page to handle.*/
      if (is_reach_start) {
        break;
      }

      mem_heap_empty(heap);

      if (!(m_n_pages % TRX_IS_INTERRUPTED_PROBE) &&
          trx_is_interrupted(trx())) {
        err = DB_INTERRUPTED;
        break;
      }

      if (is_error_set()) {
        break;
      }

      if (DB_SUCCESS != pcursor->move_to_left_block(index)) {
        break;
      }

      ++m_n_pages;
      m_first_rec = true;

      call_end_page = true;

      if (m_scan_ctx->m_reader->m_start_callback) {
        /* Page start. */
        m_thread_ctx->m_state = State::PAGE;
        err = m_scan_ctx->m_reader->m_start_callback(m_thread_ctx);
        if (err != DB_SUCCESS) {
          break;
        }
      }
    }

    ulint *offsets = nullptr;

    const rec_t *rec = page_cur_get_rec(cur);
    offsets = rec_get_offsets(rec, index, nullptr, ULINT_UNDEFINED,
                              UT_LOCATION_HERE, &heap);
    /** now, the offsets in the heap */

    if (!is_reach_end && (rec == end_rec)) {
      is_reach_end = true;
      move_switch_page = true;
    }

    if (start_tuple != nullptr) {
      ut_ad(rec != nullptr);

      /* Key value of a record can change only if the record is deleted or if
      it's updated. An update is essentially a delete + insert. So in both
      the cases we just delete mark the record and the original key value is
      preserved on the page.

      Since the range creation is based on the key values and the key value do
      not ever change the, latest (non-MVCC) version of the record should always
      tell us correctly whether we're within the range or outside of it. */
      auto ret = start_tuple->compare(rec, index, offsets);

      /* Note: The range creation doesn't use MVCC. Therefore it's possible
      that the range boundary entry could have been deleted. */
      if (ret > 0) {
        is_reach_start = true;
        page_cur_move_to_next(cur);
        continue;
      }
    }

    bool skip{};
    rec_t *clust_rec{nullptr};
    ulint *clust_rec_offsets{nullptr};
    if (page_is_leaf(cur->block->frame)) {
      skip = !m_scan_ctx->check_visibility(rec, offsets, heap, mtr, this,
                                           clust_rec, clust_rec_offsets);
    }

    if (!skip) {
      if (sec_need_clust_rec()) {
        [[maybe_unused]] rec_t *cache_rec = nullptr;
        [[maybe_unused]] ulint *cache_offsets = nullptr;
        byte *buf = nullptr;
        buf = static_cast<byte *>(
            mem_heap_alloc(heap, rec_offs_size(clust_rec_offsets)));
        cache_rec = rec_copy(buf, clust_rec, clust_rec_offsets);

        cache_offsets = static_cast<ulint *>(mem_heap_alloc(
            heap, rec_offs_get_n_alloc(clust_rec_offsets) * sizeof(ulint)));

        ut_memcpy(cache_offsets, clust_rec_offsets,
                  rec_offs_get_n_alloc(clust_rec_offsets) * sizeof(ulint));

        m_page_recs.emplace_back(std::make_tuple(cache_rec, cache_offsets));

      } else {
        m_page_recs.emplace_back(
            std::make_tuple(const_cast<rec_t *>(rec), offsets));
      }

      m_start = false;
    }

    m_first_rec = false;

    page_cur_move_to_next(cur);
  }

  if (err != DB_SUCCESS) {
    m_scan_ctx->set_error_state(err);
  }

  mem_heap_free(heap);

  if (call_end_page && m_scan_ctx->m_reader->m_finish_callback) {
    /* Page finished. */
    m_thread_ctx->m_state = State::PAGE;
    auto cb_err = m_scan_ctx->m_reader->m_finish_callback(m_thread_ctx);

    if (cb_err != DB_SUCCESS && !m_scan_ctx->is_error_set()) {
      err = cb_err;
    }
  }

  return (err);
}

void Parallel_reader::enqueue(std::shared_ptr<Ctx> ctx) {
  mutex_enter(&m_mutex);
  m_ctxs.push_back(ctx);
  mutex_exit(&m_mutex);
}

std::shared_ptr<Parallel_reader::Ctx> Parallel_reader::dequeue() {
  mutex_enter(&m_mutex);

  if (m_ctxs.empty()) {
    mutex_exit(&m_mutex);
    return (nullptr);
  }

  std::shared_ptr<Parallel_reader::Ctx> ctx{};
  if (!(m_pq_reverse_scan | m_greatdb_ap_reverse_fetch)) {
    ctx = m_ctxs.front();
    m_ctxs.pop_front();
  } else {
    ctx = m_ctxs.back();
    m_ctxs.pop_back();
  }

  mutex_exit(&m_mutex);

  return (ctx);
}

void Parallel_reader::pq_set_reverse_scan() { m_pq_reverse_scan = true; }

bool Parallel_reader::is_queue_empty() const {
  mutex_enter(&m_mutex);
  auto empty = m_ctxs.empty();
  mutex_exit(&m_mutex);
  return (empty);
}

void Parallel_reader::worker(Parallel_reader::Thread_ctx *thread_ctx) {
  dberr_t err{DB_SUCCESS};
  dberr_t cb_err{DB_SUCCESS};

  if (m_start_callback) {
    /* Thread start. */
    thread_ctx->m_state = State::THREAD;
    cb_err = m_start_callback(thread_ctx);

    if (cb_err != DB_SUCCESS) {
      err = cb_err;
      set_error_state(cb_err);
    }
  }

  /* Wait for all the threads to be spawned as it's possible that we could
  abort the operation if there are not enough resources to spawn all the
  threads. */
  if (!m_sync) {
    os_event_wait_time_low(m_event, std::chrono::microseconds::max(),
                           m_sig_count);
  }

  for (;;) {
    size_t n_completed{};
    int64_t sig_count = os_event_reset(m_event);

    while (err == DB_SUCCESS && cb_err == DB_SUCCESS && !is_error_set()) {
      auto ctx = dequeue();

      if (ctx == nullptr) {
        break;
      }

      thread_ctx->m_ctx = ctx;

      auto scan_ctx = ctx->m_scan_ctx;

      if (scan_ctx->is_error_set()) {
        break;
      }

      ctx->m_thread_ctx = thread_ctx;

      if (ctx->m_split) {
        err = ctx->split();
        /* Tell the other threads that there is work to do. */
        os_event_set(m_event);
      } else {
        if (m_start_callback) {
          /* Context start. */
          thread_ctx->m_state = State::CTX;
          cb_err = m_start_callback(thread_ctx);
        }

        if (cb_err == DB_SUCCESS && err == DB_SUCCESS) {
          if (!m_greatdb_ap_reverse_fetch) {
            ut_ad(!!ctx->is_greatdb_ap_desc() == ctx->is_greatdb_ap_desc());
            err = ctx->traverse();
          } else {
            /** support the desc support for parallel read */
            err = ctx->traverse_desc();
          }
        }

        if (m_finish_callback) {
          /* Context finished. */
          thread_ctx->m_state = State::CTX;
          cb_err = m_finish_callback(thread_ctx);
        }
      }

      /* Check for trx interrupted (useful in the case of small tables). */
      if (err == DB_SUCCESS && trx_is_interrupted(ctx->trx())) {
        err = DB_INTERRUPTED;
        scan_ctx->set_error_state(err);
        break;
      }

      ut_ad(err == DB_SUCCESS || scan_ctx->is_error_set());

      ++n_completed;
    }

    if (cb_err != DB_SUCCESS || err != DB_SUCCESS || is_error_set()) {
      break;
    }

    m_n_completed.fetch_add(n_completed, std::memory_order_relaxed);

    if (m_n_completed == m_ctx_id) {
      /* Wakeup other worker threads before exiting */
      os_event_set(m_event);
      break;
    }

    if (!m_sync) {
      os_event_wait_time_low(m_event, std::chrono::microseconds::max(),
                             sig_count);
    }
  }

  if (err != DB_SUCCESS && !is_error_set()) {
    /* Set the "global" error state. */
    set_error_state(err);
  }

  if (is_error_set()) {
    /* Wake up any sleeping threads. */
    os_event_set(m_event);
  }

  if (m_finish_callback) {
    /* Thread finished. */
    thread_ctx->m_state = State::THREAD;
    cb_err = m_finish_callback(thread_ctx);

    /* Keep the err status from previous failed operations */
    if (cb_err != DB_SUCCESS) {
      err = cb_err;
      set_error_state(cb_err);
    }
  }

  m_n_threads_exited.fetch_add(1, std::memory_order_relaxed);
  ut_a(is_error_set() || (m_n_completed == m_ctx_id && is_queue_empty()));
}

void Parallel_reader::ctx_completed_inc() {
  m_n_completed.fetch_add(1, std::memory_order_relaxed);
}

void Parallel_reader::pq_set_worker_done() {
  work_done.store(true, std::memory_order_relaxed);
}

void Parallel_reader::pq_wakeup_workers() {
  pq_set_worker_done();
  os_event_set(m_event);
}

dberr_t Parallel_reader::dispatch_ctx(row_prebuilt_t *prebuilt) {
  dberr_t err{DB_SUCCESS};

  for (;;) {
    // int64_t sig_count = os_event_reset(m_event);
    os_event_reset(m_event);

    auto ctx = dequeue();
    bool done = work_done.load(std::memory_order_relaxed);

    if (ctx == nullptr) {
      prebuilt->ctx = nullptr;
      if (is_ctx_over() || done) {
        /* Wakeup other worker threads before exiting */
        os_event_set(m_event);
        ut_a(is_queue_empty());
        return DB_END_OF_INDEX;
      } else {
        /* wait for other worker */
        // constexpr auto FOREVER = std::chrono::microseconds::max();
        // os_event_wait_time_low(m_event, FOREVER, sig_count);
        os_event_set(m_event);
        return DB_END_OF_INDEX;
      }
    } else {
      if (ctx->m_split) {
        err = ctx->split();
        /* Tell the other threads that there is work to do. */
        os_event_set(m_event);
        ctx_completed_inc();
      } else {
        prebuilt->ctx = ctx;
        break;
      }
    }
  }

  return err;
}

page_no_t Parallel_reader::Scan_ctx::search(const buf_block_t *block,
                                            const dtuple_t *key) const {
  ut_ad(index_s_own());

  page_cur_t page_cursor;
  const auto index = m_config.m_index;

  if (key != nullptr) {
    page_cur_search(block, index, key, PAGE_CUR_LE, &page_cursor);
  } else {
    page_cur_set_before_first(block, &page_cursor);
  }

  if (page_rec_is_infimum(page_cur_get_rec(&page_cursor))) {
    page_cur_move_to_next(&page_cursor);
  }

  const auto rec = page_cur_get_rec(&page_cursor);

  mem_heap_t *heap = nullptr;

  ulint offsets_[REC_OFFS_NORMAL_SIZE];
  auto offsets = offsets_;

  rec_offs_init(offsets_);

  offsets = rec_get_offsets(rec, index, offsets, ULINT_UNDEFINED,
                            UT_LOCATION_HERE, &heap);

  auto page_no = btr_node_ptr_get_child_page_no(rec, offsets);

  if (heap != nullptr) {
    mem_heap_free(heap);
  }

  return (page_no);
}

page_cur_t Parallel_reader::Scan_ctx::start_range(
    page_no_t page_no, mtr_t *mtr, const dtuple_t *key,
    Savepoints &savepoints) const {
  ut_ad(index_s_own());

  auto index = m_config.m_index;
  page_id_t page_id(index->space, page_no);
  ulint height{};

  /* Follow the left most pointer down on each page. */
  for (;;) {
    auto savepoint = mtr->get_savepoint();

    auto block = block_get_s_latched(page_id, mtr, __LINE__);

    height = btr_page_get_level(buf_block_get_frame(block));

    savepoints.push_back({savepoint, block});

    if (height != 0 && height != m_config.m_read_level) {
      page_id.set_page_no(search(block, key));
      continue;
    }

    page_cur_t page_cursor;

    if (key != nullptr) {
      page_cur_search(block, index, key, PAGE_CUR_GE, &page_cursor);
    } else {
      page_cur_set_before_first(block, &page_cursor);
    }

    if (page_rec_is_infimum(page_cur_get_rec(&page_cursor))) {
      page_cur_move_to_next(&page_cursor);
    }

    return (page_cursor);
  }
}

void Parallel_reader::Scan_ctx::create_range(Ranges &ranges,
                                             page_cur_t &leaf_page_cursor,
                                             mtr_t *mtr) const {
  leaf_page_cursor.index = m_config.m_index;

  auto iter = create_persistent_cursor(leaf_page_cursor, mtr);

  /* Setup the previous range (next) to point to the current range. */
  if (!ranges.empty()) {
    ut_a(ranges.back().second->m_heap == nullptr);
    ranges.back().second = iter;
  }

  ranges.push_back(Range(iter, std::make_shared<Iter>()));
}

dberr_t Parallel_reader::Scan_ctx::create_ranges(const Scan_range &scan_range,
                                                 page_no_t page_no,
                                                 size_t depth,
                                                 const size_t split_level,
                                                 Ranges &ranges, mtr_t *mtr) {
  ut_ad(index_s_own());
  ut_a(page_no != FIL_NULL);
  if (m_config.m_range_errno) return (DB_SUCCESS);

  /* Do a breadth first traversal of the B+Tree using recursion. We want to
  set up the scan ranges in one pass. This guarantees that the tree structure
  cannot change while we are creating the scan sub-ranges.

  Once we create the persistent cursor (Range) for a sub-tree we can release
  the latches on all blocks traversed for that sub-tree. */

  const auto index = m_config.m_index;

  page_id_t page_id(index->space, page_no);

  Savepoint savepoint({mtr->get_savepoint(), nullptr});

  auto block = block_get_s_latched(page_id, mtr, __LINE__);

  page_no_t child_page_no = FIL_NULL;

  /* read_level requested should be less than the tree height. */
  ut_ad(m_config.m_read_level <
        btr_page_get_level(buf_block_get_frame(block)) + 1);

  savepoint.second = block;

  ulint offsets_[REC_OFFS_NORMAL_SIZE];
  auto offsets = offsets_;

  rec_offs_init(offsets_);

  page_cur_t page_cursor;

  page_cursor.index = index;

  auto start = scan_range.m_start;

  if (start != nullptr) {
    if (!scan_range.is_greatdb_ap_range_scan) {
      page_cur_search(block, index, start, PAGE_CUR_LE, &page_cursor);
    } else {
      if (ranges.empty()) {
        if (ha_rkey_function::HA_READ_KEY_OR_NEXT ==
                scan_range.m_range_start_flag ||
            ha_rkey_function::HA_READ_KEY_EXACT ==
                scan_range.m_range_start_flag) {
          page_cur_search(block, index, start, PAGE_CUR_L, &page_cursor);
        } else if (ha_rkey_function::HA_READ_AFTER_KEY ==
                   scan_range.m_range_start_flag) {
          page_cur_search(block, index, start, PAGE_CUR_LE, &page_cursor);
        } else {
          ut_a(HA_READ_INVALID == scan_range.m_range_start_flag);
        }
      }
    }

    if (page_cur_is_after_last(&page_cursor)) {
      return (DB_SUCCESS);
    } else if (page_cur_is_before_first((&page_cursor))) {
      page_cur_move_to_next(&page_cursor);
    }
  } else {
    page_cur_set_before_first(block, &page_cursor);
    /* Skip the infimum record. */
    page_cur_move_to_next(&page_cursor);
  }

  mem_heap_t *heap{};

  const auto at_leaf = page_is_leaf(buf_block_get_frame(block));
  const auto at_level = btr_page_get_level(buf_block_get_frame(block));

  Savepoints savepoints{};

  while (!page_cur_is_after_last(&page_cursor)) {
    const auto rec = page_cur_get_rec(&page_cursor);

    ut_a(at_leaf || rec_get_node_ptr_flag(rec) ||
         !dict_table_is_comp(index->table));

    if (heap == nullptr) {
      heap = mem_heap_create(srv_page_size / 4, UT_LOCATION_HERE);
    }

    offsets = rec_get_offsets(rec, index, offsets, ULINT_UNDEFINED,
                              UT_LOCATION_HERE, &heap);

    const auto end = scan_range.m_end;

    if (end != nullptr && end->compare(rec, index, offsets) < 0) {
      break;
    }

    page_cur_t level_page_cursor;

    /* Split the tree one level below the root if read_level requested is below
    the root level. */
    if (at_level > m_config.m_read_level) {
      auto page_no = btr_node_ptr_get_child_page_no(rec, offsets);
      child_page_no = page_no;

      if (depth < split_level) {
        /* Need to create a range starting at a lower level in the tree. */
        create_ranges(scan_range, page_no, depth + 1, split_level, ranges, mtr);

        page_cur_move_to_next(&page_cursor);
        continue;
      }

      /* Find the range start in the leaf node. */
      level_page_cursor = start_range(page_no, mtr, start, savepoints);
    } else {
      /* In case of root node being the leaf node or in case we've been asked to
      read the root node (via read_level) place the cursor on the root node and
      proceed. */

      if (start != nullptr) {
        // if (!m_config.m_scan_range.is_greatdb_ap_range_scan) {
        page_cur_search(block, index, start, PAGE_CUR_GE, &page_cursor);
        ut_a(!page_rec_is_infimum(page_cur_get_rec(&page_cursor)));
        // } else {
        //   if (HA_READ_KEY_EXACT == m_config.m_scan_range.m_range_start_flag
        //   ||
        //       HA_READ_KEY_OR_NEXT ==
        //       m_config.m_scan_range.m_range_start_flag) {
        //     page_cur_search(block, index, start, PAGE_CUR_GE, &page_cursor);
        //     ut_a(!page_rec_is_infimum(page_cur_get_rec(&page_cursor)));
        //   } else {
        //     page_cur_search(block, index, start, PAGE_CUR_G, &page_cursor);
        //   }
        // }
      } else {
        page_cur_set_before_first(block, &page_cursor);

        /* Skip the infimum record. */
        page_cur_move_to_next(&page_cursor);
        ut_a(!page_cur_is_after_last(&page_cursor));
      }

      /* Since we are already at the requested level use the current page
       cursor. */
      memcpy(&level_page_cursor, &page_cursor, sizeof(level_page_cursor));
    }

    if (!page_rec_is_supremum(page_cur_get_rec(&level_page_cursor))) {
      create_range(ranges, level_page_cursor, mtr);
    }

    /* We've created the persistent cursor, safe to release S latches on
    the blocks that are in this range (sub-tree). */
    for (auto &savepoint : savepoints) {
      mtr->release_block_at_savepoint(savepoint.first, savepoint.second);
    }

    if (m_depth == 0 && depth == 0) {
      m_depth = savepoints.size();
    }

    savepoints.clear();

    if (at_level == m_config.m_read_level) {
      break;
    }

    start = nullptr;

    page_cur_move_to_next(&page_cursor);
  }

  if (ranges.size() == 1 && depth == split_level && !at_leaf &&
      child_page_no != FIL_NULL) {
    ranges.clear();
    create_ranges(scan_range, child_page_no, depth + 1, split_level + 1, ranges,
                  mtr);
  }

  savepoints.push_back(savepoint);

  for (auto &savepoint : savepoints) {
    mtr->release_block_at_savepoint(savepoint.first, savepoint.second);
  }

  if (heap != nullptr) {
    mem_heap_free(heap);
  }

  return (DB_SUCCESS);
}

dberr_t Parallel_reader::Scan_ctx::partition(
    const Scan_range &scan_range, Parallel_reader::Scan_ctx::Ranges &ranges,
    size_t split_level) {
  ut_ad(index_s_own());

  mtr_t mtr;
  mtr.start();
  mtr.set_log_mode(MTR_LOG_NO_REDO);

  dberr_t err{DB_SUCCESS};

  err = create_ranges(scan_range, m_config.m_index->page, 0, split_level,
                      ranges, &mtr);

  if (m_config.m_pq_reverse_scan && !ranges.empty()) {
    auto &iter = ranges.back().second;
    auto block = m_config.m_pcur->get_block();
    page_id_t page_id(m_config.m_index->space, block->get_page_no());
    auto s_block MY_ATTRIBUTE((unused)) =
        block_get_s_latched(page_id, &mtr, __LINE__);
    assert(block == s_block);

    auto page_cursor = m_config.m_pcur->get_page_cur();
    page_cursor->index = m_config.m_index;
    iter = create_persistent_cursor(*page_cursor, &mtr);

    /* deep copy of start of first ctx */
    if (scan_range.m_start == nullptr) {
      auto &first_iter = ranges.front().first;
      first_iter = std::make_shared<Iter>();
    }
  } else if (scan_range.m_end != nullptr && !ranges.empty()) {
    auto &iter = ranges.back().second;
    ut_a(iter->m_heap == nullptr);

    iter->m_heap = mem_heap_create(sizeof(btr_pcur_t) + (srv_page_size / 16),
                                   UT_LOCATION_HERE);

    iter->m_tuple = pq_dtuple_copy(scan_range.m_end, iter->m_heap);

    /* Do a deep copy. */
    for (size_t i = 0; i < dtuple_get_n_fields(iter->m_tuple); ++i) {
      dfield_dup(&iter->m_tuple->fields[i], iter->m_heap);
    }

    if (m_config.m_scan_range.is_greatdb_ap_range_scan &&
        m_config.m_scan_range.m_end) {
      iter->m_is_last_range = true;
      iter->m_iter_for_greatdb_range = true;
    }

    if (m_config.m_scan_range.is_greatdb_ap_range_scan &&
        m_config.m_scan_range.m_start) {
      auto &start_iter = ranges.front().first;
      start_iter->m_is_first_range = true;
      start_iter->m_iter_for_greatdb_range = true;
    }
  }

  mtr.commit();

  return (err);
}

dberr_t Parallel_reader::Scan_ctx::create_context(const Range &range,
                                                  bool split) {
  auto ctx_id = m_reader->m_ctx_id.fetch_add(1, std::memory_order_relaxed);

  // clang-format off

  auto ctx = std::shared_ptr<Ctx>(
      ut::new_withkey<Ctx>(UT_NEW_THIS_FILE_PSI_KEY, ctx_id, this, range),
      [](Ctx *ctx) { ut::delete_(ctx); });

  // clang-format on

  dberr_t err{DB_SUCCESS};

  if (ctx.get() == nullptr) {
    m_reader->m_ctx_id.fetch_sub(1, std::memory_order_relaxed);
    return (DB_OUT_OF_MEMORY);
  } else {
    ctx->m_split = split;
    ctx->reader = m_reader;
    m_reader->enqueue(ctx);
  }

  return (err);
}

dberr_t Parallel_reader::Scan_ctx::create_contexts(const Ranges &ranges) {
  size_t split_point{};

  {
    const auto n = std::max(max_threads(), size_t{1});

    ut_a(n <= Parallel_reader::MAX_TOTAL_THREADS);

    if (ranges.size() > n) {
      split_point = (ranges.size() / n) * n;
    } else if (m_depth < SPLIT_THRESHOLD) {
      /* If the tree is not very deep then don't split. For smaller tables
      it is more expensive to split because we end up traversing more blocks*/
      split_point = n;
    }
  }

  if (ranges.size() > split_point) {
    m_reader->m_need_change_dop = false;
  }

  size_t i{};
  size_t split_num = 0;
  if (ranges.size() > split_point) {
    split_num = ranges.size() - split_point;
  }
  bool split;

  for (auto range : ranges) {
    split = (m_config.m_pq_reverse_scan | m_config.m_is_greatdb_ap_desc_fetch)
                ? i < split_num
                : i >= split_point;
    auto err = create_context(range, split);

    if (err != DB_SUCCESS) {
      return (err);
    }

    ++i;
  }

  return DB_SUCCESS;
}

void Parallel_reader::parallel_read() {
  if (m_ctxs.empty() && !m_force_start_thread_for_ap_async_fetch) {
    return;
  }

  if (m_sync) {
    auto ptr = ut::new_withkey<Thread_ctx>(UT_NEW_THIS_FILE_PSI_KEY, 0);

    if (ptr == nullptr) {
      set_error_state(DB_OUT_OF_MEMORY);
      return;
    }

    m_thread_ctxs.push_back(ptr);

    /* Set event to indicate to ::worker() that no threads will be spawned. */
    os_event_set(m_event);

    worker(m_thread_ctxs[0]);

    return;
  }

  ut_a(m_n_threads > 0);

  m_thread_ctxs.reserve(m_n_threads);

  dberr_t err{DB_SUCCESS};

  for (size_t i = 0; i < m_n_threads; ++i) {
    try {
      auto ptr = ut::new_withkey<Thread_ctx>(UT_NEW_THIS_FILE_PSI_KEY, i);
      if (ptr == nullptr) {
        set_error_state(DB_OUT_OF_MEMORY);
        return;
      }
      m_thread_ctxs.emplace_back(ptr);
      m_parallel_read_threads.emplace_back(
          os_thread_create(parallel_read_thread_key, i + 1,
                           &Parallel_reader::worker, this, m_thread_ctxs[i]));
      m_parallel_read_threads.back().start();
    } catch (...) {
      err = DB_OUT_OF_RESOURCES;
      /* Set the global error state to tell the worker threads to exit. */
      set_error_state(err);
      break;
    }
  }

  DEBUG_SYNC_C("parallel_read_wait_for_kill_query");

  DBUG_EXECUTE_IF(
      "innodb_pread_thread_OOR", if (!m_sync) {
        err = DB_OUT_OF_RESOURCES;
        set_error_state(err);
      });

  os_event_set(m_event);

  DBUG_EXECUTE_IF("bug28079850", set_error_state(DB_INTERRUPTED););
}

dberr_t Parallel_reader::spawn(size_t n_threads) noexcept {
  /* In case this is a retry after a DB_OUT_OF_RESOURCES error. */
  m_err = DB_SUCCESS;

  m_n_threads = n_threads;

  if (max_threads() > m_n_threads) {
    release_unused_threads(max_threads() - m_n_threads);
  }

  parallel_read();

  return DB_SUCCESS;
}

dberr_t Parallel_reader::run(size_t n_threads) {
  /* In case this is a retry after a DB_OUT_OF_RESOURCES error. */
  m_err = DB_SUCCESS;

  ut_a(max_threads() >= n_threads);

  if (n_threads == 0) {
    m_sync = true;
  }

  const auto err = spawn(n_threads);

  /* Don't wait for the threads to finish if the read is not synchronous or
  if there's no parallel read. */
  if (m_sync) {
    if (err != DB_SUCCESS) {
      return err;
    }
    ut_a(m_n_threads == 0);
    return is_error_set() ? m_err.load() : DB_SUCCESS;
  } else {
    join();

    if (err != DB_SUCCESS) {
      return err;
    } else if (is_error_set()) {
      return m_err;
    }

    for (auto &scan_ctx : m_scan_ctxs) {
      if (scan_ctx->is_error_set()) {
        /* Return the state of the first Scan context that is in state ERROR. */
        return scan_ctx->m_err;
      }
    }
  }

  return DB_SUCCESS;
}

dberr_t Parallel_reader::add_scan(trx_t *trx,
                                  const Parallel_reader::Config &config,
                                  Parallel_reader::F &&f, bool split) {
  // clang-format off

  auto scan_ctx = std::shared_ptr<Scan_ctx>(
      ut::new_withkey<Scan_ctx>(UT_NEW_THIS_FILE_PSI_KEY, this, m_scan_ctx_id, trx, config, std::move(f)),
      [](Scan_ctx *scan_ctx) { ut::delete_(scan_ctx); });

  // clang-format on

  if (scan_ctx.get() == nullptr) {
    ib::error(ER_IB_ERR_PARALLEL_READ_OOM) << "Out of memory";
    return (DB_OUT_OF_MEMORY);
  }

  m_greatdb_ap_reverse_fetch = config.m_is_greatdb_ap_desc_fetch;

  m_scan_ctxs.push_back(scan_ctx);

  ++m_scan_ctx_id;

  scan_ctx->index_s_lock();

  Parallel_reader::Scan_ctx::Ranges ranges{};
  dberr_t err{DB_SUCCESS};

  /* Split at the root node (level == 0). */
  err = scan_ctx->partition(config.m_scan_range, ranges, 0);

  if (ranges.empty() || err != DB_SUCCESS) {
    /* Table is empty. */
    scan_ctx->index_s_unlock();
    return (err);
  }

  err = scan_ctx->create_contexts(ranges);

  scan_ctx->index_s_unlock();

  return (err);
}

dberr_t Parallel_reader::async_parallel_read(size_t thread_index,
                                             size_t &thread_created_count,
                                             std::string &create_thread_err_msg,
                                             bool &need_to_retry) {
  dberr_t err{DB_SUCCESS};
  thread_created_count = 0;
  if (m_ctxs.empty() && !m_force_start_thread_for_ap_async_fetch) {
    return err;
  }

  ut_a(m_n_threads > 0);

  for (size_t i = thread_index; i < m_n_threads; ++i) {
    try {
      m_parallel_read_threads.emplace_back(
          os_thread_create(parallel_read_thread_key, i + 1,
                           &Parallel_reader::worker, this, m_thread_ctxs[i]));
      /** up to here, the thread has been started; but it does not execute the
       * thread func
       */
      m_parallel_read_threads.back().start();
    } catch (const std::exception &e) {
      err = DB_OUT_OF_RESOURCES;
      /* Set the global error state to tell the worker threads to exit. */
      // set_error_state(err);
      create_thread_err_msg = e.what();
      need_to_retry = true;
      break;
    }

    ++thread_created_count;
  }

  DEBUG_SYNC_C("parallel_read_wait_for_kill_query");

  DBUG_EXECUTE_IF(
      "innodb_pread_thread_OOR", if (!m_sync) {
        err = DB_OUT_OF_RESOURCES;
        set_error_state(err);
        need_to_retry = false;
      });

  // os_event_set(m_event);

  DBUG_EXECUTE_IF("bug28079850", set_error_state(DB_INTERRUPTED);
                  need_to_retry = false;);
  if (need_to_retry) {
    err = get_error_state();
  }

  return err;
}

dberr_t Parallel_reader::async_spawn(size_t n_threads) noexcept {
  /* In case this is a retry after a DB_OUT_OF_RESOURCES error. */

  size_t thread_created_count = 0;
  size_t thread_index = 0;
  dberr_t err{DB_SUCCESS};
  std::string create_thread_err_msg;
  bool need_to_retry = false;
  uint32_t total_retry_count = 100;
  uint32_t retry_step = 0;
  uint32_t retry_interval_in_ms = 10;
  m_err = DB_SUCCESS;

  m_n_threads = n_threads;

  if (max_threads() > m_n_threads) {
    release_unused_threads(max_threads() - m_n_threads);
  }

  m_thread_ctxs.reserve(m_n_threads);
  create_thread_err_msg.reserve(256);

  for (size_t i = 0; i < m_n_threads; ++i) {
    Thread_ctx *ptr = ut::new_withkey<Thread_ctx>(UT_NEW_THIS_FILE_PSI_KEY, i);
    if (nullptr == ptr) {
      set_error_state(DB_OUT_OF_MEMORY);
      return DB_OUT_OF_MEMORY;
    }
    m_thread_ctxs.emplace_back(ptr);
  }

  do {
    need_to_retry = false;
    thread_created_count = 0;

    if (DB_SUCCESS != err) {
      ++retry_step;
      std::this_thread::sleep_for(
          std::chrono::milliseconds(retry_interval_in_ms));
    }

    err = async_parallel_read(thread_index, thread_created_count,
                              create_thread_err_msg, need_to_retry);

    thread_index += thread_created_count;
    m_n_threads_created.fetch_add(thread_created_count);
  } while ((DB_SUCCESS != err) && need_to_retry &&
           (retry_step < total_retry_count));

  if (DB_SUCCESS != err) {
    set_error_state(err);
    ib::info() << "need create parallel threads:" << m_n_threads
               << " actual created:" << m_n_threads_created.load()
               << " reason:" << create_thread_err_msg.c_str()
               << " there are about " << s_active_threads.load()
               << " parallel read threads.";
  }
  os_event_set(m_event);

  if (DB_SUCCESS != err) {
    while (m_n_threads_created.load() != m_n_threads_exited.load()) {
      std::this_thread::yield();
    }
  }

  return err;
}

/** create the work theads, start these thread and no-waiting them exist. */
dberr_t Parallel_reader::async_run(size_t n_threads) {
  /* In case this is a retry after a DB_OUT_OF_RESOURCES error. */
  m_err = DB_SUCCESS;
  m_force_start_thread_for_ap_async_fetch = true;

  ut_a(max_threads() >= n_threads);
  m_sync = false;

  const auto err = async_spawn(n_threads);
  if (DB_SUCCESS != err) {
    return err;
  }

  if (is_error_set()) {
    return get_error_state();
  }

  return DB_SUCCESS;
}

void Parallel_reader::async_worker(Parallel_reader::Thread_ctx *thread_ctx) {
  dberr_t err{DB_SUCCESS};
  dberr_t cb_err{DB_SUCCESS};

  if (m_start_callback) {
    /* Thread start. */
    thread_ctx->m_state = State::THREAD;
    cb_err = m_start_callback(thread_ctx);

    if (cb_err != DB_SUCCESS) {
      err = cb_err;
      set_error_state(cb_err);
    }
  }

  /* Wait for all the threads to be spawned as it's possible that we could
  abort the operation if there are not enough resources to spawn all the
  threads. */
  if (!m_sync) {
    os_event_wait_time_low(m_event, std::chrono::microseconds::max(),
                           m_sig_count);
  }

  for (;;) {
    size_t n_completed{};
    int64_t sig_count = os_event_reset(m_event);

    while (err == DB_SUCCESS && cb_err == DB_SUCCESS && !is_error_set()) {
      auto ctx = dequeue();

      if (ctx == nullptr) {
        break;
      }

      auto scan_ctx = ctx->m_scan_ctx;

      if (scan_ctx->is_error_set()) {
        break;
      }

      ctx->m_thread_ctx = thread_ctx;

      if (ctx->m_split) {
        err = ctx->split();
        /* Tell the other threads that there is work to do. */
        os_event_set(m_event);
      } else {
        if (m_start_callback) {
          /* Context start. */
          thread_ctx->m_state = State::CTX;
          cb_err = m_start_callback(thread_ctx);
        }

        if (cb_err == DB_SUCCESS && err == DB_SUCCESS) {
          if (!m_greatdb_ap_reverse_fetch) {
            ut_ad(!!ctx->is_greatdb_ap_desc() == ctx->is_greatdb_ap_desc());
            err = ctx->traverse();
          } else {
            /** support the desc support for parallel read */
            err = ctx->traverse_desc();
          }
        }

        if (m_finish_callback) {
          /* Context finished. */
          thread_ctx->m_state = State::CTX;
          cb_err = m_finish_callback(thread_ctx);
        }
      }

      /* Check for trx interrupted (useful in the case of small tables). */
      if (err == DB_SUCCESS && trx_is_interrupted(ctx->trx())) {
        err = DB_INTERRUPTED;
        scan_ctx->set_error_state(err);
        break;
      }

      ut_ad(err == DB_SUCCESS || scan_ctx->is_error_set());

      ++n_completed;
    }

    if (cb_err != DB_SUCCESS || err != DB_SUCCESS || is_error_set()) {
      break;
    }

    m_n_completed.fetch_add(n_completed, std::memory_order_relaxed);

    if (m_n_completed == m_ctx_id) {
      /* Wakeup other worker threads before exiting */
      os_event_set(m_event);
      break;
    }

    if (!m_sync) {
      os_event_wait_time_low(m_event, std::chrono::microseconds::max(),
                             sig_count);
    }
  }

  if (err != DB_SUCCESS && !is_error_set()) {
    /* Set the "global" error state. */
    set_error_state(err);
  }

  if (is_error_set()) {
    /* Wake up any sleeping threads. */
    os_event_set(m_event);
  }

  if (m_finish_callback) {
    /* Thread finished. */
    thread_ctx->m_state = State::THREAD;
    cb_err = m_finish_callback(thread_ctx);

    /* Keep the err status from previous failed operations */
    if (cb_err != DB_SUCCESS) {
      err = cb_err;
      set_error_state(cb_err);
    }
  }

  ut_a(is_error_set() || (m_n_completed == m_ctx_id && is_queue_empty()));
}
