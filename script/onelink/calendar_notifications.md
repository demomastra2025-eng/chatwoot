# Calendar appointment notifications

The Calendar → Notifications screen lists appointment-event `AutomationRule` records, one per row. Rules with the `calendar_managed` flag can be edited there. Appointment automations without a notification action remain read-only and stay managed in Automations. The six ready-made options use the same rules and message actions. The generic Automations list shows calendar-managed rules as read-only links to the calendar.

Appointment rules use `AutomationRules::AppointmentConditionService`, including service, specialist (`resource_id`), cabinet, status, source and appointment custom fields. A zero relative offset is valid. Visit-start notices use `appointment.starts_at`; visit-end notices use `appointment_completed` and `appointment.ends_at`, so they are created only after the appointment is completed. A status transition to `no_show` emits `appointment_no_show`.

## Adopt existing rules

Run the dry-run first:

```bash
bundle exec rake calendar_notifications:adopt MODE=dry-run BACKUP=/path/to/calendar-rule-backup.json
```

The task prints candidate counts per account and writes a JSON backup containing only rule IDs, account IDs and their original flag value. It selects appointment-event rules with a `create_touch` action. To mark the same rows in place, run:

```bash
bundle exec rake calendar_notifications:adopt MODE=apply BACKUP=/path/to/calendar-rule-backup.json
```

The task does not create rules or change their enabled state, conditions or actions. Keep the backup with the release record. The appointment drawer reads account-scoped reminder and active enrollment state through `GET /api/v1/accounts/:account_id/scheduling/appointments/:id/notifications`.
