/* Copyright (c) 2014, 2022, Oracle and/or its affiliates. All rights reserved.
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

#include <list>

#include <assert.h>
#include <errno.h>
#include <mysql/group_replication_priv.h>
#include <signal.h>
#include <time.h>

#include <mutex_lock.h>
#include <mysql/components/services/log_builtins.h>
#include "my_byteorder.h"
#include "my_dbug.h"
#include "my_systime.h"
#include "mysql/psi/mysql_file.h"
#include "plugin/group_replication/include/applier.h"
#include "plugin/group_replication/include/leave_group_on_failure.h"
#include "plugin/group_replication/include/plugin.h"
#include "plugin/group_replication/include/plugin_messages/single_primary_message.h"
#include "plugin/group_replication/include/plugin_server_include.h"
#include "plugin/group_replication/include/plugin_variables.h"
#include "plugin/group_replication/include/services/notification/notification.h"
#include "plugin/group_replication/libmysqlgcs/include/mysql/gcs/gcs_member_identifier.h"
#include "sql/protocol_classic.h"

char applier_module_channel_name[] = "group_replication_applier";
bool applier_thread_is_exiting = false;

#define RECOVERING_APPLIER_BUFFER_SIZE 65536
#define RECOVERING_APPLIER_BUFFER_MIN_SIZE 10

static void *launch_handler_thread(void *arg) {
  Applier_module *handler = (Applier_module *)arg;
  handler->applier_thread_handle();
  return nullptr;
}

Applier_module::Applier_module()
    : applier_thd_state(),
      applier_aborted(false),
      applier_error(0),
      suspended(false),
      incoming(nullptr),
      delayed_packets_queue(nullptr),
      pipeline(nullptr),
      stop_wait_timeout(LONG_TIMEOUT),
      applier_channel_observer(nullptr) {
  mysql_mutex_init(key_GR_LOCK_applier_module_run, &run_lock,
                   MY_MUTEX_INIT_FAST);
  mysql_cond_init(key_GR_COND_applier_module_run, &run_cond);
  mysql_mutex_init(key_GR_LOCK_applier_module_suspend, &suspend_lock,
                   MY_MUTEX_INIT_FAST);
  mysql_cond_init(key_GR_COND_applier_module_suspend, &suspend_cond);
  mysql_cond_init(key_GR_COND_applier_module_wait,
                  &suspension_waiting_condition);

  has_delayed_view_change_event = false;
#ifndef NDEBUG
  wait_online = false;
  conditional_trap = 0;

#endif
}

Applier_module::~Applier_module() {
  if (this->incoming) {
    while (!this->incoming->empty()) {
      Packet *packet = nullptr;
      this->incoming->pop(&packet);
      delete packet;
    }
    delete incoming;
  }

  if (this->delayed_packets_queue) {
    while (!this->delayed_packets_queue->empty()) {
      Packet *packet = this->delayed_packets_queue->front();
      this->delayed_packets_queue->pop_front();
      delete packet;
    }
    delete delayed_packets_queue;
  }

  delete applier_channel_observer;

  mysql_mutex_destroy(&run_lock);
  mysql_cond_destroy(&run_cond);
  mysql_mutex_destroy(&suspend_lock);
  mysql_cond_destroy(&suspend_cond);
  mysql_cond_destroy(&suspension_waiting_condition);

  gr_applier_vars.reset();
}

int Applier_module::setup_applier_module(Handler_pipeline_type pipeline_type,
                                         bool reset_logs, ulong stop_timeout,
                                         rpl_sidno group_sidno,
                                         ulonglong gtid_assignment_block_size) {
  DBUG_TRACE;

  int error = 0;

  // create the receiver queue
  this->incoming = new Synchronized_queue<Packet *>(key_transaction_data);
  this->delayed_packets_queue = new std::deque<Packet *>();

  stop_wait_timeout = stop_timeout;

  pipeline = nullptr;

  if ((error = get_pipeline(pipeline_type, &pipeline))) {
    return error;
  }

  reset_applier_logs = reset_logs;
  group_replication_sidno = group_sidno;
  this->gtid_assignment_block_size = gtid_assignment_block_size;

  return error;
}

int Applier_module::purge_applier_queue_and_restart_applier_module() {
  DBUG_TRACE;
  int error = 0;

  /*
    Here we are stopping applier thread intentionally and we will be starting
    the applier thread after purging the relay logs. So we should ignore any
    errors during the stop (eg: error due to stopping the applier thread in the
    middle of applying the group of events). Hence unregister the applier
    channel observer temporarily till the required work is done.
  */
  channel_observation_manager_list
      ->get_channel_observation_manager(GROUP_CHANNEL_OBSERVATION_MANAGER_POS)
      ->unregister_channel_observer(applier_channel_observer);

  /* Stop the applier thread */
  Pipeline_action *stop_action = new Handler_stop_action();
  error = pipeline->handle_action(stop_action);
  delete stop_action;
  if (error) return error; /* purecov: inspected */

  /* Purge the relay logs and initialize the channel*/
  Handler_applier_configuration_action *applier_conf_action =
      new Handler_applier_configuration_action(
          applier_module_channel_name, true, /* purge relay logs always*/
          stop_wait_timeout, group_replication_sidno);

  error = pipeline->handle_action(applier_conf_action);
  delete applier_conf_action;
  if (error) return error; /* purecov: inspected */

  channel_observation_manager_list
      ->get_channel_observation_manager(GROUP_CHANNEL_OBSERVATION_MANAGER_POS)
      ->register_channel_observer(applier_channel_observer);

  /* Start the applier thread */
  Pipeline_action *start_action = new Handler_start_action();
  error = pipeline->handle_action(start_action);
  delete start_action;

  return error;
}

int Applier_module::setup_pipeline_handlers() {
  DBUG_TRACE;

  int error = 0;

  // Configure the applier handler trough a configuration action
  Handler_applier_configuration_action *applier_conf_action =
      new Handler_applier_configuration_action(
          applier_module_channel_name, reset_applier_logs, stop_wait_timeout,
          group_replication_sidno);

  error = pipeline->handle_action(applier_conf_action);
  delete applier_conf_action;
  if (error) return error; /* purecov: inspected */

  Handler_certifier_configuration_action *cert_conf_action =
      new Handler_certifier_configuration_action(group_replication_sidno,
                                                 gtid_assignment_block_size);

  error = pipeline->handle_action(cert_conf_action);

  delete cert_conf_action;

  return error;
}

void Applier_module::set_applier_thread_context() {
  THD *thd = new THD;
  my_thread_init();
  thd->set_new_thread_id();
  thd->thread_stack = (char *)&thd;
  thd->store_globals();
  // Protocol is only initiated because of process list status
  thd->get_protocol_classic()->init_net(nullptr);
  /*
    We only set the thread type so the applier thread shows up
    in the process list.
  */
  thd->system_thread = SYSTEM_THREAD_SLAVE_IO;

#ifdef HAVE_PSI_THREAD_INTERFACE
  {
    // Attach thread instrumentation
    struct PSI_thread *psi = PSI_THREAD_CALL(get_thread)();
    thd->set_psi(psi);
  }
#endif /* HAVE_PSI_THREAD_INTERFACE */

  // Make the thread have a better description on process list
  thd->set_query(STRING_WITH_LEN("Group replication applier module"));
  thd->set_query_for_display(
      STRING_WITH_LEN("Group replication applier module"));

  // Needed to start replication threads
  thd->security_context()->skip_grants();

  global_thd_manager_add_thd(thd);

  DBUG_EXECUTE_IF("group_replication_applier_thread_init_wait", {
    const char act[] = "now wait_for signal.gr_applier_init_signal";
    assert(!debug_sync_set_action(current_thd, STRING_WITH_LEN(act)));
  });

  applier_thd = thd;
}

void Applier_module::clean_applier_thread_context() {
  applier_thd->get_protocol_classic()->end_net();
  applier_thd->release_resources();
  global_thd_manager_remove_thd(applier_thd);
}

int Applier_module::inject_event_into_pipeline(Pipeline_event *pevent,
                                               Continuation *cont) {
  int error = 0;
  pipeline->handle_event(pevent, cont);

  if ((error = cont->wait()))
    LogPluginErr(ERROR_LEVEL, ER_GRP_RPL_EVENT_HANDLING_ERROR, error);

  return error;
}

bool Applier_module::apply_action_packet(Action_packet *action_packet) {
  enum_packet_action action = action_packet->packet_action;

  // packet used to break the queue blocking wait
  if (action == TERMINATION_PACKET) {
    return true;
  }
  // packet to signal the applier to suspend
  if (action == SUSPENSION_PACKET) {
    suspend_applier_module();
    if (abort_after_suspended) {
      LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                      "abort queue after suspended");
      return true;
    } else {
      LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                      "continue to process queue after suspended");
      return false;
    }
  }

  if (action == CHECKPOINT_PACKET) {
    Queue_checkpoint_packet *packet = (Queue_checkpoint_packet *)action_packet;
    packet->signal_checkpoint_reached();
    return false;
  }

  return false; /* purecov: inspected */
}

int Applier_module::apply_view_change_packet(
    View_change_packet *view_change_packet,
    Format_description_log_event *fde_evt, Continuation *cont) {
  int error = 0;

  Gtid_set *group_executed_set = nullptr;
  Sid_map *sid_map = nullptr;
  if (!view_change_packet->group_executed_set.empty()) {
    sid_map = new Sid_map(nullptr);
    group_executed_set = new Gtid_set(sid_map, nullptr);
    if (intersect_group_executed_sets(view_change_packet->group_executed_set,
                                      group_executed_set)) {
      LogPluginErr(
          WARNING_LEVEL,
          ER_GRP_RPL_ERROR_GTID_EXECUTION_INFO); /* purecov: inspected */
      delete sid_map;                            /* purecov: inspected */
      delete group_executed_set;                 /* purecov: inspected */
      group_executed_set = nullptr;              /* purecov: inspected */
    }
  }

  if (group_executed_set != nullptr) {
    if (get_certification_handler()
            ->get_certifier()
            ->set_group_stable_transactions_set(group_executed_set)) {
      LogPluginErr(WARNING_LEVEL,
                   ER_GRP_RPL_CERTIFICATE_SIZE_ERROR); /* purecov: inspected */
    }
    delete sid_map;
    delete group_executed_set;
  }

  View_change_log_event *view_change_event =
      new View_change_log_event(view_change_packet->view_id.c_str());

  Pipeline_event *pevent = new Pipeline_event(view_change_event, fde_evt);
  pevent->mark_event(SINGLE_VIEW_EVENT);

  /*
    If there are prepared consistent transactions waiting for the
    prepare acknowledge, the View_change_log_event must be delayed
    to after those transactions are committed, since they belong to
    the previous view.
  */
  if (transaction_consistency_manager->has_local_prepared_transactions()) {
    DBUG_PRINT("info", ("Delaying the log of the view '%s' to after local "
                        "prepared transactions",
                        view_change_packet->view_id.c_str()));
    transaction_consistency_manager->schedule_view_change_event(pevent);
    has_delayed_view_change_event = true;
    return error;
  }

  error = inject_event_into_pipeline(pevent, cont);
  if (!cont->is_transaction_discarded() &&
      !pevent->is_delayed_view_change_waiting_for_consistent_transactions())
    delete pevent;

  return error;
}

int Applier_module::apply_data_packet(Data_packet *data_packet,
                                      Format_description_log_event *fde_evt,
                                      Continuation *cont, bool io_buffered,
                                      bool &recv_binlog_chaos_error) {
  DBUG_TRACE;
  int error = 0;
  uchar *payload = data_packet->payload;
  uchar *payload_end = data_packet->payload + data_packet->len;
  ulong left_len = data_packet->len;

  DBUG_EXECUTE_IF("group_replication_before_apply_data_packet", {
    const char act[] =
        "now signal signal.group_replication_before_apply_data_packet_reached "
        "wait_for continue_apply";
    assert(!debug_sync_set_action(current_thd, STRING_WITH_LEN(act)));
  });

  int i = 0;
  while ((payload != payload_end) && !error) {
    uint event_len = uint4korr(((uchar *)payload) + EVENT_LEN_OFFSET);
    if (++i == 4) {
      DBUG_EXECUTE_IF("group_replication_recv_binlog_chaos_no_rejoin",
                      event_len = 1024 * 10;);
      DBUG_EXECUTE_IF("group_replication_recv_binlog_chaos",
                      event_len = 1024 * 10;);
    }
    if (event_len > left_len || event_len <= LOG_EVENT_HEADER_LEN) {
      error = 1;
      recv_binlog_chaos_error = true;
      DBUG_EXECUTE_IF("group_replication_recv_binlog_chaos_no_rejoin",
                      recv_binlog_chaos_error = false;);
      LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                      "An un-expected data_packet from the group, the binlog "
                      "format is chaos");

      do {
        char filename[128];
        struct timeval tv;
        if (gettimeofday(&tv, nullptr) != 0) {
          break;
        }
        struct tm *tm_p = localtime((const time_t *)&tv.tv_sec);
        if (tm_p == nullptr) {
          break;
        }
        (void)sprintf(
            filename,
            "applier_binlog_chaos_file_%04d-%02d-%02dT%02d:%02d:%02d.%06d",
            tm_p->tm_year + 1900, tm_p->tm_mon + 1, tm_p->tm_mday,
            tm_p->tm_hour, tm_p->tm_min, tm_p->tm_sec, (int)(tv.tv_usec));

        int fd = mysql_file_create(PSI_NOT_INSTRUMENTED, filename, CREATE_MODE,
                                   O_WRONLY | O_EXCL | O_APPEND, MYF(MY_WME));
        if (fd < 0) {
          LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                          "Fail write chaos binlog to temp file");

          break;
        }
        if (mysql_file_write(fd, data_packet->payload, data_packet->len,
                             MYF(MY_WME + MY_NABP))) {
          LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                          "Fail write chaos binlog to temp file");
        }
        mysql_file_close(fd, MYF(0));
      } while (0);
      break;
    }

    Data_packet *new_packet =
        new Data_packet(payload, event_len, key_transaction_data);
    payload = payload + event_len;
    left_len -= event_len;

    Members_list *online_members = nullptr;
    if (nullptr != data_packet->m_online_members) {
      online_members = new Members_list(
          data_packet->m_online_members->begin(),
          data_packet->m_online_members->end(),
          Malloc_allocator<Gcs_member_identifier>(
              key_consistent_members_that_must_prepare_transaction));
    }

    enum_group_replication_consistency_level consistency_level =
        data_packet->m_consistency_level;
    if (is_arbitrator_role()) {
      consistency_level = GROUP_REPLICATION_CONSISTENCY_EVENTUAL;
    }

    Pipeline_event *pevent =
        new Pipeline_event(new_packet, fde_evt, UNDEFINED_EVENT_MODIFIER,
                           consistency_level, online_members);
    if (payload != payload_end) {
      pevent->set_io_buffered(true);
    } else {
      pevent->set_io_buffered(io_buffered);
    }

    error = inject_event_into_pipeline(pevent, cont);

    DBUG_EXECUTE_IF("group_replication_apply_data_packet_after_inject", {
      const char act[] =
          "now SIGNAL "
          "signal.group_replication_apply_data_packet_after_inject_reached "
          "WAIT_FOR "
          "signal.group_replication_apply_data_packet_after_inject_continue";
      assert(!debug_sync_set_action(current_thd, STRING_WITH_LEN(act)));
    });

    delete pevent;

    DBUG_EXECUTE_IF("stop_applier_channel_after_reading_write_rows_log_event", {
      if (payload[EVENT_TYPE_OFFSET] == binary_log::WRITE_ROWS_EVENT) {
        error = 1;
      }
    });
  }

  return error;
}

int Applier_module::apply_single_primary_action_packet(
    Single_primary_action_packet *packet) {
  int error = 0;
  Certifier_interface *certifier = get_certification_handler()->get_certifier();

  switch (packet->action) {
    case Single_primary_action_packet::NEW_PRIMARY:
      certifier->enable_conflict_detection();
      break;
    case Single_primary_action_packet::QUEUE_APPLIED:
      certifier->disable_conflict_detection();
      break;
    default:
      assert(0); /* purecov: inspected */
  }

  return error;
}

int Applier_module::apply_transaction_prepared_action_packet(
    Transaction_prepared_action_packet *packet, int *delayed) {
  DBUG_TRACE;
  return transaction_consistency_manager->handle_remote_prepare(
      packet->get_sid(), packet->m_gno, packet->m_gcs_member_id, delayed);
}

int Applier_module::apply_sync_before_execution_action_packet(
    Sync_before_execution_action_packet *packet) {
  DBUG_TRACE;
  return transaction_consistency_manager->handle_sync_before_execution_message(
      packet->m_thread_id, packet->m_gcs_member_id);
}

int Applier_module::apply_leaving_members_action_packet(
    Leaving_members_action_packet *packet) {
  DBUG_TRACE;
  return transaction_consistency_manager->handle_member_leave(
      packet->m_leaving_members);
}

/**
  Fix sync problems for after consistency when view change is happened
*/
void Applier_module::add_delayed_packets() {
  incoming->push_all(delayed_packets_queue);
}

bool Applier_module::check_remote_prepare_before_view_change(
    Transaction_prepared_action_packet *packet) {
  return transaction_consistency_manager->is_remote_prepare_before_view_change(
      packet->get_sid(), packet->m_gno);
}

bool Applier_module::check_and_delay_packet_after_delayed_view_change(
    Packet *packet) {
  bool expected = true;
  int packet_type = packet->get_packet_type();
  switch (packet_type) {
    case TRANSACTION_PREPARED_PACKET_TYPE:
      DBUG_EXECUTE_IF("consistency_after_conditional_trap", {
        if (conditional_trap) {
          const char act[] =
              "now signal "
              "signal.consistency_after_conditional_trap_waiting "
              "wait_for "
              "signal.consistency_after_conditional_trap_continue "
              "NO_CLEAR_EVENT";
          DBUG_ASSERT(
              !debug_sync_set_action(current_thd, STRING_WITH_LEN(act)));
        }
      });
      DBUG_EXECUTE_IF("consistency_after_set_trap", { conditional_trap = 1; });

      if (!check_remote_prepare_before_view_change(
              static_cast<Transaction_prepared_action_packet *>(packet))) {
        LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                        "packet type is not expected:%d, buffer it",
                        packet_type);
        this->incoming->pop();
        this->delayed_packets_queue->push_back(packet);
        expected = false;
      }
      break;
    case SYNC_BEFORE_EXECUTION_PACKET_TYPE:
    case ACTION_PACKET_TYPE:
    case VIEW_CHANGE_PACKET_TYPE:
    case DATA_PACKET_TYPE:
    case SINGLE_PRIMARY_PACKET_TYPE:
    case LEAVING_MEMBERS_PACKET_TYPE:
    case CERTIFICATION_PACKET_TYPE:
      LogPluginErrMsg(INFORMATION_LEVEL, ER_LOG_PRINTF_MSG,
                      "packet type is not expected:%d, buffer it", packet_type);
      this->incoming->pop();
      this->delayed_packets_queue->push_back(packet);
      expected = false;
      break;
    case SYNC_PREPARED_COMPLETE_TYPE:
      break;
    default:
      LogPluginErrMsg(ERROR_LEVEL, ER_LOG_PRINTF_MSG,
                      "packet type is not expected:%d", packet_type);
      DBUG_ASSERT(0);
  }

  if (expected) {
    return false;
  } else {
    return true;
  }
}

int Applier_module::apply_certification_change_action_packet(
    Certification_packet *packet) {
  return (get_certification_handler()->get_certifier()->handle_certifier_data(
      packet->payload, packet->len, packet->m_member_id));
}

int Applier_module::applier_thread_handle() {
  DBUG_TRACE;

  // set the thread context
  set_applier_thread_context();
  mysql_mutex_lock(&run_lock);
  applier_thd_state.set_initialized();
  mysql_mutex_unlock(&run_lock);

  Handler_THD_setup_action *thd_conf_action = nullptr;
  Format_description_log_event *fde_evt = nullptr;
  Continuation *cont = nullptr;
  Packet *packet = nullptr;
  bool loop_termination = false, io_buffered = false,
       io_buffered_allowed = false;
  int packet_application_error = 0, delayed = 0;
  bool recv_binlog_chaos_error = false;
  bool remaining_packets_inited = false;
  int remaining_packets_to_be_processed = 0;
  size_t applier_batch_size_threshold = 0, recovering_queue_size = 0,
         recovering_processed_cnt = 0;

  gr_applier_vars.total_messages = 0;
  gr_applier_vars.total_data_messages = 0;
  gr_applier_vars.apply_queue_size = 0;
  gr_applier_vars.io_buffer_events = 0;
  gr_applier_vars.apply_events = 0;

  applier_error = setup_pipeline_handlers();

  applier_channel_observer = new Applier_channel_state_observer();
  channel_observation_manager_list
      ->get_channel_observation_manager(GROUP_CHANNEL_OBSERVATION_MANAGER_POS)
      ->register_channel_observer(applier_channel_observer);

  if (!applier_error) {
    Pipeline_action *start_action = new Handler_start_action();
    applier_error += pipeline->handle_action(start_action);
    delete start_action;
  }

  if (applier_error) {
    goto end;
  }

  mysql_mutex_lock(&run_lock);
  applier_thread_is_exiting = false;
  applier_thd_state.set_running();
  if (stage_handler.initialize_stage_monitor())
    LogPluginErr(ERROR_LEVEL, ER_GRP_RPL_NO_STAGE_SERVICE);
  stage_handler.set_stage(info_GR_STAGE_module_executing.m_key, __FILE__,
                          __LINE__, 0, 0);
  mysql_cond_broadcast(&run_cond);
  mysql_mutex_unlock(&run_lock);

  fde_evt = new Format_description_log_event();
  /*
    Group replication does not use binary log checksumming on contents arriving
    from certification. So, group replication applier channel shall behave as a
    replication channel connected to a master that does not add checksum to its
    binary log files.
  */
  fde_evt->common_footer->checksum_alg = binary_log::BINLOG_CHECKSUM_ALG_OFF;
  cont = new Continuation();

  // Give the handlers access to the applier THD
  thd_conf_action = new Handler_THD_setup_action(applier_thd);
  // To prevent overwrite last error method
  applier_error += pipeline->handle_action(thd_conf_action);
  delete thd_conf_action;

  // Update thread instrumentation
#ifdef HAVE_PSI_THREAD_INTERFACE
  {
    struct PSI_thread *psi = applier_thd->get_psi();
    PSI_THREAD_CALL(set_thread_id)(psi, applier_thd->thread_id());
    PSI_THREAD_CALL(set_thread_THD)(psi, applier_thd);
    PSI_THREAD_CALL(set_thread_command)(applier_thd->get_command());
    // Restore Info field
    PSI_THREAD_CALL(set_thread_info)
    (STRING_WITH_LEN("Group replication applier module"));
  }
#endif

  // applier main loop
  while (!applier_error && !packet_application_error && !loop_termination) {
    if (is_applier_thread_aborted()) {
      if (remaining_packets_inited) {
        remaining_packets_to_be_processed--;
      } else {
        remaining_packets_inited = true;
        remaining_packets_to_be_processed = this->incoming->size();
      }

      if (remaining_packets_to_be_processed == 0) {
        remaining_packets_inited = false;
        my_sleep(1000);
        break;
      }
    }
    /* Delayed packets are activated by later packets */
    this->incoming->front(&packet);  // blocking

    {
      applier_batch_size_threshold = get_applier_batch_size_threshold_var();
      gr_applier_vars.apply_queue_size = this->incoming->size();
      if (!io_buffered_allowed) {
        if (applier_batch_size_threshold < RECOVERING_APPLIER_BUFFER_SIZE) {
          applier_batch_size_threshold = RECOVERING_APPLIER_BUFFER_SIZE;
        }
        if (recovering_queue_size == 0) {
          recovering_queue_size = gr_applier_vars.apply_queue_size;
        }
        if (recovering_processed_cnt >= recovering_queue_size) {
          if (gr_applier_vars.apply_queue_size <
              RECOVERING_APPLIER_BUFFER_MIN_SIZE) {
            io_buffered_allowed = true;
          }
        }
        recovering_processed_cnt++;
      }
    }

    if (applier_batch_size_threshold > 0 &&
        gr_applier_vars.apply_queue_size > applier_batch_size_threshold) {
      if (packet->get_packet_type() == DATA_PACKET_TYPE) {
        io_buffered = true;
      } else {
        io_buffered = false;
      }
    } else {
      io_buffered = false;
    }

    DBUG_EXECUTE_IF(
        "group_replication_before_commit_wait_recovery_message_applied",
        { wait_online = true; };);

    if (has_delayed_view_change_event) {
      if (check_and_delay_packet_after_delayed_view_change(packet)) {
        continue;
      }
    }

    switch (packet->get_packet_type()) {
      case ACTION_PACKET_TYPE:
        this->incoming->pop();
        loop_termination = apply_action_packet((Action_packet *)packet);
        break;
      case VIEW_CHANGE_PACKET_TYPE:
        packet_application_error = apply_view_change_packet(
            (View_change_packet *)packet, fde_evt, cont);
        this->incoming->pop();
        break;
      case DATA_PACKET_TYPE:
        packet_application_error =
            apply_data_packet((Data_packet *)packet, fde_evt, cont, io_buffered,
                              recv_binlog_chaos_error);
        // Remove from queue here, so the size only decreases after packet
        // handling
        this->incoming->pop();
        break;
      case SINGLE_PRIMARY_PACKET_TYPE:
        packet_application_error = apply_single_primary_action_packet(
            (Single_primary_action_packet *)packet);
        this->incoming->pop();
        break;
      case TRANSACTION_PREPARED_PACKET_TYPE:
        packet_application_error = apply_transaction_prepared_action_packet(
            static_cast<Transaction_prepared_action_packet *>(packet),
            &delayed);
        this->incoming->pop();
        break;
      case SYNC_BEFORE_EXECUTION_PACKET_TYPE:
        packet_application_error = apply_sync_before_execution_action_packet(
            static_cast<Sync_before_execution_action_packet *>(packet));
        this->incoming->pop();
        break;
      case LEAVING_MEMBERS_PACKET_TYPE:
        packet_application_error = apply_leaving_members_action_packet(
            static_cast<Leaving_members_action_packet *>(packet));
        this->incoming->pop();
        /**
         @ref group_replication_wait_for_current_events_execution_fail
         Member leave has been received. Primary change has started in
         separate thread. Primary change will go to error and try to suspend
         the applier by adding suspension packet. But we want to kill the
         applier via shutdown before suspension packet is processed. So block
         here till SHUTDOWN forwards the KILL signal.

         @note If we do not block here, even if KILL is forwarded suspension
         packet is processed and kill is seen post processing of suspend
         packet, hence the DEBUG here
        */
        DBUG_EXECUTE_IF(
            "group_replication_wait_for_current_events_execution_fail", {
              while (!is_applier_thread_aborted()) my_sleep(1 * 1000 * 1000);
            };);

        break;
      case CERTIFICATION_PACKET_TYPE:
        packet_application_error = apply_certification_change_action_packet(
            static_cast<Certification_packet *>(packet));
        this->incoming->pop();
        break;
      case SYNC_PREPARED_COMPLETE_TYPE:
        has_delayed_view_change_event = false;
        this->incoming->pop();
        if (delayed_packets_queue->size() > 0) {
          add_delayed_packets();
        }
        break;

      default:
        assert(0); /* purecov: inspected */
    }
    gr_applier_vars.total_messages++;
    if (packet->get_packet_type() == DATA_PACKET_TYPE) {
      gr_applier_vars.total_data_messages++;
    }

    if (!delayed) {
      delete packet;
    } else {
      this->incoming->push(packet);
      delayed = 0;
    }
  }

  if (packet_application_error) applier_error = packet_application_error;
  delete fde_evt;
  delete cont;

end:

  // always remove the observer even the thread is no longer running
  channel_observation_manager_list
      ->get_channel_observation_manager(GROUP_CHANNEL_OBSERVATION_MANAGER_POS)
      ->unregister_channel_observer(applier_channel_observer);

  // only try to leave if the applier managed to start
  // or if the applier_thd was killed by the DBA.
  if ((applier_error && applier_thd_state.is_running()) ||
      applier_thd->killed) {
    const char *exit_state_action_abort_log_message =
        "Fatal error during execution on the Applier module of Group "
        "Replication.";
    leave_group_on_failure::mask leave_actions;
    /*
      Only follow exit_state_action if we were already inside a group. We may
      happen to come across an applier error during the startup of GR (i.e.
      during the execution of the START GROUP_REPLICATION command). We must not
      follow exit_state_action on that situation.
    */
    leave_actions.set(leave_group_on_failure::HANDLE_EXIT_STATE_ACTION,
                      gcs_module->belongs_to_group());
    if (recv_binlog_chaos_error) {
      leave_actions.set(leave_group_on_failure::HANDLE_AUTO_REJOIN,
                        gcs_module->belongs_to_group());
    }
    leave_group_on_failure::leave(leave_actions,
                                  ER_GRP_RPL_APPLIER_EXECUTION_FATAL_ERROR,
                                  nullptr, exit_state_action_abort_log_message);
  }

  // Even on error cases, send a stop signal to all handlers that could be
  // active
  Pipeline_action *stop_action = new Handler_stop_action();
  int local_applier_error = pipeline->handle_action(stop_action);
  delete stop_action;

  Gcs_interface_factory::cleanup_thread_communication_resources(
      Gcs_operations::get_gcs_engine());

  LogPluginErr(INFORMATION_LEVEL, ER_GRP_RPL_APPLIER_THD_KILLED);

  DBUG_EXECUTE_IF("applier_thd_timeout", {
    const char act[] = "now wait_for signal.applier_continue";
    assert(!debug_sync_set_action(current_thd, STRING_WITH_LEN(act)));
  });

  stage_handler.end_stage();
  stage_handler.terminate_stage_monitor();

  clean_applier_thread_context();

  mysql_mutex_lock(&run_lock);

  /*
    Don't overwrite applier_error when stop_applier_thread() doesn't return
    error. So applier_error which is also referred by main thread
    doesn't return true from initialize_applier_thread() when
    start_applier_thread() fails and stop_applier_thread() succeeds.
    Also use local var - local_applier_error, as the applier can be deleted
    before the thread returns.
  */
  if (local_applier_error)
    applier_error = local_applier_error; /* purecov: inspected */
  else
    local_applier_error = applier_error;

  applier_killed_status = false;

  // Detach thread instrumentation
#ifdef HAVE_PSI_THREAD_INTERFACE
  PSI_THREAD_CALL(set_thread_THD)(applier_thd->get_psi(), nullptr);
#endif

  delete applier_thd;
  applier_thd = nullptr;
  my_thread_end();
  applier_thd_state.set_terminated();
  mysql_cond_broadcast(&run_cond);
  mysql_mutex_lock(&suspend_lock);
  mysql_cond_broadcast(&suspension_waiting_condition);
  mysql_mutex_unlock(&suspend_lock);
  mysql_mutex_unlock(&run_lock);

  applier_thread_is_exiting = true;
  my_thread_exit(nullptr);

  gr_applier_vars.total_messages = 0;
  gr_applier_vars.total_data_messages = 0;
  gr_applier_vars.apply_queue_size = 0;
  gr_applier_vars.io_buffer_events = 0;
  gr_applier_vars.apply_events = 0;
  return local_applier_error; /* purecov: inspected */
}

int Applier_module::initialize_applier_thread() {
  DBUG_TRACE;

  // avoid concurrency calls against stop invocations
  mysql_mutex_lock(&run_lock);

  applier_thread_is_exiting = false;
  applier_killed_status = false;
  applier_error = 0;

  applier_thd_state.set_created();
  if ((mysql_thread_create(key_GR_THD_applier_module_receiver, &applier_pthd,
                           get_connection_attrib(), launch_handler_thread,
                           (void *)this))) {
    /* applier_thread_is_exiting should be set true to avoid dead loop */
    applier_thread_is_exiting = true;
    applier_thd_state.set_terminated();
    mysql_mutex_unlock(&run_lock); /* purecov: inspected */
    return 1;                      /* purecov: inspected */
  }

  while (applier_thd_state.is_alive_not_running() && !applier_error) {
    DBUG_PRINT("sleep", ("Waiting for applier thread to start"));
    if (current_thd != nullptr && current_thd->is_killed()) {
      applier_error = 1;
      applier_killed_status = true;
      LogPluginErr(WARNING_LEVEL, ER_GRP_RPL_UNBLOCK_WAITING_THD);
      break;
    }

    struct timespec abstime;
    set_timespec(&abstime, 1);

    mysql_cond_timedwait(&run_cond, &run_lock, &abstime);
  }

  mysql_mutex_unlock(&run_lock);
  return applier_error;
}

int Applier_module::terminate_applier_pipeline() {
  int error = 0;
  if (pipeline != nullptr) {
    if ((error = pipeline->terminate_pipeline())) {
      LogPluginErr(
          WARNING_LEVEL,
          ER_GRP_RPL_APPLIER_PIPELINE_NOT_DISPOSED); /* purecov: inspected */
    }
    // delete anyway, as we can't do much on error cases
    delete pipeline;
    pipeline = nullptr;
  }
  return error;
}

int Applier_module::terminate_applier_thread() {
  DBUG_TRACE;

  /* This lock code needs to be re-written from scratch*/
  mysql_mutex_lock(&run_lock);

  applier_aborted = true;

  if (applier_thd_state.is_thread_dead()) {
    goto delete_pipeline;
  }

  while (applier_thd_state.is_thread_alive()) {
    DBUG_PRINT("loop", ("killing group replication applier thread"));

    if (applier_thd_state.is_initialized()) {
      mysql_mutex_lock(&applier_thd->LOCK_thd_data);

      if (applier_killed_status)
        applier_thd->awake(THD::KILL_CONNECTION);
      else
        applier_thd->awake(THD::NOT_KILLED);

      mysql_mutex_unlock(&applier_thd->LOCK_thd_data);

      // before waiting for termination, signal the queue to unlock.
      add_termination_packet();

      // also awake the applier in case it is suspended
      awake_applier_module();
    }

    /*
      There is a small chance that thread might miss the first
      alarm. To protect against it, resend the signal until it reacts
    */
    struct timespec abstime;
    set_timespec(&abstime, (stop_wait_timeout == 1 ? 1 : 2));
#ifndef NDEBUG
    int error =
#endif
        mysql_cond_timedwait(&run_cond, &run_lock, &abstime);

    if (stop_wait_timeout >= 1) {
      stop_wait_timeout = stop_wait_timeout - (stop_wait_timeout == 1 ? 1 : 2);
    }
    if (applier_thd_state.is_thread_alive() &&
        stop_wait_timeout <= 0)  // quit waiting
    {
      mysql_mutex_unlock(&run_lock);
      return 1;
    }
    assert(error == ETIMEDOUT || error == 0);
  }

  assert(!applier_thd_state.is_running());

delete_pipeline:

  // The thread ended properly so we can terminate the pipeline
  terminate_applier_pipeline();

  while (!applier_thread_is_exiting) {
    /* Check if applier thread is exiting per microsecond. */
    my_sleep(1);
  }

  /*
    Give applier thread one microsecond to exit completely after
    it set applier_thread_is_exiting to true.
  */
  my_sleep(1);

  mysql_mutex_unlock(&run_lock);

  return 0;
}

void Applier_module::inform_of_applier_stop(char *channel_name, bool aborted) {
  DBUG_TRACE;

  /*
   This function is called when async replication applier thread is stopped.
   The stop of async replication applier thread is not an issue, however when
   async replication applier thread stops because of some errors, GR applier
   pipeline is also stopped and member goes in the ERROR state.
   The function parameter 'aborted' informs about the async replication
   applier thread errors.
   When the async replication applier thread stop is initiated by Clone GR
   (m_ignore_applier_errors_during_stop=true), GR applier pipeline should
   ignore async replication applier thread errors.
  */
  if (!strcmp(channel_name, applier_module_channel_name) && aborted &&
      !m_ignore_applier_errors_during_stop &&
      applier_thd_state.is_thread_alive()) {
    LogPluginErr(ERROR_LEVEL, ER_GRP_RPL_APPLIER_THD_EXECUTION_ABORTED);
    applier_error = 1;

    // before waiting for termination, signal the queue to unlock.
    add_termination_packet();

    // also awake the applier in case it is suspended
    awake_applier_module();
  }
}

int Applier_module::wait_for_applier_complete_suspension(
    bool *abort_flag, bool wait_for_execution) {
  int error = 0;

  mysql_mutex_lock(&suspend_lock);

  /*
   We use an external flag to avoid race conditions.
   A local flag could always lead to the scenario of
     wait_for_applier_complete_suspension()

   >> thread switch

     break_applier_suspension_wait()
       we_are_waiting = false;
       awake

   thread switch <<

      we_are_waiting = true;
      wait();
  */
  while (!suspended && !(*abort_flag) && !is_applier_thread_aborted() &&
         !applier_error) {
    mysql_cond_wait(&suspension_waiting_condition, &suspend_lock);
  }

  mysql_mutex_unlock(&suspend_lock);

  if (is_applier_thread_aborted() || applier_error)
    return APPLIER_THREAD_ABORTED; /* purecov: inspected */

  /**
    Wait for the applier execution of pre suspension events (blocking method)
    while(the wait method times out)
      wait()
  */
  if (wait_for_execution) {
    error = APPLIER_GTID_CHECK_TIMEOUT_ERROR;  // timeout error
    while (error == APPLIER_GTID_CHECK_TIMEOUT_ERROR && !(*abort_flag))
      error = wait_for_applier_event_execution(1, true);  // blocking
  }

  return (error == APPLIER_RELAY_LOG_NOT_INITED);
}

void Applier_module::interrupt_applier_suspension_wait() {
  mysql_mutex_lock(&suspend_lock);
  mysql_cond_broadcast(&suspension_waiting_condition);
  mysql_mutex_unlock(&suspend_lock);
}

bool Applier_module::is_applier_thread_waiting() {
  DBUG_TRACE;
  Event_handler *event_applier = nullptr;
  Event_handler::get_handler_by_role(pipeline, APPLIER, &event_applier);

  if (event_applier == nullptr) return false; /* purecov: inspected */

  bool result = ((Applier_handler *)event_applier)->is_applier_thread_waiting();

  return result;
}

int Applier_module::wait_for_applier_event_execution(
    double timeout, bool check_and_purge_partial_transactions) {
  DBUG_TRACE;
  int error = 0;
  Event_handler *event_applier = nullptr;
  Event_handler::get_handler_by_role(pipeline, APPLIER, &event_applier);

  if (event_applier && !(error = ((Applier_handler *)event_applier)
                                     ->wait_for_gtid_execution(timeout))) {
    /*
      After applier thread is done, check if there is partial transaction
      in the relay log. If so, applier thread must be holding the lock on it
      and will never release it because there will not be any more events
      coming into this channel. In this case, purge the relaylogs and restart
      the applier thread will release the lock and update the applier thread
      execution position correctly and safely.
    */
    if (check_and_purge_partial_transactions &&
        ((Applier_handler *)event_applier)
            ->is_partial_transaction_on_relay_log()) {
      error = purge_applier_queue_and_restart_applier_module();
    }
  }
  return error;
}

bool Applier_module::get_retrieved_gtid_set(std::string &retrieved_set) {
  Replication_thread_api applier_channel(applier_module_channel_name);
  if (applier_channel.get_retrieved_gtid_set(retrieved_set)) {
    /* purecov: begin inspected */
    LogPluginErr(ERROR_LEVEL, ER_GRP_RPL_ERROR_GTID_SET_EXTRACTION,
                 " cannot extract the applier module's retrieved set.");
    return true;
    /* purecov: end */
  }
  return false;
}

int Applier_module::wait_for_applier_event_execution(std::string &retrieved_set,
                                                     double timeout,
                                                     bool update_THD_status) {
  DBUG_TRACE;
  int error = 0;
  Event_handler *event_applier = nullptr;
  Event_handler::get_handler_by_role(pipeline, APPLIER, &event_applier);

  if (event_applier) {
    error = ((Applier_handler *)event_applier)
                ->wait_for_gtid_execution(retrieved_set, timeout,
                                          update_THD_status);
  }

  return error;
}

bool Applier_module::wait_for_current_events_execution(
    std::shared_ptr<Continuation> checkpoint_condition, bool *abort_flag,
    bool update_THD_status) {
  DBUG_TRACE;
  applier_module->queue_and_wait_on_queue_checkpoint(checkpoint_condition);
  std::string current_retrieve_set;
  if (applier_module->get_retrieved_gtid_set(current_retrieve_set)) return true;

  int error = 1;
  while (!*abort_flag && error != 0) {
    error = applier_module->wait_for_applier_event_execution(
        current_retrieve_set, 1, update_THD_status);

    /* purecov: begin inspected */
    if (error == -2) {  // error when waiting
      return true;
    }
    /* purecov: end */
  }
  return false;
}

Certification_handler *Applier_module::get_certification_handler() {
  Event_handler *event_applier = nullptr;
  Event_handler::get_handler_by_role(pipeline, CERTIFIER, &event_applier);

  // The only certification handler for now
  return (Certification_handler *)event_applier;
}

int Applier_module::intersect_group_executed_sets(
    std::vector<std::string> &gtid_sets, Gtid_set *output_set) {
  Sid_map *sid_map = output_set->get_sid_map();

  std::vector<std::string>::iterator set_iterator;
  for (set_iterator = gtid_sets.begin(); set_iterator != gtid_sets.end();
       set_iterator++) {
    Gtid_set member_set(sid_map, nullptr);
    Gtid_set intersection_result(sid_map, nullptr);

    std::string exec_set_str = (*set_iterator);

    if (member_set.add_gtid_text(exec_set_str.c_str()) != RETURN_STATUS_OK) {
      return 1; /* purecov: inspected */
    }

    if (output_set->is_empty()) {
      if (output_set->add_gtid_set(&member_set)) {
        return 1; /* purecov: inspected */
      }
    } else {
      /*
        We have three sets:
          member_set:          the one sent from a given member;
          output_set:        the one that contains the intersection of
                               the computed sets until now;
          intersection_result: the intersection between set and
                               intersection_result.
        So we compute the intersection between member_set and output_set, and
        set that value to output_set to be used on the next intersection.
      */
      if (member_set.intersection(output_set, &intersection_result) !=
          RETURN_STATUS_OK) {
        return 1; /* purecov: inspected */
      }

      output_set->clear();
      if (output_set->add_gtid_set(&intersection_result) != RETURN_STATUS_OK) {
        return 1; /* purecov: inspected */
      }
    }
  }

#if !defined(NDEBUG)
  char *executed_set_string;
  output_set->to_string(&executed_set_string);
  DBUG_PRINT("info", ("View change GTID information: output_set: %s",
                      executed_set_string));
  my_free(executed_set_string);
#endif

  return 0;
}

void Applier_module::queue_certification_enabling_packet() {
  incoming->push(new Single_primary_action_packet(
      Single_primary_action_packet::NEW_PRIMARY));
}

bool Applier_module::queue_and_wait_on_queue_checkpoint(
    std::shared_ptr<Continuation> checkpoint_condition) {
  incoming->push(new Queue_checkpoint_packet(checkpoint_condition));
  return checkpoint_condition->wait() != 0;
}

Pipeline_member_stats *Applier_module::get_local_pipeline_stats() {
  // We need run_lock to get protection against STOP GR command.

  MUTEX_LOCK(guard, &run_lock);
  Pipeline_member_stats *stats = nullptr;
  auto cert = get_certification_handler();
  auto cert_module = (cert ? cert->get_certifier() : nullptr);
  if (cert_module) {
    stats = new Pipeline_member_stats(
        get_pipeline_stats_member_collector(), get_message_queue_size(),
        cert_module->get_negative_certified(),
        cert_module->get_certification_info_size());
    {
      char *committed_transactions_buf = nullptr;
      size_t committed_transactions_buf_length = 0;
      int outcome = cert_module->get_group_stable_transactions_set_string(
          &committed_transactions_buf, &committed_transactions_buf_length);
      if (!outcome && committed_transactions_buf_length > 0)
        stats->set_transaction_committed_all_members(
            committed_transactions_buf, committed_transactions_buf_length);
      my_free(committed_transactions_buf);
    }
    {
      std::string last_conflict_free_transaction;
      cert_module->get_last_conflict_free_transaction(
          &last_conflict_free_transaction);
      stats->set_transaction_last_conflict_free(last_conflict_free_transaction);
    }

  } else {
    stats = new Pipeline_member_stats(get_pipeline_stats_member_collector(),
                                      get_message_queue_size(), 0, 0);
  }
  return stats;
}
